import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Import Orders
//
// Turns a marketplace CSV (Etsy "Sold Order Items", a Shopify orders export or Studio's own template) into Slant order
// DRAFTS for review. Drafts aren't charged: placing an order stays the one-at-a-time charge review in Orders. Drafts
// are created one request at a time, never retried, and the batch stops at the first outcome it can't confirm.
// Imported names, emails and addresses live only in the sheet's memory for the session: never on disk, in
// preferences, logs or Activity (which records counts only).

let orderImportMaxFileBytes = 5 * 1024 * 1024
let orderImportMaxRows = 2_000
let orderImportMaxOrders = 500
/// Generous, so long notes columns in real exports still load; the fields a draft sends have their own limit.
let orderImportMaxCellLength = 20_000
/// Longest name, email or address field sent in a draft.
let orderImportMaxFieldLength = 200
let orderImportMaxColumns = 500
let orderImportMaxSourceIDLength = 100
/// One draft a second at most: a 500-order batch uses no more than 60 of Slant's 100 requests a minute.
let orderImportMinimumSpacing: TimeInterval = 1.0
/// When Slant's headers show this few requests left, wait for the reset before sending the next draft.
let orderImportRateLimitReserve = 10
/// Refusals in a row after which the batch stops instead of spending more requests.
let orderImportMaxConsecutiveRefusals = 5
/// The longest the batch waits for a rate-limit reset before stopping instead.
let orderImportMaxWait: TimeInterval = 300

// MARK: Reading the file

/// Decodes a CSV file's bytes: UTF-8 (with or without a byte order mark), UTF-16 with a byte order mark, otherwise
/// Windows-1252 and then Mac Roman, which older spreadsheet exports use. Refuses files over the size cap and binary data.
func orderImportDecodedText(_ data: Data, maxBytes: Int = orderImportMaxFileBytes) throws -> String {
    guard data.count <= maxBytes else {
        throw StudioError("This file is larger than \(maxBytes / (1024 * 1024)) MB. Import at most \(orderImportMaxOrders) orders at a time.")
    }
    let notText = StudioError("This file isn’t a text CSV file.")
    let head = [UInt8](data.prefix(3))
    if head.starts(with: [0xFF, 0xFE]) || head.starts(with: [0xFE, 0xFF]) {
        guard let text = String(data: data, encoding: .utf16) else { throw notText }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
    let body = head == [0xEF, 0xBB, 0xBF] ? Data(data.dropFirst(3)) : data
    guard !body.contains(0) else { throw notText }
    for encoding in [String.Encoding.utf8, .windowsCP1252, .macOSRoman] {
        if let text = String(data: body, encoding: encoding) {
            return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        }
    }
    throw notText
}

struct OrderImportCSV: Equatable {
    var header: [String]
    var rows: [[String]]
    /// Spreadsheet row number of each data row; the header is row 1 and blank lines still count.
    var rowNumbers: [Int]
}

/// Index of the first scalar after any leading lines made only of spaces and tabs.
private func orderImportFirstNonBlankLine(_ scalars: [Unicode.Scalar], from start: Int = 0) -> Int {
    var lineStart = start
    var index = start
    while index < scalars.count {
        switch scalars[index] {
        case " ", "\t":
            index += 1
        case "\r", "\n":
            index += 1
            lineStart = index
        default:
            return lineStart
        }
    }
    return lineStart
}

/// Excel's `sep=X` first line (optionally quoted), which names the delimiter and isn't part of the data: the delimiter
/// and the index just past that line, or nil when the line at `start` isn't one.
func orderImportSeparatorLine(_ scalars: [Unicode.Scalar], from start: Int = 0) -> (delimiter: Unicode.Scalar, next: Int)? {
    var end = start
    while end < scalars.count, scalars[end] != "\r", scalars[end] != "\n" { end += 1 }
    var line = Array(scalars[start..<end])
    if line.count >= 2, line.first == "\"", line.last == "\"" { line = Array(line.dropFirst().dropLast()) }
    guard line.count == 5, String(String.UnicodeScalarView(line.prefix(4))).lowercased() == "sep=" else { return nil }
    let delimiter = line[4]
    guard delimiter != "\"", delimiter != "\r", delimiter != "\n" else { return nil }
    var next = end
    if next < scalars.count, scalars[next] == "\r" { next += 1 }
    if next < scalars.count, scalars[next] == "\n" { next += 1 }
    return (delimiter, next)
}

/// The delimiter used by the header line (the first line that isn't blank): the most frequent of comma, semicolon and
/// tab outside quotes (comma on a tie).
func orderImportDelimiter(_ scalars: [Unicode.Scalar]) -> Unicode.Scalar {
    var counts: [Unicode.Scalar: Int] = [",": 0, ";": 0, "\t": 0]
    var inQuotes = false
    for scalar in scalars[orderImportFirstNonBlankLine(scalars)...] {
        if scalar == "\"" { inQuotes.toggle(); continue }
        if !inQuotes, scalar == "\n" || scalar == "\r" { break }
        if !inQuotes, counts[scalar] != nil { counts[scalar, default: 0] += 1 }
    }
    let comma = counts[","] ?? 0, semicolon = counts[";"] ?? 0, tab = counts["\t"] ?? 0
    if semicolon > comma, semicolon >= tab { return ";" }
    if tab > comma, tab > semicolon { return "\t" }
    return ","
}

/// RFC 4180 reader: quoted cells may hold delimiters, line breaks and doubled quotes; CRLF and LF both end a row.
/// Header names are trimmed, and blank lines (and rows whose cells are all empty) skipped. An Excel `sep=X` first line
/// sets the delimiter and is dropped, as Excel does. Refuses more than `maxRows` data rows or `maxColumns` columns,
/// cells longer than `maxCellLength` characters and a quoted cell that is never closed.
func parseOrderImportCSV(_ text: String, maxRows: Int = orderImportMaxRows, maxCellLength: Int = orderImportMaxCellLength,
                         maxColumns: Int = orderImportMaxColumns) throws -> OrderImportCSV {
    let scalars = Array(text.unicodeScalars)
    let delimiter: Unicode.Scalar
    var index = 0
    if let separator = orderImportSeparatorLine(scalars, from: orderImportFirstNonBlankLine(scalars)) {
        delimiter = separator.delimiter
        index = separator.next
    } else {
        delimiter = orderImportDelimiter(scalars)
    }
    var records: [[String]] = []
    var numbers: [Int] = []
    var record: [String] = []
    var field = String.UnicodeScalarView()
    var fieldLength = 0
    var inQuotes = false
    var fieldWasQuoted = false
    var recordNumber = 1

    func append(_ scalar: Unicode.Scalar) throws {
        fieldLength += 1
        guard fieldLength <= maxCellLength else {
            throw StudioError("Row \(recordNumber) has a cell longer than \(maxCellLength) characters. This doesn’t look like an orders export.")
        }
        field.append(scalar)
    }
    func endField() throws {
        guard record.count < maxColumns else {
            throw StudioError("Row \(recordNumber) has more than \(maxColumns) columns. This doesn’t look like an orders export.")
        }
        record.append(String(field))
        field = String.UnicodeScalarView()
        fieldLength = 0
        fieldWasQuoted = false
    }
    func endRecord() throws {
        let blank = record.allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !blank {
            records.append(record)
            numbers.append(recordNumber)
            guard records.count <= maxRows + 1 else {
                throw StudioError("This file has more than \(maxRows) rows. Import at most \(orderImportMaxOrders) orders at a time.")
            }
        }
        record = []
        recordNumber += 1
    }

    while index < scalars.count {
        let scalar = scalars[index]
        if inQuotes {
            if scalar == "\"" {
                if index + 1 < scalars.count, scalars[index + 1] == "\"" {
                    try append("\"")
                    index += 2
                    continue
                }
                inQuotes = false
            } else {
                try append(scalar)
            }
            index += 1
            continue
        }
        switch scalar {
        case "\"" where fieldLength == 0 && !fieldWasQuoted:
            inQuotes = true
            fieldWasQuoted = true
        case delimiter:
            try endField()
        case "\r", "\n":
            if scalar == "\r", index + 1 < scalars.count, scalars[index + 1] == "\n" { index += 1 }
            try endField()
            try endRecord()
        default:
            try append(scalar)
        }
        index += 1
    }
    if inQuotes { throw StudioError("A quoted cell that starts on row \(recordNumber) is never closed. Check the file in a spreadsheet app.") }
    if fieldLength > 0 || fieldWasQuoted || !record.isEmpty {
        try endField()
        try endRecord()
    }
    guard let header = records.first else { throw StudioError("This file is empty.") }
    return OrderImportCSV(
        header: header.map { $0.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))) },
        rows: Array(records.dropFirst()),
        rowNumbers: Array(numbers.dropFirst())
    )
}

// MARK: Formats

enum OrderImportFormat: String, Equatable, CaseIterable {
    case etsy
    case shopify
    /// Studio's own template. The raw value is what drafts record as their `source` metadata.
    case template = "csv"

    var title: String {
        switch self {
        case .etsy: return "Etsy Sold Order Items"
        case .shopify: return "Shopify orders export"
        case .template: return "Studio template"
        }
    }
    var marketplace: String {
        switch self {
        case .etsy: return "Etsy"
        case .shopify: return "Shopify"
        case .template: return "CSV"
        }
    }
}

enum OrderImportField: String, CaseIterable {
    case orderID, name, email, line1, line2, city, state, zip, country, sku, quantity, itemName, company
    case dateShipped, fulfillmentStatus, cancelledAt, financialStatus
    /// Etsy's "Variations" and a dedicated personalisation column: shown in the preview only (see Personalisation).
    case variations, personalisation
    /// What the buyer paid (ImportedSaleAmounts.swift): read for the Profit check, never sent in a draft.
    case saleCurrency, salePrice, saleItemTotal, saleDiscount, saleShipping, saleShippingDiscount
    case saleSubtotal, saleTaxes, saleTotal, saleRefunded
}

struct OrderImportFormatSpec {
    let format: OrderImportFormat
    /// Any of these headers identifies the format.
    let signature: [String]
    /// Accepted header names per field; the first is the one shown in messages.
    let columns: [OrderImportField: [String]]
    let required: [OrderImportField]
}

let orderImportTemplateHeader = ["order_id", "name", "email", "line1", "line2", "city", "state", "zip", "country", "sku", "quantity"]

