import CryptoKit
import Foundation

// Get 3DAPI Quote… (DapiQuoteView.swift): prices a library model on 3DAPI and sets it beside what Slant charges.
// Pure helpers first, then `DapiQuoteRunner`, which talks to 3DAPI only through an injected `DapiQuoting`. See
// docs/3DAPI_REFERENCE.md §2 (quote flow), §3.3 (shipping estimate) and §6 (money). Nothing here is saved to disk:
// the only memory of a quote is `DapiConnection`'s session cache of ready quote IDs and its records of quote writes in
// flight or with an unknown outcome, all by file hash.

// MARK: - Names sent to 3DAPI

/// The quote's name on 3DAPI: neutral, derived from the file's bytes only, never the model's own name. The same file
/// always gets the same name, which is how `quotes(named:)` finds a quote made earlier (or one whose create had an
/// unknown outcome).
func dapiQuoteName(fileHash: String) -> String {
    "Plinth " + String(fileHash.lowercased().prefix(16))
}

/// The upload's file name: neutral like the quote name, with the extension 3DAPI checks against the content type.
func dapiUploadFileName(fileHash: String, format: ModelFileFormat) -> String {
    "plinth-\(fileHash.lowercased().prefix(16)).\(format.rawValue)"
}

/// SHA-256 of the file's bytes as lower-case hex, read in 1 MiB pieces so a large model never sits in memory whole.
func dapiFileSHA256(at url: URL, chunkSize: Int = 1 << 20) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// `dapiFileSHA256`, stopping with `CancellationError` between pieces once the current task is cancelled.
func dapiFileSHA256Cancellable(at url: URL, chunkSize: Int = 1 << 20) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
        try Task.checkCancellation()
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

/// What identifies a file's content for a session hash cache: its path, size and modification date.
struct DapiFileIdentity: Hashable, Sendable {
    let path: String
    let size: Int64
    let modified: Date?
}

/// The identity of a regular file that exists, else nil.
func dapiFileIdentity(at url: URL) -> DapiFileIdentity? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          (attributes[.type] as? FileAttributeType) == .typeRegular,
          let size = attributes[.size] as? NSNumber else { return nil }
    return DapiFileIdentity(path: url.standardizedFileURL.path, size: size.int64Value, modified: attributes[.modificationDate] as? Date)
}

/// The file's size when it is a regular file that exists, else nil.
func dapiRegularFileSize(at url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          (attributes[.type] as? FileAttributeType) == .typeRegular,
          let size = attributes[.size] as? NSNumber else { return nil }
    return size.int64Value
}

/// Why this file can't be quoted, checked before anything is read or sent; nil when it can.
func dapiQuoteFileProblem(size: Int64?, format: ModelFileFormat?) -> String? {
    guard format != nil else { return dapiQuotableFormatsText }
    guard let size else { return "The model’s file is missing. It may have been moved or deleted." }
    if size <= 0 { return "The model’s file is empty." }
    if size > dapiMaxQuoteFileBytes { return "The model’s file is larger than 3DAPI’s 250 MB limit for quotes." }
    return nil
}

// MARK: - Finding a quote made earlier

enum DapiExistingQuote: Equatable {
    case ready(DapiQuote)
    case processing(DapiQuote)
    case none
}

/// From `quotes(named:)`: the newest usable ready quote, else the newest still processing. Failed ones are ignored
/// (3DAPI gives a failed quote back to the allowance, and a new upload may succeed), and so are quotes 3DAPI rejected
/// in review and ready ones without a price, which can't be compared. Quotes are matched by exact name again here, so
/// a client that returned more than asked can't hand back another file's price.
func dapiPickExistingQuote(_ quotes: [DapiQuote], name: String) -> DapiExistingQuote {
    let named = quotes.enumerated().filter { $0.element.name == name && !$0.element.isRejected }
    // Newest first by `createdAt`; quotes without one keep 3DAPI's own (newest-first) order after those with one.
    let sorted = named.sorted { lhs, rhs in
        switch (lhs.element.createdAt, rhs.element.createdAt) {
        case let (l?, r?) where l != r: return l > r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.offset < rhs.offset
        }
    }.map(\.element)
    if let ready = sorted.first(where: \.isUsable) { return .ready(ready) }
    if let processing = sorted.first(where: \.isProcessing) { return .processing(processing) }
    return .none
}

// MARK: - Polling

let dapiQuotePollFastInterval: TimeInterval = 5
let dapiQuotePollFastPhase: TimeInterval = 120
let dapiQuotePollSlowInterval: TimeInterval = 15
let dapiQuotePollGiveUp: TimeInterval = 15 * 60
/// How many pages of 100 quotes the read-only lookup reads before deciding there is no quote for this file.
let dapiQuoteLookupPages = 3

/// The wait before the next read of a processing quote: 5 s for the first 2 minutes, then 15 s; nil once 15 minutes
/// have passed, when polling stops and the seller can Check Again.
func dapiQuotePollDelay(elapsed: TimeInterval) -> TimeInterval? {
    guard elapsed < dapiQuotePollGiveUp else { return nil }
    return elapsed < dapiQuotePollFastPhase ? dapiQuotePollFastInterval : dapiQuotePollSlowInterval
}

// MARK: - Money

