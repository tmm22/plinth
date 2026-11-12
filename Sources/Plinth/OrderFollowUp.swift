import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Order follow-up: getting Slant's tracking back to the marketplace (Tracking for Your Shop…), a Shopify tracking
// CSV, the arrive-by date and the Needs Attention check. Everything here reads orders already loaded, except Tracking
// for Your Shop's read of recent orders (RecentOrders.swift: read-only, in the sheet's memory only, never into
// `store.orders`); nothing is written to disk except a CSV the user saves and the done ticks.

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
/// A placed order not shipped after this many business days (weekdays in the Mac's time zone; `orderBusinessDays`)
/// looks stuck. Slant says parts ship in under 5 days, and the seller's shipped orders read on 1 Nov 2026 got their
/// shipping record 2.8–3.8 days after payment, so 5 business days is past both without flagging over a weekend.
let orderAttentionNotShippedBusinessDays = 5
/// A placed order Slant still lists as SUBMITTED (paid, waiting to print) after this many business days hasn't been
/// moved to PRINTING in time to ship within 5 days, so it gets an earlier look than Not shipped. Only Slant's raw
/// SUBMITTED counts: older waiting words aren't sent any more.
let orderAttentionNotStartedBusinessDays = 3

/// Placed and being made, not yet shipped: Slant's live SUBMITTED (paid, waiting to print) and PRINTING, and the
/// earlier statuses between payment and SHIPPED (still read from old replies).
let orderAttentionProductionStatuses: Set<String> = [
    "PAID", "SUBMITTED", "QUEUED", "PROCESSING", "PRINTING", "ITEMS_ON_SHELF", "POST_PROCESSING", "COMPLETED", "IN_REVIEW",
    "AWAITING_SHIPMENT"
]

/// `fulfillment.status`, trimmed and upper-cased, or nil when there's no fulfilment or no status. Slant documents no
/// values for it; live and doc examples use the earlier vocabulary (SHIPPED, AWAITING_SHIPMENT; read 29 Oct 2026).
func orderFulfillmentStatus(_ order: [String: Any]) -> String? {
    guard let fulfillment = order["fulfillment"] as? [String: Any], let raw = fulfillment["status"] as? String else { return nil }
    let word = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return word.isEmpty ? nil : word
}

/// Shipping-record words that mean the parcel has left Slant.
let orderFulfillmentShippedStatuses: Set<String> = ["SHIPPED", "DELIVERED"]

/// The status Studio shows for an order. Slant's order status can lag its own shipping record: on 29 Oct 2026 two
/// orders read PRINTING while `fulfillment.status` was SHIPPED with tracking and a printed label. So while the order
/// status is a production status (`orderAttentionProductionStatuses`) and the shipping record says SHIPPED or
/// DELIVERED (`orderFulfillmentShippedStatuses`), Studio shows SHIPPED; otherwise Slant's order status, unchanged.
/// A DELIVERED record shows as SHIPPED too: it has never been seen live and Slant's live statuses have no Delivered,
/// so showing it would make the word go backwards once the order status catches up to SHIPPED.
///
/// Display and read-only advice only. Cancel gating, the pay/cancel re-checks, the unknown-outcome lock, pay outcomes,
/// Pay Several Drafts and the Spending Report use Slant's raw `status`, never this.
func orderDisplayStatus(_ order: [String: Any]) -> String {
    let raw = (order["status"] as? String) ?? ""
    let status = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard orderAttentionProductionStatuses.contains(status), let shipping = orderFulfillmentStatus(order),
          orderFulfillmentShippedStatuses.contains(shipping) else { return raw }
    return "SHIPPED"
}

/// Whether Studio shows the shipping record's word instead of Slant's order status (`orderDisplayStatus`).
func orderStatusLagsShippingRecord(_ order: [String: Any]) -> Bool {
    let raw = ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    // Both sides trimmed: a padded status (" printing ") without a shipping record doesn't lag.
    return orderDisplayStatus(order).trimmingCharacters(in: .whitespacesAndNewlines).uppercased() != raw
}

