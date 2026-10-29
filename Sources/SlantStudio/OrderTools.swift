import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Typed order sort keys

private let orderISOFormatterFractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()
private let orderISOFormatter = ISO8601DateFormatter()
private let orderDateOnlyFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
}()

/// Keys Slant (or older shapes) use for an order's creation time, in priority order.
let orderCreatedKeys = ["createdAt", "created_at", "created", "dateCreated"]

/// Parses an ISO 8601 timestamp (with or without fractional seconds) or a plain `yyyy-MM-dd` date.
func orderTimestamp(_ raw: String) -> Date? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    return orderISOFormatterFractional.date(from: trimmed)
        ?? orderISOFormatter.date(from: trimmed)
        ?? orderDateOnlyFormatter.date(from: trimmed)
}

/// The first non-empty creation timestamp string on the order.
func orderCreatedRaw(_ order: [String: Any]) -> String? {
    for key in orderCreatedKeys {
        if let value = order[key] as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return value }
    }
    return nil
}

func orderCreatedDate(_ order: [String: Any]) -> Date? {
    orderCreatedRaw(order).flatMap(orderTimestamp)
}

/// The order total as a number, using the same precedence as `orderTotalMoney` (total, totalCost, then the sum of
/// printing and delivery costs). Nil when Slant returned nothing usable.
func orderTotalAmount(_ order: [String: Any]) -> Decimal? {
    if order["total"] != nil { return decimalAmount(order["total"]) }
    if order["totalCost"] != nil { return decimalAmount(order["totalCost"]) }
    let print = decimalAmount(order["printingCost"])
    let delivery = decimalAmount(order["deliveryCost"])
    if let print, let delivery { return print + delivery }
    return print ?? delivery
}

// MARK: - Cost fields Studio doesn't add

// Slant's Order has no total of its own (live spec, 28 Oct 2026): Studio shows `printingCost` + `deliveryCost`. If Slant
// silently added a tax or fee field, the charge review would show too low a total without a word, so any other
// money-like field (or a Slant total that disagrees with the sum) is named in the single pay review and keeps the order
// out of Pay Several Drafts. Never changes whether Pay is enabled in the single review.

/// The cost fields Studio adds up into an order's total (`orderTotalAmount`, `orderTotalMoney`).
let orderCostFieldsStudioAdds: Set<String> = ["printingCost", "deliveryCost"]
/// Slant totals that Studio compares with the sum of those two costs, rather than naming them as extra fields: at the
/// top level (`total`, `totalCost`) and inside a `totals` object (the draft envelope's `totals.totalCost`).
let orderSlantTotalFields = ["total", "totalCost"]
/// Words that make a field look like money, matched case-insensitively anywhere in the key. Deliberately broad: a
/// false alarm (`costCentre`) only asks the seller to check the order on Slant, while a miss could under-state a charge.
/// `pric` covers price and pricing. Never `payment`: `paymentId` is a live key.
let orderMoneyKeyWords = ["cost", "fee", "tax", "total", "pric", "charge", "surcharge", "discount", "amount", "vat", "duty",
                          "gst", "levy", "handling", "insurance", "postage", "shipping", "billing"]
/// The notice names at most this many fields ("and 2 more" after them).
let orderUnlistedCostNameLimit = 3
/// Slant's total may differ from print + delivery by rounding: up to half a cent isn't a mismatch.
let orderTotalMismatchTolerance = Decimal(sign: .plus, exponent: -3, significand: 5)
/// A field name is shown with at most this many characters.
let orderUnlistedCostNameMaxLength = 40

func orderKeyLooksLikeMoney(_ key: String) -> Bool {
    let lower = key.lowercased()
    return orderMoneyKeyWords.contains { lower.contains($0) }
}

/// What the pay review says about an order's costs beyond the two Studio adds.
struct OrderUnlistedCosts: Equatable {
    /// Money-like fields Studio doesn't add into the total, sanitised and sorted, at most `orderUnlistedCostNameLimit`.
    /// Fields inside `totals` are named `totals.<key>`.
    var fields: [String] = []
    /// How many more such fields there were than are named.
    var moreFields = 0
    /// Slant's own total and the sum of print and delivery costs, when they differ by more than half a cent.
    var slantTotal: Decimal?
    var costsSum: Decimal?
    var isEmpty: Bool { fields.isEmpty && moreFields == 0 && slantTotal == nil }
}

/// A plain amount: a JSON number (not a boolean, not NaN) or a string of digits with an optional sign and decimals.
/// Stricter than `decimalAmount`, which reads "12 USD" as 12.
func orderStrictAmount(_ value: Any?) -> Decimal? {
    guard let value, !(value is NSNull) else { return nil }
    if let number = value as? NSNumber {
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let decimal = number.decimalValue
        return decimal.isNaN ? nil : decimal
    }
    guard let text = value as? String else { return nil }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: #"^[-+]?[0-9]+(\.[0-9]+)?$"#, options: .regularExpression) != nil else { return nil }
    return Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX"))
}

/// Whether a money-like field could add to the charge. Absent, null, a boolean, a zero amount and an empty list or
/// object can't; anything else (a non-zero amount, unreadable text, an object) might.
private func orderCostValueMatters(_ value: Any?) -> Bool {
    guard let value, !(value is NSNull) else { return false }
    if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return false }
    if let amount = orderStrictAmount(value) { return amount != 0 }
    if let text = value as? String { return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    if let list = value as? [Any] { return !list.isEmpty }
    if let object = value as? [String: Any] { return !object.isEmpty }
    return true
}

