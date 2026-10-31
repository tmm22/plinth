import Foundation

// The 3DAPI order composer, place-order review and cancel review: pure helpers first, then the @MainActor runners,
// which reach 3DAPI only through injected closures (tests use stubs). See docs/3DAPI_REFERENCE.md §7.
//
// 3DAPI has no drafts: `placeOrder` CHARGES AT ONCE. So the composer only gathers the order in memory, the review
// re-checks the account, every quote and shipping, and only an explicit Place Order (never the default button, no
// shortcut, never from a menu) sends it, once, with a fresh Idempotency-Key, never retried. An unclear outcome is
// recorded in `DapiOrderSession.unconfirmedOrders` for the whole session. Customer details live only in the sheets'
// memory; Activity gets status words only.

/// Either side of 3DAPI the order screens use: quotes (to re-read a line's quote) and ordering.
typealias DapiOrderClient = DapiQuoting & DapiOrdering

// MARK: - Reference

/// 3DAPI's `reference` limit (`^[A-Za-z0-9_-]{1,100}$`).
let dapiOrderReferenceMaxLength = 100
/// What Plinth adds after the seller's text: "_pl" and the per-attempt token.
let dapiOrderReferenceMarker = "_pl"
let dapiOrderReferenceTokenLength = 8

/// A fresh random token (8 lower-case hex characters) for one Place Order press.
func dapiOrderReferenceToken() -> String {
    String(format: "%08x", UInt32.random(in: .min ... .max))
}

