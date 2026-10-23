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

struct SpendReport: Equatable {
    /// Newest month first.
    var months: [SpendReportMonth] = []
    /// Most units first.
    var items: [SpendReportItem] = []
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
    }
    report.months = months.values.sorted { ($0.year, $0.month) > ($1.year, $1.month) }
    report.items = items.values.sorted {
        if $0.units != $1.units { return $0.units > $1.units }
        if $0.orders != $1.orders { return $0.orders > $1.orders }
        let byName = $0.name.localizedStandardCompare($1.name)
        if byName != .orderedSame { return byName == .orderedAscending }
        return $0.key < $1.key
    }
    return report
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

/// The report as plain text for pasting into notes or a message.
func spendReportText(_ report: SpendReport, notes: [String], calendar: Calendar = .current) -> String {
    var lines = ["Slant spending report",
                 "From \(report.countedOrders == 1 ? "1 order" : "\(report.countedOrders) orders") in the loaded Orders list. Amounts are Slant’s order totals in USD."]
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
    return lines.joined(separator: "\n") + "\n"
}

/// Two tables in one CSV, separated by a blank row: months (newest first, then a total) and every item by units.
/// Every field goes through `csvField`, so names starting with = + - @ can't run as formulas.
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

    var currentSpendReport: SpendReport {
        spendReport(orders: orders, modelNames: orderItemModelNames(localModels: localModels, files: files),
                    productSKUs: spendReportProductSKUs(savedProducts, localModels: localModels))
    }
}

// MARK: - Sheet

struct SpendingReportSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false
    @State private var exportError: String?

    var body: some View {
        let report = store.currentSpendReport
        let notes = store.spendReportNotes
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Spending report").font(.title2.weight(.bold))
                Text("What Slant charged for the \(report.countedOrders == 1 ? "1 order" : "\(report.countedOrders) orders") loaded in Orders, by month, in USD. Drafts, cancelled orders and payment errors aren’t included. Nothing here is saved.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(notes, id: \.self) { note in
                    Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let exclusions = spendReportExclusionLine(report) {
                    Text(exclusions).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            Divider()
            if report.countedOrders == 0 {
                ContentUnavailableView("No charged orders loaded", systemImage: "chart.bar",
                                       description: Text("Only drafts, cancelled orders or orders without a date are loaded."))
                    .frame(maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        monthsTable(report)
                        if !report.items.isEmpty { itemsTable(report) }
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
                    NSPasteboard.general.setString(spendReportText(report, notes: notes), forType: .string)
                    copied = true
                }
                .disabled(report.countedOrders == 0)
                Button("Export CSV…") { exportCSV(report) }
                    .disabled(report.countedOrders == 0)
            }
            .padding(20)
        }
        .frame(width: 560, height: 600)
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