/// A field name as shown: letters, digits, `_`, `.` and `-` only, at most `orderUnlistedCostNameMaxLength` characters.
func orderCostFieldDisplayName(_ key: String) -> String {
    let allowed = key.unicodeScalars.filter { scalar in
        scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || "_.-".unicodeScalars.contains(scalar))
    }
    let cleaned = String(String.UnicodeScalarView(allowed))
    guard !cleaned.isEmpty else { return "an unnamed field" }
    return cleaned.count > orderUnlistedCostNameMaxLength ? String(cleaned.prefix(orderUnlistedCostNameMaxLength)) + "…" : cleaned
}

/// A stable description of a field's value, for telling whether it changed between the review and the payment.
private func orderCostValueSignature(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "null" }
    if let amount = orderStrictAmount(value) { return NSDecimalNumber(decimal: amount).stringValue }
    if JSONSerialization.isValidJSONObject(value),
       let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]),
       let text = String(data: data, encoding: .utf8) {
        return String(text.prefix(2_000))
    }
    return String(String(describing: value).prefix(2_000))
}

/// Every field the notice is about (raw key, value signature), and the first Slant total that disagrees with the sum.
private func orderUnlistedCostFindings(_ order: [String: Any]) -> (fields: [(key: String, value: String)], mismatch: (slant: Decimal, sum: Decimal)?) {
    var fields: [(key: String, value: String)] = []
    var mismatch: (slant: Decimal, sum: Decimal)?
    let print = decimalAmount(order["printingCost"]).flatMap { $0.isNaN ? nil : $0 }
    let delivery = decimalAmount(order["deliveryCost"]).flatMap { $0.isNaN ? nil : $0 }
    let sum = print.flatMap { print in delivery.map { print + $0 } }
    func compareTotal(_ key: String, _ value: Any?) {
        guard let value, !(value is NSNull) else { return }
        guard let amount = orderStrictAmount(value) else {
            fields.append((key, orderCostValueSignature(value)))
            return
        }
        if let sum, mismatch == nil, abs(amount - sum) > orderTotalMismatchTolerance {
            mismatch = (amount, sum)
        }
    }
    for key in orderSlantTotalFields { compareTotal(key, order[key]) }
    let totals = order["totals"] as? [String: Any]
    if let totals {
        for key in orderSlantTotalFields { compareTotal("totals.\(key)", totals[key]) }
        for (key, value) in totals where !orderCostFieldsStudioAdds.contains(key) && !orderSlantTotalFields.contains(key)
            && orderKeyLooksLikeMoney(key) && orderCostValueMatters(value) {
            fields.append(("totals.\(key)", orderCostValueSignature(value)))
        }
    }
    for (key, value) in order where !orderCostFieldsStudioAdds.contains(key) && !orderSlantTotalFields.contains(key)
        && !(key == "totals" && totals != nil) && orderKeyLooksLikeMoney(key) && orderCostValueMatters(value) {
        fields.append((key, orderCostValueSignature(value)))
    }
    return (fields.sorted { $0.key < $1.key }, mismatch)
}

/// Money-like fields on the order (top level, and inside a `totals` object) other than `printingCost` and
/// `deliveryCost`, and whether Slant's own total disagrees with their sum by more than half a cent. Item-level
/// `price` and `currency` are known and not looked at. Nested objects such as `platform` aren't searched.
func orderUnlistedCosts(_ order: [String: Any]) -> OrderUnlistedCosts {
    let findings = orderUnlistedCostFindings(order)
    var names: [String] = []
    for field in findings.fields {
        let name = orderCostFieldDisplayName(field.key)
        if !names.contains(name) { names.append(name) }
    }
    names.sort { $0.localizedStandardCompare($1) == .orderedAscending }
    return OrderUnlistedCosts(fields: Array(names.prefix(orderUnlistedCostNameLimit)),
                              moreFields: max(0, names.count - orderUnlistedCostNameLimit),
                              slantTotal: findings.mismatch?.slant, costsSum: findings.mismatch?.sum)
}

/// The fields and values behind the notice, for the re-check just before paying: a fee that appears or changes after
/// the review stops the payment like a changed price.
func orderUnlistedCostSignature(_ order: [String: Any]) -> [String] {
    let findings = orderUnlistedCostFindings(order)
    var signature = findings.fields.map { "\($0.key)=\($0.value)" }
    if let mismatch = findings.mismatch {
        signature.append("mismatch=\(NSDecimalNumber(decimal: mismatch.slant).stringValue)/\(NSDecimalNumber(decimal: mismatch.sum).stringValue)")
    }
    return signature
}

/// "taxCost", "taxCost and serviceFee", "a, b and c", "a, b, c and 2 more".
private func orderUnlistedCostFieldList(_ costs: OrderUnlistedCosts) -> String {
    var names = costs.fields
    if costs.moreFields > 0 { names.append("\(costs.moreFields) more") }
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
}

private func orderUnlistedCostMoney(_ amount: Decimal) -> String { money(NSDecimalNumber(decimal: amount)) }

/// The single pay review's notice, or nil when Slant's order lists nothing beyond print and delivery costs. Advisory:
/// it never changes whether Pay is enabled.
func orderUnlistedCostNotice(_ costs: OrderUnlistedCosts) -> String? {
    guard !costs.isEmpty else { return nil }
    var parts: [String] = []
    if !costs.fields.isEmpty {
        parts.append("Slant also lists \(orderUnlistedCostFieldList(costs)), which this total may not include.")
    }
    if let slant = costs.slantTotal, let sum = costs.costsSum {
        parts.append("Slant’s total (\(orderUnlistedCostMoney(slant)) USD) isn’t print plus delivery (\(orderUnlistedCostMoney(sum)) USD).")
    }
    parts.append("Check the order on Slant before paying.")
    return parts.joined(separator: " ")
}