/// The seller's text as 3DAPI accepts it: letters, digits, `_` and `-` kept, anything else (spaces, `#`, accents)
/// becomes `-`, runs of `-` collapse to one, and `-` is trimmed from both ends. Empty when nothing usable is left.
func dapiSanitisedReference(_ text: String) -> String {
    var result = ""
    for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars {
        let value = scalar.value
        let keep = (0x30...0x39).contains(value) || (0x41...0x5A).contains(value) || (0x61...0x7A).contains(value) || value == 0x5F
        if keep {
            result.unicodeScalars.append(scalar)
        } else if !result.hasSuffix("-") {
            result.append("-")
        }
    }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

/// The `reference` sent with an order: the seller's own reference (sanitised, shortened to fit) then "_pl" and a token
/// that is new for every Place Order press, so Look for Order on 3DAPI can find exactly this attempt. With no seller
/// text it is "plinth_" and the token. Never longer than 100 characters.
func dapiOrderReference(sellerReference: String?, token: String) -> String {
    let marker = String(token.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(dapiOrderReferenceTokenLength))
    let room = dapiOrderReferenceMaxLength - dapiOrderReferenceMarker.count - marker.count
    var seller = String(dapiSanitisedReference(sellerReference ?? "").prefix(max(0, room)))
    seller = seller.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    guard !seller.isEmpty else { return "plinth_" + marker }
    return seller + dapiOrderReferenceMarker + marker
}

// MARK: - Validation

/// The composer's fields that can carry a problem.
enum DapiComposerField: Hashable, Sendable {
    case name, email, phone, line1, line2, city, state, postcode, country, notes
}

let dapiNameMaxLength = 200
let dapiEmailMaxLength = 254
let dapiPhoneMaxLength = 40
let dapiAddressLineMaxLength = 200
let dapiCityMaxLength = 100
let dapiStateMaxLength = 100
let dapiPostcodeMaxLength = 20
let dapiNotesMaxLength = 2000
let dapiOrderMaxLines = 100
let dapiOrderMaxUnitsPerLine = 10_000

/// The recipient as typed, for the composer's validation. Memory only.
struct DapiComposerAddress: Equatable {
    var delivery = DeliveryDetails()
    var phone = ""
}

private func dapiHasControlCharacters(_ text: String) -> Bool {
    text.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}

/// Each field's problem, mirroring 3DAPI's limits (name 1–200, a real email, street and city required, an ISO country
/// code, optional notes ≤ 2,000). Nothing here invents a value: a missing email is a problem, never filled in.
func dapiRecipientProblems(_ address: DapiComposerAddress, notes: String = "") -> [DapiComposerField: String] {
    var problems: [DapiComposerField: String] = [:]
    let d = address.delivery
    func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    func check(_ field: DapiComposerField, _ value: String, required: String?, max: Int) {
        let text = trimmed(value)
        if text.isEmpty {
            if let required { problems[field] = required }
        } else if text.count > max {
            problems[field] = "Use at most \(max) characters."
        } else if dapiHasControlCharacters(text) {
            problems[field] = "Remove the line breaks or tabs."
        }
    }
    check(.name, d.name, required: "Enter the recipient’s name.", max: dapiNameMaxLength)
    let email = trimmed(d.email)
    if email.isEmpty {
        problems[.email] = "3DAPI needs the recipient’s email."
    } else if email.count > dapiEmailMaxLength || !isEmailAddress(email) {
        problems[.email] = "Enter an email like name@example.com."
    }
    check(.phone, address.phone, required: nil, max: dapiPhoneMaxLength)
    check(.line1, d.line1, required: "Enter the street address.", max: dapiAddressLineMaxLength)
    check(.line2, d.line2, required: nil, max: dapiAddressLineMaxLength)
    check(.city, d.city, required: "Enter the city.", max: dapiCityMaxLength)
    check(.state, d.state, required: nil, max: dapiStateMaxLength)
    check(.postcode, d.zip, required: nil, max: dapiPostcodeMaxLength)
    let country = orderCountryPickerValue(d)
    if country.isEmpty {
        problems[.country] = "Choose the country."
    } else if !dapiIsDeliveryCountry(country) {
        problems[.country] = "Choose a country from the list."
    }
    if notes.trimmingCharacters(in: .whitespacesAndNewlines).count > dapiNotesMaxLength {
        problems[.notes] = "Notes can be at most 2,000 characters."
    }
    return problems
}

/// An ISO alpha-2 country a parcel can go to (the composer's country list).
func dapiIsDeliveryCountry(_ code: String) -> Bool {
    let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return isCountryCode(upper) && !orderNonCountryRegionCodes.contains(upper)
        && Locale.Region.isoRegions.contains { $0.identifier == upper }
}

/// The recipient sent to 3DAPI: the typed values trimmed, empty optional fields as nil.
func dapiOrderRecipient(_ address: DapiComposerAddress) -> DapiOrderRecipient {
    func value(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    func optional(_ text: String) -> String? { let v = value(text); return v.isEmpty ? nil : v }
    let d = address.delivery
    return DapiOrderRecipient(name: value(d.name), email: value(d.email), phone: optional(address.phone),
                              line1: value(d.line1), line2: optional(d.line2), city: value(d.city),
                              state: optional(d.state), postalCode: optional(d.zip),
                              countryCode: orderCountryPickerValue(d).uppercased())
}

// MARK: - Lines

/// Where a composer line stands.
enum DapiComposerLineState: Equatable {
    /// Reading the model's file or looking for its quote.
    case resolving
    /// A usable ready quote is attached.
    case ready
    /// No usable quote: the reason (never fixed from here; quotes are made in Models).
    case problem(String)
}

/// One line of the composer: a library model (or a duplicated order's quote), its quote, quantity and materials.
struct DapiComposerLine: Identifiable, Equatable {
    let id: UUID
    /// The library model this line came from, if any.
    var modelID: UUID?
    /// What the seller sees: the model's name, or the quote's.
    var name: String
    var quoteID: String?
    var quote: DapiQuote?
    var quantityText: String
    /// Use the quote's suggested materials (3DAPI's default), or one catalogue material per slot.
    var useSuggested: Bool
    /// Slot → catalogue material ID, when not using the suggestions.
    var slotMaterials: [Int: String]
    var state: DapiComposerLineState

    init(id: UUID = UUID(), modelID: UUID? = nil, name: String, quoteID: String? = nil, quote: DapiQuote? = nil,
         quantity: Int = 1, useSuggested: Bool = true, slotMaterials: [Int: String] = [:], state: DapiComposerLineState = .resolving) {
        self.id = id
        self.modelID = modelID
        self.name = name
        self.quoteID = quoteID
        self.quote = quote
        self.quantityText = String(quantity)
        self.useSuggested = useSuggested
        self.slotMaterials = slotMaterials
        self.state = state
    }

    var quantity: Int? { printQuantity(quantityText) }
}

/// The quote names a catalogue material for every slot, so `use_suggested_materials` can be sent.
func dapiQuoteHasSuggestions(_ quote: DapiQuote?) -> Bool {
    guard let quote, !quote.suggestedMaterials.isEmpty else { return false }
    return quote.suggestedMaterials.allSatisfy { !($0.materialName ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
}

/// The extruder slots a line needs a material for: the quote's suggested slots, else slot 1.
func dapiLineSlots(_ quote: DapiQuote?) -> [Int] {
    let slots = Array(Set((quote?.suggestedMaterials ?? []).map(\.slot).filter { $0 >= 1 })).sorted()
    return slots.isEmpty ? [1] : slots
}

/// The catalogue material 3DAPI suggested for a slot, matched by exact name (any case), if it is in the catalogue.
func dapiSuggestedMaterialID(slot: Int, quote: DapiQuote?, catalogue: [DapiMaterial]) -> String? {
    guard let name = quote?.suggestedMaterials.first(where: { $0.slot == slot })?.materialName?
        .trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
    return catalogue.first { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == name }?.id
}

/// Why a line can't be ordered yet, or nil.
func dapiLineProblem(_ line: DapiComposerLine) -> String? {
    switch line.state {
    case .resolving: return "Looking for this model’s 3DAPI quote…"
    case .problem(let reason): return reason
    case .ready: break
    }
    guard let quote = line.quote, quote.isUsable, line.quoteID != nil else { return "This line has no usable 3DAPI quote." }
    guard line.quantity != nil else { return "Enter a quantity from 1 to 10,000." }
    if line.useSuggested, dapiQuoteHasSuggestions(quote) { return nil }
    for slot in dapiLineSlots(quote) where (line.slotMaterials[slot] ?? "").isEmpty {
        return dapiLineSlots(quote).count > 1 ? "Choose a material for slot \(slot)." : "Choose a material."
    }
    return nil
}

/// The line as 3DAPI is asked to print it, or nil while it has a problem.
func dapiLineRequest(_ line: DapiComposerLine) -> DapiOrderLineRequest? {
    guard dapiLineProblem(line) == nil, let quoteID = line.quoteID, let quantity = line.quantity else { return nil }
    if line.useSuggested, dapiQuoteHasSuggestions(line.quote) {
        return DapiOrderLineRequest(quoteID: quoteID, quantity: quantity, materials: .suggested)
    }
    let slots = dapiLineSlots(line.quote).map { DapiMaterialSlot(slot: $0, materialID: line.slotMaterials[$0] ?? "") }
    return DapiOrderLineRequest(quoteID: quoteID, quantity: quantity, materials: .slots(slots))
}

/// The materials as the review lists them: the suggestions (with their names), or the chosen material per slot.
func dapiLineMaterialsText(_ line: DapiComposerLine, catalogue: [DapiMaterial]) -> String {
    if line.useSuggested, dapiQuoteHasSuggestions(line.quote) {
        let names = (line.quote?.suggestedMaterials ?? []).sorted { $0.slot < $1.slot }.compactMap(\.materialName)
        return "3DAPI’s suggestion" + (names.isEmpty ? "" : ": " + names.joined(separator: ", "))
    }
    let slots = dapiLineSlots(line.quote)
    return slots.map { slot in
        let id = line.slotMaterials[slot] ?? ""
        let name = catalogue.first { $0.id == id }?.name ?? id
        return slots.count > 1 ? "Slot \(slot): \(name)" : name
    }.joined(separator: ", ")
}

/// The composed order, or nil while any line or the recipient has a problem.
func dapiOrderDraft(lines: [DapiComposerLine], address: DapiComposerAddress, reference: String, notes: String,
                    catalogue: [DapiMaterial]) -> DapiOrderDraft? {
    guard dapiComposerLinesProblem(lines) == nil, dapiRecipientProblems(address, notes: notes).isEmpty else { return nil }
    var draftLines: [DapiOrderDraft.Line] = []
    for line in lines {
        guard let request = dapiLineRequest(line) else { return nil }
        draftLines.append(DapiOrderDraft.Line(request: request, name: line.name,
                                              materialsText: dapiLineMaterialsText(line, catalogue: catalogue)))
    }
    let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    return DapiOrderDraft(lines: draftLines, recipient: dapiOrderRecipient(address),
                          sellerReference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
                          notes: trimmedNotes.isEmpty ? nil : trimmedNotes)
}

/// Why the lines can't be ordered yet, or nil.
func dapiComposerLinesProblem(_ lines: [DapiComposerLine]) -> String? {
    if lines.isEmpty { return "Add at least one model." }
    if lines.count > dapiOrderMaxLines { return "3DAPI takes at most 100 lines in one order." }
    for (index, line) in lines.enumerated() {
        if let problem = dapiLineProblem(line) {
            return lines.count > 1 ? "Line \(index + 1): \(problem)" : problem
        }
    }
    return nil
}

/// The lines of a duplicated order: the same quotes, quantities and material slots. Each still needs its quote read
/// again (it may have been rejected since). The address is never copied: 3DAPI doesn't return a structured one.
func dapiComposerLines(duplicating order: DapiOrder) -> [DapiComposerLine] {
    (order.items ?? []).map { item in
        let slots = Dictionary(item.materials.map { ($0.slot, $0.materialID) }, uniquingKeysWith: { first, _ in first })
        return DapiComposerLine(name: item.quoteName ?? "", quoteID: item.quoteID,
                                quantity: min(max(item.quantity, 1), dapiOrderMaxUnitsPerLine),
                                useSuggested: slots.isEmpty, slotMaterials: slots, state: .resolving)
    }
}

/// Whether the composer holds anything typed or chosen, so closing it asks first.
/// The lines as the seller shaped them (which lines, and their quantities), for the discard check.
func dapiComposerLineSignature(_ lines: [DapiComposerLine]) -> [String] {
    lines.map { "\($0.id.uuidString)|\($0.quantityText)" }
}

func dapiComposerHasInput(lineSignature: [String], initialLineSignature: [String], address: DapiComposerAddress,
                          initialAddress: DapiComposerAddress, reference: String, notes: String) -> Bool {
    if lineSignature != initialLineSignature { return true }
    if address != initialAddress { return true }
    return !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

// MARK: - Line names

/// Plinth's neutral quote name ("Plinth " and 16 lower-case hex characters, `dapiQuoteName`).
func dapiIsNeutralQuoteName(_ name: String?) -> Bool {
    guard let name, name.hasPrefix("Plinth "), name.count == 23 else { return false }
    return name.dropFirst(7).allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains($0)) }
}

/// The name shown for an order line: the library model whose file hashes to Plinth's neutral quote name, else the quote
/// name as 3DAPI has it, else a placeholder. `modelNames` maps neutral quote names to model names.
func dapiLineDisplayName(quoteName: String?, modelNames: [String: String]) -> String {
    let trimmed = quoteName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if dapiIsNeutralQuoteName(trimmed), let model = modelNames[trimmed] { return model }
    return trimmed.isEmpty ? "Unnamed quote" : trimmed
}

/// Hashes library models' files lazily (off the main thread, once per file version) so order lines named
/// "Plinth <hex>" can show the model's name. Memory only; it never blocks the UI and never sends anything.
@MainActor final class DapiModelNameIndex: ObservableObject {
    static let shared = DapiModelNameIndex()

    /// Neutral quote name → model name.
    @Published private(set) var names: [String: String] = [:]
    /// File path → (version, hash), so an unchanged file is read once a session.
    private var hashes: [String: (version: String, hash: String)] = [:]
    private var running = false
    private var pending: [LocalModel]?

    /// The model name for a neutral quote name, if known.
    func modelName(forQuoteName name: String?) -> String? {
        guard let name, dapiIsNeutralQuoteName(name) else { return nil }
        return names[name]
    }

    /// Records a hash computed elsewhere (the composer adding a model).
    func note(hash: String, modelName: String, path: String, version: String) {
        hashes[path] = (version, hash)
        names[dapiQuoteName(fileHash: hash)] = modelName
    }

    /// Hashes every library model not yet hashed at its current version, one at a time in the background.
    func refresh(models: [LocalModel]) {
        guard !running else { pending = models; return }
        running = true
        Task { @MainActor in
            var current = models
            while true {
                var map: [String: String] = [:]
                for model in current {
                    let path = model.filePath
                    guard let version = dapiFileVersion(path: path) else { continue }
                    let hash: String
                    if let cached = hashes[path], cached.version == version {
                        hash = cached.hash
                    } else {
                        let url = model.url
                        guard let computed = try? await Task.detached(priority: .utility, operation: { try dapiFileSHA256(at: url) }).value
                        else { continue }
                        hashes[path] = (version, computed)
                        hash = computed
                    }
                    map[dapiQuoteName(fileHash: hash)] = model.name
                }
                names = map
                guard let next = pending else { break }
                pending = nil
                current = next
            }
            running = false
        }
    }
}

/// A file's size and modification time, so a changed file is hashed again; nil when it isn't a regular file.
func dapiFileVersion(path: String) -> String? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          (attributes[.type] as? FileAttributeType) == .typeRegular else { return nil }
    let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
    let modified = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(size)-\(modified)"
}

// MARK: - Shipping and totals

/// What a shipping estimate was asked for; a different key makes it stale.
struct DapiOrderShippingKey: Equatable, Sendable {
    let lines: [DapiOrderLineRequest]
    let countryCode: String
}

/// Each line's "up to" cost: 3DAPI's per-unit price × quantity (its real per-unit price falls with quantity and is
/// known only once ordered). Nil on overflow.
func dapiLineUpTo(unitPrice: DapiMoney, quantity: Int) -> DapiMoney? { dapiMoneyTimes(unitPrice, quantity) }

/// The order's "up to" total: every line's upper bound plus shipping, only when every amount is in one currency.
func dapiOrderUpToTotal(lines: [(unitPrice: DapiMoney, quantity: Int)], shipping: DapiMoney) -> DapiMoney? {
    var total = shipping
    for line in lines {
        guard let upTo = dapiLineUpTo(unitPrice: line.unitPrice, quantity: line.quantity),
              let sum = dapiMoneySum(total, upTo) else { return nil }
        total = sum
    }
    return total
}

let dapiWalletNote = "If your 3DAPI wallet is short, 3DAPI charges the rest to your saved card, with VAT on that top-up for EU and UK businesses."
let dapiOrderChargeNote = "Place Order charges your 3DAPI wallet at once and sends the order to production. 3DAPI has no draft orders."
let dapiOrderUpToNote = "3DAPI’s per-unit price falls with quantity, so the item amounts are upper bounds: the exact price comes only with the order."

/// Customer-facing copy for a failed account check before ordering.
let dapiOrderAccountUnreadable = "Plinth couldn’t check your 3DAPI account, so nothing was sent."

// MARK: - Review snapshot and the pre-send comparison

/// The figures the seller reviewed; compared again just before sending.
struct DapiOrderReviewSnapshot: Equatable, Sendable {
    var countryCode: String
    var lines: [DapiOrderLineRequest]
    /// Quote ID → 3DAPI's per-unit price.
    var unitPrices: [String: DapiMoney]
    var shippingTotal: DapiMoney
    /// `dapiOrderingProblem`'s answer (nil when the account can order).
    var orderingProblem: String?
}

/// What changed between the reviewed figures and the fresh ones, in the seller's words; empty when nothing did.
/// `names` maps quote IDs to the names shown in the review.
func dapiReviewChanges(reviewed: DapiOrderReviewSnapshot, current: DapiOrderReviewSnapshot,
                       names: [String: String] = [:]) -> [String] {
    var changes: [String] = []
    if reviewed.orderingProblem != current.orderingProblem {
        changes.append(current.orderingProblem ?? "Your 3DAPI account’s ordering status changed.")
    }
    if reviewed.countryCode.uppercased() != current.countryCode.uppercased() { changes.append("The delivery country changed.") }
    if reviewed.lines != current.lines { changes.append("The order’s lines changed.") }
    for quoteID in reviewed.unitPrices.keys.sorted() {
        let before = reviewed.unitPrices[quoteID]
        let after = current.unitPrices[quoteID]
        guard before != after else { continue }
        let name = names[quoteID] ?? "A model"
        switch (before, after) {
        case let (b?, a?): changes.append("\(name): \(dapiMoneyText(b)) → \(dapiMoneyText(a)) per unit.")
        default: changes.append("\(name): its price is no longer available.")
        }
    }
    for quoteID in current.unitPrices.keys.sorted() where reviewed.unitPrices[quoteID] == nil {
        changes.append("\(names[quoteID] ?? "A model"): a new price.")
    }
    if reviewed.shippingTotal != current.shippingTotal {
        changes.append("Shipping: \(dapiMoneyText(reviewed.shippingTotal)) → \(dapiMoneyText(current.shippingTotal)).")
    }
    return changes
}

// MARK: - Place outcome

/// How a Place Order that didn't return an order ended.
enum DapiPlaceFailure: Equatable {
    /// Definitely not placed and nothing charged (refused, rate limited, or never sent).
    case notCharged(String)
    /// 3DAPI may have charged and placed it.
    case unknown(String)
}

/// Classifies a failed `placeOrder`. Anything Plinth can't place with certainty (a timeout, 5xx, an unreadable
/// reply, or an error it doesn't recognise) is unknown: 3DAPI may have charged and placed it.
func dapiPlaceFailure(_ error: Error, now: Date = Date()) -> DapiPlaceFailure {
    guard let error = error as? DapiError else {
        return .unknown(dapiPlaceUnknownText)
    }
    switch error {
    case .missingKey:
        return .notCharged("Add your 3DAPI key in Settings first. Nothing was sent.")
    case .notSent(let detail):
        return .notCharged("Nothing was sent, so nothing was charged. \(dapiRedacted(detail, limit: 400))")
    case .rateLimited:
        return .notCharged("3DAPI is limiting requests and didn’t place the order, so nothing was charged. \(error.userMessage(now: now))")
    case .refused(let status, let code, let message):
        return .notCharged(dapiOrderRefusalMessage(status: status, code: code, message: message))
    case .outcomeUnknown, .readFailed:
        return .unknown(dapiPlaceUnknownText)
    }
}

let dapiPlaceUnknownText = "3DAPI didn’t answer clearly, so it may have charged your wallet and placed the order. Plinth won’t send it again. Press Look for Order on 3DAPI to check before placing it again."

/// The seller's text for a definite refusal of an order or cancellation. Always says nothing was charged (for an order)
/// because 3DAPI places nothing it refuses.
func dapiOrderRefusalMessage(status: Int, code: String?, message: String?) -> String {
    let reason: String
    switch code {
    case "payment_failed": reason = "3DAPI couldn’t take the payment (the wallet top-up from your card failed)."
    case "insufficient_balance": reason = "Your 3DAPI wallet doesn’t hold enough, and no card could top it up."
    case "compliance_blocked": reason = "3DAPI needs your business billing details first. Add them in 3DAPI’s dashboard."
    case "quote_not_found": reason = "3DAPI has no such quote for this account."
    case "production_unavailable": reason = "3DAPI has no production partner for this order at the moment."
    case "quote_not_ready": reason = "A quote isn’t ready yet."
    case "quote_rejected": reason = "3DAPI rejected one of the files in review."
    case "quote_not_approved": reason = "3DAPI hasn’t approved your account for ordering yet."
    case "material_not_allowed": reason = "A chosen material can’t be used for that model."
    case "material_slots_mismatch": reason = "The materials don’t match the model’s slots."
    case "suggestions_unavailable": reason = "3DAPI has no suggested materials for a model. Choose the materials yourself."
    case "shipping_destination_not_served": reason = "3DAPI doesn’t deliver to that country."
    case "missing_scope": reason = "This 3DAPI key can’t place or cancel orders. Make a key with orders:write in 3DAPI’s dashboard."
    case "order_not_cancellable": reason = "3DAPI can no longer cancel this order: a production partner has started it. Email contact@dapi.digital."
    case "idempotency_key_reused": reason = "3DAPI refused a repeated request that differed from the first."
    default: reason = dapiRefusalMessage(status: status, code: code, message: message)
    }
    return reason
}

// MARK: - Place runner

/// What the place-order review talks to; tests pass stubs.
struct DapiPlaceEnvironment {
    var client: @MainActor () throws -> any DapiOrderClient
    /// Re-reads the account and onboarding and returns `dapiOrderingProblem`'s answer (or why it couldn't check).
    var orderingProblem: @MainActor () async -> String?
    var unconfirmedOrders: @MainActor () -> [DapiUnconfirmedOrder]
    var beginWrite: @MainActor () -> UUID
    var endWrite: @MainActor (UUID) -> Void
    var noteUnconfirmed: @MainActor (DapiUnconfirmedOrder) -> Void
    var newIdempotencyKey: @MainActor () -> String
    var newReferenceToken: @MainActor () -> String
    var now: @MainActor () -> Date

    @MainActor static func live() -> DapiPlaceEnvironment {
        DapiPlaceEnvironment(
            client: { try dapiCurrentOrderClient() },
            orderingProblem: { await dapiRefreshOrderingProblem() },
            unconfirmedOrders: { DapiOrderSession.shared.unconfirmedOrders },
            beginWrite: { DapiOrderSession.shared.beginWrite(.dapiOrder) },
            endWrite: { DapiOrderSession.shared.endWrite($0) },
            noteUnconfirmed: { DapiOrderSession.shared.noteUnconfirmedOrder($0) },
            newIdempotencyKey: { UUID().uuidString },
            newReferenceToken: { dapiOrderReferenceToken() },
            now: { Date() })
    }
}

/// The saved key's client, which must both quote and order.
@MainActor func dapiCurrentOrderClient() throws -> any DapiOrderClient {
    let client = try DapiConnection.shared.currentClient()
    guard let both = client as? any DapiOrderClient else {
        throw DapiError.notSent("This 3DAPI connection can’t place orders.")
    }
    return both
}

/// Re-reads the account (and onboarding) and says why it can't order, or nil. An onboarding reply that can't be read
/// counts as no blockers: 3DAPI refuses an order from an account with blockers anyway (nothing charged).
@MainActor func dapiRefreshOrderingProblem() async -> String? {
    let connection = DapiConnection.shared
    let failure = await connection.refreshStatus()
    guard let account = connection.account else { return failure ?? dapiOrderAccountUnreadable }
    if account.isIntegrator, connection.onboarding == nil { await connection.refreshOnboarding() }
    return dapiOrderingProblem(account: account, onboardingOrderBlockers: connection.onboarding?.orderBlockers ?? [])
}

/// The order as composed: what is sent, plus the names shown. Memory only.
struct DapiOrderDraft: Equatable {
    struct Line: Equatable {
        let request: DapiOrderLineRequest
        let name: String
        /// "3DAPI’s suggested materials", or the chosen material per slot.
        var materialsText = ""
    }
    let lines: [Line]
    let recipient: DapiOrderRecipient
    /// The seller's own reference as typed (sanitised when sent), or empty.
    let sellerReference: String
    let notes: String?

    var units: Int { lines.reduce(0) { $0 + $1.request.quantity } }
    var quoteNames: [String: String] {
        Dictionary(lines.map { ($0.request.quoteID, $0.name) }, uniquingKeysWith: { first, _ in first })
    }
}

/// What the review shows: fresh quotes, shipping and (when the key can read it) the wallet.
struct DapiOrderReviewFigures: Equatable {
    let snapshot: DapiOrderReviewSnapshot
    let quotes: [String: DapiQuote]
    let shipping: DapiShippingEstimate
    let wallet: DapiWallet?
}

enum DapiPlacePhase: Equatable {
    /// Reading the account, quotes and shipping (first, or again with Check Again).
    case checking
    /// The figures are shown and Place Order may be pressed.
    case ready
    /// A check failed or the account can't order: nothing can be sent.
    case blocked(String)
    /// Re-checking just before sending.
    case rechecking
    /// The order is with 3DAPI.
    case placing
    case placed(DapiOrder)
    /// 3DAPI refused it, or it was never sent: nothing was charged.
    case notCharged(String)
    /// It may have been charged and placed.
    case unknown(String)
}

/// The review-and-place flow for one composed order.
@MainActor final class DapiPlaceOrderRunner: ObservableObject {
    @Published private(set) var phase: DapiPlacePhase = .checking
    @Published private(set) var figures: DapiOrderReviewFigures?
    /// What changed when the pre-send check found different figures (shown above the new ones).
    @Published private(set) var changes: [String] = []
    /// Place Order was pressed while earlier orders are unconfirmed: the view asks Place Anyway / Don't Place.
    @Published var askPlaceAnyway = false
    /// The unconfirmed record made by this sheet's attempt, for Look for Order on 3DAPI.
    @Published private(set) var unconfirmed: DapiUnconfirmedOrder?

    let draft: DapiOrderDraft
    private let environment: DapiPlaceEnvironment
    private var checkTask: Task<Void, Never>?
    private var started = false
    private var closed = false
    /// Called once with the placed order (the list inserts and selects it).
    var onPlaced: ((DapiOrder) -> Void)?
    var log: ((_ title: String, _ detail: String, _ success: Bool) -> Void)?

    init(draft: DapiOrderDraft, environment: DapiPlaceEnvironment) {
        self.draft = draft
        self.environment = environment
    }

    var isWriting: Bool { phase == .placing }
    var isLoading: Bool { phase == .checking || phase == .rechecking }
    var canPlace: Bool { phase == .ready && figures != nil && !askPlaceAnyway }
    /// Go Back and closing are refused only while the order is with 3DAPI.
    var canClose: Bool { !isWriting }

    /// First appearance: read everything once.
    func start() {
        closed = false
        guard !started else { return }
        started = true
        runCheck()
    }

    func checkAgain() {
        guard phase != .placing, phase != .rechecking, checkTask == nil else { return }
        switch phase {
        case .placed, .unknown: return
        default: break
        }
        runCheck()
    }

    /// The sheet went away: stop any read (never the order request, which can't be in flight because the sheet can't
    /// close while it is).
    func close() {
        closed = true
        checkTask?.cancel()
        checkTask = nil
    }

    private func runCheck() {
        phase = .checking
        changes = []
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.readFigures()
            self.checkTask = nil
            guard !Task.isCancelled, !self.closed else { return }
            switch result {
            case .success(let figures):
                self.figures = figures
                self.phase = .ready
            case .failure(let message):
                self.figures = nil
                self.phase = .blocked(message)
            }
        }
    }

    enum CheckResult { case success(DapiOrderReviewFigures), failure(String) }

    /// The account, every distinct quote (each must be usable), a fresh shipping estimate and the wallet (optional).
    func readFigures() async -> CheckResult {
        if let problem = await environment.orderingProblem() { return .failure(problem) }
        if Task.isCancelled { return .failure("Stopped.") }
        let client: any DapiOrderClient
        do { client = try environment.client() } catch { return .failure(dapiFailureMessage(error)) }
        var quotes: [String: DapiQuote] = [:]
        for line in draft.lines where quotes[line.request.quoteID] == nil {
            do {
                let quote = try await client.quote(id: line.request.quoteID)
                guard quote.isUsable, let price = quote.price, price.amountMinor >= 0 else {
                    return .failure("\(line.name): \(dapiOrderQuoteUnusableReason(quote)) Nothing was sent.")
                }
                quotes[line.request.quoteID] = quote
            } catch {
                if dapiIsCancellation(error) { return .failure("Stopped.") }
                return .failure("Couldn’t read the quote for \(line.name): \(dapiFailureMessage(error)) Nothing was sent.")
            }
        }
        let requests = draft.lines.map(\.request)
        let shipping: DapiShippingEstimate
        do {
            shipping = try await client.shippingEstimate(lines: requests, countryCode: draft.recipient.countryCode)
        } catch {
            if dapiIsCancellation(error) { return .failure("Stopped.") }
            return .failure("Couldn’t price shipping: \(dapiFailureMessage(error)) Nothing was sent.")
        }
        var wallet: DapiWallet?
        do { wallet = try await client.wallet() } catch { wallet = nil }
        if Task.isCancelled { return .failure("Stopped.") }
        let snapshot = DapiOrderReviewSnapshot(
            countryCode: draft.recipient.countryCode, lines: requests,
            unitPrices: quotes.compactMapValues(\.price), shippingTotal: shipping.total, orderingProblem: nil)
        return .success(DapiOrderReviewFigures(snapshot: snapshot, quotes: quotes, shipping: shipping, wallet: wallet))
    }

    /// Place Order. With unconfirmed orders this session it first asks (`askPlaceAnyway`); then it re-checks every
    /// figure, stops if any changed, and only then sends the order once.
    func placeOrder(confirmedAnyway: Bool = false) {
        guard phase == .ready, let reviewed = figures, !closed else { return }
        if !confirmedAnyway, !environment.unconfirmedOrders().isEmpty {
            askPlaceAnyway = true
            return
        }
        askPlaceAnyway = false
        phase = .rechecking
        checkTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.readFigures()
            self.checkTask = nil
            guard !Task.isCancelled, !self.closed else { return }
            switch result {
            case .failure(let message):
                self.figures = nil
                self.phase = .blocked(message)
            case .success(let fresh):
                let changed = dapiReviewChanges(reviewed: reviewed.snapshot, current: fresh.snapshot, names: self.draft.quoteNames)
                if !changed.isEmpty {
                    self.figures = fresh
                    self.changes = changed
                    self.phase = .ready
                    return
                }
                self.send(figures: fresh)
            }
        }
    }

    func declinePlaceAnyway() { askPlaceAnyway = false }

    private func send(figures: DapiOrderReviewFigures) {
        guard phase == .rechecking, !closed else { return }
        let client: any DapiOrderClient
        do { client = try environment.client() } catch {
            phase = .notCharged(dapiPlaceFailureText(dapiPlaceFailure(error)))
            return
        }
        let reference = dapiOrderReference(sellerReference: draft.sellerReference, token: environment.newReferenceToken())
        let request = DapiOrderRequest(lines: figures.snapshot.lines, recipient: draft.recipient, reference: reference,
                                       customerNotes: draft.notes)
        let key = environment.newIdempotencyKey()
        let token = environment.beginWrite()
        phase = .placing
        let sentAt = environment.now()
        let record = DapiUnconfirmedOrder(id: UUID(), reference: reference, recipientName: draft.recipient.name,
                                          countryCode: draft.recipient.countryCode, units: draft.units, sentAt: sentAt)
        // Not stored in `checkTask`: nothing cancels the order request once it is sent.
        Task { [weak self] in
            let result: Result<DapiOrder, Error>
            do { result = .success(try await client.placeOrder(request, idempotencyKey: key)) } catch { result = .failure(error) }
            guard let self else { return }
            self.environment.endWrite(token)
            self.finish(result, record: record)
        }
    }

    private func finish(_ result: Result<DapiOrder, Error>, record: DapiUnconfirmedOrder) {
        switch result {
        case .success(let order):
            phase = .placed(order)
            log?("3DAPI order", order.status.countsAsPlaced ? "Placed" : "Created, status \(order.status.isUnknown ? "unrecognised" : order.status.raw)", true)
            onPlaced?(order)
        case .failure(let error):
            switch dapiPlaceFailure(error, now: environment.now()) {
            case .notCharged(let message):
                phase = .notCharged(message)
                log?("3DAPI order", (error as? DapiError)?.activityDetail ?? "Not sent", false)
            case .unknown(let message):
                environment.noteUnconfirmed(record)
                unconfirmed = record
                phase = .unknown(message)
                log?("3DAPI order", "Outcome unknown", false)
            }
        }
    }
}

