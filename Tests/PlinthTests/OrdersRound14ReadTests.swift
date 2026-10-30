import XCTest
@testable import SlantStudio

/// Round 14: reading orders after Slant's status change of 26 Oct 2026 (DRAFT, SUBMITTED, PRINTING, SHIPPED,
/// CANCELLED), live pagination, the publicId lookup, the date filter's margin and the order watch's re-label rule.
final class OrdersRound14ReadTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
    private let utc = TimeZone(identifier: "UTC")!
    private let sydney = TimeZone(identifier: "Australia/Sydney")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private func obs(_ id: String, _ status: String) -> OrderWatchObservation {
        OrderWatchObservation(id: id, status: status, number: id)
    }
    private func order(_ id: String, created: String? = nil, extra: [String: Any] = [:]) -> Record {
        var values: [String: Any] = ["publicId": id, "status": "PRINTING"]
        if let created { values["createdAt"] = created }
        for (key, value) in extra { values[key] = value }
        return Record(values: values)
    }
    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, in zone: TimeZone) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: Pagination

    func testHasMoreUsesTotalPagesThenCountThenPageSize() {
        // Live shape: count is the total across pages.
        XCTAssertFalse(listHasMorePages(pagination: ["count": 6, "totalPages": 1, "page": 1, "limit": 100], recordCount: 6, currentPage: 1, pageSize: 100))
        XCTAssertTrue(listHasMorePages(pagination: ["count": 250, "totalPages": 3], recordCount: 100, currentPage: 2, pageSize: 100))
        XCTAssertFalse(listHasMorePages(pagination: ["count": 250, "totalPages": 3], recordCount: 50, currentPage: 3, pageSize: 100))
        // Count alone: more than the rows read means more remain.
        XCTAssertTrue(listHasMorePages(pagination: ["count": 101], recordCount: 100, currentPage: 1, pageSize: 100))
        XCTAssertFalse(listHasMorePages(pagination: ["count": 160], recordCount: 60, currentPage: 2, pageSize: 100))
        XCTAssertTrue(listHasMorePages(pagination: ["count": "250"], recordCount: 100, currentPage: 2, pageSize: 100))
        // Slant's own limit wins over the one asked for (a capped page).
        XCTAssertTrue(listHasMorePages(pagination: ["count": 150, "limit": 50], recordCount: 50, currentPage: 2, pageSize: 100))
        // A count equal to a full page could be a per-page count, so the page-size rule decides.
        XCTAssertTrue(listHasMorePages(pagination: ["count": 100], recordCount: 100, currentPage: 1, pageSize: 100))
        // A count below the rows read can't be a total: ignored.
        XCTAssertTrue(listHasMorePages(pagination: ["count": 100], recordCount: 100, currentPage: 2, pageSize: 100))
        // Booleans, fractions and junk are never figures.
        XCTAssertTrue(listHasMorePages(pagination: ["totalPages": true], recordCount: 100, currentPage: 1, pageSize: 100))
        XCTAssertFalse(listHasMorePages(pagination: ["totalPages": 1.5, "count": NSNull()], recordCount: 40, currentPage: 1, pageSize: 100))
        XCTAssertTrue(listHasMorePages(pagination: ["totalPages": "x"], recordCount: 100, currentPage: 1, pageSize: 100))
    }

    func testEmptyPageAlwaysEndsTheList() {
        XCTAssertFalse(listHasMorePages(pagination: ["totalPages": 9, "count": 900], recordCount: 0, currentPage: 2, pageSize: 100))
        XCTAssertFalse(listHasMorePages(pagination: nil, recordCount: 0, currentPage: 1, pageSize: 0))
    }

    func testPaginationIntegerAndTotalCount() {
        XCTAssertEqual(paginationInteger(6), 6)
        XCTAssertEqual(paginationInteger(NSNumber(value: 7.0)), 7)
        XCTAssertEqual(paginationInteger(" 12 "), 12)
        XCTAssertNil(paginationInteger(-1))
        XCTAssertNil(paginationInteger(NSNumber(value: true)))
        XCTAssertNil(paginationInteger(2.5))
        XCTAssertNil(paginationInteger(Double.infinity))
        XCTAssertNil(paginationInteger(NSNull()))
        XCTAssertNil(paginationInteger(nil))
        XCTAssertEqual(listPaginationTotalCount(["count": 2, "totalPages": 1, "page": 1, "limit": 5]), 2)
        XCTAssertNil(listPaginationTotalCount(nil))
        XCTAssertNil(listPaginationTotalCount(["total": 3]))
    }

    func testListChangedWhilePagingOnlyWhenBothCountsKnownAndDiffer() {
        XCTAssertTrue(orderListChangedWhilePaging(firstCount: 120, latestCount: 119))
        XCTAssertTrue(orderListChangedWhilePaging(firstCount: 120, latestCount: 121))
        XCTAssertFalse(orderListChangedWhilePaging(firstCount: 120, latestCount: 120))
        XCTAssertFalse(orderListChangedWhilePaging(firstCount: nil, latestCount: 3))
        XCTAssertFalse(orderListChangedWhilePaging(firstCount: 3, latestCount: nil))
        XCTAssertTrue(orderListChangedWhileLoadingNote.contains("Reload"))
    }

    // MARK: Not found and search

    func testOrderNotFoundError() {
        let lookup = #"{"success":false,"error":{"message":"Order not found.","statusCode":400}}"#
        XCTAssertTrue(orderNotFoundError(APIError.http(status: 404, body: "", retryAfter: nil, rateLimitReset: nil)))
        XCTAssertTrue(orderNotFoundError(APIError.http(status: 400, body: lookup, retryAfter: nil, rateLimitReset: nil)))
        XCTAssertFalse(orderNotFoundError(APIError.http(status: 400, body: #"{"error":{"message":"Invalid status filter"}}"#, retryAfter: nil, rateLimitReset: nil)))
        XCTAssertFalse(orderNotFoundError(APIError.http(status: 500, body: lookup, retryAfter: nil, rateLimitReset: nil)))
        XCTAssertFalse(orderNotFoundError(APIError.http(status: 429, body: "", retryAfter: nil, rateLimitReset: nil)))
        XCTAssertFalse(orderNotFoundError(URLError(.timedOut)))
        XCTAssertFalse(orderNotFoundError(APIError.invalidResponse("Order not found")))
    }

    func testSearchAsksForThePublicIdDirectly() {
        let query = orderSearchQueryItems(" 1000000000003 ", platformID: " plat-1 ")
        XCTAssertEqual(query["publicId"], "SLANT_1000000000003")
        XCTAssertEqual(query["platformId"], "plat-1")
        XCTAssertEqual(query["page"], "1")
        XCTAssertEqual(query["limit"], String(listPageSize))
        XCTAssertNil(query["query"])
        XCTAssertNil(orderSearchQueryItems("SLANT_1", platformID: "  ")["platformId"])
    }

    func testSearchKeepsOnlyTheOrderLookedUp() {
        let newest = (1...5).map { order("SLANT_\($0)") }
        // Slant ignored publicId and returned the newest orders: none is the one asked for.
        XCTAssertTrue(orderSearchMatchingRecords(newest, typed: "SLANT_99").isEmpty)
        XCTAssertEqual(orderSearchMatchingRecords(newest, typed: "slant_3").map(\.id), ["SLANT_3"])
        XCTAssertEqual(orderSearchMatchingRecords(newest, typed: " 4 ").map(\.id), ["SLANT_4"])
        let lower = Record(values: ["order": ["publicId": " slant_7 "]])
        XCTAssertEqual(orderSearchMatchingRecords([lower], typed: "SLANT_7").count, 1)
        XCTAssertTrue(orderSearchMatchingRecords([Record(values: ["id": "SLANT_8"])], typed: "SLANT_8").isEmpty)
        XCTAssertTrue(orderSearchMatchingRecords(newest, typed: "   ").isEmpty)
    }

    // MARK: Date filter margin

    func testDateQueryAsksForADayEitherSide() {
        var filter = OrderFilter()
        filter.startDate = localDate(2026, 10, 1, 9, in: sydney)
        filter.endDate = localDate(2026, 10, 31, 23, in: sydney)
        XCTAssertEqual(orderFilterStartDateQueryValue(filter.startDate!, timeZone: sydney), "2026-09-30")
        // To is 31 Oct: the exclusive endDate is 1 Nov, plus a day's margin.
        XCTAssertEqual(orderFilterEndDateQueryValue(filter.endDate!, timeZone: sydney), "2026-11-02")
        // Year boundary.
        XCTAssertEqual(orderFilterStartDateQueryValue(localDate(2026, 1, 1, 0, in: utc), timeZone: utc), "2025-12-31")
        XCTAssertEqual(orderFilterEndDateQueryValue(localDate(2026, 12, 31, 23, in: utc), timeZone: utc), "2027-01-02")
        let query = orderFilterQueryItems(OrderFilter(), page: 1, limit: 100, platformID: "")
        XCTAssertNil(query["startDate"])
        XCTAssertNil(query["endDate"])
    }

    func testTrimKeepsOnlyTheChosenLocalDays() {
        var filter = OrderFilter()
        filter.startDate = localDate(2026, 10, 1, 15, in: sydney)
        filter.endDate = localDate(2026, 10, 31, 8, in: sydney)
        let rows = [
            order("BEFORE", created: "2026-09-30T13:59:59Z"),   // 30 Sep 23:59:59 in Sydney (UTC+10)
            order("FIRST", created: "2026-09-30T14:00:00Z"),    // 1 Oct 00:00 in Sydney
            order("LAST", created: "2026-10-31T12:59:59Z"),     // 31 Oct 23:59:59 in Sydney (UTC+11 after DST)
            order("AFTER", created: "2026-10-31T13:00:00Z"),    // 1 Nov 00:00 in Sydney
            order("UNDATED")
        ]
        XCTAssertEqual(orderFilterTrimmed(rows, filter: filter, timeZone: sydney).map(\.id), ["FIRST", "LAST", "UNDATED"])
        // West of Greenwich the same instants fall on other days: 31 Oct 13:00Z is still 31 Oct in Los Angeles.
        var west = OrderFilter()
        west.startDate = localDate(2026, 10, 31, 12, in: losAngeles)
        west.endDate = west.startDate
        XCTAssertEqual(orderFilterTrimmed(rows, filter: west, timeZone: losAngeles).map(\.id), ["LAST", "AFTER", "UNDATED"])
        XCTAssertEqual(orderFilterTrimmed(rows, filter: OrderFilter(status: "PRINTING"), timeZone: sydney).count, rows.count)
        // Only an end date.
        var endOnly = OrderFilter()
        endOnly.endDate = localDate(2026, 9, 30, 12, in: utc)
        XCTAssertEqual(orderFilterTrimmed(rows, filter: endOnly, timeZone: utc).map(\.id), ["BEFORE", "FIRST", "UNDATED"])
    }

    // MARK: Order watch re-label

    func testRelabelRule() {
        for legacy in ["PAID", "QUEUED", "PROCESSING", "ITEMS_ON_SHELF", "POST_PROCESSING", "COMPLETED", "IN_REVIEW", "AWAITING_SHIPMENT"] {
            XCTAssertTrue(orderWatchChangeIsSlantRelabel(from: legacy, to: "SUBMITTED"), legacy)
            XCTAssertTrue(orderWatchChangeIsSlantRelabel(from: legacy, to: "PRINTING"), legacy)
            XCTAssertFalse(orderWatchChangeIsReported(from: legacy, to: "PRINTING"), legacy)
            XCTAssertTrue(orderWatchChangeIsReported(from: legacy, to: "SHIPPED"), legacy)
            XCTAssertTrue(orderWatchChangeIsReported(from: legacy, to: "CANCELLED"), legacy)
        }
        XCTAssertTrue(orderWatchChangeIsSlantRelabel(from: "CANCELED", to: "CANCELLED"))
        XCTAssertTrue(orderWatchChangeIsSlantRelabel(from: "DELIVERED", to: "SHIPPED"))
        XCTAssertFalse(orderWatchChangeIsSlantRelabel(from: "PAYMENT_ERROR", to: "PRINTING"))
        XCTAssertFalse(orderWatchChangeIsSlantRelabel(from: "CANCELED", to: "PRINTING"))
        XCTAssertFalse(orderWatchChangeIsSlantRelabel(from: "DELIVERED", to: "PRINTING"))
        // Live statuses are never re-labels.
        XCTAssertFalse(orderWatchChangeIsSlantRelabel(from: "SUBMITTED", to: "PRINTING"))
        XCTAssertFalse(orderWatchChangeIsSlantRelabel(from: "DRAFT", to: "PRINTING"))
        XCTAssertTrue(orderWatchChangeIsReported(from: "SUBMITTED", to: "PRINTING"))
        XCTAssertFalse(orderWatchChangeIsReported(from: "DRAFT", to: "SUBMITTED"))
    }

    func testLegacySnapshotMovesSilentlyToLiveStatuses() {
        let saved = orderWatchApplying([obs("A", "QUEUED"), obs("B", "PAID"), obs("C", "CANCELED"), obs("D", "DELIVERED"),
                                        obs("E", "QUEUED"), obs("F", "AWAITING_SHIPMENT"), obs("G", "PAYMENT_ERROR")],
                                       to: OrderWatchSnapshot(), now: t0).snapshot
        let later = t0.addingTimeInterval(240)
        let applied = orderWatchApplying([obs("A", "PRINTING"), obs("B", "SUBMITTED"), obs("C", "CANCELLED"), obs("D", "SHIPPED"),
                                          obs("E", "SHIPPED"), obs("F", "CANCELLED"), obs("G", "PRINTING")],
                                         to: saved, now: later)
        // Re-labels are recorded but neither listed, badged nor notified.
        for id in ["A", "B", "C", "D"] {
            XCTAssertFalse(applied.snapshot.orders[id]!.hasUnseenChange, id)
            XCTAssertNil(applied.snapshot.orders[id]!.changedAt, id)
        }
        XCTAssertEqual(applied.snapshot.orders["A"]?.status, "PRINTING")
        XCTAssertEqual(applied.snapshot.orders["C"]?.seenStatus, "CANCELLED")
        let changes = orderWatchUnseenChanges(applied.snapshot)
        XCTAssertEqual(Set(changes.map(\.id)), ["E", "F", "G"])
        XCTAssertEqual(orderWatchBadgeCount(changes), 2)
        let notified = orderWatchNotificationTexts(applied.transitions)
        XCTAssertEqual(Set(notified.compactMap(\.orderID)), ["E", "F"])
        XCTAssertTrue(notified.contains { $0.title == "Order F was cancelled" })
    }

    func testRelabelOfAnUnseenChangeKeepsItsTime() {
        var snapshot = orderWatchApplying([obs("A", "DRAFT")], to: OrderWatchSnapshot(), now: t0).snapshot
        let t1 = t0.addingTimeInterval(240)
        snapshot = orderWatchApplying([obs("A", "QUEUED")], to: snapshot, now: t1).snapshot
        XCTAssertEqual(orderWatchUnseenChanges(snapshot).map(\.to), ["QUEUED"])
        let applied = orderWatchApplying([obs("A", "PRINTING")], to: snapshot, now: t1.addingTimeInterval(240))
        XCTAssertEqual(applied.snapshot.orders["A"]?.changedAt, t1)
        XCTAssertEqual(orderWatchUnseenChanges(applied.snapshot).map(\.to), ["PRINTING"])
        XCTAssertTrue(orderWatchNotificationTexts(applied.transitions).isEmpty)
    }

    func testCancelledIsNotableAndGroupedOnce() {
        XCTAssertTrue(orderWatchNotableStatuses.contains("CANCELLED"))
        XCTAssertTrue(orderWatchBadgeStatuses.contains("CANCELLED"))
        XCTAssertTrue(orderWatchShouldNotify(OrderWatchTransition(id: "A", number: "A", from: "PRINTING", to: "CANCELLED")))
        XCTAssertFalse(orderWatchShouldNotify(OrderWatchTransition(id: "A", number: "A", from: "SUBMITTED", to: "PRINTING")))
        let changes = [OrderWatchChange(id: "A", from: "QUEUED", to: "CANCELED"), OrderWatchChange(id: "B", from: "PRINTING", to: "CANCELLED"),
                       OrderWatchChange(id: "C", from: "PRINTING", to: "SHIPPED")]
        let groups = orderWatchSummaryGroups(changes)
        XCTAssertEqual(groups.map(\.status), ["CANCELLED", "SHIPPED"])
        XCTAssertEqual(groups.first?.count, 2)
        XCTAssertEqual(orderWatchSummaryText(changes), "2 cancelled · 1 shipped")
    }

    // MARK: Needs attention, tracking, problems, spending

    private func attention(_ status: String, created: Date, arriveBy: String? = nil, processed: Date? = nil, now: Date) -> OrderAttention? {
        var values: [String: Any] = ["publicId": "X", "status": status, "createdAt": ISO8601DateFormatter().string(from: created)]
        if let arriveBy { values["arriveByDate"] = arriveBy }
        if let processed { values["processedAt"] = ISO8601DateFormatter().string(from: processed) }
        return orderAttention(values, now: now, timeZone: utc)
    }

    func testLateOnlyForKnownProductionStatusesOrRecentDrafts() {
        let now = t0
        let created = now.addingTimeInterval(-86_400)
        let due = "2020-01-01T00:00:00Z"
        for status in ["SUBMITTED", "PRINTING", "QUEUED", "submitted"] {
            if case .pastArriveBy? = attention(status, created: created, arriveBy: due, now: now) {} else { XCTFail(status) }
        }
        if case .pastArriveBy? = attention("DRAFT", created: created, arriveBy: due, now: now) {} else { XCTFail("draft") }
        for status in ["SHIPPED", "CANCELLED", "CANCELED", "RETURNED", "ON_HOLD"] {
            XCTAssertNil(attention(status, created: created, arriveBy: due, now: now), status)
        }
        // A draft past the 30-day window isn't late either.
        XCTAssertNil(attention("DRAFT", created: now.addingTimeInterval(-40 * 86_400), arriveBy: due, now: now))
    }

    func testLiveStatusesInAttentionTrackingProblemsAndSpending() {
        let old = t0.addingTimeInterval(-10 * 86_400)
        XCTAssertEqual(attention("SUBMITTED", created: old, processed: old, now: t0), .notShipped(days: 10, sincePlaced: true))
        XCTAssertEqual(attention("PRINTING", created: old, now: t0), .notShipped(days: 10, sincePlaced: false))
        XCTAssertNil(attention("SHIPPED", created: old, now: t0))
        XCTAssertNil(attention(" cancelled ", created: old, now: t0))

        XCTAssertTrue(orderDetailShowsTracking(status: "SUBMITTED", hasTrackingDetails: false))
        XCTAssertTrue(orderDetailShowsTracking(status: "PRINTING", hasTrackingDetails: false))
        XCTAssertTrue(orderDetailShowsTracking(status: "SHIPPED", hasTrackingDetails: false))
        XCTAssertFalse(orderDetailShowsTracking(status: "CANCELLED", hasTrackingDetails: false))
        XCTAssertFalse(orderDetailShowsTracking(status: "DRAFT", hasTrackingDetails: false))

        XCTAssertEqual(orderProblemKinds(status: "PRINTING"), [.late, .other])
        XCTAssertEqual(orderProblemKinds(status: "SUBMITTED"), [.late, .other])
        XCTAssertEqual(orderProblemKinds(status: "SHIPPED"), [.damaged, .wrongItem, .missingItem, .printDefect, .late, .other])
        XCTAssertEqual(orderProblemKinds(status: "CANCELLED"), [.other])

        for status in ["SUBMITTED", "PRINTING", "SHIPPED"] { XCTAssertTrue(spendReportCountedStatuses.contains(status), status) }
        let report = spendReport(orders: [Record(values: ["publicId": "A", "status": "CANCELLED", "createdAt": "2026-10-01T00:00:00Z"]),
                                          Record(values: ["publicId": "B", "status": "PRINTING", "createdAt": "2026-10-01T00:00:00Z", "total": 5])])
        XCTAssertEqual(report.excludedCancelled, 1)
        XCTAssertEqual(report.countedOrders, 1)

        XCTAssertNil(orderItemProgress(["status": "PRINTING"], orderStatus: "PRINTING"))
        XCTAssertNil(orderItemProgress(["estimatedPrintCompletion": "2026-11-01"], orderStatus: "CANCELLED"))
        XCTAssertNotNil(orderItemProgress(["estimatedPrintCompletion": "2026-11-01"], orderStatus: "SUBMITTED"))

        if case .unavailable = profitCheckSlantTotal(["status": "cancelled ", "total": 5]) {} else { XCTFail("cancelled total") }
    }

    // MARK: Detail facts

    func testDetailFactsShowPlacedAndUpdated() {
        let facts = orderDetailFacts([
            "createdAt": "2026-10-20T09:00:00.000Z", "processedAt": "2026-10-20T10:00:00.000Z",
            "updatedAt": "2026-10-27T15:30:00.000Z"
        ])
        XCTAssertEqual(facts.map(\.0), ["Placed", "Updated"])
        XCTAssertFalse(facts[1].1.isEmpty)
        // Unchanged since it was made: no Updated line.
        XCTAssertNil(orderDetailUpdatedLabel(["createdAt": "2026-10-20T09:00:00.000Z", "updatedAt": "2026-10-20T09:00:00.400Z"]))
        XCTAssertNotNil(orderDetailUpdatedLabel(["updatedAt": "2026-10-20T09:00:00Z"]))
        XCTAssertNil(orderDetailUpdatedLabel(["updatedAt": "soon"]))
        XCTAssertNil(orderDetailUpdatedLabel(["updatedAt": NSNull()]))
        XCTAssertTrue(orderDetailFacts(["processedAt": NSNull(), "updatedAt": NSNull()]).isEmpty)
    }
}
