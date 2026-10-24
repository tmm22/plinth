import SwiftUI
import AppKit
import UniformTypeIdentifiers

// Spending report: what the loaded orders cost on Slant per calendar month, and which items sold the most units.
// Built from the orders already in the Orders list (no requests), from the same totals the list shows. Nothing is
// saved: the report lives in the sheet while it's open, and only the text or CSV the user copies or exports leaves it.
// It holds Slant's charges only, never what buyers paid, and no recipient details.

// MARK: - Model

/// Statuses whose orders Slant has charged for. Drafts, cancelled orders, payment errors and any status Studio doesn't
/// know are left out (and counted), so a new Slant status never adds spend by accident.
let spendReportCountedStatuses: Set<String> = [
    "PAID", "QUEUED", "PROCESSING", "PRINTING", "ITEMS_ON_SHELF", "POST_PROCESSING", "COMPLETED", "IN_REVIEW",
    "AWAITING_SHIPMENT", "SHIPPED", "DELIVERED"
]

struct SpendReportMonth: Equatable, Identifiable {
    let year: Int
    let month: Int
    var orders = 0
    /// Sum of the totals that could be read, in USD.
    var spend: Decimal = 0
    /// Counted orders in this month whose total Slant didn't return (or returned in another currency).
    var ordersWithoutTotal = 0
    var id: String { String(format: "%04d-%02d", year, month) }
}

struct SpendReportItem: Equatable, Identifiable {
    /// Grouping key: the uploaded file, component or stationery ID, otherwise the item's name and type.
    let key: String
    let name: String
    var sku: String?
    var units = 0
    /// Counted orders that include this item.
    var orders = 0
    var id: String { key }
}

/// What Slant charged to print one product (a saved product with a single print item, by SKU) or one uploaded model,
/// from the item prices of counted orders whose item prices add up to their printing cost.
struct SpendReportProductCost: Equatable, Identifiable {
    /// "sku:<normalised SKU>" for a saved product with one print item, otherwise the item's report key (its file).
    let key: String
    let name: String
    var sku: String?
    var orders = 0
    var units = 0
    /// Sum of Slant's item prices (each the price of the whole line, not of one unit), in USD.
    var total: Decimal = 0
    var id: String { key }
    var averagePerUnit: Decimal? { units > 0 ? roundedToCents(total / Decimal(units)) : nil }
}

/// What Slant charged for delivery to one destination country.
struct SpendReportDeliveryCost: Equatable, Identifiable {
    /// ISO 3166 code, or "" when the order's address country wasn't recognised.
    let countryCode: String
    var orders = 0
    var total: Decimal = 0
    var lowest: Decimal?
    var highest: Decimal?
    var id: String { countryCode }
    var average: Decimal? { orders > 0 ? roundedToCents(total / Decimal(orders)) : nil }
}

struct SpendReport: Equatable {
    /// Newest month first.
    var months: [SpendReportMonth] = []
    /// Most units first.
    var items: [SpendReportItem] = []
    /// Printing cost per product or model, most units first.
    var productCosts: [SpendReportProductCost] = []
    /// Counted orders with print items whose item prices couldn't be used: missing, not USD, a quantity that isn't a
    /// whole number, or prices that don't add up to the order's printing cost.
    var ordersWithoutItemPrices = 0
    /// Delivery cost per destination country, most orders first; an unrecognised country last.
    var deliveryCosts: [SpendReportDeliveryCost] = []
    /// Counted orders without a readable USD delivery cost.
    var ordersWithoutDelivery = 0
    var countedOrders = 0
    var totalSpend: Decimal = 0
    var ordersWithoutTotal = 0
    var excludedDrafts = 0
    var excludedCancelled = 0
    /// Payment errors and statuses Studio doesn't know.
    var excludedOther = 0
    /// Counted-status orders without a readable creation date; left out of months and items.
    var undated = 0
    /// Order items whose quantity wasn't a whole number above zero; left out of units.
    var itemsWithoutQuantity = 0
}

private let usdCurrencyCodes: Set<String> = ["", "USD"]

