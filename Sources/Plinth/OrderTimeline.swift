import Foundation
import SwiftUI

// MARK: - Order timeline and time to ship
//
// Display only, worked out from orders already loaded: the order detail's dated events (Created, Paid, Shipping
// label created, Arrive by), the caption for a paid order that hasn't shipped, and the seller's own typical time from
// payment to a shipping label (the order detail and the Spending Report). Nothing here sends a request, saves order
// data, or feeds any pay, cancel or lock check, and nothing is presented as Slant's status or a promise from Slant.
//
// Slant removed its print stages on 26 Oct 2026: live orders read on 1 Nov 2026 had no `printItem.assignments` and a
// null `estimatedPrintCompletion` on every item. The shipping record (`fulfillment`) is null until the order ships,
// and its `createdAt` came 2.8–3.8 days after `processedAt` on the shipped orders read, so it marks when the label
// was made (docs/API_REFERENCE.md).

/// The shipping record, when Slant sent one as an object.
private func orderFulfillmentObject(_ order: [String: Any]) -> [String: Any]? {
    order["fulfillment"] as? [String: Any]
}

/// A timestamp field read through `orderTimestamp`; nil when absent, not a string, empty or unreadable.
func orderTimelineDate(_ value: Any?) -> Date? {
    (value as? String).flatMap(orderTimestamp)
}

/// When the order was paid: `processedAt` (absent on drafts).
func orderPaidDate(_ order: [String: Any]) -> Date? {
    orderTimelineDate(order["processedAt"])
}

/// When Slant's shipping record was created (`fulfillment.createdAt`), or nil without one.
func orderShippingRecordCreatedDate(_ order: [String: Any]) -> Date? {
    orderFulfillmentObject(order).flatMap { orderTimelineDate($0["createdAt"]) }
}

/// Whether the shipping record says a label was printed (`fulfillment.labelPrinted`, a real boolean `true` only).
func orderShippingLabelPrinted(_ order: [String: Any]) -> Bool {
    guard let value = orderFulfillmentObject(order)?["labelPrinted"] as? NSNumber,
          CFGetTypeID(value) == CFBooleanGetTypeID() else { return false }
    return value.boolValue
}

/// One dated event in the order detail's timeline.
struct OrderTimelineEvent: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case created, paid, shippingRecord, arriveBy
    }
    let kind: Kind
    let title: String
    let date: Date
    /// A calendar date without a time (an arrive-by date sent as midnight UTC); shown in UTC, without a time.
    var dateOnly = false
    var id: String { kind.rawValue }
}

/// The order's dated events in a fixed order: Created, Paid, Shipping label created (or Shipping record created when
/// Slant doesn't say a label was printed), Arrive by. Each appears only when its date reads; nothing is guessed.
func orderTimelineEvents(_ order: [String: Any]) -> [OrderTimelineEvent] {
    var events: [OrderTimelineEvent] = []
    if let created = orderCreatedDate(order) {
        events.append(OrderTimelineEvent(kind: .created, title: "Created", date: created))
    }
    if let paid = orderPaidDate(order) {
        events.append(OrderTimelineEvent(kind: .paid, title: "Paid", date: paid))
    }
    if let record = orderShippingRecordCreatedDate(order) {
        events.append(OrderTimelineEvent(kind: .shippingRecord,
                                         title: orderShippingLabelPrinted(order) ? "Shipping label created" : "Shipping record created",
                                         date: record))
    }
    if let arriveBy = orderArriveByDate(order) {
        events.append(OrderTimelineEvent(kind: .arriveBy, title: "Arrive by", date: arriveBy,
                                         dateOnly: orderArriveByIsDateOnly(arriveBy)))
    }
    return events
}

/// "29 Oct, 15:10" (or "29 Oct" without the time) in the given locale and time zone; the year is added when it isn't
/// this year's. A date-only value is shown in UTC, so it isn't shifted to the previous day west of Greenwich.
func orderTimelineDateText(_ date: Date, includeTime: Bool = true, dateOnly: Bool = false, now: Date = Date(),
                           locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    let zone = dateOnly ? (TimeZone(identifier: "UTC") ?? .gmt) : timeZone
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = zone
    formatter.setLocalizedDateFormatFromTemplate((sameYear ? "dMMM" : "dMMMy") + (includeTime && !dateOnly ? "jmm" : ""))
    return formatter.string(from: date)
}

/// The text shown for one event: a date and time, or just the date for Arrive by (as the Arrive by column shows it).
func orderTimelineEventDateText(_ event: OrderTimelineEvent, now: Date = Date(), locale: Locale = .current,
                                timeZone: TimeZone = .current) -> String {
    orderTimelineDateText(event.date, includeTime: event.kind != .arriveBy, dateOnly: event.dateOnly, now: now,
                          locale: locale, timeZone: timeZone)
}