/// Why Pay Several Drafts leaves the order out, or nil: a batch gets less attention per order, so such a draft is paid
/// on its own after checking.
func orderUnlistedCostBatchReason(_ costs: OrderUnlistedCosts) -> String? {
    guard !costs.isEmpty else { return nil }
    var parts: [String] = []
    if !costs.fields.isEmpty {
        parts.append("Slant also lists \(orderUnlistedCostFieldList(costs)) for it, which may not be included in its total.")
    }
    if let slant = costs.slantTotal, let sum = costs.costsSum {
        parts.append("Slant’s own total for it (\(orderUnlistedCostMoney(slant)) USD) doesn’t match print cost plus delivery (\(orderUnlistedCostMoney(sum)) USD).")
    }
    parts.append("Check it on Slant, then pay it in its own review.")
    return parts.joined(separator: " ")
}

/// Sort value for orders without a creation date: they sort as the oldest.
let orderMissingDateSortKey = Date.distantPast
/// Sort value for orders without a total: they sort as the cheapest.
let orderMissingTotalSortKey = -Decimal.greatestFiniteMagnitude

/// The table's default sort follows the server's createdAt sort from Filters (Newest = DESC, Oldest = ASC).
func orderTableDefaultSort(serverSortOrder: String) -> [KeyPathComparator<OrderTableRow>] {
    let descending = normalizedOrderSortOrder(serverSortOrder) == "DESC"
    return [KeyPathComparator(\OrderTableRow.createdSortKey, order: descending ? .reverse : .forward)]
}

/// Sorts rows by the table's comparators. Ties (and an empty comparator list) keep the order Slant returned.
func orderTableRowsSorted(_ rows: [OrderTableRow], using comparators: [KeyPathComparator<OrderTableRow>]) -> [OrderTableRow] {
    guard !comparators.isEmpty else { return rows }
    return rows.enumerated().sorted { lhs, rhs in
        for comparator in comparators {
            switch comparator.compare(lhs.element, rhs.element) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: continue
            }
        }
        return lhs.offset < rhs.offset
    }.map(\.element)
}

// MARK: - Order detail facts

