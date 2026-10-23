import XCTest
@testable import SlantStudio

final class BatchPayTests: XCTestCase {
    private func draft(_ id: String, status: String = "DRAFT", total: Any? = "10.00", extra: [String: Any] = [:]) -> [String: Any] {
        var order: [String: Any] = ["publicId": id, "status": status]
        if let total { order["totalCost"] = total }
        order.merge(extra) { _, new in new }
        return order
    }

    private func http(_ status: Int, body: String = "") -> APIError {
        .http(status: status, body: body, retryAfter: nil, rateLimitReset: nil)
    }

    // MARK: Choosing

    func testOffersOnlyLoadedDraftsInListOrderOnce() {
        let orders = [
            Record(values: draft("a")),
            Record(values: draft("b", status: "QUEUED")),
            Record(values: draft("c", status: "draft")),
            Record(values: ["order": draft("d")])
        ]
        let ids = batchPayDraftRecords(listIDs: ["c", "b", "missing", "a", "c", "", "d"], orders: orders).map(\.id)
        // "d" is wrapped in an "order" envelope, whose Record id is empty, so it isn't offered.
        XCTAssertEqual(ids, ["c", "a"])
        XCTAssertTrue(batchPayDraftRecords(listIDs: [], orders: orders).isEmpty)
    }

    func testSelectionIsCappedAtTwenty() {
        var selection = Set<String>()
        for index in 0..<25 { selection = batchPayToggled(selection, id: "o\(index)") }
        XCTAssertEqual(selection.count, batchPayMaxDrafts)
        XCTAssertFalse(selection.contains("o20"))
        // Unticking always works, and frees a place.
        selection = batchPayToggled(selection, id: "o0")
        XCTAssertEqual(selection.count, 19)
        selection = batchPayToggled(selection, id: "o24")
        XCTAssertTrue(selection.contains("o24"))
        XCTAssertEqual(batchPayToggled(["a"], id: "a", cap: 1), [])
        XCTAssertEqual(batchPayToggled(["a"], id: "b", cap: 1), ["a"])
    }

    func testSelectAllTakesTheFirstTwentyAndOrderedSelectionFollowsTheList() {
        let ids = (0..<30).map { "o\($0)" }
        let all = batchPaySelectAll(ids)
        XCTAssertEqual(all, Set(ids.prefix(20)))
        XCTAssertEqual(batchPayOrderedSelection(["o5", "o1", "gone"], available: ids), ["o1", "o5"])
        XCTAssertEqual(batchPayOrderedSelection(Set(ids), available: ids).count, 20)
        XCTAssertEqual(batchPayOrderedSelection(["o1", "o2", "o3"], available: ids, cap: 2), ["o1", "o2"])
    }

    func testSelectionCaptionAndReviewTitle() {
        XCTAssertEqual(batchPaySelectionCaption(selected: 0, available: 1), "0 of 1 draft selected")
        XCTAssertEqual(batchPaySelectionCaption(selected: 3, available: 12), "3 of 12 drafts selected")
        XCTAssertEqual(batchPaySelectionCaption(selected: 20, available: 34), "20 of 34 drafts selected · up to 20 at a time")
        XCTAssertEqual(batchPayReviewButtonTitle(0), "Review Drafts")
        XCTAssertEqual(batchPayReviewButtonTitle(1), "Review 1 Draft")
        XCTAssertEqual(batchPayReviewButtonTitle(7), "Review 7 Drafts")
    }

    func testItemSummary() {
        let items: [[String: Any]] = [
            ["name": "Bracket", "quantity": 2], ["name": "Packing slip", "quantity": 1],
            ["name": "Hook", "quantity": 3], ["name": "Tag", "quantity": 1]
        ]
        XCTAssertEqual(batchPayItemSummary([]), "No items listed")
        XCTAssertEqual(batchPayItemSummary(Array(items.prefix(1))), "2 × Bracket")
        XCTAssertEqual(batchPayItemSummary(items), "2 × Bracket, 1 × Packing slip and 2 more")
    }

    func testLockNoticeNamesLockedOrders() {
        XCTAssertNil(batchPayLockNotice(lockedOrderNumbers: []))
        XCTAssertNil(batchPayLockNotice(lockedOrderNumbers: ["  "]))
        let one = batchPayLockNotice(lockedOrderNumbers: ["SLANT_2"]) ?? ""
        XCTAssertTrue(one.contains("order SLANT_2 didn’t confirm"))
        XCTAssertTrue(one.contains("one at a time"))
        let many = batchPayLockNotice(lockedOrderNumbers: ["d", "c", "b", "a", "e"]) ?? ""
        XCTAssertTrue(many.contains("orders a, b, c and 2 more"))
    }

