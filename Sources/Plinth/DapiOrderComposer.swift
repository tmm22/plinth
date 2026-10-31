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

private func dapiHasControlCharacters(_ text: String, allowingLineBreaks: Bool = false) -> Bool {
    text.unicodeScalars.contains { scalar in
        if allowingLineBreaks, scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
        return CharacterSet.controlCharacters.contains(scalar)
    }
}

/// Each field's problem, mirroring 3DAPI's limits and the client's own check (`dapiOrderRequestProblem`): lengths in
/// Unicode scalars (JSON Schema's count), name 1–200, an email `dapiEmailLooksValid` accepts, street and city required,
/// a country 3DAPI delivers to, optional notes ≤ 2,000. Nothing here invents a value: a missing email is a problem,
/// never filled in.
func dapiRecipientProblems(_ address: DapiComposerAddress, notes: String = "") -> [DapiComposerField: String] {
    var problems: [DapiComposerField: String] = [:]
    let d = address.delivery
    func trimmed(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines) }
    func check(_ field: DapiComposerField, _ value: String, required: String?, max: Int) {
        let text = trimmed(value)
        if text.isEmpty {
            if let required { problems[field] = required }
        } else if text.unicodeScalars.count > max {
            problems[field] = "Use at most \(max) characters."
        } else if dapiHasControlCharacters(text) {
            problems[field] = "Remove the line breaks or tabs."
        }
    }
    check(.name, d.name, required: "Enter the recipient’s name.", max: dapiNameMaxLength)
    let email = trimmed(d.email)
    if email.isEmpty {
        problems[.email] = "3DAPI needs the recipient’s email."
    } else if !dapiEmailLooksValid(email) {
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
    let trimmedNotes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmedNotes.unicodeScalars.count > dapiNotesMaxLength {
        problems[.notes] = "Notes can be at most 2,000 characters."
    } else if dapiHasControlCharacters(trimmedNotes, allowingLineBreaks: true) {
        problems[.notes] = "Remove the control characters from the notes."
    }
    return problems
}

/// Countries 3DAPI never delivers to (its shipping docs). Left out of the 3DAPI composer's country list.
let dapiUnservedCountryCodes: Set<String> = ["RU", "BY", "IR", "SY"]
let dapiUnservedCountriesNote = "3DAPI delivers worldwide except Russia, Belarus, Iran and Syria."

/// An ISO alpha-2 country a 3DAPI parcel can go to (the composer's country list).
func dapiIsDeliveryCountry(_ code: String) -> Bool {
    let upper = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return isCountryCode(upper) && !orderNonCountryRegionCodes.contains(upper) && !dapiUnservedCountryCodes.contains(upper)
        && Locale.Region.isoRegions.contains { $0.identifier == upper }
}