/// The title Studio shows for an order's status: `orderStatusTitle` of `orderDisplayStatus`. Display only.
func orderDisplayStatusTitle(_ order: [String: Any]) -> String {
    orderStatusTitle(orderDisplayStatus(order))
}

/// Why Studio shows Shipped, for the status cell's hover hint and a caption in the detail: "Slant’s shipping record
/// says Shipped, but Slant hasn’t yet updated this order’s status from Printing." Nil unless the status lags. A
/// shipping record of SHIPPED may mean only that a label was made, so this never says the parcel was handed over.
func orderStatusLagNote(_ order: [String: Any]) -> String? {
    guard orderStatusLagsShippingRecord(order) else { return nil }
    let raw = (order["status"] as? String) ?? ""
    return "Slant’s shipping record says \(orderDisplayStatusTitle(order)), but Slant hasn’t yet updated this order’s status from \(orderStatusTitle(raw.trimmingCharacters(in: .whitespacesAndNewlines)))."
}

/// What the cancel re-check compares between the order shown in the review and the order re-fetched just before
/// sending: the shipping record's status and the tracking numbers (as a sorted list, so a reordering isn't a change).
struct OrderShippingDetails: Equatable {
    var status: String?
    var trackingNumbers: [String]
}

func orderShippingDetails(_ order: [String: Any]) -> OrderShippingDetails {
    OrderShippingDetails(status: orderFulfillmentStatus(order), trackingNumbers: orderTrackingNumbers(order).sorted())
}

/// The cancel review's stop when the shipping record or tracking changed between the review and the send.
let orderShippingDetailsChangedMessage = "This order’s shipping record or tracking changed. Review it again."

/// Status-filter hint (the Orders list and its filtered-empty text): Slant filters by its order status, which can lag
/// its shipping record, so such orders are listed under Printing or Submitted, not Shipped.
let orderStatusFilterLagHint = "Slant’s filter uses its own order status, so orders Plinth shows as Shipped while Slant still says Printing or Submitted are listed under that status."