    // MARK: Review

    func testEligibilityAndExclusionReasons() {
        XCTAssertNil(batchPayExclusionReason(orderID: "a", order: draft("a"), loadFailure: nil, locked: false))
        // A locked draft is never paid, whatever was loaded.
        XCTAssertNotNil(batchPayExclusionReason(orderID: "a", order: draft("a"), loadFailure: nil, locked: true))
        XCTAssertEqual(batchPayExclusionReason(orderID: "a", order: nil, loadFailure: "Check your connection and try again.", locked: false),
                       "Couldn’t load it. Check your connection and try again.")
        XCTAssertEqual(batchPayExclusionReason(orderID: "a", order: nil, loadFailure: nil, locked: false), "It wasn’t loaded.")
        XCTAssertEqual(batchPayExclusionReason(orderID: "a", order: draft("b"), loadFailure: nil, locked: false),
                       "Slant returned a different order.")
        XCTAssertEqual(batchPayExclusionReason(orderID: "a", order: draft("a", status: "QUEUED"), loadFailure: nil, locked: false),
                       "It’s no longer a draft (now In queue).")
        XCTAssertEqual(batchPayExclusionReason(orderID: "a", order: draft("a", status: ""), loadFailure: nil, locked: false),
                       "Slant didn’t return its status.")
        XCTAssertEqual(batchPayExclusionReason(orderID: "a", order: draft("a", total: nil), loadFailure: nil, locked: false),
                       "Slant didn’t return a total for it.")
        // Printing cost alone isn't a payable total (as in the single review).
        XCTAssertNotNil(batchPayExclusionReason(orderID: "a", order: draft("a", total: nil, extra: ["printingCost": "4.00"]),
                                                loadFailure: nil, locked: false))
        XCTAssertNil(batchPayExclusionReason(orderID: "a", order: draft("a", total: nil, extra: ["printingCost": "4.00", "deliveryCost": "5.00"]),
                                             loadFailure: nil, locked: false))
        // A non-numeric `total` hides a numeric totalCost from the displayed total, so it isn't paid.
        XCTAssertNotNil(batchPayExclusionReason(orderID: "a", order: draft("a", extra: ["total": "n/a"]), loadFailure: nil, locked: false))
        XCTAssertEqual(batchPayExclusionReason(orderID: "a", order: draft("a", total: "-1.00"), loadFailure: nil, locked: false),
                       "Its total isn’t a valid amount.")
    }

    func testGrandTotalIsAnExactDecimalSum() {
        let orders = [draft("a", total: "0.10"), draft("b", total: "0.20"), draft("c", total: nil, extra: ["printingCost": "1.15", "deliveryCost": "4.05"])]
        XCTAssertEqual(batchPayGrandTotal(orders), Decimal(string: "5.50"))
        XCTAssertEqual(batchPayGrandTotal([]), 0)
        XCTAssertNil(batchPayGrandTotal([draft("a"), draft("b", total: nil)]))
        let many = Array(repeating: draft("a", total: "0.10"), count: 20)
        XCTAssertEqual(batchPayGrandTotal(many), Decimal(2))
    }

    func testFinalButtonAndConfirmationTitles() {
        XCTAssertEqual(batchPayButtonTitle(count: 3, total: Decimal(string: "45.1")!), "Pay 3 Orders (Total $45.10 USD)")
        XCTAssertEqual(batchPayButtonTitle(count: 1, total: Decimal(string: "1234.5")!), "Pay 1 Order (Total $1234.50 USD)")
        XCTAssertEqual(batchPayConfirmTitle(count: 2, total: Decimal(string: "19.99")!), "Pay 2 orders for $19.99 USD?")
        XCTAssertEqual(batchPayConfirmTitle(count: 1, total: 0), "Pay 1 order for $0.00 USD?")
    }

    func testPayBlockedReasons() {
        XCTAssertNil(batchPayPayBlockedReason(payableCount: 2, totalKnown: true, busy: false, locked: false, accountChanged: false))
        XCTAssertNotNil(batchPayPayBlockedReason(payableCount: 2, totalKnown: true, busy: false, locked: true, accountChanged: false))
        XCTAssertNotNil(batchPayPayBlockedReason(payableCount: 2, totalKnown: true, busy: false, locked: false, accountChanged: true))
        XCTAssertNotNil(batchPayPayBlockedReason(payableCount: 0, totalKnown: true, busy: false, locked: false, accountChanged: false))
        XCTAssertNotNil(batchPayPayBlockedReason(payableCount: 2, totalKnown: false, busy: false, locked: false, accountChanged: false))
        XCTAssertNotNil(batchPayPayBlockedReason(payableCount: 2, totalKnown: true, busy: true, locked: false, accountChanged: false))
    }