/// "$12.45" for USD (rounded to the cent); any other currency with its code ("EUR 12.45"), using ISO 4217's decimal
/// places, and never converted. A currency that isn't a three-letter code is shown as 3DAPI's raw minor units.
func dapiMoneyText(_ value: DapiMoney) -> String {
    if let usd = value.usd { return money(NSDecimalNumber(decimal: roundedToCents(usd))) }
    let code = value.currency.trimmingCharacters(in: .whitespaces).uppercased()
    guard code.count == 3, code.allSatisfy({ $0.isASCII && $0.isLetter }) else {
        return "\(value.amountMinor) (unknown currency)"
    }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .currencyISOCode
    formatter.usesGroupingSeparator = true
    formatter.currencyCode = code
    let digits = formatter.maximumFractionDigits
    var divisor = Decimal(1)
    for _ in 0..<max(0, digits) { divisor *= 10 }
    let major = Decimal(value.amountMinor) / divisor
    return formatter.string(from: NSDecimalNumber(decimal: major)).map { $0.replacingOccurrences(of: "\u{00A0}", with: " ") }
        ?? "\(value.amountMinor) (\(code) minor units)"
}

/// `value` × `quantity`, in the same currency; nil on overflow.
func dapiMoneyTimes(_ value: DapiMoney, _ quantity: Int) -> DapiMoney? {
    let (product, overflow) = value.amountMinor.multipliedReportingOverflow(by: quantity)
    return overflow ? nil : DapiMoney(amountMinor: product, currency: value.currency)
}

/// The sum when both amounts are in the same currency; nil otherwise (they are never combined) or on overflow.
func dapiMoneySum(_ lhs: DapiMoney, _ rhs: DapiMoney) -> DapiMoney? {
    guard lhs.currency.lowercased() == rhs.currency.lowercased() else { return nil }
    let (sum, overflow) = lhs.amountMinor.addingReportingOverflow(rhs.amountMinor)
    return overflow ? nil : DapiMoney(amountMinor: sum, currency: lhs.currency)
}

// MARK: - The Slant side

/// Slant's print total for the comparison: only a current estimate (`estimateIsCurrent`) for this very model (it is
/// the selected one and linked to the uploaded file the estimate priced) at the sheet's quantity. Never fetched here.
func dapiSlantPrintTotal(estimate: [String: Any]?, estimateIsCurrent: Bool, sheetModelID: UUID, selectedLocalID: UUID?,
                         selectedRemoteID: String?, fileID: String, estimateQuantity: Int, sheetQuantity: Int) -> Decimal? {
    guard estimateIsCurrent, selectedLocalID == sheetModelID, !fileID.isEmpty, selectedRemoteID == fileID,
          estimateQuantity == sheetQuantity, let estimate,
          let total = estimateAmount(estimate["total"]), total >= 0 else { return nil }
    return total
}

/// What Slant charged for delivery to `countryCode` across the loaded orders the Spending Report counts: those on the
/// default platform (`spendReportDeliveryCost` in SpendReport.swift), by its rules (charged orders,
/// USD). Nil when none went there.
func dapiSlantDelivery(orders: [Record], platformID: String, countryCode: String) -> SpendReportDeliveryCost? {
    spendReportDeliveryCost(orders: orders, platformID: platformID, countryCode: countryCode)
}

func dapiCountryName(_ code: String, locale: Locale = .current) -> String {
    locale.localizedString(forRegionCode: code) ?? code
}

/// Countries whose English name takes "the" in a sentence ("a parcel to the United Kingdom").
let dapiCountriesTakingThe: Set<String> = [
    "AE", "BS", "CD", "CF", "CG", "CK", "CX", "CC", "DO", "FK", "FO", "GB", "GM", "IO", "KM", "KY", "MH", "MP", "MV", "NL",
    "PH", "PS", "SB", "SC", "TC", "TF", "UM", "US", "VA", "VG", "VI"
]

/// The country's name for use inside an English sentence: "the United Kingdom", "Germany". "the" is added only when
/// the Mac shows country names in English.
func dapiCountryPhrase(_ code: String, locale: Locale = .current) -> String {
    let upper = code.uppercased()
    let name = dapiCountryName(upper, locale: locale)
    guard locale.language.languageCode == .english, dapiCountriesTakingThe.contains(upper),
          !name.lowercased().hasPrefix("the ") else { return name }
    return "the " + name
}

// MARK: - The comparison

/// The country and quantity a shipping estimate was (or is to be) asked for.
struct DapiShippingKey: Equatable, Sendable {
    let countryCode: String
    let quantity: Int
}

/// The shipping shown no longer matches the country or quantity chosen.
func dapiShippingIsStale(shippingFor: DapiShippingKey?, destination: DapiShippingKey?) -> Bool {
    guard let shippingFor else { return false }
    return shippingFor != destination
}

struct DapiComparisonCell: Equatable {
    var value: String
    var note: String?
    /// Shown in orange: out of date or missing.
    var isWarning = false
}

struct DapiComparisonRow: Equatable, Identifiable {
    let id: String
    let label: String
    let dapi: DapiComparisonCell
    let slant: DapiComparisonCell
}

struct DapiComparisonInputs {
    var unitPrice: DapiMoney
    var quantity: Int
    var countryCode: String
    var shipping: DapiShippingEstimate?
    var shippingIsStale: Bool
    var slantPrintTotal: Decimal?
    var slantDelivery: SpendReportDeliveryCost?
}

