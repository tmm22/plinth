import XCTest
@testable import SlantStudio

/// Round 13 orders fixes: the live SUBMITTED status, inline failures, Paste Address's address check, the review run,
/// readable tracking values, the margin's minus sign and order watch's hold caption.
final class OrdersRound13Tests: XCTestCase {
    // MARK: SUBMITTED (seen live 26 Oct 2026, not in the bundled OpenAPI)

    func testSubmittedIsAPlacedCancellableStatusEverywhere() {
        XCTAssertTrue(orderKnownStatuses.contains("SUBMITTED"))
        XCTAssertEqual(orderStatusTitle("SUBMITTED"), "Submitted")
        XCTAssertEqual(orderStatusTitle("submitted"), "Submitted")
        XCTAssertTrue(orderCanRequestCancellation("SUBMITTED"))
        XCTAssertNil(orderCancellationBlockedReason("SUBMITTED"))
        XCTAssertFalse(orderCancellationIsRefundOnly("SUBMITTED"))
        XCTAssertEqual(orderCancelActionTitle("SUBMITTED"), "Cancel & Refund…")
        XCTAssertEqual(orderCancelSheetBody("SUBMITTED"), orderCancelSheetBody("PAID"))
        XCTAssertNil(orderDetailCancelBlockedNote("SUBMITTED"))
        // Toolbar Status menu: right after Draft (Slant's live order).
        XCTAssertEqual(orderStatusFilterOptions.firstIndex(of: "SUBMITTED"), 1)
        // Counted spend, Needs attention's not-shipped rule, tracking and Report a Problem's Late.
        XCTAssertTrue(spendReportCountedStatuses.contains("SUBMITTED"))
        XCTAssertTrue(orderAttentionProductionStatuses.contains("SUBMITTED"))
        XCTAssertTrue(orderDetailShowsTracking(status: "SUBMITTED", hasTrackingDetails: false))
        XCTAssertTrue(orderProblemKinds(status: "SUBMITTED").contains(.late))
        XCTAssertTrue(orderOffersProblemReport(status: "SUBMITTED"))
    }

