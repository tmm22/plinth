import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Order follow-up: getting Slant's tracking back to the marketplace (Tracking for Your Shop…), a Shopify tracking
// CSV, the arrive-by date and the Needs Attention check. Everything here reads orders already loaded; nothing sends a
// request, and nothing is written to disk except a CSV the user saves.

// MARK: - Arrive-by date

private let arriveByUTC = TimeZone(identifier: "UTC") ?? .gmt

/// The order's `arriveByDate` (Order schema, nullable; also looked for on `fulfillment`). An estimated delivery
/// isn't a promise, so it is not used here. Nil when absent or unreadable.
func orderArriveByDate(_ order: [String: Any]) -> Date? {
    var candidates: [Any?] = [order["arriveByDate"]]
    if let fulfillment = order["fulfillment"] as? [String: Any] { candidates.append(fulfillment["arriveByDate"]) }
    for value in candidates {
        if let raw = value as? String, let date = orderTimestamp(raw) { return date }
    }
    return nil
}

/// A timestamp at exactly midnight UTC is a calendar date sent as a date-time ("2026-10-25T00:00:00.000Z").
func orderArriveByIsDateOnly(_ date: Date) -> Bool {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = arriveByUTC
    let parts = calendar.dateComponents([.hour, .minute, .second, .nanosecond], from: date)
    return parts.hour == 0 && parts.minute == 0 && parts.second == 0 && (parts.nanosecond ?? 0) < 1_000_000
}

/// When the order counts as late: for a date-only value, the end of that calendar day in the Mac's time zone (so a
/// parcel due "25 Oct" isn't late during the 25th anywhere, west or east of Greenwich); otherwise the timestamp itself.
func orderArriveByDeadline(_ date: Date, timeZone: TimeZone = .current) -> Date {
    guard orderArriveByIsDateOnly(date) else { return date }
    var utc = Calendar(identifier: .gregorian)
    utc.timeZone = arriveByUTC
    var local = Calendar(identifier: .gregorian)
    local.timeZone = timeZone
    // The day Slant sent (read in UTC), as a local calendar day; late from the start of the next local day.
    let day = utc.dateComponents([.year, .month, .day], from: date)
    guard let start = local.date(from: day), let end = local.date(byAdding: .day, value: 1, to: start) else {
        return date.addingTimeInterval(86_400)
    }
    return end
}

/// "25 Oct 2026". A date-only value is shown in UTC, so it isn't shifted to the previous day west of Greenwich.
func orderArriveByLabel(_ date: Date) -> String {
    if orderArriveByIsDateOnly(date) {
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = arriveByUTC
        return date.formatted(style)
    }
    return date.formatted(date: .abbreviated, time: .omitted)
}

/// Sort value for orders without an arrive-by date: last when sorting soonest first, so due orders lead.
let orderMissingArriveBySortKey = Date.distantFuture
/// The orders table's Arrive by column, the only one with a customization ID (its visibility follows the data).
let orderArriveByColumnID = "arriveBy"

// MARK: - Needs attention

/// A draft older than this hasn't been placed, so its customer is waiting. Two days covers a weekend's delay in
/// reviewing imported drafts without flagging ones made today or yesterday.
let orderAttentionDraftDays = 2
/// Drafts older than this are left alone: Slant can't cancel or remove a draft, so an abandoned or duplicate draft
/// would otherwise be flagged for ever. A month is well past any marketplace's dispatch window.
let orderAttentionDraftIgnoredAfterDays = 30
/// A placed order not shipped after this long looks stuck. Slant doesn't document a turnaround, so five days is a
/// conservative stand-in that leaves room for printing and finishing before flagging.
let orderAttentionProductionDays = 5

/// Placed and being made, not yet shipped (Slant's statuses between payment and SHIPPED).
let orderAttentionProductionStatuses: Set<String> = [
    "PAID", "SUBMITTED", "QUEUED", "PROCESSING", "PRINTING", "ITEMS_ON_SHELF", "POST_PROCESSING", "COMPLETED", "IN_REVIEW",
    "AWAITING_SHIPMENT"
]