let dapiNoSlantEstimateText = "No current Slant estimate for this quantity — get one in Models with Slant 3D as the print service"
let dapiUpperBoundNote = "3DAPI charges less per unit for larger quantities; the exact price comes only with an order."
let dapiSlantNoDeliveryHistoryText = "None of your loaded orders went there. Slant prices delivery only in a draft."
let dapiSlantTotalOtherParcelsText = "Past delivery charges were for other parcels, so they aren’t added to this quantity."
let dapiVATNote = "3DAPI’s prices are before VAT, which it adds only for UK and EU businesses without a confirmed VAT number."
let dapiComparisonOnlyNote = "This sheet only compares prices; it orders nothing. To print with 3DAPI, choose 3DAPI as the print service in Settings › Account, then use Order with 3DAPI… in Models once 3DAPI has approved your account."

/// The parcel size 3DAPI priced ("Small parcel"), or "Flat rate" when it couldn't weigh the order yet. 3DAPI's zone
/// name is internal and isn't shown.
func dapiShippingNote(_ shipping: DapiShippingEstimate) -> String {
    guard let tier = shipping.tier?.trimmingCharacters(in: .whitespaces), !tier.isEmpty else { return "Flat rate" }
    return tier.prefix(1).uppercased() + tier.dropFirst().lowercased() + " parcel"
}

/// The Slant delivery cell's note: how many past orders the figure comes from.
func dapiSlantDeliveryNote(_ delivery: SpendReportDeliveryCost, countryCode: String) -> String {
    let country = dapiCountryPhrase(countryCode)
    if delivery.orders == 1 { return "From 1 past order to \(country), whatever it held" }
    return "Average of \(delivery.orders) past orders to \(country) (\(spendReportRangeText(delivery))), whatever they held"
}

func dapiComparisonRows(_ inputs: DapiComparisonInputs) -> [DapiComparisonRow] {
    let quantity = max(1, inputs.quantity)
    let usd: (Decimal) -> String = { money(NSDecimalNumber(decimal: roundedToCents($0))) }
    var rows: [DapiComparisonRow] = []

    // Print.
    let slantPrint: DapiComparisonCell = inputs.slantPrintTotal.map { DapiComparisonCell(value: usd($0)) }
        ?? DapiComparisonCell(value: "—", note: dapiNoSlantEstimateText, isWarning: true)
    let dapiPrintTotal = dapiMoneyTimes(inputs.unitPrice, quantity)
    if quantity == 1 {
        rows.append(DapiComparisonRow(id: "print", label: "Print, 1 unit",
                                      dapi: DapiComparisonCell(value: dapiMoneyText(inputs.unitPrice)), slant: slantPrint))
    } else {
        let slantEach = inputs.slantPrintTotal.flatMap { comparisonPerUnit(total: $0, quantity: quantity) }
        rows.append(DapiComparisonRow(
            id: "unit", label: "Print, 1 unit",
            dapi: DapiComparisonCell(value: dapiMoneyText(inputs.unitPrice), note: "Price for a single unit"),
            slant: slantEach.map { DapiComparisonCell(value: usd($0), note: "Per unit at \(quantity)") } ?? DapiComparisonCell(value: "—")))
        rows.append(DapiComparisonRow(
            id: "print", label: "Print, \(quantity) units",
            dapi: DapiComparisonCell(value: dapiPrintTotal.map { "Up to \(dapiMoneyText($0))" } ?? "—", note: dapiUpperBoundNote),
            slant: slantPrint))
    }

    // Shipping.
    let country = dapiCountryName(inputs.countryCode)
    // Stale shipping is explained once, above the table (with Update Shipping); its cells just say "—".
    let dapiShipping: DapiComparisonCell
    if let shipping = inputs.shipping, !inputs.shippingIsStale {
        dapiShipping = DapiComparisonCell(value: dapiMoneyText(shipping.total), note: dapiShippingNote(shipping))
    } else if inputs.shippingIsStale {
        dapiShipping = DapiComparisonCell(value: "—")
    } else {
        dapiShipping = DapiComparisonCell(value: "—", note: "Not priced yet.")
    }
    let slantShipping: DapiComparisonCell
    if let delivery = inputs.slantDelivery, let average = delivery.average {
        slantShipping = DapiComparisonCell(value: usd(average), note: dapiSlantDeliveryNote(delivery, countryCode: inputs.countryCode))
    } else {
        slantShipping = DapiComparisonCell(value: "—", note: dapiSlantNoDeliveryHistoryText)
    }
    rows.append(DapiComparisonRow(id: "shipping", label: "Shipping (\(country))", dapi: dapiShipping, slant: slantShipping))

    // Total.
    let dapiTotal: DapiComparisonCell
    if let shipping = inputs.shipping, !inputs.shippingIsStale, let print = dapiPrintTotal {
        if let sum = dapiMoneySum(print, shipping.total) {
            dapiTotal = DapiComparisonCell(value: quantity > 1 ? "Up to \(dapiMoneyText(sum))" : dapiMoneyText(sum))
        } else {
            dapiTotal = DapiComparisonCell(value: "—", note: "Print and shipping are in different currencies, so they aren’t added.")
        }
    } else {
        dapiTotal = DapiComparisonCell(value: "—")
    }
    // Past delivery charges were for whatever those parcels held, so they're added only to a single unit.
    let slantTotal: DapiComparisonCell
    if let print = inputs.slantPrintTotal, let average = inputs.slantDelivery?.average {
        slantTotal = quantity == 1
            ? DapiComparisonCell(value: "About \(usd(print + average))", note: "Print estimate plus average past delivery")
            : DapiComparisonCell(value: "—", note: dapiSlantTotalOtherParcelsText)
    } else {
        slantTotal = DapiComparisonCell(value: "—")
    }
    rows.append(DapiComparisonRow(id: "total", label: "Total", dapi: dapiTotal, slant: slantTotal))
    return rows
}

