import XCTest
@testable import SlantStudio

/// Round 15 review fixes on the money path: Pay Several Drafts' duplicate pass, the money-word matcher, the Workbench's
/// view of a draft's totals, the review's item list and when Create Anyway is asked for.
final class OrdersReviewFixesRound15Tests: XCTestCase {

    // MARK: Pay Several Drafts: a draft left out for another reason still holds its marketplace order

    private func draft(_ id: String, extra: [String: Any] = [:], metadata: [String: Any]? = ["source": "etsy", "sourceOrderId": "3141"]) -> [String: Any] {
        var order: [String: Any] = ["publicId": id, "status": "DRAFT", "printingCost": "9.93", "deliveryCost": "5.25"]
        if let metadata { order["metadata"] = metadata }
        order.merge(extra) { _, new in new }
        return order
    }

    /// The reviewers' scenario: A and B are for the same Etsy order; A is left out for an unlisted cost. B must not be
    /// paid in the batch, or the seller paying A on its own after checking it would pay the sale twice.
    func testADraftLeftOutForAnUnlistedCostStillBlocksItsDuplicate() {
        let a = draft("A", extra: ["taxCost": "1.20"])
        let b = draft("B")
        let reasonA = batchPayExclusionReason(orderID: "A", order: a, loadFailure: nil, locked: false)
        XCTAssertNotNil(reasonA)
        XCTAssertNil(batchPayExclusionReason(orderID: "B", order: b, loadFailure: nil, locked: false))
        let reasons = batchPayDuplicateExclusions([(id: "A", order: a), (id: "B", order: b)], placedKeys: [], excludedIDs: ["A"])
        XCTAssertEqual(Set(reasons.keys), ["B"])
        XCTAssertEqual(reasons["B"], "Another draft in this review is also for Etsy order 3141 and was left out, so this one may be a duplicate. Check them in Orders.")
        // Without the excluded draft in the pass (the old behaviour) B would have been paid.
        XCTAssertTrue(batchPayDuplicateExclusions([(id: "B", order: b)], placedKeys: []).isEmpty)
    }

    /// The same for a draft left out by a lock or a failed load (its list copy names the marketplace order), and for one
    /// already sent for payment in this batch.
    func testEveryOtherExclusionReasonHoldsTheMarketplaceOrderToo() {
        let a = draft("A")
        let b = draft("B")
        // Locked: the fresh copy loaded, but the draft is left out.
        XCTAssertNotNil(batchPayExclusionReason(orderID: "A", order: a, loadFailure: nil, locked: true))
        XCTAssertEqual(Set(batchPayDuplicateExclusions([(id: "A", order: a), (id: "B", order: b)], placedKeys: [],
                                                       excludedIDs: ["A"]).keys), ["B"])
        // Failed to load: the list's copy is used.
        let listed = [Record(values: a), Record(values: b)]
        let fromList = batchPayDuplicateCheckOrder(id: "A", fresh: nil, listed: listed)
        XCTAssertEqual(fromList.flatMap(batchPayMarketplaceKey), batchPayMarketplaceKey(a))
        // A reply for another order isn't trusted for the key; the list's copy is used instead.
        let other = draft("Z", metadata: ["source": "etsy", "sourceOrderId": "999"])
        XCTAssertEqual(batchPayDuplicateCheckOrder(id: "A", fresh: other, listed: listed).flatMap(batchPayMarketplaceKey),
                       batchPayMarketplaceKey(a))
        XCTAssertNil(batchPayDuplicateCheckOrder(id: "Q", fresh: nil, listed: listed))
        let fresh = draft("A", extra: ["status": "SUBMITTED"])
        XCTAssertEqual(batchPayDuplicateCheckOrder(id: "A", fresh: fresh, listed: listed)?["status"] as? String, "SUBMITTED")
    }