/// Title for an order item's own status (OrderItem.status: PROCESSING, READY, SHIPPED, DELIVERED), or nil when absent.
func orderItemStatusTitle(_ item: [String: Any]) -> String? {
    guard let raw = (item["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
    switch raw.uppercased() {
    case "PROCESSING": return "Processing"
    case "READY": return "Ready"
    case "SHIPPED": return "Shipped"
    case "DELIVERED": return "Delivered"
    default: return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Per-item status is only worth showing when the items' statuses differ; otherwise it repeats the order status.
func orderItemStatusesDiffer(_ items: [[String: Any]]) -> Bool {
    let titles = items.map { orderItemStatusTitle($0) ?? "" }
    guard let first = titles.first else { return false }
    return titles.contains { $0 != first }
}

/// Display name for an `options.shippingProvider` value; unknown values are shown as Slant sent them.
func orderShippingProviderTitle(_ code: String) -> String {
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
    if let match = orderShippingProviderChoices.first(where: { !$0.code.isEmpty && $0.code == trimmed.uppercased() }) { return match.name }
    return trimmed
}

/// Readable words for a tracking value Slant sends as an API constant (carrier SHIPPO, service INTERNATIONAL, shipment
/// status IN_TRANSIT): "Shippo", "International", "In transit". Carrier acronyms stay in capitals, and values that
/// aren't all capitals (a carrier's own name, a tracking number) are shown as sent. Display only: copies, CSVs and
/// requests keep Slant's value.
func orderAPIValueTitle(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: #"^[A-Z][A-Z_ ]*[A-Z]$"#, options: .regularExpression) != nil else { return trimmed }
    let known: [String: String] = [
        "SHIPPO": "Shippo", "SHIPSTATION": "ShipStation", "FEDEX": "FedEx", "USPS": "USPS", "UPS": "UPS", "DHL": "DHL",
        "DHL_EXPRESS": "DHL Express", "EASYPOST": "EasyPost", "ROYAL_MAIL": "Royal Mail", "AUSTRALIA_POST": "Australia Post",
        "CANADA_POST": "Canada Post", "USPS_INTERNATIONAL": "USPS International"
    ]
    if let name = known[trimmed] { return name }
    let words = trimmed.replacingOccurrences(of: "_", with: " ").lowercased()
    return words.prefix(1).uppercased() + words.dropFirst()
}

/// Slant's `updatedAt` as "28 Oct 2026, 09:14" for the detail's Updated fact, or nil when absent, unreadable or within
/// a minute of `createdAt` (an order nothing has changed since it was made).
func orderDetailUpdatedLabel(_ order: [String: Any]) -> String? {
    guard let raw = order["updatedAt"] as? String, let updated = orderTimestamp(raw) else { return nil }
    if let created = orderCreatedDate(order), abs(updated.timeIntervalSince(created)) < 60 { return nil }
    return updated.formatted(date: .abbreviated, time: .shortened)
}

/// Extra order fields Slant returns that the detail pane shows only when present: when the order was placed
/// (`processedAt`; Slant's docs call a DRAFT "not yet processed"), when Slant last changed it (`updatedAt`), the requested shipping
/// provider and the fulfillment delivery instructions.
func orderDetailFacts(_ order: [String: Any]) -> [(String, String)] {
    var rows: [(String, String)] = []
    if let processed = order["processedAt"] as? String, !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        rows.append(("Placed", orderDateLabel(processed)))
    }
    if let updated = orderDetailUpdatedLabel(order) { rows.append(("Updated", updated)) }
    if let provider = (order["options"] as? [String: Any])?["shippingProvider"] as? String {
        let title = orderShippingProviderTitle(provider)
        if !title.isEmpty { rows.append(("Shipping provider", title)) }
    }
    if let instructions = (order["fulfillment"] as? [String: Any])?["deliveryInstructions"] as? String {
        let trimmed = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { rows.append(("Delivery instructions", trimmed)) }
    }
    return rows
}

/// The marketplace order reference stored in the order's `metadata` (`sourceOrderId`, plus `source` such as "Etsy"
/// when present), as CSV order import writes it. Nil when Slant didn't return metadata or the reference is absent.
func orderMarketplaceReference(_ order: [String: Any]) -> (id: String, source: String?)? {
    guard let metadata = order["metadata"] as? [String: Any] else { return nil }
    func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull), !(value is [Any]), !(value is [String: Any]) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
        let trimmed = ((value as? String) ?? String(describing: value)).trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
    guard let id = text(metadata["sourceOrderId"]) else { return nil }
    return (id: id, source: text(metadata["source"]))
}

/// Label for the marketplace reference. Import writes `source` in lower case ("etsy", "shopify", or "csv" for Studio's
/// template, which could come from anywhere), so known values get their proper names; another tool's value is shown
/// as written; no source at all reads "Marketplace order".
func orderMarketplaceReferenceLabel(source: String?) -> String {
    let trimmed = (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    switch trimmed.lowercased() {
    case "": return "Marketplace order"
    case "etsy": return "Etsy order"
    case "shopify": return "Shopify order"
    case "csv": return "Imported order"
    default: return "\(trimmed) order"
    }
}

/// One line for the orders table, such as "Etsy order 3141592653". Nil when the order has no marketplace reference.
func orderMarketplaceReferenceLine(_ order: [String: Any]) -> String? {
    guard let reference = orderMarketplaceReference(order) else { return nil }
    return "\(orderMarketplaceReferenceLabel(source: reference.source)) \(reference.id)"
}

// MARK: - Duplicate-draft guard

/// What happened to one Create Draft press.
enum DraftCreateAttempt {
    /// Nothing was sent (another request was running).
    case notSent
    case succeeded
    case failed(Error)
}

/// A Create Draft whose outcome wasn't confirmed, so Slant may hold that draft. In memory only, like the rest of the
/// guard: the recipient's name and the time are shown so the notice can be matched to the right customer.
struct UnconfirmedDraftAttempt: Equatable {
    let recipient: String
    let date: Date
    /// The `metadata.studioDraftId` sent with this attempt, for Check Slant (DraftConfirmation.swift); nil when the
    /// draft's metadata had no room for it.
    var marker: String? = nil
    /// The platform the draft was sent to, so Check Slant reads that platform's orders.
    var platformID: String = ""
}

/// How many unconfirmed attempts the notice remembers (the most recent ones).
let unconfirmedDraftAttemptLimit = 5

/// The recipient as compared between a confirmed creation and earlier unconfirmed attempts: trimmed, runs of
/// whitespace collapsed to one space, case-insensitive. An empty name stays empty, so it matches only another empty one.
/// It is the name only, not the address: two customers with the same name are one recipient here.
func draftAttemptRecipientKey(_ recipient: String) -> String {
    recipient.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
}

/// Unconfirmed Create Draft attempts after one more press. A timeout, transport failure, 5xx, 408/409 or an
/// unreadable reply adds this attempt. A confirmed success removes only the attempts for the same recipient name
/// (`draftAttemptRecipientKey`; owner decision, 28 Oct 2026): creating a draft for one customer says nothing about
/// another customer's unconfirmed draft, so that warning stays. Matching is by name only, so two customers with the
/// same name share a warning: a confirmed draft for one clears the other's attempt too. A failure that proves nothing
/// happened (refused with a definite 4xx, or never sent) leaves the list as it was, because it says nothing about the
/// earlier requests. Look for Draft on Slant confirms attempts by marker (`unconfirmedDraftAttempts(_:confirmedMarkers:)`).
func unconfirmedDraftAttempts(previous: [UnconfirmedDraftAttempt], attempt: DraftCreateAttempt,
                              recipient: String, date: Date,
                              marker: String? = nil, platformID: String = "") -> [UnconfirmedDraftAttempt] {
    switch attempt {
    case .notSent: return previous
    case .succeeded:
        let confirmed = draftAttemptRecipientKey(recipient)
        return previous.filter { draftAttemptRecipientKey($0.recipient) != confirmed }
    case .failed(let error):
        if orderMutationErrorProvesNoEffect(error) { return previous }
        let name = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        let added = UnconfirmedDraftAttempt(recipient: name, date: date, marker: marker,
                                            platformID: platformID.trimmingCharacters(in: .whitespacesAndNewlines))
        return Array((previous + [added]).suffix(unconfirmedDraftAttemptLimit))
    }
}

/// Whether earlier unconfirmed attempts have dropped off the list, which keeps only the most recent
/// `unconfirmedDraftAttemptLimit`. Set when an unconfirmed attempt pushes one out, and kept for the rest of the
/// session: the dropped attempts' recipients are no longer known, so no confirmed creation can show they were for the
/// same customer, and Look for Draft on Slant can't look for them (their markers went with them). The notice and
/// Create Anyway stay required.
func unconfirmedDraftAttemptsOverflowed(previous: [UnconfirmedDraftAttempt], overflowed: Bool,
                                        attempt: DraftCreateAttempt) -> Bool {
    switch attempt {
    case .notSent, .succeeded: return overflowed
    case .failed(let error):
        if orderMutationErrorProvesNoEffect(error) { return overflowed }
        return overflowed || previous.count >= unconfirmedDraftAttemptLimit
    }
}

/// Where to look for drafts: the Status menu in the Orders toolbar, set to Draft.
let draftCreateCheckDraftsPath = "Orders toolbar › Status › Draft"

/// The composer notice while earlier Create Draft attempts are unconfirmed. Names each attempt's recipient and time, so
/// a composer for a different customer can tell the warning is about someone else's draft. `earlierUnlisted`: older
/// unconfirmed attempts have dropped off the list (`unconfirmedDraftAttemptsOverflowed`).
func draftCreateUnknownNotice(_ attempts: [UnconfirmedDraftAttempt], earlierUnlisted: Bool = false,
                              time: (Date) -> String = draftAttemptTimeText) -> String {
    func describe(_ attempt: UnconfirmedDraftAttempt) -> String {
        attempt.recipient.isEmpty ? "at \(time(attempt.date))" : "for \(attempt.recipient) at \(time(attempt.date))"
    }
    if earlierUnlisted {
        let list = attempts.map(describe).joined(separator: "; ")
        let lead: String
        switch attempts.count {
        case 0: lead = "Earlier Create Draft attempts didn’t get a clear answer from Slant"
        case 1: lead = "More than one Create Draft attempt didn’t get a clear answer from Slant (the latest: \(list))"
        default: lead = "More than \(attempts.count) Create Draft attempts didn’t get a clear answer from Slant (the latest: \(list))"
        }
        return "\(lead), so those drafts may exist. Check your drafts (\(draftCreateCheckDraftsPath)) before creating them again."
    }
    guard let last = attempts.last else { return "" }
    if attempts.count == 1 {
        return "Your Create Draft \(describe(last)) didn’t get a clear answer from Slant, so that draft may exist. "
            + "Check your drafts (\(draftCreateCheckDraftsPath)) before creating it again."
    }
    let list = attempts.map(describe).joined(separator: "; ")
    return "\(attempts.count) Create Draft attempts didn’t get a clear answer from Slant (\(list)), so those drafts may exist. "
        + "Check your drafts (\(draftCreateCheckDraftsPath)) before creating them again."
}

/// The Create Anyway confirmation's message.
func draftCreateAnywayMessage(_ attempts: [UnconfirmedDraftAttempt], earlierUnlisted: Bool = false,
                              time: (Date) -> String = draftAttemptTimeText) -> String {
    draftCreateUnknownNotice(attempts, earlierUnlisted: earlierUnlisted, time: time) + (attempts.count > 1 || earlierUnlisted
        ? " If this is one of those orders, creating it again makes a second draft."
        : " If this is the same order, creating it again makes a second draft.")
}

/// "2:32 PM" today; with the date for an attempt on an earlier day.
func draftAttemptTimeText(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .abbreviated, time: .shortened)
}

/// The composer's Create Draft needs an explicit "Create Anyway" while `outcomeUnknown` (from
/// `draftCreateNeedsCreateAnyway`) holds and the seller hasn't confirmed.
func draftCreateNeedsConfirmation(outcomeUnknown: Bool, confirmed: Bool) -> Bool {
    outcomeUnknown && !confirmed
}

/// Whether the next Create (the composer's Create Draft, or the Workbench's `POST /orders`) needs Create Anyway (owner
/// decision, 28 Oct 2026). The notice shows whenever any attempt is unconfirmed, but asking on every Create trains the
/// seller to click through it, so it asks only when this draft could be one of those: its recipient matches an
/// unconfirmed attempt's (`draftAttemptRecipientKey`, by name only), an unconfirmed attempt has no recipient, older
/// attempts dropped off the list (`overflowed`), or this draft has no recipient. `recipient` is the name the request
/// actually sends.
func draftCreateNeedsCreateAnyway(attempts: [UnconfirmedDraftAttempt], overflowed: Bool, recipient: String) -> Bool {
    if overflowed { return true }
    guard !attempts.isEmpty else { return false }
    let key = draftAttemptRecipientKey(recipient)
    if key.isEmpty { return true }
    return attempts.contains { attempt in
        let attemptKey = draftAttemptRecipientKey(attempt.recipient)
        return attemptKey.isEmpty || attemptKey == key
    }
}

/// The discard prompt mustn't claim nothing was sent once a create request may have reached Slant.
func orderComposerDiscardMessage(outcomeUnknown: Bool) -> String {
    outcomeUnknown
        ? "Your items and delivery details haven’t been saved. Slant may already have created a draft from an earlier attempt; check your drafts (\(draftCreateCheckDraftsPath))."
        : "Your items and delivery details haven’t been saved. Nothing has been sent to Slant."
}

// MARK: - Platform scoping (display only)
//
// Slant's `GET /orders` didn't filter by `platformId` in Studio's tests (29 Oct 2026: an unknown or malformed
// `platformId`, and any `ownerId`, returned every order of the account; whether a second owned platform's ID filters
// is untested). Every order seen names its platform in `customer.platformId` (none had a top-level `platformId`), so
// Studio scopes what it shows locally. These helpers are for showing and summing only: `store.orders` stays raw, and
// duplicate, draft-marker, lock and charge checks never use them.

/// The platform an order names: `customer.platformId` (what Slant sends), else a top-level `platformId`; nil when it
/// names none.
func orderNamedPlatformID(_ order: [String: Any]) -> String? {
    for value in [(order["customer"] as? [String: Any])?["platformId"], order["platformId"]] {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
    }
    return nil
}

/// Whether an order is on `platformID`: nil when the order names no platform or no platform is given (it can't be
/// judged, so callers keep it).
func orderPlatformMatch(_ order: [String: Any], platformID: String) -> Bool? {
    let current = platformID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !current.isEmpty, let named = orderNamedPlatformID(order) else { return nil }
    return named == current
}

/// The loaded orders shown (or summed) for the default platform: those that name another platform are left out,
/// except any order under an unknown-outcome lock (`keeping`, matched by any of its IDs), which must stay reachable so
/// its Reload Order can lift the lock. Without a platform nothing is left out. Display only (see above).
func ordersShownOnPlatform(_ records: [Record], platformID: String, keeping: Set<String> = []) -> [Record] {
    guard !platformID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return records }
    return records.filter { record in
        let order = orderObject(record.values)
        guard orderPlatformMatch(order, platformID: platformID) == false else { return true }
        let ids = [record.id, orderNumber(order), (order["id"] as? String) ?? ""].filter { !$0.isEmpty }
        return ids.contains { keeping.contains($0) }
    }
}

/// The one line under the Orders list (and in its empty states) when orders on other platforms are hidden.
func orderOtherPlatformsHiddenLine(_ hidden: Int) -> String? {
    guard hidden > 0 else { return nil }
    let count = hidden == 1 ? "1 loaded order on another platform isn’t" : "\(hidden.formatted()) loaded orders on other platforms aren’t"
    return "\(count) shown: Orders lists your default platform’s orders (Settings › Account)."
}

// MARK: - Orders list and detail layout

/// The note under the orders list while searching. Typing filters the loaded orders; Return asks Slant, and clearing
/// the box returns to the normal list. Nil when there's nothing to explain.
func orderSearchHint(typed: String, searchActive: Bool) -> String? {
    if searchActive { return "Showing what Slant found. Clear the search to return to the list." }
    guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    // Slant's lookup finds order numbers only (see orderSearchQueryItems), so don't promise more.
    return "Showing loaded orders that match. Press Return to look up an order number on Slant."
}

/// Tracking is shown for orders being made or shipped, and whenever Slant returned tracking details. Drafts, cancelled
/// orders and payment problems have nothing to track, so a "No tracking yet" line would only be noise.
func orderDetailShowsTracking(status: String, hasTrackingDetails: Bool) -> Bool {
    if hasTrackingDetails { return true }
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return !["DRAFT", "CANCELED", "CANCELLED", "PAYMENT_ERROR"].contains(normalized)
}

/// The charge/cancel review shows up to this many items as a plain list; more scroll in a fixed-height box. A fixed
/// threshold (not ViewThatFits measuring) keeps the sheet's layout free of measurement cycles, which hung the app
/// when an accessibility client hit-tested the sheet.
let orderReviewPlainItemLimit = 4

func orderReviewItemListScrolls(itemCount: Int) -> Bool {
    itemCount > orderReviewPlainItemLimit
}

// MARK: - Order item names

/// The uploaded model an order item prints: its top-level or nested `printItem` file ID.
func orderItemFileID(_ item: [String: Any]) -> String? {
    for value in [item["publicFileServiceId"], (item["printItem"] as? [String: Any])?["publicFileServiceId"]] {
        if let id = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty { return id }
    }
    return nil
}

/// Uploaded file ID → model name, for order items whose own name is null. The library name (what the seller sees in
/// Models) wins over the uploaded file's name; blank names are skipped so the item falls back to its type.
func orderItemModelNames(localModels: [LocalModel], files: [Record]) -> [String: String] {
    var names: [String: String] = [:]
    for model in localModels {
        guard let id = model.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, names[id] == nil else { continue }
        let name = model.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { names[id] = name }
    }
    for file in files {
        let id = file.string("publicFileServiceId", "publicId", "id").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, names[id] == nil else { continue }
        let name = displayName(for: file, fallback: "")
        if !name.isEmpty { names[id] = name }
    }
    return names
}

/// "2 × Desk Tidy": an order item's quantity and name, as listed in the order detail and the review sheet.
func orderItemLineText(_ item: [String: Any], modelNames: [String: String] = [:]) -> String {
    let quantity: String
    if let whole = orderItemQuantity(item) {
        quantity = String(whole)
    } else if let raw = item["quantity"], !(raw is NSNull) {
        quantity = String(describing: raw)
    } else {
        quantity = "1"
    }
    return "\(quantity) × \(orderItemDisplayName(item, modelNames: modelNames))"
}

/// Under the charge review's item list, which scrolls when long: says how many items are flagged for a large quantity,
/// so a flagged line scrolled out of view isn't missed. Nil for a single item (its flag is in view) or none flagged.
func orderReviewLargeQuantityNotice(_ items: [[String: Any]]) -> String? {
    let flagged = items.filter { orderItemHasLargeQuantity($0) }.count
    guard items.count > 1, flagged > 0 else { return nil }
    return flagged == 1 ? "1 item has a large quantity. Check it above." : "\(flagged) items have a large quantity. Check them above."
}

// MARK: - Draft composer copy

/// The composer's own heading (a sheet shows no window title).
func orderComposerHeading(sourceOrderNumber: String?) -> String {
    guard let number = sourceOrderNumber?.trimmingCharacters(in: .whitespacesAndNewlines), !number.isEmpty else {
        return "New order draft"
    }
    return "Duplicate of order \(number)"
}

/// Shown when a new draft reuses the address from this session's last draft, such as
/// "Same address as your last draft: Ada Lovelace, London".
func orderComposerReusedAddressLine(_ delivery: DeliveryDetails) -> String {
    let parts = [delivery.name, delivery.city]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    let summary = parts.isEmpty ? delivery.email.trimmingCharacters(in: .whitespacesAndNewlines) : parts.joined(separator: ", ")
    return summary.isEmpty ? "Same address as your last draft" : "Same address as your last draft: \(summary)"
}

/// The composer's Advanced options start open when a duplicate copied a value into them, so copied values that will be
/// sent are never hidden.
func orderComposerAdvancedStartsExpanded(shippingProvider: String, metadataFields: [OrderMetadataField]) -> Bool {
    func filled(_ text: String) -> Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    return filled(shippingProvider) || metadataFields.contains { filled($0.key) || filled($0.value) }
}

// MARK: - Copied item options

/// Read-only summary of a composer line's item options, one entry per top-level key in key order. Empty when the line
/// sends no options. Options that aren't a JSON object (which the draft would reject) are reported as one entry.
func orderLineOptionsSummary(_ optionsJSON: String) -> [(key: String, value: String)] {
    let trimmed = optionsJSON.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return [] }
    guard let data = trimmed.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [String: Any] else {
        return [(key: "Options", value: "Not a valid JSON object")]
    }
    return object.keys.sorted().map { key in
        let value = object[key]
        let text: String
        if let string = value as? String {
            text = string
        } else if let value,
                  let encoded = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
                  let string = String(data: encoded, encoding: .utf8) {
            // Values come from JSONSerialization, so they are always encodable; booleans render as true/false.
            text = string
        } else {
            text = "null"
        }
        return (key: key, value: text)
    }
}