/// The short notes under the comparison. Figures quoted from 3DAPI's documentation carry its date.
func dapiComparisonNotes(countryCode: String, shipping: DapiShippingEstimate?, suggestedMaterials: [DapiSuggestedMaterial],
                         slantMaterialName: String?) -> [String] {
    var notes = ["The two services slice and print differently (3DAPI on its partners’ printers with its own settings, Slant with its fixed settings), so these prices aren’t for an identical part."]
    let suggested = suggestedMaterials.sorted { $0.slot < $1.slot }.compactMap { material -> String? in
        let name = (material.materialName ?? material.fileFilamentType)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (name?.isEmpty == false) ? name : nil
    }
    if !suggested.isEmpty {
        var line = "3DAPI priced it in \(suggested.joined(separator: ", ")), the material it suggested"
        if let slant = slantMaterialName?.trimmingCharacters(in: .whitespacesAndNewlines), !slant.isEmpty {
            line += "; your Slant material is \(slant)"
        }
        notes.append(line + ".")
    }
    notes.append(dapiVATNote)
    let code = countryCode.uppercased()
    if !code.isEmpty, code != "US" {
        notes.append("Slant ships from the US, so a parcel to \(dapiCountryPhrase(code)) goes through customs: it can take longer, and the buyer may pay duty or courier fees unless the marketplace collected VAT at checkout. 3DAPI prints in or near the buyer’s region where it can.")
    }
    notes.append("3DAPI’s stated times: production 3–5 business days, then delivery in 1–3 business days locally or 5–10 internationally (3DAPI docs, Oct 2026).")
    notes.append(dapiComparisonOnlyNote)
    return notes
}

/// "7 of 25 quotes used (3DAPI’s limit until it approves your account).", while the account awaits approval and the
/// allowance is known.
func dapiOnboardingAllowanceText(_ onboarding: DapiOnboarding?) -> String? {
    guard let onboarding, let limit = onboarding.uploadsLimit else { return nil }
    return "\(onboarding.uploadsUsed) of \(limit) quotes used (3DAPI’s limit until it approves your account)."
}

/// Why a new quote can't be asked for now, from the last onboarding reading, or nil. Quoting is paused while files are
/// in review, and stops once the round's quotes are used. Nil readings never block: 3DAPI refuses with a code anyway.
func dapiAllowanceProblem(_ onboarding: DapiOnboarding?) -> String? {
    guard let onboarding else { return nil }
    if onboarding.status == "in_review" {
        return "3DAPI pauses new quotes while it reviews the files you submitted for approval. Nothing was sent; press Get Quote once the review is done."
    }
    if let limit = onboarding.uploadsLimit, onboarding.uploadsUsed >= limit {
        return "You’ve used all \(limit) quotes 3DAPI allows until it approves your account. Submit files for approval in 3DAPI’s dashboard to get more. Nothing was sent."
    }
    return nil
}

// MARK: - Earlier writes this session

/// What Get Quote may do once the lookup found no quote for the file.
enum DapiNewQuoteGate: Equatable {
    /// Upload and create one quote.
    case proceed
    /// An upload or create for this file is still waiting for 3DAPI (perhaps from a sheet that was closed): send nothing.
    case wait
    /// An earlier upload or create for this file had an unknown outcome: ask before sending another.
    case confirm
}

func dapiNewQuoteGate(writeInFlight: Bool, outcomeUnknown: Bool, confirmedAnother: Bool) -> DapiNewQuoteGate {
    if writeInFlight { return .wait }
    if outcomeUnknown && !confirmedAnother { return .confirm }
    return .proceed
}

let dapiWriteInFlightText = "3DAPI is still answering an earlier request for this file. Wait a moment, then press Get Quote."
let dapiAnotherQuoteTitle = "Get another quote?"
let dapiAnotherQuoteMessage = "An earlier request for this file didn’t get a clear answer, and Plinth couldn’t find its quote. 3DAPI may already have the earlier request, and another may use one more quote from your allowance."

// MARK: - Errors

enum DapiQuoteStep: Equatable, Sendable {
    /// Looking for a quote, and the allowance check: reads.
    case lookup
    /// `POST /v2/uploads`: a write.
    case upload
    /// The presigned PUT of the file's bytes: cancellable.
    case transfer
    /// `POST /v2/quotes`: a write.
    case create
    case poll, shipping
}

/// The next midnight UTC after `now`, when `daily_quote_limit_reached` resets.
func dapiNextMidnightUTC(after now: Date) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let start = calendar.startOfDay(for: now)
    return calendar.date(byAdding: .day, value: 1, to: start) ?? now.addingTimeInterval(86_400)
}