/// The hint under the Orders list for the chosen status filter, or nil. Always under Shipped (orders not loaded may
/// be listed under Printing or Submitted instead); under another status only while a loaded order with that raw
/// status lags its shipping record (in practice Printing or Submitted).
func orderStatusFilterLagHintText(status: String?, loaded: [Record]) -> String? {
    let filter = (status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if filter.isEmpty { return nil }
    if filter == "SHIPPED" { return orderStatusFilterLagHint }
    let lagging = loaded.contains { record in
        let order = orderObject(record.values)
        let raw = ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return raw == filter && orderStatusLagsShippingRecord(order)
    }
    return lagging ? orderStatusFilterLagHint : nil
}

/// Why an order needs a look. Worked out locally from the loaded order and the clock; never a request.
enum OrderAttention: Equatable {
    case paymentProblem
    case pastArriveBy(Date)
    /// `days` are business days (`orderBusinessDays`). `sincePlaced` is false when Slant returned no `processedAt` and
    /// the age is counted from creation.
    case notShipped(days: Int, sincePlaced: Bool)
    /// Still SUBMITTED (Slant's paid, waiting to print) `days` business days after it was placed (or created).
    case notStarted(days: Int, sincePlaced: Bool)
    case draftNotPlaced(days: Int)

    /// Short text for the table's marker.
    var title: String {
        switch self {
        case .paymentProblem: return "Payment problem"
        case .pastArriveBy: return "Late"
        case .notShipped: return "Not shipped"
        case .notStarted: return "Waiting to print"
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
            return "Not shipped \(orderBusinessDaysText(days)) after it was \(sincePlaced ? "paid" : "created")."
        case .notStarted(let days, let sincePlaced):
            return "\(sincePlaced ? "Paid" : "Created") \(orderBusinessDaysText(days)) ago and Slant still lists it as Submitted, waiting to print."
        case .draftNotPlaced(let days):
            return "A draft for \(orderAttentionDays(days)) and not placed yet."
        }
    }
}

func orderAttentionDays(_ days: Int) -> String { days == 1 ? "1 day" : "\(days) days" }

/// The most pressing reason the order needs a look, or nil. Payment problems first, then a missed arrive-by date,
/// then an order not shipped in time, then one still waiting to print, then a draft left unplaced. Business days are
/// weekdays in `timeZone` (the Mac's). Cancelled and delivered orders never need one;
/// unknown statuses aren't guessed at. A shipped order is never late here (it's on its way, also when only Slant's
/// shipping record says so: `orderStatusLagsShippingRecord`), and neither is a draft
/// past the `orderAttentionDraftIgnoredAfterDays` window (or with no creation date), which Slant can't remove.
func orderAttention(_ order: [String: Any], now: Date, timeZone: TimeZone = .current) -> OrderAttention? {
    let status = ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !status.isEmpty, !orderStatusIsCancelled(status), status != "DELIVERED" else { return nil }
    if status == "PAYMENT_ERROR" { return .paymentProblem }
    // Slant's shipping record says the order shipped though its status still says it's being made
    // (`orderDisplayStatus`): it's on its way, so neither late nor stuck. Removes an alarm only; nothing is enabled.
    if orderStatusLagsShippingRecord(order) { return nil }
    let draftInWindow = orderCreatedDate(order).map {
        now.timeIntervalSince($0) <= Double(orderAttentionDraftIgnoredAfterDays) * 86_400
    } ?? false
    // Late only while Studio knows the order is still being made (or is a recent draft): never once shipped, and never
    // for a status Studio doesn't know, which might mean the parcel is already on its way.
    let canBeLate = orderAttentionProductionStatuses.contains(status) || (status == "DRAFT" && draftInWindow)
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
        if let start = placed ?? orderCreatedDate(order), age(from: start) != nil {
            let days = orderBusinessDays(from: start, to: now, calendar: orderBusinessDayCalendar(timeZone: timeZone))
            if days >= orderAttentionNotShippedBusinessDays { return .notShipped(days: days, sincePlaced: placed != nil) }
            if status == "SUBMITTED", days >= orderAttentionNotStartedBusinessDays {
                return .notStarted(days: days, sincePlaced: placed != nil)
            }
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
func orderAttentionFilterHint(moreOnServer: Bool, statusFilter: String? = nil, datesFiltered: Bool = false,
                              searchActive: Bool = false) -> String {
    var text = "Showing loaded orders that need attention: payment problems, past their arrive-by date, not shipped "
        + "\(orderAttentionNotShippedBusinessDays) business days after being paid, still waiting to print after "
        + "\(orderAttentionNotStartedBusinessDays) business days, or drafts not placed after \(orderAttentionDraftDays) days."
    // Say what the loaded list leaves out, so "nothing needs attention" is never read as covering every order.
    if searchActive {
        text += " Only the order found by your search is checked; clear the search to check the list."
    } else {
        let status = statusFilter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let kind = status.isEmpty ? "orders" : "\(orderStatusTitle(status)) orders"
        if datesFiltered {
            text += " Only \(kind) from the chosen dates are loaded."
        } else if !status.isEmpty {
            text += " Only \(kind) are loaded."
        }
        if moreOnServer { text += " Load more to check older orders." }
    }
    return text
}

/// The empty list's text while Needs Attention is on. Names only the filters in use: the status by name (as
/// `orderAttentionFilterHint` does) and "the chosen dates" only when dates are set.
func orderAttentionEmptyDetail(statusFilter: String? = nil, datesFiltered: Bool = false, search: String = "") -> String {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let status = statusFilter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var orders = status.isEmpty ? "loaded orders" : "loaded \(orderStatusTitle(status)) orders"
    if datesFiltered { orders += " from the chosen dates" }
    if !query.isEmpty { orders += " matching “\(query)”" }
    return "None of the \(orders) need attention."
}

/// The orders table's Status cell, with an orange marker when the order needs attention. Its tooltip and VoiceOver
/// label say why. `note` (`orderStatusLagNote`) explains a status taken from Slant's shipping record.
struct OrderStatusCell: View {
    let status: String
    let attention: OrderAttention?
    var note: String? = nil

    var body: some View {
        if let attention {
            HStack(spacing: 3) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.studioWarning).imageScale(.small)
                Text(status).lineLimit(1)
            }
            // The tooltip goes on the combined element: on the HStack before `.combine` it reached VoiceOver twice.
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(status), needs attention: \(attention.detail)")
            .help("\(status). \(attention.detail)")
        } else if let note {
            Text(status).lineLimit(1)
                .accessibilityLabel("\(status). \(note)")
                .help(note)
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
    /// The status shown in the list (`orderDisplayStatus`); `status` stays Slant's own. Display only.
    var displayStatus = ""

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
    return ShopFollowUpEntry(
        id: record.id, slantOrderNumber: orderNumber(order), marketplaceID: reference?.id, source: reference?.source,
        recipientFirstName: orderRecipientFirstName(order), provider: fulfillmentProvider(order["fulfillment"]),
        trackingNumbers: numbers, status: (order["status"] as? String) ?? "", created: orderCreatedDate(order),
        sourceShop: orderShopifySourceShop(order), sourceItems: orderShopifySourceItems(order),
        recipientName: orderRecipientName(order), postcode: orderShippingPostcode(order),
        displayStatus: orderDisplayStatus(order))
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

/// The carrier the order's tracking numbers agree on, worked out from them (`carrierDetected`), or nil. Slant's
/// provider counts only when it names a real carrier, which must then agree.
func shopFollowUpDetectedCarrier(_ entry: ShopFollowUpEntry) -> DetectedCarrier? {
    carrierDetected(forNumbers: entry.trackingNumbers, namedCarrier: entry.provider)
}

/// What Copy Order & Tracking puts on the clipboard: "3141592653 — 1Z999AA10123456784", and after each number whose
/// carrier Plinth recognises, that carrier and its tracking page: "(UPS: https://www.ups.com/track?tracknum=…)". The
/// marketplace order number when imported, otherwise Slant's. Never the recipient's name. Copy Tracking stays the
/// bare numbers, for a shop's tracking-number field.
func shopFollowUpOrderAndTrackingText(_ entry: ShopFollowUpEntry) -> String {
    let numbers = entry.trackingNumbers.map { number -> String in
        guard let carrier = carrierDetected(forNumber: number, namedCarrier: entry.provider) else { return number }
        if let url = carrier.trackingURL { return "\(number) (\(carrier.name): \(url.absoluteString))" }
        return "\(number) (\(carrier.name))"
    }
    return "\(entry.marketplaceID ?? entry.slantOrderNumber) — \(numbers.joined(separator: ", "))"
}

/// The row's carrier caption, just the carrier's name ("USPS", "UPS"), with how Plinth knows in its help: Slant's
/// carrier when it names a real one, else the carrier the tracking numbers agree on (`carrierDetectedHelp`, naming
/// any label service). With neither, "Label service: Shippo" when Slant named one; nil when Slant names nothing and
/// no carrier is recognised.
func shopFollowUpCarrierCaption(_ entry: ShopFollowUpEntry) -> (text: String, help: String)? {
    let service = entry.provider.flatMap(carrierLabelServiceName)
    if let provider = entry.provider, service == nil {
        return (orderAPIValueTitle(provider), "The carrier Slant named.")
    }
    if let carrier = shopFollowUpDetectedCarrier(entry) {
        return (carrier.name, carrierDetectedHelp(labelService: service))
    }
    if let service { return ("Label service: \(service)", "The service that made the shipping label; it isn’t the carrier.") }
    return nil
}

/// Each row's checkbox. Not "Done", the sheet's dismiss button: Voice Control's "Click Done" would match every row.
let shopFollowUpAddedTitle = "Added to Shop"
/// Its spoken name starts with the visible title and names the row.
func shopFollowUpAddedAccessibilityLabel(_ rowDescription: String) -> String { "\(shopFollowUpAddedTitle), \(rowDescription)" }
/// Help for the done tick: what is remembered, where, and until when.
let shopFollowUpDoneHelp = "Tick once you’ve added this order’s tracking in your shop. Plinth remembers your marks on this Mac (order IDs only) until you disconnect or change the API key."


// MARK: - Shopify tracking CSV

let shopifyTrackingCSVColumns = ["Order name", "Tracking number", "Tracking company"]

/// The tracking company for Shopify: Slant's provider when it names a real carrier (as before); when it is a label
/// service (`carrierLabelServiceName`: never sent as the company) or blank, the carrier every tracking number agrees
/// on, worked out from the numbers, but only under the exact name Shopify lists (`DetectedCarrier.shopifyCompany`);
/// otherwise blank, and Shopify works the carrier out itself.
func shopifyTrackingCompany(_ entry: ShopFollowUpEntry) -> String {
    shopifyTrackingCompanyChoice(entry).company
}

/// `shopifyTrackingCompany` and whether it was worked out from the tracking numbers (shown as such in the review).
func shopifyTrackingCompanyChoice(_ entry: ShopFollowUpEntry) -> (company: String, fromNumber: Bool) {
    let provider = entry.provider?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !provider.isEmpty, carrierLabelServiceName(provider) == nil { return (provider, false) }
    guard let company = detectCarrier(forNumbers: entry.trackingNumbers)?.shopifyCompany else { return ("", false) }
    return (company, true)
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

// MARK: - Recent orders for the sheet

/// Whether the sheet reads recent orders as it opens: when the Orders list is filtered (status or dates) or shows a
/// search, so it may hold no shipped orders at all (straight after an import it shows drafts only). Otherwise the
/// seller can press Load Recent Orders.
func shopFollowUpShouldReadOnOpen(filterActive: Bool, searchActive: Bool, hasKey: Bool) -> Bool {
    hasKey && (filterActive || searchActive)
}

/// What the Orders list leaves out, for the sheet's empty state: "The Orders list shows only Draft orders, so shipped
/// orders may not be loaded." Nil when it isn't filtered or searched.
func shopFollowUpListLimitText(statusFilter: String?, datesFiltered: Bool, searchActive: Bool) -> String? {
    if searchActive { return "The Orders list shows a search result, so shipped orders may not be loaded." }
    let status = statusFilter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !status.isEmpty, datesFiltered {
        return "The Orders list shows only \(orderStatusTitle(status)) orders from the chosen dates, so shipped orders may not be loaded."
    }
    if !status.isEmpty { return "The Orders list shows only \(orderStatusTitle(status)) orders, so shipped orders may not be loaded." }
    if datesFiltered { return "The Orders list shows only orders from the chosen dates, so shipped orders may not be loaded." }
    return nil
}

/// The empty sheet's description: never blames Slant for orders the list's filter or search left out.
func shopFollowUpEmptyText(doneCount: Int, listLimit: String?, reading: Bool, recent: RecentOrdersRead?,
                           dateText: (Date) -> String = recentOrdersDateText) -> String {
    if doneCount > 0 {
        return "Every listed order with tracking is marked Added to Shop. Show marked orders lists them again."
    }
    if reading { return "Loading your recent orders from Slant…" }
    if let recent, recent.finished {
        return "No order in your Orders list, or in \(recentOrdersReachText(recent, dateText: dateText)), has tracking from Slant yet. Check again later."
    }
    var parts: [String] = []
    if let recent {
        let reason = recentOrdersStopReason(recent)
        parts.append(reason.isEmpty ? "Couldn’t load your recent orders from Slant." : "Couldn’t load your recent orders from Slant. \(reason)")
    }
    if let listLimit {
        parts.append(listLimit)
        parts.append("Load Recent Orders adds your newest orders on Slant.")
    } else {
        parts.append(recent == nil
            ? "No order in your Orders list has tracking from Slant yet. Refresh Orders later to check again."
            : "No order in your Orders list has tracking from Slant yet.")
    }
    return parts.joined(separator: " ")
}

/// Under the header: where the listed orders come from.
func shopFollowUpSourceText(reading: Bool, recent: RecentOrdersRead?, ordersHasMore: Bool,
                            dateText: (Date) -> String = recentOrdersDateText) -> String {
    if reading { return "Loading your recent orders from Slant…" }
    if let recent, recent.finished {
        return "Shows your Orders list and \(recentOrdersReachText(recent, dateText: dateText))."
    }
    let more = "Load Recent Orders adds your \(recentOrdersMaxPages * recentOrdersPageSize) newest orders on Slant."
    if let recent {
        let reason = recentOrdersStopReason(recent)
        var text = "Couldn’t load your recent orders from Slant."
        if !reason.isEmpty { text += " " + reason }
        if recent.pagesRead > 0, recent.stop != .accountChanged {
            text += " Shows your Orders list and \(recentOrdersReachText(recent, dateText: dateText)) only."
        } else {
            text += " Shows orders from your Orders list only."
        }
        return text
    }
    return ordersHasMore
        ? "Shows orders from your Orders list, which hasn’t loaded your older orders. \(more)"
        : "Shows orders from your Orders list. \(more)"
}

// MARK: - Sheet

/// After the order title in Tracking for Your Shop: " · Ada · Shipped" (the first name only when known).
func shopFollowUpOrderSuffix(firstName: String?, status: String) -> String {
    let name = firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return (name.isEmpty ? "" : " · \(name)") + " · \(orderStatusTitle(status))"
}

struct ShopFollowUpSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var showDone = false
    @State private var exportError: String?
    /// Send Tracking to Shopify… (ShopifyTracking.swift), with the store and orders fixed when it opens.
    @State private var shopifySend: ShopifyTrackingSession?
    @ObservedObject private var shopify = ShopifyConnection.shared
    /// Recent orders of every status and platform (RecentOrders.swift): this sheet's memory only, never in
    /// `store.orders`. Read as the sheet opens while the Orders list is filtered or searched, or on Load Recent Orders.
    @State private var recentRead: RecentOrdersRead?
    @State private var recentReading = false
    @State private var recentTask: Task<Void, Never>?
    /// Bumped when the sheet closes, so a reply that arrives afterwards is ignored.
    @State private var recentGeneration = 0

    /// The loaded orders, then the read's (each order once: `shopFollowUpGroups` keeps the first entry with
    /// tracking, so a loaded copy without tracking never hides the read's copy with it).
    private var sourceOrders: [Record] { store.orders + (recentRead?.orders(forKey: store.apiKey) ?? []) }

    var body: some View {
        let groups = shopFollowUpGroups(sourceOrders, done: store.shopFollowUpDoneIDs, showDone: showDone)
        let listed = groups.imported + groups.notImported
        let shopifyCount = shopifyTrackingCSVRows(listed.filter { !store.shopFollowUpDoneIDs.contains($0.id) }).count
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Tracking for your shop").font(.title2.weight(.bold))
                Text("Orders Slant has shipped, with their tracking, to copy into Etsy or Shopify. Mark an order as done once you’ve added its tracking in your shop. Plinth remembers your marks on this Mac.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(shopFollowUpSourceText(reading: recentReading, recent: recentRead, ordersHasMore: store.ordersHasMore))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if recentReading { ProgressView().controlSize(.small).accessibilityLabel("Loading recent orders") }
                    Spacer(minLength: 0)
                    if store.hasKey, !recentReading {
                        Button(recentRead == nil ? "Load Recent Orders" : "Load Again") { startRecentRead() }
                            .disabled(store.busy)
                            .help("Read your \(recentOrdersMaxPages * recentOrdersPageSize) newest orders on Slant, every status and platform, for this sheet only. Read-only: the Orders list doesn’t change.")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if listed.isEmpty {
                ContentUnavailableView {
                    Label(groups.doneCount > 0 ? "All orders added to your shop" : "No tracking yet", systemImage: "shippingbox")
                } description: {
                    Text(shopFollowUpEmptyText(
                        doneCount: groups.doneCount,
                        listLimit: shopFollowUpListLimitText(statusFilter: store.orderFilter.status,
                                                             datesFiltered: store.orderFilter.startDate != nil || store.orderFilter.endDate != nil,
                                                             searchActive: store.orderSearchActive),
                        reading: recentReading, recent: recentRead))
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
                    Label(exportError, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.studioWarning).lineLimit(2)
                }
                // Marks apply as they're made, so Done; Escape closes the sheet as everywhere else.
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 620, idealWidth: 700, minHeight: 440, idealHeight: 560)
        .onAppear {
            if shopFollowUpShouldReadOnOpen(filterActive: store.orderFilter.isActive, searchActive: store.orderSearchActive,
                                            hasKey: store.hasKey) {
                startRecentRead()
            }
        }
        .onDisappear {
            // Stops the read before its next page; anything it returns later is ignored, and its orders are dropped.
            recentGeneration += 1
            recentTask?.cancel()
            recentTask = nil
            recentRead = nil
            recentReading = false
        }
        .sheet(item: $shopifySend) { session in
            ShopifyTrackingSheet(shop: session.shop, candidates: session.candidates).environmentObject(store)
        }
    }

    /// Read-only, inside `store.run` (so never while another request runs). Nothing changes in the Orders list.
    private func startRecentRead() {
        guard store.hasKey, !store.busy, !recentReading else { return }
        recentReading = true
        recentGeneration += 1
        let generation = recentGeneration
        recentTask = Task {
            let read = await store.readRecentOrders(title: "Read recent orders for tracking")
            guard generation == recentGeneration else { return }
            recentReading = false
            recentTask = nil
            if let read { recentRead = read }
        }
    }

    private func row(_ entry: ShopFollowUpEntry) -> some View {
        let done = Binding(
            get: { store.shopFollowUpDoneIDs.contains(entry.id) },
            set: { ticked in
                if ticked { store.shopFollowUpDoneIDs.insert(entry.id) } else { store.shopFollowUpDoneIDs.remove(entry.id) }
            })
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            // A visible label, so the box can be clicked on its word and spoken (Voice Control: "Added to Shop").
            Toggle(shopFollowUpAddedTitle, isOn: done)
                .toggleStyle(.checkbox)
                .accessibilityLabel(shopFollowUpAddedAccessibilityLabel(shopFollowUpOrderTitle(entry)))
                .help(shopFollowUpDoneHelp)
            VStack(alignment: .leading, spacing: 3) {
                // One paragraph that wraps, so a long order number is shown in full rather than cut off.
                (Text(shopFollowUpOrderTitle(entry)).fontWeight(.medium)
                    + Text(shopFollowUpOrderSuffix(firstName: entry.recipientFirstName,
                                                   status: entry.displayStatus.isEmpty ? entry.status : entry.displayStatus))
                        .foregroundStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(shopFollowUpTrackingText(entry))
                    .font(.callout.monospaced()).textSelection(.enabled).lineLimit(2)
                if let carrier = shopFollowUpCarrierCaption(entry) {
                    Text(carrier.text).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(carrier.help)
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
