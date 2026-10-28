import XCTest
@testable import SlantStudio

/// Round 15: hardening the money path against Slant's next silent API change.
final class OrdersSafetyRound15Tests: XCTestCase {

    // MARK: Cost fields Studio doesn't add

    /// The live spec's Order properties and the keys seen on live orders (28 Oct 2026), none of which is an extra cost.
    private let liveOrderKeys = [
        "arriveByDate", "createdAt", "creatorId", "customer", "deliveryCost", "fulfillment", "items", "options", "ownerId",
        "paymentId", "platformId", "printingCost", "processedAt", "publicId", "status", "updatedAt", "platform", "metadata", "id"
    ]

    private func liveOrder(_ extra: [String: Any] = [:]) -> [String: Any] {
        var order: [String: Any] = [
            "arriveByDate": "2026-11-05", "createdAt": "2026-10-28T09:00:00.000Z", "creatorId": "creator-1",
            "customer": ["details": ["email": "ada@example.com", "address": ["name": "Ada"]]],
            "deliveryCost": "5.25", "fulfillment": NSNull(), "items": [["price": 9.93, "currency": "USD", "quantity": 1]],
            "options": ["shippingProvider": "SHIPPO"], "ownerId": "owner-1", "paymentId": "pay_123", "platformId": "plat-1",
            "printingCost": "9.93", "processedAt": NSNull(), "publicId": "SLANT_1", "status": "DRAFT",
            "updatedAt": "2026-10-28T09:01:00.000Z",
            // A nested object's money words are never looked at.
            "platform": ["id": "plat-1", "name": "Shop", "feeSchedule": "standard", "totalOrders": 12]
        ]
        order.merge(extra) { _, new in new }
        return order
    }

    func testLiveOrderKeysNeverLookLikeExtraCosts() {
        for key in liveOrderKeys where !orderCostFieldsStudioAdds.contains(key) {
            XCTAssertFalse(orderKeyLooksLikeMoney(key), key)
        }
        XCTAssertTrue(orderUnlistedCosts(liveOrder()).isEmpty)
        XCTAssertNil(orderUnlistedCostNotice(orderUnlistedCosts(liveOrder())))
        XCTAssertNil(orderUnlistedCostBatchReason(orderUnlistedCosts(liveOrder())))
    }

    /// The bundled spec's Order and OrderTotals: no property but the two costs and Slant's totals looks like money, so
    /// a spec update that adds one fails here and gets looked at.
    func testBundledSpecOrderPropertiesAreAllAccountedFor() throws {
        let url = try XCTUnwrap(EndpointCatalog.specificationURL())
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let schemas = try XCTUnwrap((document["components"] as? [String: Any])?["schemas"] as? [String: Any])
        for name in ["Order", "OrderTotals"] {
            let properties = try XCTUnwrap((schemas[name] as? [String: Any])?["properties"] as? [String: Any], name)
            for key in properties.keys where !orderCostFieldsStudioAdds.contains(key) && !orderSlantTotalFields.contains(key) {
                XCTAssertFalse(orderKeyLooksLikeMoney(key), "\(name).\(key)")
            }
        }
    }

    func testEveryMoneyWordIsMatchedInAnyCase() {
        for key in ["taxCost", "serviceFee", "salesTax", "grandTotal", "subtotal", "unitPrice", "handlingCharge", "fuelSurcharge",
                    "discount", "AMOUNT_DUE", "vat", "importDuty", "Fees", "costCentre"] {
            XCTAssertTrue(orderKeyLooksLikeMoney(key), key)
        }
        for key in ["status", "currency", "paymentId", "weight", "createdAt", "processedAt"] {
            XCTAssertFalse(orderKeyLooksLikeMoney(key), key)
        }
    }