/// Checked in this order: Shopify and Etsy files have distinctive headers; the template is the fallback.
let orderImportFormatSpecs: [OrderImportFormatSpec] = [
    OrderImportFormatSpec(
        format: .shopify, signature: ["Lineitem quantity", "Lineitem sku"],
        columns: [
            .orderID: ["Name"], .email: ["Email"], .quantity: ["Lineitem quantity"], .sku: ["Lineitem sku"],
            .itemName: ["Lineitem name"], .name: ["Shipping Name"], .line1: ["Shipping Address1"],
            .line2: ["Shipping Address2"], .city: ["Shipping City"], .zip: ["Shipping Zip"],
            .state: ["Shipping Province"], .country: ["Shipping Country"], .company: ["Shipping Company"],
            .fulfillmentStatus: ["Fulfillment Status"], .cancelledAt: ["Cancelled at"], .financialStatus: ["Financial Status"],
            .saleCurrency: ["Currency"], .saleSubtotal: ["Subtotal"], .saleShipping: ["Shipping"], .saleTaxes: ["Taxes"],
            .saleTotal: ["Total"], .saleDiscount: ["Discount Amount"], .saleRefunded: ["Refunded Amount"]
        ],
        required: [.orderID, .quantity, .sku, .name, .line1, .city, .zip, .country]
    ),
    OrderImportFormatSpec(
        format: .etsy, signature: ["Ship Name", "Ship Address1"],
        columns: [
            .orderID: ["Order ID"], .name: ["Ship Name"], .line1: ["Ship Address1"], .line2: ["Ship Address2"],
            .city: ["Ship City"], .state: ["Ship State"], .zip: ["Ship Zipcode", "Ship Zip", "Ship Postal Code"],
            .country: ["Ship Country"], .sku: ["SKU"], .quantity: ["Quantity"], .itemName: ["Item Name"],
            .dateShipped: ["Date Shipped"],
            .variations: ["Variations"], .personalisation: orderImportPersonalisationColumns,
            .saleCurrency: ["Currency"], .salePrice: ["Price"], .saleItemTotal: ["Item Total"],
            .saleDiscount: ["Discount Amount"], .saleShipping: ["Order Shipping"], .saleShippingDiscount: ["Shipping Discount"]
        ],
        required: [.orderID, .name, .line1, .city, .zip, .country, .sku, .quantity]
    ),
    OrderImportFormatSpec(
        format: .template, signature: ["order_id"],
        columns: [
            .orderID: ["order_id"], .name: ["name", "recipient"], .email: ["email"],
            .line1: ["line1", "address1", "address_line1"], .line2: ["line2", "address2", "address_line2"],
            .city: ["city"], .state: ["state", "province"], .zip: ["zip", "postcode", "postal_code", "zipcode"],
            .country: ["country"], .sku: ["sku"], .quantity: ["quantity", "qty"],
            .personalisation: orderImportPersonalisationColumns
        ],
        required: [.orderID, .name, .line1, .city, .zip, .country, .sku, .quantity]
    )
]