/// What the sheet says when a step fails. Nothing is ever retried by itself; the seller decides.
func dapiQuoteErrorMessage(_ error: DapiError, step: DapiQuoteStep, now: Date, timeZone: TimeZone = .current) -> String {
    switch error {
    case .missingKey:
        return "No 3DAPI key is saved. Add one in Settings, then try again."
    case .rateLimited(let code, let retryAt):
        if code == "daily_quote_limit_reached" {
            let formatter = DateFormatter()
            formatter.timeZone = timeZone
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            let reset = formatter.string(from: dapiNextMidnightUTC(after: now))
            return "3DAPI’s daily quote limit for accounts awaiting approval is used up. It resets at midnight UTC (\(reset) your time)."
        }
        let wait = retryAt.map { rateLimitResetWaitCopy(secondsFromNow: max(1, $0.timeIntervalSince(now))) } ?? "Try again in about a minute."
        return "3DAPI’s rate limit was reached. \(wait)"
    case .outcomeUnknown:
        switch step {
        case .upload:
            return "3DAPI may have received the upload request, but its reply didn’t come back. No quote was requested and nothing was sent again; 3DAPI deletes unused uploads after 24 hours."
        case .transfer:
            return "The file may not have reached 3DAPI in full: the reply didn’t come back. No quote was requested and nothing was sent again; 3DAPI deletes unused uploads after 24 hours."
        case .create:
            return "3DAPI may have made the quote, but its reply didn’t come back. Nothing was sent again. Get Quote looks for this quote first next time."
        default:
            return error.userMessage
        }
    case .refused:
        let message = error.userMessage
        let prefix: String
        switch step {
        case .upload, .transfer: prefix = "3DAPI refused the file."
        case .create: prefix = "3DAPI refused the quote."
        case .shipping: prefix = "3DAPI couldn’t price shipping."
        default: return message
        }
        // 3DAPI's storage gives no reason Plinth can use, so say what to do next.
        if step == .transfer { return "\(prefix) Press Get Quote to upload it again." }
        return message.hasPrefix("3DAPI") ? message : "\(prefix) \(message)"
    case .notSent, .readFailed:
        return error.userMessage
    }
}

// MARK: - Runner

/// Everything the runner needs from the app, injected so tests run without `DapiConnection`, the Keychain or a store.
struct DapiQuoteEnvironment {
    var client: @MainActor () throws -> any DapiQuoting
    var readyQuoteID: @MainActor (_ fileHash: String) -> String?
    var rememberReadyQuote: @MainActor (_ id: String, _ fileHash: String) -> Void
    var beginRequest: @MainActor () -> Void
    var endRequest: @MainActor () -> Void
    /// The session's records of quote writes by file hash (`DapiConnection`): in flight, and unknown outcomes.
    var quoteWriteInFlight: @MainActor (_ fileHash: String) -> Bool
    var quoteWriteOutcomeUnknown: @MainActor (_ fileHash: String) -> Bool
    var beginQuoteWrite: @MainActor (_ fileHash: String) -> Void
    var endQuoteWrite: @MainActor (_ fileHash: String) -> Void
    var noteQuoteWriteUnknown: @MainActor (_ fileHash: String) -> Void
    /// Reads onboarding (the allowance) and returns it; nil when the read failed or was cancelled. A read.
    var readAllowance: @MainActor () async -> DapiOnboarding?
    /// After a quote is created, so "N of 25 quotes used" stays right. A read.
    var refreshAllowance: @MainActor () async -> Void
    var sleep: @Sendable (TimeInterval) async throws -> Void
    var now: @MainActor () -> Date
    var newIdempotencyKey: @MainActor () -> String
    var fileSize: @Sendable (URL) -> Int64?
    var hashFile: @Sendable (URL) throws -> String

    @MainActor static func live() -> DapiQuoteEnvironment {
        let connection = DapiConnection.shared
        return DapiQuoteEnvironment(
            client: { try connection.currentClient() },
            readyQuoteID: { connection.readyQuoteID(forFileHash: $0) },
            rememberReadyQuote: { connection.rememberReadyQuote(id: $0, forFileHash: $1) },
            beginRequest: { connection.beginRequest() },
            endRequest: { connection.endRequest() },
            quoteWriteInFlight: { connection.quoteWriteIsInFlight(forFileHash: $0) },
            quoteWriteOutcomeUnknown: { connection.quoteWriteOutcomeUnknown(forFileHash: $0) },
            beginQuoteWrite: { connection.beginQuoteWrite(forFileHash: $0) },
            endQuoteWrite: { connection.endQuoteWrite(forFileHash: $0) },
            noteQuoteWriteUnknown: { connection.noteQuoteWriteUnknown(forFileHash: $0) },
            readAllowance: { await connection.refreshOnboarding() },
            refreshAllowance: { await connection.refreshOnboarding() },
            sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
            now: { Date() },
            newIdempotencyKey: { UUID().uuidString },
            fileSize: { dapiRegularFileSize(at: $0) },
            hashFile: { try dapiFileSHA256(at: $0) }
        )
    }
}

enum DapiQuotePhase: Equatable {
    case idle
    case checkingFile
    case lookingUp
    /// `POST /v2/uploads`, then the file's bytes (`DapiQuoteRunner.writeInFlight` tells which).
    case uploading
    case creating
    /// Reading a processing quote every few seconds.
    case processing
    /// A quote exists but isn't ready, and nothing is being read: stopped, given up after 15 minutes, or a read
    /// failed. Check Again reads it once and resumes polling.
    case paused(String)
    case ready
    /// 3DAPI couldn't quote the file; its reason, when it gave one.
    case quoteFailed(String?)
    /// No quote was found, and an earlier write for this file had an unknown outcome: the sheet asks before another.
    case confirmAnother
    /// Stopped before a usable quote was found or made; Get Quote starts again (looking first).
    case problem(String)
}

