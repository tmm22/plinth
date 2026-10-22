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

/// Extra order fields Slant returns that the detail pane shows only when present: when the order was processed, the
/// requested shipping provider and the fulfillment delivery instructions.
func orderDetailFacts(_ order: [String: Any]) -> [(String, String)] {
    var rows: [(String, String)] = []
    if let processed = order["processedAt"] as? String, !processed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        rows.append(("Processed", orderDateLabel(processed)))
    }
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
}

/// How many unconfirmed attempts the notice remembers (the most recent ones).
let unconfirmedDraftAttemptLimit = 5

/// Unconfirmed Create Draft attempts after one more press. A timeout, transport failure, 5xx, 408/409 or an
/// unreadable reply adds this attempt; only a confirmed success clears the list. A failure that proves nothing
/// happened (refused with a definite 4xx, or never sent) leaves the list as it was, because it says nothing about the
/// earlier requests.
func unconfirmedDraftAttempts(previous: [UnconfirmedDraftAttempt], attempt: DraftCreateAttempt,
                              recipient: String, date: Date) -> [UnconfirmedDraftAttempt] {
    switch attempt {
    case .notSent: return previous
    case .succeeded: return []
    case .failed(let error):
        if orderMutationErrorProvesNoEffect(error) { return previous }
        let name = recipient.trimmingCharacters(in: .whitespacesAndNewlines)
        return Array((previous + [UnconfirmedDraftAttempt(recipient: name, date: date)]).suffix(unconfirmedDraftAttemptLimit))
    }
}

/// Where to look for drafts: the Status menu in the Orders toolbar, set to Draft.
let draftCreateCheckDraftsPath = "Orders toolbar › Status › Draft"

/// The composer notice while earlier Create Draft attempts are unconfirmed. Names each attempt's recipient and time, so
/// a composer for a different customer can tell the warning is about someone else's draft.
func draftCreateUnknownNotice(_ attempts: [UnconfirmedDraftAttempt],
                              time: (Date) -> String = draftAttemptTimeText) -> String {
    func describe(_ attempt: UnconfirmedDraftAttempt) -> String {
        attempt.recipient.isEmpty ? "at \(time(attempt.date))" : "for \(attempt.recipient) at \(time(attempt.date))"
    }
    guard let last = attempts.last else { return "" }
    if attempts.count == 1 {
        return "Your Create Draft \(describe(last)) didn’t get a reply from Slant, so that draft may exist. "
            + "Check your drafts (\(draftCreateCheckDraftsPath)) before creating it again."
    }
    let list = attempts.map(describe).joined(separator: "; ")
    return "\(attempts.count) Create Draft attempts didn’t get a reply from Slant (\(list)), so those drafts may exist. "
        + "Check your drafts (\(draftCreateCheckDraftsPath)) before creating them again."
}

/// The Create Anyway confirmation's message.
func draftCreateAnywayMessage(_ attempts: [UnconfirmedDraftAttempt],
                              time: (Date) -> String = draftAttemptTimeText) -> String {
    draftCreateUnknownNotice(attempts, time: time) + (attempts.count > 1
        ? " If this is one of those orders, creating it again makes a second draft."
        : " If this is the same order, creating it again makes a second draft.")
}

/// "2:32 PM" today; with the date for an attempt on an earlier day.
func draftAttemptTimeText(_ date: Date) -> String {
    Calendar.current.isDateInToday(date)
        ? date.formatted(date: .omitted, time: .shortened)
        : date.formatted(date: .abbreviated, time: .shortened)
}

/// The composer's Create Draft needs an explicit "Create Anyway" while an earlier draft's outcome is unknown.
func draftCreateNeedsConfirmation(outcomeUnknown: Bool, confirmed: Bool) -> Bool {
    outcomeUnknown && !confirmed
}

/// The discard prompt mustn't claim nothing was sent once a create request may have reached Slant.
func orderComposerDiscardMessage(outcomeUnknown: Bool) -> String {
    outcomeUnknown
        ? "Your items and delivery details haven’t been saved. Slant may already have created a draft from an earlier attempt; check your drafts (\(draftCreateCheckDraftsPath))."
        : "Your items and delivery details haven’t been saved. Nothing has been sent to Slant."
}

// MARK: - Orders list and detail layout

/// The note under the orders list while searching. Typing filters the loaded orders; Return asks Slant to search all
/// orders, and clearing the box returns to the normal list. Nil when there's nothing to explain.
func orderSearchHint(typed: String, searchActive: Bool) -> String? {
    if searchActive { return "Showing results from all orders. Clear the search to return to the list." }
    guard !typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    return "Showing loaded orders that match. Press Return to search all orders."
}

/// Tracking is shown for orders being made or shipped, and whenever Slant returned tracking details. Drafts, cancelled
/// orders and payment problems have nothing to track, so a "No tracking yet" line would only be noise.
func orderDetailShowsTracking(status: String, hasTrackingDetails: Bool) -> Bool {
    if hasTrackingDetails { return true }
    let normalized = status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return !["DRAFT", "CANCELED", "CANCELLED", "PAYMENT_ERROR"].contains(normalized)
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
        return "New Order Draft"
    }
    return "Duplicate of Order \(number)"
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