    func testCancelRecheckAcceptsAnUnchangedSubmittedOrderOnly() {
        let shown: [String: Any] = ["status": "SUBMITTED", "total": "75.42"]
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shown, latest: shown), .proceed)
        let moved: [String: Any] = ["status": "QUEUED", "total": "75.42"]
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shown, latest: moved),
                       .statusBlocked("This order’s status changed. Review it again."))
        // Pay still needs DRAFT.
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: shown, latest: shown), .statusBlocked("Only drafts can be placed."))
        XCTAssertTrue(orderConfirmFinalActionEnabled(writeSucceeded: false, loaded: true, status: "SUBMITTED", isPay: false))
        XCTAssertFalse(orderConfirmFinalActionEnabled(writeSucceeded: false, loaded: true, status: "SUBMITTED", isPay: true))
    }

    func testBatchPayCountsSubmittedAsPlacedAndStillStopsOnUnreadable() {
        XCTAssertEqual(batchPayOutcomeAfterSuccess(["status": "SUBMITTED"]), .placed)
        XCTAssertFalse(batchPayAcceptedOutcomeStaysLocked(["status": "SUBMITTED"]))
        XCTAssertEqual(batchPayOutcomeAfterSuccess(nil), .unclear)
        XCTAssertEqual(batchPayOutcomeAfterSuccess(["status": ""]), .unclear)
        XCTAssertTrue(batchPayAcceptedOutcomeStaysLocked([:]))
        let placed = batchPayPlacedMarketplaceKeys([
            Record(values: ["id": "S", "status": "SUBMITTED", "metadata": ["source": "etsy", "sourceOrderId": "99"]])
        ])
        XCTAssertEqual(placed, ["etsy|99||"])
    }

    func testOrderWatchTreatsSubmittedAsPlacing() {
        XCTAssertFalse(orderWatchChangeIsReported(from: "DRAFT", to: "PAID"))
        XCTAssertFalse(orderWatchChangeIsReported(from: "DRAFT", to: "SUBMITTED"))
        XCTAssertFalse(orderWatchChangeIsReported(from: "SUBMITTED", to: "PAID"))
        XCTAssertTrue(orderWatchChangeIsReported(from: "SUBMITTED", to: "QUEUED"))
        XCTAssertTrue(orderWatchChangeIsReported(from: "SUBMITTED", to: "CANCELED"))
        XCTAssertFalse(orderWatchChangeIsReported(from: "PAID", to: "SUBMITTED"))
        XCTAssertFalse(orderWatchNotableStatuses.contains("SUBMITTED"))
    }

    func testSpendReportCountsSubmittedAndNamesUnrecognisedStatuses() {
        func order(_ id: String, _ status: String) -> Record {
            Record(values: ["id": id, "publicId": id, "status": status, "createdAt": "2026-10-26T10:00:00Z", "total": "75.42"])
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let report = spendReport(orders: [order("A", "SUBMITTED"), order("B", "PAYMENT_ERROR"), order("C", "ON_HOLD"),
                                          order("D", "REFUNDED"), order("E", "LOST"), order("F", "HELD")], calendar: calendar)
        XCTAssertEqual(report.countedOrders, 1)
        XCTAssertEqual(report.totalSpend, Decimal(string: "75.42"))
        XCTAssertEqual(report.excludedPaymentProblems, 1)
        XCTAssertEqual(report.excludedUnrecognised, 4)
        XCTAssertEqual(spendReportExclusionLine(report),
                       "Left out: 1 order with a payment problem, 4 orders with a status Studio doesn’t recognise (HELD, LOST, ON_HOLD and 1 more).")
        XCTAssertFalse(spendReportExclusionLine(report)?.contains("payment error") == true)
        XCTAssertEqual(spendReportUnrecognisedStatusNames([]), "")
        XCTAssertEqual(spendReportUnrecognisedStatusNames(["X"]), " (X)")
    }

    // MARK: Inline failures

    func testComposerCreateFailureQuotesADefiniteRefusal() {
        let refused = APIError.http(status: 422, body: #"{"message":"Invalid postcode"}"#, retryAfter: nil, rateLimitReset: nil)
        XCTAssertEqual(orderComposerCreateFailureMessage(refused), "Slant didn’t create the draft. Slant said: “Invalid postcode.”")
        let unknown = APIError.http(status: 503, body: "", retryAfter: nil, rateLimitReset: nil)
        XCTAssertFalse(orderComposerCreateFailureMessage(unknown).isEmpty)
        XCTAssertFalse(orderComposerCreateFailureMessage(unknown).contains("didn’t create"), "A 5xx is unknown, not a refusal")
        // Round 14: a reply without an order number leaves the outcome unknown, so the note says the draft may exist.
        XCTAssertEqual(orderComposerCreateFailureMessage(StudioError("Slant didn’t return an order number.")),
                       "Slant’s reply didn’t confirm the draft, so this draft may have been created. Check the notice at the "
                       + "top of this form before creating it again.")
    }

    func testLookForDraftFailureSaysNothingWasConfirmed() {
        XCTAssertEqual(draftMarkerSearchFailureText("Check your connection and try again."),
                       "Couldn’t look on Slant, so nothing was confirmed. Check your connection and try again.")
        XCTAssertEqual(draftMarkerSearchFailureText("  "), "Couldn’t look on Slant, so nothing was confirmed.")
    }

    func testEscapeThatClosedAPopoverDoesNotCloseTheComposer() {
        let now = Date()
        XCTAssertFalse(composerCancelFollowsPopoverClose(closedAt: nil, now: now))
        XCTAssertTrue(composerCancelFollowsPopoverClose(closedAt: now, now: now))
        XCTAssertTrue(composerCancelFollowsPopoverClose(closedAt: now.addingTimeInterval(-0.1), now: now))
        XCTAssertFalse(composerCancelFollowsPopoverClose(closedAt: now.addingTimeInterval(-1), now: now))
        XCTAssertFalse(composerCancelFollowsPopoverClose(closedAt: now.addingTimeInterval(5), now: now))
    }

    // MARK: Paste Address

    func testOnlyAddressLikeTextCanBeUsed() {
        let token = "aB3x9Qz7Lm2Vt8Kp4Rw6Yn1Hs5Jd0Fg3Cb7Ne2Mq9Pu4Xe6Wa8Zk1Ti5Ol3Gy7Rh2Sv0Df9Lp4Qm6Bn8Vc1Xz3Kj5Hg7Fd2Sa4"
        XCTAssertFalse(pastedAddressLooksLikeAddress(parsePastedAddressDetecting(token)))
        XCTAssertFalse(pastedAddressLooksLikeAddress(parsePastedAddressDetecting("https://example.com/some/long/path")))
        XCTAssertFalse(pastedAddressLooksLikeAddress(parsePastedAddressDetecting("Ada Lovelace\n12 Main St")),
                       "A street alone, with no town or postcode, would clear the form's town and postcode")
        XCTAssertTrue(pastedAddressLooksLikeAddress(parsePastedAddressDetecting("""
        Ada Lovelace
        12 Main St
        Springfield, IL 62701
        United States
        """)))
        XCTAssertTrue(pastedAddressLooksLikeAddress(PastedAddress(line1: "Rosebank", city: "Ballymore", zip: "N91 X2Y3")),
                      "A house name as the street is fine with a town and postcode")
        XCTAssertFalse(pastedAddressLooksLikeAddress(PastedAddress(line1: String(repeating: "x", count: 40), city: "Springfield")))
        XCTAssertFalse(pastedAddressLooksLikeAddress(PastedAddress()))
    }

    func testClipboardThatIsNotAnAddressIsNeverShown() {
        let token = "aB3x9Qz7Lm2Vt8Kp4Rw6Yn1Hs5Jd0Fg3Cb7Ne2Mq9Pu4Xe6Wa8Zk1Ti5Ol3Gy7Rh2Sv0Df9Lp4Qm6Bn8Vc1Xz3Kj5Hg7Fd2Sa4"
        let skipped = addressPasteClipboardPrefill(token)
        XCTAssertEqual(skipped.text, "")
        XCTAssertTrue(skipped.skippedNonAddress)
        let address = "Ada Lovelace\n12 Main St\nSpringfield, IL 62701"
        let kept = addressPasteClipboardPrefill(address)
        XCTAssertEqual(kept.text, address)
        XCTAssertFalse(kept.skippedNonAddress)
        XCTAssertEqual(addressPasteClipboardPrefill(nil).text, "")
        XCTAssertFalse(addressPasteClipboardPrefill(nil).skippedNonAddress)
        XCTAssertFalse(addressPasteClipboardPrefill(address, holdsFileURL: true).skippedNonAddress)
    }

    // MARK: Review Drafts One by One…

    func testReviewRunCountsUnlockedDraftsInListOrder() {
        let rows: [(id: String, status: String)] = [
            (id: "A", status: "DRAFT"), (id: "B", status: "PAID"), (id: "C", status: "draft"),
            (id: "L", status: "DRAFT"), (id: "C", status: "DRAFT"), (id: "", status: "DRAFT"), (id: "E", status: "DRAFT")
        ]
        let ids = orderReviewRunDraftIDs(rows: rows, isLocked: { $0 == "L" })
        XCTAssertEqual(ids, ["A", "C", "E"])
        XCTAssertEqual(orderReviewRunPositionText(draftIDs: ids, current: "C"), "Draft 2 of 3")
        XCTAssertNil(orderReviewRunPositionText(draftIDs: ids, current: "B"))
        XCTAssertNil(orderReviewRunPositionText(draftIDs: ["A"], current: "A"), "A single draft needs no count")
    }

    func testNextDraftIsOfferedBeforePayOnlyInARunAndNeverMidPay() {
        // After a confirmed payment: always (as before).
        XCTAssertTrue(orderReviewOffersNextDraft(inRun: false, writeSucceeded: true, writeAttempted: true, writing: false))
        // Skip during a run, before Pay.
        XCTAssertTrue(orderReviewOffersNextDraft(inRun: true, writeSucceeded: false, writeAttempted: false, writing: false))
        XCTAssertFalse(orderReviewOffersNextDraft(inRun: false, writeSucceeded: false, writeAttempted: false, writing: false))
        // Never while a Pay is being sent or after one whose result is unknown.
        XCTAssertFalse(orderReviewOffersNextDraft(inRun: true, writeSucceeded: false, writeAttempted: false, writing: true))
        XCTAssertFalse(orderReviewOffersNextDraft(inRun: true, writeSucceeded: false, writeAttempted: true, writing: false))
    }

    // MARK: Display

    func testTrackingConstantsReadAsWords() {
        XCTAssertEqual(orderAPIValueTitle("SHIPPO"), "Shippo")
        XCTAssertEqual(orderAPIValueTitle("INTERNATIONAL"), "International")
        XCTAssertEqual(orderAPIValueTitle("SHIPPED"), "Shipped")
        XCTAssertEqual(orderAPIValueTitle("IN_TRANSIT"), "In transit")
        XCTAssertEqual(orderAPIValueTitle("UPS"), "UPS")
        XCTAssertEqual(orderAPIValueTitle("FEDEX"), "FedEx")
        XCTAssertEqual(orderAPIValueTitle("Royal Mail"), "Royal Mail")
        XCTAssertEqual(orderAPIValueTitle("1Z999AA10123456784"), "1Z999AA10123456784")
        XCTAssertEqual(orderAPIValueTitle(" usps "), "usps")
        // Copies and the Shopify CSV still read Slant's value.
        let facts = trackingFacts(["provider": "SHIPPO", "deliveryMethod": "INTERNATIONAL", "trackingNumbers": ["1Z"]])
        XCTAssertEqual(facts.first { $0.0 == "Carrier" }?.1, "SHIPPO")
    }

    func testMarginPercentUsesATrueMinus() {
        XCTAssertEqual(profitPercentText(Decimal(string: "-107.7")!), "−107.7%")
        XCTAssertEqual(profitPercentText(Decimal(string: "12.5")!), "12.5%")
        XCTAssertEqual(profitPercentText(0), "0%")
        XCTAssertTrue(profitCheckEntryCaption.contains("clears when you choose another order"))
        XCTAssertTrue(profitCheckEntryCaption.contains("Nothing you type here is saved"))
    }

    func testComposerHeadingsAreSentenceCase() {
        XCTAssertEqual(orderComposerHeading(sourceOrderNumber: nil), "New order draft")
        XCTAssertEqual(orderComposerHeading(sourceOrderNumber: "SLANT_1"), "Duplicate of order SLANT_1")
    }

    // MARK: Order watch hold

    func testOrderWatchHoldCaptions() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let refused = orderWatchFailureEffect(APIError.http(status: 401, body: "", retryAfter: nil, rateLimitReset: nil), now: now)
        XCTAssertEqual(orderWatchHold(after: refused), .accountRefused)
        XCTAssertTrue(orderWatchHoldCaption(.accountRefused, now: now)?.hasPrefix("Paused: Slant refused") == true)
        let limited = orderWatchFailureEffect(APIError.http(status: 429, body: "", retryAfter: "120", rateLimitReset: nil), now: now)
        XCTAssertEqual(orderWatchHold(after: limited), .rateLimited(until: now.addingTimeInterval(120)))
        XCTAssertTrue(orderWatchHoldCaption(.rateLimited(until: now.addingTimeInterval(120)), now: now)?.hasPrefix("Waiting for Slant’s rate limit") == true)
        XCTAssertNil(orderWatchHoldCaption(.rateLimited(until: now.addingTimeInterval(-1)), now: now), "A wait that has passed says nothing")
        XCTAssertNil(orderWatchHoldCaption(nil, now: now))
        let other = orderWatchFailureEffect(APIError.http(status: 500, body: "", retryAfter: nil, rateLimitReset: nil), now: now)
        XCTAssertNil(orderWatchHold(after: other))
    }
}

extension OrdersRound13Tests {
    func testUnspacedNonLatinAddressIsNotAToken() {
        XCTAssertFalse(addressPasteValueLooksLikeToken("東京都千代田区丸の内一丁目九番二号グラントウキョウサウスタワー"))
        XCTAssertTrue(addressPasteValueLooksLikeToken("aB3dE5gH7jK9mN1pQ3sT5vW7yZ9bC"))
        XCTAssertTrue(addressPasteValueLooksLikeToken("https://example.com"))
    }
}
