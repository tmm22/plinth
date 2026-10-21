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

/// Countries whose postcode format is unambiguous enough to check locally, with an example for the warning.
private let postcodeFormats: [String: (name: String, pattern: String, example: String)] = [
    "US": ("US ZIP code", #"^\d{5}(-\d{4})?$"#, "12345 or 12345-6789"),
    "CA": ("Canadian postal code", #"^[ABCEGHJ-NPRSTVXY]\d[ABCEGHJ-NPRSTV-Z] ?\d[ABCEGHJ-NPRSTV-Z]\d$"#, "K1A 0B1"),
    "GB": ("UK postcode", #"^(GIR ?0AA|[A-PR-UWYZ][A-HK-Y]?\d[A-Z\d]? ?\d[ABD-HJLNP-UW-Z]{2})$"#, "SW1A 1AA"),
    "AU": ("Australian postcode", #"^\d{4}$"#, "2000"),
    "NZ": ("New Zealand postcode", #"^\d{4}$"#, "6011"),
    "DE": ("German postcode", #"^\d{5}$"#, "10115"),
    "FR": ("French postcode", #"^\d{5}$"#, "75001"),
    "NL": ("Dutch postcode", #"^[1-9]\d{3} ?[A-Z]{2}$"#, "1012 AB"),
    "JP": ("Japanese postal code", #"^\d{3}-?\d{4}$"#, "100-0001"),
    "IE": ("Eircode", #"^([AC-FHKNPRTV-Y]\d{2}|D6W) ?[\dAC-FHKNPRTV-Y]{4}$"#, "D02 X285")
]

/// Country codes with a local postcode format check.
var postcodeCheckedCountryCodes: Set<String> { Set(postcodeFormats.keys) }

/// A gentle warning when a postcode doesn't match the usual format for a handful of countries. Never blocks a draft;
/// empty postcodes (handled by required-field validation) and countries without a known format get no warning.
func postcodeFormatWarning(_ postcode: String, country: String) -> String? {
    let code = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let value = postcode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !value.isEmpty, let format = postcodeFormats[code] else { return nil }
    if value.range(of: format.pattern, options: .regularExpression) != nil { return nil }
    return "This doesn’t look like a \(format.name) (for example \(format.example)). Check it; you can still create the draft."
}

// MARK: - CSV export

let ordersCSVBaseColumns = [
    "Order number", "Created", "Status", "Item count", "Items",
    "Printing cost", "Delivery cost", "Total", "Currency", "Carrier", "Tracking numbers"
]
let ordersCSVAddressColumns = [
    "Recipient", "Email", "Address line 1", "Address line 2", "City", "State", "Postal code", "Country"
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
            csvText(address["city"]), csvText(address["state"]), csvText(address["zip"]), csvText(address["country"])
        ]
    }
    return row
}

/// CSV for the given orders (header row first, CRLF line endings). Recipient, email and address columns are only
/// included when `includeAddresses` is true.
func ordersCSV(_ records: [Record], includeAddresses: Bool) -> String {
    let header = includeAddresses ? ordersCSVBaseColumns + ordersCSVAddressColumns : ordersCSVBaseColumns
    let rows = [header] + records.map { ordersCSVRow($0, includeAddresses: includeAddresses) }
    return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
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
    return includeAddresses ? "\(orders), including recipients and addresses" : orders
}

extension StudioStore {
    /// Writes the given (already loaded) orders to a CSV the user picks. No network requests. Recipient and address
    /// columns are off unless the user ticks the checkbox in the save panel.
    func exportOrdersCSV(_ records: [Record]) {
        guard !records.isEmpty else { return }
        let panel = NSSavePanel()
        panel.title = "Export Orders"
        panel.message = records.count == 1 ? "Exports the order shown in the list." : "Exports the \(records.count) orders shown in the list."
        panel.nameFieldStringValue = ordersCSVDefaultFileName()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        let checkbox = NSButton(checkboxWithTitle: "Include recipient and address", target: nil, action: nil)
        checkbox.state = .off
        let note = NSTextField(wrappingLabelWithString: "Names, emails and addresses are left out unless you include them. The file isn’t protected once saved.")
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 360
        let stack = NSStackView(views: [checkbox, note])
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
