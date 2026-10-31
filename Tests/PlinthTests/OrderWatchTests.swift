import XCTest
@testable import Plinth

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
        var snap = orderWatchApplying([obs("A", "PRINTING"), obs("B", "PAID"), obs("C", "SUBMITTED"), obs("D", "AWAITING_SHIPMENT")],
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
                       ["IN_REVIEW", "CANCELLED", "DELIVERED", "SHIPPED", "QUEUED", "PRINTING", "MYSTERY_STATE"])
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

    func testDeliveredIsListedButNotBadged() {
        let changes = [
            OrderWatchChange(id: "A", from: "SHIPPED", to: "DELIVERED"),
            OrderWatchChange(id: "B", from: "PRINTING", to: "SHIPPED"),
            OrderWatchChange(id: "C", from: "QUEUED", to: "PRINTING"),
            OrderWatchChange(id: "D", from: "PAID", to: "CANCELED")
        ]
        XCTAssertEqual(orderWatchBadgeCount(changes), 2, "shipped and cancelled badge; delivered and progress don't")
        XCTAssertEqual(orderWatchBadgeCount([changes[0]]), 0)
        XCTAssertTrue(orderWatchSummaryText(changes).contains("1 delivered"), "still listed in the banner")
        XCTAssertTrue(orderWatchShouldNotify(OrderWatchTransition(id: "A", number: "A", from: "SHIPPED", to: "DELIVERED")))
        XCTAssertTrue(orderWatchChangesIncludeShipped(changes))
        XCTAssertFalse(orderWatchChangesIncludeShipped([changes[0], changes[2]]))
    }

    func testPlatformChangeForgetsOnlyBetweenKnownPlatforms() {
        XCTAssertTrue(orderWatchPlatformChanged(from: "plat_A", to: "plat_B"))
        XCTAssertFalse(orderWatchPlatformChanged(from: "plat_A", to: "plat_A"))
        XCTAssertFalse(orderWatchPlatformChanged(from: " plat_A ", to: "plat_A"))
        XCTAssertFalse(orderWatchPlatformChanged(from: "plat_A", to: ""), "the blank during a key change isn't a platform")
        XCTAssertFalse(orderWatchPlatformChanged(from: nil, to: "plat_A"), "the first platform adopts the saved statuses")
        XCTAssertFalse(orderWatchPlatformChanged(from: "", to: "plat_A"))
    }

    func testBackgroundRateLimitNeverOverwritesNewerFigures() {
        let now = t0
        let reset = now.addingTimeInterval(40)
        let current = RateLimitInfo(limit: 100, remaining: 50, reset: reset)
        // Same window: the allowance only falls, so a higher figure is older.
        XCTAssertFalse(orderWatchShouldApplyRateLimit(current: current, incoming: RateLimitInfo(limit: 100, remaining: 51, reset: reset), now: now))
        XCTAssertTrue(orderWatchShouldApplyRateLimit(current: current, incoming: RateLimitInfo(limit: 100, remaining: 49, reset: reset), now: now))
        XCTAssertTrue(orderWatchShouldApplyRateLimit(current: current, incoming: RateLimitInfo(limit: 100, remaining: 50, reset: reset.addingTimeInterval(0.5)), now: now))
        // A later window wins; an earlier one never does.
        XCTAssertTrue(orderWatchShouldApplyRateLimit(current: current, incoming: RateLimitInfo(limit: 100, remaining: 99, reset: reset.addingTimeInterval(60)), now: now))
        XCTAssertFalse(orderWatchShouldApplyRateLimit(current: current, incoming: RateLimitInfo(limit: 100, remaining: 10, reset: reset.addingTimeInterval(-30)), now: now))
        // Nothing known, or the known window has passed.
        XCTAssertTrue(orderWatchShouldApplyRateLimit(current: nil, incoming: RateLimitInfo(remaining: 80), now: now))
        XCTAssertTrue(orderWatchShouldApplyRateLimit(current: RateLimitInfo(), incoming: RateLimitInfo(remaining: 80), now: now))
        XCTAssertTrue(orderWatchShouldApplyRateLimit(current: RateLimitInfo(remaining: 5, reset: now.addingTimeInterval(-1)),
                                                     incoming: RateLimitInfo(remaining: 80), now: now))
        // No reset time to tell windows apart: only the same or less allowance.
        XCTAssertFalse(orderWatchShouldApplyRateLimit(current: RateLimitInfo(remaining: 50), incoming: RateLimitInfo(remaining: 60), now: now))
        XCTAssertTrue(orderWatchShouldApplyRateLimit(current: RateLimitInfo(remaining: 50), incoming: RateLimitInfo(remaining: 50), now: now))
        // A reply without figures, or without a remaining count, changes nothing.
        XCTAssertFalse(orderWatchShouldApplyRateLimit(current: current, incoming: RateLimitInfo(), now: now))
        XCTAssertFalse(orderWatchShouldApplyRateLimit(current: current, incoming: RateLimitInfo(limit: 100), now: now))
    }

    // MARK: With 3DAPI as the print service

    func testChecksDontDependOnThePrintService() {
        // Owner decision (delegated, 31 Oct 2026): Slant's watch keeps running while 3DAPI is chosen, so the
        // conditions have no print-service input and the skip rules are the ones from before the pause.
        XCTAssertNil(orderWatchSkipReason(OrderWatchConditions(now: Date())))
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(enabled: false)), .disabled)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(modalUIShown: true)), .modalUI)
        XCTAssertEqual(orderWatchSkipReason(OrderWatchConditions(busy: true)), .busy)
        // The sidebar shows the chosen service's count; the Dock (`orderWatchDockBadgeLabel`) shows Slant's always.
        XCTAssertEqual(ordersSidebarBadgeCount(service: .dapi, slantCount: 4, dapiCount: 1), 1)
        XCTAssertEqual(ordersSidebarBadgeCount(service: .slant, slantCount: 4, dapiCount: 1), 4)
        XCTAssertEqual(orderWatchDockBadgeLabel(count: 4, showOnDock: true), "4")
    }

    func testNotificationClickTargetsAndRoutes() {
        XCTAssertEqual(OrderWatchNotificationTarget(userInfo: [dapiOrderWatchNotificationOrderIDKey: "ord_Test0001"]),
                       .dapi(orderID: "ord_Test0001"))
        XCTAssertEqual(OrderWatchNotificationTarget(userInfo: [orderWatchNotificationOrderIDKey: "SLANT-TEST-1"]),
                       .slant(orderID: "SLANT-TEST-1"))
        // An invalid 3DAPI ID is never used; nothing else in it is read.
        XCTAssertEqual(OrderWatchNotificationTarget(userInfo: [dapiOrderWatchNotificationOrderIDKey: "ord_x/../y"]), .slant(orderID: nil))
        XCTAssertEqual(OrderWatchNotificationTarget(userInfo: [:]), .slant(orderID: nil))

        XCTAssertEqual(orderWatchNotificationRoute(.dapi(orderID: "ord_A"), service: .dapi), .dapiOrder(orderID: "ord_A"))
        XCTAssertEqual(orderWatchNotificationRoute(.slant(orderID: "S1"), service: .slant), .slantOrders(orderID: "S1"))
        // The other service's notification asks before switching to that service; it never switches by itself.
        XCTAssertEqual(orderWatchNotificationRoute(.dapi(orderID: "ord_A"), service: .slant), .askToSwitch(to: .dapi))
        XCTAssertEqual(orderWatchNotificationRoute(.slant(orderID: "S1"), service: .dapi), .askToSwitch(to: .slant))
        XCTAssertEqual(orderWatchNotificationRoute(.slant(orderID: nil), service: .dapi), .askToSwitch(to: .slant))
        // After the switch, the same click takes that service's own path.
        XCTAssertEqual(orderWatchNotificationRoute(.slant(orderID: "S1"), service: .slant), .slantOrders(orderID: "S1"))
        XCTAssertEqual(orderWatchNotificationRoute(.dapi(orderID: "ord_A"), service: .dapi), .dapiOrder(orderID: "ord_A"))
    }

    func testSwitchQuestionNamesTheServiceAndTheNumberOnly() {
        let slant = orderWatchSwitchQuestion(to: .slant, number: "1042")
        XCTAssertEqual(slant.title, "Show this Slant order?")
        XCTAssertEqual(slant.message, "Plinth is set to 3DAPI. Switch the print service to Slant 3D to see order 1042?")
        XCTAssertEqual(slant.switchButton, "Switch to Slant 3D")
        let dapi = orderWatchSwitchQuestion(to: .dapi, number: nil)
        XCTAssertEqual(dapi.title, "Show this 3DAPI order?")
        XCTAssertEqual(dapi.message, "Plinth is set to Slant 3D. Switch the print service to 3DAPI to see this order?")
        XCTAssertEqual(dapi.switchButton, "Switch to 3DAPI")
        XCTAssertEqual(orderWatchSwitchQuestion(to: .dapi, number: "  ").message,
                       "Plinth is set to Slant 3D. Switch the print service to 3DAPI to see this order?")
    }

    func testNotifiedNumbersAreBoundedAndClean() {
        var numbers: [String: String] = [:]
        numbers = orderWatchNotedNumbers(numbers, adding: " 1042 ", for: "slant:S1")
        XCTAssertEqual(numbers["slant:S1"], "1042")
        // Nothing for an empty number or ID, or text with control characters.
        XCTAssertEqual(orderWatchNotedNumbers(numbers, adding: "", for: "slant:S2"), numbers)
        XCTAssertEqual(orderWatchNotedNumbers(numbers, adding: "7", for: ""), numbers)
        XCTAssertEqual(orderWatchNotedNumbers(numbers, adding: "7\u{0}8", for: "slant:S3"), numbers)
        XCTAssertEqual(orderWatchNotedNumbers(numbers, adding: String(repeating: "9", count: 80), for: "slant:S4")["slant:S4"]?.count, 40)
        // Capped: a new entry past the limit starts over (memory only, numbers only).
        var full: [String: String] = [:]
        for i in 0..<3 { full = orderWatchNotedNumbers(full, adding: "\(i)", for: "dapi:ord_\(i)", limit: 3) }
        XCTAssertEqual(full.count, 3)
        XCTAssertEqual(orderWatchNotedNumbers(full, adding: "9", for: "dapi:ord_2", limit: 3).count, 3, "An update isn't a new entry")
        XCTAssertEqual(orderWatchNotedNumbers(full, adding: "9", for: "dapi:ord_9", limit: 3), ["dapi:ord_9": "9"])
    }

    func testNotificationClickWaitsForModalUIAndRequests() {
        let dapiRoute = OrderWatchNotificationRoute.dapiOrder(orderID: "ord_A")
        func canOpen(_ route: OrderWatchNotificationRoute, sheet: Bool = false, modal: Bool = false, error: Bool = false,
                     busy: Bool = false, writes: Int = 0, sheets: Int = 0) -> Bool {
            orderWatchNotificationCanOpen(route, storeSheetPresented: sheet, appModalUIPresented: modal, errorShown: error, busy: busy,
                                          dapiWritesInFlight: writes, dapiOrderSheetsOpen: sheets)
        }
        for route in [dapiRoute, .slantOrders(orderID: "S1")] {
            XCTAssertTrue(canOpen(route))
            XCTAssertFalse(canOpen(route, sheet: true), "a Slant review is open")
            XCTAssertFalse(canOpen(route, modal: true))
            XCTAssertFalse(canOpen(route, error: true))
            XCTAssertFalse(canOpen(route, busy: true))
        }
        XCTAssertFalse(canOpen(dapiRoute, writes: 1), "a 3DAPI order write waits for its reply")
        XCTAssertFalse(canOpen(dapiRoute, sheets: 1))
        XCTAssertTrue(canOpen(.slantOrders(orderID: "S1"), writes: 1), "Slant's rule is unchanged")
        // The switch question waits like any click, and also for 3DAPI's writes and order sheets, which would refuse
        // the switch anyway.
        for service in PrintService.allCases {
            let ask = OrderWatchNotificationRoute.askToSwitch(to: service)
            XCTAssertTrue(canOpen(ask))
            XCTAssertFalse(canOpen(ask, sheet: true))
            XCTAssertFalse(canOpen(ask, modal: true), "an open sheet, alert or dialog in any window")
            XCTAssertFalse(canOpen(ask, error: true))
            XCTAssertFalse(canOpen(ask, busy: true))
            XCTAssertFalse(canOpen(ask, writes: 1))
            XCTAssertFalse(canOpen(ask, sheets: 1))
        }
    }

    func testSettingsNoteFor3DAPI() {
        XCTAssertTrue(orderWatchDapiServiceNote.contains("every 4 minutes"))
        XCTAssertTrue(orderWatchDapiServiceNote.contains("nothing about them is saved"))
        XCTAssertTrue(orderWatchDapiServiceNote.contains("order number and status only"))
        XCTAssertTrue(orderWatchDapiServiceNote.contains("keeps checking your Slant orders"))
        XCTAssertTrue(orderWatchDapiServiceNote.contains("the Dock count still shows Slant orders"))
        XCTAssertFalse(orderWatchDapiServiceNote.contains("aren’t checked"))
    }

    func testNotificationsUnavailableOutsideAnAppBundle() {
        // The test runner is an .xctest bundle, never the packaged .app.
        XCTAssertFalse(orderWatchNotificationsAvailable(bundle: Bundle(for: OrderWatchTests.self)))
    }
}