let dapiStoppedPausedText = "Stopped. 3DAPI is still working on the quote: press Check Again to see whether it’s ready."
let dapiGaveUpPausedText = "3DAPI is still working on the quote after 15 minutes: press Check Again to see whether it’s ready."
let dapiStoppedBeforeBytesText = "Stopped. The file wasn’t sent."
let dapiStoppedDuringBytesText = "Stopped while the file was being sent, so 3DAPI may have part of it. No quote was requested; 3DAPI deletes unused uploads after 24 hours."
let dapiStoppedAfterUploadText = "Stopped after the upload. No quote was requested; 3DAPI deletes unused uploads after 24 hours."

/// Why a ready quote can't be compared, or nil when it can.
func dapiUnusableQuoteMessage(_ quote: DapiQuote) -> String? {
    if quote.isRejected { return "3DAPI rejected this file in review, so its quote can’t be used. Press Get Quote to ask for a new one." }
    if quote.isReady && quote.price == nil { return "3DAPI marked the quote ready but sent no price. Press Get Quote to ask for a new one." }
    return nil
}

@MainActor final class DapiQuoteRunner: ObservableObject {
    @Published private(set) var phase: DapiQuotePhase = .idle
    @Published private(set) var quote: DapiQuote?
    @Published private(set) var shipping: DapiShippingEstimate?
    @Published private(set) var shippingFor: DapiShippingKey?
    @Published private(set) var shippingRequesting = false
    @Published private(set) var shippingProblem: String?
    /// A write (`POST /v2/uploads` or `POST /v2/quotes`) has been sent and hasn't answered; Stop waits for it. The
    /// file's bytes aren't a write in this sense: Stop cancels them.
    @Published private(set) var writeInFlight = false
    @Published private(set) var stopRequested = false
    /// The country and quantity chosen in the sheet; the first shipping estimate uses it once the quote is ready.
    var destination: DapiShippingKey?
    /// Status-only Activity lines ("Ready", "Failed", "Outcome unknown", `DapiError.activityDetail`).
    var log: ((_ title: String, _ detail: String, _ success: Bool) -> Void)?

    private let environment: DapiQuoteEnvironment
    private(set) var runTask: Task<Void, Never>?
    private(set) var shippingTask: Task<Void, Never>?
    private var fileHash: String?
    private(set) var isClosed = false

    init(environment: DapiQuoteEnvironment) {
        self.environment = environment
    }

    var isWorking: Bool {
        switch phase {
        case .checkingFile, .lookingUp, .uploading, .creating, .processing: return true
        default: return false
        }
    }

    /// Get Quote: look for this file's quote (session cache, then 3DAPI's list), and only when there is none, upload
    /// the file once and create one quote. `confirmedAnother` is the seller's Get Another Quote after an earlier unknown
    /// outcome for this file. Ignored while a run is going or after the sheet closed.
    func getQuote(fileURL: URL, format: ModelFileFormat?, confirmedAnother: Bool = false) {
        guard !isWorking, !isClosed else { return }
        resetForRun()
        phase = .checkingFile
        runTask = Task { await self.run(fileURL: fileURL, format: format, confirmedAnother: confirmedAnother) }
    }

    /// Don't Quote: the seller declined another quote after an unknown outcome. Nothing is sent.
    func declineAnother() {
        guard phase == .confirmAnother else { return }
        phase = .idle
    }

    /// Check Again: one read of the paused quote, then polling resumes while it is still processing.
    func checkAgain() {
        guard case .paused = phase, let id = quote?.id, !isClosed else { return }
        stopRequested = false
        phase = .processing
        runTask = Task { await self.poll(quoteID: id, readFirst: true) }
    }

    /// Stop: reads and the file's bytes stop at once; an upload request or quote create already sent is never
    /// cancelled, and the run ends when it answers.
    func stop() {
        guard isWorking else { return }
        stopRequested = true
        if !writeInFlight { runTask?.cancel() }
        shippingTask?.cancel()
    }

    /// The sheet closed: stop everything (a write in flight still finishes) and start nothing new.
    func close() {
        isClosed = true
        stop()
        shippingTask?.cancel()
        if phase == .confirmAnother { phase = .idle }
    }

    /// The same sheet appeared again after closing: accept presses again. A run still finishing a write keeps going
    /// and ends as stopped; anything else starts afresh.
    func reopen() {
        guard isClosed else { return }
        isClosed = false
        if !isWorking {
            resetForRun()
            phase = .idle
        }
    }

    /// The first estimate once ready, or Update Shipping: one read-only `shippingEstimate`, never repeated by itself.
    func requestShipping(_ key: DapiShippingKey) {
        guard !isClosed, phase == .ready, let quote, !shippingRequesting,
              !key.countryCode.isEmpty, (1...10_000).contains(key.quantity) else { return }
        shippingRequesting = true
        shippingProblem = nil
        shippingTask = Task { await self.fetchShipping(quoteID: quote.id, key: key) }
    }

    private func resetForRun() {
        stopRequested = false
        quote = nil
        shipping = nil
        shippingFor = nil
        shippingProblem = nil
        fileHash = nil
    }

    private var stopped: Bool { stopRequested || isClosed || Task.isCancelled }

    // MARK: Steps