/// Why an order needs a look. Worked out locally from the loaded order and the clock; never a request.
enum OrderAttention: Equatable {
    case paymentProblem
    case pastArriveBy(Date)
    /// `sincePlaced` is false when Slant returned no `processedAt` and the age is counted from creation.
    case notShipped(days: Int, sincePlaced: Bool)
    case draftNotPlaced(days: Int)

    /// Short text for the table's marker.
    var title: String {
        switch self {
        case .paymentProblem: return "Payment problem"
        case .pastArriveBy: return "Late"
        case .notShipped: return "Not shipped"
        case .draftNotPlaced: return "Draft not placed"
        }
    }

    /// One sentence for the marker's tooltip and VoiceOver.
    var detail: String {
        switch self {
        case .paymentProblem:
            return "Slant had a problem charging for this order."
        case .pastArriveBy(let date):
            return "Past its arrive-by date (\(orderArriveByLabel(date))) and not shipped yet."
        case .notShipped(let days, let sincePlaced):
            return "Not shipped \(orderAttentionDays(days)) after it was \(sincePlaced ? "placed" : "created")."
        case .draftNotPlaced(let days):
            return "A draft for \(orderAttentionDays(days)) and not placed yet."
        }
    }
}

func orderAttentionDays(_ days: Int) -> String { days == 1 ? "1 day" : "\(days) days" }

/// The most pressing reason the order needs a look, or nil. Payment problems first, then a missed arrive-by date,
/// then an order not shipped in time, then a draft left unplaced. Cancelled and delivered orders never need one;
/// unknown statuses aren't guessed at. A shipped order is never late here (it's on its way), and neither is a draft
/// past the `orderAttentionDraftIgnoredAfterDays` window (or with no creation date), which Slant can't remove.
func orderAttention(_ order: [String: Any], now: Date, timeZone: TimeZone = .current) -> OrderAttention? {
    let status = ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !status.isEmpty, !["CANCELED", "CANCELLED", "DELIVERED"].contains(status) else { return nil }
    if status == "PAYMENT_ERROR" { return .paymentProblem }
    let draftInWindow = orderCreatedDate(order).map {
        now.timeIntervalSince($0) <= Double(orderAttentionDraftIgnoredAfterDays) * 86_400
    } ?? false
    let canBeLate = status != "SHIPPED" && (status != "DRAFT" || draftInWindow)
    if canBeLate, let arriveBy = orderArriveByDate(order), now > orderArriveByDeadline(arriveBy, timeZone: timeZone) {
        return .pastArriveBy(arriveBy)
    }
    func age(from start: Date?) -> TimeInterval? {
        guard let start else { return nil }
        let interval = now.timeIntervalSince(start)
        return interval > 0 ? interval : nil
    }
    let day: TimeInterval = 86_400
    if orderAttentionProductionStatuses.contains(status) {
        let placed = (order["processedAt"] as? String).flatMap(orderTimestamp)
        if let interval = age(from: placed ?? orderCreatedDate(order)), interval > Double(orderAttentionProductionDays) * day {
            return .notShipped(days: Int(interval / day), sincePlaced: placed != nil)
        }
    }
    if status == "DRAFT", let interval = age(from: orderCreatedDate(order)),
       interval > Double(orderAttentionDraftDays) * day, interval <= Double(orderAttentionDraftIgnoredAfterDays) * day {
        return .draftNotPlaced(days: Int(interval / day))
    }
    return nil
}

/// The Needs Attention filter over loaded orders. Off returns the list unchanged.
func orderAttentionFiltered(_ records: [Record], enabled: Bool, now: Date) -> [Record] {
    guard enabled else { return records }
    return records.filter { orderAttention(orderObject($0.values), now: now) != nil }
}