/// Why a quote can't be ordered now (rejected, failed, still processing, or ready without a price).
func dapiOrderQuoteUnusableReason(_ quote: DapiQuote) -> String {
    if quote.isRejected { return "3DAPI rejected this file in review, so it can’t be ordered." }
    if quote.isFailed { return "3DAPI couldn’t quote this file, so it can’t be ordered." }
    if quote.isProcessing { return "3DAPI is still pricing this file. Try again in a few minutes." }
    if quote.isReady { return "3DAPI sent no price for this quote, so it can’t be ordered." }
    return "This quote isn’t ready, so it can’t be ordered."
}

func dapiPlaceFailureText(_ failure: DapiPlaceFailure) -> String {
    switch failure {
    case .notCharged(let text), .unknown(let text): return text
    }
}

/// The Place Anyway question's text, naming each unconfirmed attempt (name, units, country, time). Memory only.
func dapiPlaceAnywayMessage(_ attempts: [DapiUnconfirmedOrder], now: Date = Date()) -> String {
    let lines = attempts.map { dapiUnconfirmedOrderLine($0) }
    return "These orders were sent this session without a clear answer, so 3DAPI may have charged and placed them:\n"
        + lines.joined(separator: "\n")
        + "\nPlacing this order may charge you twice for the same customer. Use Look for Order on 3DAPI in Orders first if you’re unsure."
}