    func testAnExtraTaxFieldIsNamedAndExplained() {
        let costs = orderUnlistedCosts(liveOrder(["taxCost": "1.20"]))
        XCTAssertEqual(costs.fields, ["taxCost"])
        XCTAssertNil(costs.slantTotal)
        XCTAssertEqual(orderUnlistedCostNotice(costs),
                       "Slant also lists taxCost, which this total may not include. Check the order on Slant before paying.")
        XCTAssertEqual(orderUnlistedCostBatchReason(costs),
                       "Slant also lists taxCost for it, which may not be included in its total. Check it on Slant, then pay it in its own review.")
        // A number or an object counts too.
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["serviceFee": 0.5])).fields, ["serviceFee"])
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["fees": [["name": "Handling", "amount": 1]]])).fields, ["fees"])
        // Unreadable text might be an amount.
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["handlingFee": "see invoice"])).fields, ["handlingFee"])
        // Erring towards a false alarm: a cost centre is named too (it only asks the seller to check).
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["costCentre": "Workshop"])).fields, ["costCentre"])
    }

    func testFieldsThatCanNotAddToTheChargeAreIgnored() {
        for value in [NSNull(), 0, "0", "0.00", " ", true, false, [Any](), [String: Any]()] as [Any] {
            XCTAssertTrue(orderUnlistedCosts(liveOrder(["taxCost": value])).isEmpty, "\(value)")
        }
    }

    func testNamesAreSortedSanitisedAndCapped() {
        let costs = orderUnlistedCosts(liveOrder([
            "vatAmount": "1", "zFee": "1", "Duty": "1", "bTax": "1", "tax\u{202E}Cost\n": "2",
            String(repeating: "x", count: 60) + "Fee": "3"
        ]))
        XCTAssertEqual(costs.fields, ["bTax", "Duty", "taxCost"])
        XCTAssertEqual(costs.moreFields, 3)
        XCTAssertEqual(orderUnlistedCostNotice(costs),
                       "Slant also lists bTax, Duty, taxCost and 3 more, which this total may not include. Check the order on Slant before paying.")
        XCTAssertEqual(orderCostFieldDisplayName(String(repeating: "a", count: 50)), String(repeating: "a", count: 40) + "…")
        XCTAssertEqual(orderCostFieldDisplayName("💰"), "an unnamed field")
        let two = orderUnlistedCosts(liveOrder(["taxCost": "1", "serviceFee": "2"]))
        XCTAssertEqual(orderUnlistedCostNotice(two)?.hasPrefix("Slant also lists serviceFee and taxCost, which this"), true)
    }

    func testASlantTotalThatDisagreesWithTheSumIsFlagged() {
        // The draft envelope's totals: 9.93 + 5.25 = 15.18.
        let agrees = orderUnlistedCosts(liveOrder(["totals": ["printingCost": "9.93", "deliveryCost": "5.25", "totalCost": "15.18"]]))
        XCTAssertTrue(agrees.isEmpty)
        // Within half a cent is rounding.
        XCTAssertTrue(orderUnlistedCosts(liveOrder(["total": 15.184])).isEmpty)
        let higher = orderUnlistedCosts(liveOrder(["totals": ["totalCost": "16.40"]]))
        XCTAssertEqual(higher.slantTotal, Decimal(string: "16.40"))
        XCTAssertEqual(higher.costsSum, Decimal(string: "15.18"))
        XCTAssertEqual(orderUnlistedCostNotice(higher),
                       "Slant’s total ($16.40 USD) isn’t print plus delivery ($15.18 USD). Check the order on Slant before paying.")
        XCTAssertEqual(orderUnlistedCostBatchReason(higher),
                       "Slant’s own total for it ($16.40 USD) doesn’t match print cost plus delivery ($15.18 USD). Check it on Slant, then pay it in its own review.")
        // At the top level too, as a number or a string.
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["totalCost": 20])).slantTotal, 20)
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["total": "15.00"])).slantTotal, 15)
        // An extra cost inside totals is named with its path.
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["totals": ["totalCost": "15.18", "taxCost": "1.00"]])).fields, ["totals.taxCost"])
    }

    func testOddTotalsShapesAreFlaggedRatherThanTrusted() {
        // `totals` as a string or a number can't be compared, so it's named.
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["totals": "16.40"])).fields, ["totals"])
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["totals": 16.4])).fields, ["totals"])
        // An unreadable Slant total is named, never compared.
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["total": "n/a"])).fields, ["total"])
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["totals": ["totalCost": "about 16"]])).fields, ["totals.totalCost"])
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["total": NSNumber(value: Double.nan)])).fields, ["total"])
        XCTAssertEqual(orderUnlistedCosts(liveOrder(["total": "NaN"])).fields, ["total"])
        // A null total says nothing.
        XCTAssertTrue(orderUnlistedCosts(liveOrder(["total": NSNull()])).isEmpty)
    }

    func testMissingCostsSkipTheComparisonButStillNameExtras() {
        var order = liveOrder(["total": "30.00", "taxCost": "2.00"])
        order["deliveryCost"] = nil
        let costs = orderUnlistedCosts(order)
        XCTAssertNil(costs.slantTotal, "no sum to compare with")
        XCTAssertEqual(costs.fields, ["taxCost"])
        order["printingCost"] = nil
        order["taxCost"] = nil
        XCTAssertTrue(orderUnlistedCosts(order).isEmpty)
        XCTAssertTrue(orderUnlistedCosts([:]).isEmpty)
    }

    func testTheDraftEnvelopeKeepsItsTotalsForTheCheck() {
        let merged = mergeOrderDraftEnvelope([
            "order": ["publicId": "SLANT_1", "status": "DRAFT"],
            "totals": ["printingCost": "3", "deliveryCost": "2", "totalCost": "5.00", "taxCost": "0.40"]
        ])
        XCTAssertEqual(merged["totalCost"] as? String, "5.00")
        XCTAssertEqual(orderUnlistedCosts(merged).fields, ["totals.taxCost"])
        // An order's own totals win over the envelope's.
        let own = mergeOrderDraftEnvelope(["order": ["publicId": "SLANT_1", "totals": ["totalCost": "5.00"]],
                                           "totals": ["totalCost": "9.00"]])
        XCTAssertEqual((own["totals"] as? [String: Any])?["totalCost"] as? String, "5.00")
    }

    func testTheNoticeNeverChangesWhetherPayIsEnabled() {
        let flagged = liveOrder(["taxCost": "1.20"])
        XCTAssertEqual(
            orderConfirmFinalActionEnabled(writeSucceeded: false, loaded: true, status: "DRAFT", isPay: true, order: flagged),
            orderConfirmFinalActionEnabled(writeSucceeded: false, loaded: true, status: "DRAFT", isPay: true, order: liveOrder()))
        XCTAssertTrue(orderConfirmFinalActionEnabled(writeSucceeded: false, loaded: true, status: "DRAFT", isPay: true, order: flagged))
        XCTAssertTrue(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: flagged).0)
    }

    func testPaySeveralDraftsLeavesSuchADraftOut() {
        XCTAssertNil(batchPayExclusionReason(orderID: "SLANT_1", order: liveOrder(), loadFailure: nil, locked: false))
        XCTAssertEqual(batchPayExclusionReason(orderID: "SLANT_1", order: liveOrder(["taxCost": "1.20"]), loadFailure: nil, locked: false),
                       "Slant also lists taxCost for it, which may not be included in its total. Check it on Slant, then pay it in its own review.")
        XCTAssertNotNil(batchPayExclusionReason(orderID: "SLANT_1", order: liveOrder(["totalCost": "16.40"]), loadFailure: nil, locked: false))
        // The earlier reasons still come first.
        XCTAssertEqual(batchPayExclusionReason(orderID: "SLANT_1", order: liveOrder(["taxCost": "1", "status": "SUBMITTED"]),
                                               loadFailure: nil, locked: false), "It’s no longer a draft (now Submitted).")
    }

    func testAFeeThatAppearsBeforePayingStopsThePayment() {
        let reviewed = liveOrder()
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: reviewed, latest: liveOrder()), .proceed)
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: reviewed, latest: liveOrder(["taxCost": "1.20"])), .priceChanged)
        // Seen in the review and unchanged: the seller saw the notice, so the payment goes ahead.
        let flagged = liveOrder(["taxCost": "1.20", "platform": ["name": "Other"]])
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: flagged, latest: liveOrder(["taxCost": "1.2"])), .proceed)
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: flagged, latest: liveOrder(["taxCost": "2.40"])), .priceChanged)
        // Object values compare by content, whatever their key order.
        let fees: [String: Any] = ["a": 1, "b": 2, "c": ["d": 3, "e": 4]]
        XCTAssertEqual(orderUnlistedCostSignature(liveOrder(["fees": fees])), orderUnlistedCostSignature(liveOrder(["fees": fees])))
        // Cancelling isn't affected.
        let printing = liveOrder(["status": "PRINTING"])
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: printing, latest: liveOrder(["status": "PRINTING", "taxCost": "1"])), .proceed)
        // The Workbench's re-check does the same.
        XCTAssertTrue(workbenchOrderPreviewMatches(reviewed, liveOrder()))
        XCTAssertFalse(workbenchOrderPreviewMatches(reviewed, liveOrder(["serviceFee": "0.99"])))
    }

    func testTheReviewKeepsTheNoticeInView() {
        let lines = orderReviewCostNoticeLines
        let layout = orderReviewItemListLayout(itemCount: 3, extraReceiptLines: 2 + lines, maximumExtraLines: 2 + lines)
        XCTAssertTrue(layout.scrolls)
        XCTAssertEqual(layout.height, orderReviewItemBoxHeight - CGFloat(2 + lines) * orderReviewExtraLineHeight)
        // Without the notice, the cap is unchanged.
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 9, extraReceiptLines: 7).height, 86)
    }

    // MARK: A status Studio doesn't recognise

    func testAnUnrecognisedStatusIsNamedInsteadOfCalledUncancellable() {
        XCTAssertEqual(orderCancellationBlockedReason("ON_HOLD"),
                       "Studio doesn’t recognise this order’s status (“ON_HOLD”), so it doesn’t offer Cancel. Check the order on Slant.")
        XCTAssertEqual(orderDetailCancelBlockedNote(" awaiting_pickup "),
                       "Studio doesn’t recognise this order’s status (“awaiting_pickup”), so it doesn’t offer Cancel. Check the order on Slant.")
        XCTAssertEqual(orderCancellationBlockedReason(""),
                       "Slant didn’t return this order’s status, so Studio doesn’t offer Cancel. Check the order on Slant.")
        let long = orderCancellationBlockedReason(String(repeating: "Z", count: 80) + "\n\u{7}") ?? ""
        XCTAssertTrue(long.contains("(“" + String(repeating: "Z", count: 40) + "…”)"), long)
        XCTAssertEqual(orderCancelConfirmAllowed(status: "ON_HOLD", loaded: true).1, orderCancellationBlockedReason("ON_HOLD"))
        XCTAssertEqual(workbenchCancelAllowed(status: "ON_HOLD", loaded: true).1, orderCancellationBlockedReason("ON_HOLD"))
        // Known statuses keep their copy.
        XCTAssertEqual(orderCancellationBlockedReason("cancelled"), "This order was already cancelled.")
        XCTAssertEqual(orderCancellationBlockedReason("draft"), "Slant doesn’t cancel drafts. A draft costs nothing unless you place it.")
        for status in orderKnownStatuses where !orderStatusIsCancelled(status) && status != "DRAFT" {
            XCTAssertNil(orderCancellationBlockedReason(status), status)
        }
    }

    // MARK: Status meanings in one table

    private struct StatusMeaning {
        let status: String
        let title: String
        let live: Bool
        let cancelled: Bool
        let cancellable: Bool
        let refundOnly: Bool
        let cancelButton: String
        let countedAsSpend: Bool
        /// orderAttention for an order past its arrive-by date, created yesterday: "late", "payment" or nil.
        let attention: String?
        let watchNotable: Bool
        let watchBadge: Bool
        /// batchPayOutcomeAfterSuccess: "placed", "notPlaced" or "unrecognised".
        let afterPay: String
        let lockStaysAfter2xx: Bool
        /// A loaded order with this status makes a draft for the same marketplace order a likely duplicate.
        let blocksDuplicateDraft: Bool
        let payableInBatch: Bool
        let progressShown: Bool
        let trackingShownWithoutDetails: Bool
        let offersProblemReport: Bool
        let problemCanBeLate: Bool
    }

    private var statusTable: [StatusMeaning] {
        func row(_ status: String, _ title: String, live: Bool = false, cancelled: Bool = false, cancellable: Bool,
                 refundOnly: Bool = false, cancelButton: String, spend: Bool, attention: String?, notable: Bool = false,
                 badge: Bool = false, afterPay: String, lockStays: Bool = false, blocksDuplicate: Bool, payable: Bool = false,
                 progress: Bool, tracking: Bool, problemReport: Bool = true, problemLate: Bool) -> StatusMeaning {
            StatusMeaning(status: status, title: title, live: live, cancelled: cancelled, cancellable: cancellable,
                          refundOnly: refundOnly, cancelButton: cancelButton, countedAsSpend: spend, attention: attention,
                          watchNotable: notable, watchBadge: badge, afterPay: afterPay, lockStaysAfter2xx: lockStays,
                          blocksDuplicateDraft: blocksDuplicate, payableInBatch: payable, progressShown: progress,
                          trackingShownWithoutDetails: tracking, offersProblemReport: problemReport, problemCanBeLate: problemLate)
        }
        return [
            // Slant's live statuses since 26 Oct 2026.
            row("DRAFT", "Draft", live: true, cancellable: false, cancelButton: "Cancel Draft", spend: false, attention: "late",
                afterPay: "notPlaced", lockStays: true, blocksDuplicate: false, payable: true, progress: false, tracking: false,
                problemReport: false, problemLate: false),
            row("SUBMITTED", "Submitted", live: true, cancellable: true, cancelButton: "Cancel & Refund", spend: true,
                attention: "late", afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("PRINTING", "Printing", live: true, cancellable: true, cancelButton: "Cancel & Refund", spend: true,
                attention: "late", afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("SHIPPED", "Shipped", live: true, cancellable: true, refundOnly: true, cancelButton: "Request Refund", spend: true,
                attention: nil, notable: true, badge: true, afterPay: "placed", blocksDuplicate: true, progress: false,
                tracking: true, problemLate: true),
            row("CANCELLED", "Cancelled", live: true, cancelled: true, cancellable: false, cancelButton: "Cancel Order",
                spend: false, attention: nil, notable: true, badge: true, afterPay: "notPlaced", blocksDuplicate: false,
                progress: false, tracking: false, problemLate: false),
            // The earlier statuses, still read from saved snapshots and old replies.
            row("PAID", "Paid", cancellable: true, cancelButton: "Cancel & Refund", spend: true, attention: "late",
                afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("QUEUED", "In queue", cancellable: true, cancelButton: "Cancel & Refund", spend: true, attention: "late",
                afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("PROCESSING", "Processing", cancellable: true, cancelButton: "Cancel & Refund", spend: true, attention: "late",
                afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("ITEMS_ON_SHELF", "On the shelf", cancellable: true, cancelButton: "Cancel & Refund", spend: true,
                attention: "late", afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("POST_PROCESSING", "Finishing", cancellable: true, cancelButton: "Cancel & Refund", spend: true,
                attention: "late", afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("COMPLETED", "Printed", cancellable: true, cancelButton: "Cancel & Refund", spend: true, attention: "late",
                afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("IN_REVIEW", "In review", cancellable: true, cancelButton: "Cancel & Refund", spend: true, attention: "late",
                notable: true, badge: true, afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true,
                problemLate: true),
            row("AWAITING_SHIPMENT", "Awaiting shipment", cancellable: true, cancelButton: "Cancel & Refund", spend: true,
                attention: "late", afterPay: "placed", blocksDuplicate: true, progress: true, tracking: true, problemLate: true),
            row("DELIVERED", "Delivered", cancellable: true, refundOnly: true, cancelButton: "Request Refund", spend: true,
                attention: nil, notable: true, afterPay: "placed", blocksDuplicate: true, progress: false, tracking: true,
                problemLate: false),
            row("CANCELED", "Cancelled", cancelled: true, cancellable: false, cancelButton: "Cancel Order", spend: false,
                attention: nil, notable: true, badge: true, afterPay: "notPlaced", blocksDuplicate: false, progress: false,
                tracking: false, problemLate: false),
            row("PAYMENT_ERROR", "Payment problem", cancellable: true, cancelButton: "Cancel Order", spend: false,
                attention: "payment", notable: true, badge: true, afterPay: "notPlaced", blocksDuplicate: false,
                progress: false, tracking: false, problemLate: false),
            // A status Studio doesn't know: never cancellable, never spend, never late, never placed; but past DRAFT, so a
            // pay's lock lifts, and a marketplace order holding one keeps its other drafts out of a batch.
            row("ON_HOLD", "On Hold", cancellable: false, cancelButton: "Cancel Order", spend: false, attention: nil,
                afterPay: "unrecognised", blocksDuplicate: true, progress: true, tracking: true, problemLate: false)
        ]
    }

    func testEveryStatusMeansTheSameInEveryList() throws {
        let table = statusTable
        // Every known status is in the table exactly once, and the table holds one status Studio doesn't know.
        let known = table.map(\.status).filter { orderKnownStatuses.contains($0) }
        XCTAssertEqual(Set(known), orderKnownStatuses, "add a row for each status Studio recognises")
        XCTAssertEqual(known.count, orderKnownStatuses.count)
        XCTAssertEqual(table.filter { !orderKnownStatuses.contains($0.status) }.count, 1)

        let now = try XCTUnwrap(orderTimestamp("2026-10-28T12:00:00Z"))
        for meaning in table {
            let status = meaning.status
            let message = "status \(status)"
            XCTAssertEqual(orderStatusTitle(status), meaning.title, message)
            XCTAssertEqual(orderLiveStatuses.contains(status), meaning.live, message)
            XCTAssertEqual(orderStatusFilterOptions.contains(status), meaning.live, message)
            XCTAssertEqual(orderStatusIsCancelled(status), meaning.cancelled, message)
            XCTAssertEqual(orderStatusIsCancelled(status.lowercased()), meaning.cancelled, message)
            XCTAssertEqual(orderCanRequestCancellation(status), meaning.cancellable, message)
            XCTAssertEqual(orderCancellationBlockedReason(status) == nil, meaning.cancellable, message)
            XCTAssertEqual(orderCancellationIsRefundOnly(status), meaning.refundOnly, message)
            XCTAssertEqual(orderCancelButtonBaseTitle(status), meaning.cancelButton, message)
            XCTAssertEqual(spendReportCountedStatuses.contains(status), meaning.countedAsSpend, message)

            let lateOrder: [String: Any] = ["status": status, "createdAt": "2026-10-27T12:00:00Z", "arriveByDate": "2026-10-01"]
            let attention: String?
            switch orderAttention(lateOrder, now: now, timeZone: TimeZone(identifier: "UTC")!) {
            case .pastArriveBy?: attention = "late"
            case .paymentProblem?: attention = "payment"
            case nil: attention = nil
            case let other?: attention = "\(other)"
            }
            XCTAssertEqual(attention, meaning.attention, message)

            XCTAssertEqual(orderWatchNotableStatuses.contains(status), meaning.watchNotable, message)
            XCTAssertEqual(orderWatchBadgeStatuses.contains(status), meaning.watchBadge, message)

            let afterPay: String
            switch batchPayOutcomeAfterSuccess(["publicId": "SLANT_1", "status": status]) {
            case .placed: afterPay = "placed"
            case .notPlaced: afterPay = "notPlaced"
            case .unrecognised: afterPay = "unrecognised"
            case let other: afterPay = "\(other)"
            }
            XCTAssertEqual(afterPay, meaning.afterPay, message)
            XCTAssertEqual(orderPlacedStatuses.contains(status), meaning.afterPay == "placed", message)
            XCTAssertEqual(batchPayAcceptedOutcomeStaysLocked(["status": status]), meaning.lockStaysAfter2xx, message)

            let marketplace: [String: Any] = ["source": "etsy", "sourceOrderId": "3141"]
            let placed = Record(values: ["publicId": "SLANT_9", "status": status, "metadata": marketplace])
            XCTAssertEqual(!batchPayPlacedMarketplaceKeys([placed]).isEmpty, meaning.blocksDuplicateDraft, message)
            let loaded: [String: Any] = ["publicId": "SLANT_1", "status": status, "printingCost": "9.93", "deliveryCost": "5.25"]
            XCTAssertEqual(batchPayIsDraft(loaded), meaning.payableInBatch, message)
            XCTAssertEqual(batchPayExclusionReason(orderID: "SLANT_1", order: loaded, loadFailure: nil, locked: false) == nil,
                           meaning.payableInBatch, message)

            let item: [String: Any] = ["estimatedPrintCompletion": "2026-11-02T10:00:00Z"]
            XCTAssertEqual(orderItemProgress(item, orderStatus: status) != nil, meaning.progressShown, message)
            XCTAssertEqual(orderDetailShowsTracking(status: status, hasTrackingDetails: false), meaning.trackingShownWithoutDetails, message)
            XCTAssertEqual(orderOffersProblemReport(status: status), meaning.offersProblemReport, message)
            XCTAssertEqual(orderProblemKinds(status: status).contains(.late), meaning.problemCanBeLate, message)
        }
    }

    // MARK: Slant's shipping record beside its order status (round 16)

    private struct ShippingRecordMeaning {
        let status: String
        let fulfillment: Any
        /// What the list, detail and Tracking for Your Shop show.
        let title: String
        let lags: Bool
        /// orderAttention for an order past its arrive-by date, and for one placed 6 days ago with no arrive-by date.
        let late: Bool
        let notShipped: Bool
        let progressShown: Bool
        let problemCanBeDamaged: Bool
        let problemCanBeLate: Bool
        /// The cancel review's wording (gating stays on the raw status).
        let cancelButton: String
    }

    private var shippingRecordTable: [ShippingRecordMeaning] {
        let shipped: [String: Any] = ["status": "SHIPPED", "provider": "SHIPPO", "deliveryMethod": "INTERNATIONAL",
                                      "trackingNumbers": ["TEST0001US"], "labelPrinted": true, "providerStatus": NSNull()]
        func row(_ status: String, _ fulfillment: Any, _ title: String, lags: Bool, late: Bool, notShipped: Bool,
                 progress: Bool, damaged: Bool, problemLate: Bool, cancelButton: String) -> ShippingRecordMeaning {
            ShippingRecordMeaning(status: status, fulfillment: fulfillment, title: title, lags: lags, late: late,
                                  notShipped: notShipped, progressShown: progress, problemCanBeDamaged: damaged,
                                  problemCanBeLate: problemLate, cancelButton: cancelButton)
        }
        return [
            // The live shape of 29 Oct 2026.
            row("PRINTING", shipped, "Shipped", lags: true, late: false, notShipped: false, progress: false, damaged: true,
                problemLate: true, cancelButton: "Request Refund"),
            row("SUBMITTED", shipped, "Shipped", lags: true, late: false, notShipped: false, progress: false, damaged: true,
                problemLate: true, cancelButton: "Request Refund"),
            row("PRINTING", ["status": "DELIVERED"], "Delivered", lags: true, late: false, notShipped: false, progress: false,
                damaged: true, problemLate: false, cancelButton: "Request Refund"),
            // Slant's own docs example: a label may be made before the parcel ships.
            row("PRINTING", ["status": "AWAITING_SHIPMENT", "labelPrinted": true], "Printing", lags: false, late: true,
                notShipped: true, progress: true, damaged: false, problemLate: true, cancelButton: "Cancel & Refund"),
            row("PRINTING", ["trackingNumbers": ["1Z"]], "Printing", lags: false, late: true, notShipped: true, progress: true,
                damaged: false, problemLate: true, cancelButton: "Cancel & Refund"),
            row("PRINTING", ["status": "LABEL_CREATED"], "Printing", lags: false, late: true, notShipped: true, progress: true,
                damaged: false, problemLate: true, cancelButton: "Cancel & Refund"),
            row("PRINTING", ["status": 3], "Printing", lags: false, late: true, notShipped: true, progress: true,
                damaged: false, problemLate: true, cancelButton: "Cancel & Refund"),
            row("PRINTING", "SHIPPED", "Printing", lags: false, late: true, notShipped: true, progress: true,
                damaged: false, problemLate: true, cancelButton: "Cancel & Refund"),
            row(" printing ", ["status": " shipped\n"], "Shipped", lags: true, late: false, notShipped: false, progress: false,
                damaged: true, problemLate: true, cancelButton: "Request Refund"),
            row("CANCELLED", shipped, "Cancelled", lags: false, late: false, notShipped: false, progress: false,
                damaged: false, problemLate: false, cancelButton: "Cancel Order"),
            row("DRAFT", shipped, "Draft", lags: false, late: true, notShipped: false, progress: false, damaged: false,
                problemLate: false, cancelButton: "Cancel Draft"),
            row("ON_HOLD", shipped, "On Hold", lags: false, late: false, notShipped: false, progress: true, damaged: false,
                problemLate: false, cancelButton: "Cancel Order"),
        ]
    }

    /// The shipping record changes only what is shown and read-only advice. Every write gate, the lock, pay outcomes,
    /// Pay Several Drafts and the Spending Report see exactly what they see without it.
    func testTheShippingRecordChangesOnlyWhatIsShown() throws {
        let now = try XCTUnwrap(orderTimestamp("2026-10-29T12:00:00Z"))
        let utc = try XCTUnwrap(TimeZone(identifier: "UTC"))
        for meaning in shippingRecordTable {
            let message = "\(meaning.status) + \(meaning.fulfillment)"
            let base: [String: Any] = [
                "publicId": "SLANT_1", "status": meaning.status, "createdAt": "2026-10-23T09:00:00.000Z",
                "processedAt": "2026-10-23T09:01:00.000Z", "printingCost": "14.20", "deliveryCost": "41.20",
                "items": [["type": "PRINT", "price": "14.20", "currency": "USD", "quantity": 1]],
                "metadata": ["source": "etsy", "sourceOrderId": "3141"],
                "customer": ["details": ["address": ["name": "Ada", "country": "GB"]]]
            ]
            var order = base
            order["fulfillment"] = meaning.fulfillment
            let raw = (order["status"] as? String) ?? ""

            // Shown: the list, the detail, search, Tracking for Your Shop.
            XCTAssertEqual(orderDisplayStatusTitle(order), meaning.title, message)
            XCTAssertEqual(OrderTableRow(record: Record(values: order), now: now).status, meaning.title, message)
            XCTAssertEqual(OrderTableRow(record: Record(values: order), now: now).statusSortKey, orderStatusTitle(raw), message)
            XCTAssertEqual(orderStatusLagsShippingRecord(order), meaning.lags, message)
            XCTAssertEqual(orderStatusLagNote(order) != nil, meaning.lags, message)
            XCTAssertTrue(orderMatchesSearch(Record(values: order), query: meaning.title), message)
            XCTAssertTrue(orderMatchesSearch(Record(values: order), query: orderStatusTitle(raw)), message)

            // Read-only advice.
            var late = order
            late["arriveByDate"] = "2026-10-25"
            late["createdAt"] = "2026-10-28T09:00:00.000Z"
            late["processedAt"] = "2026-10-28T09:01:00.000Z"
            if case .pastArriveBy? = orderAttention(late, now: now, timeZone: utc) {
                XCTAssertTrue(meaning.late, message)
            } else {
                XCTAssertFalse(meaning.late, message)
            }
            if case .notShipped? = orderAttention(order, now: now, timeZone: utc) {
                XCTAssertTrue(meaning.notShipped, message)
            } else {
                XCTAssertFalse(meaning.notShipped, message)
            }
            let item: [String: Any] = ["estimatedPrintCompletion": "2026-11-02T10:00:00Z"]
            XCTAssertEqual(orderItemProgress(item, orderStatus: orderDisplayStatus(order)) != nil, meaning.progressShown, message)
            let kinds = orderProblemKinds(status: orderDisplayStatus(order))
            XCTAssertEqual(kinds.contains(.damaged), meaning.problemCanBeDamaged, message)
            XCTAssertEqual(kinds.contains(.late), meaning.problemCanBeLate, message)
            XCTAssertEqual(orderCancelSheetButtonTitle(orderDisplayStatus(order)), meaning.cancelButton, message)

            // Raw only: cancel gating, the re-checks, the lock, pay outcomes, Pay Several Drafts and spend.
            XCTAssertEqual(orderCanRequestCancellation(raw), orderCanRequestCancellation((base["status"] as? String) ?? ""), message)
            XCTAssertEqual(orderCancelConfirmAllowed(status: raw, loaded: true).0,
                           orderCancelConfirmAllowed(status: meaning.status, loaded: true).0, message)
            XCTAssertEqual(workbenchCancelAllowed(status: raw, loaded: true).0,
                           workbenchCancelAllowed(status: meaning.status, loaded: true).0, message)
            for method in ["POST", "DELETE"] {
                XCTAssertEqual(orderConfirmRecheck(method: method, shown: order, latest: order),
                               orderConfirmRecheck(method: method, shown: base, latest: base), "\(method) \(message)")
            }
            XCTAssertEqual(workbenchOrderPreviewMatches(order, order), workbenchOrderPreviewMatches(base, base), message)
            XCTAssertEqual(batchPayOutcomeAfterSuccess(order), batchPayOutcomeAfterSuccess(base), message)
            XCTAssertEqual(batchPayAcceptedOutcomeStaysLocked(order), batchPayAcceptedOutcomeStaysLocked(base), message)
            XCTAssertEqual(batchPayIsDraft(order), batchPayIsDraft(base), message)
            XCTAssertEqual(batchPayExclusionReason(orderID: "SLANT_1", order: order, loadFailure: nil, locked: false),
                           batchPayExclusionReason(orderID: "SLANT_1", order: base, loadFailure: nil, locked: false), message)
            XCTAssertEqual(batchPayPlacedMarketplaceKeys([Record(values: order)]),
                           batchPayPlacedMarketplaceKeys([Record(values: base)]), message)
            let spend = spendReport(orders: [Record(values: order)], calendar: Calendar(identifier: .gregorian))
            let spendBase = spendReport(orders: [Record(values: base)], calendar: Calendar(identifier: .gregorian))
            XCTAssertEqual(spend.countedOrders, spendBase.countedOrders, message)
            XCTAssertEqual(spend.totalSpend, spendBase.totalSpend, message)
            XCTAssertEqual(spend.excludedUnrecognised, spendBase.excludedUnrecognised, message)

            // The lock records Slant's status as the review re-fetched it, and a reload of the same order (shipping
            // record and all) never counts as the cancel's outcome.
            var locks = OrderOutcomeLocks()
            locks.mark("SLANT_1", action: .cancel, reviewedStatus: order["status"] as? String)
            XCTAssertEqual(locks.contexts["SLANT_1"]?.reviewedStatus, raw.uppercased(), message)
            XCTAssertFalse(unknownOutcomeResolvedByReload(context: locks.contexts["SLANT_1"],
                                                          reloadedStatus: (order["status"] as? String) ?? ""), message)
        }
    }

    // MARK: A confirmed draft clears only its own recipient's warning

    private let date = Date(timeIntervalSince1970: 1_000)
    private let timeout = URLError(.timedOut)

    func testASuccessForAnotherCustomerKeepsTheWarning() {
        let ada = UnconfirmedDraftAttempt(recipient: "Ada Lovelace", date: date, marker: "m1", platformID: "p")
        let grace = UnconfirmedDraftAttempt(recipient: "Grace Hopper", date: date, marker: "m2", platformID: "p")
        let anonymous = UnconfirmedDraftAttempt(recipient: "", date: date, marker: "m3", platformID: "p")
        func success(_ previous: [UnconfirmedDraftAttempt], for recipient: String) -> [UnconfirmedDraftAttempt] {
            unconfirmedDraftAttempts(previous: previous, attempt: .succeeded, recipient: recipient, date: date, marker: "new")
        }
        XCTAssertEqual(success([ada, grace], for: "Grace Hopper"), [ada])
        // Trimmed, whitespace collapsed, any case.
        XCTAssertEqual(success([ada, grace], for: "  ada\t \nLOVELACE "), [grace])
        // Every attempt for that recipient goes.
        XCTAssertEqual(success([ada, grace, ada], for: "Ada Lovelace"), [grace])
        // An empty recipient (a Workbench body without a name) matches only an empty one.
        XCTAssertEqual(success([ada, anonymous], for: ""), [ada])
        XCTAssertEqual(success([ada, anonymous], for: "   "), [ada])
        XCTAssertEqual(success([ada, anonymous], for: "Ada Lovelace"), [anonymous])
        XCTAssertEqual(success([ada], for: "Ada"), [ada], "a partial name isn't the same recipient")
        XCTAssertEqual(draftAttemptRecipientKey(" Ada \u{00A0} Lovelace "), "ada lovelace")
        // The Workbench reads the recipient from the JSON body.
        XCTAssertEqual(orderDraftBodyRecipient(["customer": ["details": ["address": ["name": " Grace Hopper "]]]]), "Grace Hopper")
        XCTAssertEqual(orderDraftBodyRecipient(["items": []]), "")
        XCTAssertEqual(orderDraftBodyRecipient(nil), "")
    }

    func testDroppedAttemptsKeepTheGuardAfterAnySuccess() {
        // Six unknown outcomes: the first drops off the 5-entry list and sets the flag.
        var attempts: [UnconfirmedDraftAttempt] = []
        var overflowed = false
        for index in 0..<6 {
            let attempt = DraftCreateAttempt.failed(timeout)
            overflowed = unconfirmedDraftAttemptsOverflowed(previous: attempts, overflowed: overflowed, attempt: attempt)
            attempts = unconfirmedDraftAttempts(previous: attempts, attempt: attempt, recipient: "R\(index)", date: date)
        }
        XCTAssertTrue(overflowed)
        XCTAssertEqual(attempts.map(\.recipient), ["R1", "R2", "R3", "R4", "R5"])
        // Successes for every listed recipient empty the list, but the dropped R0 may still exist.
        for index in 1..<6 {
            overflowed = unconfirmedDraftAttemptsOverflowed(previous: attempts, overflowed: overflowed, attempt: .succeeded)
            attempts = unconfirmedDraftAttempts(previous: attempts, attempt: .succeeded, recipient: "R\(index)", date: date)
        }
        XCTAssertEqual(attempts, [])
        XCTAssertTrue(overflowed, "the guard stays for the session")
        XCTAssertTrue(draftCreateNeedsConfirmation(outcomeUnknown: !attempts.isEmpty || overflowed, confirmed: false))
        // Even a success for the dropped recipient can't clear it: Studio no longer knows who it was.
        XCTAssertTrue(unconfirmedDraftAttemptsOverflowed(previous: [], overflowed: true, attempt: .succeeded))
    }

    func testLookForDraftOnSlantIsUnchanged() {
        let a = UnconfirmedDraftAttempt(recipient: "Ada", date: date, marker: "m1")
        let b = UnconfirmedDraftAttempt(recipient: "Ada", date: date, marker: "m2")
        // Found by marker only: another attempt for the same recipient stays.
        XCTAssertEqual(unconfirmedDraftAttempts([a, b], confirmedMarkers: ["m1"]), [b])
    }
}