/// Under the list while Needs Attention is on: what it checks, and that only loaded orders are checked.
func orderAttentionFilterHint(moreOnServer: Bool) -> String {
    let base = "Showing loaded orders that need attention: payment problems, past their arrive-by date, not shipped "
        + "\(orderAttentionProductionDays) days after being placed, or drafts not placed after \(orderAttentionDraftDays) days."
    return moreOnServer ? base + " Load more to check older orders." : base
}

/// The empty list's text while Needs Attention is on.
func orderAttentionEmptyDetail(filterActive: Bool, search: String = "") -> String {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    var orders = "loaded orders"
    if filterActive { orders += " with the chosen status or dates" }
    if !query.isEmpty { orders += " matching “\(query)”" }
    return "None of the \(orders) need attention."
}

/// The orders table's Status cell, with an orange marker when the order needs attention. Its tooltip and VoiceOver
/// label say why.
struct OrderStatusCell: View {
    let status: String
    let attention: OrderAttention?

    var body: some View {
        if let attention {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).imageScale(.small)
                Text(status).lineLimit(1)
            }
            // The tooltip goes on the combined element: on the HStack before `.combine` it reached VoiceOver twice.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(status), needs attention: \(attention.detail)")
            .help("\(status). \(attention.detail)")
        } else {
            Text(status).lineLimit(1).help(status)
        }
    }
}

// MARK: - Tracking for your shop

/// One loaded order with tracking, as listed in Tracking for Your Shop….
struct ShopFollowUpEntry: Identifiable, Equatable {
    let id: String
    let slantOrderNumber: String
    /// `metadata.sourceOrderId` and `metadata.source`, as Import Orders writes them; nil when not imported.
    let marketplaceID: String?
    let source: String?
    /// Display only (session data, never saved or exported).
    let recipientFirstName: String?
    /// `fulfillment.provider` (or `carrier`) as Slant sent it. May be the label service rather than the carrier.
    let provider: String?
    let trackingNumbers: [String]
    let status: String
    let created: Date?
    /// Shopify drafts (ShopifyOrderMatching.swift): `metadata.sourceShop` and `metadata.sourceItems`, when recorded.
    var sourceShop: String? = nil
    var sourceItems: [ShopifySourceItem]? = nil
    /// The recipient's full name and postcode, for Send Tracking's same-order check on orders imported without their
    /// store. Memory only: never saved, exported or logged.
    var recipientName = ""
    var postcode = ""