/// "Ada Lovelace · 3 units · GB · 14:05".
func dapiUnconfirmedOrderLine(_ attempt: DapiUnconfirmedOrder) -> String {
    let name = attempt.recipientName.trimmingCharacters(in: .whitespacesAndNewlines)
    let units = attempt.units == 1 ? "1 unit" : "\(attempt.units) units"
    let time = attempt.sentAt.formatted(date: .omitted, time: .shortened)
    return [name.isEmpty ? "No name" : name, units, attempt.countryCode, time].joined(separator: " · ")
}

// MARK: - Look for Order on 3DAPI

/// What the read-only lookup found for one unconfirmed attempt.
enum DapiOrderLookupResult: Equatable {
    case found(DapiOrder)
    /// No order with the exact reference: it may still appear, or wasn't placed. The attempt is kept.
    case notFound
    case failed(String)
    /// Not looked for: an earlier read was rate limited.
    case skipped
}

/// The order whose reference is exactly `reference` (case-sensitive, as sent), if a page holds one.
func dapiOrderMatching(reference: String, in orders: [DapiOrder]) -> DapiOrder? {
    orders.first { $0.reference == reference }
}

/// The pause between lookup reads.
let dapiOrderLookupPause: TimeInterval = 0.6

/// Looks for each attempt by its exact reference, one read at a time, paused between reads, and stops at a 429.
/// Found attempts are confirmed through `confirm`; not-found ones are never cleared.
@MainActor func dapiLookForOrders(_ attempts: [DapiUnconfirmedOrder], client: any DapiOrdering,
                                  pause: @Sendable (TimeInterval) async throws -> Void,
                                  confirm: (String) -> Void) async -> [UUID: DapiOrderLookupResult] {
    var results: [UUID: DapiOrderLookupResult] = [:]
    var stop = false
    for (index, attempt) in attempts.enumerated() {
        if stop || Task.isCancelled { results[attempt.id] = .skipped; continue }
        if index > 0 {
            do { try await pause(dapiOrderLookupPause) } catch { results[attempt.id] = .skipped; stop = true; continue }
        }
        do {
            let page = try await client.orders(DapiOrderListQuery(reference: attempt.reference, limit: 10, expandItems: true))
            if let order = dapiOrderMatching(reference: attempt.reference, in: page.orders) {
                confirm(attempt.reference)
                results[attempt.id] = .found(order)
            } else {
                results[attempt.id] = .notFound
            }
        } catch {
            if dapiIsCancellation(error) { results[attempt.id] = .skipped; stop = true; continue }
            if case DapiError.rateLimited = error { stop = true }
            results[attempt.id] = .failed(dapiFailureMessage(error))
        }
    }
    return results
}