/// Builds the report from loaded order records. Months use `calendar` (normally the Mac's, so an order placed late on
/// the 31st lands in the seller's own month). Orders repeated in the list are counted once.
func spendReport(orders records: [Record], modelNames: [String: String] = [:], productSKUs: [String: String] = [:],
                 calendar: Calendar = .current) -> SpendReport {
    var report = SpendReport()
    var months: [String: SpendReportMonth] = [:]
    var items: [String: SpendReportItem] = [:]
    var costs: [String: SpendReportProductCost] = [:]
    var deliveries: [String: SpendReportDeliveryCost] = [:]
    // A country name is matched against every region, so each distinct value is resolved once per report.
    var countryCodes: [String: String] = [:]
    // Saved products with a single print item: their prints are grouped by SKU, so a re-upload stays one product.
    let singlePrintSKUs = Set(productSKUs.values.map(normalizedSKU))
    var seen = Set<String>()
    for record in records {
        let order = orderObject(record.values)
        let number = orderNumber(order)
        if !number.isEmpty, !seen.insert(number).inserted { continue }
        let status = ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard spendReportCountedStatuses.contains(status) else {
            switch status {
            case "DRAFT": report.excludedDrafts += 1
            case "CANCELED", "CANCELLED": report.excludedCancelled += 1
            default: report.excludedOther += 1
            }
            continue
        }
        guard let created = orderCreatedDate(order) else { report.undated += 1; continue }
        let parts = calendar.dateComponents([.year, .month], from: created)
        guard let year = parts.year, let month = parts.month else { report.undated += 1; continue }
        let key = String(format: "%04d-%02d", year, month)
        var bucket = months[key] ?? SpendReportMonth(year: year, month: month)
        bucket.orders += 1
        let currency = ((order["currency"] as? String) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        if usdCurrencyCodes.contains(currency), let total = orderTotalAmount(order) {
            bucket.spend += total
            report.totalSpend += total
        } else {
            bucket.ordersWithoutTotal += 1
            report.ordersWithoutTotal += 1
        }
        months[key] = bucket
        report.countedOrders += 1

        var inThisOrder = Set<String>()
        for item in order["items"] as? [[String: Any]] ?? [] {
            guard let units = orderItemQuantity(item), units > 0 else { report.itemsWithoutQuantity += 1; continue }
            let identity = spendReportItemIdentity(item, modelNames: modelNames, productSKUs: productSKUs)
            var entry = items[identity.key] ?? SpendReportItem(key: identity.key, name: identity.name, sku: identity.sku)
            if entry.sku == nil { entry.sku = identity.sku }
            entry.units += units
            if inThisOrder.insert(identity.key).inserted { entry.orders += 1 }
            items[identity.key] = entry
        }

        let orderIsUSD = usdCurrencyCodes.contains(currency)
        let orderItems = order["items"] as? [[String: Any]] ?? []
        if orderItems.contains(where: { spendReportItemType($0) == "PRINT" }) {
            if orderIsUSD, let lines = spendReportPricedPrintLines(orderItems, printingCost: order["printingCost"]) {
                var costedInThisOrder = Set<String>()
                for line in lines {
                    let identity = spendReportItemIdentity(line.item, modelNames: modelNames, productSKUs: productSKUs)
                    let key: String
                    if let sku = identity.sku, singlePrintSKUs.contains(normalizedSKU(sku)) { key = "sku:\(normalizedSKU(sku))" }
                    else { key = identity.key }
                    var entry = costs[key] ?? SpendReportProductCost(key: key, name: identity.name, sku: identity.sku)
                    if entry.sku == nil { entry.sku = identity.sku }
                    entry.units += line.units
                    entry.total += line.price
                    if costedInThisOrder.insert(key).inserted { entry.orders += 1 }
                    costs[key] = entry
                }
            } else {
                report.ordersWithoutItemPrices += 1
            }
        }
        if orderIsUSD, let delivery = estimateAmount(order["deliveryCost"]), delivery >= 0 {
            let code = spendReportCountryCode(order, cache: &countryCodes)
            var entry = deliveries[code] ?? SpendReportDeliveryCost(countryCode: code)
            entry.orders += 1
            entry.total += delivery
            entry.lowest = min(entry.lowest ?? delivery, delivery)
            entry.highest = max(entry.highest ?? delivery, delivery)
            deliveries[code] = entry
        } else {
            report.ordersWithoutDelivery += 1
        }
    }
    report.months = months.values.sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    report.items = items.values.sorted {
        if $0.units != $1.units { return $0.units > $1.units }
        if $0.orders != $1.orders { return $0.orders > $1.orders }
        let byName = $0.name.localizedStandardCompare($1.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return $0.key < $1.key
    }
    report.productCosts = costs.values.sorted {
        if $0.units != $1.units { return $0.units > $1.units }
        if $0.orders != $1.orders { return $0.orders > $1.orders }
        let byName = $0.name.localizedStandardCompare($1.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return $0.key < $1.key
    }
    report.deliveryCosts = deliveries.values.sorted {
        if $0.countryCode.isEmpty != $1.countryCode.isEmpty { return !$0.countryCode.isEmpty }
        if $0.orders != $1.orders { return $0.orders > $1.orders }
        return $0.countryCode < $1.countryCode
    }
    return report
}

/// The item's type, upper-cased; an untyped item with an uploaded file counts as a print.
func spendReportItemType(_ item: [String: Any]) -> String {
    let declared = ((item["type"] as? String) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
    if !declared.isEmpty { return declared }
    return orderItemFileID(item) == nil ? "" : "PRINT"
}

struct SpendReportPricedLine {
    let item: [String: Any]
    let units: Int
    /// Slant's price for the whole line, in USD.
    let price: Decimal
}

/// The order's print items with their prices, or nil when the prices can't be trusted for a per-product average.
/// Slant's item `price` is the price of the whole line (live, 23 Oct 2026: a line of 2 was priced 19.86 where one unit
/// was 9.93, equal to the order's `printingCost`). So every item must carry a USD price and a whole quantity, and the
/// prices of all items must add up exactly to the order's `printingCost`. Otherwise the order is left out (and counted)
/// rather than split by guesswork.
func spendReportPricedPrintLines(_ items: [[String: Any]], printingCost: Any?) -> [SpendReportPricedLine]? {
    guard !items.isEmpty, let printing = estimateAmount(printingCost), printing >= 0 else { return nil }
    var sum: Decimal = 0
    var lines: [SpendReportPricedLine] = []
    for item in items {
        let currency = ((item["currency"] as? String) ?? "").trimmingCharacters(in: .whitespaces).uppercased()
        guard usdCurrencyCodes.contains(currency), let price = estimateAmount(item["price"]), price >= 0,
              let units = orderItemQuantity(item), units > 0 else { return nil }
        sum += price
        if spendReportItemType(item) == "PRINT" { lines.append(SpendReportPricedLine(item: item, units: units, price: price)) }
    }
    guard sum == printing, !lines.isEmpty else { return nil }
    return lines
}

/// The order's delivery country as an ISO code (an ISO code or an exact country name in the address), or "" when it
/// isn't recognised. Never assumed.
func spendReportCountryCode(_ order: [String: Any]) -> String {
    var cache: [String: String] = [:]
    return spendReportCountryCode(order, cache: &cache)
}

func spendReportCountryCode(_ order: [String: Any], cache: inout [String: String]) -> String {
    let address = ((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any]
    guard let raw = address?["country"] as? String else { return "" }
    if let known = cache[raw] { return known }
    let selection = orderCountrySelection(fromAddressCountry: raw)
    let code = selection.selection == orderCountryOtherTag ? selection.customCode : selection.selection
    cache[raw] = code
    return code
}

/// "Australia (AU)", named like the composer's country list.
func spendReportCountryTitle(_ code: String, locale: Locale = .current) -> String {
    guard !code.isEmpty else { return "Country not recognised" }
    let name = locale.localizedString(forRegionCode: code) ?? code
    return name == code ? code : "\(name) (\(code))"
}

/// How an order item is grouped and named in the report. Print items group by uploaded file and are named like the
/// order detail names them (linked library model, then uploaded file); a generic fallback name gets a short file ID so
/// two unnamed models don't read as one. The SKU is the item's own, else the saved product's for that file.
func spendReportItemIdentity(_ item: [String: Any], modelNames: [String: String],
                             productSKUs: [String: String]) -> (key: String, name: String, sku: String?) {
    let name = orderItemDisplayName(item, modelNames: modelNames)
    let own = spendReportItemSKU(item)
    if let fileID = orderItemFileID(item) {
        let generic = orderItemDisplayName(["type": item["type"] ?? "PRINT"])
        let shown = name == generic ? "\(name) (\(fileID.prefix(8))…)" : name
        return ("file:\(fileID)", shown, own ?? productSKUs[fileID])
    }
    for (kind, keys) in [("component", ["componentId"]), ("stationery", ["stationeryId"])] {
        let nested = (item["\(kind)Item"] as? [String: Any]) ?? [:]
        for key in keys {
            if let id = stringValue(item[key] ?? nested[key])?.trimmingCharacters(in: .whitespaces), !id.isEmpty {
                return ("\(kind):\(id)", name, own)
            }
        }
    }
    let type = ((item["type"] as? String) ?? "").uppercased()
    return ("name:\(type)|\(name.lowercased())", name, own)
}

/// The item's `SKU` (or `sku`), top level or in `printItem`; nil when absent or blank.
func spendReportItemSKU(_ item: [String: Any]) -> String? {
    let nested = item["printItem"] as? [String: Any] ?? [:]
    for value in [item["SKU"], item["sku"], nested["SKU"], nested["sku"]] {
        if let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { return text }
    }
    return nil
}

/// Uploaded file ID → saved product SKU, only where exactly one saved product with a SKU prints that file and it has
/// no other print item, so the SKU can't be credited to the wrong product.
func spendReportProductSKUs(_ products: [SavedProduct], localModels: [LocalModel]) -> [String: String] {
    var candidates: [String: Set<String>] = [:]
    for product in products {
        let sku = product.sku.trimmingCharacters(in: .whitespacesAndNewlines)
        let prints = product.lines.filter { $0.type.uppercased() == "PRINT" }
        guard !sku.isEmpty, prints.count == 1, let line = prints.first else { continue }
        var fileIDs = Set<String>()
        let reference = line.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reference.isEmpty { fileIDs.insert(reference) }
        if let modelID = line.localModelID, let remote = localModels.first(where: { $0.id == modelID })?.remoteID?
            .trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty {
            fileIDs.insert(remote)
        }
        for id in fileIDs { candidates[id, default: []].insert(sku) }
    }
    return candidates.compactMapValues { $0.count == 1 ? $0.first : nil }
}

// MARK: - Wording and output

/// What the loaded list covers, so a partial or filtered list isn't read as the whole account.
func spendReportScopeNotes(searchActive: Bool, statusFilter: String?, hasDateRange: Bool, moreOnServer: Bool) -> [String] {
    var notes: [String] = []
    if searchActive { notes.append("The Orders list shows search results, so only those orders are included. Clear the search to include the rest.") }
    if let statusFilter, !statusFilter.isEmpty {
        notes.append("The Orders list is filtered to \(orderStatusTitle(statusFilter)) orders, so only those are included.")
    }
    if hasDateRange { notes.append("The Orders list is limited to the dates set in Dates & Sort.") }
    if moreOnServer { notes.append("Slant has older orders that aren’t loaded. Use Load More at the end of the Orders list to include them.") }
    return notes
}

/// One line on what was left out, or nil when nothing was.
func spendReportExclusionLine(_ report: SpendReport) -> String? {
    func count(_ n: Int, _ singular: String, _ plural: String) -> String? { n == 0 ? nil : "\(n) \(n == 1 ? singular : plural)" }
    let parts = [
        count(report.excludedDrafts, "draft", "drafts"),
        count(report.excludedCancelled, "cancelled order", "cancelled orders"),
        count(report.excludedOther, "order with a payment error or another status", "orders with a payment error or another status"),
        count(report.undated, "order without a date", "orders without a date"),
    ].compactMap { $0 }
    return parts.isEmpty ? nil : "Left out: " + parts.joined(separator: ", ") + "."
}

func spendReportMonthTitle(_ month: SpendReportMonth, calendar: Calendar = .current) -> String {
    guard let date = calendar.date(from: DateComponents(year: month.year, month: month.month, day: 1)) else { return month.id }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = calendar.locale ?? .current
    formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
    return formatter.string(from: date)
}

/// Plain decimal for CSV cells ("1234.50"), never grouped or localised.
func spendReportCSVAmount(_ amount: Decimal) -> String {
    let formatter = NumberFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.numberStyle = .decimal
    formatter.usesGroupingSeparator = false
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? ""
}

func spendReportItemTitle(_ item: SpendReportItem) -> String {
    item.sku.map { "\(item.name) (SKU \($0))" } ?? item.name
}

/// Items shown in the sheet and the copied text; the CSV lists them all.
let spendReportTopItemLimit = 10

/// Under the printing costs table and in the copied text.
let spendReportProductCostCaption = "Slant’s price for each print item, from orders whose item prices add up to their printing cost. Components, stationery and delivery aren’t included, and each average covers every material used."
/// Under the delivery table and in the copied text.
let spendReportDeliveryCaption = "What Slant charged to deliver each order, in USD: a guide for your Etsy or Shopify shipping profiles. Slant prices delivery only when a draft is created, so past orders are the best evidence available. Orders with more or heavier items usually cost more to send."

/// Why some orders are missing from the printing costs table, or nil.
func spendReportItemPriceExclusionLine(_ report: SpendReport) -> String? {
    let n = report.ordersWithoutItemPrices
    guard n > 0 else { return nil }
    return "\(n) \(n == 1 ? "order is" : "orders are") left out because \(n == 1 ? "its" : "their") item prices were missing or didn’t add up to the order’s printing cost."
}

/// Why some orders are missing from the delivery table, or nil.
func spendReportDeliveryExclusionLine(_ report: SpendReport) -> String? {
    let n = report.ordersWithoutDelivery
    guard n > 0 else { return nil }
    return "\(n) \(n == 1 ? "order has" : "orders have") no delivery cost in USD and \(n == 1 ? "isn’t" : "aren’t") included."
}

func spendReportUSD(_ amount: Decimal?) -> String {
    amount.map { money(NSDecimalNumber(decimal: $0)) } ?? "—"
}

/// "$22.80–$41.20", or one amount when every order cost the same.
func spendReportRangeText(_ entry: SpendReportDeliveryCost) -> String {
    guard let lowest = entry.lowest, let highest = entry.highest else { return "—" }
    return lowest == highest ? spendReportUSD(lowest) : "\(spendReportUSD(lowest))–\(spendReportUSD(highest))"
}

/// Default source phrase: the report is built from the Orders list.
let spendReportLoadedListSource = "in the loaded Orders list"

/// The report as plain text for pasting into notes or a message.
func spendReportText(_ report: SpendReport, notes: [String], calendar: Calendar = .current,
                     source: String = spendReportLoadedListSource) -> String {
    var lines = ["Slant spending report",
                 "From \(report.countedOrders == 1 ? "1 order" : "\(report.countedOrders) orders") \(source). Amounts are Slant’s order totals in USD."]
    if let exclusions = spendReportExclusionLine(report) { lines.append(exclusions) }
    lines += notes
    lines.append("")
    lines.append("Month — orders — spend")
    for month in report.months {
        var line = "\(spendReportMonthTitle(month, calendar: calendar)) — \(month.orders) — \(money(NSDecimalNumber(decimal: month.spend)))"
        if month.ordersWithoutTotal > 0 { line += " (\(month.ordersWithoutTotal) without a total)" }
        lines.append(line)
    }
    lines.append("Total — \(report.countedOrders) — \(money(NSDecimalNumber(decimal: report.totalSpend)))")
    if !report.items.isEmpty {
        lines.append("")
        lines.append("Top items by units")
        for item in report.items.prefix(spendReportTopItemLimit) {
            lines.append("\(spendReportItemTitle(item)) — \(item.units) \(item.units == 1 ? "unit" : "units") in \(item.orders) \(item.orders == 1 ? "order" : "orders")")
        }
    }
    if !report.productCosts.isEmpty || report.ordersWithoutItemPrices > 0 {
        lines.append("")
        lines.append("Average printing cost per product")
        lines.append(spendReportProductCostCaption)
        if let exclusion = spendReportItemPriceExclusionLine(report) { lines.append(exclusion) }
        for cost in report.productCosts.prefix(spendReportTopItemLimit) {
            lines.append("\(spendReportProductCostTitle(cost)) — \(cost.units) \(cost.units == 1 ? "unit" : "units") in \(cost.orders) \(cost.orders == 1 ? "order" : "orders") — \(spendReportUSD(cost.total)) — \(spendReportUSD(cost.averagePerUnit)) each")
        }
    }
    if !report.deliveryCosts.isEmpty || report.ordersWithoutDelivery > 0 {
        lines.append("")
        lines.append("Delivery by destination country")
        lines.append(spendReportDeliveryCaption)
        if let exclusion = spendReportDeliveryExclusionLine(report) { lines.append(exclusion) }
        for entry in report.deliveryCosts {
            lines.append("\(spendReportCountryTitle(entry.countryCode)) — \(entry.orders) \(entry.orders == 1 ? "order" : "orders") — average \(spendReportUSD(entry.average)) — \(spendReportRangeText(entry))")
        }
    }
    return lines.joined(separator: "\n") + "\n"
}

func spendReportProductCostTitle(_ cost: SpendReportProductCost) -> String {
    cost.sku.map { "\(cost.name) (SKU \($0))" } ?? cost.name
}

/// Tables in one CSV, separated by blank rows: months (newest first, then a total), every item by units, and, when
/// the orders carry them, printing cost per product and delivery per country. Every field goes through `csvField`,
/// so names starting with = + - @ can't run as formulas.
func spendReportCSV(_ report: SpendReport) -> String {
    var rows: [[String]] = [["Month", "Orders", "Spend (USD)", "Orders without a total"]]
    for month in report.months {
        rows.append([month.id, String(month.orders), spendReportCSVAmount(month.spend), String(month.ordersWithoutTotal)])
    }
    rows.append(["Total", String(report.countedOrders), spendReportCSVAmount(report.totalSpend), String(report.ordersWithoutTotal)])
    rows.append([])
    rows.append(["Item", "SKU", "Units", "Orders"])
    for item in report.items {
        rows.append([item.name, item.sku ?? "", String(item.units), String(item.orders)])
    }
    if !report.productCosts.isEmpty {
        rows.append([])
        rows.append(["Product", "SKU", "Orders", "Units", "Printing cost (USD)", "Average per unit (USD)"])
        for cost in report.productCosts {
            rows.append([cost.name, cost.sku ?? "", String(cost.orders), String(cost.units), spendReportCSVAmount(cost.total),
                         cost.averagePerUnit.map(spendReportCSVAmount) ?? ""])
        }
    }
    if !report.deliveryCosts.isEmpty {
        rows.append([])
        rows.append(["Destination country", "Country code", "Orders", "Delivery (USD)", "Average (USD)", "Lowest (USD)", "Highest (USD)"])
        for entry in report.deliveryCosts {
            rows.append([spendReportCountryTitle(entry.countryCode, locale: Locale(identifier: "en_US")), entry.countryCode,
                         String(entry.orders), spendReportCSVAmount(entry.total), entry.average.map(spendReportCSVAmount) ?? "",
                         entry.lowest.map(spendReportCSVAmount) ?? "", entry.highest.map(spendReportCSVAmount) ?? ""])
        }
    }
    return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
}

func spendReportDefaultFileName(date: Date = Date()) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    return "Slant spending \(formatter.string(from: date)).csv"
}

// MARK: - Store actions

extension StudioStore {
    /// File › Spending Report… and Orders › More: Orders only, with orders loaded and nothing modal shown. No request.
    func openSpendingReportFromMenu() {
        guard !menuCommandsBlockedByModalUI, ordersExportMenuEnabled(destination: destination, ordersLoaded: !orders.isEmpty,
                                                                     sheetPresented: false) else { return }
        showSpendingReport = true
    }

    var spendReportNotes: [String] {
        spendReportScopeNotes(searchActive: orderSearchActive, statusFilter: orderFilter.status,
                              hasDateRange: orderFilter.startDate != nil || orderFilter.endDate != nil,
                              moreOnServer: ordersHasMore && !orderSearchActive)
    }

    var currentSpendReport: SpendReport { spendReport(for: orders) }

    func spendReport(for records: [Record]) -> SpendReport {
        SlantStudio.spendReport(orders: records, modelNames: orderItemModelNames(localModels: localModels, files: files),
                    productSKUs: spendReportProductSKUs(savedProducts, localModels: localModels))
    }
}

// MARK: - Load the whole period
//
// A read-only `GET /orders` walk over one period, page by page, for this report only. It runs through `store.run`, so
// the app-wide busy flag is held and nothing else starts meanwhile; it never retries, stops (keeping what it loaded)
// when Slant's rate limit runs low, after a 429 or any error, and when stopped or the sheet closes. The orders it
// fetches stay in the sheet's memory: `store.orders` and the Orders list are never changed.

enum SpendReportPeriod: String, CaseIterable, Identifiable {
    case thisMonth, last3Months, last6Months, last12Months, thisYear, lastYear
    var id: String { rawValue }
    var title: String {
        switch self {
        case .thisMonth: return "This month"
        case .last3Months: return "Last 3 months"
        case .last6Months: return "Last 6 months"
        case .last12Months: return "Last 12 months"
        case .thisYear: return "This year"
        case .lastYear: return "Last year"
        }
    }
}

/// A period of whole local days: `start` (midnight) up to, not including, `end`.
struct SpendReportInterval: Equatable {
    let start: Date
    let end: Date
    func contains(_ date: Date) -> Bool { date >= start && date < end }
}

/// The period in the Mac's calendar. "Last 3 months" is this month and the two before it, so its months match the
/// report's; periods that include today end at the end of today.
func spendReportPeriodInterval(_ period: SpendReportPeriod, now: Date = Date(), calendar: Calendar = .current) -> SpendReportInterval {
    let today = calendar.startOfDay(for: now)
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
    let monthStart = calendar.date(from: calendar.dateComponents([.year, .month], from: now)) ?? today
    let yearStart = calendar.date(from: calendar.dateComponents([.year], from: now)) ?? today
    func monthsBack(_ n: Int) -> Date { calendar.date(byAdding: .month, value: -n, to: monthStart) ?? monthStart }
    switch period {
    case .thisMonth: return SpendReportInterval(start: monthStart, end: tomorrow)
    case .last3Months: return SpendReportInterval(start: monthsBack(2), end: tomorrow)
    case .last6Months: return SpendReportInterval(start: monthsBack(5), end: tomorrow)
    case .last12Months: return SpendReportInterval(start: monthsBack(11), end: tomorrow)
    case .thisYear: return SpendReportInterval(start: yearStart, end: tomorrow)
    case .lastYear:
        return SpendReportInterval(start: calendar.date(byAdding: .year, value: -1, to: yearStart) ?? yearStart, end: yearStart)
    }
}

/// Orders per page: the same page size the Orders list uses.
let spendReportPeriodPageSize = listPageSize
/// At most this many pages for one report (5,000 orders at 100 a page).
let spendReportPeriodMaxPages = 50

/// `GET /orders` query for one page of the period. Slant reads `startDate`/`endDate` as dates without saying in which
/// time zone, and `endDate` is exclusive, so the request asks for a day either side and `spendReportPeriodOrders`
/// keeps only the orders created inside the period on the Mac's calendar. Oldest first, so orders created while the
/// pages load are added at the end and never shift a page already read.
func spendReportPeriodQuery(_ interval: SpendReportInterval, page: Int, platformID: String,
                            calendar: Calendar = .current) -> [String: String] {
    let before = calendar.date(byAdding: .day, value: -1, to: interval.start) ?? interval.start
    let after = calendar.date(byAdding: .day, value: 1, to: interval.end) ?? interval.end
    var query = ["page": String(page), "limit": String(spendReportPeriodPageSize), "sortBy": "createdAt", "sortOrder": "ASC",
                 "startDate": spendReportDayString(before, calendar: calendar), "endDate": spendReportDayString(after, calendar: calendar)]
    let platform = platformID.trimmingCharacters(in: .whitespacesAndNewlines)
    if !platform.isEmpty { query["platformId"] = platform }
    return query
}

func spendReportDayString(_ date: Date, calendar: Calendar = .current) -> String {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

/// Adds a page to what was loaded: orders created outside the period are dropped, and an order already loaded (by
/// order number) isn't added again. Orders without a readable date are kept, so the report counts them as undated.
func spendReportPeriodOrders(_ existing: [Record], adding page: [Record], interval: SpendReportInterval) -> [Record] {
    var seen = Set(existing.map { orderNumber(orderObject($0.values)) })
    var result = existing
    for record in page {
        let order = orderObject(record.values)
        if let created = orderCreatedDate(order), !interval.contains(created) { continue }
        let number = orderNumber(order)
        if !number.isEmpty, !seen.insert(number).inserted { continue }
        result.append(record)
    }
    return result
}

/// Whether a `GET /orders` reply lists orders (possibly none): `data` is an array, or an object holding `orders`.
/// An unreadable reply must stop the load rather than look like the last page.
func spendReportPageIsReadable(_ json: Any?) -> Bool {
    guard let root = json as? [String: Any] else { return false }
    if root["data"] is [Any] { return true }
    if let data = root["data"] as? [String: Any], data["orders"] is [Any] { return true }
    return false
}

enum SpendReportPageStep: Equatable {
    case next
    case complete
    case capReached
}

/// After a page: finished when Slant says there are no more pages (or sent an empty one), stopped at the page cap.
func spendReportPageStep(pagesLoaded: Int, hasMore: Bool, pageWasEmpty: Bool, maxPages: Int = spendReportPeriodMaxPages) -> SpendReportPageStep {
    if !hasMore || pageWasEmpty { return .complete }
    return pagesLoaded >= maxPages ? .capReached : .next
}

func spendReportPeriodLoadBlockedReason(hasKey: Bool, connected: Bool, busy: Bool, running: Bool) -> String? {
    if !hasKey || !connected { return "Connect your account to load orders." }
    if running { return "Loading orders…" }
    if busy { return "Wait for the current task to finish." }
    return nil
}

func spendReportLoadedCountText(_ count: Int) -> String {
    count == 1 ? "1 order" : "\(count.formatted()) orders"
}

/// "Loaded 340 orders…" while the pages come in.
func spendReportLoadProgress(_ count: Int) -> String {
    "Loaded \(spendReportLoadedCountText(count))…"
}

/// "1 Aug – 24 Oct 2026" (the end shown is the last day included).
func spendReportIntervalTitle(_ interval: SpendReportInterval, calendar: Calendar = .current) -> String {
    let formatter = DateIntervalFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.locale = calendar.locale ?? .current
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.end
    return formatter.string(from: interval.start, to: max(interval.start, lastDay))
}

/// Where the report's orders came from, after "From N orders …".
func spendReportPeriodSource(_ interval: SpendReportInterval, calendar: Calendar = .current) -> String {
    "created \(spendReportIntervalTitle(interval, calendar: calendar)), loaded for this report"
}

/// Notes for a report built from a loaded period: platform scope and, when it isn't complete, how far it reaches.
func spendReportPeriodNotes(platformName: String?, complete: Bool, capReached: Bool, loadedCount: Int,
                            lastCreated: Date?, calendar: Calendar = .current) -> [String] {
    var notes: [String] = []
    if let platformName, !platformName.isEmpty {
        notes.append("Only orders on the platform “\(platformName)” are included, like the Orders list.")
    }
    if !complete {
        let reach = lastCreated.map { date -> String in
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = calendar.locale ?? .current
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            return " It covers orders created up to \(formatter.string(from: date))."
        } ?? ""
        if capReached {
            notes.append("Not the whole period: Studio loads at most \(spendReportPeriodMaxPages) pages (\((spendReportPeriodMaxPages * spendReportPeriodPageSize).formatted()) orders) for one report.\(reach) Choose a shorter period to see the rest.")
        } else {
            notes.append("Not the whole period yet: \(spendReportLoadedCountText(loadedCount)) loaded.\(reach) Choose Continue Loading for the rest.")
        }
    }
    notes.append("These orders are only used here; the Orders list isn’t changed.")
    return notes
}

/// Why loading stopped, as shown in the sheet. Nothing is retried; Continue Loading carries on from the next page.
func spendReportLoadStopMessage(_ error: Error) -> String {
    switch comparisonErrorDisposition(error) {
    case .cancelled: return "Stopped. Orders already loaded are kept."
    case .stopRun(let reason), .failCell(let reason):
        if let studio = error as? StudioError { return studio.message }
        return reason.hasPrefix("Stopped") ? reason : "Stopped: \(reason)"
    }
}

@MainActor final class SpendReportPeriodLoader: ObservableObject {
    struct Load {
        let period: SpendReportPeriod
        let interval: SpendReportInterval
        let platformID: String
        var records: [Record] = []
        var nextPage = 1
        var complete = false
        var capReached = false
        var lastCreated: Date?
    }

    @Published private(set) var load: Load?
    @Published private(set) var running = false
    @Published private(set) var message: String?
    private var task: Task<Void, Never>?
    private var generation = 0
    private var lastRequestStart: Date?
    private var observedAt: Date?
    private var rateLimitedUntil: Date?

    /// The loaded period, only while it belongs to the store's current platform.
    func current(platformID: String) -> Load? {
        guard let load, load.platformID == platformID.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        return load
    }

    var canContinue: Bool {
        guard let load, !running else { return false }
        return !load.complete && !load.capReached
    }

    func start(_ period: SpendReportPeriod, store: StudioStore) {
        guard !running else { return }
        let interval = spendReportPeriodInterval(period)
        load = Load(period: period, interval: interval, platformID: store.platformID.trimmingCharacters(in: .whitespacesAndNewlines))
        run(store: store)
    }

    func continueLoading(store: StudioStore) {
        guard canContinue, current(platformID: store.platformID) != nil else { return }
        run(store: store)
    }

    /// Back to the Orders list: forgets what was loaded.
    func reset() {
        guard !running else { return }
        load = nil
        message = nil
    }

    /// Stop button and sheet close: cancels the page being read; nothing that arrives afterwards is used.
    func stop() {
        guard running else { return }
        generation += 1
        task?.cancel()
        task = nil
        running = false
        message = "Stopped. Orders already loaded are kept."
    }

    private func run(store: StudioStore) {
        if let reason = spendReportPeriodLoadBlockedReason(hasKey: store.hasKey, connected: store.connected, busy: store.busy, running: running) {
            message = reason
            return
        }
        generation += 1
        let runGeneration = generation
        running = true
        message = nil
        task = Task { [weak self] in
            guard let self else { return }
            var stopMessage: String?
            let started = await store.run("Load orders for spending report", handlesError: { error in
                stopMessage = spendReportLoadStopMessage(error)
                return true
            }) {
                try await self.fetchPages(store: store, generation: runGeneration)
            }
            guard runGeneration == self.generation else { return }
            self.running = false
            self.task = nil
            self.message = started ? stopMessage : "Wait for the current task to finish."
        }
    }

    private func fetchPages(store: StudioStore, generation runGeneration: Int) async throws {
        while true {
            guard runGeneration == generation, var current = load else { throw CancellationError() }
            try Task.checkCancellation()
            guard current.platformID == store.platformID.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw StudioError("Stopped because the default platform changed.")
            }
            if let until = rateLimitedUntil, until > Date() {
                throw StudioError("Stopped: Slant’s rate limit was reached. \(rateLimitResetWaitCopy(secondsFromNow: until.timeIntervalSinceNow)) Then choose Continue Loading.")
            }
            if case .stop(let reason) = comparisonPacing(rateLimit: store.rateLimit, observedAt: observedAt, now: Date()) {
                throw StudioError("\(reason) Then choose Continue Loading.")
            }
            if let last = lastRequestStart {
                let wait = comparisonMinimumSpacing - Date().timeIntervalSince(last)
                if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            guard runGeneration == generation else { throw CancellationError() }
            let query = spendReportPeriodQuery(current.interval, page: current.nextPage, platformID: current.platformID)
            lastRequestStart = Date()
            let response: APIResponse
            do {
                response = try await store.client.request("GET", path: "/orders", query: query)
            } catch {
                if case APIError.http(429, _, let retryAfter, let reset) = error {
                    rateLimitedUntil = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date())
                }
                throw error
            }
            guard runGeneration == generation else { throw CancellationError() }
            if response.rateLimit.hasValues { observedAt = Date() }
            store.noteBackgroundRateLimit(from: response)
            guard spendReportPageIsReadable(response.json) else {
                throw APIError.invalidResponse("Slant’s reply didn’t list orders.")
            }
            let page = responseRecords(response)
            current.records = spendReportPeriodOrders(current.records, adding: page, interval: current.interval)
            current.lastCreated = current.records.compactMap { orderCreatedDate(orderObject($0.values)) }.max()
            let hasMore = listHasMorePages(pagination: responsePagination(response), recordCount: page.count,
                                           currentPage: current.nextPage, pageSize: spendReportPeriodPageSize)
            let pagesLoaded = current.nextPage
            current.nextPage += 1
            switch spendReportPageStep(pagesLoaded: pagesLoaded, hasMore: hasMore, pageWasEmpty: page.isEmpty) {
            case .complete: current.complete = true
            case .capReached: current.capReached = true
            case .next: break
            }
            load = current
            store.progress = spendReportLoadProgress(current.records.count)
            if current.complete || current.capReached { return }
        }
    }
}

// MARK: - Sheet

/// "the 3 orders", "the 1 order", or "the orders" when none are counted.
func spendReportOrdersPhrase(_ count: Int) -> String {
    switch count {
    case 0: return "the orders"
    case 1: return "the 1 order"
    default: return "the \(count) orders"
    }
}

struct SpendingReportSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var exportError: String?
    /// Orders fetched by Load the Whole Period: in this sheet's memory only, never in `store.orders`.
    @StateObject private var periodLoader = SpendReportPeriodLoader()
    @State private var period: SpendReportPeriod = .last3Months

    var body: some View {
        let loaded = store.hasKey ? periodLoader.current(platformID: store.platformID) : nil
        let report = loaded.map { store.spendReport(for: $0.records) } ?? store.currentSpendReport
        let notes = loaded.map {
            spendReportPeriodNotes(platformName: platformName($0.platformID), complete: $0.complete, capReached: $0.capReached,
                                   loadedCount: $0.records.count, lastCreated: $0.lastCreated)
        } ?? store.spendReportNotes
        let source = loaded.map { spendReportPeriodSource($0.interval) } ?? spendReportLoadedListSource
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spending report").font(.title2.weight(.bold))
                Text(loaded.map { "What Slant charged for \(spendReportOrdersPhrase(report.countedOrders)) created \(spendReportIntervalTitle($0.interval)), by month, in USD. Drafts, cancelled orders and payment errors aren’t included. Nothing here is saved." }
                     ?? "What Slant charged for \(spendReportOrdersPhrase(report.countedOrders)) loaded in Orders, by month, in USD. Drafts, cancelled orders and payment errors aren’t included. Nothing here is saved.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                periodControls(loaded)
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let exclusions = spendReportExclusionLine(report) {
                    Text(exclusions).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
            Divider()
            if report.countedOrders == 0 {
                ContentUnavailableView(loaded == nil ? "No charged orders loaded" : "No charged orders in this period", systemImage: "chart.bar",
                                       description: Text(loaded == nil ? "Only drafts, cancelled orders or orders without a date are loaded."
                                                         : "Slant returned only drafts, cancelled orders or orders without a date for this period."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        monthsTable(report)
                        if !report.items.isEmpty { itemsTable(report) }
                        if !report.productCosts.isEmpty || report.ordersWithoutItemPrices > 0 { productCostsTable(report) }
                        if !report.deliveryCosts.isEmpty || report.ordersWithoutDelivery > 0 { deliveryTable(report) }
                    }
                    .padding(24)
                }
            }
            Divider()
            HStack {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let exportError {
                    Label(exportError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).lineLimit(2)
                } else if copied {
                    Text("Copied").font(.callout).foregroundStyle(.secondary)
                }
                Button("Copy as Text") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(spendReportText(report, notes: notes, source: source), forType: .string)
                    copied = true
                }
                .disabled(report.countedOrders == 0)
                Button("Export CSV…") { exportCSV(report) }
                    .disabled(report.countedOrders == 0)
            }
            .padding(20)
        }
        .frame(width: 640, height: 680)
        .onChange(of: period) { _, _ in periodLoader.reset() }
        .onDisappear { periodLoader.stop() }
    }

    private func platformName(_ id: String) -> String? {
        guard !id.isEmpty, let record = store.platforms.first(where: { $0.id == id }) else { return nil }
        let name = displayName(for: record, fallback: "")
        return name.isEmpty ? nil : name
    }

    /// Load the Whole Period: a period picker, the button, progress and Stop, and what happened last.
    @ViewBuilder
    private func periodControls(_ loaded: SpendReportPeriodLoader.Load?) -> some View {
        let blocked = spendReportPeriodLoadBlockedReason(hasKey: store.hasKey, connected: store.connected,
                                                         busy: store.busy, running: periodLoader.running)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Picker("Period", selection: $period) {
                    ForEach(SpendReportPeriod.allCases) { Text($0.title).tag($0) }
                }
                .fixedSize()
                .disabled(periodLoader.running)
                if periodLoader.running {
                    ProgressView().controlSize(.small)
                    Text(spendReportLoadProgress(periodLoader.load?.records.count ?? 0)).font(.callout).monospacedDigit()
                    Button("Stop") { periodLoader.stop() }
                } else {
                    Button("Load the Whole Period") { periodLoader.start(period, store: store) }
                        .disabled(blocked != nil)
                        .help(blocked ?? "Read every order created in \(spendReportIntervalTitle(spendReportPeriodInterval(period))) from Slant, one page at a time")
                    if periodLoader.canContinue, loaded != nil {
                        Button("Continue Loading") { periodLoader.continueLoading(store: store) }
                            .disabled(blocked != nil)
                    }
                    if loaded != nil {
                        Button("Use Orders List") { periodLoader.reset() }
                            .help("Show the report for the orders loaded in Orders again")
                    }
                }
            }
            if let message = periodLoader.message {
                Text(message).font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            } else if periodLoader.load != nil, loaded == nil, !periodLoader.running {
                Text("The default platform changed, so the loaded period isn’t shown. Load it again.")
                    .font(.caption).foregroundStyle(.orange)
            } else if loaded == nil, let blocked, !periodLoader.running {
                Text(blocked).font(.caption).foregroundStyle(.secondary)
            } else if loaded == nil {
                Text("Reads every order in \(spendReportIntervalTitle(spendReportPeriodInterval(period))) from Slant for this report, without changing the Orders list.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func productCostsTable(_ report: SpendReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Average printing cost per product",
                           caption: report.productCosts.count > spendReportTopItemLimit ? "The CSV lists all \(report.productCosts.count) products" : "")
            if !report.productCosts.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Product"); Text("Orders").gridColumnAlignment(.trailing); Text("Units").gridColumnAlignment(.trailing)
                        Text("Printing").gridColumnAlignment(.trailing); Text("Each").gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.productCosts.prefix(spendReportTopItemLimit)) { cost in
                        GridRow {
                            Text(spendReportProductCostTitle(cost)).lineLimit(2)
                            Text("\(cost.orders)").monospacedDigit()
                            Text("\(cost.units)").monospacedDigit()
                            Text(spendReportUSD(cost.total)).monospacedDigit()
                            Text(spendReportUSD(cost.averagePerUnit)).monospacedDigit().fontWeight(.semibold)
                        }
                    }
                }
                .textSelection(.enabled)
            }
            Text(spendReportProductCostCaption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let exclusion = spendReportItemPriceExclusionLine(report) {
                Text(exclusion).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func deliveryTable(_ report: SpendReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Delivery by destination country")
            if !report.deliveryCosts.isEmpty {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                    GridRow {
                        Text("Country"); Text("Orders").gridColumnAlignment(.trailing); Text("Average").gridColumnAlignment(.trailing)
                        Text("Range").gridColumnAlignment(.trailing)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                    ForEach(report.deliveryCosts) { entry in
                        GridRow {
                            Text(spendReportCountryTitle(entry.countryCode)).lineLimit(2)
                            Text("\(entry.orders)").monospacedDigit()
                            Text(spendReportUSD(entry.average)).monospacedDigit().fontWeight(.semibold)
                            Text(spendReportRangeText(entry)).monospacedDigit()
                        }
                    }
                }
                .textSelection(.enabled)
            }
            Text(spendReportDeliveryCaption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let exclusion = spendReportDeliveryExclusionLine(report) {
                Text(exclusion).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func monthsTable(_ report: SpendReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "By month")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Month"); Text("Orders").gridColumnAlignment(.trailing); Text("Spend").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(report.months) { month in
                    GridRow {
                        Text(spendReportMonthTitle(month))
                        Text("\(month.orders)").monospacedDigit()
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(money(NSDecimalNumber(decimal: month.spend))).monospacedDigit()
                            if month.ordersWithoutTotal > 0 {
                                Text("\(month.ordersWithoutTotal) without a total").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                GridRow {
                    Text("Total").fontWeight(.semibold)
                    Text("\(report.countedOrders)").monospacedDigit().fontWeight(.semibold)
                    Text(money(NSDecimalNumber(decimal: report.totalSpend))).monospacedDigit().fontWeight(.semibold)
                }
            }
            .textSelection(.enabled)
        }
    }

    private func itemsTable(_ report: SpendReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeading(title: "Top items by units",
                           caption: report.items.count > spendReportTopItemLimit ? "The CSV lists all \(report.items.count) items" : "")
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    Text("Item"); Text("Units").gridColumnAlignment(.trailing); Text("Orders").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(report.items.prefix(spendReportTopItemLimit)) { item in
                    GridRow {
                        Text(spendReportItemTitle(item)).lineLimit(2)
                        Text("\(item.units)").monospacedDigit()
                        Text("\(item.orders)").monospacedDigit()
                    }
                }
            }
            .textSelection(.enabled)
            if report.itemsWithoutQuantity > 0 {
                Text("\(report.itemsWithoutQuantity) \(report.itemsWithoutQuantity == 1 ? "item had" : "items had") no readable quantity and \(report.itemsWithoutQuantity == 1 ? "isn’t" : "aren’t") counted.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func exportCSV(_ report: SpendReport) {
        let panel = NSSavePanel()
        panel.title = "Export Spending Report"
        panel.nameFieldStringValue = spendReportDefaultFileName()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        exportError = nil
        // A UTF-8 byte order mark lets spreadsheet apps read non-ASCII names correctly.
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(spendReportCSV(report).utf8)
        do {
            try data.write(to: destination, options: .atomic)
            store.activities.insert(Activity(title: "Export spending report", detail: report.countedOrders == 1 ? "1 order" : "\(report.countedOrders) orders", success: true), at: 0)
        } catch {
            // Shown in the sheet: a window alert behind it would wait until the sheet closes.
            exportError = "Not exported: \(error.localizedDescription)"
        }
    }
}
