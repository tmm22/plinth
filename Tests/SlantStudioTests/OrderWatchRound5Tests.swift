import XCTest
@testable import SlantStudio

final class OrderWatchRound5Tests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func obs(_ id: String, _ status: String) -> OrderWatchObservation {
        OrderWatchObservation(id: id, status: status, number: id)
    }
    private func order(_ id: String, updatedAt: Any?, wrapped: Bool = false) -> Record {
        var values: [String: Any] = ["publicId": id, "status": "PRINTING"]
        if let updatedAt { values["updatedAt"] = updatedAt }
        return Record(values: wrapped ? ["order": values, "publicId": id] : values)
    }

    // MARK: Updated-first read

    func testRecentlyUpdatedQuerySortsByUpdatedAtNewestFirst() {
        let query = orderWatchRecentlyUpdatedQuery(platformID: "plat-1")
        XCTAssertEqual(query["sortBy"], "updatedAt")
        XCTAssertEqual(query["sortOrder"], "DESC")
        XCTAssertEqual(query["page"], "1")
        XCTAssertEqual(query["limit"], String(listPageSize))
        XCTAssertEqual(query["platformId"], "plat-1")
        XCTAssertNil(query["status"])
        XCTAssertNil(query["startDate"])
        XCTAssertNil(query["endDate"])
    }

    func testSortCheckRecognisesNewestUpdatedFirst() {
        let rows = [order("A", updatedAt: "2026-10-24T10:00:00.000Z"), order("B", updatedAt: "2026-10-24T09:00:00.000Z"),
                    order("C", updatedAt: "2026-10-24T09:00:00.000Z"), order("D", updatedAt: "2026-10-01T09:00:00Z", wrapped: true)]
        XCTAssertEqual(orderWatchUpdatedSortCheck(rows), .sorted)
    }

    func testSortCheckSpotsAnIgnoredSort() {
        let rows = [order("A", updatedAt: "2026-10-20T10:00:00.000Z"), order("B", updatedAt: "2026-10-24T09:00:00.000Z")]
        XCTAssertEqual(orderWatchUpdatedSortCheck(rows), .notSorted)
    }

    func testSortCheckAllowsASecondOfRoundingAndSkipsUnreadableRows() {
        let rows = [order("A", updatedAt: "2026-10-24T10:00:00.000Z"), order("B", updatedAt: nil), order("C", updatedAt: 12),
                    order("D", updatedAt: "not a date"), order("E", updatedAt: "2026-10-24T10:00:00.900Z")]
        XCTAssertEqual(orderWatchUpdatedSortCheck(rows), .sorted)
    }

    func testSortCheckIsInconclusiveWithoutTwoDates() {
        XCTAssertEqual(orderWatchUpdatedSortCheck([]), .inconclusive)
        XCTAssertEqual(orderWatchUpdatedSortCheck([order("A", updatedAt: "2026-10-24T10:00:00Z"), order("B", updatedAt: nil)]), .inconclusive)
    }

    func testOnlyA400Or422StopsTheUpdatedRead() {
        XCTAssertTrue(orderWatchUpdatedReadRefused(APIError.http(status: 400, body: "bad sortBy", retryAfter: nil, rateLimitReset: nil)))
        XCTAssertTrue(orderWatchUpdatedReadRefused(APIError.http(status: 422, body: "", retryAfter: nil, rateLimitReset: nil)))
        XCTAssertFalse(orderWatchUpdatedReadRefused(APIError.http(status: 429, body: "", retryAfter: "5", rateLimitReset: nil)))
        XCTAssertFalse(orderWatchUpdatedReadRefused(APIError.http(status: 401, body: "", retryAfter: nil, rateLimitReset: nil)))
        XCTAssertFalse(orderWatchUpdatedReadRefused(APIError.http(status: 500, body: "", retryAfter: nil, rateLimitReset: nil)))
        XCTAssertFalse(orderWatchUpdatedReadRefused(URLError(.timedOut)))
    }

    // MARK: Merging both reads

    func testMergeDedupesByIDAndLaterReadWins() {
        let merged = orderWatchMergedObservations([obs("A", "PRINTING"), obs("B", "QUEUED"), obs("A", "PAID")],
                                                  [obs("C", "SHIPPED"), obs("A", "SHIPPED")])
        XCTAssertEqual(merged, [obs("A", "SHIPPED"), obs("B", "QUEUED"), obs("C", "SHIPPED")])
        XCTAssertEqual(orderWatchMergedObservations([], []), [])
        XCTAssertEqual(orderWatchMergedObservations([obs("A", "PAID")], []), [obs("A", "PAID")])
    }

    func testOlderOrderSeenFirstByUpdatedReadIsSilentThenReported() {
        // A is among the newest; OLD is only in the updated-first read.
        let first = orderWatchApplying(orderWatchMergedObservations([obs("A", "PAID")], [obs("OLD", "PRINTING")]),
                                       to: OrderWatchSnapshot(), now: t0)
        XCTAssertTrue(first.transitions.isEmpty)
        XCTAssertEqual(first.snapshot.orders["OLD"]?.status, "PRINTING")
        // Next check: OLD is only in the updated-first read again, now shipped; reported once.
        let later = t0.addingTimeInterval(orderWatchInterval)
        let second = orderWatchApplying(orderWatchMergedObservations([obs("A", "PAID")], [obs("OLD", "SHIPPED"), obs("A", "PAID")]),
                                        to: first.snapshot, now: later)
        XCTAssertEqual(second.transitions, [OrderWatchTransition(id: "OLD", number: "OLD", from: "PRINTING", to: "SHIPPED")])
        XCTAssertEqual(orderWatchBadgeCount(orderWatchUnseenChanges(second.snapshot)), 1)
    }

    func testDraftToPaidStaysUnreportedThroughTheUpdatedRead() {
        let first = orderWatchApplying([obs("D", "DRAFT")], to: OrderWatchSnapshot(), now: t0).snapshot
        let second = orderWatchApplying(orderWatchMergedObservations([obs("D", "DRAFT")], [obs("D", "PAID")]), to: first, now: t0 + 240)
        XCTAssertTrue(orderWatchUnseenChanges(second.snapshot).isEmpty)
        XCTAssertTrue(orderWatchNotificationTexts(second.transitions).isEmpty)
    }

    // MARK: Show's reads by ID

    func testIDsToFetchKeepOrderSkipLoadedDuplicatesAndOddIDs() {
        let wanted = ["C", "A", "C", "", " B", "B\n", String(repeating: "x", count: 200), "D", "E"]
        XCTAssertEqual(orderWatchIDsToFetch(wanted: wanted, loaded: ["A"]), ["C", "D", "E"])
        XCTAssertEqual(orderWatchIDsToFetch(wanted: ["A", "B", "C"], loaded: [], limit: 2), ["A", "B"])
        XCTAssertEqual(orderWatchIDsToFetch(wanted: ["A"], loaded: ["A"]), [])
        let many = (1...30).map { "S\($0)" }
        XCTAssertEqual(orderWatchIDsToFetch(wanted: many, loaded: []).count, orderWatchShowFetchLimit)
    }

    func testOrdersReadByIDJoinOnlyTheirOwnPlatformsList() {
        XCTAssertTrue(orderWatchFetchedOrderFitsPlatform(["platformId": "P1"], platformID: "P1"))
        XCTAssertTrue(orderWatchFetchedOrderFitsPlatform(["customer": ["platformId": "P1"]], platformID: " P1 "))
        XCTAssertFalse(orderWatchFetchedOrderFitsPlatform(["platformId": "P2"], platformID: "P1"))
        XCTAssertFalse(orderWatchFetchedOrderFitsPlatform(["platformId": "P2", "customer": ["platformId": "P3"]], platformID: "P1"))
        // The only shape live Slant sends (every order seen, 29 Oct 2026): the platform in `customer.platformId`
        // alone. This check is what scopes Show and notification-click reads, since Slant doesn't filter them.
        XCTAssertFalse(orderWatchFetchedOrderFitsPlatform(["customer": ["platformId": "P2"]], platformID: "P1"))
        XCTAssertFalse(orderWatchFetchedOrderFitsPlatform(["customer": ["platformId": "P2", "details": ["email": "a@example.com"]]],
                                                          platformID: "P1"))
        XCTAssertTrue(orderWatchFetchedOrderFitsPlatform(["publicId": "X"], platformID: "P1"))
        XCTAssertTrue(orderWatchFetchedOrderFitsPlatform(["platformId": NSNull(), "customer": "odd"], platformID: "P1"))
        XCTAssertTrue(orderWatchFetchedOrderFitsPlatform(["platformId": "P2"], platformID: ""))
    }

    // MARK: Notifications open the order

    func testSingleNotificationsCarryOnlyTheOrderIDAndSummaryNone() {
        let one = orderWatchNotificationTexts([OrderWatchTransition(id: "SLANT_9", number: "1009", from: "AWAITING_SHIPMENT", to: "SHIPPED")])
        XCTAssertEqual(one.map(\.orderID), ["SLANT_9"])
        let many = orderWatchNotificationTexts((1...5).map { OrderWatchTransition(id: "S\($0)", number: "S\($0)", from: "SHIPPED", to: "DELIVERED") })
        XCTAssertEqual(many.count, 1)
        XCTAssertNil(many.first?.orderID)
    }

    func testNotificationOrderIDIsReadStrictly() {
        XCTAssertEqual(orderWatchNotificationOrderID([orderWatchNotificationOrderIDKey: "SLANT_1"]), "SLANT_1")
        XCTAssertNil(orderWatchNotificationOrderID([:]))
        XCTAssertNil(orderWatchNotificationOrderID([orderWatchNotificationOrderIDKey: 42]))
        XCTAssertNil(orderWatchNotificationOrderID([orderWatchNotificationOrderIDKey: ""]))
        XCTAssertNil(orderWatchNotificationOrderID([orderWatchNotificationOrderIDKey: " SLANT_1"]))
        XCTAssertNil(orderWatchNotificationOrderID([orderWatchNotificationOrderIDKey: "SLANT\n1"]))
        XCTAssertNil(orderWatchNotificationOrderID([orderWatchNotificationOrderIDKey: String(repeating: "x", count: 129)]))
    }

    func testSelectionRequestsAreDistinctPerClick() {
        XCTAssertNotEqual(OrderWatchSelectionRequest(orderID: "A"), OrderWatchSelectionRequest(orderID: "A"))
    }

    // MARK: Dock badge

    func testDockBadgeFollowsTheSidebarCount() {
        XCTAssertNil(orderWatchDockBadgeLabel(count: 0, showOnDock: true))
        XCTAssertNil(orderWatchDockBadgeLabel(count: 3, showOnDock: false))
        XCTAssertEqual(orderWatchDockBadgeLabel(count: 3, showOnDock: true), "3")
        let changes = [OrderWatchChange(id: "A", from: "PRINTING", to: "SHIPPED"),
                       OrderWatchChange(id: "B", from: "SHIPPED", to: "DELIVERED"),
                       OrderWatchChange(id: "C", from: "PAID", to: "PAYMENT_ERROR")]
        XCTAssertEqual(orderWatchDockBadgeLabel(count: orderWatchBadgeCount(changes), showOnDock: true), "2")
    }

    // MARK: Last sidebar section

    func testRestoredSidebarDestination() {
        XCTAssertEqual(restoredSidebarDestination(saved: nil, showDeveloperTools: false), .models)
        XCTAssertEqual(restoredSidebarDestination(saved: "Orders", showDeveloperTools: false), .orders)
        XCTAssertEqual(restoredSidebarDestination(saved: "Catalog", showDeveloperTools: false), .catalog)
        XCTAssertEqual(restoredSidebarDestination(saved: "Models", showDeveloperTools: true), .models)
        XCTAssertEqual(restoredSidebarDestination(saved: "API Workbench", showDeveloperTools: true), .api)
        XCTAssertEqual(restoredSidebarDestination(saved: "API Workbench", showDeveloperTools: false), .models)
        XCTAssertEqual(restoredSidebarDestination(saved: "Activity", showDeveloperTools: false), .models)
        // Not sidebar rows: catalog kinds and Platforms (which opens Settings) never restore.
        XCTAssertEqual(restoredSidebarDestination(saved: "Materials", showDeveloperTools: true), .models)
        XCTAssertEqual(restoredSidebarDestination(saved: "Platforms", showDeveloperTools: true), .models)
        XCTAssertEqual(restoredSidebarDestination(saved: "orders", showDeveloperTools: false), .models)
        XCTAssertEqual(restoredSidebarDestination(saved: "", showDeveloperTools: false), .models)
    }

    // MARK: Platform composer wording

    func testPlatformAddressErrorExplainsWhatToEnter() {
        XCTAssertThrowsError(try PlatformDraft(name: "Shop", url: "etsy.com/shop/x").payload()) { error in
            XCTAssertTrue(error.localizedDescription.contains("https://www.etsy.com/shop/"))
        }
        XCTAssertNoThrow(try PlatformDraft(name: "Shop", url: "https://www.etsy.com/shop/MyShop").payload())
    }
}