    var isImported: Bool { marketplaceID != nil }
    var isShopify: Bool { (source ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "shopify" }
}

/// The order's tracking numbers in Slant's order, without blanks or repeats.
func orderTrackingNumbers(_ order: [String: Any]) -> [String] {
    var seen = Set<String>()
    return trackingFacts(order["fulfillment"]).filter { $0.0 == "Tracking number" }
        .map { $0.1.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && seen.insert($0).inserted }
}

/// The first word of the recipient's name, or nil.
func orderRecipientFirstName(_ order: [String: Any]) -> String? {
    orderRecipientName(order).split(whereSeparator: \.isWhitespace).first.map(String.init)
}

/// Nil when the order has no tracking: there's nothing to send to the shop yet.
func shopFollowUpEntry(_ record: Record) -> ShopFollowUpEntry? {
    let order = orderObject(record.values)
    let numbers = orderTrackingNumbers(order)
    guard !numbers.isEmpty else { return nil }
    let reference = orderMarketplaceReference(order)
    let provider = trackingFacts(order["fulfillment"]).first { $0.0 == "Carrier" }?.1.trimmingCharacters(in: .whitespacesAndNewlines)
    return ShopFollowUpEntry(
        id: record.id, slantOrderNumber: orderNumber(order), marketplaceID: reference?.id, source: reference?.source,
        recipientFirstName: orderRecipientFirstName(order), provider: (provider?.isEmpty ?? true) ? nil : provider,
        trackingNumbers: numbers, status: (order["status"] as? String) ?? "", created: orderCreatedDate(order),
        sourceShop: orderShopifySourceShop(order), sourceItems: orderShopifySourceItems(order),
        recipientName: orderRecipientName(order), postcode: orderShippingPostcode(order))
}

struct ShopFollowUpGroups: Equatable {
    /// Orders with a marketplace reference, newest first.
    var imported: [ShopFollowUpEntry] = []
    /// Orders with tracking but no marketplace reference, newest first.
    var notImported: [ShopFollowUpEntry] = []
    /// Orders with tracking that were marked done in the shop this session (and so are left out above).
    var doneCount = 0
}

/// Loaded orders with tracking, split by whether they carry a marketplace reference. Newest first (orders without a
/// creation date last; ties keep Slant's order). Orders in `done` are counted, and listed only when `showDone`.
func shopFollowUpGroups(_ records: [Record], done: Set<String>, showDone: Bool = false) -> ShopFollowUpGroups {
    let entries = records.enumerated().compactMap { offset, record in shopFollowUpEntry(record).map { (offset, $0) } }
        .sorted { lhs, rhs in
            let left = lhs.1.created ?? orderMissingDateSortKey, right = rhs.1.created ?? orderMissingDateSortKey
            return left != right ? left > right : lhs.0 < rhs.0
        }
        .map(\.1)
    var groups = ShopFollowUpGroups()
    var listed = Set<String>()
    for entry in entries where listed.insert(entry.id).inserted {
        let isDone = done.contains(entry.id)
        if isDone { groups.doneCount += 1 }
        guard !isDone || showDone else { continue }
        if entry.isImported { groups.imported.append(entry) } else { groups.notImported.append(entry) }
    }
    return groups
}

/// The order's label in the sheet: "Etsy order 3141592653", or "Slant order SLANT_…" when not imported.
func shopFollowUpOrderTitle(_ entry: ShopFollowUpEntry) -> String {
    guard let id = entry.marketplaceID else { return "Slant order \(entry.slantOrderNumber)" }
    return "\(orderMarketplaceReferenceLabel(source: entry.source)) \(id)"
}

/// What Copy Tracking puts on the clipboard: the tracking numbers, comma-separated when there are several.
func shopFollowUpTrackingText(_ entry: ShopFollowUpEntry) -> String {
    entry.trackingNumbers.joined(separator: ", ")
}

/// What Copy Order & Tracking puts on the clipboard: "3141592653 — 1Z999AA10123456784". The marketplace order
/// number when imported, otherwise Slant's. Never the recipient's name.
func shopFollowUpOrderAndTrackingText(_ entry: ShopFollowUpEntry) -> String {
    "\(entry.marketplaceID ?? entry.slantOrderNumber) — \(shopFollowUpTrackingText(entry))"
}

// MARK: - Shopify tracking CSV

let shopifyTrackingCSVColumns = ["Order name", "Tracking number", "Tracking company"]

/// Label services Slant may report as the fulfilment provider. They aren't carriers, so they're not sent to Shopify
/// as the tracking company (Shopify works the carrier out from the number when the company is blank).
let shopFollowUpLabelServices: Set<String> = ["SHIPPO", "SHIPSTATION"]

/// The tracking company for Shopify: the provider unless it's a label service, else blank.
func shopifyTrackingCompany(_ entry: ShopFollowUpEntry) -> String {
    guard let provider = entry.provider?.trimmingCharacters(in: .whitespacesAndNewlines), !provider.isEmpty else { return "" }
    let key = provider.uppercased().filter { $0.isLetter || $0.isNumber }
    return shopFollowUpLabelServices.contains(key) ? "" : provider
}

/// The Shopify order name. Import Orders stores the export's Name column ("#1001", or whatever prefix the shop uses)
/// as `sourceOrderId`, so it's used as stored, trimmed. A "#" is never added: a shop can set its own prefix.
func shopifyOrderName(_ sourceOrderID: String) -> String {
    sourceOrderID.trimmingCharacters(in: .whitespacesAndNewlines)
}

/// One row per Shopify order with tracking; several tracking numbers share the row, comma-separated. Other
/// marketplaces' orders and orders that weren't imported are left out: their numbers mean nothing to Shopify.
func shopifyTrackingCSVRows(_ entries: [ShopFollowUpEntry]) -> [[String]] {
    entries.compactMap { entry in
        guard entry.isShopify, let id = entry.marketplaceID, !shopifyOrderName(id).isEmpty, !entry.trackingNumbers.isEmpty else { return nil }
        return [shopifyOrderName(id), entry.trackingNumbers.joined(separator: ","), shopifyTrackingCompany(entry)]
    }
}

/// The CSV (header first, CRLF line endings), through the orders export's `csvField` formula guard. No names or
/// addresses.
func shopifyTrackingCSV(_ entries: [ShopFollowUpEntry]) -> String {
    ([shopifyTrackingCSVColumns] + shopifyTrackingCSVRows(entries))
        .map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
}

func shopifyTrackingCSVDefaultFileName(date: Date = Date()) -> String {
    ordersCSVDefaultFileName(date: date).replacingOccurrences(of: "Slant orders", with: "Shopify tracking")
}

// MARK: - Store hooks

extension StudioStore {
    /// File › Tracking for Your Shop…: opens the sheet only (no request), and only when nothing modal is shown.
    func openShopFollowUpFromMenu() {
        guard !menuCommandsBlockedByModalUI, !orders.isEmpty else { return }
        destination = .orders
        showShopFollowUp = true
    }