/// Weekdays between two moments, counted as 3DAPI's Needs Attention counts them (`dapiBusinessDays`: weekdays after
/// `start`'s day up to and including `end`'s day, in `calendar`'s time zone; public holidays are not known, so they
/// count). Shared date arithmetic only: nothing else from 3DAPI is used.
func orderBusinessDays(from start: Date, to end: Date, calendar: Calendar = .current) -> Int {
    dapiBusinessDays(from: start, to: end, calendar: calendar)
}

/// `Calendar.current` (the seller's weekend) in `timeZone`.
func orderBusinessDayCalendar(timeZone: TimeZone = .current) -> Calendar {
    var calendar = Calendar.current
    calendar.timeZone = timeZone
    return calendar
}

func orderBusinessDaysText(_ days: Int) -> String { days == 1 ? "1 business day" : "\(days) business days" }

// MARK: Paid, not yet shipped

/// Whether the order is paid and still being made, as far as Plinth can tell: a production status shown by
/// `orderDisplayStatus` (so not once the shipping record says it shipped), with a readable `processedAt`, and no
/// shipping record date yet. Display only.
func orderIsPaidAwaitingShipment(_ order: [String: Any]) -> Bool {
    let shown = orderDisplayStatus(order).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    return orderAttentionProductionStatuses.contains(shown) && orderPaidDate(order) != nil
        && orderShippingRecordCreatedDate(order) == nil
}

/// The caption under the detail's header for a paid order that hasn't shipped: "Paid 29 Oct · 3 business days ago ·
/// Slant doesn’t share print stages or a finish date." The last part is left out when an item did report progress
/// (`hasItemProgress`), which Plinth still shows if Slant ever sends it. Nil for any other order.
func orderPaidAwaitingShipmentCaption(_ order: [String: Any], hasItemProgress: Bool = false, now: Date = Date(),
                                      locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
    guard orderIsPaidAwaitingShipment(order), let paid = orderPaidDate(order) else { return nil }
    let calendar = orderBusinessDayCalendar(timeZone: timeZone)
    let age: String
    if paid > now || calendar.isDate(paid, inSameDayAs: now) {
        age = "today"
    } else {
        let days = orderBusinessDays(from: paid, to: now, calendar: calendar)
        age = days == 0 ? "no business days since" : "\(orderBusinessDaysText(days)) ago"
    }
    var parts = ["Paid \(orderTimelineDateText(paid, includeTime: false, now: now, locale: locale, timeZone: timeZone))", age]
    if !hasItemProgress { parts.append("Slant doesn’t share print stages or a finish date.") }
    var text = parts.joined(separator: " · ")
    if hasItemProgress { text += "." }
    return text
}