/// One line summing up a lookup.
func dapiOrderLookupSummary(_ results: [DapiOrderLookupResult]) -> String {
    let found = results.filter { if case .found = $0 { true } else { false } }.count
    let missing = results.filter { $0 == .notFound }.count
    let failed = results.filter { if case .failed = $0 { true } else { false } }.count
    let skipped = results.filter { $0 == .skipped }.count
    var parts: [String] = []
    if found > 0 { parts.append(found == 1 ? "Found 1 order on 3DAPI." : "Found \(found) orders on 3DAPI.") }
    if missing > 0 {
        parts.append((missing == 1 ? "1 order wasn’t found" : "\(missing) orders weren’t found")
                     + ": it may still appear in a moment, or 3DAPI didn’t place it. Plinth keeps the warning.")
    }
    if failed > 0 { parts.append(failed == 1 ? "1 lookup failed." : "\(failed) lookups failed.") }
    if skipped > 0 { parts.append("3DAPI is limiting requests: look again in a minute.") }
    return parts.isEmpty ? "Nothing to look for." : parts.joined(separator: " ")
}

// MARK: - Cancel

/// Why Cancel Order can't be offered or sent for this order now, or nil. Only an order 3DAPI still lets you cancel,
/// still in the status the seller saw, and without an earlier cancel whose outcome is unknown.
func dapiCancelBlockedReason(order: DapiOrder, shownStatus: DapiOrderStatus, outcomeUnknown: Bool) -> String? {
    if outcomeUnknown { return "An earlier cancellation of this order didn’t get a clear answer. Refresh the order to see whether it was cancelled." }
    if order.status != shownStatus {
        return "The order is now “\(order.status.label)”, not “\(shownStatus.label)” as shown. Check it again before cancelling."
    }
    if order.status.isUnknown { return "3DAPI sent a status Plinth doesn’t recognise, so Plinth won’t cancel this order." }
    guard order.status.canRequestCancellation else {
        return "3DAPI can’t cancel an order once a production partner has it. Email contact@dapi.digital."
    }
    return nil
}

