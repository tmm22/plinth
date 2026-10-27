import XCTest
@testable import SlantStudio

/// Round 14 money paths: the unknown-outcome lock's decisions after a 2xx pay, failures before sending, the created-
/// draft check, the Workbench's draft marker and batch body, the duplicate advisory and the quit question.
final class MoneyPathRound14Tests: XCTestCase {
    private func http(_ status: Int, _ body: String = "") -> APIError {
        .http(status: status, body: body, retryAfter: nil, rateLimitReset: nil)
    }

    // MARK: Failure before sending

    func testOnlyFailuresBeforeSendingProveNoEffect() {
        for code: URLError.Code in [.cannotFindHost, .dnsLookupFailed, .badURL, .unsupportedURL,
                                    .appTransportSecurityRequiresSecureConnection] {
            XCTAssertTrue(orderMutationErrorProvesNoEffect(URLError(code)), "\(code)")
        }
        for code: URLError.Code in [.notConnectedToInternet, .cannotConnectToHost, .networkConnectionLost, .timedOut,
                                    .cancelled, .secureConnectionFailed, .badServerResponse, .unknown, .dataNotAllowed] {
            XCTAssertFalse(orderMutationErrorProvesNoEffect(URLError(code)), "\(code) may have reached Slant")
        }
        // Unchanged: definite refusals lift it, everything else keeps it.
        XCTAssertTrue(orderMutationErrorProvesNoEffect(http(422)))
        XCTAssertFalse(orderMutationErrorProvesNoEffect(http(409)))
        XCTAssertFalse(orderMutationErrorProvesNoEffect(CancellationError()))
    }

    func testANeverSentCreateLeavesTheDraftGuardAsItWas() {
        let earlier = [UnconfirmedDraftAttempt(recipient: "Ada", date: Date(timeIntervalSince1970: 0))]
        let after = unconfirmedDraftAttempts(previous: earlier, attempt: .failed(URLError(.cannotFindHost)), recipient: "Bo", date: Date())
        XCTAssertEqual(after, earlier)
        let timedOut = unconfirmedDraftAttempts(previous: earlier, attempt: .failed(URLError(.notConnectedToInternet)), recipient: "Bo", date: Date())
        XCTAssertEqual(timedOut.count, 2, "no connection may still have sent part of the request")
        guard case .refused = batchPayOutcome(forPayError: URLError(.dnsLookupFailed)) else { return XCTFail("not sent") }
        guard case .unknown = batchPayOutcome(forPayError: URLError(.cannotConnectToHost)) else { return XCTFail("unknown") }
    }

    // MARK: Lock IDs and aliases

    func testLockIDsIncludeTheReturnedOrdersIDs() {
        XCTAssertEqual(orderOutcomeLockIDs(requested: "SLANT_1", order: ["publicId": "SLANT_1", "id": "abc"]), ["SLANT_1", "abc"])
        XCTAssertEqual(orderOutcomeLockIDs(requested: "slant_1", order: ["publicId": "SLANT_1"]), ["slant_1", "SLANT_1"])
        XCTAssertEqual(orderOutcomeLockIDs(requested: " SLANT_1 ", order: nil), ["SLANT_1"])
        XCTAssertEqual(orderOutcomeLockIDs(requested: "", order: ["publicId": ""]), [])
    }

    func testAliasedLockLiftsTogether() {
        var locks = OrderOutcomeLocks()
        locks.mark("slant_1", action: .pay, reviewedStatus: "draft", aliases: ["slant_1", "SLANT_1"])
        XCTAssertEqual(locks.ids, ["slant_1", "SLANT_1"])
        XCTAssertEqual(locks.contexts["SLANT_1"], UnknownOutcomeContext(action: .pay, reviewedStatus: "DRAFT"))
        XCTAssertEqual(locks.groups.count, 1)
        // The Orders review lifts it under the ID it lists; the typed one goes with it.
        locks.clear("SLANT_1")
        XCTAssertTrue(locks.ids.isEmpty)
        XCTAssertTrue(locks.contexts.isEmpty)
    }

