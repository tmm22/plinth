import Foundation
import SwiftUI

// MARK: - Order timeline and time to ship
//
// Display only, worked out from orders already loaded: the order detail's dated events (Created, Paid, Shipping
// label created, Arrive by, Last updated), the caption for a paid order that hasn't shipped, and the seller's own
// typical time from payment to a shipping label (that caption and Report a Problem's late advice). Nothing here sends
// a request, saves order data, or feeds any pay, cancel or lock check, and nothing is presented as Slant's status or a
// promise from Slant.
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

/// When Slant's shipping record was created (`fulfillment.createdAt`), or nil without one. The seller sees it as when
/// the shipping label was created: the record is made with the label.
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
        case created, paid, shippingRecord, arriveBy, updated
    }
    let kind: Kind
    let title: String
    let date: Date
    /// A calendar date without a time (an arrive-by date sent as midnight UTC); shown in UTC, without a time.
    var dateOnly = false
    var id: String { kind.rawValue }
}

/// The order's dated events in a fixed order: Created, Paid (`processedAt`), Shipping label created (the shipping
/// record's `createdAt`, whatever `labelPrinted` says), Arrive by, then Last updated (`updatedAt`, left out within a
/// minute of creation: `orderLastUpdatedDate`). Each appears only when its date reads; nothing is guessed.
func orderTimelineEvents(_ order: [String: Any]) -> [OrderTimelineEvent] {
    var events: [OrderTimelineEvent] = []
    if let created = orderCreatedDate(order) {
        events.append(OrderTimelineEvent(kind: .created, title: "Created", date: created))
    }
    if let paid = orderPaidDate(order) {
        events.append(OrderTimelineEvent(kind: .paid, title: "Paid", date: paid))
    }
    if let record = orderShippingRecordCreatedDate(order) {
        events.append(OrderTimelineEvent(kind: .shippingRecord, title: "Shipping label created", date: record))
    }
    if let arriveBy = orderArriveByDate(order) {
        events.append(OrderTimelineEvent(kind: .arriveBy, title: "Arrive by", date: arriveBy,
                                         dateOnly: orderArriveByIsDateOnly(arriveBy)))
    }
    if let updated = orderLastUpdatedDate(order) {
        events.append(OrderTimelineEvent(kind: .updated, title: "Last updated", date: updated))
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

/// How long ago the order was paid, in words: "3 business days ago", or, while no business day has passed (paid
/// today, at the weekend, or ahead of the clock), by the calendar: "today", "yesterday" or "on Saturday".
func orderPaidAgoText(_ paid: Date, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
    let calendar = orderBusinessDayCalendar(timeZone: timeZone)
    if paid > now || calendar.isDate(paid, inSameDayAs: now) { return "today" }
    let days = orderBusinessDays(from: paid, to: now, calendar: calendar)
    if days > 0 { return "\(orderBusinessDaysText(days)) ago" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(paid, inSameDayAs: yesterday) {
        return "yesterday"
    }
    let formatter = DateFormatter()
    formatter.locale = locale
    formatter.timeZone = timeZone
    formatter.setLocalizedDateFormatFromTemplate("EEEE")
    return "on \(formatter.string(from: paid))"
}

/// When the label usually came: "after 3 business days", "after 1 business day", "after 3.5 business days" for a
/// median halfway between two values, or "the same business day" for a median of 0.
func orderShipTimeTypicalText(_ summary: OrderShipTimeSummary) -> String {
    if summary.median == 0 { return "the same business day" }
    return summary.median == 1 ? "after 1 business day" : "after \(orderShipTimeNumberText(summary.median)) business days"
}

/// The caption under the detail's header for a paid order that hasn't shipped: "Paid 3 business days ago (29 Oct)."
/// (or "Paid today (1 Nov).", "Paid yesterday (31 Oct).", "Paid on Saturday (31 Oct)." while no business day has
/// passed), then, with the seller's own `typical` time, `orderShipTimeDetailLine`. Nil for any other order. That Slant
/// shares no print stages goes in the help (`orderPaidAwaitingShipmentHelp`).
func orderPaidAwaitingShipmentCaption(_ order: [String: Any], typical: OrderShipTimeSummary? = nil, now: Date = Date(),
                                      locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
    guard orderIsPaidAwaitingShipment(order), let paid = orderPaidDate(order) else { return nil }
    let date = orderTimelineDateText(paid, includeTime: false, now: now, locale: locale, timeZone: timeZone)
    var text = "Paid \(orderPaidAgoText(paid, now: now, locale: locale, timeZone: timeZone)) (\(date))."
    if let typical { text += " " + orderShipTimeDetailLine(typical) }
    return text
}

/// Hover text for that caption: that Slant shares no print stages (left out if an item ever reports progress), how
/// business days are counted, and where the usual time comes from.
func orderPaidAwaitingShipmentHelp(hasItemProgress: Bool, hasTypical: Bool) -> String {
    var parts: [String] = []
    if !hasItemProgress { parts.append("Slant doesn’t share print stages or a finish date.") }
    parts.append("Business days are weekdays in this Mac’s time zone; public holidays still count.")
    if hasTypical {
        parts.append("The usual time comes from your own recent orders on your default platform (up to \(orderShipTimeSampleLimit) with both dates): from payment to when Slant made the shipping label. It isn’t a promise from Slant.")
    }
    return parts.joined(separator: " ")
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
/// Callers pass the loaded orders on the default platform
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

/// The sentence about the seller's usual time: "Your recent orders usually got a shipping label after 3 business days
/// (3–4 over the last 5)." or, when every order took the same, "(each of the last 3)".
func orderShipTimeDetailLine(_ summary: OrderShipTimeSummary) -> String {
    let spread = summary.fewest == summary.most
        ? "each of the last \(summary.orders)"
        : "\(summary.fewest)–\(summary.most) over the last \(summary.orders)"
    return "Your recent orders usually got a shipping label \(orderShipTimeTypicalText(summary)) (\(spread))."
}

/// The typical time over `records` on the platform `platformID` (`ordersShownOnPlatform`, without the Orders list's
/// lock exception: orders naming another platform are left out, orders naming none are kept, and without a platform
/// nothing is left out). Display only; the records passed in are never changed.
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

/// The order detail's timeline: one row per dated event, shown from two events up. Display only.
struct OrderTimelineSection: View {
    let order: [String: Any]

    var body: some View {
        let events = orderTimelineEvents(order)
        // A lone date (a draft's Created) says nothing a timeline adds.
        if events.count >= 2 {
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
