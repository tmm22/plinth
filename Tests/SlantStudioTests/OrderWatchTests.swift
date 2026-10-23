import XCTest
@testable import SlantStudio

final class OrderWatchTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func record(_ id: String, _ status: Any?, wrapped: Bool = false) -> Record {
        var order: [String: Any] = ["publicId": id, "customer": ["details": ["name": "Ada Lovelace"]], "total": 12.5]
        if let status { order["status"] = status }
        order["items"] = [["status": "PROCESSING"]]
        return Record(values: wrapped ? ["order": order, "publicId": id] : order)
    }
    private func obs(_ id: String, _ status: String) -> OrderWatchObservation {
        OrderWatchObservation(id: id, status: status, number: id)
    }

    // MARK: Observations

    func testObservationsUseOrderLevelStatusAndSkipOddRows() {
        let rows = [record("SLANT_1", "shipped"), record("SLANT_2", nil), record("SLANT_3", 5), record("SLANT_1", "DELIVERED"),
                    record("SLANT_4", "PRINTING", wrapped: true), Record(values: ["status": "PAID"])]
        let result = orderWatchObservations(rows)
        XCTAssertEqual(result, [obs("SLANT_1", "SHIPPED"), obs("SLANT_4", "PRINTING")])
    }

    // MARK: Diffing

    func testFirstRunRecordsSilently() {
        let applied = orderWatchApplying([obs("A", "SHIPPED"), obs("B", "DRAFT")], to: OrderWatchSnapshot(), now: t0)
        XCTAssertTrue(applied.transitions.isEmpty)
        XCTAssertEqual(applied.snapshot.orders.count, 2)
        XCTAssertTrue(orderWatchUnseenChanges(applied.snapshot).isEmpty)
        XCTAssertEqual(applied.snapshot.updatedAt, t0)
    }

    func testStatusChangeBecomesUnseenAndSummarised() {
        var snap = orderWatchApplying([obs("A", "PRINTING"), obs("B", "PAID"), obs("C", "QUEUED"), obs("D", "AWAITING_SHIPMENT")],
                                      to: OrderWatchSnapshot(), now: t0).snapshot
        let later = t0.addingTimeInterval(240)
        let applied = orderWatchApplying([obs("A", "SHIPPED"), obs("B", "PAYMENT_ERROR"), obs("C", "PRINTING"), obs("D", "SHIPPED")],
                                         to: snap, now: later)
        snap = applied.snapshot
        XCTAssertEqual(applied.transitions.count, 4)
        let changes = orderWatchUnseenChanges(snap)
        XCTAssertEqual(Set(changes.map(\.id)), ["A", "B", "C", "D"])
        XCTAssertEqual(orderWatchSummaryText(changes), "1 payment problem · 2 shipped · 1 printing")
        XCTAssertEqual(orderWatchBadgeCount(changes), 3)
        XCTAssertEqual(snap.orders["A"]?.changedAt, later)
    }

    func testUnseenChangeKeepsTheStatusLastLookedAt() {
        var snap = orderWatchApplying([obs("A", "PRINTING")], to: OrderWatchSnapshot(), now: t0).snapshot
        snap = orderWatchApplying([obs("A", "COMPLETED")], to: snap, now: t0 + 1).snapshot
        snap = orderWatchApplying([obs("A", "SHIPPED")], to: snap, now: t0 + 2).snapshot
        XCTAssertEqual(orderWatchUnseenChanges(snap), [OrderWatchChange(id: "A", from: "PRINTING", to: "SHIPPED", changedAt: t0 + 2)])
        // Back to the status last looked at: nothing to report.
        snap = orderWatchApplying([obs("A", "PRINTING")], to: snap, now: t0 + 3).snapshot
        XCTAssertTrue(orderWatchUnseenChanges(snap).isEmpty)
    }

    func testPlacingADraftIsNotReported() {
        var snap = orderWatchApplying([obs("A", "DRAFT")], to: OrderWatchSnapshot(), now: t0).snapshot
        let applied = orderWatchApplying([obs("A", "PAID")], to: snap, now: t0 + 1)
        snap = applied.snapshot
        XCTAssertTrue(orderWatchUnseenChanges(snap).isEmpty)
        XCTAssertEqual(snap.orders["A"]?.seenStatus, "PAID")
        XCTAssertTrue(orderWatchNotificationTexts(applied.transitions).isEmpty)
        // A later problem after placing is reported.
        snap = orderWatchApplying([obs("A", "PAYMENT_ERROR")], to: snap, now: t0 + 2).snapshot
        XCTAssertEqual(orderWatchUnseenChanges(snap).map(\.to), ["PAYMENT_ERROR"])
        XCTAssertFalse(orderWatchChangeIsReported(from: "SHIPPED", to: "SHIPPED"))
        XCTAssertTrue(orderWatchChangeIsReported(from: "DRAFT", to: "CANCELED"))
    }

    func testMissingOrdersAreLeftAlone() {
        var snap = orderWatchApplying([obs("A", "PRINTING"), obs("B", "QUEUED")], to: OrderWatchSnapshot(), now: t0).snapshot
        snap = orderWatchApplying([obs("B", "QUEUED")], to: snap, now: t0 + 100).snapshot
        XCTAssertEqual(snap.orders["A"]?.status, "PRINTING")
        XCTAssertEqual(snap.orders["A"]?.lastSeen, t0)
        XCTAssertEqual(snap.orders["B"]?.lastSeen, t0 + 100)
        XCTAssertTrue(orderWatchUnseenChanges(snap).isEmpty)
    }

    func testAcknowledgeAllOrSome() {
        var snap = orderWatchApplying([obs("A", "PRINTING"), obs("B", "PRINTING")], to: OrderWatchSnapshot(), now: t0).snapshot
        snap = orderWatchApplying([obs("A", "SHIPPED"), obs("B", "DELIVERED")], to: snap, now: t0 + 1).snapshot
        let some = orderWatchAcknowledging(snap, ids: ["A"])
        XCTAssertEqual(orderWatchUnseenChanges(some).map(\.id), ["B"])
        XCTAssertTrue(orderWatchUnseenChanges(orderWatchAcknowledging(snap)).isEmpty)
    }

    func testSummaryOrdering() {
        let changes = ["PRINTING", "SHIPPED", "IN_REVIEW", "QUEUED", "SHIPPED", "MYSTERY_STATE", "DELIVERED", "CANCELED"]
            .enumerated().map { OrderWatchChange(id: "\($0.offset)", from: "PAID", to: $0.element) }
        XCTAssertEqual(orderWatchSummaryGroups(changes).map(\.status),
                       ["IN_REVIEW", "CANCELED", "DELIVERED", "SHIPPED", "QUEUED", "PRINTING", "MYSTERY_STATE"])
        XCTAssertEqual(orderWatchSummaryText([]), "")
    }

    func testUnseenChangesSortedNewestFirst() {
        var snap = orderWatchApplying([obs("A", "PRINTING"), obs("B", "PRINTING")], to: OrderWatchSnapshot(), now: t0).snapshot
        snap = orderWatchApplying([obs("B", "SHIPPED")], to: snap, now: t0 + 1).snapshot
        snap = orderWatchApplying([obs("A", "SHIPPED")], to: snap, now: t0 + 2).snapshot
        XCTAssertEqual(orderWatchUnseenChanges(snap).map(\.id), ["A", "B"])
    }

    // MARK: Notifications

    func testNotificationsCarryOnlyNumberAndStatus() {
        let transitions = [OrderWatchTransition(id: "SLANT_9", number: "SLANT_9", from: "AWAITING_SHIPMENT", to: "SHIPPED"),
                           OrderWatchTransition(id: "SLANT_8", number: "SLANT_8", from: "PAID", to: "QUEUED"),
                           OrderWatchTransition(id: "SLANT_7", number: "", from: "PAID", to: "PAYMENT_ERROR")]
        let texts = orderWatchNotificationTexts(transitions)
        XCTAssertEqual(texts.map(\.title), ["Order SLANT_9 has shipped", "Order SLANT_7 has a payment problem"])
        XCTAssertEqual(texts.first?.body, "Awaiting shipment → Shipped")
        for text in texts { XCTAssertFalse((text.title + text.body).contains("Ada")) }
    }

    func testManyNotificationsBecomeOneSummary() {
        let transitions = (1...5).map { OrderWatchTransition(id: "S\($0)", number: "S\($0)", from: "SHIPPED", to: "DELIVERED") }
        let texts = orderWatchNotificationTexts(transitions)
        XCTAssertEqual(texts, [OrderWatchNotificationText(identifier: "order-watch-summary", title: "5 orders changed", body: "5 delivered")])
        XCTAssertTrue(orderWatchShouldNotify(OrderWatchTransition(id: "x", number: "x", from: "PAID", to: "IN_REVIEW")))
        XCTAssertFalse(orderWatchShouldNotify(OrderWatchTransition(id: "x", number: "x", from: "QUEUED", to: "PRINTING")))
    }

    // MARK: Pruning

    func testPruneDropsOldAndCapsKeepingUnseen() {
        var snap = OrderWatchSnapshot()
        snap.orders["old"] = OrderWatchEntry(status: "DELIVERED", seenStatus: "DELIVERED", lastSeen: t0 - orderWatchMaxAge - 10)
        for index in 0..<10 {
            snap.orders["o\(index)"] = OrderWatchEntry(status: "PAID", seenStatus: "PAID", lastSeen: t0 - TimeInterval(index))
        }
        snap.orders["unseen"] = OrderWatchEntry(status: "SHIPPED", seenStatus: "PAID", lastSeen: t0 - 1000)
        let pruned = orderWatchPruned(snap, now: t0, maxEntries: 4)
        XCTAssertEqual(Set(pruned.orders.keys), ["unseen", "o0", "o1", "o2"])
        XCTAssertEqual(orderWatchPruned(snap, now: t0).orders.count, 11)
        XCTAssertTrue(orderWatchPruned(snap, now: t0, maxEntries: 0).orders.isEmpty)
    }

    // MARK: When to check

    func testSkipReasons() {
        XCTAssertNil(orderWatchSkipReason(OrderWatchConditions(now: t0)))
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(enabled: false)), .disabled)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(hasKey: false)), .noKey)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(hasPlatform: false)), .noPlatform)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(busy: true)), .busy)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(modalUIShown: true)), .modalUI)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(inFlight: true)), .inFlight)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(accountPaused: true)), .accountPaused)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(backoffUntil: t0 + 30, now: t0)), .rateLimited(until: t0 + 30))
        XCTAssertNil(orderWatchSkipReason(OrderWatchConditions(backoffUntil: t0 - 1, now: t0)))
    }

    func testRateLimitSkips() {
        let low = RateLimitInfo(limit: 100, remaining: 5, reset: t0 + 40, role: nil)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(rateLimit: low, now: t0)), .rateLimited(until: t0 + 40))
        // The reset has passed: the allowance refilled.
        XCTAssertNil(orderWatchSkipReason(OrderWatchConditions(rateLimit: low, now: t0 + 41)))
        let plenty = RateLimitInfo(limit: 100, remaining: 80, reset: t0 + 40, role: nil)
        XCTAssertNil(orderWatchSkipReason(OrderWatchConditions(rateLimit: plenty, now: t0)))
        // Low with no reset time: wait one interval, then go ahead unless a newer reading arrived.
        let lowNoReset = RateLimitInfo(limit: 100, remaining: orderWatchRateLimitReserve, reset: nil, role: nil)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(rateLimit: lowNoReset, now: t0)), .rateLimited(until: nil))
        XCTAssertNil(orderWatchSkipReason(OrderWatchConditions(rateLimit: lowNoReset, rateLimitAlreadyWaitedFor: lowNoReset, now: t0)))
    }

    func testNextDelay() {
        XCTAssertEqual(orderWatchNextDelay(after: nil, now: t0), orderWatchInterval)
        XCTAssertEqual(orderWatchNextDelay(after: .busy, now: t0), orderWatchRecheckDelay)
        XCTAssertEqual(orderWatchNextDelay(after: .rateLimited(until: t0 + 40), now: t0), 42)
        XCTAssertEqual(orderWatchNextDelay(after: .rateLimited(until: t0 + 9999), now: t0), orderWatchInterval)
        XCTAssertEqual(orderWatchNextDelay(after: .rateLimited(until: t0 - 100), now: t0), 5)
        XCTAssertEqual(orderWatchNextDelay(after: .rateLimited(until: nil), now: t0), orderWatchInterval)
    }

    func testFailureEffects() {
        let resetMillis = String(Int((t0.timeIntervalSince1970 + 50) * 1000))
        let limited = APIError.http(status: 429, body: "", retryAfter: nil, rateLimitReset: resetMillis)
        XCTAssertEqual(orderWatchFailureEffect(limited, now: t0).backoffUntil?.timeIntervalSince1970 ?? 0, t0.timeIntervalSince1970 + 50, accuracy: 0.01)
        let retryAfter = APIError.http(status: 429, body: "", retryAfter: "12", rateLimitReset: nil)
        XCTAssertEqual(orderWatchFailureEffect(retryAfter, now: t0).backoffUntil, t0 + 12)
        let bare = APIError.http(status: 429, body: "", retryAfter: "soon", rateLimitReset: nil)
        XCTAssertEqual(orderWatchFailureEffect(bare, now: t0).backoffUntil, t0 + 60)
        XCTAssertTrue(orderWatchFailureEffect(APIError.http(status: 401, body: "", retryAfter: nil, rateLimitReset: nil), now: t0).pauseAccount)
        XCTAssertTrue(orderWatchFailureEffect(APIError.http(status: 403, body: "", retryAfter: nil, rateLimitReset: nil), now: t0).pauseAccount)
        let server = orderWatchFailureEffect(APIError.http(status: 503, body: "", retryAfter: nil, rateLimitReset: nil), now: t0)
        XCTAssertNil(server.backoffUntil); XCTAssertFalse(server.pauseAccount)
        XCTAssertFalse(orderWatchFailureEffect(URLError(.timedOut), now: t0).pauseAccount)
    }

    // MARK: Storage

    func testRoundTrip() throws {
        var snap = OrderWatchSnapshot(updatedAt: t0)
        snap.orders["SLANT_1"] = OrderWatchEntry(status: "SHIPPED", seenStatus: "PRINTING", lastSeen: t0, changedAt: t0 - 5)
        snap.orders["SLANT_2"] = OrderWatchEntry(status: "DRAFT", seenStatus: "DRAFT", lastSeen: t0 - 60)
        let data = try XCTUnwrap(encodeOrderWatchSnapshot(snap))
        XCTAssertEqual(decodeOrderWatchSnapshot(data), snap)
        // Only IDs, statuses and times are written.
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        for key in ["name", "address", "email", "total", "metadata", "platform"] { XCTAssertFalse(text.lowercased().contains(key), key) }
    }

    func testLenientDecoding() throws {
        let json = """
        {"version": 7, "updatedAt": 1790000000, "orders": {
          "GOOD": {"status": "shipped", "seenStatus": "PRINTING", "lastSeen": 1789999000},
          "NO_SEEN": {"status": "PAID"},
          "BAD_STATUS": {"status": 4},
          "NOT_OBJECT": "PAID",
          "": {"status": "PAID"},
          "ODD_DATE": {"status": "QUEUED", "lastSeen": true, "changedAt": "yesterday"}
        }}
        """
        let snap = try XCTUnwrap(decodeOrderWatchSnapshot(Data(json.utf8), now: t0))
        XCTAssertEqual(Set(snap.orders.keys), ["GOOD", "NO_SEEN", "ODD_DATE"])
        XCTAssertEqual(snap.orders["GOOD"], OrderWatchEntry(status: "SHIPPED", seenStatus: "PRINTING",
                                                           lastSeen: Date(timeIntervalSince1970: 1_789_999_000)))
        XCTAssertEqual(snap.orders["NO_SEEN"]?.seenStatus, "PAID")
        XCTAssertEqual(snap.orders["NO_SEEN"]?.lastSeen, t0)
        XCTAssertNil(snap.orders["ODD_DATE"]?.changedAt)
        XCTAssertNil(decodeOrderWatchSnapshot(Data("not json".utf8)))
        XCTAssertNil(decodeOrderWatchSnapshot(Data("[1,2]".utf8)))
        XCTAssertEqual(decodeOrderWatchSnapshot(Data("{}".utf8)), OrderWatchSnapshot())
    }

    // MARK: Focus

    func testFocusedRecords() {
        let orders = [record("A", "PAID"), record("B", "SHIPPED"), record("C", "PAID")]
        XCTAssertNil(orderWatchFocusedRecords(orders, focus: nil))
        XCTAssertNil(orderWatchFocusedRecords(orders, focus: []))
        XCTAssertNil(orderWatchFocusedRecords(orders, focus: ["Z"]))
        XCTAssertEqual(orderWatchFocusedRecords(orders, focus: ["C", "A"])?.map(\.id), ["A", "C"])
        XCTAssertEqual(orderWatchFocusCaption(count: 1), "Showing 1 order that changed since you last looked.")
        XCTAssertEqual(orderWatchFocusCaption(count: 3), "Showing 3 orders that changed since you last looked.")
    }

    func testNotificationsUnavailableOutsideAnAppBundle() {
        // The test runner is an .xctest bundle, never the packaged .app.
        XCTAssertFalse(orderWatchNotificationsAvailable(bundle: Bundle(for: OrderWatchTests.self)))
    }
}