    func testUnrelatedLocksStaySeparate() {
        var locks = OrderOutcomeLocks()
        locks.mark("A", action: .pay, reviewedStatus: "DRAFT")
        locks.mark("B", action: .cancel, reviewedStatus: "PRINTING", aliases: ["b-internal"])
        XCTAssertEqual(locks.groups.count, 2)
        locks.clear("A")
        XCTAssertEqual(locks.ids, ["B", "b-internal"])
        locks.clear("b-internal")
        XCTAssertTrue(locks.ids.isEmpty)
        // Marking again joins an existing group rather than leaving a stray ID behind.
        locks.mark("C", action: .pay, reviewedStatus: "DRAFT", aliases: ["c2"])
        locks.mark("c2", action: .pay, reviewedStatus: "DRAFT", aliases: ["c3"])
        locks.clear("C")
        XCTAssertTrue(locks.ids.isEmpty)
    }

    // MARK: After a 2xx pay

    func testOnlyKnownPlacedStatusesCountAsPlaced() {
        for status in ["SUBMITTED", "PRINTING", "SHIPPED", "printing", "PAID", "QUEUED", "DELIVERED"] {
            XCTAssertEqual(batchPayOutcomeAfterSuccess(["status": status]), .placed, status)
            XCTAssertFalse(batchPayAcceptedOutcomeStaysLocked(["status": status]), status)
        }
        for status in ["CANCELLED", "CANCELED", "cancelled", "PAYMENT_ERROR"] {
            guard case .notPlaced = batchPayOutcomeAfterSuccess(["status": status]) else { return XCTFail(status) }
            XCTAssertFalse(batchPayAcceptedOutcomeStaysLocked(["status": status]), "a definite outcome lifts the lock")
        }
        XCTAssertEqual(batchPayOutcomeAfterSuccess(["status": "on_hold"]), .unrecognised("ON_HOLD"))
        XCTAssertFalse(batchPayAcceptedOutcomeStaysLocked(["status": "ON_HOLD"]), "past DRAFT, so the lock lifts")
        XCTAssertTrue(batchPayAcceptedOutcomeStaysLocked(["status": "DRAFT"]))
        XCTAssertTrue(batchPayAcceptedOutcomeStaysLocked([:]))
    }

    func testUnrecognisedStatusStopsTheBatchAndIsNotCountedPlaced() {
        guard case .stop = batchPayNextStep(after: .unrecognised("ON_HOLD")) else { return XCTFail("must stop") }
        XCTAssertEqual(batchPayRowState(for: .unrecognised("ON_HOLD")), .unrecognised("ON_HOLD"))
        XCTAssertTrue(batchPayStateText(.unrecognised("ON_HOLD")).contains("ON_HOLD"))
        XCTAssertEqual(batchPayTally([.unrecognised("X"), .placed]), BatchPayTally(placed: 1, unknown: 1))
    }

    func testPayIsJudgedOnlyByThisOrder() {
        let draft: [String: Any] = ["publicId": "SLANT_1", "status": "DRAFT"]
        let placed: [String: Any] = ["publicId": "SLANT_1", "status": "SUBMITTED"]
        let other: [String: Any] = ["publicId": "SLANT_2", "status": "SUBMITTED"]
        XCTAssertEqual(orderPayAcceptedOrder(replied: draft, refreshed: placed, orderID: "SLANT_1")?["status"] as? String, "SUBMITTED")
        XCTAssertEqual(orderPayAcceptedOrder(replied: placed, refreshed: nil, orderID: "SLANT_1")?["status"] as? String, "SUBMITTED")
        XCTAssertEqual(orderPayAcceptedOrder(replied: draft, refreshed: other, orderID: "SLANT_1")?["status"] as? String, "DRAFT")
        XCTAssertNil(orderPayAcceptedOrder(replied: ["success": true], refreshed: other, orderID: "SLANT_1"))
    }