    /// The pass only ever leaves more out: no reason is returned for an excluded draft, and drafts for other orders are
    /// untouched. A left-out draft holds its marketplace order wherever it is in the list, so a payable draft before it
    /// is left out too (paying that one now and the left-out one later on its own would also pay the sale twice).
    func testThePassNeverIncludesAnything() {
        let a = draft("A")
        let b = draft("B")
        let c = draft("C", metadata: ["source": "etsy", "sourceOrderId": "2718"])
        let plain = draft("P", metadata: nil)
        let reasons = batchPayDuplicateExclusions(
            [(id: "A", order: a), (id: "B", order: b), (id: "C", order: c), (id: "P", order: plain)],
            placedKeys: [], excludedIDs: ["B"])
        XCTAssertEqual(Set(reasons.keys), ["A"], "B is already out and gets no reason; C and P are other orders")
        XCTAssertTrue(reasons["A"]?.contains("was left out") == true)
        // Two payable drafts and no left-out one: the first stays included, as before.
        let both = batchPayDuplicateExclusions([(id: "A", order: a), (id: "B", order: b)], placedKeys: [])
        XCTAssertEqual(Set(both.keys), ["B"])
        XCTAssertEqual(both["B"], "Another draft in this review is also for Etsy order 3141. Only the first is included; check them in Orders.")
        // An already placed marketplace order still leaves every draft for it out, excluded ones get no reason.
        let placed = batchPayDuplicateExclusions([(id: "A", order: a), (id: "B", order: b)], placedKeys: [batchPayMarketplaceKey(a)!],
                                                 excludedIDs: ["A"])
        XCTAssertEqual(Set(placed.keys), ["B"])
        XCTAssertTrue(placed["B"]?.contains("already placed") == true)
    }

    // MARK: Money words

    func testTheNewMoneyWordsAreMatched() {
        for key in ["pricing", "unitPrice", "PRICE", "gst", "GSTAmount", "levy", "carbonLevy", "handling", "handlingCharge",
                    "insurance", "shippingInsurance", "postage", "shipping", "shippingCost", "billing", "billingTotal"] {
            XCTAssertTrue(orderKeyLooksLikeMoney(key), key)
        }
        // `payment` is deliberately not a money word: paymentId is a live key.
        XCTAssertFalse(orderKeyLooksLikeMoney("paymentId"))
        XCTAssertFalse(orderMoneyKeyWords.contains("payment"))
        for key in ["arriveByDate", "createdAt", "creatorId", "customer", "deliveryCost", "fulfillment", "items", "options",
                    "ownerId", "paymentId", "platformId", "printingCost", "processedAt", "publicId", "status", "updatedAt",
                    "platform"] where !orderCostFieldsStudioAdds.contains(key) {
            XCTAssertFalse(orderKeyLooksLikeMoney(key), key)
        }
        let order: [String: Any] = ["publicId": "SLANT_1", "status": "DRAFT", "printingCost": "9.93", "deliveryCost": "5.25",
                                    "shipping": "2.00", "gst": "1.10"]
        XCTAssertEqual(orderUnlistedCosts(order).fields, ["gst", "shipping"])
    }

    // MARK: The Workbench sees the draft envelope's totals

    func testTheWorkbenchKeepsTheEnvelopeTotals() {
        let envelope: [String: Any] = [
            "order": ["publicId": "SLANT_1", "status": "DRAFT", "printingCost": "9.93", "deliveryCost": "5.25"],
            "totals": ["printingCost": "9.93", "deliveryCost": "5.25", "totalCost": "15.18", "taxCost": "1.20"]
        ]
        let order = workbenchUnwrapOrder(envelope)
        XCTAssertEqual(order["publicId"] as? String, "SLANT_1")
        // The notice side sees the tax inside totals, as the Orders review does.
        XCTAssertEqual(orderUnlistedCosts(order).fields, ["totals.taxCost"])
        XCTAssertEqual(orderUnlistedCosts(order), orderUnlistedCosts(mergeOrderDraftEnvelope(envelope)))
        // The comparison side: a tax that appears in totals between the review and the send is a change.
        var later = envelope
        later["totals"] = ["printingCost": "9.93", "deliveryCost": "5.25", "totalCost": "15.18", "taxCost": "2.40"]
        XCTAssertFalse(workbenchOrderPreviewMatches(order, workbenchUnwrapOrder(later)))
        XCTAssertTrue(workbenchOrderPreviewMatches(order, workbenchUnwrapOrder(envelope)))
        // A bare order reads as before.
        XCTAssertEqual(workbenchUnwrapOrder(["status": "DRAFT", "printingCost": "1.00"])["printingCost"] as? String, "1.00")
    }