    /// Writes the Shopify tracking CSV to a file the user picks. Activity records the count only. Returns the
    /// message for a failed write, which the sheet shows itself: a window alert behind the sheet would wait until
    /// it closes.
    func exportShopifyTrackingCSV(_ entries: [ShopFollowUpEntry]) -> String? {
        let count = shopifyTrackingCSVRows(entries).count
        guard count > 0 else { return nil }
        let panel = NSSavePanel()
        panel.title = "Export Shopify Tracking"
        panel.message = count == 1
            ? "Saves the order name and tracking for 1 Shopify order, for a bulk-fulfilment app. No names or addresses."
            : "Saves the order names and tracking for \(count) Shopify orders, for a bulk-fulfilment app. No names or addresses."
        panel.nameFieldStringValue = shopifyTrackingCSVDefaultFileName()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return nil }
        let data = Data([0xEF, 0xBB, 0xBF]) + Data(shopifyTrackingCSV(entries).utf8)
        do {
            try data.write(to: destination, options: .atomic)
            activities.insert(Activity(title: "Export Shopify tracking", detail: count == 1 ? "1 order" : "\(count) orders", success: true), at: 0)
            return nil
        } catch {
            return "Not exported: \(error.localizedDescription)"
        }
    }
}

// MARK: - Sheet

