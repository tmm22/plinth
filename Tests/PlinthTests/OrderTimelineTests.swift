import XCTest
@testable import Plinth

/// The order detail's timeline, the caption for a paid order not yet shipped, and the seller's own time from payment
/// to a shipping label (OrderTimeline.swift). Display only; made-up IDs and dates.
final class OrderTimelineTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let gb = Locale(identifier: "en_GB")
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_GB")
        calendar.timeZone = utc
        return calendar
    }
    private func date(_ text: String) -> Date { orderTimestamp(text)! }

    private let shippedRecord: [String: Any] = [
        "status": "SHIPPED", "provider": "SHIPPO", "deliveryMethod": "INTERNATIONAL", "trackingNumbers": ["TEST0001US"],
        "labelPrinted": true, "providerStatus": NSNull(), "createdAt": "2026-10-23T15:00:00.000Z",
        "updatedAt": "2026-10-23T15:20:00.000Z"
    ]

    private func order(_ status: String = "PRINTING", created: Any? = "2026-10-19T09:00:00.000Z",
                       paid: Any? = "2026-10-19T09:05:00.000Z", fulfillment: Any? = nil, id: String = "SLANT_1",
                       extra: [String: Any] = [:]) -> [String: Any] {
        var values: [String: Any] = ["publicId": id, "status": status]
        if let created { values["createdAt"] = created }
        if let paid { values["processedAt"] = paid }
        if let fulfillment { values["fulfillment"] = fulfillment }
        values.merge(extra) { _, new in new }
        return values
    }

    // MARK: Timeline

    func testTheTimelineListsOnlyReadableDatesInOrder() {
        var full = order(fulfillment: shippedRecord)
        full["arriveByDate"] = "2026-11-05T00:00:00.000Z"
        let events = orderTimelineEvents(full)
        XCTAssertEqual(events.map(\.title), ["Created", "Paid", "Shipping label created", "Arrive by"])
        XCTAssertEqual(events.map(\.date), [date("2026-10-19T09:00:00Z"), date("2026-10-19T09:05:00Z"),
                                            date("2026-10-23T15:00:00Z"), date("2026-11-05T00:00:00Z")])
        XCTAssertEqual(events.last?.dateOnly, true)
        // Last updated comes last, and only when the order changed after it was made.
        var updated = full
        updated["updatedAt"] = "2026-10-24T08:00:00.000Z"
        XCTAssertEqual(orderTimelineEvents(updated).map(\.title), ["Created", "Paid", "Shipping label created", "Arrive by", "Last updated"])
        updated["updatedAt"] = "2026-10-19T09:00:30.000Z"
        XCTAssertEqual(orderTimelineEvents(updated).last?.title, "Arrive by", "within a minute of creation")

        // A draft: created only (Slant sends no processedAt and a null fulfillment).
        XCTAssertEqual(orderTimelineEvents(order("DRAFT", paid: NSNull(), fulfillment: NSNull())).map(\.title), ["Created"])
        // Unreadable or missing dates are skipped, never guessed.
        XCTAssertEqual(orderTimelineEvents(order(created: "yesterday", paid: 42)).map(\.title), [])
        XCTAssertEqual(orderTimelineEvents([:]).map(\.title), [])
        // A shipping record that isn't an object, or has no readable createdAt, adds nothing.
        XCTAssertEqual(orderTimelineEvents(order(fulfillment: "SHIPPED")).map(\.title), ["Created", "Paid"])
        XCTAssertEqual(orderTimelineEvents(order(fulfillment: ["status": "SHIPPED", "createdAt": NSNull()])).map(\.title), ["Created", "Paid"])
    }

    func testTheShippingRecordDateIsAlwaysTheShippingLabel() {
        var record = shippedRecord
        record["labelPrinted"] = false
        XCTAssertEqual(orderTimelineEvents(order(fulfillment: record)).map(\.title), ["Created", "Paid", "Shipping label created"])
        for odd: Any in ["true", 1, NSNull()] {
            record["labelPrinted"] = odd
            XCTAssertFalse(orderShippingLabelPrinted(order(fulfillment: record)), "\(odd)")
        }
        record.removeValue(forKey: "labelPrinted")
        XCTAssertEqual(orderTimelineEvents(order(fulfillment: record)).last?.title, "Shipping label created")
        XCTAssertTrue(orderShippingLabelPrinted(order(fulfillment: shippedRecord)))
    }

    func testDatesAreShownInTheMacsTimeZoneAndArriveByInUTC() {
        let now = date("2026-11-01T12:00:00Z")
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        let paid = date("2026-10-28T23:30:00Z")
        XCTAssertEqual(orderTimelineDateText(paid, includeTime: false, now: now, locale: gb, timeZone: utc), "28 Oct")
        XCTAssertEqual(orderTimelineDateText(paid, includeTime: false, now: now, locale: gb, timeZone: sydney), "29 Oct")
        XCTAssertTrue(orderTimelineDateText(paid, now: now, locale: gb, timeZone: utc).hasPrefix("28 Oct"))
        XCTAssertTrue(orderTimelineDateText(paid, now: now, locale: gb, timeZone: utc).contains("23:30"))
        XCTAssertTrue(orderTimelineDateText(date("2025-12-30T10:00:00Z"), includeTime: false, now: now, locale: gb, timeZone: utc)
            .contains("2025"), "another year shows the year")
        // A date-only arrive-by keeps its day west of Greenwich, without a time.
        let arriveBy = OrderTimelineEvent(kind: .arriveBy, title: "Arrive by", date: date("2026-11-05T00:00:00Z"), dateOnly: true)
        let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
        XCTAssertEqual(orderTimelineEventDateText(arriveBy, now: now, locale: gb, timeZone: losAngeles), "5 Nov")
        let created = OrderTimelineEvent(kind: .created, title: "Created", date: paid)
        XCTAssertTrue(orderTimelineEventDateText(created, now: now, locale: gb, timeZone: utc).contains("23:30"))
    }

    // MARK: Paid, not yet shipped

    func testThePaidCaptionCountsBusinessDays() {
        let now = date("2026-11-02T12:00:00Z") // Monday
        func caption(_ values: [String: Any], at: Date? = nil, typical: OrderShipTimeSummary? = nil) -> String? {
            orderPaidAwaitingShipmentCaption(values, typical: typical, now: at ?? now, locale: gb, timeZone: utc)
        }
        // Paid Wednesday: Thursday, Friday and Monday.
        XCTAssertEqual(caption(order(paid: "2026-10-28T10:00:00Z")), "Paid 3 business days ago (28 Oct).")
        XCTAssertEqual(caption(order("SUBMITTED", paid: "2026-10-30T10:00:00Z")), "Paid 1 business day ago (30 Oct).")
        XCTAssertEqual(caption(order(paid: "2026-11-02T08:00:00Z")), "Paid today (2 Nov).")
        // While no business day has passed, calendar words: paid Saturday, read on Sunday; paid Friday, read on Sunday.
        XCTAssertEqual(caption(order(paid: "2026-10-31T10:00:00Z"), at: date("2026-11-01T10:00:00Z")), "Paid yesterday (31 Oct).")
        XCTAssertEqual(caption(order(paid: "2026-10-30T10:00:00Z"), at: date("2026-11-01T10:00:00Z")), "Paid on Friday (30 Oct).")
        // A payment time ahead of the clock reads as today rather than a negative age.
        XCTAssertEqual(caption(order(paid: "2026-11-02T13:00:00Z")), "Paid today (2 Nov).")
        // The seller's usual time, in plain words.
        XCTAssertEqual(caption(order(paid: "2026-10-28T10:00:00Z"), typical: OrderShipTimeSummary(orders: 5, fewest: 3, most: 4, median: 3)),
                       "Paid 3 business days ago (28 Oct). Your recent orders usually got a shipping label after 3 business days (3–4 over the last 5).")
        // What Slant doesn't share goes in the help, unless an item ever reports progress again.
        XCTAssertTrue(orderPaidAwaitingShipmentHelp(hasItemProgress: false, hasTypical: false).hasPrefix("Slant doesn’t share print stages or a finish date."))
        XCTAssertFalse(orderPaidAwaitingShipmentHelp(hasItemProgress: true, hasTypical: false).contains("print stages"))
        XCTAssertTrue(orderPaidAwaitingShipmentHelp(hasItemProgress: false, hasTypical: true).contains("isn’t a promise"))
    }

    func testThePaidCaptionIsOnlyForPaidOrdersStillBeingMade() {
        let now = date("2026-11-02T12:00:00Z")
        func caption(_ values: [String: Any]) -> String? {
            orderPaidAwaitingShipmentCaption(values, now: now, locale: gb, timeZone: utc)
        }
        XCTAssertNil(caption(order("DRAFT", paid: nil)))
        XCTAssertNil(caption(order("SHIPPED", fulfillment: shippedRecord)))
        XCTAssertNil(caption(order("CANCELLED")))
        XCTAssertNil(caption(order("PAYMENT_ERROR")))
        XCTAssertNil(caption(order("ON_HOLD")), "an unrecognised status isn't guessed at")
        XCTAssertNil(caption(order(paid: nil)), "no payment date, no caption")
        XCTAssertNil(caption(order(paid: "soon")))
        // Shown as Shipped from Slant's shipping record (`orderDisplayStatus`): not awaiting shipment.
        XCTAssertNil(caption(order("PRINTING", fulfillment: shippedRecord)))
        // A label already made but not shipped: the timeline says so instead.
        XCTAssertNil(caption(order("PRINTING", fulfillment: ["status": "AWAITING_SHIPMENT", "labelPrinted": true,
                                                             "createdAt": "2026-10-30T10:00:00Z"])))
        // A record without a date doesn't count as one.
        XCTAssertNotNil(caption(order("PRINTING", fulfillment: ["status": "AWAITING_SHIPMENT"])))
        XCTAssertNotNil(caption(order("PRINTING", fulfillment: NSNull())))
        XCTAssertNotNil(caption(order(" submitted ")))
    }

    func testItemProgressIsJudgedByTheShownStatus() {
        let items: [[String: Any]] = [["estimatedPrintCompletion": "2026-11-03T10:00:00Z"]]
        XCTAssertTrue(orderHasItemProgress(order(extra: ["items": items])))
        XCTAssertFalse(orderHasItemProgress(order(fulfillment: shippedRecord, extra: ["items": items])))
        XCTAssertFalse(orderHasItemProgress(order(extra: ["items": [["estimatedPrintCompletion": NSNull()]]])))
        XCTAssertFalse(orderHasItemProgress(order(extra: ["items": "not a list"])))
    }

    // MARK: Typical time to ship

    /// A shipped order paid at `paid` whose shipping record was created at `label`.
    private func shipped(_ id: String, paid: String, label: String, status: String = "SHIPPED", platform: String? = nil,
                         labelPrinted: Any = true, recordStatus: String = "SHIPPED") -> Record {
        var record = shippedRecord
        record["createdAt"] = label
        record["labelPrinted"] = labelPrinted
        record["status"] = recordStatus
        var values = order(status, created: paid, paid: paid, fulfillment: record, id: id)
        if let platform { values["customer"] = ["platformId": platform] }
        return Record(values: values)
    }

    func testTheSummaryNeedsThreeOrders() {
        let two = [shipped("A", paid: "2026-10-05T10:00:00Z", label: "2026-10-08T10:00:00Z"),
                   shipped("B", paid: "2026-10-12T10:00:00Z", label: "2026-10-15T10:00:00Z")]
        XCTAssertNil(orderShipTimeSummary(two, calendar: utcCalendar))
        // The same order twice counts once.
        XCTAssertNil(orderShipTimeSummary(two + [two[0]], calendar: utcCalendar))
        let three = two + [shipped("C", paid: "2026-10-16T10:00:00Z", label: "2026-10-21T10:00:00Z")] // Fri → Wed
        XCTAssertEqual(orderShipTimeSummary(three, calendar: utcCalendar),
                       OrderShipTimeSummary(orders: 3, fewest: 3, most: 3, median: 3))
    }

    func testTheSummaryRangeAndMedian() {
        let records = [
            shipped("A", paid: "2026-10-05T10:00:00Z", label: "2026-10-07T10:00:00Z"), // 2
            shipped("B", paid: "2026-10-12T10:00:00Z", label: "2026-10-15T10:00:00Z"), // 3
            shipped("C", paid: "2026-10-16T10:00:00Z", label: "2026-10-22T10:00:00Z"), // 4: the weekend isn't counted
            shipped("D", paid: "2026-10-19T10:00:00Z", label: "2026-10-22T10:00:00Z", status: "PRINTING") // 3, status lagging
        ]
        let summary = orderShipTimeSummary(records, calendar: utcCalendar)
        XCTAssertEqual(summary, OrderShipTimeSummary(orders: 4, fewest: 2, most: 4, median: 3))
        let odd = orderShipTimeSummary(Array(records.prefix(3)) + [shipped("E", paid: "2026-10-26T10:00:00Z", label: "2026-10-30T10:00:00Z")],
                                       calendar: utcCalendar)
        XCTAssertEqual(odd, OrderShipTimeSummary(orders: 4, fewest: 2, most: 4, median: 3.5))
    }

    func testOnlyUsableOrdersCount() {
        let good = [
            shipped("A", paid: "2026-10-05T10:00:00Z", label: "2026-10-08T10:00:00Z"),
            shipped("B", paid: "2026-10-12T10:00:00Z", label: "2026-10-15T10:00:00Z"),
        ]
        let unusable = [
            // The record before the payment.
            shipped("X1", paid: "2026-10-15T10:00:00Z", label: "2026-10-12T10:00:00Z"),
            // Cancelled, drafts, payment problems and unknown statuses aren't the seller's charged orders.
            shipped("X2", paid: "2026-10-05T10:00:00Z", label: "2026-10-08T10:00:00Z", status: "CANCELLED"),
            shipped("X3", paid: "2026-10-05T10:00:00Z", label: "2026-10-08T10:00:00Z", status: "DRAFT"),
            shipped("X4", paid: "2026-10-05T10:00:00Z", label: "2026-10-08T10:00:00Z", status: "ON_HOLD"),
            // Neither a printed label nor a shipped record.
            shipped("X5", paid: "2026-10-05T10:00:00Z", label: "2026-10-08T10:00:00Z", labelPrinted: false, recordStatus: "AWAITING_SHIPMENT"),
            // Unreadable dates.
            shipped("X6", paid: "not a date", label: "2026-10-08T10:00:00Z"),
            shipped("X7", paid: "2026-10-05T10:00:00Z", label: "soon"),
            Record(values: order("SHIPPED", fulfillment: NSNull(), id: "X8")),
            Record(values: order("SHIPPED", fulfillment: "SHIPPED", id: "X9")),
        ]
        XCTAssertNil(orderShipTimeSummary(good + unusable, calendar: utcCalendar))
        // A shipped record without labelPrinted still counts: the parcel left.
        let third = shipped("C", paid: "2026-10-12T10:00:00Z", label: "2026-10-14T10:00:00Z", labelPrinted: NSNull())
        XCTAssertEqual(orderShipTimeSummary(good + unusable + [third], calendar: utcCalendar)?.orders, 3)
    }

    func testOnlyTheMostRecentThirtyCount() {
        // 31 orders: the oldest took ten business days, the rest one. Only the newest 30 labels count.
        let base = date("2026-01-05T10:00:00Z")
        var records = [shipped("OLD", paid: "2025-12-01T10:00:00Z", label: "2025-12-15T10:00:00Z")]
        for index in 0..<30 {
            let paid = base.addingTimeInterval(Double(index) * 7 * 86_400) // Mondays
            let iso = ISO8601DateFormatter()
            records.append(shipped("N\(index)", paid: iso.string(from: paid), label: iso.string(from: paid.addingTimeInterval(86_400))))
        }
        XCTAssertEqual(orderShipTimeSummary(records, calendar: utcCalendar),
                       OrderShipTimeSummary(orders: orderShipTimeSampleLimit, fewest: 1, most: 1, median: 1))
    }

    func testOtherPlatformsAreLeftOut() {
        let records = [
            shipped("A", paid: "2026-10-05T10:00:00Z", label: "2026-10-08T10:00:00Z", platform: "plat-1"),
            shipped("B", paid: "2026-10-12T10:00:00Z", label: "2026-10-15T10:00:00Z", platform: "plat-1"),
            shipped("C", paid: "2026-10-12T10:00:00Z", label: "2026-10-14T10:00:00Z", platform: "plat-2"),
            shipped("D", paid: "2026-10-19T10:00:00Z", label: "2026-10-23T10:00:00Z"), // names no platform: kept
        ]
        XCTAssertEqual(orderShipTimeSummary(records, platformID: "plat-1", calendar: utcCalendar),
                       OrderShipTimeSummary(orders: 3, fewest: 3, most: 4, median: 3))
        XCTAssertNil(orderShipTimeSummary(records, platformID: "plat-2", calendar: utcCalendar), "only C and D")
        XCTAssertEqual(orderShipTimeSummary(records, platformID: "", calendar: utcCalendar)?.orders, 4, "no platform, nothing left out")
    }

    func testSummaryWording() {
        let range = OrderShipTimeSummary(orders: 5, fewest: 3, most: 4, median: 3)
        XCTAssertEqual(orderShipTimeDetailLine(range),
                       "Your recent orders usually got a shipping label after 3 business days (3–4 over the last 5).")
        let same = OrderShipTimeSummary(orders: 3, fewest: 1, most: 1, median: 1)
        XCTAssertEqual(orderShipTimeDetailLine(same),
                       "Your recent orders usually got a shipping label after 1 business day (each of the last 3).")
        XCTAssertEqual(orderShipTimeDetailLine(OrderShipTimeSummary(orders: 4, fewest: 2, most: 4, median: 3.5)),
                       "Your recent orders usually got a shipping label after 3.5 business days (2–4 over the last 4).")
        XCTAssertFalse(orderShipTimeDetailLine(range).contains("median"))
        XCTAssertEqual(orderShipTimeDetailLine(OrderShipTimeSummary(orders: 3, fewest: 0, most: 1, median: 0)),
                       "Your recent orders usually got a shipping label the same business day (0–1 over the last 3).")
    }

    func testTheSpendingReportHasNoShipTimeSection() throws {
        // Removed in round 18's review: the order detail keeps the usual time, the report doesn't repeat it.
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Plinth/SpendReport.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        XCTAssertFalse(text.contains("orderShipTime"))
    }

    func testBusinessDaysMatchThreeDAPIsCount() {
        let monday = date("2026-11-02T10:00:00Z")
        for end in ["2026-11-02T18:00:00Z", "2026-11-05T09:00:00Z", "2026-11-09T10:00:00Z", "2026-10-01T10:00:00Z"] {
            XCTAssertEqual(orderBusinessDays(from: monday, to: date(end), calendar: utcCalendar),
                           dapiBusinessDays(from: monday, to: date(end), calendar: utcCalendar), end)
        }
        XCTAssertEqual(orderBusinessDays(from: monday, to: date("2026-11-05T09:00:00Z"), calendar: utcCalendar), 3)
        XCTAssertEqual(orderBusinessDayCalendar(timeZone: utc).timeZone, utc)
    }
}