    private func run(fileURL: URL, format: ModelFileFormat?, confirmedAnother: Bool) async {
        let size = environment.fileSize(fileURL)
        if let problem = dapiQuoteFileProblem(size: size, format: format) {
            phase = .problem(problem)
            return
        }
        guard let format, let contentType = dapiQuoteFileContentType(forExtension: format.rawValue) else {
            phase = .problem(dapiQuotableFormatsText)
            return
        }
        let hashFile = environment.hashFile
        let hash: String
        do {
            hash = try await Task.detached(priority: .userInitiated) { try hashFile(fileURL) }.value
        } catch {
            phase = .problem("The model’s file couldn’t be read.")
            return
        }
        if stopped { phase = .problem("Stopped. Nothing was sent."); return }
        fileHash = hash
        // A closed sheet's upload or create for this file may still be waiting for 3DAPI.
        if environment.quoteWriteInFlight(hash) { phase = .problem(dapiWriteInFlightText); return }
        let client: any DapiQuoting
        do {
            client = try environment.client()
        } catch {
            phase = .problem(dapiQuoteErrorMessage((error as? DapiError) ?? .missingKey, step: .lookup, now: environment.now()))
            return
        }
        let name = dapiQuoteName(fileHash: hash)

        // 1. A ready quote found earlier this session (unless it has since been rejected or has no price).
        phase = .lookingUp
        if let cachedID = environment.readyQuoteID(hash) {
            switch await read(step: .lookup, { try await client.quote(id: cachedID) }) {
            case .success(let found) where found.isUsable:
                finishReady(found)
                return
            case .success:
                break // Not usable after all: look it up by name below.
            case .failure(let message, let detail):
                end(.problem(message), detail: detail)
                return
            }
        }

        // 2. A quote for this file made earlier (including one whose create had an unknown outcome).
        let existing: [DapiQuote]
        switch await read(step: .lookup, { try await client.quotes(named: name, maxPages: dapiQuoteLookupPages) }) {
        case .success(let list): existing = list
        case .failure(let message, let detail): end(.problem(message), detail: detail); return
        }
        switch dapiPickExistingQuote(existing, name: name) {
        case .ready(let found):
            finishReady(found)
            return
        case .processing(let found):
            quote = found
            phase = .processing
            await poll(quoteID: found.id, readFirst: false)
            return
        case .none:
            break
        }
        if stopped { end(.problem("Stopped. Nothing was sent.")); return }

        // 3. Nothing found. An earlier write for this file that is still waiting, or whose outcome is unknown, comes
        //    first: never a second one while the first may be in flight, and another only after the seller says so.
        switch dapiNewQuoteGate(writeInFlight: environment.quoteWriteInFlight(hash),
                                outcomeUnknown: environment.quoteWriteOutcomeUnknown(hash), confirmedAnother: confirmedAnother) {
        case .wait:
            end(.problem(dapiWriteInFlightText), detail: "Earlier request still waiting")
            return
        case .confirm:
            phase = .confirmAnother
            return
        case .proceed:
            break
        }

        // 4. The allowance, read fresh: nothing is uploaded while quoting is paused or the round is used up. A failed
        //    read doesn't stop it (3DAPI refuses with a code anyway).
        let allowance = await environment.readAllowance()
        if stopped { end(.problem("Stopped. Nothing was sent.")); return }
        if let problem = dapiAllowanceProblem(allowance) {
            end(.problem(problem), detail: allowance?.status == "in_review" ? "Quoting paused" : "Allowance used")
            return
        }
        guard let currentSize = environment.fileSize(fileURL), currentSize == size else {
            end(.problem("The model’s file changed after Get Quote was pressed. Nothing was sent; press Get Quote again."))
            return
        }

        // 5. Upload once, then create one quote.
        phase = .uploading
        guard let created = await uploadAndCreate(client: client, fileURL: fileURL, format: format, contentType: contentType,
                                                  size: currentSize, hash: hash, name: name) else { return }
        quote = created
        await environment.refreshAllowance()
        if created.isReady { finishReady(created); return }
        if created.isFailed { finishFailed(created); return }
        if stopRequested || isClosed {
            end(.paused(dapiStoppedPausedText))
            return
        }
        phase = .processing
        await poll(quoteID: created.id, readFirst: false)
    }

    /// `POST /v2/uploads`, the file's bytes, then `POST /v2/quotes`: each sent once with its own fresh Idempotency-Key.
    /// The span is recorded as in flight for this file (so no second one starts meanwhile, even from a reopened sheet);
    /// the bytes between the two writes can be stopped. Nil when it ended (the phase says why).
    private func uploadAndCreate(client: any DapiQuoting, fileURL: URL, format: ModelFileFormat, contentType: String,
                                 size: Int64, hash: String, name: String) async -> DapiQuote? {
        environment.beginQuoteWrite(hash)
        defer { environment.endQuoteWrite(hash) }
        let uploadKey = environment.newIdempotencyKey()
        let target: DapiUploadTarget
        switch await write(step: .upload, hash: hash, {
            try await client.createUpload(fileName: dapiUploadFileName(fileHash: hash, format: format), contentType: contentType,
                                          sizeBytes: size, idempotencyKey: uploadKey)
        }) {
        case .success(let made): target = made
        case .failure(let message, let detail): end(.problem(message), detail: detail); return nil
        }
        if stopped { end(.problem(dapiStoppedBeforeBytesText)); return nil }
        switch await read(step: .transfer, { try await client.sendUploadBytes(target, fileURL: fileURL) }) {
        case .success: break
        case .failure(let message, let detail): end(.problem(message), detail: detail); return nil
        }
        if stopped { end(.problem(dapiStoppedAfterUploadText)); return nil }
        phase = .creating
        let createKey = environment.newIdempotencyKey()
        switch await write(step: .create, hash: hash, {
            try await client.createQuote(uploadID: target.uploadID, name: name, idempotencyKey: createKey)
        }) {
        case .success(let made): return made
        case .failure(let message, let detail): end(.problem(message), detail: detail); return nil
        }
    }