    // MARK: The review's item list

    func testTheItemListAlwaysShowsARow() {
        for maximum in 0...8 {
            for extras in -1...8 {
                let one = orderReviewItemListLayout(itemCount: 1, extraReceiptLines: extras, maximumExtraLines: maximum)
                XCTAssertFalse(one.scrolls, "one item is always listed plainly (extras \(extras), max \(maximum))")
                let many = orderReviewItemListLayout(itemCount: 9, extraReceiptLines: extras, maximumExtraLines: maximum)
                XCTAssertGreaterThanOrEqual(many.height, 2 * orderReviewExtraLineHeight)
            }
        }
        // With the cost notice (four extra lines): one item plain, two scroll in the shortest box.
        XCTAssertFalse(orderReviewItemListLayout(itemCount: 1, extraReceiptLines: 4, maximumExtraLines: 4).scrolls)
        XCTAssertTrue(orderReviewItemListLayout(itemCount: 2, extraReceiptLines: 4, maximumExtraLines: 4).scrolls)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 2, extraReceiptLines: 4, maximumExtraLines: 4).height, 44)
    }

    // MARK: Create Anyway only when it matters

    private let date = Date(timeIntervalSince1970: 1_000)

    func testCreateAnywayOnlyForAPossibleRepeat() {
        let ada = UnconfirmedDraftAttempt(recipient: "Ada Lovelace", date: date)
        let anonymous = UnconfirmedDraftAttempt(recipient: "", date: date)
        // Nothing unconfirmed: never.
        XCTAssertFalse(draftCreateNeedsCreateAnyway(attempts: [], overflowed: false, recipient: "Ada Lovelace"))
        XCTAssertFalse(draftCreateNeedsCreateAnyway(attempts: [], overflowed: false, recipient: ""))
        // (a) the same recipient, as the key compares it.
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: "Ada Lovelace"))
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: "  ada\tLOVELACE "))
        // Another customer: the notice still shows, but no Create Anyway.
        XCTAssertFalse(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: "Grace Hopper"))
        XCTAssertFalse(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: "Ada"))
        // (b) an unconfirmed attempt without a recipient could be anyone.
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada, anonymous], overflowed: false, recipient: "Grace Hopper"))
        // (c) attempts dropped off the list: their recipients are unknown.
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [], overflowed: true, recipient: "Grace Hopper"))
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: true, recipient: "Grace Hopper"))
        // (d) this draft has no recipient.
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: ""))
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: " \n "))
        // Create Anyway still needs the explicit press.
        XCTAssertTrue(draftCreateNeedsConfirmation(outcomeUnknown: true, confirmed: false))
        XCTAssertFalse(draftCreateNeedsConfirmation(outcomeUnknown: true, confirmed: true))
    }

    /// The Workbench judges by the body's recipient: a body without a readable name always asks.
    func testTheWorkbenchJudgesByTheBodysRecipient() {
        let ada = UnconfirmedDraftAttempt(recipient: "Ada Lovelace", date: date)
        let body: [String: Any] = ["customer": ["details": ["address": ["name": "Ada Lovelace"]]]]
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: orderDraftBodyRecipient(body)))
        let other: [String: Any] = ["customer": ["details": ["address": ["name": "Grace Hopper"]]]]
        XCTAssertFalse(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: orderDraftBodyRecipient(other)))
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: orderDraftBodyRecipient(["items": []])))
        XCTAssertTrue(draftCreateNeedsCreateAnyway(attempts: [ada], overflowed: false, recipient: orderDraftBodyRecipient([body])))
    }
}