struct ShopFollowUpSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var showDone = false
    @State private var exportError: String?
    /// Send Tracking to Shopify… (ShopifyTracking.swift), with the store and orders fixed when it opens.
    @State private var shopifySend: ShopifyTrackingSession?
    @ObservedObject private var shopify = ShopifyConnection.shared

    var body: some View {
        let groups = shopFollowUpGroups(store.orders, done: store.shopFollowUpDoneIDs, showDone: showDone)
        let listed = groups.imported + groups.notImported
        let shopifyCount = shopifyTrackingCSVRows(listed.filter { !store.shopFollowUpDoneIDs.contains($0.id) }).count
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tracking for your shop").font(.title2.bold())
                Text("Orders Slant has shipped, with their tracking, to copy into Etsy or Shopify. Mark an order as done once you’ve added its tracking in your shop; marks last until you quit Studio. Only loaded orders are listed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if listed.isEmpty {
                ContentUnavailableView {
                    Label(groups.doneCount > 0 ? "All orders marked as done" : "No tracking yet", systemImage: "shippingbox")
                } description: {
                    Text(groups.doneCount > 0
                         ? "Every loaded order with tracking is marked as done in your shop. Show marked orders lists them again."
                         : "None of the loaded orders has tracking from Slant yet. Refresh Orders later to check again.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    if !groups.imported.isEmpty {
                        Section("Marketplace orders") { ForEach(groups.imported) { row($0) } }
                    }
                    if !groups.notImported.isEmpty {
                        Section("Other orders") { ForEach(groups.notImported) { row($0) } }
                    }
                }
                .frame(minHeight: 240)
            }
            HStack {
                Button("Export Shopify Tracking CSV…") {
                    exportError = store.exportShopifyTrackingCSV(listed.filter { !store.shopFollowUpDoneIDs.contains($0.id) })
                }
                .disabled(shopifyCount == 0)
                .help(shopifyCount == 0
                      ? "No imported Shopify orders with tracking are listed"
                      : "Order name, tracking number and company for a Shopify bulk-fulfilment app")
                if shopify.isConfigured {
                    let candidates = shopifyTrackingCandidates(listed, done: store.shopFollowUpDoneIDs)
                    Button("Send Tracking to Shopify…") {
                        guard let shop = shopify.shop, !candidates.isEmpty else { return }
                        shopifySend = ShopifyTrackingSession(shop: shop, candidates: candidates)
                    }
                        .disabled(candidates.isEmpty || shopify.busy)
                        .help(candidates.isEmpty
                              ? "No imported Shopify orders with tracking are waiting"
                              : "Review, then add this tracking to the orders in \(shopify.shop ?? "your store")")
                }
                if groups.doneCount > 0 {
                    Toggle("Show marked orders (\(groups.doneCount))", isOn: $showDone)
                        .toggleStyle(.checkbox)
                }
                Spacer()
                // Shown here, as in the spending report: a window alert would wait behind the sheet.
                if let exportError {
                    Label(exportError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange).lineLimit(2)
                }
                // Marks apply as they're made, so Done; Escape closes the sheet as everywhere else.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            if store.ordersHasMore {
                Text("Older orders aren’t loaded. Load more in Orders to include them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 440, idealHeight: 560)
        .sheet(item: $shopifySend) { session in
            ShopifyTrackingSheet(shop: session.shop, candidates: session.candidates).environmentObject(store)
        }
    }

    private func row(_ entry: ShopFollowUpEntry) -> some View {
        let done = Binding(
            get: { store.shopFollowUpDoneIDs.contains(entry.id) },
            set: { ticked in
                if ticked { store.shopFollowUpDoneIDs.insert(entry.id) } else { store.shopFollowUpDoneIDs.remove(entry.id) }
            })
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Toggle("Done in your shop", isOn: done)
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel("Marked as done in your shop, \(shopFollowUpOrderTitle(entry))")
                .help("Mark as done once you’ve added this order’s tracking in your shop (this session only)")
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(shopFollowUpOrderTitle(entry)).font(.body.weight(.medium)).textSelection(.enabled)
                    if let name = entry.recipientFirstName {
                        Text("· \(name)").foregroundStyle(.secondary)
                    }
                    Text("· \(orderStatusTitle(entry.status))").foregroundStyle(.secondary)
                }
                .lineLimit(1)
                Text(shopFollowUpTrackingText(entry))
                    .font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                if let provider = entry.provider {
                    Text("Provider: \(orderAPIValueTitle(provider))").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            Button("Copy Tracking") { copyToPasteboard(shopFollowUpTrackingText(entry)) }
                .help("Copy the tracking number")
            Button("Copy Order & Tracking") { copyToPasteboard(shopFollowUpOrderAndTrackingText(entry)) }
                .help("Copy “\(shopFollowUpOrderAndTrackingText(entry))”")
        }
        .padding(.vertical, 2)
    }
}
