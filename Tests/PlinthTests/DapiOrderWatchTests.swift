import XCTest
@testable import Plinth

// The 3DAPI order watch (DapiOrderWatch.swift): the pure diffing and failure rules, and `tick()` driven with a
// scripted client, a fixed clock and a recording notifier. No loop, network, Keychain or notifications.

final class DapiOrderWatchTests: XCTestCase {
    func page(_ orders: [DapiOrder], hasMore: Bool = false) -> Result<DapiOrderPage, DapiError> {
        .success(DapiOrderPage(orders: orders, hasMore: hasMore, nextCursor: hasMore ? "c" : nil))
    }

    func o(_ id: String, _ status: DapiOrderStatus, number: String? = nil) -> DapiOrder {
        insightOrder(id: id, number: number ?? "2AP-\(id)", status: status)
    }

    // MARK: Pure rules

    func testQueryListsOpenStatusesWithoutLines() {
        let query = dapiOrderWatchQuery()
        XCTAssertEqual(query.statuses, [.awaitingPayment, .paid, .assigned, .inProduction, .shipped, .onHold, .rejected])
        XCTAssertEqual(query.limit, 100)
        XCTAssertFalse(query.expandItems)
        XCTAssertNil(query.cursor)
    }

    func testFirstSightIsSilentAndChangesAreReportedOnce() {
        var state = DapiOrderWatchState()
        XCTAssertEqual(dapiOrderWatchApply([o("ord_1", .paid), o("ord_2", .onHold)], to: &state), [])
        XCTAssertTrue(state.unseen.isEmpty)
        let notices = dapiOrderWatchApply([o("ord_1", .shipped), o("ord_2", .onHold)], to: &state)
        XCTAssertEqual(notices, [DapiOrderWatchNotice(orderID: "ord_1", number: "2AP-ord_1", status: .shipped)])
        XCTAssertEqual(state.unseen, ["ord_1": .shipped])
        // The same status again (in another case, with spaces) is no change.
        XCTAssertEqual(dapiOrderWatchApply([o("ord_1", DapiOrderStatus(raw: " SHIPPED "))], to: &state), [])
        XCTAssertEqual(dapiOrderWatchApply([o("ord_9", .unknown("Mystery"))], to: &state), [])
        XCTAssertEqual(dapiOrderWatchApply([o("ord_9", .unknown(" mystery "))], to: &state), [])
        // A change to a status that isn't notable is recorded silently and clears an unseen notable one.
        XCTAssertEqual(dapiOrderWatchApply([o("ord_2", .inProduction)], to: &state), [])
        XCTAssertEqual(dapiOrderWatchApply([o("ord_2", .rejected)], to: &state).map(\.status), [.rejected])
        XCTAssertEqual(dapiOrderWatchApply([o("ord_2", .paid)], to: &state), [])
        XCTAssertEqual(state.unseen, ["ord_1": .shipped])
        // Unsafe IDs are ignored.
        XCTAssertEqual(dapiOrderWatchApply([o("../x", .paid)], to: &state), [])
        XCTAssertNil(state.orders["../x"])
    }

    func testNoticeTextAndUserInfo() {
        let notice = DapiOrderWatchNotice(orderID: "ord_abc123", number: "2AP77", status: .onHold)
        XCTAssertEqual(notice.body, "3DAPI order 2AP77 is now on hold.")
        XCTAssertEqual(notice.identifier, "dapi-order-ord_abc123-on_hold")
        XCTAssertEqual(dapiOrderWatchNotificationOrderID([dapiOrderWatchNotificationOrderIDKey: "ord_abc123"]), "ord_abc123")
        XCTAssertNil(dapiOrderWatchNotificationOrderID([dapiOrderWatchNotificationOrderIDKey: "ord_a/b"]))
        XCTAssertNil(dapiOrderWatchNotificationOrderID([dapiOrderWatchNotificationOrderIDKey: "qte_abc"]))
        XCTAssertNil(dapiOrderWatchNotificationOrderID(["orderID": "ord_abc"]))
    }

    func testDroppedOrdersAreReadFairlyAndFinalOnesNever() {
        var state = DapiOrderWatchState()
        for index in 0..<15 { state.orders["ord_\(String(format: "%02d", index))"] = DapiOrderWatchEntry(status: .paid, number: "") }
        state.orders["ord_done"] = DapiOrderWatchEntry(status: .completed, number: "")
        state.orders["ord_00"]?.lastFetched = Date(timeIntervalSince1970: 100)
        let dropped = dapiOrderWatchDropped(state, listedIDs: ["ord_01"])
        XCTAssertEqual(dropped.count, dapiOrderWatchFetchLimit)
        XCTAssertFalse(dropped.contains("ord_01"))
        XCTAssertFalse(dropped.contains("ord_done"))
        XCTAssertFalse(dropped.contains("ord_00")) // read most recently, so last in line
        XCTAssertEqual(dropped.first, "ord_02")
    }

