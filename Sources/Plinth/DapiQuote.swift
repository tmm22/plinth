import CryptoKit
import Foundation

// Get 3DAPI Quote… (DapiQuoteView.swift): prices a library model on 3DAPI and sets it beside what Slant charges.
// Pure helpers first, then `DapiQuoteRunner`, which talks to 3DAPI only through an injected `DapiQuoting`. See
// docs/3DAPI_REFERENCE.md §2 (quote flow), §3.3 (shipping estimate) and §6 (money). Nothing here is saved to disk:
// the only memory of a quote is `DapiConnection`'s session cache of ready quote IDs by file hash.

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

/// The `content_type` 3DAPI accepts for a `quote_file` of each format (docs §2.1).
func dapiContentType(_ format: ModelFileFormat) -> String {
    switch format {
    case .stl: return "model/stl"
    case .obj: return "model/obj"
    case .threeMF: return "model/3mf"
    }
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

/// The file's size when it is a regular file that exists, else nil.
func dapiRegularFileSize(at url: URL) -> Int64? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
          (attributes[.type] as? FileAttributeType) == .typeRegular,
          let size = attributes[.size] as? NSNumber else { return nil }
    return size.int64Value
}

/// Why this file can't be quoted, checked before anything is read or sent; nil when it can.
func dapiQuoteFileProblem(size: Int64?, format: ModelFileFormat?) -> String? {
    guard format != nil else { return "3DAPI quotes STL, OBJ and 3MF files only." }
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

/// From `quotes(named:)`: the newest ready quote, else the newest still processing; failed ones are ignored (3DAPI
/// gives a failed quote back to the allowance, and a new upload may succeed). Quotes are matched by exact name again
/// here, so a client that returned more than asked can't hand back another file's price.
func dapiPickExistingQuote(_ quotes: [DapiQuote], name: String) -> DapiExistingQuote {
    let named = quotes.enumerated().filter { $0.element.name == name }
    // Newest first by `createdAt`; quotes without one keep 3DAPI's own (newest-first) order after those with one.
    let sorted = named.sorted { lhs, rhs in
        switch (lhs.element.createdAt, rhs.element.createdAt) {
        case let (l?, r?) where l != r: return l > r
        case (.some, nil): return true
        case (nil, .some): return false
        default: return lhs.offset < rhs.offset
        }
    }.map(\.element)
    if let ready = sorted.first(where: \.isReady) { return .ready(ready) }
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

/// What Slant charged for delivery to `countryCode` across loaded orders (the Spending Report's rules: charged
/// orders, USD), or nil when none went there.
func dapiSlantDelivery(orders: [Record], countryCode: String) -> SpendReportDeliveryCost? {
    let code = countryCode.uppercased()
    guard !code.isEmpty else { return nil }
    return spendReport(orders: orders).deliveryCosts.first { $0.countryCode == code && $0.orders > 0 }
}

func dapiCountryName(_ code: String, locale: Locale = .current) -> String {
    locale.localizedString(forRegionCode: code) ?? code
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

let dapiNoSlantEstimateText = "No current Slant estimate for this quantity — get one in Print configuration"
let dapiUpperBoundNote = "3DAPI charges less per unit for larger quantities; the exact price comes only with an order."

func dapiShippingNote(_ shipping: DapiShippingEstimate) -> String {
    var parts: [String] = []
    if let zone = shipping.zoneName?.trimmingCharacters(in: .whitespaces), !zone.isEmpty { parts.append("Zone \(zone)") }
    if let tier = shipping.tier?.trimmingCharacters(in: .whitespaces), !tier.isEmpty { parts.append("\(tier.lowercased()) parcel") }
    if parts.isEmpty { parts.append("Flat rate") }
    parts.append("excl. VAT")
    return parts.joined(separator: " · ")
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
    let dapiShipping: DapiComparisonCell
    if let shipping = inputs.shipping, !inputs.shippingIsStale {
        dapiShipping = DapiComparisonCell(value: dapiMoneyText(shipping.total), note: dapiShippingNote(shipping))
    } else if inputs.shipping != nil {
        dapiShipping = DapiComparisonCell(value: "Out of date", note: "Update Shipping to price this country and quantity.", isWarning: true)
    } else {
        dapiShipping = DapiComparisonCell(value: "—", note: "Not priced yet.")
    }
    let slantShipping: DapiComparisonCell
    if let delivery = inputs.slantDelivery, let average = delivery.average {
        let orders = delivery.orders == 1 ? "1 loaded order" : "\(delivery.orders) loaded orders"
        let range = delivery.orders > 1 ? ", \(spendReportRangeText(delivery))" : ""
        slantShipping = DapiComparisonCell(value: "\(usd(average)) average", note: "What Slant charged (\(orders)\(range))")
    } else {
        slantShipping = DapiComparisonCell(
            value: "—", note: "Slant prices delivery when a draft is created; none of your loaded orders went to \(country).")
    }
    rows.append(DapiComparisonRow(id: "shipping", label: "Shipping to \(country)", dapi: dapiShipping, slant: slantShipping))

    // Total.
    let dapiTotal: DapiComparisonCell
    if let shipping = inputs.shipping, !inputs.shippingIsStale, let print = dapiPrintTotal {
        if let sum = dapiMoneySum(print, shipping.total) {
            dapiTotal = DapiComparisonCell(value: quantity > 1 ? "Up to \(dapiMoneyText(sum))" : dapiMoneyText(sum), note: "Excl. VAT")
        } else {
            dapiTotal = DapiComparisonCell(value: "—", note: "Print and shipping are in different currencies, so they aren’t added.")
        }
    } else {
        dapiTotal = DapiComparisonCell(value: "—", note: inputs.shippingIsStale ? "Waiting for Update Shipping." : nil)
    }
    let slantTotal: DapiComparisonCell
    if let print = inputs.slantPrintTotal, let average = inputs.slantDelivery?.average {
        slantTotal = DapiComparisonCell(value: "About \(usd(print + average))", note: "Print estimate plus average past delivery")
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
    let code = countryCode.uppercased()
    if !code.isEmpty, code != "US" {
        let country = dapiCountryName(code)
        var line = "Slant prints in the US, so a buyer in \(country) may owe import VAT or duty on delivery. 3DAPI prints in or near the buyer’s region where it can"
        if let zone = shipping?.zoneName?.trimmingCharacters(in: .whitespaces), !zone.isEmpty { line += " (zone \(zone))" }
        notes.append(line + "; elsewhere its buyers pay import duties too (3DAPI docs, Oct 2026).")
    }
    notes.append("3DAPI’s stated times: production 3–5 business days, then delivery in 1–3 days locally or 5–10 internationally (3DAPI docs, Oct 2026).")
    return notes
}

/// "7 of 25 quotes used this round", while the account awaits approval and the allowance is known.
func dapiOnboardingAllowanceText(_ onboarding: DapiOnboarding?) -> String? {
    guard let onboarding, let limit = onboarding.uploadsLimit else { return nil }
    return "\(onboarding.uploadsUsed) of \(limit) quotes used this round"
}

// MARK: - Errors

enum DapiQuoteStep: Equatable, Sendable {
    case lookup, upload, create, poll, shipping
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
            return "3DAPI may have received the file, but its reply didn’t come back. No quote was requested and nothing was sent again; 3DAPI deletes unused uploads after 24 hours."
        case .create:
            return "3DAPI may have made the quote, but its reply didn’t come back. Nothing was sent again. Get Quote looks for this quote first next time."
        default:
            return error.userMessage
        }
    case .refused:
        switch step {
        case .upload: return "3DAPI refused the file. \(error.userMessage)"
        case .create: return "3DAPI refused the quote. \(error.userMessage)"
        case .shipping: return "3DAPI couldn’t price shipping. \(error.userMessage)"
        default: return error.userMessage
        }
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
    /// Stopped before a quote was found or made; Get Quote starts again (looking first).
    case problem(String)
}

@MainActor final class DapiQuoteRunner: ObservableObject {
    @Published private(set) var phase: DapiQuotePhase = .idle
    @Published private(set) var quote: DapiQuote?
    @Published private(set) var shipping: DapiShippingEstimate?
    @Published private(set) var shippingFor: DapiShippingKey?
    @Published private(set) var shippingRequesting = false
    @Published private(set) var shippingProblem: String?
    /// A write (upload or create) has been sent and hasn't answered; Stop waits for it.
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
    private var closed = false

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
    /// the file once and create one quote. Ignored while a run is going or after the sheet closed.
    func getQuote(fileURL: URL, format: ModelFileFormat?) {
        guard !isWorking, !closed else { return }
        resetForRun()
        phase = .checkingFile
        runTask = Task { await self.run(fileURL: fileURL, format: format) }
    }

    /// Check Again: one read of the paused quote, then polling resumes while it is still processing.
    func checkAgain() {
        guard case .paused = phase, let id = quote?.id, !closed else { return }
        stopRequested = false
        phase = .processing
        runTask = Task { await self.poll(quoteID: id, readFirst: true) }
    }

    /// Stop: reads stop at once; an upload or create already sent is never cancelled, and the run ends when it answers.
    func stop() {
        guard isWorking else { return }
        stopRequested = true
        if !writeInFlight { runTask?.cancel() }
        shippingTask?.cancel()
    }

    /// The sheet closed: stop everything (a write in flight still finishes) and start nothing new.
    func close() {
        closed = true
        stop()
        shippingTask?.cancel()
    }

    /// The first estimate once ready, or Update Shipping: one read-only `shippingEstimate`, never repeated by itself.
    func requestShipping(_ key: DapiShippingKey) {
        guard !closed, phase == .ready, let quote, !shippingRequesting,
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

    // MARK: Steps

    private func run(fileURL: URL, format: ModelFileFormat?) async {
        let size = environment.fileSize(fileURL)
        if let problem = dapiQuoteFileProblem(size: size, format: format) {
            phase = .problem(problem)
            return
        }
        guard let format else { return }
        let hashFile = environment.hashFile
        let hash: String
        do {
            hash = try await Task.detached(priority: .userInitiated) { try hashFile(fileURL) }.value
        } catch {
            phase = .problem("The model’s file couldn’t be read.")
            return
        }
        if stopRequested { phase = .problem("Stopped. Nothing was sent."); return }
        fileHash = hash
        let client: any DapiQuoting
        do {
            client = try environment.client()
        } catch {
            phase = .problem(dapiQuoteErrorMessage(.missingKey, step: .lookup, now: environment.now()))
            return
        }
        let name = dapiQuoteName(fileHash: hash)

        // 1. A ready quote found earlier this session.
        phase = .lookingUp
        if let cachedID = environment.readyQuoteID(hash) {
            switch await read(step: .lookup, { try await client.quote(id: cachedID) }) {
            case .success(let found) where found.isReady:
                finishReady(found)
                return
            case .success:
                break // Not ready after all: look it up by name below.
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
        if stopRequested { end(.problem("Stopped. Nothing was sent.")); return }

        // 3. Upload once, then create one quote. Each is sent once with its own fresh Idempotency-Key.
        phase = .uploading
        let uploadKey = environment.newIdempotencyKey()
        let uploadID: String
        switch await write(step: .upload, {
            try await client.uploadQuoteFile(at: fileURL, fileName: dapiUploadFileName(fileHash: hash, format: format),
                                             contentType: dapiContentType(format), idempotencyKey: uploadKey)
        }) {
        case .success(let id): uploadID = id
        case .failure(let message, let detail): end(.problem(message), detail: detail); return
        }
        if stopRequested {
            end(.problem("Stopped after the upload. No quote was requested; 3DAPI deletes unused uploads after 24 hours."))
            return
        }
        phase = .creating
        let createKey = environment.newIdempotencyKey()
        let created: DapiQuote
        switch await write(step: .create, {
            try await client.createQuote(uploadID: uploadID, name: name, idempotencyKey: createKey)
        }) {
        case .success(let made): created = made
        case .failure(let message, let detail): end(.problem(message), detail: detail); return
        }
        quote = created
        await environment.refreshAllowance()
        if created.isReady { finishReady(created); return }
        if created.isFailed { finishFailed(created); return }
        if stopRequested || closed {
            end(.paused("Stopped. The quote carries on at 3DAPI; Check Again reads it."))
            return
        }
        phase = .processing
        await poll(quoteID: created.id, readFirst: false)
    }

    private func poll(quoteID: String, readFirst: Bool) async {
        let started = environment.now()
        var readNow = readFirst
        while true {
            if !readNow {
                guard let delay = dapiQuotePollDelay(elapsed: environment.now().timeIntervalSince(started)) else {
                    end(.paused("Still processing on 3DAPI after 15 minutes. Check Again reads it once more."))
                    return
                }
                do {
                    try await environment.sleep(delay)
                } catch {
                    end(.paused("Stopped. The quote carries on at 3DAPI; Check Again reads it."))
                    return
                }
            }
            readNow = false
            if stopRequested || Task.isCancelled {
                end(.paused("Stopped. The quote carries on at 3DAPI; Check Again reads it."))
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
            shippingProblem = dapiQuoteErrorMessage(.missingKey, step: .shipping, now: environment.now())
            return
        }
        switch await read(step: .shipping, { try await client.shippingEstimate(quoteID: quoteID, quantity: key.quantity, countryCode: key.countryCode.uppercased()) }) {
        case .success(let estimate):
            guard !closed, quote?.id == quoteID else { return }
            shipping = estimate
            shippingFor = key
        case .failure(let message, let detail):
            guard !closed, !Task.isCancelled else { return }
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

    /// A read: counted with `beginRequest`/`endRequest`, cancellable by Stop.
    private func read<Value>(step: DapiQuoteStep, _ body: () async throws -> Value) async -> Outcome<Value> {
        environment.beginRequest()
        defer { environment.endRequest() }
        do {
            return .success(try await body())
        } catch {
            return describe(error, step: step)
        }
    }

    /// A write: sent once, never cancelled (the run's task isn't cancelled while `writeInFlight`), never re-sent.
    private func write<Value>(step: DapiQuoteStep, _ body: () async throws -> Value) async -> Outcome<Value> {
        environment.beginRequest()
        writeInFlight = true
        defer {
            writeInFlight = false
            environment.endRequest()
        }
        do {
            return .success(try await body())
        } catch {
            return describe(error, step: step)
        }
    }

    private func describe<Value>(_ error: Error, step: DapiQuoteStep) -> Outcome<Value> {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .failure("Stopped. Nothing more was sent.", detail: "Stopped")
        }
        let dapiError = (error as? DapiError) ?? .readFailed(dapiRedacted(error.localizedDescription))
        let detail: String
        if case .outcomeUnknown = dapiError, step == .upload || step == .create {
            detail = "Outcome unknown"
        } else {
            detail = dapiError.activityDetail
        }
        return .failure(dapiQuoteErrorMessage(dapiError, step: step, now: environment.now()), detail: detail)
    }

    // MARK: Endings

    private func finishReady(_ ready: DapiQuote) {
        quote = ready
        if let fileHash { environment.rememberReadyQuote(ready.id, fileHash) }
        phase = .ready
        log?("3DAPI quote", "Ready", true)
        if let destination, !closed { requestShipping(destination) }
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