/// How a cancellation ended.
enum DapiCancelOutcome: Equatable {
    /// 3DAPI returned the order cancelled.
    case cancelled(DapiOrder)
    /// 3DAPI answered, but the order doesn't show as cancelled: the outcome stays unclear until a reload shows it.
    case notYetCancelled(DapiOrder)
    /// Refused or never sent: nothing changed.
    case refused(String)
    /// The request may have reached 3DAPI.
    case unknown(String)

    /// The cancel stays recorded as unknown (no second cancel) until a reload shows the order cancelled.
    var recordsUnknown: Bool {
        switch self {
        case .notYetCancelled, .unknown: true
        default: false
        }
    }
}

func dapiCancelOutcome(_ result: Result<DapiOrder, Error>) -> DapiCancelOutcome {
    switch result {
    case .success(let order):
        return order.status == .cancelled ? .cancelled(order) : .notYetCancelled(order)
    case .failure(let error):
        guard let error = error as? DapiError else { return .unknown(dapiCancelUnknownText) }
        switch error {
        case .missingKey: return .refused("Add your 3DAPI key in Settings first. Nothing was sent.")
        case .notSent(let detail): return .refused("Nothing was sent. \(dapiRedacted(detail, limit: 400))")
        case .rateLimited: return .refused("3DAPI is limiting requests and didn’t cancel the order. \(error.userMessage)")
        case .refused(let status, let code, let message):
            return .refused(dapiOrderRefusalMessage(status: status, code: code, message: message))
        case .outcomeUnknown, .readFailed: return .unknown(dapiCancelUnknownText)
        }
    }
}

let dapiCancelUnknownText = "3DAPI didn’t answer clearly, so the order may or may not be cancelled. Plinth won’t send the cancellation again: refresh the order to see its status."
let dapiCancelExplanation = "3DAPI refunds a paid order in full to your 3DAPI wallet. It can’t cancel an order once a production partner has started it."

/// Session bookkeeping a loaded order settles: an unconfirmed attempt whose exact reference it carries is confirmed, and
/// a cancel with an unknown outcome is cleared once the order shows cancelled. Nothing else clears either.
func dapiSessionSettlements(_ orders: [DapiOrder], unconfirmed: [DapiUnconfirmedOrder],
                            cancelUnknown: Set<String>) -> (confirmReferences: [String], clearCancelIDs: [String]) {
    let references = Set(orders.compactMap(\.reference))
    let confirm = unconfirmed.map(\.reference).filter { references.contains($0) }
    let clear = orders.filter { cancelUnknown.contains($0.id) && $0.status == .cancelled }.map(\.id)
    return (Array(Set(confirm)).sorted(), clear)
}

