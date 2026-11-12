import XCTest
@testable import Plinth

/// Round 22: the order detail's Refresh Order lifts a pay/cancel lock by the review's own rule, the lock caption's
/// wording, the review's note after its own reload, and list state committed only after a read succeeds.
final class OrderLockRefreshRound22Tests: XCTestCase {
    // MARK: One rule for every by-ID reload

    /// The IDs a reload of `order` (read by `requested`) lifts, with the closures backed by a real lock value.
    private func lifted(_ locks: OrderOutcomeLocks, requested: String, order: [String: Any]) -> [String] {
        orderOutcomeLockIDsResolvedByReload(requested: requested, order: order,
                                            isLocked: { locks.ids.contains($0) }, context: { locks.contexts[$0] })
    }
    private func order(_ id: String, status: String?) -> [String: Any] {
        var order: [String: Any] = ["publicId": id]
        if let status { order["status"] = status }
        return order
    }

    func testACancelSentFromSubmittedLiftsOnceSlantShowsItCancelled() {
        var locks = OrderOutcomeLocks()
        locks.mark("SLANT_1", action: .cancel, reviewedStatus: "SUBMITTED")
        XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: "CANCELLED")), ["SLANT_1"])
        XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: " cancelled ")), ["SLANT_1"])
        // Unchanged: the reload can't show whether the cancel took effect.
        XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: "SUBMITTED")), [])
    }

    func testACancelSentWhileBeingMadeIsNotLiftedByShipping() {
        // Owner decision, 30 Oct 2026: an order being made ships whether or not a refund was asked for.
        for reviewed in ["PRINTING", "SUBMITTED"] {
            var locks = OrderOutcomeLocks()
            locks.mark("SLANT_1", action: .cancel, reviewedStatus: reviewed)
            for reloaded in ["SHIPPED", " shipped ", "DELIVERED"] {
                XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: reloaded)), [],
                               "\(reviewed) → \(reloaded)")
            }
            // Slant then showing it cancelled does lift it, as the shipped-since note promises.
            XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: "CANCELLED")), ["SLANT_1"])
        }
    }

    func testAPayIsLiftedOnlyOnceTheOrderLeavesDraft() {
        var locks = OrderOutcomeLocks()
        locks.mark("SLANT_1", action: .pay, reviewedStatus: "DRAFT")
        for status in ["DRAFT", " draft ", "", "  "] {
            XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: status)), [], "'\(status)'")
        }
        XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: nil)), [], "no status")
        XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: ["publicId": "SLANT_1", "status": 3]), [],
                       "an unreadable status")
        for status in ["SUBMITTED", "PAYMENT_ERROR", "CANCELLED"] {
            XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: status)), ["SLANT_1"], status)
        }
    }

    func testALockWithoutARecordOfTheAttemptStays() {
        var locks = OrderOutcomeLocks()
        locks.mark("SLANT_1", action: nil, reviewedStatus: nil)
        locks.mark("SLANT_2", action: .cancel, reviewedStatus: "")
        XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: "CANCELLED")), [])
        XCTAssertEqual(lifted(locks, requested: "SLANT_2", order: order("SLANT_2", status: "CANCELLED")), [])
    }

    func testOnlyTheReloadedOrdersLockIsConsidered() {
        var locks = OrderOutcomeLocks()
        locks.mark("SLANT_2", action: .pay, reviewedStatus: "DRAFT")
        XCTAssertEqual(lifted(locks, requested: "SLANT_1", order: order("SLANT_1", status: "SUBMITTED")), [])
        XCTAssertEqual(lifted(OrderOutcomeLocks(), requested: "SLANT_1", order: order("SLANT_1", status: "SUBMITTED")), [])
    }

    func testAWorkbenchAliasGroupIsFoundAndClearedThroughTheOrdersOwnID() {
        // The Workbench locked the typed lower-case ID and the publicId Slant returned for it.
        var locks = OrderOutcomeLocks()
        locks.mark("slant_x", action: .cancel, reviewedStatus: "SUBMITTED", aliases: ["SLANT_X"])
        let ids = lifted(locks, requested: "SLANT_X", order: order("SLANT_X", status: "CANCELLED"))
        XCTAssertEqual(ids, ["SLANT_X"])
        for id in ids { locks.clear(id) }
        XCTAssertTrue(locks.ids.isEmpty, "lifting any ID of the order lifts all of them")
        // An order whose internal `id` is the locked one is found through it too.
        var other = OrderOutcomeLocks()
        other.mark("internal-7", action: .pay, reviewedStatus: "DRAFT")
        XCTAssertEqual(lifted(other, requested: "SLANT_7", order: ["publicId": "SLANT_7", "id": "internal-7", "status": "SUBMITTED"]),
                       ["internal-7"])
    }

    func testTheDetailAndTheReviewLiftThroughTheSharedHelper() throws {
        let view = try source("OrdersView.swift")
        // The detail's load: the lift sits right after the check that the reply is this order.
        let load = try XCTUnwrap(view.range(of: "func load(_ id: String) {"))
        let loadBody = String(view[load.lowerBound...].prefix(900))
        let belongs = try XCTUnwrap(loadBody.range(of: "guard orderBelongs(order, to: id)"))
        let lift = try XCTUnwrap(loadBody.range(of: "store.liftOutcomeLocksResolvedByReload(requested: id, order: order)"))
        XCTAssertLessThan(belongs.lowerBound, lift.lowerBound)
        // The review's reload uses the same helper, never its own copy of the rule.
        let reload = try XCTUnwrap(view.range(of: "func loadFresh(keepUnknownMessage: Bool = false) {"))
        let confirm = try XCTUnwrap(view.range(of: "func confirmAction() {"))
        let reloadBody = String(view[reload.lowerBound..<confirm.lowerBound])
        XCTAssertTrue(reloadBody.contains("store.liftOutcomeLocksResolvedByReload(requested: orderID, order: loaded)"))
        XCTAssertFalse(reloadBody.contains("unknownOutcomeResolvedByReload("))
    }

    // MARK: The lock's caption

    func testTheDuplicateCaptionDoesNotSayRefreshWhereARefreshCantLiftTheLock() {
        let cancelWhileMade = UnknownOutcomeContext(action: .cancel, reviewedStatus: "PRINTING")
        func reason(_ context: UnknownOutcomeContext?, _ status: String?) -> String? {
            orderDuplicateBlockedReason(draftBlockedReason: nil, composerOpen: false, outcomeUnknown: true, busy: false,
                                        lockContext: context, currentStatus: status)
        }
        XCTAssertEqual(reason(cancelWhileMade, "SHIPPED"), unknownOutcomeShippedSinceCancelMessage)
        XCTAssertEqual(reason(cancelWhileMade, "PRINTING"), unknownOutcomeBlockMessage)
        XCTAssertEqual(reason(cancelWhileMade, nil), unknownOutcomeBlockMessage)
        XCTAssertEqual(reason(UnknownOutcomeContext(action: .pay, reviewedStatus: "DRAFT"), "SHIPPED"), unknownOutcomeBlockMessage)
        XCTAssertEqual(reason(nil, "SHIPPED"), unknownOutcomeBlockMessage)
        // Unlocked, or blocked for another reason first: unchanged.
        XCTAssertNil(orderDuplicateBlockedReason(draftBlockedReason: nil, composerOpen: false, outcomeUnknown: false, busy: false,
                                                 lockContext: cancelWhileMade, currentStatus: "SHIPPED"))
        XCTAssertEqual(orderDuplicateBlockedReason(draftBlockedReason: "Connect your account first.", composerOpen: false,
                                                   outcomeUnknown: true, busy: false, lockContext: cancelWhileMade,
                                                   currentStatus: "SHIPPED"), "Connect your account first.")
        // Every caption that says to refresh is one a refresh can now lift.
        XCTAssertTrue(unknownOutcomeBlockMessage.contains("Refresh the order"))
        XCTAssertFalse(unknownOutcomeShippedSinceCancelMessage.localizedCaseInsensitiveContains("refresh"))
    }

    // MARK: The review's note after its own Refresh Order

    func testTheReviewSaysWhatSlantShowsOnceItsReloadLiftedTheLock() {
        XCTAssertEqual(orderReviewNoteAfterReload(writeAttempted: true, lockHeld: false, rawStatus: "SUBMITTED"),
                       "Refreshed: Slant now lists this order as “Submitted”.")
        XCTAssertEqual(orderReviewNoteAfterReload(writeAttempted: true, lockHeld: false, rawStatus: " CANCELLED "),
                       workbenchReloadResolvedNote(status: "CANCELLED"))
        // Still locked: the earlier "result is unknown" note stays.
        XCTAssertNil(orderReviewNoteAfterReload(writeAttempted: true, lockHeld: true, rawStatus: "SUBMITTED"))
        // Nothing sent from this review: no note about a result.
        XCTAssertNil(orderReviewNoteAfterReload(writeAttempted: false, lockHeld: false, rawStatus: "SUBMITTED"))
        // No status to name.
        for status in [nil, "", "  "] as [String?] {
            XCTAssertNil(orderReviewNoteAfterReload(writeAttempted: true, lockHeld: false, rawStatus: status))
        }
    }

    func testTheUnknownResultCaptionShowsOnlyWhileTheLockHolds() throws {
        let view = try source("OrdersView.swift")
        XCTAssertTrue(view.contains("writeAttempted ? (sharedOutcomeLock ? mutationLock.1 : nil) : unknownOutcomeLockMessage("))
    }

    func testAnUnclearPayOrCancelNeverTellsActivityToTryAgain() throws {
        let errors: [Error] = [URLError(.timedOut), URLError(.networkConnectionLost), CancellationError(),
                               APIError.http(status: 503, body: "", retryAfter: nil, rateLimitReset: nil),
                               APIError.invalidResponse("The API reported a failure (HTTP 200)")]
        for error in errors {
            let detail = activityDetail(for: StudioError(slantUnclearReplyCause(error) + ", so the result is unknown."))
            XCTAssertFalse(detail.localizedCaseInsensitiveContains("try again"), detail)
            XCTAssertTrue(detail.hasSuffix(", so the result is unknown."), detail)
        }
        let view = try source("OrdersView.swift")
        XCTAssertTrue(view.contains("throw StudioError(slantUnclearReplyCause(error) + \", so the result is unknown.\")"))
    }

    // MARK: List state only after a read succeeds

    func testClearingTheSearchAndChangingTheFilterCommitNothingBeforeTheRead() throws {
        let store = try source("StudioStore.swift")
        let search = try XCTUnwrap(store.range(of: "func searchOrders(_ text: String) async {"))
        let apply = try XCTUnwrap(store.range(of: "func applyOrderFilter(_ filter: OrderFilter) async -> Bool {"))
        let more = try XCTUnwrap(store.range(of: "func loadMoreOrders() async {"))
        let searchBody = String(store[search.lowerBound..<apply.lowerBound])
        let clearBranch = String(searchBody[..<(try XCTUnwrap(searchBody.range(of: "var restoreList = false")).lowerBound)])
        XCTAssertTrue(clearBranch.contains("guard !busy else { return }"))
        for assignment in ["orders = ", "orderSearchActive = ", "orderPage = ", "ordersHasMore = "] {
            XCTAssertFalse(clearBranch.contains(assignment), "clearing must not set \(assignment)before the reload")
        }
        let applyBody = String(store[apply.lowerBound..<more.lowerBound])
        let request = try XCTUnwrap(applyBody.range(of: "try await client.request(\"GET\", path: \"/orders\""))
        let commit = try XCTUnwrap(applyBody.range(of: "orderFilter = filter"))
        XCTAssertLessThan(request.lowerBound, commit.lowerBound, "the filter changes only with its rows")
        XCTAssertEqual(applyBody.components(separatedBy: "orderFilter = filter").count, 2, "assigned once")
    }

    func testAClearOrFilterChangeThatCouldntReadKeepsImportsDuplicateCheckReading() {
        // A lookup's result is listed; the clear is skipped (busy) or its reload fails: the search stays active, so
        // Import Orders still treats the list as partial and reads recent orders.
        XCTAssertNotNil(orderImportDuplicateCoverageNotice(ordersLoaded: true, ordersHasMore: false, listIsPartial: true))
        // A Status change SHIPPED → All whose read failed keeps SHIPPED, whose rows it still shows.
        var shipped = OrderFilter()
        shipped.status = "SHIPPED"
        XCTAssertTrue(shipped.isActive)
        XCTAssertNotNil(orderImportDuplicateCoverageNotice(ordersLoaded: true, ordersHasMore: false,
                                                           listIsPartial: false || shipped.isActive))
    }

    func testImportWaitsOutTheRecentOrdersReadsRateLimit() throws {
        let importSource = try source("OrderImport.swift")
        XCTAssertTrue(importSource.contains("var rateLimitedUntil: Date? = recentOrdersRateLimitedUntil"))
        // It only adds a wait, and one too long stops before anything is sent.
        let now = Date()
        XCTAssertEqual(orderImportPacing(lastRequestStart: nil, rateLimit: nil, rateLimitedUntil: now.addingTimeInterval(60), now: now),
                       .wait(60))
        XCTAssertEqual(orderImportPacing(lastRequestStart: nil, rateLimit: nil, rateLimitedUntil: now.addingTimeInterval(-5), now: now),
                       .wait(0))
        if case .wait = orderImportPacing(lastRequestStart: nil, rateLimit: nil,
                                          rateLimitedUntil: now.addingTimeInterval(orderImportMaxWait + 1), now: now) {
            XCTFail("a wait past the limit stops instead")
        }
    }

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }
}
