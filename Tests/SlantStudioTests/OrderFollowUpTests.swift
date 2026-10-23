import XCTest
@testable import SlantStudio

final class OrderFollowUpTests: XCTestCase {
    private let day: TimeInterval = 86_400
    private let now = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!

    private func iso(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    private func order(_ id: String, status: String = "SHIPPED", created: String? = "2026-10-20T10:00:00Z",
                       tracking: Any? = nil, provider: Any? = nil, metadata: [String: Any]? = nil,
                       name: String? = nil, extra: [String: Any] = [:]) -> Record {
        var values: [String: Any] = ["publicId": id, "status": status]
        if let created { values["createdAt"] = created }
        var fulfillment: [String: Any] = [:]
        if let tracking { fulfillment["trackingNumbers"] = tracking }
        if let provider { fulfillment["provider"] = provider }
        if !fulfillment.isEmpty { values["fulfillment"] = fulfillment }
        if let metadata { values["metadata"] = metadata }
        if let name { values["customer"] = ["details": ["address": ["name": name, "line1": "1 High St"], "email": "a@example.com"]] }
        values.merge(extra) { _, new in new }
        return Record(values: values)
    }

    // MARK: Shipped list and grouping

    func testOnlyOrdersWithTrackingAreListedAndGroupedByMarketplaceReference() {
        let records = [
            order("SLANT_1", created: "2026-10-18T10:00:00Z", tracking: ["1Z1"], metadata: ["source": "etsy", "sourceOrderId": "3141"]),
            order("SLANT_2", tracking: [], metadata: ["source": "shopify", "sourceOrderId": "#1001"]),
            order("SLANT_3", created: "2026-10-21T10:00:00Z", tracking: ["9400"]),
            order("SLANT_4", status: "DRAFT", metadata: ["source": "etsy", "sourceOrderId": "2718"]),
            order("SLANT_5", created: "2026-10-22T10:00:00Z", tracking: ["1Z5", "1Z5", " "], metadata: ["source": "shopify", "sourceOrderId": "#1002"])
        ]
        let groups = shopFollowUpGroups(records, done: [])
        XCTAssertEqual(groups.imported.map(\.id), ["SLANT_5", "SLANT_1"], "newest first; no tracking, no row")
        XCTAssertEqual(groups.notImported.map(\.id), ["SLANT_3"])
        XCTAssertEqual(groups.imported.first?.trackingNumbers, ["1Z5"], "blanks and repeats dropped")
        XCTAssertEqual(groups.doneCount, 0)
    }

    func testDoneOrdersAreHiddenAndCountedUnlessShown() {
        let records = [
            order("A", tracking: ["1"], metadata: ["sourceOrderId": "1"]),
            order("B", tracking: ["2"]),
            order("C", tracking: ["3"], metadata: ["sourceOrderId": "3"])
        ]
        let hidden = shopFollowUpGroups(records, done: ["A", "B", "gone"])
        XCTAssertEqual(hidden.imported.map(\.id), ["C"])
        XCTAssertTrue(hidden.notImported.isEmpty)
        XCTAssertEqual(hidden.doneCount, 2, "IDs not in the loaded list aren't counted")
        let shown = shopFollowUpGroups(records, done: ["A", "B"], showDone: true)
        XCTAssertEqual(Set(shown.imported.map(\.id)), ["A", "C"])
        XCTAssertEqual(shown.notImported.map(\.id), ["B"])
        XCTAssertEqual(shown.doneCount, 2)
    }

    func testMissingDatesSortLastAndTiesKeepSlantOrder() {
        let records = [
            order("nodate", created: nil, tracking: ["1"]),
            order("a", created: "2026-10-20T10:00:00Z", tracking: ["2"]),
            order("b", created: "2026-10-20T10:00:00Z", tracking: ["3"]),
            order("a", created: "2026-10-20T10:00:00Z", tracking: ["4"])
        ]
        XCTAssertEqual(shopFollowUpGroups(records, done: []).notImported.map(\.id), ["a", "b", "nodate"], "a repeated ID is listed once")
    }

    func testEntryFieldsAndCopyTexts() throws {
        let entry = try XCTUnwrap(shopFollowUpEntry(order("SLANT_9", tracking: ["1Z9", "1Z10"], provider: "SHIPPO",
                                                          metadata: ["source": "etsy", "sourceOrderId": 3141592653],
                                                          name: "Ada  Lovelace")))
        XCTAssertEqual(entry.marketplaceID, "3141592653", "numeric IDs are read as text")
        XCTAssertEqual(entry.recipientFirstName, "Ada")
        XCTAssertEqual(entry.provider, "SHIPPO")
        XCTAssertEqual(shopFollowUpOrderTitle(entry), "Etsy order 3141592653")
        XCTAssertEqual(shopFollowUpTrackingText(entry), "1Z9, 1Z10")
        XCTAssertEqual(shopFollowUpOrderAndTrackingText(entry), "3141592653 — 1Z9, 1Z10")
        XCTAssertFalse(shopFollowUpOrderAndTrackingText(entry).contains("Ada"), "never the customer's name")

        let plain = try XCTUnwrap(shopFollowUpEntry(order("SLANT_8", tracking: ["9400"])))
        XCTAssertNil(plain.recipientFirstName)
        XCTAssertNil(plain.provider)
        XCTAssertEqual(shopFollowUpOrderTitle(plain), "Slant order SLANT_8")
        XCTAssertEqual(shopFollowUpOrderAndTrackingText(plain), "SLANT_8 — 9400")
    }

    func testSingleTrackingNumberFieldIsAccepted() throws {
        let record = Record(values: ["publicId": "X", "status": "SHIPPED", "fulfillment": ["trackingNumber": "LONE1"]])
        XCTAssertEqual(try XCTUnwrap(shopFollowUpEntry(record)).trackingNumbers, ["LONE1"])
        XCTAssertNil(shopFollowUpEntry(Record(values: ["publicId": "Y", "fulfillment": NSNull()])))
    }

    // MARK: Shopify tracking CSV

    func testShopifyOrderNameIsUsedAsStored() {
        XCTAssertEqual(shopifyOrderName(" #1001 "), "#1001")
        XCTAssertEqual(shopifyOrderName("SH1001"), "SH1001", "a shop's own prefix is kept")
        XCTAssertEqual(shopifyOrderName("1001"), "1001", "no # is invented")
    }

    func testShopifyCSVHasOnlyShopifyOrdersWithTrackingAndNoPersonalData() throws {
        let entries = [
            order("S1", tracking: ["1Z1"], provider: "UPS", metadata: ["source": "shopify", "sourceOrderId": "#1001"], name: "Ada Lovelace"),
            order("S2", tracking: ["1Z2", "1Z3"], provider: "ShipStation", metadata: ["source": "Shopify", "sourceOrderId": "#1002"]),
            order("E1", tracking: ["E1"], metadata: ["source": "etsy", "sourceOrderId": "3141"]),
            order("N1", tracking: ["N1"])
        ].compactMap(shopFollowUpEntry)
        XCTAssertEqual(shopifyTrackingCSVRows(entries), [["#1001", "1Z1", "UPS"], ["#1002", "1Z2,1Z3", ""]])
        let csv = shopifyTrackingCSV(entries)
        XCTAssertEqual(csv, "Order name,Tracking number,Tracking company\r\n#1001,1Z1,UPS\r\n#1002,\"1Z2,1Z3\",\r\n")
        XCTAssertFalse(csv.contains("Ada"))
        XCTAssertFalse(csv.contains("High St"))
    }

    func testShopifyCSVGuardsFormulaLikeValues() throws {
        let entries = [order("S1", tracking: ["=HYPERLINK(\"x\")"], provider: "+Carrier",
                             metadata: ["source": "shopify", "sourceOrderId": "@1001"])].compactMap(shopFollowUpEntry)
        let row = try XCTUnwrap(shopifyTrackingCSV(entries).components(separatedBy: "\r\n").dropFirst().first)
        XCTAssertEqual(row, "'@1001,\"'=HYPERLINK(\"\"x\"\")\",'+Carrier")
    }

    func testLabelServicesAreNotSentAsTheTrackingCompany() throws {
        func company(_ provider: Any?) throws -> String {
            try shopifyTrackingCompany(XCTUnwrap(shopFollowUpEntry(order("S", tracking: ["1"], provider: provider))))
        }
        XCTAssertEqual(try company("SHIPPO"), "")
        XCTAssertEqual(try company("Ship Station"), "")
        XCTAssertEqual(try company("USPS"), "USPS")
        XCTAssertEqual(try company(nil), "")
    }

    func testTrackingCSVFileName() {
        let date = ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")!
        XCTAssertTrue(shopifyTrackingCSVDefaultFileName(date: date).hasPrefix("Shopify tracking 2026-10-2"))
        XCTAssertTrue(shopifyTrackingCSVDefaultFileName(date: date).hasSuffix(".csv"))
    }

    // MARK: Arrive-by date

    func testArriveByParsingAndSortKey() {
        let top = order("A", extra: ["arriveByDate": "2026-10-25T00:00:00.000Z"]).values
        XCTAssertEqual(orderArriveByDate(top), ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z"))
        let nested = order("B", extra: ["fulfillment": ["arriveByDate": "2026-10-26"]]).values
        XCTAssertNotNil(orderArriveByDate(nested))
        XCTAssertNil(orderArriveByDate(order("C", extra: ["arriveByDate": NSNull()]).values))
        XCTAssertNil(orderArriveByDate(order("D", extra: ["arriveByDate": "soon"]).values))
        XCTAssertNil(orderArriveByDate(order("E", extra: ["fulfillment": ["estimatedDelivery": "2026-10-26"]]).values),
                     "an estimate isn't a promise")

        let rows = [
            OrderTableRow(record: order("late", extra: ["arriveByDate": "2026-10-30T00:00:00Z"])),
            OrderTableRow(record: order("none")),
            OrderTableRow(record: order("soon", extra: ["arriveByDate": "2026-10-24T00:00:00Z"]))
        ]
        let sorted = orderTableRowsSorted(rows, using: [KeyPathComparator(\OrderTableRow.arriveBySortKey)])
        XCTAssertEqual(sorted.map(\.id), ["soon", "late", "none"], "soonest first, blanks last")
        XCTAssertEqual(rows[1].arriveBy, "")
    }

    func testDateOnlyArriveByIsShownWithoutTimeZoneShift() {
        let midnight = ISO8601DateFormatter().date(from: "2026-10-25T00:00:00Z")!
        XCTAssertTrue(orderArriveByIsDateOnly(midnight))
        XCTAssertFalse(orderArriveByIsDateOnly(midnight.addingTimeInterval(3600)))
        var style = Date.FormatStyle(date: .abbreviated, time: .omitted)
        style.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(orderArriveByLabel(midnight), midnight.formatted(style))
        XCTAssertEqual(orderArriveByDeadline(midnight), midnight.addingTimeInterval(day), "late only after that whole day")
        let timed = midnight.addingTimeInterval(15 * 3600)
        XCTAssertEqual(orderArriveByDeadline(timed), timed)
    }

    // MARK: Needs attention

    func testPaymentProblemAlwaysNeedsAttention() {
        XCTAssertEqual(orderAttention(order("P", status: "PAYMENT_ERROR", created: iso(now)).values, now: now), .paymentProblem)
    }

    func testPastArriveByAndNotDelivered() {
        let due = ISO8601DateFormatter().date(from: "2026-10-22T00:00:00Z")!
        let values = order("L", status: "SHIPPED", extra: ["arriveByDate": "2026-10-22T00:00:00Z"]).values
        XCTAssertEqual(orderAttention(values, now: now), .pastArriveBy(due))
        // Still within the arrive-by day.
        let sameDay = ISO8601DateFormatter().date(from: "2026-10-22T20:00:00Z")!
        XCTAssertNil(orderAttention(values, now: sameDay))
        for status in ["DELIVERED", "CANCELED"] {
            XCTAssertNil(orderAttention(order("L", status: status, extra: ["arriveByDate": "2026-10-01T00:00:00Z"]).values, now: now))
        }
    }

    func testNotShippedAfterProductionDays() {
        let threshold = Double(orderAttentionProductionDays) * day
        let placed = now.addingTimeInterval(-threshold - 3600)
        let values = order("S", status: "PRINTING", created: iso(now.addingTimeInterval(-20 * day)),
                           extra: ["processedAt": iso(placed)]).values
        XCTAssertEqual(orderAttention(values, now: now), .notShipped(days: orderAttentionProductionDays, sincePlaced: true))
        // Counted from when it was placed, not from when the draft was made.
        let recentlyPlaced = order("S", status: "QUEUED", created: iso(now.addingTimeInterval(-20 * day)),
                                   extra: ["processedAt": iso(now.addingTimeInterval(-day))]).values
        XCTAssertNil(orderAttention(recentlyPlaced, now: now))
        // Without processedAt, from creation, and the text says so.
        let noProcessed = order("S", status: "AWAITING_SHIPMENT", created: iso(now.addingTimeInterval(-8 * day))).values
        XCTAssertEqual(orderAttention(noProcessed, now: now), .notShipped(days: 8, sincePlaced: false))
        XCTAssertEqual(OrderAttention.notShipped(days: 8, sincePlaced: false).detail, "Not shipped 8 days after it was created.")
        XCTAssertNil(orderAttention(order("S", status: "SHIPPED", created: iso(now.addingTimeInterval(-30 * day))).values, now: now))
    }

    func testDraftNotPlacedWindow() {
        func draft(ageDays: Double) -> OrderAttention? {
            orderAttention(order("D", status: "DRAFT", created: iso(now.addingTimeInterval(-ageDays * day))).values, now: now)
        }
        XCTAssertNil(draft(ageDays: 1))
        XCTAssertNil(draft(ageDays: Double(orderAttentionDraftDays)))
        XCTAssertEqual(draft(ageDays: 3), .draftNotPlaced(days: 3))
        XCTAssertNotNil(draft(ageDays: Double(orderAttentionDraftIgnoredAfterDays)))
        XCTAssertNil(draft(ageDays: Double(orderAttentionDraftIgnoredAfterDays) + 1), "old drafts can't be removed, so they aren't flagged")
        XCTAssertEqual(OrderAttention.draftNotPlaced(days: 1).detail, "A draft for 1 day and not placed yet.")
    }

    func testOddInputsNeverNeedAttention() {
        XCTAssertNil(orderAttention([:], now: now))
        XCTAssertNil(orderAttention(order("X", status: "SOMETHING_NEW", created: iso(now.addingTimeInterval(-90 * day))).values, now: now))
        // A creation date in the future (clock skew) isn't an age.
        XCTAssertNil(orderAttention(order("X", status: "DRAFT", created: iso(now.addingTimeInterval(10 * day))).values, now: now))
        XCTAssertNil(orderAttention(order("X", status: "PAID", created: nil).values, now: now))
        XCTAssertNil(orderAttention(order("X", status: "PAID", created: "not a date").values, now: now))
    }

    func testPaymentProblemOutranksLateness() {
        let values = order("X", status: "PAYMENT_ERROR", extra: ["arriveByDate": "2026-10-01T00:00:00Z"]).values
        XCTAssertEqual(orderAttention(values, now: now), .paymentProblem)
        let lateAndStuck = order("Y", status: "PRINTING", created: iso(now.addingTimeInterval(-10 * day)),
                                 extra: ["arriveByDate": "2026-10-01T00:00:00Z"]).values
        XCTAssertEqual(orderAttention(lateAndStuck, now: now)?.title, "Late")
    }

    func testAttentionFilterAndTableMarker() {
        let records = [
            order("ok", status: "SHIPPED"),
            order("late", status: "PAYMENT_ERROR"),
            order("draft", status: "DRAFT", created: iso(now.addingTimeInterval(-3 * day)))
        ]
        XCTAssertEqual(orderAttentionFiltered(records, enabled: false, now: now).map(\.id), ["ok", "late", "draft"])
        XCTAssertEqual(orderAttentionFiltered(records, enabled: true, now: now).map(\.id), ["late", "draft"])
        XCTAssertNil(OrderTableRow(record: records[0], now: now).attention)
        XCTAssertEqual(OrderTableRow(record: records[2], now: now).attention, .draftNotPlaced(days: 3))
    }

    func testAttentionCopy() {
        XCTAssertTrue(orderAttentionFilterHint(moreOnServer: true).hasSuffix("Load more to check older orders."))
        XCTAssertFalse(orderAttentionFilterHint(moreOnServer: false).contains("Load more"))
        XCTAssertEqual(orderAttentionEmptyDetail(filterActive: false), "None of the loaded orders need attention.")
        XCTAssertEqual(orderAttentionEmptyDetail(filterActive: true, search: " bracket "),
                       "None of the loaded orders with the chosen status or dates matching “bracket” need attention.")
    }
}