/// Header names compared ignoring case, spaces, underscores and punctuation.
func orderImportHeaderKey(_ name: String) -> String {
    String(name.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
}

struct OrderImportLayout: Equatable {
    let format: OrderImportFormat
    let columns: [OrderImportField: Int]
}

/// Recognises the file by its headers. A recognised format missing a required column, and unrecognised headers, get a
/// message listing what is expected. There is no column mapping.
func orderImportLayout(header: [String]) throws -> OrderImportLayout {
    var positions: [String: Int] = [:]
    for (index, name) in header.enumerated() {
        let key = orderImportHeaderKey(name)
        if !key.isEmpty, positions[key] == nil { positions[key] = index }
    }
    for spec in orderImportFormatSpecs where spec.signature.contains(where: { positions[orderImportHeaderKey($0)] != nil }) {
        var columns: [OrderImportField: Int] = [:]
        for (field, names) in spec.columns {
            if let index = names.lazy.compactMap({ positions[orderImportHeaderKey($0)] }).first { columns[field] = index }
        }
        let missing = spec.required.filter { columns[$0] == nil }.compactMap { spec.columns[$0]?.first }
        if !missing.isEmpty {
            var message = "This looks like a \(spec.format.title) file, but it’s missing: \(missing.joined(separator: ", "))."
            if spec.format == .etsy {
                message += " Download “Sold Order Items” (not “Sold Orders”) from Etsy’s Shop Manager › Settings › Options › Download Data."
            }
            throw StudioError(message)
        }
        return OrderImportLayout(format: spec.format, columns: columns)
    }
    throw StudioError("Studio couldn’t recognise this file’s columns. It reads Etsy “Sold Order Items” CSV files, Shopify order exports and Studio’s template (\(orderImportTemplateHeader.joined(separator: ", "))). Use Save Template… for an example.")
}

// MARK: Orders

struct OrderImportItem: Equatable {
    var sku: String
    var quantityText: String
    var itemName: String
    var row: Int
    /// The buyer's personalisation text (Personalisation.swift), shown in the preview with Copy. Memory only: never
    /// sent in a draft, saved or logged.
    var personalisation = ""
    /// The marketplace's full options text, shown beside the personalisation when it holds other options too.
    var options = ""
}

struct OrderImportOrder: Identifiable, Equatable {
    var id: String { OrderImportLedger.key(source: source, sourceOrderID: sourceOrderID) }
    let source: OrderImportFormat
    let sourceOrderID: String
    var rows: [Int] = []
    var name = ""
    var email = ""
    var line1 = ""
    var line2 = ""
    var city = ""
    var state = ""
    var zip = ""
    /// The country as written in the file.
    var country = ""
    /// The ISO code the country resolves to, or empty when it isn't recognised. Never assumed.
    var countryCode = ""
    var company = ""
    var items: [OrderImportItem] = []
    /// Delivery fields whose value differs between rows of this order.
    var conflictingFields: [String] = []
    /// Rows with delivery details that repeat an earlier row of this order cell for cell, as when two exports are
    /// combined. Rows without delivery details (Shopify's extra item rows) never count.
    var repeatedRows: [Int] = []
    /// Why the marketplace shows this order as already shipped, cancelled or refunded.
    var alreadyHandled: String?
    /// HTML character references (as Etsy exports them) were decoded in the name or address.
    var decodedEntities = false
    /// The sale columns of each row that has them (ImportedSaleAmounts.swift). Memory only.
    var saleRows: [OrderImportSaleRow] = []
}

struct OrderImportParse: Equatable {
    let format: OrderImportFormat
    var orders: [OrderImportOrder]
    var notices: [String] = []
}

/// Delivery fields merged across an order's rows, with their names for conflict messages.
private let orderImportDeliveryFields: [(field: OrderImportField, label: String, keyPath: WritableKeyPath<OrderImportOrder, String>)] = [
    (.name, "recipient name", \.name), (.email, "email", \.email), (.line1, "address line 1", \.line1),
    (.line2, "address line 2", \.line2), (.city, "city", \.city), (.state, "state", \.state), (.zip, "postcode", \.zip),
    (.country, "country", \.country), (.company, "company", \.company)
]

/// Groups rows into orders by order ID, in the order IDs first appear. Order-level fields come from the first row that
/// has them, so Shopify's extra line-item rows (blank order-level fields) inherit them; a later row with a different
/// non-blank value is recorded as a conflict rather than guessed between.
func orderImportOrders(from csv: OrderImportCSV, layout: OrderImportLayout, maxOrders: Int = orderImportMaxOrders) throws -> OrderImportParse {
    var orders: [OrderImportOrder] = []
    var positions: [String: Int] = [:]
    var seenRows: [String: Set<String>] = [:]
    var rowsWithoutID = 0
    for (rowIndex, row) in csv.rows.enumerated() {
        func value(_ field: OrderImportField) -> String {
            guard let column = layout.columns[field], column < row.count else { return "" }
            return row[column].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let rowNumber = rowIndex < csv.rowNumbers.count ? csv.rowNumbers[rowIndex] : rowIndex + 2
        let sourceID = value(.orderID)
        guard !sourceID.isEmpty else {
            if row.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { rowsWithoutID += 1 }
            continue
        }
        let position: Int
        if let existing = positions[sourceID] {
            position = existing
        } else {
            guard orders.count < maxOrders else {
                throw StudioError("This file has more than \(maxOrders) orders. Import at most \(maxOrders) at a time.")
            }
            orders.append(OrderImportOrder(source: layout.format, sourceOrderID: sourceID))
            position = orders.count - 1
            positions[sourceID] = position
        }
        var order = orders[position]
        order.rows.append(rowNumber)
        // Only rows that carry the order's shipping details can show an overlapping export: Shopify's follow-on item
        // rows leave them blank, and two of those can legitimately be identical (the same SKU twice in one order).
        // A combined export repeats each order's first row, which always carries them. Email isn't counted, as some
        // exports repeat it on every row.
        if orderImportDeliveryFields.contains(where: { $0.field != .email && !value($0.field).isEmpty }) {
            let fingerprint = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.joined(separator: "\u{1F}")
            if seenRows[sourceID, default: []].insert(fingerprint).inserted == false { order.repeatedRows.append(rowNumber) }
        }
        for entry in orderImportDeliveryFields {
            let incoming = value(entry.field)
            guard !incoming.isEmpty else { continue }
            let current = order[keyPath: entry.keyPath]
            if current.isEmpty {
                order[keyPath: entry.keyPath] = incoming
            } else if orderImportComparable(current) != orderImportComparable(incoming), !order.conflictingFields.contains(entry.label) {
                order.conflictingFields.append(entry.label)
            }
        }
        let sku = value(.sku), quantity = value(.quantity), itemName = value(.itemName)
        if !sku.isEmpty || !quantity.isEmpty || !itemName.isEmpty {
            var item = OrderImportItem(sku: sku, quantityText: quantity, itemName: itemName, row: rowNumber)
            item.options = orderImportDecodingHTMLEntities(value(.variations))
            item.personalisation = orderImportPersonalisation(options: item.options,
                                                              column: orderImportDecodingHTMLEntities(value(.personalisation)))
            order.items.append(item)
        }
        if let sale = orderImportSaleRow(value) { order.saleRows.append(sale) }
        if order.alreadyHandled == nil {
            order.alreadyHandled = orderImportAlreadyHandledReason(
                format: layout.format, dateShipped: value(.dateShipped), fulfillmentStatus: value(.fulfillmentStatus),
                cancelledAt: value(.cancelledAt), financialStatus: value(.financialStatus))
        }
        orders[position] = order
    }
    guard !orders.isEmpty else { throw StudioError("This file has no orders.") }
    for index in orders.indices {
        var order = orders[index]
        for keyPath in [\OrderImportOrder.name, \.line1, \.line2, \.city] {
            let decoded = orderImportDecodingHTMLEntities(order[keyPath: keyPath])
            if decoded != order[keyPath: keyPath] { order[keyPath: keyPath] = decoded; order.decodedEntities = true }
        }
        // Spreadsheet exports (Shopify among them) keep leading zeros by prefixing the postcode with an apostrophe.
        if order.zip.hasPrefix("'") { order.zip = String(order.zip.dropFirst()).trimmingCharacters(in: .whitespaces) }
        order.countryCode = orderImportCountryCode(order.country)
        orders[index] = order
    }
    var notices: [String] = []
    if rowsWithoutID > 0 {
        notices.append(rowsWithoutID == 1 ? "1 row without an order ID was ignored." : "\(rowsWithoutID) rows without an order ID were ignored.")
    }
    return OrderImportParse(format: layout.format, orders: orders, notices: notices)
}

/// Reads, recognises and groups a file in one step.
func orderImportParse(data: Data) throws -> OrderImportParse {
    let csv = try parseOrderImportCSV(try orderImportDecodedText(data))
    let layout = try orderImportLayout(header: csv.header)
    return try orderImportOrders(from: csv, layout: layout)
}

private func orderImportComparable(_ value: String) -> String {
    value.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
}

/// Why the marketplace already shows this order as done: Etsy's Date Shipped, or Shopify's fulfillment, cancellation
/// and refund columns. These orders aren't ticked by default.
func orderImportAlreadyHandledReason(format: OrderImportFormat, dateShipped: String, fulfillmentStatus: String,
                                     cancelledAt: String, financialStatus: String) -> String? {
    switch format {
    case .etsy:
        return dateShipped.isEmpty ? nil : "Etsy shows this order as shipped."
    case .shopify:
        if !cancelledAt.isEmpty { return "Shopify shows this order as cancelled." }
        let financial = financialStatus.lowercased()
        if financial == "refunded" { return "Shopify shows this order as refunded." }
        if financial == "voided" { return "Shopify shows this order’s payment as voided." }
        if fulfillmentStatus.lowercased() == "fulfilled" { return "Shopify shows this order as fulfilled." }
        return nil
    case .template:
        return nil
    }
}

/// Country names that aren't a region's exact name in English or the Mac's language.
private let orderImportCountryAliases: [String: String] = [
    "usa": "US", "u.s.a.": "US", "u.s.": "US", "united states of america": "US",
    "uk": "GB", "u.k.": "GB", "great britain": "GB"
]

/// ISO code for a country written as a code or a country name, or empty when it isn't recognised. Never assumes US.
func orderImportCountryCode(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    if let alias = orderImportCountryAliases[trimmed.lowercased()] { return alias }
    let selection = orderCountrySelection(fromAddressCountry: trimmed)
    return selection.selection == orderCountryOtherTag ? selection.customCode : selection.selection
}

/// Decodes the HTML character references Etsy writes into names and addresses (`&#39;`, `&amp;` and so on).
/// References to control characters, and anything else, are left as written.
func orderImportDecodingHTMLEntities(_ text: String) -> String {
    guard text.contains("&"),
          let regex = try? NSRegularExpression(pattern: #"&(#[0-9]{1,7}|#[xX][0-9A-Fa-f]{1,6}|amp|quot|apos|lt|gt|nbsp);"#) else { return text }
    let source = text as NSString
    var result = ""
    var location = 0
    for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
        result += source.substring(with: NSRange(location: location, length: match.range.location - location))
        let name = source.substring(with: match.range(at: 1))
        result += orderImportEntityValue(name) ?? source.substring(with: match.range)
        location = match.range.location + match.range.length
    }
    return result + source.substring(from: location)
}

private func orderImportEntityValue(_ name: String) -> String? {
    switch name {
    case "amp": return "&"
    case "quot": return "\""
    case "apos": return "'"
    case "lt": return "<"
    case "gt": return ">"
    case "nbsp": return " "
    default:
        let number: UInt32?
        if name.hasPrefix("#x") || name.hasPrefix("#X") { number = UInt32(name.dropFirst(2), radix: 16) }
        else { number = UInt32(name.dropFirst()) }
        guard let number, number >= 0x20, !(0x7F...0x9F).contains(number), let scalar = Unicode.Scalar(number) else { return nil }
        return String(Character(scalar))
    }
}

/// A whole number of units from 1 to 10,000; anything else (decimals, signs, words) is refused.
func orderImportQuantity(_ text: String) -> Int? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.count <= 5, trimmed.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
          let value = Int(trimmed), (1...10_000).contains(value) else { return nil }
    return value
}

/// A US ZIP that lost its leading zeros in a spreadsheet (3 or 4 digits, optionally with +4), padded back to five
/// digits. Nil for anything else. Only applied when the user chooses it for that order.
func orderImportPaddedUSZIP(_ zip: String) -> String? {
    let trimmed = zip.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.range(of: #"^\d{3,4}(-\d{4})?$"#, options: .regularExpression) != nil else { return nil }
    let parts = trimmed.split(separator: "-", maxSplits: 1).map(String.init)
    let head = String(repeating: "0", count: 5 - parts[0].count) + parts[0]
    return parts.count == 2 ? "\(head)-\(parts[1])" : head
}

/// The metadata each imported draft carries, so later imports can recognise it. Two of Slant's ten fields, plus the
/// draft marker (`studioDraftId`, DraftConfirmation.swift) on the body actually sent.
func orderImportMetadata(source: OrderImportFormat, sourceOrderID: String, draftMarker: String? = nil) -> [String: Any] {
    let metadata: [String: Any] = ["source": source.rawValue, "sourceOrderId": sourceOrderID.trimmingCharacters(in: .whitespacesAndNewlines)]
    guard let draftMarker else { return metadata }
    return orderMetadataAddingDraftMarker(metadata, marker: draftMarker)
}

// MARK: Duplicate protection

struct OrderImportDraftMarker: Equatable {
    let marker: String
    let platformID: String
}

/// Source orders imported this session. Memory only: never written to disk, and cleared when the account changes.
struct OrderImportLedger: Equatable {
    enum Entry: Equatable {
        case created(orderID: String)
        /// The draft request's outcome wasn't confirmed; it may have been created.
        case unknown
    }
    private(set) var entries: [String: Entry] = [:]
    /// For `.unknown` entries, the marker their draft was sent with and its platform, so Check Slant can look for it
    /// (DraftConfirmation.swift). Keyed like `entries`.
    private(set) var unconfirmedMarkers: [String: OrderImportDraftMarker] = [:]

    static func key(source: OrderImportFormat, sourceOrderID: String) -> String {
        "\(source.rawValue)|\(sourceOrderID.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
    mutating func record(_ entry: Entry, source: OrderImportFormat, sourceOrderID: String,
                         marker: String? = nil, platformID: String = "") {
        let key = Self.key(source: source, sourceOrderID: sourceOrderID)
        entries[key] = entry
        if entry == .unknown, let marker {
            unconfirmedMarkers[key] = OrderImportDraftMarker(marker: marker, platformID: platformID)
        } else {
            unconfirmedMarkers[key] = nil
        }
    }
    /// Check Slant found the draft of an unconfirmed import: it was created, as `orderID`.
    mutating func confirm(key: String, orderID: String) {
        guard entries[key] == .unknown, !orderID.isEmpty else { return }
        entries[key] = .created(orderID: orderID)
        unconfirmedMarkers[key] = nil
    }
    func entry(source: OrderImportFormat, sourceOrderID: String) -> Entry? {
        entries[Self.key(source: source, sourceOrderID: sourceOrderID)]
    }
}

/// The rows of the shown list that a ledger key belongs to, so a draft confirmed by its ledger key shows as created
/// on its row (row IDs needn't stay the same as ledger keys).
func orderImportRowIDs(forLedgerKey key: String, in orders: [OrderImportOrder]) -> [String] {
    orders.filter { OrderImportLedger.key(source: $0.source, sourceOrderID: $0.sourceOrderID) == key }.map(\.id)
}

/// Ledger keys for loaded orders whose metadata names an imported source order. Slant may not return metadata in the
/// list; then nothing matches and only the session ledger protects against duplicates. Metadata without a `source`
/// matches that order ID from any source.
func orderImportLoadedSourceKeys(_ orders: [Record]) -> Set<String> {
    var keys = Set<String>()
    for record in orders {
        guard let metadata = orderObject(record.values)["metadata"] as? [String: Any],
              let rawID = metadata["sourceOrderId"] else { continue }
        let id = (rawID as? String ?? String(describing: rawID)).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { continue }
        let source = ((metadata["source"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let format = OrderImportFormat(rawValue: source) {
            keys.insert(OrderImportLedger.key(source: format, sourceOrderID: id))
        } else if source.isEmpty {
            for format in OrderImportFormat.allCases { keys.insert(OrderImportLedger.key(source: format, sourceOrderID: id)) }
        }
    }
    return keys
}

/// Why this source order might already have a draft, or nil.
func orderImportDuplicateReason(_ order: OrderImportOrder, ledger: OrderImportLedger, loadedKeys: Set<String>) -> String? {
    switch ledger.entry(source: order.source, sourceOrderID: order.sourceOrderID) {
    case .created(let orderID)?:
        return orderImportAlreadyImportedWarning(orderID)
    case .unknown?:
        return "An earlier import of this order didn’t confirm and may have been created. Check your drafts (Show Drafts, or Orders toolbar › Status › Draft) before importing it again."
    case nil:
        break
    }
    if loadedKeys.contains(order.id) {
        return "An order in the loaded list was already imported from this \(order.source.marketplace) order."
    }
    return nil
}

func orderImportAlreadyImportedWarning(_ orderID: String) -> String {
    "Already imported this session as draft \(orderID)."
}

/// A row's warnings as shown. A row this sheet has just created a draft for already says "Draft created", so the
/// ledger's "Already imported … as draft" warning for that same draft is left out. It still shows when the file is
/// chosen again (results reset) or for any other draft ID, so the duplicate check is unchanged.
func orderImportVisibleWarnings(_ warnings: [String], rowState: OrderImportRowState?) -> [String] {
    guard case .created(let orderID)? = rowState else { return warnings }
    let own = orderImportAlreadyImportedWarning(orderID)
    return warnings.filter { $0 != own }
}

/// Whether one of the import sheet's collapsible sections (Match products, Personalise with OpenSCAD) is open: as the
/// seller last left it, or, until they open or close it, only while it needs a choice.
func orderImportSectionExpanded(userChoice: Bool?, needsInput: Bool) -> Bool {
    userChoice ?? needsInput
}

/// Match products' disclosure label, saying whether choices are still needed.
func orderImportMatchProductsTitle(keys: Int, unchosen: Int) -> String {
    guard keys > 0 else { return "Match products" }
    if unchosen == 0 { return "Match products · all chosen" }
    return "Match products · \(unchosen) of \(keys) to choose"
}

/// The import sheet before a file is chosen.
let orderImportEmptyHint = "Choose a CSV file to check its orders here. Nothing is sent to Slant until you confirm."

/// The Create button's title; "Create Drafts" while nothing is ready (before a file is chosen or after a run).
func orderImportCreateButtonTitle(_ count: Int) -> String {
    switch count {
    case ...0: return "Create Drafts"
    case 1: return "Create 1 Draft"
    default: return "Create \(count) Drafts"
    }
}

/// Shown when the duplicate check can't see every earlier order.
func orderImportDuplicateCoverageNotice(ordersLoaded: Bool, ordersHasMore: Bool, listIsPartial: Bool) -> String? {
    if !ordersLoaded {
        return "Orders aren’t loaded, so only this session’s imports are checked for duplicates."
    }
    if ordersHasMore || listIsPartial {
        return "Only the orders loaded in the list (and this session’s imports) are checked for duplicates. Older orders, and orders hidden by search or filters, aren’t."
    }
    return nil
}

// MARK: Matching items to saved products

/// Identifies an imported item that no saved product matches by SKU, so the user can choose a product for it in
/// Match products: its SKU, or its item name (Etsy “Item Name”, Shopify “Lineitem name”) when the SKU is blank.
struct OrderImportMatchKey: Equatable, Identifiable {
    enum Kind: Equatable { case sku, itemName }
    let kind: Kind
    /// SKUs compare ignoring case and surrounding spaces; names also ignore repeated spaces.
    let normalized: String
    /// As first written in the file.
    let display: String
    /// Orders with at least one item under this key.
    var orderCount = 0
    var id: String { "\(kind == .sku ? "sku" : "name")|\(normalized)" }
}

/// The match key for an item: its SKU when it has one, else its item name; nil when it has neither.
func orderImportMatchKey(for item: OrderImportItem) -> OrderImportMatchKey? {
    let sku = item.sku.trimmingCharacters(in: .whitespacesAndNewlines)
    if !sku.isEmpty { return OrderImportMatchKey(kind: .sku, normalized: normalizedSKU(sku), display: sku) }
    let name = item.itemName.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    guard !name.isEmpty else { return nil }
    return OrderImportMatchKey(kind: .itemName, normalized: name.lowercased(), display: name)
}

/// What the user chose in Match products for one key. Held only in the sheet's memory: never saved, and dropped
/// when another file is chosen or the sheet closes. Never guessed: nothing is matched without a choice.
enum OrderImportProductChoice: Hashable {
    case product(UUID)
    /// Leave items under this key out of the drafts (for example Shopify's shipping protection or tips).
    case leaveOut
}

/// Every distinct key of an item no saved product matches by SKU, in the order they first appear.
func orderImportUnmatchedKeys(_ orders: [OrderImportOrder], products: [SavedProduct]) -> [OrderImportMatchKey] {
    var keys: [OrderImportMatchKey] = []
    var positions: [String: Int] = [:]
    for order in orders {
        var counted = Set<String>()
        for item in order.items where savedProduct(forSKU: item.sku, in: products) == nil {
            guard let key = orderImportMatchKey(for: item) else { continue }
            let position: Int
            if let existing = positions[key.id] {
                position = existing
            } else {
                keys.append(key)
                position = keys.count - 1
                positions[key.id] = position
            }
            if counted.insert(key.id).inserted { keys[position].orderCount += 1 }
        }
    }
    return keys
}

/// The SKUs among `keys`, for a one-line summary the seller can copy, e.g. "2 SKUs have no saved product: A, B".
func orderImportMissingSKUs(_ keys: [OrderImportMatchKey]) -> [String] {
    keys.filter { $0.kind == .sku }.map(\.display)
}

func orderImportMissingSKUSummary(_ skus: [String]) -> String? {
    guard !skus.isEmpty else { return nil }
    return "\(skus.count == 1 ? "1 SKU has" : "\(skus.count) SKUs have") no saved product: \(skus.joined(separator: ", "))"
}

/// Orders whose checks a new choice unblocked and that would be ticked on loading: these are ticked for the user.
func orderImportNewlyTickable(before: [String: OrderImportCheck], after: [String: OrderImportCheck]) -> Set<String> {
    Set(after.compactMap { id, check in
        before[id]?.canTick == false && check.tickedByDefault ? id : nil
    })
}

// MARK: Checking an order

struct OrderImportContext {
    var products: [SavedProduct]
    var localModels: [LocalModel] = []
    var filaments: [Record] = []
    var components: [Record] = []
    var stationery: [Record] = []
    var platformID: String
    var ownerID: String = ""
    var fallbackEmail: String = ""
    var ledger = OrderImportLedger()
    var loadedKeys: Set<String> = []
    /// Match products choices, keyed by `OrderImportMatchKey.id`. Used only for items no saved product matches by SKU.
    var productChoices: [String: OrderImportProductChoice] = [:]
}

struct OrderImportCheck {
    /// Problems that stop this order being imported; it can't be ticked while any remain.
    var blockers: [String] = []
    /// Reasons to look twice; the order is unticked by default but can be ticked.
    var warnings: [String] = []
    var notes: [String] = []
    var itemsSummary = ""
    var lines: [OrderLine] = []
    /// The exact `POST /orders` body, built only through `orderDraftPayload`. Nil while any blocker remains.
    var body: [String: Any]?
    /// The only blocker is the empty "Email for orders without one" field.
    var waitingForEmail = false
    /// A zero-padded ZIP the user may choose for this order.
    var paddedZIP: String?
    /// The email this draft uses comes from "Email for orders without one".
    var usesFallbackEmail = false
    /// At least one item was matched, or left out, by a Match products choice.
    var usesProductChoice = false
    /// Items left out of the draft by a Match products choice, so the buyer's item total covers more than the draft.
    var leftOutItemCount = 0
    /// Parallel to the order's items: the saved product each was drafted with (nil when left out or unmatched).
    var itemProductIDs: [UUID?] = []
    /// Parallel to `lines`: the saved product and item each line came from (batch personalisation).
    var lineSources: [OrderImportLineSource?] = []
    /// The email and postcode the draft uses, so a personalised draft is built the same way.
    var draftEmail = ""
    var draftZIP = ""

    var canTick: Bool { blockers.isEmpty }
    var tickedByDefault: Bool { (blockers.isEmpty || waitingForEmail) && warnings.isEmpty }
}

struct OrderImportLineSource: Equatable {
    let productID: UUID
    let savedLineID: UUID
}

/// Everything the preview says about one order, and the draft body when it can be imported. `padZIP` applies the
/// zero-padded US ZIP the user chose for this order. `draftMarker` (only for the body actually sent) is added to its
/// metadata as `studioDraftId`.
func orderImportCheck(_ order: OrderImportOrder, context: OrderImportContext, padZIP: Bool = false,
                      draftMarker: String? = nil) -> OrderImportCheck {
    var check = OrderImportCheck()
    func block(_ text: String) { if !check.blockers.contains(text) { check.blockers.append(text) } }
    func warn(_ text: String) { if !check.warnings.contains(text) { check.warnings.append(text) } }
    func note(_ text: String) { if !check.notes.contains(text) { check.notes.append(text) } }

    if order.sourceOrderID.count > orderImportMaxSourceIDLength {
        block("The order ID is longer than \(orderImportMaxSourceIDLength) characters.")
    }
    if !order.repeatedRows.isEmpty {
        let rows = order.repeatedRows.map(String.init).joined(separator: ", ")
        block("Row\(order.repeatedRows.count == 1 ? "" : "s") \(rows) repeat\(order.repeatedRows.count == 1 ? "s" : "") an earlier row of this order exactly. Check the file wasn’t combined from overlapping exports.")
    }
    if !order.conflictingFields.isEmpty {
        block("Rows for this order have a different \(order.conflictingFields.joined(separator: ", ")). Fix the file so every row of an order has the same delivery details.")
    }

    // Items. Each row is matched to a saved product by SKU, else by the user's Match products choice. Units are summed
    // per product so each product resolves once (once-per-order lines are added once, and the 10,000 cap applies to
    // the total), and a once-per-order line that several products share is added once.
    enum SummaryEntry { case product(UUID), text(String) }
    var entries: [SummaryEntry] = []
    var groups: [UUID: (product: SavedProduct, units: Int)] = [:]
    var groupOrder: [UUID] = []
    var leftOut = 0
    var personalisedItemIncluded = false
    if order.items.isEmpty { block("This order has no items.") }
    check.itemProductIDs = Array(repeating: nil, count: order.items.count)
    for (itemIndex, item) in order.items.enumerated() {
        let sku = item.sku.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = sku.isEmpty ? (item.itemName.isEmpty ? "item on row \(item.row)" : "“\(item.itemName)”") : sku
        var product = savedProduct(forSKU: sku, in: context.products)
        if product == nil, let key = orderImportMatchKey(for: item), let choice = context.productChoices[key.id] {
            switch choice {
            case .leaveOut:
                check.usesProductChoice = true
                leftOut += 1
                note("\(sku.isEmpty ? "The \(label)" : "SKU \(sku)") is left out of the draft, as you chose.")
                continue
            case .product(let id):
                if let chosen = context.products.first(where: { $0.id == id }) {
                    product = chosen
                    check.usesProductChoice = true
                    note("\(sku.isEmpty ? "The \(label)" : "SKU \(sku)") uses “\(savedProductDisplayName(chosen))”, as you chose.")
                }
            }
        }
        // Drafts carry no personalisation: a personalised item (not left out) is drafted as the plain model.
        if !item.personalisation.isEmpty { personalisedItemIncluded = true }
        guard let units = orderImportQuantity(item.quantityText) else {
            block("Quantity “\(item.quantityText)” for \(label.hasPrefix("item on row") ? "the \(label)" : label) isn’t a whole number from 1 to 10,000.")
            entries.append(.text("? × \(label)"))
            continue
        }
        guard let product else {
            if !sku.isEmpty {
                block("No saved product has SKU \(sku). Choose one under Match products, or add it in Saved Products.")
            } else if item.itemName.isEmpty {
                block("The \(label) has no SKU or name. Add the SKU in your shop, or create this draft by hand.")
            } else {
                block("The \(label) has no SKU. Choose a saved product for it under Match products, or add the SKU in your shop.")
            }
            entries.append(.text("\(units) × \(label)"))
            continue
        }
        check.itemProductIDs[itemIndex] = product.id
        if groups[product.id] == nil {
            groups[product.id] = (product, 0)
            groupOrder.append(product.id)
            entries.append(.product(product.id))
        }
        groups[product.id]?.units += units
    }
    check.leftOutItemCount = leftOut
    if !order.items.isEmpty, leftOut == order.items.count {
        block("Every item of this order is left out, so there’s nothing to draft.")
    }
    // A warning, so the order starts unticked; the seller may still tick it deliberately.
    if personalisedItemIncluded { warn(orderImportPlainModelWarning) }
    var lines: [OrderLine] = []
    var perOrderLineIndex: [String: Int] = [:]
    var groupLineIndices: [UUID: [Int]] = [:]
    var groupResolved: Set<UUID> = []
    for id in groupOrder {
        guard let group = groups[id] else { continue }
        let name = savedProductDisplayName(group.product)
        guard group.units <= 10_000 else {
            block("This order has more than 10,000 units of “\(name)” in total.")
            continue
        }
        let resolution = savedProductOrderLines(group.product, units: group.units, localModels: context.localModels,
                                                filaments: context.filaments, components: context.components,
                                                stationery: context.stationery)
        resolution.blockers.forEach(block)
        resolution.notes.forEach(note)
        guard resolution.blockers.isEmpty else { continue }
        groupResolved.insert(id)
        for (index, line) in resolution.lines.enumerated() {
            if index < resolution.perOrder.count, resolution.perOrder[index] {
                let key = orderImportPerOrderLineKey(line)
                if let existing = perOrderLineIndex[key] {
                    lines[existing].quantity = max(lines[existing].quantity, line.quantity)
                    continue
                }
                perOrderLineIndex[key] = lines.count
            }
            groupLineIndices[id, default: []].append(lines.count)
            lines.append(line)
            check.lineSources.append(index < group.product.lines.count
                ? OrderImportLineSource(productID: id, savedLineID: group.product.lines[index].id) : nil)
        }
    }
    check.lines = lines
    check.itemsSummary = entries.flatMap { entry -> [String] in
        switch entry {
        case .text(let text):
            return [text]
        case .product(let id):
            guard let group = groups[id] else { return [] }
            guard groupResolved.contains(id) else { return ["\(group.units) × \(savedProductDisplayName(group.product))"] }
            return (groupLineIndices[id] ?? []).map {
                "\(lines[$0].quantity) × \(savedProductOrderLineTitle(lines[$0], localModels: context.localModels, components: context.components, stationery: context.stationery))"
            }
        }
    }.joined(separator: ", ")

    // Delivery
    let missing = [("recipient name", order.name), ("address line 1", order.line1), ("city", order.city), ("postcode", order.zip)]
        .filter { $0.1.isEmpty }.map(\.0)
    if !missing.isEmpty { block("Missing \(missing.joined(separator: ", ")).") }
    let tooLong = [("recipient name", order.name), ("email", order.email), ("address line 1", order.line1),
                   ("address line 2", order.line2), ("city", order.city), ("state", order.state), ("postcode", order.zip)]
        .filter { $0.1.count > orderImportMaxFieldLength }.map(\.0)
    if !tooLong.isEmpty { block("The \(tooLong.joined(separator: ", ")) is longer than \(orderImportMaxFieldLength) characters.") }
    if order.country.isEmpty {
        block("Missing country.")
    } else if order.countryCode.isEmpty {
        block("Country “\(order.country)” isn’t recognised. Use a two-letter code like US or a full country name.")
    } else if orderStateIsRequired(order.countryCode), order.state.isEmpty {
        block("A state or province is required for \(order.countryCode).")
    }
    var zip = order.zip
    if order.countryCode == "US", let padded = orderImportPaddedUSZIP(order.zip) {
        if padZIP {
            zip = padded
            note("ZIP changed from \(order.zip) to \(padded), as you chose.")
        } else {
            check.paddedZIP = padded
            warn("ZIP \(order.zip) has fewer than 5 digits; spreadsheets often drop a leading zero. Choose \(padded) below if that’s right.")
        }
    } else if let advice = postcodeFormatWarning(zip, country: order.countryCode) {
        note(advice)
    }
    if !order.company.isEmpty {
        warn("The shipping company “\(order.company)” isn’t sent: Slant drafts have no company field.")
    }
    if order.decodedEntities { note("HTML character codes in the name or address were converted to the characters they stand for.") }

    // Email
    var email = order.email
    if !email.isEmpty {
        if !isEmailAddress(email) { block("Email “\(email)” isn’t a valid address.") }
    } else if isEmailAddress(context.fallbackEmail) {
        email = context.fallbackEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        check.usesFallbackEmail = true
    } else {
        block(orderImportMissingEmailBlocker)
        check.waitingForEmail = check.blockers == [orderImportMissingEmailBlocker]
    }

    // Already handled or imported
    if let handled = order.alreadyHandled { warn("\(handled) Tick it only if it really needs a new draft.") }
    if let duplicate = orderImportDuplicateReason(order, ledger: context.ledger, loadedKeys: context.loadedKeys) { warn(duplicate) }

    guard check.blockers.isEmpty else { return check }
    check.draftEmail = email
    check.draftZIP = zip
    do {
        check.body = try orderImportDraftBody(order, context: context, email: email, zip: zip, lines: check.lines,
                                              draftMarker: draftMarker)
    } catch {
        block(error.localizedDescription)
    }
    return check
}

/// An imported order's `POST /orders` body, built only through `orderDraftPayload`.
func orderImportDraftBody(_ order: OrderImportOrder, context: OrderImportContext, email: String, zip: String,
                          lines: [OrderLine], draftMarker: String? = nil) throws -> [String: Any] {
    try orderDraftPayload(
        platformID: context.platformID, ownerID: context.ownerID, email: email, recipientName: order.name,
        line1: order.line1, line2: order.line2, city: order.city, state: order.state, zip: zip, country: order.countryCode,
        paymentID: "", metadata: orderImportMetadata(source: order.source, sourceOrderID: order.sourceOrderID, draftMarker: draftMarker),
        options: [:], lines: lines)
}

/// Once-per-order lines of different products are the same item (and added once) when their type, reference,
/// material, image link and options all match.
func orderImportPerOrderLineKey(_ line: OrderLine) -> String {
    [line.type, line.reference, line.filamentID, line.imageURL, line.optionsJSON]
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .joined(separator: "\u{1F}")
}

/// Shown on an order with personalisation: its draft uses the saved product's model, not a personalised one.
let orderImportPlainModelWarning = "This draft uses the plain model. Make the personalised one first."

let orderImportMissingEmailBlocker = "No email. Fill in “Email for orders without one” to import it."

// MARK: Template

/// The template header and one example row, CRLF line endings.
func orderImportTemplateCSV() -> String {
    let example = ["1001", "Alex Example", "alex@example.com", "1 Example Street", "Apt 2", "Springfield", "IL", "62701", "US", "YOUR-SKU", "1"]
    return [orderImportTemplateHeader, example].map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
}

// MARK: - Runner decisions

enum OrderImportOutcome: Equatable {
    case created(orderID: String)
    /// Slant definitely didn't create it (a 4xx other than 408/409, or a failure before sending).
    case refused(String)
    /// It may have been created.
    case unknown(String)
}

let orderImportUnknownAdvice = "It may have been created. Check your drafts (Show Drafts) before importing it again."

/// The orders list filter that shows drafts, newest first: applied by the reload after an import and by Show Drafts.
func orderImportDraftsFilter() -> OrderFilter {
    var filter = OrderFilter()
    filter.status = "DRAFT"
    return filter
}

/// A 2xx reply is a created draft only when it names the order; otherwise the outcome is unknown.
func orderImportOutcome(response object: [String: Any]) -> OrderImportOutcome {
    let id = Record(values: mergeOrderDraftEnvelope(object)).id.trimmingCharacters(in: .whitespacesAndNewlines)
    return id.isEmpty ? .unknown("Slant didn’t return an order number. \(orderImportUnknownAdvice)") : .created(orderID: id)
}

/// Refused only when the error proves Slant didn't act (`orderMutationErrorProvesNoEffect`); timeouts, transport
/// errors, 5xx, 408 and 409 leave the outcome unknown.
func orderImportOutcome(error: Error) -> OrderImportOutcome {
    if orderMutationErrorProvesNoEffect(error) {
        if case APIError.http(429, _, _, _)? = error as? APIError {
            return .refused("Slant’s rate limit was reached, so this draft wasn’t created.")
        }
        return .refused(friendlyAPIMessage(error))
    }
    let reason: String
    if case APIError.http(let status, _, _, _)? = error as? APIError {
        reason = "Slant replied with an error (HTTP \(status))."
    } else if let urlError = error as? URLError, urlError.code == .timedOut {
        reason = "Slant didn’t reply in time."
    } else {
        reason = "The request didn’t complete."
    }
    return .unknown("\(reason) \(orderImportUnknownAdvice)")
}

enum OrderImportNextStep: Equatable {
    case next
    case stop(String)
}

/// After each draft: an unknown outcome always stops the batch; refusals continue unless the key or platform was
/// refused or too many were refused in a row.
func orderImportNextStep(after outcome: OrderImportOutcome, error: Error?, consecutiveRefusals: Int,
                         maxConsecutiveRefusals: Int = orderImportMaxConsecutiveRefusals) -> OrderImportNextStep {
    switch outcome {
    case .created:
        return .next
    case .unknown:
        return .stop("Stopped: Slant didn’t confirm one draft, so nothing more was sent. Check your drafts (Show Drafts) before importing it again.")
    case .refused:
        if case APIError.http(let status, _, _, _)? = error as? APIError, status == 401 || status == 403 {
            return .stop("Stopped: Slant refused the key or platform, so the rest weren’t sent.")
        }
        if consecutiveRefusals >= maxConsecutiveRefusals {
            return .stop("Stopped after \(maxConsecutiveRefusals) refusals in a row. Check the messages, then try the rest again.")
        }
        return .next
    }
}

enum OrderImportPacing: Equatable {
    case wait(TimeInterval)
    case stop(String)
}

/// How long to wait before the next draft: at least `minimumSpacing` after the last one started, until a 429's reset
/// time, and until the rate-limit reset when Slant's headers show `reserve` or fewer requests left. Stops instead of
/// waiting longer than `maxWait`.
func orderImportPacing(lastRequestStart: Date?, rateLimit: RateLimitInfo?, rateLimitedUntil: Date?, now: Date,
                       minimumSpacing: TimeInterval = orderImportMinimumSpacing, reserve: Int = orderImportRateLimitReserve,
                       maxWait: TimeInterval = orderImportMaxWait) -> OrderImportPacing {
    var wait: TimeInterval = 0
    if let lastRequestStart { wait = max(0, minimumSpacing - now.timeIntervalSince(lastRequestStart)) }
    if let rateLimitedUntil, rateLimitedUntil > now { wait = max(wait, rateLimitedUntil.timeIntervalSince(now)) }
    if let rateLimit, let remaining = rateLimit.remaining, remaining <= reserve {
        if let reset = rateLimit.reset {
            if reset > now { wait = max(wait, reset.timeIntervalSince(now)) }
        } else {
            // A low count without a usable reset time: wait out a whole one-minute window rather than press on.
            wait = max(wait, 60)
        }
    }
    if wait > maxWait {
        return .stop("Stopped to wait for Slant’s rate limit. \(rateLimitResetWaitCopy(secondsFromNow: wait))")
    }
    return .wait(wait)
}

struct OrderImportTally: Equatable {
    var created = 0
    var refused = 0
    var unknown = 0
    var notSent = 0
    /// Batch personalisation: models uploaded, orders whose model couldn't be made, and uploads not confirmed.
    var modelsUploaded = 0
    var notPersonalised = 0
    var uploadsUnconfirmed = 0
}

/// Activity text for an import: counts only, never names, addresses or order IDs from the file.
func orderImportActivityDetail(_ tally: OrderImportTally) -> String {
    var parts = [tally.created == 1 ? "1 draft created" : "\(tally.created) drafts created"]
    if tally.refused > 0 { parts.append("\(tally.refused) refused") }
    if tally.unknown > 0 { parts.append("\(tally.unknown) not confirmed") }
    if tally.notSent > 0 { parts.append("\(tally.notSent) not sent") }
    if tally.modelsUploaded > 0 {
        parts.append(tally.modelsUploaded == 1 ? "1 personalised model uploaded" : "\(tally.modelsUploaded) personalised models uploaded")
    }
    if tally.notPersonalised > 0 { parts.append("\(tally.notPersonalised) not personalised") }
    if tally.uploadsUnconfirmed > 0 {
        parts.append(tally.uploadsUnconfirmed == 1 ? "1 upload not confirmed" : "\(tally.uploadsUnconfirmed) uploads not confirmed")
    }
    return parts.joined(separator: " · ")
}

// MARK: - Runner

struct OrderImportJob {
    let id: String
    let source: OrderImportFormat
    let sourceOrderID: String
    let body: [String: Any]
    /// The `metadata.studioDraftId` in `body`, kept with an unknown outcome for Check Slant.
    var draftMarker: String? = nil
    /// Set when the draft uses personalised models made just before it (BatchPersonalise.swift).
    var personalisation: BatchPersonaliseJob? = nil
}

enum OrderImportRowState: Equatable {
    case queued
    /// Making or uploading the order's personalised models.
    case preparing(String)
    case sending
    case created(String)
    case refused(String)
    case unknown(String)
    case notSent
}

/// Sends drafts strictly one at a time. Stopping (or closing the sheet) takes effect before the next request; a
/// request already sent is always allowed to finish so its outcome is recorded.
@MainActor final class OrderImportRunner: ObservableObject {
    @Published private(set) var running = false
    @Published private(set) var states: [String: OrderImportRowState] = [:]
    @Published private(set) var message: String?
    @Published private(set) var waitingUntil: Date?
    @Published private(set) var sentCount = 0
    @Published private(set) var totalCount = 0
    /// Counts from the last finished batch.
    @Published private(set) var lastTally: OrderImportTally?
    private(set) var stopRequested = false
    /// What buyers paid (USD), by import row ID, set by the sheet before a batch. Each created draft's amounts move
    /// to the store's in-memory `importedSaleAmounts`; never saved or logged.
    var saleAmounts: [String: ImportedSaleAmounts] = [:]
    /// The amounts of drafts whose outcome wasn't confirmed, by ledger key, so Look for Drafts on Slant can attach them
    /// to the order it finds. In this sheet's memory only, like `saleAmounts`.
    private(set) var unconfirmedSaleAmounts: [String: ImportedSaleAmounts] = [:]

    func start(_ jobs: [OrderImportJob], store: StudioStore) {
        guard !running, !jobs.isEmpty else { return }
        guard !store.busy else {
            message = "Wait for the current task to finish, then try again."
            return
        }
        stopRequested = false
        message = nil
        sentCount = 0
        totalCount = jobs.count
        for job in jobs { states[job.id] = .queued }
        running = true
        // The batch holds the app-wide busy flag so no other Slant task interleaves with it.
        store.busy = true
        store.progress = "Importing orders"
        Task { await self.execute(jobs, store: store) }
    }

    func requestStop() {
        if running { stopRequested = true }
    }

    /// Look for Drafts on Slant found the draft of a row whose outcome was unknown: show it as created.
    func noteConfirmed(_ id: String, orderID: String) {
        guard !running, case .unknown? = states[id] else { return }
        states[id] = .created(orderID)
    }

    /// The buyer's amounts for an unconfirmed draft that has now been found, once (ledger key).
    func takeUnconfirmedSaleAmounts(ledgerKey: String) -> ImportedSaleAmounts? {
        unconfirmedSaleAmounts.removeValue(forKey: ledgerKey)
    }

    /// Clears results for a newly chosen file. Ignored while a batch runs.
    func reset() {
        guard !running else { return }
        states = [:]
        message = nil
        sentCount = 0
        totalCount = 0
        lastTally = nil
    }

    private func execute(_ jobs: [OrderImportJob], store: StudioStore) async {
        let client = store.client
        let apiKey = store.apiKey
        let platformID = store.platformID
        var tally = OrderImportTally()
        var consecutiveRefusals = 0
        var lastStart: Date?
        var observedRateLimit = store.rateLimit
        var rateLimitedUntil: Date?
        var stopMessage: String?
        let ownerID = store.ownerID
        let accountChanged = "Stopped because the account or platform changed. The rest weren’t sent."

        /// Waits as the pacing requires; a reason to stop, or nil. Personalised uploads share it with drafts.
        func pace() async -> String? {
            if stopRequested { return "Stopped. The rest weren’t sent." }
            switch orderImportPacing(lastRequestStart: lastStart, rateLimit: observedRateLimit, rateLimitedUntil: rateLimitedUntil, now: Date()) {
            case .stop(let reason):
                return reason
            case .wait(let seconds):
                if seconds > 0 {
                    waitingUntil = Date().addingTimeInterval(seconds)
                    await sleepUnlessStopped(seconds)
                    waitingUntil = nil
                }
            }
            return stopRequested ? "Stopped. The rest weren’t sent." : nil
        }
        func accountUnchanged() -> Bool { store.hasKey && store.apiKey == apiKey && store.platformID == platformID }

        jobLoop: for job in jobs {
            if let reason = await pace() { stopMessage = reason; break }
            guard accountUnchanged() else { stopMessage = accountChanged; break }
            var body = job.body
            if let personalised = job.personalisation {
                // Make and upload this buyer's models, then build the draft with them. Nothing falls back to the plain model.
                var step = await batchPersonaliseMakeAndUpload(personalised, client: client, platformID: platformID, ownerID: ownerID,
                                                               hooks: BatchPersonaliseRunHooks(
                    status: { [weak self] in self?.states[job.id] = .preparing($0) },
                    pace: { await pace() },
                    accountProblem: { accountUnchanged() ? nil : accountChanged },
                    isStopRequested: { [weak self] in self?.stopRequested ?? true },
                    uploadSent: { result in
                        lastStart = Date()
                        switch result {
                        case .success(let response):
                            if case .uploaded = batchPersonaliseUploadOutcome(response: responseObject(response)) { tally.modelsUploaded += 1 }
                            if response.rateLimit.hasValues {
                                observedRateLimit = response.rateLimit
                                store.rateLimit = response.rateLimit
                            }
                        case .failure(let error):
                            if case APIError.http(429, _, let retryAfter, let reset)? = error as? APIError {
                                rateLimitedUntil = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date())
                            }
                        }
                    }))
                if case .ready(let fileIDs) = step {
                    if let lines = batchPersonaliseDraftLines(personalised.plan.baseLines, models: personalised.plan.models, fileIDs: fileIDs),
                       let built = try? personalised.makeBody(lines) {
                        body = built
                    } else {
                        step = .notMade("Studio couldn’t build the draft with the personalised model, so it wasn’t sent.")
                    }
                }
                switch step {
                case .ready:
                    // The uploads used requests too: pace the draft after them.
                    if let reason = await pace() { states[job.id] = .queued; stopMessage = reason; break jobLoop }
                    guard accountUnchanged() else { states[job.id] = .queued; stopMessage = accountChanged; break jobLoop }
                case .notMade(let reason):
                    states[job.id] = .refused(reason)
                    tally.notPersonalised += 1
                    consecutiveRefusals += 1
                case .refused(let reason, _):
                    states[job.id] = .refused(reason)
                    tally.refused += 1
                    consecutiveRefusals += 1
                case .unknown(let reason):
                    states[job.id] = .unknown(reason)
                    tally.uploadsUnconfirmed += 1
                case .stopped:
                    states[job.id] = .queued
                }
                if case .stop(let reason) = batchPersonaliseNextStep(after: step, consecutiveRefusals: consecutiveRefusals) {
                    stopMessage = reason
                    break jobLoop
                }
                guard case .ready = step else { continue }
            }
            states[job.id] = .sending
            lastStart = Date()
            let outcome: OrderImportOutcome
            var failure: Error?
            do {
                let response = try await client.request("POST", path: "/orders", body: body)
                if response.rateLimit.hasValues {
                    observedRateLimit = response.rateLimit
                    store.rateLimit = response.rateLimit
                }
                outcome = orderImportOutcome(response: responseObject(response))
            } catch {
                failure = error
                if case APIError.http(429, _, let retryAfter, let reset)? = error as? APIError {
                    rateLimitedUntil = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date())
                }
                outcome = orderImportOutcome(error: error)
            }
            sentCount += 1
            switch outcome {
            case .created(let orderID):
                store.orderImportLedger.record(.created(orderID: orderID), source: job.source, sourceOrderID: job.sourceOrderID)
                states[job.id] = .created(orderID)
                tally.created += 1
                if let amounts = saleAmounts[job.id] { store.importedSaleAmounts[orderID] = amounts }
                consecutiveRefusals = 0
            case .refused(let reason):
                states[job.id] = .refused(reason)
                tally.refused += 1
                consecutiveRefusals += 1
            case .unknown(let reason):
                store.orderImportLedger.record(.unknown, source: job.source, sourceOrderID: job.sourceOrderID,
                                               marker: job.draftMarker, platformID: platformID)
                if job.draftMarker != nil, let amounts = saleAmounts[job.id] {
                    unconfirmedSaleAmounts[OrderImportLedger.key(source: job.source, sourceOrderID: job.sourceOrderID)] = amounts
                }
                states[job.id] = .unknown(reason)
                tally.unknown += 1
            }
            if case .stop(let reason) = orderImportNextStep(after: outcome, error: failure, consecutiveRefusals: consecutiveRefusals) {
                stopMessage = reason
                break
            }
        }
        for job in jobs where states[job.id] == .queued {
            states[job.id] = .notSent
            tally.notSent += 1
        }
        waitingUntil = nil
        running = false
        store.busy = false
        store.progress = ""
        let summary = orderImportActivityDetail(tally)
        message = stopMessage.map { "\($0) \(summary)." } ?? "Done: \(summary)."
        if tally.created + tally.refused + tally.unknown + tally.notPersonalised + tally.uploadsUnconfirmed + tally.modelsUploaded > 0 {
            store.activities.insert(Activity(title: "Import orders", detail: summary,
                                             success: tally.refused == 0 && tally.unknown == 0 && tally.notSent == 0
                                                && tally.notPersonalised == 0 && tally.uploadsUnconfirmed == 0), at: 0)
            store.activities = Array(store.activities.prefix(100))
        }
        lastTally = tally
        // One read-only reload of the drafts list so new drafts appear in Orders. Never repeats a draft request.
        if tally.created + tally.unknown > 0, store.hasKey, store.apiKey == apiKey {
            await store.applyOrderFilter(orderImportDraftsFilter())
        }
    }

    private func sleepUnlessStopped(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while !stopRequested {
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 { break }
            try? await Task.sleep(nanoseconds: UInt64(min(0.25, remaining) * 1_000_000_000))
        }
    }
}

// MARK: - Store hooks

extension StudioStore {
    /// Why Import Orders… is unavailable, or nil.
    var orderImportBlockedReason: String? {
        if let reason = orderDraftBlockedReason { return reason }
        if !connected { return "Connect your account first." }
        if busy { return "Wait for the current task to finish." }
        return nil
    }

    /// File › Import Orders…: only opens the sheet, and only when nothing modal is shown.
    func importOrdersFromMenu() {
        guard !menuCommandsBlockedByModalUI, orderImportBlockedReason == nil else { return }
        destination = .orders
        showOrderImport = true
    }
}

// MARK: - Sheet

struct OrderImportSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = OrderImportRunner()
    @State private var fileName: String?
    @State private var parsed: OrderImportParse?
    @State private var loadError: String?
    @State private var fallbackEmail = ""
    @State private var ticked: Set<String> = []
    @State private var paddedZIP: Set<String> = []
    @State private var confirmCreate = false
    /// Match products choices for this file only: never saved, and cleared with the file.
    @State private var productChoices: [String: OrderImportProductChoice] = [:]
    /// Look for Drafts on Slant's last result for unconfirmed imports (counts only).
    @State private var importCheckMessage: String?
    /// Match products and Personalise with OpenSCAD: open while they need input, until the seller opens or closes them
    /// (`orderImportSectionExpanded`). Reset with the list.
    @State private var matchProductsExpanded: Bool?
    @State private var personaliseExpanded: Bool?
    /// Personalise with OpenSCAD (BatchPersonaliseView.swift): memory only, reset with the file.
    @StateObject private var personalise = BatchPersonaliseSession()

    private var context: OrderImportContext {
        OrderImportContext(
            products: store.savedProducts, localModels: store.localModels, filaments: store.filaments,
            components: store.components, stationery: store.stationery, platformID: store.platformID,
            ownerID: store.ownerID, fallbackEmail: fallbackEmail, ledger: store.orderImportLedger,
            loadedKeys: orderImportLoadedSourceKeys(store.orders), productChoices: productChoices)
    }

    private func checks(for parse: OrderImportParse) -> [String: OrderImportCheck] {
        let context = context
        var result: [String: OrderImportCheck] = [:]
        let inputs = personalise.inputs
        for order in parse.orders {
            let check = orderImportCheck(order, context: context, padZIP: paddedZIP.contains(order.id))
            let eligibility = batchPersonaliseEligibility(order, check: check, products: context.products, inputs: inputs)
            result[order.id] = batchPersonalisedCheck(check, eligibility: eligibility)
        }
        return result
    }

    /// Changes a personalisation choice (or re-reads OpenSCAD and the templates). Orders it makes clean are ticked;
    /// orders it returns to the plain model are unticked.
    private func updatePersonalisation(_ parse: OrderImportParse, _ change: () -> Void) {
        guard !runner.running else { return }
        let before = checks(for: parse)
        change()
        let after = checks(for: parse)
        ticked.subtract(batchPersonaliseNewlyUnticked(before: before, after: after))
        ticked.formUnion(batchPersonaliseNewlyTicked(before: before, after: after))
    }

    private func isSendable(_ id: String, checks: [String: OrderImportCheck]) -> Bool {
        guard let check = checks[id], check.blockers.isEmpty, check.body != nil else { return false }
        switch runner.states[id] {
        case .created?, .unknown?, .sending?, .preparing?: return false
        default: return true
        }
    }

    private func readyIDs(_ parse: OrderImportParse, checks: [String: OrderImportCheck]) -> [String] {
        parse.orders.map(\.id).filter { ticked.contains($0) && isSendable($0, checks: checks) }
    }

    var body: some View {
        let currentChecks = parsed.map(checks(for:)) ?? [:]
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Import Orders").font(.title2.bold())
                Text("Creates Slant order drafts from an Etsy “Sold Order Items” CSV, a Shopify orders export or Studio’s template. Each item must match a saved product by SKU, or one you choose under Match products. Drafts aren’t charged: afterwards you review and pay them in Orders, one at a time or together with Pay Several Drafts… in the Orders toolbar’s More menu.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Choose File…") { chooseFile() }.disabled(runner.running)
                // ShopifyImport.swift: shown only once Shopify is connected in Settings.
                ShopifyImportFetchButton(disabled: runner.running, onLoaded: { apply($0, label: $1) },
                                         onError: { loadError = $0 })
                Button("Save Template…") { saveTemplate() }
                if let fileName {
                    Text(fileName).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
            }
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let parsed {
                preview(parsed, checks: currentChecks)
            } else if loadError == nil {
                ContentUnavailableView {
                    Label("No file chosen", systemImage: "doc.text")
                } description: {
                    Text(orderImportEmptyHint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Spacer(minLength: 0)
            }
            footer(currentChecks)
        }
        .padding(20)
        .frame(minWidth: 780, idealWidth: 860, minHeight: 560, idealHeight: 680)
        .confirmationDialog(confirmTitle(currentChecks), isPresented: $confirmCreate, titleVisibility: .visible) {
            Button(createButtonTitle(readyCount(currentChecks))) { startImport() }
            // Return cancels, so pressing it twice can't start a batch.
            Button("Cancel", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(confirmMessage(currentChecks))
        }
        .task { await store.refreshFilamentsIfStale() }
        .onChange(of: runner.running) { _, running in
            // Orders the batch never sent (it was stopped) are ticked again; sent ones stay unticked.
            guard !running else { return }
            for (id, state) in runner.states where state == .notSent { ticked.insert(id) }
        }
        .onDisappear {
            // Closing stops the batch before its next request and drops every imported address and product choice.
            runner.requestStop()
            parsed = nil
            fallbackEmail = ""
            ticked = []
            paddedZIP = []
            productChoices = [:]
            personalise.reset()
        }
    }

    @ViewBuilder
    private func preview(_ parse: OrderImportParse, checks: [String: OrderImportCheck]) -> some View {
        let blocked = parse.orders.filter { checks[$0.id]?.canTick == false }.count
        VStack(alignment: .leading, spacing: 6) {
            Text("\(parse.format.title) · \(parse.orders.count == 1 ? "1 order" : "\(parse.orders.count) orders")\(blocked > 0 ? " · \(blocked) can’t be imported" : "")")
                .font(.headline)
            ForEach(parse.notices, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            if let coverage = orderImportDuplicateCoverageNotice(
                ordersLoaded: store.ordersLoaded, ordersHasMore: store.ordersHasMore,
                listIsPartial: store.orderSearchActive || store.orderFilter.isActive) {
                Text(coverage).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Text("Drafts are created on platform \(platformName).").font(.caption).foregroundStyle(.secondary)
            if let saleNotice = orderImportSaleAmountsNotice(parse.orders) {
                Text(saleNotice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if parse.orders.contains(where: { $0.items.contains { !$0.personalisation.isEmpty } }) {
                OrderImportPersonalisationNotice(list: orderImportPersonalisationList(parse.orders))
            }
        }
        if parse.orders.contains(where: { $0.email.isEmpty }) {
            VStack(alignment: .leading, spacing: 4) {
                TextField("Email for orders without one", text: $fallbackEmail, prompt: Text("you@yourshop.com"))
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .disabled(runner.running)
                Text("Slant needs an email for every order. \(parse.format == .etsy ? "Etsy files don’t include buyers’ emails, so" : "Some orders have none;") enter one to use for these orders, such as your shop’s. Studio never fills one in for you.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if !fallbackEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isEmailAddress(fallbackEmail) {
                    Text("Enter an email like name@example.com.").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        // Collapsible, so the order list and the footer keep their room: each opens by itself only while it needs a
        // choice (Personalise only once Match products doesn't), and stays as the seller leaves it.
        let unmatched = orderImportUnmatchedKeys(parse.orders, products: store.savedProducts)
        let unchosen = unmatched.filter { productChoices[$0.id] == nil }.count
        let matchOpen = orderImportSectionExpanded(userChoice: matchProductsExpanded, needsInput: unchosen > 0)
        if !unmatched.isEmpty {
            DisclosureGroup(isExpanded: Binding(get: { matchOpen }, set: { matchProductsExpanded = $0 })) {
                matchProducts(unmatched, parse: parse)
            } label: {
                Text(orderImportMatchProductsTitle(keys: unmatched.count, unchosen: unchosen)).font(.headline)
            }
            .studioDisclosureStyle()
        }
        let personalisable = batchPersonaliseProducts(parse.orders, checks: checks, products: store.savedProducts)
        if !personalisable.isEmpty {
            let undecided = personalisable.filter { personalise.choices[$0.product.id] == nil }.count
            let needsInput = personalise.openSCAD != nil && undecided > 0 && !(matchOpen && !unmatched.isEmpty)
            DisclosureGroup(isExpanded: Binding(
                get: { orderImportSectionExpanded(userChoice: personaliseExpanded, needsInput: needsInput) },
                set: { personaliseExpanded = $0 })) {
                OrderImportPersonaliseSection(
                    session: personalise, products: personalisable, disabled: runner.running,
                    choose: { id, choice in updatePersonalisation(parse) { personalise.choices[id] = choice } },
                    checkAgain: { updatePersonalisation(parse) { personalise.refresh(products: store.savedProducts) } })
            } label: {
                Text(batchPersonaliseSectionTitle(openSCADInstalled: personalise.openSCAD != nil,
                                                  products: personalisable.count, undecided: undecided)).font(.headline)
            }
            .studioDisclosureStyle()
        }
        List(parse.orders) { order in
            row(order, check: checks[order.id] ?? OrderImportCheck())
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 200)
    }

    /// Each item key no saved product matches by SKU, once, with a product picker. A choice applies to every row with
    /// that key, lives only in this sheet, and is never guessed.
    private func matchProducts(_ keys: [OrderImportMatchKey], parse: OrderImportParse) -> some View {
        let products = savedProductsSorted(store.savedProducts)
        let missingSKUs = orderImportMissingSKUs(keys)
        return VStack(alignment: .leading, spacing: 6) {
            if let summary = orderImportMissingSKUSummary(missingSKUs) {
                HStack(spacing: 8) {
                    Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                        .help(summary)
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(missingSKUs.joined(separator: "\n"), forType: .string)
                    }
                    .controlSize(.small)
                    .help("Copy these SKUs, one per line, to set them up in Saved Products.")
                }
            }
            Text("Choose the saved product to use for each, just for this file. Nothing is matched unless you choose it, and choices aren’t saved. To match automatically next time, give the saved product the same SKU.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(keys) { key in
                        HStack {
                            Text(key.kind == .sku ? "SKU \(key.display)" : "No SKU: “\(key.display)”")
                                .lineLimit(1).truncationMode(.middle)
                            Text(key.orderCount == 1 ? "1 order" : "\(key.orderCount) orders").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Picker("Product for \(key.display)", selection: Binding<OrderImportProductChoice?>(
                                get: { productChoices[key.id] },
                                set: { choose($0, for: key, parse: parse) })) {
                                Text("Choose a product…").tag(OrderImportProductChoice?.none)
                                ForEach(products) { product in
                                    let sku = product.sku.trimmingCharacters(in: .whitespacesAndNewlines)
                                    Text(sku.isEmpty ? savedProductDisplayName(product) : "\(savedProductDisplayName(product)) (\(sku))")
                                        .tag(OrderImportProductChoice?.some(.product(product.id)))
                                }
                                Divider()
                                Text("Leave out of drafts").tag(OrderImportProductChoice?.some(.leaveOut))
                            }
                            .labelsHidden()
                            .frame(width: 260)
                            .disabled(runner.running)
                        }
                    }
                }
            }
            .frame(maxHeight: keys.count > 4 ? 130 : nil)
            .fixedSize(horizontal: false, vertical: keys.count <= 4)
        }
    }

    private func choose(_ choice: OrderImportProductChoice?, for key: OrderImportMatchKey, parse: OrderImportParse) {
        guard !runner.running else { return }
        let before = checks(for: parse)
        productChoices[key.id] = choice
        // Orders the choice makes importable are ticked, as they would have been on loading; it never unticks.
        ticked.formUnion(orderImportNewlyTickable(before: before, after: checks(for: parse)))
    }

    private func row(_ order: OrderImportOrder, check: OrderImportCheck) -> some View {
        let state = runner.states[order.id]
        let lockedByRun: Bool = {
            switch state {
            case .created?, .unknown?, .sending?, .preparing?: return true
            default: return false
            }
        }()
        return HStack(alignment: .top, spacing: 10) {
            Toggle("Import order \(order.sourceOrderID)", isOn: Binding(
                get: { ticked.contains(order.id) && check.canTick && !lockedByRun },
                set: { if $0 { ticked.insert(order.id) } else { ticked.remove(order.id) } }))
                .labelsHidden()
                .toggleStyle(.checkbox)
                .disabled(!check.canTick || lockedByRun || runner.running)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(order.sourceOrderID).fontWeight(.semibold).lineLimit(1)
                    Text(order.name.isEmpty ? "No recipient" : order.name).lineLimit(1)
                    Spacer()
                    Text(order.countryCode.isEmpty ? (order.country.isEmpty ? "No country" : order.country) : order.countryCode)
                        .foregroundStyle(.secondary).lineLimit(1)
                }
                Text(check.itemsSummary.isEmpty ? "No items" : check.itemsSummary)
                    .font(.callout).foregroundStyle(.secondary).lineLimit(2)
                // Personalisation (Personalisation.swift): display and Copy only; drafts are built without it.
                ForEach(Array(order.items.enumerated()).filter { !$0.element.personalisation.isEmpty }, id: \.offset) { _, item in
                    OrderImportPersonalisationRow(item: item, showsItemName: order.items.count > 1)
                }
                if let state { stateLabel(state) }
                ForEach(check.blockers, id: \.self) { text in
                    Label(text, systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red)
                }
                ForEach(orderImportVisibleWarnings(check.warnings, rowState: state), id: \.self) { text in
                    Label(text, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
                }
                if let padded = orderImportPaddedUSZIP(order.zip), order.countryCode == "US" {
                    Toggle("Use ZIP \(padded)", isOn: Binding(
                        get: { paddedZIP.contains(order.id) },
                        set: { if $0 { paddedZIP.insert(order.id) } else { paddedZIP.remove(order.id) } }))
                        .toggleStyle(.checkbox).font(.caption)
                        .disabled(runner.running || lockedByRun)
                }
                ForEach(check.notes, id: \.self) { text in
                    Text(text).font(.caption).foregroundStyle(.secondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }

    @ViewBuilder
    private func stateLabel(_ state: OrderImportRowState) -> some View {
        switch state {
        case .queued: Label("Waiting", systemImage: "clock").font(.caption).foregroundStyle(.secondary)
        case .preparing(let step): Label(step, systemImage: "wand.and.stars").font(.caption).foregroundStyle(.secondary)
        case .sending: Label("Creating draft…", systemImage: "arrow.up.circle").font(.caption).foregroundStyle(.secondary)
        case .created(let id): Label("Draft created: \(id)", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .refused(let reason): Label("Not created: \(reason)", systemImage: "xmark.circle.fill").font(.caption).foregroundStyle(.red)
        case .unknown(let reason): Label("Not confirmed: \(reason)", systemImage: "questionmark.circle.fill").font(.caption).foregroundStyle(.orange)
        case .notSent: Label("Not sent", systemImage: "minus.circle").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func footer(_ checks: [String: OrderImportCheck]) -> some View {
        let count = readyCount(checks)
        return VStack(alignment: .leading, spacing: 6) {
            if runner.running {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if let until = runner.waitingUntil, until.timeIntervalSinceNow > 2 {
                        Text("Waiting for Slant’s rate limit… \(runner.sentCount) of \(runner.totalCount) sent.").font(.callout)
                    } else {
                        Text("Creating drafts… \(runner.sentCount) of \(runner.totalCount) sent.").font(.callout)
                    }
                }
            } else if let message = runner.message {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !runner.running, let importCheckMessage {
                Text(importCheckMessage).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if let reason = store.orderDraftBlockedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if runner.running {
                    Button("Stop") { runner.requestStop() }
                        .help("Stop before the next draft. A draft already being created finishes first.")
                }
                if !runner.running, !store.orderImportLedger.unconfirmedMarkers.isEmpty {
                    Button(draftCheckButtonTitle(count: store.orderImportLedger.unconfirmedMarkers.count)) { checkUnconfirmedImports() }
                        .disabled(store.busy)
                        .help("Look for drafts that didn’t confirm in your newest orders on Slant. Read-only: nothing is created or changed.")
                }
                if showDraftsAvailable {
                    let drafts = orderImportDraftsFilter()
                    Button("Show Drafts") { showDrafts() }
                        .disabled(store.busy && store.orderFilter != drafts)
                        .help("Close and show draft orders in Orders, where you review and pay each one.")
                }
                Button(runner.running ? "Close and Stop" : "Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                // No default-action shortcut: creating drafts always takes a click and the confirmation.
                Button(createButtonTitle(count) + "…") { confirmCreate = true }
                    .buttonStyle(.borderedProminent)
                    .disabled(count == 0 || runner.running || store.busy || store.orderDraftBlockedReason != nil)
            }
        }
    }

    /// Look for Drafts on Slant (DraftConfirmation.swift): read-only. A draft found with an unconfirmed import's marker
    /// marks that order as created in the session ledger, shows its row as created and gets the buyer's amounts, as a
    /// confirmed create would; not finding one changes nothing.
    private func checkUnconfirmedImports() {
        let pending = store.orderImportLedger.unconfirmedMarkers
        var markers: [String: String] = [:]
        for value in pending.values { markers[value.marker] = value.platformID }
        guard !markers.isEmpty, !store.busy, !runner.running else { return }
        Task {
            guard let result = await store.searchOrdersForDraftMarkers(markers) else { return }
            var confirmed = 0
            for (key, value) in pending {
                guard let record = result.found[value.marker.lowercased()] else { continue }
                store.orderImportLedger.confirm(key: key, orderID: record.id)
                for rowID in orderImportRowIDs(forLedgerKey: key, in: parsed?.orders ?? []) {
                    runner.noteConfirmed(rowID, orderID: record.id)
                }
                if let amounts = runner.takeUnconfirmedSaleAmounts(ledgerKey: key), store.importedSaleAmounts[record.id] == nil {
                    store.importedSaleAmounts[record.id] = amounts
                }
                confirmed += 1
            }
            importCheckMessage = orderImportDraftCheckMessage(confirmed: confirmed, stillUnconfirmed: pending.count - confirmed, result: result)
        }
    }

    /// After a batch that made (or may have made) drafts, or when this session's imports are on record.
    private var showDraftsAvailable: Bool {
        guard !runner.running else { return false }
        if let tally = runner.lastTally, tally.created + tally.unknown > 0 { return true }
        return !store.orderImportLedger.entries.isEmpty
    }

    /// Applies the orders list's Draft status filter (unless the list already shows it) and closes the sheet.
    private func showDrafts() {
        let drafts = orderImportDraftsFilter()
        let alreadyShown = store.orderFilter == drafts && (store.busy || (store.ordersLoaded && !store.orderSearchActive))
        store.destination = .orders
        dismiss()
        if !alreadyShown {
            Task { await store.applyOrderFilter(drafts) }
        }
    }

    private var platformName: String {
        let name = store.platforms.first { $0.id == store.platformID }?.name ?? ""
        return name.isEmpty ? store.platformID : name
    }

    private func readyCount(_ checks: [String: OrderImportCheck]) -> Int {
        parsed.map { readyIDs($0, checks: checks).count } ?? 0
    }

    private func createButtonTitle(_ count: Int) -> String {
        orderImportCreateButtonTitle(count)
    }

    private func confirmTitle(_ checks: [String: OrderImportCheck]) -> String {
        let count = readyCount(checks)
        return count == 1 ? "Create 1 order draft?" : "Create \(count) order drafts?"
    }

    private func confirmMessage(_ checks: [String: OrderImportCheck]) -> String {
        guard let parsed else { return "" }
        let ids = readyIDs(parsed, checks: checks)
        var text = "These are drafts: nothing is charged. Studio creates them one at a time on platform \(platformName) and stops if Slant doesn’t confirm one. Afterwards, review and pay them in Orders, one at a time or together with Pay Several Drafts… in the Orders toolbar’s More menu."
        let fallbackCount = ids.filter { checks[$0]?.usesFallbackEmail == true }.count
        if fallbackCount > 0 {
            let email = fallbackEmail.trimmingCharacters(in: .whitespacesAndNewlines)
            text += fallbackCount == 1 ? " 1 draft uses \(email) as its email." : " \(fallbackCount) drafts use \(email) as their email."
        }
        let chosenCount = ids.filter { checks[$0]?.usesProductChoice == true }.count
        if chosenCount > 0 {
            text += chosenCount == 1 ? " 1 draft uses your Match products choices." : " \(chosenCount) drafts use your Match products choices."
        }
        text += batchPersonaliseConfirmText(ids.filter { personalisationJob(for: $0, checks: checks) != nil }.count) ?? ""
        return text
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.title = "Import Orders"
        panel.message = "Choose an Etsy “Sold Order Items” CSV, a Shopify orders export or a file made from Studio’s template."
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        load(url)
    }

    private func load(_ url: URL) {
        guard !runner.running else { return }
        do {
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > orderImportMaxFileBytes {
                throw StudioError("This file is larger than \(orderImportMaxFileBytes / (1024 * 1024)) MB. Import at most \(orderImportMaxOrders) orders at a time.")
            }
            apply(try orderImportParse(data: try Data(contentsOf: url)), label: url.lastPathComponent)
        } catch {
            parsed = nil
            ticked = []
            paddedZIP = []
            productChoices = [:]
            personalise.reset()
            fileName = url.lastPathComponent
            loadError = error.localizedDescription
        }
    }

    /// Shows a parsed file, or orders fetched from Shopify (ShopifyImport.swift), with fresh results and choices.
    private func apply(_ parse: OrderImportParse, label: String) {
        guard !runner.running else { return }
        runner.reset()
        paddedZIP = []
        productChoices = [:]
        personalise.reset()
        personalise.refresh(products: store.savedProducts)
        parsed = parse
        loadError = nil
        // The last look on Slant and the sections' open/closed choices belong to the previous list.
        importCheckMessage = nil
        matchProductsExpanded = nil
        personaliseExpanded = nil
        fileName = label
        let initial = checks(for: parse)
        ticked = Set(parse.orders.map(\.id).filter { initial[$0]?.tickedByDefault == true })
    }

    private func saveTemplate() {
        let panel = NSSavePanel()
        panel.title = "Save Order Import Template"
        panel.nameFieldStringValue = "Slant order import template.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(orderImportTemplateCSV().utf8).write(to: url, options: .atomic)
        } catch {
            loadError = "Could not save the template: \(error.localizedDescription)"
        }
    }

    /// The personalised models an order's draft uses, when Personalise with OpenSCAD can make them; else nil.
    private func personalisationJob(for id: String, checks: [String: OrderImportCheck], draftMarker: String? = nil) -> BatchPersonaliseJob? {
        guard let order = parsed?.orders.first(where: { $0.id == id }), let check = checks[id],
              case .ready(let plan) = batchPersonaliseEligibility(order, check: check, products: store.savedProducts, inputs: personalise.inputs)
        else { return nil }
        let context = context
        return BatchPersonaliseJob(
            plan: plan,
            uploadNames: plan.models.indices.map {
                batchPersonaliseUploadName(source: order.source, sourceOrderID: order.sourceOrderID, index: $0, count: plan.models.count)
            },
            makeBody: { lines in
                try orderImportDraftBody(order, context: context, email: check.draftEmail, zip: check.draftZIP, lines: lines,
                                         draftMarker: draftMarker)
            })
    }

    private func startImport() {
        guard let parsed, !runner.running, store.orderDraftBlockedReason == nil else { return }
        // Rebuilt from the current state, so the bodies sent are exactly what the preview shows.
        let currentChecks = checks(for: parsed)
        let context = context
        let jobs: [OrderImportJob] = parsed.orders.compactMap { order in
            guard ticked.contains(order.id), isSendable(order.id, checks: currentChecks) else { return nil }
            // The same body with a fresh draft marker (DraftConfirmation.swift), so Check Slant can find it later.
            let marker = newStudioDraftMarker()
            let marked = orderImportCheck(order, context: context, padZIP: paddedZIP.contains(order.id), draftMarker: marker)
            guard marked.blockers.isEmpty, let body = marked.body else { return nil }
            var job = OrderImportJob(id: order.id, source: order.source, sourceOrderID: order.sourceOrderID, body: body,
                                     draftMarker: orderDraftMarkerSent(body, generated: marker))
            // A personalised draft's body is rebuilt with its uploaded models, carrying the same marker.
            job.personalisation = personalisationJob(for: order.id, checks: currentChecks, draftMarker: marker)
            return job
        }
        guard !jobs.isEmpty else { return }
        // A draft that leaves items out doesn't get the whole order's item total (ImportedSaleAmounts.swift).
        runner.saleAmounts = importedSaleAmountsByOrder(
            parsed.orders, leavingOutItemsIn: Set(currentChecks.filter { $0.value.leftOutItemCount > 0 }.map(\.key)))
        importCheckMessage = nil
        runner.start(jobs, store: store)
        // Sent orders are unticked so pressing Create again never resends them without a fresh, explicit tick.
        if runner.running { ticked.subtract(jobs.map(\.id)) }
    }
}