/// What the cancel review talks to.
struct DapiCancelEnvironment {
    var client: @MainActor () throws -> any DapiOrdering
    var beginWrite: @MainActor () -> UUID
    var endWrite: @MainActor (UUID) -> Void
    var outcomeUnknown: @MainActor (String) -> Bool
    var noteUnknown: @MainActor (String) -> Void
    var clearUnknown: @MainActor (String) -> Void
    var newIdempotencyKey: @MainActor () -> String

    @MainActor static func live() -> DapiCancelEnvironment {
        DapiCancelEnvironment(
            client: { try dapiCurrentOrderClient() },
            beginWrite: { DapiOrderSession.shared.beginWrite(.dapiCancellation) },
            endWrite: { DapiOrderSession.shared.endWrite($0) },
            outcomeUnknown: { DapiOrderSession.shared.cancelOutcomeUnknown.contains($0) },
            noteUnknown: { DapiOrderSession.shared.noteCancelOutcomeUnknown(orderID: $0) },
            clearUnknown: { DapiOrderSession.shared.clearCancelOutcomeUnknown(orderID: $0) },
            newIdempotencyKey: { UUID().uuidString })
    }
}

enum DapiCancelPhase: Equatable {
    case loading
    case ready(DapiOrder)
    case blocked(String)
    case cancelling
    case done(DapiCancelOutcome)
}

/// Cancel 3DAPI order: re-reads the order, checks it can still be cancelled in the status shown, re-reads it again just
/// before sending, then sends the cancel once.
@MainActor final class DapiCancelOrderRunner: ObservableObject {
    @Published private(set) var phase: DapiCancelPhase = .loading
    let orderID: String
    let shownStatus: DapiOrderStatus
    private let environment: DapiCancelEnvironment
    private var readTask: Task<Void, Never>?
    private var started = false
    private var closed = false
    /// Every order read or returned here (the list replaces its copy).
    var onOrder: ((DapiOrder) -> Void)?
    var log: ((_ title: String, _ detail: String, _ success: Bool) -> Void)?

    init(orderID: String, shownStatus: DapiOrderStatus, environment: DapiCancelEnvironment) {
        self.orderID = orderID
        self.shownStatus = shownStatus
        self.environment = environment
    }

    var isWriting: Bool { phase == .cancelling }
    var canCancel: Bool { if case .ready = phase { true } else { false } }

    func start() {
        closed = false
        guard !started else { return }
        started = true
        readTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.fetchAndGate()
            self.readTask = nil
            guard !Task.isCancelled, !self.closed else { return }
            switch result {
            case .success(let order): self.phase = .ready(order)
            case .failure(let message): self.phase = .blocked(message)
            }
        }
    }

    func close() {
        closed = true
        readTask?.cancel()
        readTask = nil
    }

    enum Gate { case success(DapiOrder), failure(String) }

    private func fetchAndGate() async -> Gate {
        do {
            let client = try environment.client()
            let order = try await client.order(id: orderID)
            onOrder?(order)
            if order.status == .cancelled, environment.outcomeUnknown(order.id) { environment.clearUnknown(order.id) }
            if let reason = dapiCancelBlockedReason(order: order, shownStatus: shownStatus,
                                                    outcomeUnknown: environment.outcomeUnknown(order.id)) {
                return .failure(reason)
            }
            return .success(order)
        } catch {
            if dapiIsCancellation(error) { return .failure("Stopped.") }
            return .failure("Couldn’t read the order from 3DAPI: \(dapiFailureMessage(error)) Nothing was sent.")
        }
    }

    /// Cancel Order: re-reads and re-checks the order, then sends the cancellation once.
    func cancelOrder() {
        guard case .ready = phase, !closed else { return }
        phase = .loading
        readTask = Task { [weak self] in
            guard let self else { return }
            let gate = await self.fetchAndGate()
            self.readTask = nil
            guard !Task.isCancelled, !self.closed else { return }
            switch gate {
            case .failure(let message): self.phase = .blocked(message)
            case .success(let order): self.send(order)
            }
        }
    }

    private func send(_ order: DapiOrder) {
        let client: any DapiOrdering
        do { client = try environment.client() } catch {
            phase = .done(dapiCancelOutcome(.failure(error)))
            return
        }
        let key = environment.newIdempotencyKey()
        let token = environment.beginWrite()
        phase = .cancelling
        let id = order.id
        Task { [weak self] in
            let result: Result<DapiOrder, Error>
            do { result = .success(try await client.cancelOrder(id: id, idempotencyKey: key)) } catch { result = .failure(error) }
            guard let self else { return }
            self.environment.endWrite(token)
            let outcome = dapiCancelOutcome(result)
            if outcome.recordsUnknown { self.environment.noteUnknown(id) }
            switch outcome {
            case .cancelled(let order):
                self.onOrder?(order)
                self.log?("3DAPI cancellation", "Cancelled", true)
            case .notYetCancelled(let order):
                self.onOrder?(order)
                self.log?("3DAPI cancellation", "Outcome unknown", false)
            case .refused:
                var detail = "Refused"
                if case .failure(let error) = result, let dapiError = error as? DapiError { detail = dapiError.activityDetail }
                self.log?("3DAPI cancellation", detail, false)
            case .unknown:
                self.log?("3DAPI cancellation", "Outcome unknown", false)
            }
            self.phase = .done(outcome)
        }
    }
}

// MARK: - Composer state

let dapiNoQuoteForModelText = "Get a 3DAPI quote for this model first: select it in Models and press Get 3DAPI Quote…. The order composer never uploads or creates quotes."
let dapiQuoteStillProcessingText = "3DAPI is still pricing this model. Press Check Again in a few minutes."

/// What the composer talks to; tests pass stubs.
struct DapiComposerEnvironment {
    var client: @MainActor () throws -> any DapiOrderClient
    var readyQuoteID: @MainActor (_ fileHash: String) -> String?
    var rememberReadyQuote: @MainActor (_ id: String, _ fileHash: String) -> Void
    var hashFile: @Sendable (URL) throws -> String
    var noteHash: @MainActor (_ hash: String, _ model: LocalModel) -> Void

    @MainActor static func live() -> DapiComposerEnvironment {
        DapiComposerEnvironment(
            client: { try dapiCurrentOrderClient() },
            readyQuoteID: { DapiConnection.shared.readyQuoteID(forFileHash: $0) },
            rememberReadyQuote: { DapiConnection.shared.rememberReadyQuote(id: $0, forFileHash: $1) },
            hashFile: { try dapiFileSHA256(at: $0) },
            noteHash: { hash, model in
                DapiModelNameIndex.shared.note(hash: hash, modelName: model.name, path: model.filePath,
                                               version: dapiFileVersion(path: model.filePath) ?? "")
            })
    }
}

/// The composer's lines, the material catalogue and the shipping estimate. Reads only: it never uploads, creates a
/// quote or places anything.
@MainActor final class DapiComposerState: ObservableObject {
    @Published var lines: [DapiComposerLine] = []
    @Published private(set) var materials: [DapiMaterial] = []
    @Published private(set) var materialsLoading = false
    @Published private(set) var materialsProblem: String?
    @Published private(set) var shipping: DapiShippingEstimate?
    @Published private(set) var shippingFor: DapiOrderShippingKey?
    @Published private(set) var shippingLoading = false
    @Published private(set) var shippingProblem: String?