    private func poll(quoteID: String, readFirst: Bool) async {
        let started = environment.now()
        var readNow = readFirst
        while true {
            if !readNow {
                guard let delay = dapiQuotePollDelay(elapsed: environment.now().timeIntervalSince(started)) else {
                    end(.paused(dapiGaveUpPausedText))
                    return
                }
                do {
                    try await environment.sleep(delay)
                } catch {
                    end(.paused(dapiStoppedPausedText))
                    return
                }
            }
            readNow = false
            if stopRequested || Task.isCancelled {
                end(.paused(dapiStoppedPausedText))
                return
            }
            switch await read(step: .poll, { try await self.readQuote(id: quoteID) }) {
            case .success(let latest):
                quote = latest
                if latest.isReady { finishReady(latest); return }
                if latest.isFailed { finishFailed(latest); return }
            case .failure(let message, let detail):
                end(.paused(message), detail: detail)
                return
            }
        }
    }

    /// One read of a quote with the client for the key saved now (a removed key stops polling with a message).
    private func readQuote(id: String) async throws -> DapiQuote {
        try await environment.client().quote(id: id)
    }

    private func fetchShipping(quoteID: String, key: DapiShippingKey) async {
        defer { shippingRequesting = false }
        let client: any DapiQuoting
        do { client = try environment.client() } catch {
            shippingProblem = dapiQuoteErrorMessage((error as? DapiError) ?? .missingKey, step: .shipping, now: environment.now())
            return
        }
        switch await read(step: .shipping, { try await client.shippingEstimate(quoteID: quoteID, quantity: key.quantity, countryCode: key.countryCode.uppercased()) }) {
        case .success(let estimate):
            guard !isClosed, quote?.id == quoteID else { return }
            shipping = estimate
            shippingFor = key
        case .failure(let message, let detail):
            guard !isClosed, !Task.isCancelled else { return }
            shippingProblem = message
            log?("3DAPI shipping estimate", detail, false)
        }
    }

    // MARK: Requests

    private enum Outcome<Value> {
        case success(Value)
        /// The sheet's message, and the status-only Activity detail.
        case failure(String, detail: String)
    }

    /// A read, or the file's bytes: counted with `beginRequest`/`endRequest`, cancellable by Stop.
    private func read<Value>(step: DapiQuoteStep, _ body: () async throws -> Value) async -> Outcome<Value> {
        environment.beginRequest()
        defer { environment.endRequest() }
        do {
            return .success(try await body())
        } catch {
            return describe(error, step: step)
        }
    }

    /// A write: sent once, never cancelled (the run's task isn't cancelled while `writeInFlight`), never re-sent. An
    /// unknown outcome is recorded for the file for the session.
    private func write<Value>(step: DapiQuoteStep, hash: String, _ body: () async throws -> Value) async -> Outcome<Value> {
        environment.beginRequest()
        writeInFlight = true
        defer {
            writeInFlight = false
            environment.endRequest()
        }
        do {
            return .success(try await body())
        } catch {
            if case .outcomeUnknown? = error as? DapiError { environment.noteQuoteWriteUnknown(hash) }
            return describe(error, step: step)
        }
    }

    private func describe<Value>(_ error: Error, step: DapiQuoteStep) -> Outcome<Value> {
        if dapiIsCancellation(error) {
            return .failure(step == .transfer ? dapiStoppedDuringBytesText : "Stopped. Nothing more was sent.", detail: "Stopped")
        }
        let dapiError = (error as? DapiError) ?? .readFailed(dapiRedacted(error.localizedDescription))
        let detail: String
        if case .outcomeUnknown = dapiError, step == .upload || step == .transfer || step == .create {
            detail = "Outcome unknown"
        } else {
            detail = dapiError.activityDetail
        }
        return .failure(dapiQuoteErrorMessage(dapiError, step: step, now: environment.now()), detail: detail)
    }

    // MARK: Endings

    /// A ready quote: compared and remembered only when usable; a rejected or priceless one ends with Get Quote offered.
    private func finishReady(_ ready: DapiQuote) {
        quote = ready
        if let problem = dapiUnusableQuoteMessage(ready) {
            phase = .problem(problem)
            log?("3DAPI quote", "Not usable", false)
            return
        }
        if let fileHash { environment.rememberReadyQuote(ready.id, fileHash) }
        phase = .ready
        log?("3DAPI quote", "Ready", true)
        if let destination, !isClosed { requestShipping(destination) }
    }

    private func finishFailed(_ failed: DapiQuote) {
        quote = failed
        phase = .quoteFailed(failed.failureReason)
        log?("3DAPI quote", "Failed", false)
    }

    /// Ends a run that sent at least one request, with one status-only Activity line.
    private func end(_ newPhase: DapiQuotePhase, detail: String? = nil) {
        phase = newPhase
        let fallback: String
        if case .paused = newPhase { fallback = "Still processing" } else { fallback = "Stopped" }
        log?("3DAPI quote", detail ?? (stopRequested ? "Stopped" : fallback), false)
    }
}