/// Whether any of the order's items has production progress to show (`orderItemProgress`), judged by the shown status.
func orderHasItemProgress(_ order: [String: Any]) -> Bool {
    let items = (order["items"] as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    let shown = orderDisplayStatus(order)
    return items.contains { orderItemProgress($0, orderStatus: shown) != nil }
}

// MARK: Typical time to ship (from the seller's own orders)

/// The most recent orders the typical time is worked out from.
let orderShipTimeSampleLimit = 30
/// Fewer orders than this say too little to show.
let orderShipTimeMinimumOrders = 3

/// Business days from payment to Slant's shipping record, over the seller's most recent such orders.
struct OrderShipTimeSummary: Equatable {
    var orders: Int
    var fewest: Int
    var most: Int
    /// The middle value; halfway between the two middle values for an even count.
    var median: Double
}

/// One order's business days from `processedAt` to `fulfillment.createdAt`, with the record's date for recency. Nil
/// unless the order counts as charged (`spendReportCountedStatuses`, Slant's raw status) and has both dates with the
/// record not before the payment, and the record says a label was printed or the order shipped.
func orderShipTimeSample(_ order: [String: Any], calendar: Calendar) -> (days: Int, recordDate: Date)? {
    let status = ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard spendReportCountedStatuses.contains(status), let paid = orderPaidDate(order),
          let record = orderShippingRecordCreatedDate(order), record >= paid else { return nil }
    let shipped = orderFulfillmentStatus(order).map { orderFulfillmentShippedStatuses.contains($0) } ?? false
    guard orderShippingLabelPrinted(order) || shipped else { return nil }
    return (orderBusinessDays(from: paid, to: record, calendar: calendar), record)
}

/// The typical time from payment to a shipping label over `records`, newest record first, at most
/// `orderShipTimeSampleLimit` orders, each order counted once. Nil with fewer than `orderShipTimeMinimumOrders`.
/// Callers pass the rows they show or sum: the Spending Report's orders, or the loaded orders on the default platform
/// (`ordersShownOnPlatform`), never every platform's.
func orderShipTimeSummary(_ records: [Record], calendar: Calendar = .current) -> OrderShipTimeSummary? {
    var seen = Set<String>()
    var samples: [(days: Int, recordDate: Date, id: String)] = []
    for record in records {
        let order = orderObject(record.values)
        let number = orderNumber(order)
        let key = number.isEmpty ? record.id : number
        if !key.isEmpty, !seen.insert(key).inserted { continue }
        if let sample = orderShipTimeSample(order, calendar: calendar) {
            samples.append((sample.days, sample.recordDate, key))
        }
    }
    let recent = samples.sorted {
        $0.recordDate != $1.recordDate ? $0.recordDate > $1.recordDate : $0.id < $1.id
    }.prefix(orderShipTimeSampleLimit)
    guard recent.count >= orderShipTimeMinimumOrders else { return nil }
    let days = recent.map(\.days).sorted()
    let middle = days.count / 2
    let median = days.count.isMultiple(of: 2) ? Double(days[middle - 1] + days[middle]) / 2 : Double(days[middle])
    return OrderShipTimeSummary(orders: days.count, fewest: days.first ?? 0, most: days.last ?? 0, median: median)
}

/// "3", or "3.5" for a median halfway between two values.
func orderShipTimeNumberText(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
}

/// "3–4 business days", or "3 business days" when every order took the same.
func orderShipTimeRangeText(_ summary: OrderShipTimeSummary) -> String {
    summary.fewest == summary.most ? orderBusinessDaysText(summary.fewest) : "\(summary.fewest)–\(summary.most) business days"
}

/// The order detail's line for a paid order that hasn't shipped: "Your recent orders got a shipping label 3–4
/// business days after payment (median 3, last 5 orders)."
func orderShipTimeDetailLine(_ summary: OrderShipTimeSummary) -> String {
    "Your recent orders got a shipping label \(orderShipTimeRangeText(summary)) after payment (median \(orderShipTimeNumberText(summary.median)), last \(summary.orders) orders)."
}

let orderShipTimeReportHeading = "Payment to shipping label"
/// Under the Spending Report's section and in the copied text.
let orderShipTimeReportCaption = "From your own orders in this report: business days from payment to when Slant’s shipping record was created, over your most recent \(orderShipTimeSampleLimit) at most. Weekends aren’t counted; public holidays are. Slant doesn’t publish a finish date, so this isn’t a promise."

/// The section's one-line summary: "5 orders: 3–4 business days, median 3."
func orderShipTimeReportLine(_ summary: OrderShipTimeSummary) -> String {
    "\(summary.orders) orders: \(orderShipTimeRangeText(summary)), median \(orderShipTimeNumberText(summary.median))."
}

/// Appended to the Spending Report's copied text, or "" without a summary.
func orderShipTimeReportText(_ summary: OrderShipTimeSummary?) -> String {
    guard let summary else { return "" }
    return ["", orderShipTimeReportHeading, orderShipTimeReportCaption, orderShipTimeReportLine(summary)]
        .joined(separator: "\n") + "\n"
}

/// Appended to the Spending Report's CSV (after a blank row), or "" without a summary. Plain numbers only.
func orderShipTimeReportCSV(_ summary: OrderShipTimeSummary?) -> String {
    guard let summary else { return "" }
    let rows: [[String]] = [
        [],
        ["Payment to shipping label", "Orders", "Fewest business days", "Most business days", "Median business days"],
        ["Recent orders", String(summary.orders), String(summary.fewest), String(summary.most),
         orderShipTimeNumberText(summary.median)]
    ]
    return rows.map { $0.map(csvField).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
}

/// The typical time over `records` on the platform `platformID` (`ordersShownOnPlatform`, without the Orders list's
/// lock exception, as the Spending Report sums: orders naming another platform are left out, orders naming none are
/// kept, and without a platform nothing is left out). Display only; the records passed in are never changed.
func orderShipTimeSummary(_ records: [Record], platformID: String, calendar: Calendar = .current) -> OrderShipTimeSummary? {
    orderShipTimeSummary(ordersShownOnPlatform(records, platformID: platformID), calendar: calendar)
}

extension StudioStore {
    /// The typical time over `records` on the default platform. `store.orders` is never filtered.
    func orderShipTimeSummary(for records: [Record]) -> OrderShipTimeSummary? {
        Plinth.orderShipTimeSummary(records, platformID: platformID)
    }
}

// MARK: Views

/// The order detail's timeline: one row per dated event. Display only.
struct OrderTimelineSection: View {
    let order: [String: Any]

    var body: some View {
        let events = orderTimelineEvents(order)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Timeline").font(.headline)
                ForEach(events) { event in
                    LabeledContent(event.title) {
                        Text(orderTimelineEventDateText(event)).monospacedDigit().textSelection(.enabled)
                    }
                }
            }
            .labeledContentStyle(.receipt)
        }
    }
}