    private let environment: DapiComposerEnvironment
    private var lineTasks: [UUID: Task<Void, Never>] = [:]
    private var materialsTask: Task<Void, Never>?
    private var shippingTask: Task<Void, Never>?
    private var materialsRequested = false
    private var autoShippingDone = false
    /// The library model each model line came from (line ID → model), for Check Again.
    private var lineModels: [UUID: LocalModel] = [:]

    init(environment: DapiComposerEnvironment) {
        self.environment = environment
    }

    var isResolving: Bool { lines.contains { $0.state == .resolving } }

    func addModel(_ model: LocalModel, quantity: Int = 1) {
        guard lines.count < dapiOrderMaxLines else { return }
        let line = DapiComposerLine(modelID: model.id, name: model.name,
                                    quantity: min(max(quantity, 1), dapiOrderMaxUnitsPerLine))
        lines.append(line)
        lineModels[line.id] = model
        resolve(lineID: line.id)
    }

    func addDuplicated(_ duplicated: [DapiComposerLine], modelNames: [String: String]) {
        for var line in duplicated.prefix(max(0, dapiOrderMaxLines - lines.count)) {
            line.name = dapiLineDisplayName(quoteName: line.name, modelNames: modelNames)
            lines.append(line)
            resolve(lineID: line.id)
        }
    }

    func remove(lineID: UUID) {
        lineTasks[lineID]?.cancel()
        lineTasks[lineID] = nil
        lineModels[lineID] = nil
        lines.removeAll { $0.id == lineID }
    }

    func checkAgain(lineID: UUID) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }), lines[index].state != .resolving else { return }
        lines[index].state = .resolving
        resolve(lineID: lineID)
    }

    /// Stops every read (the sheet closed).
    func close() {
        lineTasks.values.forEach { $0.cancel() }
        lineTasks = [:]
        materialsTask?.cancel()
        materialsTask = nil
        shippingTask?.cancel()
        shippingTask = nil
        if materialsLoading { materialsLoading = false; materialsRequested = false }
        shippingLoading = false
        for index in lines.indices where lines[index].state == .resolving {
            lines[index].state = .problem("Stopped. Press Check Again.")
        }
    }

    private func update(_ lineID: UUID, _ change: (inout DapiComposerLine) -> Void) {
        guard let index = lines.firstIndex(where: { $0.id == lineID }) else { return }
        change(&lines[index])
    }

    private func resolve(lineID: UUID) {
        lineTasks[lineID]?.cancel()
        lineTasks[lineID] = Task { [weak self] in
            guard let self else { return }
            let result = await self.findQuote(lineID: lineID)
            guard !Task.isCancelled else { return }
            self.lineTasks[lineID] = nil
            self.update(lineID) { line in
                switch result {
                case .success(let quote):
                    line.quote = quote
                    line.quoteID = quote.id
                    line.state = .ready
                    if !dapiQuoteHasSuggestions(quote) { line.useSuggested = false }
                case .failure(let message):
                    line.state = .problem(message)
                }
            }
            self.fillSuggestedSlots()
        }
    }

    enum QuoteResult { case success(DapiQuote), failure(String) }

    private func findQuote(lineID: UUID) async -> QuoteResult {
        guard let line = lines.first(where: { $0.id == lineID }) else { return .failure("Removed.") }
        let client: any DapiOrderClient
        do { client = try environment.client() } catch { return .failure(dapiFailureMessage(error)) }
        // A duplicated line carries its quote ID: read it again (it may have been rejected since).
        if lineModels[lineID] == nil, let quoteID = line.quoteID {
            do {
                let quote = try await client.quote(id: quoteID)
                return quote.isUsable ? .success(quote) : .failure(dapiOrderQuoteUnusableReason(quote))
            } catch {
                return .failure("Couldn’t read this quote: \(dapiFailureMessage(error))")
            }
        }
        guard let model = lineModels[lineID] else { return .failure("This line has no model.") }
        let url = model.url
        let hashFile = environment.hashFile
        let hash: String
        do {
            hash = try await Task.detached(priority: .userInitiated) { try hashFile(url) }.value
        } catch {
            return .failure("Plinth couldn’t read this model’s file.")
        }
        if Task.isCancelled { return .failure("Stopped.") }
        environment.noteHash(hash, model)
        if let cached = environment.readyQuoteID(hash) {
            if let quote = try? await client.quote(id: cached), quote.isUsable { return .success(quote) }
            if Task.isCancelled { return .failure("Stopped.") }
        }
        let name = dapiQuoteName(fileHash: hash)
        do {
            let found = try await client.quotes(named: name, maxPages: dapiQuoteLookupPages)
            switch dapiPickExistingQuote(found, name: name) {
            case .ready(let quote):
                environment.rememberReadyQuote(quote.id, hash)
                return .success(quote)
            case .processing:
                return .failure(dapiQuoteStillProcessingText)
            case .none:
                return .failure(dapiNoQuoteForModelText)
            }
        } catch {
            return .failure("Couldn’t look for this model’s quote: \(dapiFailureMessage(error))")
        }
    }

    /// Reads the catalogue once per sheet (for the per-slot pickers).
    func loadMaterialsIfNeeded() {
        guard !materialsRequested else { return }
        materialsRequested = true
        materialsLoading = true
        materialsProblem = nil
        materialsTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<[DapiMaterial], Error>
            do { result = .success(try await self.environment.client().materials()) } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self.materialsLoading = false
            self.materialsTask = nil
            switch result {
            case .success(let list):
                self.materials = list
                self.fillSuggestedSlots()
            case .failure(let error):
                self.materialsRequested = false
                self.materialsProblem = "Couldn’t read 3DAPI’s materials: \(dapiFailureMessage(error))"
            }
        }
    }

    /// Pre-selects 3DAPI's suggested material for any empty slot, once the catalogue and the quote are both known.
    private func fillSuggestedSlots() {
        guard !materials.isEmpty else { return }
        for index in lines.indices where lines[index].state == .ready {
            for slot in dapiLineSlots(lines[index].quote) where (lines[index].slotMaterials[slot] ?? "").isEmpty {
                if let id = dapiSuggestedMaterialID(slot: slot, quote: lines[index].quote, catalogue: materials) {
                    lines[index].slotMaterials[slot] = id
                }
            }
        }
    }

    /// The first estimate comes by itself once every line and the country are set; later ones need Update Shipping.
    func shippingInputsChanged(_ key: DapiOrderShippingKey?) {
        guard let key, !autoShippingDone, shippingFor == nil, !shippingLoading else { return }
        autoShippingDone = true
        requestShipping(key)
    }

    /// Update Shipping: one estimate for these lines and country (nothing is created).
    func requestShipping(_ key: DapiOrderShippingKey) {
        shippingTask?.cancel()
        shippingLoading = true
        shippingProblem = nil
        shippingTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<DapiShippingEstimate, Error>
            do {
                result = .success(try await self.environment.client().shippingEstimate(lines: key.lines, countryCode: key.countryCode))
            } catch { result = .failure(error) }
            guard !Task.isCancelled else { return }
            self.shippingLoading = false
            self.shippingTask = nil
            switch result {
            case .success(let estimate):
                self.shipping = estimate
                self.shippingFor = key
            case .failure(let error):
                self.shipping = nil
                self.shippingFor = nil
                self.shippingProblem = "Couldn’t price shipping: \(dapiFailureMessage(error))"
            }
        }
    }
}