    func testWorkbenchPayKeepsTheLockLikeTheOrdersReview() {
        let draft: [String: Any] = ["publicId": "SLANT_1", "status": "DRAFT"]
        let placed: [String: Any] = ["publicId": "SLANT_1", "status": "PRINTING"]
        // Still a draft after the re-read: the charge may still happen.
        XCTAssertTrue(workbenchPayAcceptedKeepsLock(replied: placed, refreshed: draft, requested: "SLANT_1"))
        // The re-read failed: the reply decides.
        XCTAssertFalse(workbenchPayAcceptedKeepsLock(replied: placed, refreshed: nil, requested: "SLANT_1"))
        XCTAssertTrue(workbenchPayAcceptedKeepsLock(replied: draft, refreshed: nil, requested: "SLANT_1"))
        // An empty 2xx body and a failed re-read: nothing shows the outcome.
        XCTAssertTrue(workbenchPayAcceptedKeepsLock(replied: [:], refreshed: nil, requested: "SLANT_1"))
        XCTAssertTrue(workbenchPayAcceptedKeepsLock(replied: nil, refreshed: nil, requested: "SLANT_1"))
        // Another order's status never counts.
        XCTAssertTrue(workbenchPayAcceptedKeepsLock(replied: [:], refreshed: ["publicId": "SLANT_9", "status": "PRINTING"], requested: "SLANT_1"))
        // A cancelled reply is definite: the lock lifts, but it isn't placed.
        XCTAssertFalse(workbenchPayAcceptedKeepsLock(replied: [:], refreshed: ["publicId": "SLANT_1", "status": "CANCELLED"], requested: "SLANT_1"))
        // A typed ID in another case still names the order Slant routed it to.
        XCTAssertFalse(workbenchPayAcceptedKeepsLock(replied: [:], refreshed: placed, requested: "slant_1"))
    }

    func testWorkbenchOrderMatch() {
        XCTAssertTrue(workbenchOrderMatchesRequestedID(["publicId": "SLANT_1"], requested: "SLANT_1"))
        XCTAssertTrue(workbenchOrderMatchesRequestedID(["publicId": "SLANT_1"], requested: "slant_1"))
        XCTAssertTrue(workbenchOrderMatchesRequestedID(["id": "abc"], requested: "abc"))
        XCTAssertFalse(workbenchOrderMatchesRequestedID(["publicId": "SLANT_2"], requested: "SLANT_1"))
        XCTAssertFalse(workbenchOrderMatchesRequestedID([:], requested: "SLANT_1"))
        XCTAssertFalse(workbenchOrderMatchesRequestedID(["publicId": ""], requested: ""))
    }

    func testSinglePayMessagesNeverClaimANotPlacedOrderWasPlaced() {
        XCTAssertEqual(orderPayAcceptedMessage(.placed), "Order placed.")
        let cancelled = orderPayAcceptedMessage(batchPayOutcomeAfterSuccess(["status": "CANCELLED"])) ?? ""
        XCTAssertTrue(cancelled.contains("wasn’t placed"))
        XCTAssertFalse(cancelled.contains("Order placed"))
        let paymentProblem = orderPayAcceptedMessage(batchPayOutcomeAfterSuccess(["status": "PAYMENT_ERROR"])) ?? ""
        XCTAssertTrue(paymentProblem.contains("payment problem"))
        XCTAssertTrue((orderPayAcceptedMessage(.unrecognised("ON_HOLD")) ?? "").contains("ON_HOLD"))
        XCTAssertNil(orderPayAcceptedMessage(.unclear))
        // Activity never records "Completed" for an accepted pay that wasn't placed.
        XCTAssertEqual(orderPayActivityDetail(.placed), "Completed")
        for outcome: BatchPayOutcome in [.unclear, .unrecognised("X"), .notPlaced("Slant shows it as cancelled."),
                                         batchPayOutcomeAfterSuccess(["status": "DRAFT"])] {
            XCTAssertNotEqual(orderPayActivityDetail(outcome), "Completed", "\(outcome)")
        }
    }