/// The client's own pre-send check (`dapiOrderRequestProblem`) on the order as the composer would send it, with a
/// placeholder reference of the right shape. Anything it refuses keeps Review Order… off, so nothing passes the
/// composer and then fails as "Nothing was sent" after the review.
func dapiComposerRequestProblem(lines: [DapiOrderLineRequest], recipient: DapiOrderRecipient, notes: String?) -> String? {
    dapiOrderRequestProblem(DapiOrderRequest(lines: lines, recipient: recipient,
                                             reference: dapiOrderReference(sellerReference: nil, token: "00000000"),
                                             customerNotes: notes))
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

/// The quote names a catalogue material (by name or ID) for every slot, so `use_suggested_materials` can be sent.
func dapiQuoteHasSuggestions(_ quote: DapiQuote?) -> Bool {
    guard let quote, !quote.suggestedMaterials.isEmpty else { return false }
    return quote.suggestedMaterials.allSatisfy {
        !($0.materialName ?? "").trimmingCharacters(in: .whitespaces).isEmpty
            || !($0.materialID ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// A line chooses its own materials (not 3DAPI's suggestions), so 3DAPI's quoted price may not be what it charges.
func dapiLineUsesChosenMaterials(_ request: DapiOrderLineRequest) -> Bool {
    if case .slots = request.materials { return true }
    return false
}

/// The extruder slots a line needs a material for: the quote's suggested slots, else slot 1.
func dapiLineSlots(_ quote: DapiQuote?) -> [Int] {
    let slots = Array(Set((quote?.suggestedMaterials ?? []).map(\.slot).filter { $0 >= 1 })).sorted()
    return slots.isEmpty ? [1] : slots
}

/// The catalogue material 3DAPI suggested for a slot, if it is in the catalogue: by the suggestion's material ID when
/// 3DAPI sent one, else by exact name (any case).
func dapiSuggestedMaterialID(slot: Int, quote: DapiQuote?, catalogue: [DapiMaterial]) -> String? {
    guard let suggestion = quote?.suggestedMaterials.first(where: { $0.slot == slot }) else { return nil }
    if let id = suggestion.materialID?.trimmingCharacters(in: .whitespaces), !id.isEmpty,
       let match = catalogue.first(where: { $0.id == id }) {
        return match.id
    }
    guard let name = suggestion.materialName?.trimmingCharacters(in: .whitespaces).lowercased(), !name.isEmpty else { return nil }
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
    let recipient = dapiOrderRecipient(address)
    let sentNotes = trimmedNotes.isEmpty ? nil : trimmedNotes
    guard dapiComposerRequestProblem(lines: draftLines.map(\.request), recipient: recipient, notes: sentNotes) == nil else {
        return nil
    }
    return DapiOrderDraft(lines: draftLines, recipient: recipient,
                          sellerReference: reference.trimmingCharacters(in: .whitespacesAndNewlines),
                          notes: sentNotes)
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

let dapiWalletNote = "If your 3DAPI wallet is short, 3DAPI charges the rest to your saved card, with VAT on that top-up for EU and UK businesses without a confirmed VAT number."
/// Shown when any line uses chosen materials: 3DAPI's quote priced the file, not those materials.
let dapiChosenMaterialsPriceNote = "3DAPI prices the file in its quote. Materials you chose yourself may change the price 3DAPI charges, which Plinth can’t check before ordering."

/// What the "up to" total exceeds the wallet balance by (same currency only), or nil when the wallet covers it or the
/// balance isn't known. Sample credit isn't counted: 3DAPI applies it only to orders to the seller's own country.
func dapiWalletShortfall(upTo: DapiMoney?, wallet: DapiWallet?) -> DapiMoney? {
    guard let upTo, let balance = wallet?.balance,
          upTo.currency.lowercased() == balance.currency.lowercased(), upTo.amountMinor > balance.amountMinor else { return nil }
    return DapiMoney(amountMinor: upTo.amountMinor - max(0, balance.amountMinor), currency: upTo.currency)
}

/// The review's line for a shortfall.
func dapiWalletShortfallText(_ shortfall: DapiMoney) -> String {
    "Your wallet may be up to \(dapiMoneyText(shortfall)) short for this order. 3DAPI charges any shortfall to your saved card, with VAT on that top-up for EU and UK businesses without a confirmed VAT number."
}

/// The review's sample-credit choice and its caption.
let dapiSampleCreditToggleTitle = "Use My Sample Credit"
let dapiSampleCreditCaption = "3DAPI uses it only for orders to your own country (your billing or sign-up country); otherwise the order is charged in full."

/// Why the sample-credit choice stops a Place Order at the pre-send check, or nil: the seller changed it after pressing
/// Place Order, or ticked it and the fresh wallet no longer shows sample credit.
func dapiSampleCreditChange(pressed: Bool, current: Bool, available: Bool) -> String? {
    if pressed != current { return "You changed Use My Sample Credit while Plinth was checking. Press Place Order again." }
    if pressed, !available { return "Your 3DAPI wallet no longer shows sample credit, so it can’t be used." }
    return nil
}
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
    case .refused:
        return .notCharged(dapiPlaceRefusalMessage(error, now: now))
    case .outcomeUnknown, .readFailed:
        return .unknown(dapiPlaceUnknownText)
    }
}

let dapiPlaceUnknownText = "3DAPI didn’t answer clearly, so it may have charged your wallet and placed the order. Plinth won’t send it again. Press Look for Order on 3DAPI to check before placing it again."

/// A definite refusal of Place Order: the client's own copy (`DapiError.userMessage`, the single source for 3DAPI's
/// error codes) and that nothing was charged, because 3DAPI places and charges nothing it refuses.
func dapiPlaceRefusalMessage(_ error: DapiError, now: Date = Date()) -> String {
    error.userMessage(now: now) + " Nothing was charged."
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
    /// Records an attempt as unconfirmed. Called just before the `POST` (like Slant's lock), so another composer's Place
    /// asks Place Anyway while this one waits; it stays for an unknown outcome.
    var noteUnconfirmed: @MainActor (DapiUnconfirmedOrder) -> Void
    /// Removes the attempt with this exact reference: a confirmed order, or a definite refusal (nothing charged).
    var confirmUnconfirmed: @MainActor (String) -> Void
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
            confirmUnconfirmed: { DapiOrderSession.shared.confirmUnconfirmedOrder(reference: $0) },
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
    /// Use My Sample Credit (off by default; shown only when the wallet shows sample credit). What was ticked when
    /// Place Order was pressed is what is sent, and only while the fresh wallet still shows sample credit.
    @Published var useSampleCredit = false

    let draft: DapiOrderDraft
    private let environment: DapiPlaceEnvironment
    private var checkTask: Task<Void, Never>?
    private var started = false
    private(set) var closed = false
    /// Use My Sample Credit as it was when Place Order was pressed.
    private var pressedSampleCredit = false
    /// Called once with the placed order (the list inserts and selects it).
    var onPlaced: ((DapiOrder) -> Void)?
    /// Called just before the order request goes out, with its attempt (already recorded as unconfirmed).
    var onSending: ((DapiUnconfirmedOrder) -> Void)?
    /// Called when 3DAPI definitely didn't place an attempt, before its unconfirmed record is removed.
    var onNotCharged: ((_ reference: String) -> Void)?
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

    /// Go Back, Close or the sheet going away: stop any read, so a re-check that finishes afterwards never sends.
    /// Never the order request itself: Go Back is refused while it is with 3DAPI (`canClose`), and a request whose
    /// task hadn't started yet is dropped unsent (`send`).
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
        pressedSampleCredit = useSampleCredit
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
                var changed = dapiReviewChanges(reviewed: reviewed.snapshot, current: fresh.snapshot, names: self.draft.quoteNames)
                let creditAvailable = (fresh.wallet?.sampleCredit?.amountMinor ?? 0) > 0
                if let credit = dapiSampleCreditChange(pressed: self.pressedSampleCredit, current: self.useSampleCredit,
                                                       available: creditAvailable) {
                    changed.append(credit)
                    if !creditAvailable { self.useSampleCredit = false }
                }
                if !changed.isEmpty {
                    self.figures = fresh
                    self.changes = changed
                    self.phase = .ready
                    return
                }
                self.send(figures: fresh, useSampleCredit: self.pressedSampleCredit && creditAvailable)
            }
        }
    }

    func declinePlaceAnyway() { askPlaceAnyway = false }

    private func send(figures: DapiOrderReviewFigures, useSampleCredit: Bool) {
        guard phase == .rechecking, !closed else { return }
        let client: any DapiOrderClient
        do { client = try environment.client() } catch {
            phase = .notCharged(dapiPlaceFailureText(dapiPlaceFailure(error)))
            return
        }
        let reference = dapiOrderReference(sellerReference: draft.sellerReference, token: environment.newReferenceToken())
        var request = DapiOrderRequest(lines: figures.snapshot.lines, recipient: draft.recipient, reference: reference,
                                       customerNotes: draft.notes)
        request.useSampleCredit = useSampleCredit
        let key = environment.newIdempotencyKey()
        let environment = self.environment
        let token = environment.beginWrite()
        phase = .placing
        let record = DapiUnconfirmedOrder(id: UUID(), reference: reference, recipientName: draft.recipient.name,
                                          countryCode: draft.recipient.countryCode, units: draft.units, sentAt: environment.now())
        // Recorded before sending, like Slant's lock: until 3DAPI answers clearly, any other Place asks Place Anyway.
        environment.noteUnconfirmed(record)
        onSending?(record)
        // Not stored in `checkTask`: nothing cancels the order request once it is sent. `self` is held strongly, so
        // the write always ends and the outcome is always recorded, even if the sheet has gone.
        Task { [self] in
            if self.closed {
                // The sheet went away before the request was handed over: nothing was sent.
                environment.endWrite(token)
                self.onNotCharged?(reference)
                environment.confirmUnconfirmed(reference)
                self.phase = .notCharged("Nothing was sent, so nothing was charged.")
                return
            }
            let result: Result<DapiOrder, Error>
            do { result = .success(try await client.placeOrder(request, idempotencyKey: key)) } catch { result = .failure(error) }
            environment.endWrite(token)
            self.finish(result, record: record)
        }
    }

    private func finish(_ result: Result<DapiOrder, Error>, record: DapiUnconfirmedOrder) {
        switch result {
        case .success(let order):
            environment.confirmUnconfirmed(record.reference)
            phase = .placed(order)
            log?("3DAPI order", order.status.countsAsPlaced ? "Placed" : "Created, status: \(order.status.label)", true)
            onPlaced?(order)
        case .failure(let error):
            switch dapiPlaceFailure(error, now: environment.now()) {
            case .notCharged(let message):
                onNotCharged?(record.reference)
                environment.confirmUnconfirmed(record.reference)
                phase = .notCharged(message)
                log?("3DAPI order", (error as? DapiError)?.activityDetail ?? "Not sent", false)
            case .unknown(let message):
                // The record made before sending stays for the whole session.
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

/// One of a composer's own attempts (sent, and not definitely refused) is no longer unconfirmed: 3DAPI has that order
/// (placed, found by Look for Order on 3DAPI, or seen in a reload). The composer then closes as after a placed order.
func dapiComposerOwnOrderSettled(sent: Set<String>, unconfirmed: [String]) -> Bool {
    let open = Set(unconfirmed)
    return sent.contains { !open.contains($0) }
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
        return "3DAPI can’t cancel an order once a production partner has it. Email \(dapiProblemSupportAddress) about this one."
    }
    return nil
}

/// The order detail's one line when Cancel Order… isn't offered, or nil when it is (or an earlier cancel's outcome is
/// unknown, which has its own note). Like Slant's `orderDetailCancelBlockedNote`.
func dapiCancelUnavailableNote(_ order: DapiOrder, cancelUnknown: Bool) -> String? {
    if cancelUnknown || order.status.canRequestCancellation { return nil }
    switch order.status {
    case .cancelled:
        return "This order is already cancelled."
    case .shipped, .completed, .returned:
        return "This order has shipped, so it can’t be cancelled. Use Report a Problem… if something is wrong with it."
    case .unknown:
        return "Plinth doesn’t recognise this status, so it doesn’t offer Cancel. Email \(dapiProblemSupportAddress) about this one."
    default:
        return "3DAPI can cancel only while an order is Paid, before a production partner has it. Email \(dapiProblemSupportAddress) about this one."
    }
}

/// Whether an order was placed through 3DAPI's checkout (the buyer paid 3DAPI), rather than from the seller's wallet.
func dapiOrderIsCheckout(mode: String) -> Bool { mode.trimmingCharacters(in: .whitespaces).lowercased() == "checkout" }

/// What cancelling does to the money, by how the order was paid and its status. Wallet orders are refunded to the
/// wallet; paid checkout orders to the customer's card in 5–10 business days; an unpaid checkout order's link closes.
func dapiCancelExplanation(mode: String, status: DapiOrderStatus) -> String {
    if status == .awaitingPayment {
        return "This order hasn’t been paid, so cancelling it closes its checkout link. Nothing is refunded because nothing was charged."
    }
    if dapiOrderIsCheckout(mode: mode) {
        return "3DAPI refunds this order in full to your customer’s card, usually within 5–10 business days. It can’t cancel an order once a production partner has it."
    }
    return "3DAPI refunds this order in full to your 3DAPI wallet. It can’t cancel an order once a production partner has it."
}

/// The cancel review's line once 3DAPI returned the order cancelled.
func dapiCancelledText(mode: String, status: DapiOrderStatus) -> String {
    if status == .awaitingPayment { return "3DAPI cancelled the order and closed its checkout link." }
    if dapiOrderIsCheckout(mode: mode) {
        return "3DAPI cancelled the order. It refunds your customer’s card in full, usually within 5–10 business days."
    }
    return "3DAPI cancelled the order and refunds it in full to your 3DAPI wallet."
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

    /// The cancel stays recorded as unknown (no second cancel) until a reload shows the order cancelled or in another
    /// status than the one it was sent from (`dapiCancelLockLifted`).
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
        case .refused: return .refused(error.userMessage)
        case .outcomeUnknown, .readFailed: return .unknown(dapiCancelUnknownText)
        }
    }
}

let dapiCancelUnknownText = "3DAPI didn’t answer clearly, so the order may or may not be cancelled. Plinth won’t send the cancellation again: refresh the order to see its status."

/// Whether a loaded order lifts the lock of a cancel whose outcome is unknown: it shows cancelled, or a status other
/// than the one the cancel was sent from (that is the cancel's outcome either way). The same status keeps it, and
/// so does any status when the sent-from status wasn't recorded.
func dapiCancelLockLifted(order: DapiOrder, sentFrom: DapiOrderStatus?) -> Bool {
    if order.status == .cancelled { return true }
    guard let sentFrom else { return false }
    return dapiOrderWatchStatusKey(order.status) != dapiOrderWatchStatusKey(sentFrom)
}

/// Session bookkeeping a loaded order settles: an unconfirmed attempt whose exact reference it carries is confirmed, and
/// a cancel with an unknown outcome is cleared by `dapiCancelLockLifted`. Nothing else clears either.
func dapiSessionSettlements(_ orders: [DapiOrder], unconfirmed: [DapiUnconfirmedOrder], cancelUnknown: Set<String>,
                            cancelSentFrom: [String: DapiOrderStatus] = [:]) -> (confirmReferences: [String], clearCancelIDs: [String]) {
    let references = Set(orders.compactMap(\.reference))
    let confirm = unconfirmed.map(\.reference).filter { references.contains($0) }
    let clear = orders.filter { cancelUnknown.contains($0.id) && dapiCancelLockLifted(order: $0, sentFrom: cancelSentFrom[$0.id]) }
        .map(\.id)
    return (Array(Set(confirm)).sorted(), Array(Set(clear)).sorted())
}

/// The 3DAPI cancel bookkeeping beside `DapiOrderSession.cancelOutcomeUnknown`, for the whole session, in memory only:
/// the status each unknown-outcome cancel was sent from (what lifts its lock), and the orders this session cancelled
/// through Plinth (the order watch doesn't tell the seller about their own cancellation).
@MainActor final class DapiCancelSession {
    static let shared = DapiCancelSession()

    private(set) var sentFrom: [String: DapiOrderStatus] = [:]
    private(set) var cancelledThroughPlinth: Set<String> = []

    /// Locks further cancels of `orderID` until a reload shows the outcome.
    func noteOutcomeUnknown(orderID: String, sentFrom status: DapiOrderStatus) {
        sentFrom[orderID] = status
        DapiOrderSession.shared.noteCancelOutcomeUnknown(orderID: orderID)
    }

    func clear(orderID: String) {
        sentFrom[orderID] = nil
        DapiOrderSession.shared.clearCancelOutcomeUnknown(orderID: orderID)
    }

    func noteCancelledThroughPlinth(orderID: String) { cancelledThroughPlinth.insert(orderID) }
}

/// What the cancel review talks to.
struct DapiCancelEnvironment {
    var client: @MainActor () throws -> any DapiOrdering
    var beginWrite: @MainActor () -> UUID
    var endWrite: @MainActor (UUID) -> Void
    var outcomeUnknown: @MainActor (String) -> Bool
    /// The status an unknown-outcome cancel of this order was sent from, if recorded.
    var sentFrom: @MainActor (String) -> DapiOrderStatus?
    /// Records an unknown outcome and the status the cancel was sent from.
    var noteUnknown: @MainActor (String, DapiOrderStatus) -> Void
    var clearUnknown: @MainActor (String) -> Void
    /// 3DAPI returned the order cancelled (the order watch stays quiet about it).
    var noteCancelled: @MainActor (String) -> Void
    var newIdempotencyKey: @MainActor () -> String

    @MainActor static func live() -> DapiCancelEnvironment {
        DapiCancelEnvironment(
            client: { try dapiCurrentOrderClient() },
            beginWrite: { DapiOrderSession.shared.beginWrite(.dapiCancellation) },
            endWrite: { DapiOrderSession.shared.endWrite($0) },
            outcomeUnknown: { DapiOrderSession.shared.cancelOutcomeUnknown.contains($0) },
            sentFrom: { DapiCancelSession.shared.sentFrom[$0] },
            noteUnknown: { DapiCancelSession.shared.noteOutcomeUnknown(orderID: $0, sentFrom: $1) },
            clearUnknown: { DapiCancelSession.shared.clear(orderID: $0) },
            noteCancelled: { DapiCancelSession.shared.noteCancelledThroughPlinth(orderID: $0) },
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
    private(set) var closed = false
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
            if environment.outcomeUnknown(order.id), dapiCancelLockLifted(order: order, sentFrom: environment.sentFrom(order.id)) {
                environment.clearUnknown(order.id)
            }
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
        guard !closed else { return }
        let client: any DapiOrdering
        do { client = try environment.client() } catch {
            phase = .done(dapiCancelOutcome(.failure(error)))
            return
        }
        let key = environment.newIdempotencyKey()
        let environment = self.environment
        let token = environment.beginWrite()
        phase = .cancelling
        let id = order.id
        let sentFrom = order.status
        // `self` is held strongly: the write always ends and an unknown outcome is always recorded.
        Task { [self] in
            if self.closed {
                // The sheet went away before the request was handed over: nothing was sent.
                environment.endWrite(token)
                self.phase = .done(.refused("Nothing was sent."))
                return
            }
            let result: Result<DapiOrder, Error>
            do { result = .success(try await client.cancelOrder(id: id, idempotencyKey: key)) } catch { result = .failure(error) }
            environment.endWrite(token)
            let outcome = dapiCancelOutcome(result)
            if outcome.recordsUnknown { environment.noteUnknown(id, sentFrom) }
            switch outcome {
            case .cancelled(let order):
                environment.noteCancelled(id)
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
    /// The references of this composer's Place Order attempts that 3DAPI didn't definitely refuse. If one of them leaves
    /// the session's unconfirmed list (Look for Order on 3DAPI, a reload or a placed order found it), 3DAPI has this
    /// order, so the composer closes like after a placed order and never lets the same draft be placed again silently.
    private(set) var sentReferences: Set<String> = []

    init(environment: DapiComposerEnvironment) {
        self.environment = environment
    }

    /// The review is about to send an attempt (already recorded as unconfirmed).
    func noteSending(reference: String) { sentReferences.insert(reference) }
    /// 3DAPI definitely didn't place an attempt (called before its record is removed).
    func noteNotCharged(reference: String) { sentReferences.remove(reference) }

    /// Whether one of this composer's attempts was found or placed: see `dapiComposerOwnOrderSettled`.
    func ownOrderSettled(unconfirmedReferences: [String]) -> Bool {
        dapiComposerOwnOrderSettled(sent: sentReferences, unconfirmed: unconfirmedReferences)
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

    /// Reads the catalogue once per sheet (for the per-slot pickers). After a failure it isn't read again by itself:
    /// only Try Again (`retryMaterials`) reads it again.
    func loadMaterialsIfNeeded() {
        guard !materialsRequested else { return }
        startMaterialsRead()
    }

    /// Try Again after a failed materials read: one more read, only on the seller's press.
    func retryMaterials() {
        guard !materialsLoading, materials.isEmpty else { return }
        startMaterialsRead()
    }

    private func startMaterialsRead() {
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
                // `materialsRequested` stays set: a later change in the form never reads again by itself.
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