    func testPruningDropsFinalOrdersFirst() {
        var state = DapiOrderWatchState()
        state.orders["ord_a"] = DapiOrderWatchEntry(status: .paid, number: "")
        state.orders["ord_b"] = DapiOrderWatchEntry(status: .completed, number: "")
        state.orders["ord_c"] = DapiOrderWatchEntry(status: .cancelled, number: "")
        state.unseen["ord_c"] = .cancelled
        let pruned = dapiOrderWatchPruned(state, limit: 2)
        XCTAssertEqual(Set(pruned.orders.keys), ["ord_a", "ord_c"])
        XCTAssertEqual(dapiOrderWatchPruned(state, limit: 1).orders.keys.sorted(), ["ord_a"])
        XCTAssertTrue(dapiOrderWatchPruned(state, limit: 1).unseen.isEmpty)
    }

    func testFailureRules() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.rateLimited(code: nil, retryAt: nil), now: now),
                       .backOff(until: now.addingTimeInterval(60)))
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.rateLimited(code: nil, retryAt: now.addingTimeInterval(300)), now: now),
                       .backOff(until: now.addingTimeInterval(300)))
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.rateLimited(code: nil, retryAt: now.addingTimeInterval(86_400)), now: now),
                       .backOff(until: now.addingTimeInterval(3600)))
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.rateLimited(code: nil, retryAt: now.addingTimeInterval(-50)), now: now),
                       .backOff(until: now.addingTimeInterval(60)))
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.refused(status: 401, code: "invalid_api_key", message: nil), now: now), .pause)
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.refused(status: 403, code: "missing_scope", message: nil), now: now), .pause)
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.refused(status: 404, code: nil, message: nil), now: now), .forget)
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.readFailed("x"), now: now), .skip)
        XCTAssertEqual(dapiOrderWatchFailure(DapiError.missingKey, now: now), .skip)
        XCTAssertEqual(dapiOrderWatchFailure(URLError(.timedOut), now: now), .skip)
    }

    // MARK: tick()

    @MainActor
    final class Harness {
        let client = InsightsScriptedDapiOrders()
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        var canCheck = true
        var hasClient = true
        var notices: [[DapiOrderWatchNotice]] = []
        var sleeps: [TimeInterval] = []
        var duringSleep: (() -> Void)?
        var cancelledByPlinth: Set<String> = []
        lazy var watch: DapiOrderWatch = DapiOrderWatch(environment: DapiOrderWatchEnvironment(
            makeClient: { [unowned self] in
                guard self.hasClient else { throw DapiError.missingKey }
                return self.client
            },
            canCheck: { [unowned self] in self.canCheck },
            now: { [unowned self] in MainActor.assumeIsolated { self.now } },
            sleep: { [unowned self] seconds in
                await MainActor.run {
                    self.sleeps.append(seconds)
                    self.duringSleep?()
                }
            },
            notify: { [unowned self] in self.notices.append($0) },
            cancelledThroughPlinth: { [unowned self] in self.cancelledByPlinth }), startsLoop: false)
    }

    @MainActor
    func testInactiveWatchSendsNothing() async {
        let harness = Harness()
        await harness.watch.tick()
        XCTAssertTrue(harness.client.queries.isEmpty)
    }

    @MainActor
    func testTickRecordsSilentlyThenBadgesAndNotifiesChanges() async {
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.client.scriptPages([page([o("ord_1", .paid), o("ord_2", .inProduction)])])
        let delay = await watch.tick()
        XCTAssertEqual(delay, dapiOrderWatchInterval)
        XCTAssertEqual(harness.client.queries, [dapiOrderWatchQuery()])
        XCTAssertEqual(watch.badgeCount, 0)
        XCTAssertTrue(harness.notices.isEmpty)
        // ord_2 shipped (still listed); ord_1 left the list: read by ID, now cancelled.
        harness.client.scriptPages([page([o("ord_2", .shipped)])])
        harness.client.scriptOrder("ord_1", .success(o("ord_1", .cancelled)))
        await watch.tick()
        XCTAssertEqual(harness.client.idReads, ["ord_1"])
        XCTAssertEqual(harness.sleeps, [dapiOrderWatchFetchSpacing])
        XCTAssertEqual(watch.badgeCount, 2)
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertEqual(Set(harness.notices[0].map(\.status)), [.shipped, .cancelled])
        // Nothing new: no notices, and the cancelled order (final) is never read again.
        harness.client.scriptPages([page([o("ord_2", .shipped)])])
        await watch.tick()
        XCTAssertEqual(harness.notices.count, 1)
        XCTAssertEqual(harness.client.idReads, ["ord_1"])
        XCTAssertEqual(watch.badgeCount, 2)
        watch.ordersViewed()
        XCTAssertEqual(watch.badgeCount, 0)
        // Statuses stay remembered after viewing: the same status again isn't a change.
        await watch.tick()
        XCTAssertEqual(watch.badgeCount, 0)
    }

    @MainActor
    func testByIDReadsAreCappedAndAWrongIDIsIgnored() async {
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.client.scriptPages([page((0..<14).map { o("ord_\(String(format: "%02d", $0))", .paid) })])
        await watch.tick()
        harness.client.scriptPages([page([])])
        harness.client.scriptOrder("ord_00", .success(o("ord_99", .shipped)))
        for index in 1..<14 { harness.client.scriptOrder("ord_\(String(format: "%02d", index))", .success(o("ord_\(String(format: "%02d", index))", .paid))) }
        await watch.tick()
        XCTAssertEqual(harness.client.idReads.count, dapiOrderWatchFetchLimit)
        XCTAssertEqual(watch.badgeCount, 0)
        XCTAssertNil(watch.state.orders["ord_99"])
        // The next check reads the ones not read yet first.
        await watch.tick()
        XCTAssertEqual(Array(harness.client.idReads[10..<14]), ["ord_10", "ord_11", "ord_12", "ord_13"])
    }

    @MainActor
    func testNotFoundIsForgottenAndOtherFailuresStopTheReads() async {
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.client.scriptPages([page([o("ord_1", .paid), o("ord_2", .paid), o("ord_3", .paid)])])
        await watch.tick()
        harness.client.scriptPages([page([])])
        // ord_1 isn't scripted → 404; ord_2 fails to read; ord_3 must then wait.
        harness.client.scriptOrder("ord_2", .failure(.readFailed("timeout")))
        harness.client.scriptOrder("ord_3", .success(o("ord_3", .shipped)))
        await watch.tick()
        XCTAssertEqual(harness.client.idReads, ["ord_1", "ord_2"])
        XCTAssertNil(watch.state.orders["ord_1"])
        XCTAssertNotNil(watch.state.orders["ord_2"])
        XCTAssertEqual(watch.badgeCount, 0)
    }

    @MainActor
    func testSkipsWhileBusyOrWithoutAKey() async {
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.canCheck = false
        do { let delay = await watch.tick(); XCTAssertEqual(delay, dapiOrderWatchRecheckDelay) }
        harness.canCheck = true
        harness.hasClient = false
        do { let delay = await watch.tick(); XCTAssertEqual(delay, dapiOrderWatchRecheckDelay) }
        XCTAssertTrue(harness.client.queries.isEmpty)
    }

    @MainActor
    func testBacksOffAfterA429() async {
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.client.scriptPages([.failure(.rateLimited(code: "rate_limited", retryAt: harness.now.addingTimeInterval(600)))])
        let delay = await watch.tick()
        XCTAssertEqual(delay, dapiOrderWatchInterval)
        XCTAssertEqual(harness.client.queries.count, 1)
        harness.now = harness.now.addingTimeInterval(240)
        // Still waiting: no request, and the next look comes within the usual interval.
        do { let delay = await watch.tick(); XCTAssertEqual(delay, dapiOrderWatchInterval) }
        XCTAssertEqual(harness.client.queries.count, 1)
        harness.now = harness.now.addingTimeInterval(361)
        harness.client.scriptPages([page([])])
        await watch.tick()
        XCTAssertEqual(harness.client.queries.count, 2)
    }

    @MainActor
    func testPausesAfterARefusedKeyUntilSetActiveAgain() async {
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.client.scriptPages([.failure(.refused(status: 401, code: "invalid_api_key", message: nil))])
        await watch.tick()
        XCTAssertTrue(watch.paused)
        harness.client.scriptPages([page([])])
        await watch.tick()
        XCTAssertEqual(harness.client.queries.count, 1)
        watch.setActive(true)
        XCTAssertFalse(watch.paused)
        await watch.tick()
        XCTAssertEqual(harness.client.queries.count, 2)
    }

    @MainActor
    func testSetActiveFalseMidTickDropsTheResultAndForgets() async {
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.client.scriptPages([page([o("ord_1", .paid)])])
        await watch.tick()
        harness.client.scriptPages([page([])])
        harness.client.scriptOrder("ord_1", .success(o("ord_1", .shipped)))
        // The seller switches service (or removes the key) while the by-ID read waits.
        harness.duringSleep = { watch.setActive(false) }
        await watch.tick()
        XCTAssertEqual(watch.badgeCount, 0)
        XCTAssertTrue(watch.state.orders.isEmpty)
        XCTAssertTrue(harness.notices.isEmpty)
        XCTAssertTrue(harness.client.idReads.isEmpty)
        // Starting again records silently.
        harness.duringSleep = nil
        watch.setActive(true)
        harness.client.scriptPages([page([o("ord_1", .shipped)])])
        await watch.tick()
        XCTAssertEqual(watch.badgeCount, 0)
        XCTAssertTrue(harness.notices.isEmpty)
    }

    @MainActor
    func testTheSellersOwnCancellationIsNoNews() async {
        var state = DapiOrderWatchState()
        _ = dapiOrderWatchApply([o("ord_1", .paid), o("ord_2", .paid)], to: &state)
        let notices = dapiOrderWatchApply([o("ord_1", .cancelled), o("ord_2", .cancelled)], to: &state,
                                          cancelledThroughPlinth: ["ord_1"])
        XCTAssertEqual(notices.map(\.orderID), ["ord_2"])
        XCTAssertEqual(state.unseen, ["ord_2": .cancelled])
        XCTAssertEqual(state.orders["ord_1"]?.status, .cancelled, "Recorded silently")
        // Through tick(): the by-ID read finds it cancelled; no badge, no notification.
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.client.scriptPages([page([o("ord_1", .paid)])])
        await watch.tick()
        harness.cancelledByPlinth = ["ord_1"]
        harness.client.scriptPages([page([])])
        harness.client.scriptOrder("ord_1", .success(o("ord_1", .cancelled)))
        await watch.tick()
        XCTAssertEqual(watch.badgeCount, 0)
        XCTAssertTrue(harness.notices.isEmpty)
    }

    @MainActor
    func testAKeyChangeForgetsTheSnapshotAndLiftsAPause() async {
        let harness = Harness()
        let watch = harness.watch
        watch.keyChanged(generation: 1) // Inactive: only noted.
        watch.setActive(true)
        harness.client.scriptPages([page([o("ord_1", .paid)])])
        await watch.tick()
        harness.client.scriptPages([page([o("ord_1", .shipped)])])
        await watch.tick()
        XCTAssertEqual(watch.badgeCount, 1)
        harness.client.scriptPages([.failure(.refused(status: 401, code: "invalid_api_key", message: nil))])
        await watch.tick()
        XCTAssertTrue(watch.paused)
        // The same generation again changes nothing.
        watch.keyChanged(generation: 1)
        XCTAssertTrue(watch.paused)
        XCTAssertEqual(watch.badgeCount, 1)
        // A new key (even one that looks like the same account): snapshot and badge forgotten, pause lifted.
        watch.keyChanged(generation: 2)
        XCTAssertFalse(watch.paused)
        XCTAssertEqual(watch.badgeCount, 0)
        XCTAssertTrue(watch.state.orders.isEmpty)
        // The new key's orders are recorded silently.
        harness.client.scriptPages([page([o("ord_1", .cancelled)])])
        await watch.tick()
        XCTAssertEqual(watch.badgeCount, 0)
        XCTAssertEqual(harness.notices.count, 1, "Only the earlier key's shipped notice")
        XCTAssertEqual(watch.state.orders["ord_1"]?.status, .cancelled)
    }

    @MainActor
    func testKeyRemovedBetweenTicksSkipsQuietly() async {
        let harness = Harness()
        let watch = harness.watch
        watch.setActive(true)
        harness.client.scriptPages([page([o("ord_1", .paid)])])
        await watch.tick()
        harness.hasClient = false
        do { let delay = await watch.tick(); XCTAssertEqual(delay, dapiOrderWatchRecheckDelay) }
        XCTAssertEqual(harness.client.queries.count, 1)
        XCTAssertNotNil(watch.state.orders["ord_1"])
    }
}