    // MARK: Created drafts

    func testACreatedDraftNeedsAPublicIDOrID() {
        XCTAssertEqual(orderCreatedID(["publicId": " SLANT_1 ", "name": "x"]), "SLANT_1")
        XCTAssertEqual(orderCreatedID(["publicId": "", "id": "abc"]), "abc")
        XCTAssertEqual(orderCreatedID(["id": 42]), "42")
        XCTAssertNil(orderCreatedID(["name": "Order for Ada"]))
        XCTAssertNil(orderCreatedID(["id": true]))
        XCTAssertNil(orderCreatedID(["publicId": NSNull()]))
        XCTAssertNil(orderCreatedID([:]))
        guard case .unknown = orderImportOutcome(response: ["order": ["name": "Order"]]) else { return XCTFail("a name isn't an order number") }
        XCTAssertEqual(orderImportOutcome(response: ["order": ["id": "abc"]]), .created(orderID: "abc"))
    }

    func testComposerCreateFailureNeverSaysTryAgainWhenTheDraftMayExist() {
        for error: Error in [URLError(.timedOut), URLError(.networkConnectionLost), http(500), http(503), http(408), http(409),
                             StudioError("Slant didn’t return an order number."), APIError.invalidResponse("bad")] {
            let message = orderComposerCreateFailureMessage(error)
            XCTAssertTrue(message.contains("may have been created"), "\(error): \(message)")
            XCTAssertFalse(message.lowercased().contains("try again"), "\(error): \(message)")
        }
        XCTAssertTrue(orderComposerCreateFailureMessage(URLError(.timedOut)).hasPrefix("Slant didn’t reply in time"))
        XCTAssertTrue(orderComposerCreateFailureMessage(http(503)).contains("HTTP 503"))
        // A definite refusal quotes Slant; a failure before sending says nothing was created.
        let refused = orderComposerCreateFailureMessage(http(400, #"{"success":false,"error":{"message":"Invalid address","statusCode":400}}"#))
        XCTAssertTrue(refused.hasPrefix("Slant didn’t create the draft."), refused)
        XCTAssertFalse(orderComposerCreateFailureMessage(URLError(.cannotFindHost)).contains("may have been created"))
    }

    // MARK: Workbench draft create and batch

    func testWorkbenchDraftBodyGetsTheComposersMarker() throws {
        let body: [String: Any] = ["platformId": "p", "customer": ["details": ["address": ["name": " Ada "]]], "metadata": ["note": "x"]]
        let (marked, marker) = workbenchDraftBodyAddingMarker(body, marker: "ABC-1")
        XCTAssertEqual(marker, "abc-1")
        let metadata = try XCTUnwrap((marked as? [String: Any])?["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["studioDraftId"] as? String, "ABC-1")
        XCTAssertEqual(metadata["note"] as? String, "x")
        XCTAssertEqual(orderDraftBodyRecipient(marked), "Ada")
        // No metadata yet: one is added.
        let (bare, bareMarker) = workbenchDraftBodyAddingMarker(["platformId": "p"], marker: "m")
        XCTAssertEqual(((bare as? [String: Any])?["metadata"] as? [String: Any])?["studioDraftId"] as? String, "m")
        XCTAssertEqual(bareMarker, "m")
    }

    func testWorkbenchDraftBodyIsLeftAloneWithoutRoom() {
        var full: [String: Any] = [:]
        for index in 0..<10 { full["k\(index)"] = "v" }
        let (unchanged, none) = workbenchDraftBodyAddingMarker(["metadata": full], marker: "m")
        XCTAssertNil(none)
        XCTAssertEqual(((unchanged as? [String: Any])?["metadata"] as? [String: Any])?.count, 10)
        XCTAssertNil(workbenchDraftBodyAddingMarker(["metadata": "text"], marker: "m").marker)
        XCTAssertNil(workbenchDraftBodyAddingMarker(["metadata": ["studioDraftId": "mine"]], marker: "m").marker,
                     "the seller's own value under the key is never remembered")
        XCTAssertNil(workbenchDraftBodyAddingMarker([1, 2], marker: "m").marker)
        XCTAssertEqual(orderDraftBodyRecipient(nil), "")
    }

    func testOrdersBatchReplyShapes() {
        XCTAssertEqual(ordersBatchReplyOrders(["data": [["publicId": "A"], ["publicId": "B"]]])?.compactMap { $0["publicId"] as? String }, ["A", "B"])
        XCTAssertEqual(ordersBatchReplyOrders(["data": [["order": ["publicId": "A"]]]])?.first?["publicId"] as? String, "A")
        XCTAssertNil(ordersBatchReplyOrders(["data": ["publicId": "A"]]))
        XCTAssertNil(ordersBatchReplyOrders(nil))
    }

    // MARK: Duplicate advisory

    private func order(_ id: String, status: String, source: String? = "etsy", sourceOrderID: String? = "314") -> Record {
        var metadata: [String: Any] = [:]
        if let source { metadata["source"] = source }
        if let sourceOrderID { metadata["sourceOrderId"] = sourceOrderID }
        return Record(values: ["publicId": id, "status": status, "metadata": metadata])
    }

    func testDuplicateAdvisoryNamesAPlacedOrderOrAnotherDraft() {
        let reviewed = order("D1", status: "DRAFT").values
        let placed = orderReviewMarketplaceDuplicateNotice(reviewed, orderID: "D1", loaded: [order("D1", status: "DRAFT"), order("P1", status: "PRINTING")])
        XCTAssertEqual(placed, "Etsy order 314 already has a placed order, so this draft may be a duplicate.")
        let otherDraft = orderReviewMarketplaceDuplicateNotice(reviewed, orderID: "D1", loaded: [order("D1", status: "DRAFT"), order("D2", status: "DRAFT")])
        XCTAssertEqual(otherDraft, "Another loaded draft is also for Etsy order 314. Check this isn’t a duplicate.")
    }

    func testDuplicateAdvisoryIgnoresItselfCancellationsAndOtherSales() {
        let reviewed = order("D1", status: "DRAFT").values
        XCTAssertNil(orderReviewMarketplaceDuplicateNotice(reviewed, orderID: "D1", loaded: [order("D1", status: "DRAFT")]))
        XCTAssertNil(orderReviewMarketplaceDuplicateNotice(reviewed, orderID: "D1", loaded: [order("C1", status: "CANCELLED")]))
        XCTAssertNil(orderReviewMarketplaceDuplicateNotice(reviewed, orderID: "D1", loaded: [order("P1", status: "SHIPPED", sourceOrderID: "999")]))
        XCTAssertNil(orderReviewMarketplaceDuplicateNotice(reviewed, orderID: "D1", loaded: [order("P1", status: "SHIPPED", source: "shopify")]))
        let unreferenced = order("D1", status: "DRAFT", source: nil, sourceOrderID: nil).values
        XCTAssertNil(orderReviewMarketplaceDuplicateNotice(unreferenced, orderID: "D1", loaded: [order("P1", status: "PRINTING", source: nil, sourceOrderID: nil)]))
    }

    // MARK: Quitting

    func testQuitAsksOnlyWhileAWriteIsInFlight() throws {
        XCTAssertNil(slantWritesQuitQuestion([]))
        let one = try XCTUnwrap(slantWritesQuitQuestion([.payment]))
        XCTAssertTrue(one.message.contains("reply to a payment."))
        let several = try XCTUnwrap(slantWritesQuitQuestion([.payDrafts, .draft, .payment, .payment]))
        XCTAssertTrue(several.message.contains("a payment, a new draft and Pay Several Drafts"), several.message)
    }
}