/// The line with its copied options removed, so the draft sends Slant's defaults for that item.
func orderLineRemovingOptions(_ line: OrderLine) -> OrderLine {
    var result = line
    result.optionsJSON = "{}"
    return result
}

// MARK: - Postcode format warnings

/// Countries whose postcode format is unambiguous enough to check locally, with an example for the warning and the
/// shortest valid length in letters and digits (spaces and hyphens not counted).
private let postcodeFormats: [String: (name: String, pattern: String, example: String, minimumLength: Int)] = [
    "US": ("US ZIP code", #"^\d{5}(-\d{4})?$"#, "12345 or 12345-6789", 5),
    "CA": ("Canadian postal code", #"^[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z] ?\d[ABCEGHJ-NPRSTV-Z]\d$"#, "K1A 0B1", 6),
    "GB": ("UK postcode", #"^(GIR ?0AA|[A-PR-UWYZ][A-HK-Y]?\d[A-Z\d]? ?\d[ABD-HJLNP-UW-Z]{2})$"#, "SW1A 1AA", 5),
    "AU": ("Australian postcode", #"^\d{4}$"#, "2000", 4),
    "NZ": ("New Zealand postcode", #"^\d{4}$"#, "6011", 4),
    "DE": ("German postcode", #"^\d{5}$"#, "10115", 5),
    "FR": ("French postcode", #"^\d{5}$"#, "75001", 5),
    "NL": ("Dutch postcode", #"^[1-9]\d{3} ?[A-Z]{2}$"#, "1012 AB", 6),
    "JP": ("Japanese postal code", #"^\d{3}-?\d{4}$"#, "100-0001", 7),
    "IE": ("Eircode", #"^([AC-FHKNPRTV-Y]\d{2}|D6W) ?[\dAC-FHKNPRTV-Y]{4}$"#, "D02 X285", 7)
]

/// Country codes with a local postcode format check.
var postcodeCheckedCountryCodes: Set<String> { Set(postcodeFormats.keys) }

/// A gentle warning when a postcode doesn't match the usual format for a handful of countries. Never blocks a draft;
/// empty postcodes (handled by required-field validation) and countries without a known format get no warning.
/// `whileEditing` (the field has focus) holds the warning back until the value reaches the country's minimum length,
/// so it doesn't appear on every keystroke; once the field loses focus any mismatch shows.
func postcodeFormatWarning(_ postcode: String, country: String, whileEditing: Bool = false) -> String? {
    let code = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let value = postcode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !value.isEmpty, let format = postcodeFormats[code] else { return nil }
    if whileEditing, value.filter({ $0.isLetter || $0.isNumber }).count < format.minimumLength { return nil }
    if value.range(of: format.pattern, options: .regularExpression) != nil { return nil }
    return "This doesn’t look like a \(format.name) (for example \(format.example)). Check it; you can still create the draft."
}

// MARK: - CSV export

let ordersCSVBaseColumns = [
    "Order number", "Created", "Status", "Item count", "Items",
    "Printing cost", "Delivery cost", "Total", "Currency", "Carrier", "Tracking numbers"
]
/// Opt-in columns: recipient, address and the order's metadata (which may hold customer references).
let ordersCSVAddressColumns = [
    "Recipient", "Email", "Address line 1", "Address line 2", "City", "State", "Postal code", "Country", "Metadata"
]

/// One CSV field: a leading formula character (= + - @ tab or CR) is neutralised with an apostrophe unless the
/// value is a plain number, and fields with commas, quotes, line breaks or edge spaces are quoted (RFC 4180).
func csvField(_ value: String) -> String {
    var text = value
    let first = text.unicodeScalars.first
    let firstVisible = text.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) }
    let startsLikeFormula = first.map { "=+-@\t\r".unicodeScalars.contains($0) } == true
        || firstVisible.map { "=+-@".unicodeScalars.contains($0) } == true
    if startsLikeFormula, text.range(of: #"^-?\d+(\.\d+)?$"#, options: .regularExpression) == nil {
        text = "'" + text
    }
    let needsQuotes = text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        || text.first?.isWhitespace == true || text.last?.isWhitespace == true
    guard needsQuotes else { return text }
    return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

private func csvAmount(_ amount: Decimal?) -> String {
    guard let amount else { return "" }
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? ""
}

private func csvText(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let text = value as? String { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
    return String(describing: value)
}

private let csvCreatedFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
}()

/// The CSV row values for one order, in `ordersCSVBaseColumns` (+ address columns) order. Fields Slant didn't return
/// are left blank; nothing is estimated or filled in.
func ordersCSVRow(_ record: Record, includeAddresses: Bool) -> [String] {
    let order = orderObject(record.values)
    let created: String
    if let raw = orderCreatedRaw(order) {
        created = orderTimestamp(raw).map { csvCreatedFormatter.string(from: $0) } ?? raw
    } else {
        created = ""
    }
    var itemCount = ""
    var itemSummary = ""
    if let items = order["items"] as? [[String: Any]] {
        let quantities = items.map(orderItemQuantity)
        if quantities.allSatisfy({ $0 != nil }) { itemCount = String(quantities.compactMap { $0 }.reduce(0, +)) }
        itemSummary = items.map { item in
            let quantity = orderItemQuantity(item).map(String.init) ?? csvText(item["quantity"])
            let name = orderItemDisplayName(item)
            return quantity.isEmpty ? name : "\(quantity) × \(name)"
        }.joined(separator: "; ")
    }
    let printing = decimalAmount(order["printingCost"])
    let delivery = decimalAmount(order["deliveryCost"])
    let total = orderTotalAmount(order)
    // Slant documents order costs in USD; an explicit currency on the order wins.
    var currency = csvText(order["currency"])
    if currency.isEmpty, printing != nil || delivery != nil || total != nil { currency = "USD" }
    let fulfillment = order["fulfillment"] as? [String: Any]
    let carrier = csvText(fulfillment?["provider"]).isEmpty ? csvText(fulfillment?["carrier"]) : csvText(fulfillment?["provider"])
    let tracking = trackingFacts(order["fulfillment"]).filter { $0.0 == "Tracking number" }.map(\.1).joined(separator: "; ")
    var row = [
        orderNumber(order), created, csvText(order["status"]), itemCount, itemSummary,
        csvAmount(printing), csvAmount(delivery), csvAmount(total), currency, carrier, tracking
    ]
    if includeAddresses {
        let details = (order["customer"] as? [String: Any])?["details"] as? [String: Any] ?? [:]
        let address = details["address"] as? [String: Any] ?? [:]
        row += [
            orderRecipientName(order), csvText(details["email"]), csvText(address["line1"]), csvText(address["line2"]),
            csvText(address["city"]), csvText(address["state"]), csvText(address["zip"]), csvText(address["country"]),
            ordersCSVMetadata(order["metadata"])
        ]
    }
    return row
}

/// Order metadata as compact JSON with sorted keys, or blank when there is none.
func ordersCSVMetadata(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "" }
    if let object = value as? [String: Any], object.isEmpty { return "" }
    guard JSONSerialization.isValidJSONObject(value),
          let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes]),
          let text = String(data: data, encoding: .utf8) else { return csvText(value) }
    return text
}

/// CSV for the given orders (header row first, CRLF line endings). Recipient, email, address and metadata columns
/// are only included when `includeAddresses` is true.
func ordersCSV(_ records: [Record], includeAddresses: Bool) -> String {
    let header = includeAddresses ? ordersCSVBaseColumns + ordersCSVAddressColumns : ordersCSVBaseColumns
    let rows = [header] + records.map { ordersCSVRow($0, includeAddresses: includeAddresses) }
    return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
}

/// Save-panel note when Slant has older orders that the list hasn't loaded.
func ordersCSVPartialNotice(moreOnServer: Bool) -> String? {
    moreOnServer ? "Only loaded orders are exported. Load more to include older ones." : nil
}

func ordersCSVDefaultFileName(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return "Slant orders \(formatter.string(from: date)).csv"
}

/// Activity text for an export. Never includes order contents.
func ordersCSVActivityDetail(count: Int, includeAddresses: Bool) -> String {
    let orders = count == 1 ? "1 order" : "\(count) orders"
    return includeAddresses ? "\(orders), including recipients, addresses and metadata" : orders
}

extension StudioStore {
    /// Writes the given (already loaded) orders to a CSV the user picks. No network requests. Recipient, address and
    /// metadata columns are off unless the user ticks the checkbox in the save panel. `moreOnServer` adds a note that
    /// older orders that haven't been loaded aren't included.
    func exportOrdersCSV(_ records: [Record], moreOnServer: Bool = false) {
        guard !records.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Orders"
        panel.message = records.count == 1 ? "Exports the order shown in the list." : "Exports the \(records.count) orders shown in the list."
        panel.nameFieldStringValue = ordersCSVDefaultFileName()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let checkbox = NSButton(checkboxWithTitle: "Include recipient, address and metadata", target: nil, action: nil)
        checkbox.state = .off
        func smallNote(_ text: String) -> NSTextField {
            let note = NSTextField(wrappingLabelWithString: text)
            note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            note.textColor = .secondaryLabelColor
            note.preferredMaxLayoutWidth = 360
            return note
        }
        var views: [NSView] = [checkbox, smallNote("Names, emails, addresses and metadata (which may hold customer references) are left out unless you include them. The file isn’t protected once saved.")]
        if let notice = ordersCSVPartialNotice(moreOnServer: moreOnServer) { views.append(smallNote(notice)) }
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = stack
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let includeAddresses = checkbox.state == .on
        // A UTF-8 byte order mark lets spreadsheet apps read non-ASCII names correctly.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(ordersCSV(records, includeAddresses: includeAddresses).utf8)
        do {
            try data.write(to: destination, options: .atomic)
            activities.insert(Activity(title: "Export orders", detail: ordersCSVActivityDetail(count: records.count, includeAddresses: includeAddresses), success: true), at: 0)
        } catch {
            showError("Could not export orders: \(error.localizedDescription)")
        }
    }
}