    func testLargeQuantityNoticeCountsOrders() {
        let big = draft("a", extra: ["items": [["name": "Bracket", "quantity": 50], ["name": "Hook", "quantity": 30]]])
        let small = draft("b", extra: ["items": [["name": "Bracket", "quantity": 2]]])
        XCTAssertNil(batchPayLargeQuantityNotice([small, draft("c")]))
        XCTAssertEqual(batchPayLargeQuantityNotice([big, small]), "1 order has an item with a large quantity. Check it below.")
        XCTAssertEqual(batchPayLargeQuantityNotice([big, big]), "2 orders have an item with a large quantity. Check them below.")
    }

    // MARK: Paying

    func testPayErrorsSplitIntoRefusedAndUnknownLikeTheSingleReview() {
        for status in [400, 401, 402, 403, 404, 422, 429] {
            guard case .refused = batchPayOutcome(forPayError: http(status)) else { return XCTFail("HTTP \(status) is a definite refusal") }
        }
        XCTAssertEqual(batchPayOutcome(forPayError: http(422, body: #"{"message":"Card declined"}"#)),
                       .refused("Slant didn’t accept the payment request. Slant said: “Card declined.”"))
        if case .refused = batchPayOutcome(forPayError: APIError.invalidRequest("Bad path")) {} else { XCTFail("not sent is no effect") }
        for status in [408, 409, 500, 502, 503] {
            guard case .unknown = batchPayOutcome(forPayError: http(status)) else { return XCTFail("HTTP \(status) leaves the outcome unknown") }
        }
        if case .unknown = batchPayOutcome(forPayError: URLError(.timedOut)) {} else { XCTFail("a timeout is unknown") }
        if case .unknown = batchPayOutcome(forPayError: URLError(.networkConnectionLost)) {} else { XCTFail("transport is unknown") }
        if case .unknown = batchPayOutcome(forPayError: APIError.invalidResponse("garbled")) {} else { XCTFail("unreadable is unknown") }
    }

    func testOnlyAPlacedOrderLetsTheBatchContinue() {
        XCTAssertEqual(batchPayNextStep(after: .placed), .next)
        for outcome: BatchPayOutcome in [.changed("The price changed."), .refused("No."), .unknown("Timed out"), .notSent("Couldn’t reload it.")] {
            guard case .stop = batchPayNextStep(after: outcome) else { return XCTFail("\(outcome) must stop the batch") }
        }
        guard case .stop(let unknown) = batchPayNextStep(after: .unknown("x")) else { return XCTFail() }
        XCTAssertTrue(unknown.contains("may have been charged"))
        guard case .stop(let changed) = batchPayNextStep(after: .changed("x")) else { return XCTFail() }
        XCTAssertTrue(changed.contains("Review the drafts again"))
    }

    func testRowStatesAndText() {
        XCTAssertEqual(batchPayRowState(for: .placed), .placed)
        XCTAssertEqual(batchPayRowState(for: .changed("The price changed.")), .notPaid("The price changed. Review it again."))
        XCTAssertEqual(batchPayRowState(for: .refused("Declined.")), .refused("Declined."))
        XCTAssertEqual(batchPayRowState(for: .unknown("Timed out")), .unknown)
        XCTAssertEqual(batchPayRowState(for: .notSent("Stopped.")), .notPaid("Stopped."))
        XCTAssertEqual(batchPayStateText(.placed), "Placed")
        XCTAssertEqual(batchPayStateText(.refused("Declined.")), "Refused: Declined.")
        XCTAssertTrue(batchPayStateText(.unknown).contains("Reload it"))
        XCTAssertEqual(batchPayStateText(.notPaid("Stopped.")), "Not paid: Stopped.")
        XCTAssertEqual(batchPayStateText(.reloaded("QUEUED")), "Reloaded: now In queue.")
    }

    func testResultSummaryCountsOnly() {
        let states: [BatchPayRowState] = [.placed, .placed, .refused("x"), .unknown, .notPaid("y"), .queued, .reloaded("QUEUED")]
        let tally = batchPayTally(states)
        XCTAssertEqual(tally, BatchPayTally(placed: 2, refused: 1, unknown: 1, notPaid: 2))
        XCTAssertEqual(batchPaySummary(tally), "2 placed · 1 refused · 1 not confirmed · 2 not paid")
        XCTAssertEqual(batchPaySummary(BatchPayTally(placed: 3)), "3 placed")
        XCTAssertEqual(batchPaySummary(BatchPayTally()), "0 placed")
    }
}
