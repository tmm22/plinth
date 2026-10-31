import XCTest
@testable import Plinth

/// Report a Problem's late-order advice (Slant and 3DAPI) and reprints linked to their original order.
/// Every order number, tracking number and date here is made up.
final class ProblemReprintTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var now: Date { date("2026-11-05T12:00:00Z") }

    private func slantOrder(_ status: String, processedAt: String? = "2026-10-29T09:00:00Z",
                            fulfillment: Any? = nil) -> [String: Any] {
        var order: [String: Any] = ["publicId": "SLANT_TEST1", "status": status, "createdAt": "2026-10-28T09:00:00Z"]
        if let processedAt { order["processedAt"] = processedAt }
        order["fulfillment"] = fulfillment ?? NSNull()
        return order
    }

    // MARK: Days ago

    func testDaysAgoCountsCalendarDays() {
        XCTAssertEqual(problemReportDaysAgoText(date("2026-11-05T01:00:00Z"), now: now, calendar: calendar), "today")
        XCTAssertEqual(problemReportDaysAgoText(date("2026-11-04T23:00:00Z"), now: now, calendar: calendar), "yesterday")
        XCTAssertEqual(problemReportDaysAgoText(date("2026-10-29T09:00:00Z"), now: now, calendar: calendar), "7 days ago")
        // A date after now (a wrong clock) gives no age rather than a negative one.
        XCTAssertNil(problemReportDaysAgoText(date("2026-11-07T09:00:00Z"), now: now, calendar: calendar))
        XCTAssertEqual(problemReportDateWithAge(date("2026-10-29T09:00:00Z"), now: now, calendar: calendar),
                       "29 October 2026 (7 days ago)")
    }

    // MARK: Slant late stage

    func testLateStageTellsSlantFromTheCarrier() {
        XCTAssertEqual(orderLateStage(slantOrder("PRINTING")), .atSlant)
        XCTAssertEqual(orderLateStage(slantOrder("SUBMITTED")), .atSlant)
        // A record without tracking (a label not made yet) is still at Slant.
        XCTAssertEqual(orderLateStage(slantOrder("PRINTING", fulfillment: ["status": "AWAITING_SHIPMENT"])), .atSlant)
        // Shipped by Slant's status, or by its shipping record while the status lags.
        XCTAssertEqual(orderLateStage(slantOrder("SHIPPED")), .withCarrier)
        XCTAssertEqual(orderLateStage(slantOrder("PRINTING", fulfillment: ["status": "SHIPPED", "trackingNumbers": ["TEST0001"]])), .withCarrier)
        // A label exists (tracking) though the record doesn't say shipped yet.
        XCTAssertEqual(orderLateStage(slantOrder("PRINTING", fulfillment: ["trackingNumbers": ["TEST0001"]])), .withCarrier)
        // A shipping record date means a label was made, even before Slant lists a tracking number.
        XCTAssertEqual(orderLateStage(slantOrder("PRINTING", fulfillment: ["createdAt": "2026-11-02T10:00:00Z"])), .withCarrier)
        for status in ["DRAFT", "CANCELLED", "CANCELED", "PAYMENT_ERROR", "SOMETHING_NEW", ""] {
            XCTAssertNil(orderLateStage(slantOrder(status)), status)
        }
    }

    func testLateGuidanceOnlyForLateAndByStage() throws {
        let atSlant = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder("PRINTING")))
        XCTAssertTrue(atSlant.contains("the delay is at Slant"), atSlant)
        let shipped = slantOrder("SHIPPED", fulfillment: ["status": "SHIPPED", "trackingNumbers": ["TEST0001"]])
        let carrier = try XCTUnwrap(orderProblemGuidance(.late, order: shipped))
        XCTAssertTrue(carrier.contains("most likely a carrier delay"), carrier)
        XCTAssertTrue(carrier.contains("Check the tracking first"), carrier)
        let noTracking = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder("SHIPPED")))
        XCTAssertTrue(noTracking.contains("hasn’t listed a tracking number"), noTracking)
        let labelOnly = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder("PRINTING", fulfillment: ["trackingNumbers": ["T1"]])))
        XCTAssertTrue(labelOnly.contains("made a shipping label"), labelOnly)
        for kind in OrderProblemKind.allCases where kind != .late {
            XCTAssertNil(orderProblemGuidance(kind, order: shipped), kind.title)
        }
        XCTAssertNil(orderProblemGuidance(.late, order: slantOrder("CANCELLED")))
        // The status shown is trimmed and read in any case before the shipped check.
        let padded = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder(" shipped ", fulfillment: ["trackingNumbers": ["T1"]])))
        XCTAssertTrue(padded.contains("most likely a carrier delay"), padded)
        // A label made without a tracking number yet: with the carrier, asking for the number.
        let recordOnly = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder("PRINTING", fulfillment: ["createdAt": "2026-11-02T10:00:00Z"])))
        XCTAssertTrue(recordOnly.contains("made a shipping label"), recordOnly)
        XCTAssertTrue(recordOnly.contains("hasn’t listed a tracking number"), recordOnly)
        // Never a claim window or a promise.
        for text in [atSlant, carrier, noTracking, labelOnly, padded, recordOnly] {
            for word in ["within", "claim", "guarantee", "refund"] { XCTAssertFalse(text.lowercased().contains(word), word) }
        }
    }

    func testLateMessageAddsSlantsOwnDatesOnly() {
        let atSlant = orderProblemMessage(order: slantOrder("PRINTING"), problem: .late, details: "", now: now, calendar: calendar)
        XCTAssertTrue(atSlant.contains("Paid: 29 October 2026 (7 days ago)"), atSlant)
        XCTAssertTrue(atSlant.contains("Shipping label: not made yet"), atSlant)
        // Without processedAt nothing is guessed (createdAt is when the draft was made, not paid).
        let unpaidDate = orderProblemMessage(order: slantOrder("PRINTING", processedAt: nil), problem: .late, details: "",
                                             now: now, calendar: calendar)
        XCTAssertFalse(unpaidDate.contains("Paid:"), unpaidDate)
        XCTAssertTrue(unpaidDate.contains("Shipping label: not made yet"))
        let shipped = slantOrder("PRINTING", fulfillment: ["status": "SHIPPED", "createdAt": "2026-11-02T10:00:00Z",
                                                          "trackingNumbers": ["TEST0001", "TEST0002"]])
        let carrier = orderProblemMessage(order: shipped, problem: .late, details: "", now: now, calendar: calendar)
        XCTAssertTrue(carrier.contains("Tracking number: TEST0001"), carrier)
        XCTAssertTrue(carrier.contains("Tracking number: TEST0002"), carrier)
        XCTAssertTrue(carrier.contains("Shipping label created: 2 November 2026 (3 days ago)"), carrier)
        XCTAssertFalse(carrier.contains("not made yet"))
        XCTAssertFalse(carrier.contains("Paid:"))
        // Other problems keep the message as it was.
        let damaged = orderProblemMessage(order: shipped, problem: .damaged, details: "", now: now, calendar: calendar)
        XCTAssertFalse(damaged.contains("Shipping label created"))
        let unknown = orderProblemMessage(order: slantOrder("CANCELLED"), problem: .late, details: "", now: now, calendar: calendar)
        XCTAssertFalse(unknown.contains("Paid:"))
        XCTAssertFalse(unknown.contains("Shipping label"))
    }

    func testLateAdviceAtSlantUsesTheSellersUsualTime() throws {
        // Paid Thursday 29 Oct; read on Thursday 5 Nov: 5 business days.
        let typical = OrderShipTimeSummary(orders: 5, fewest: 3, most: 4, median: 3)
        let late = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder("PRINTING"), typical: typical, now: now, timeZone: utc))
        XCTAssertTrue(late.contains("Paid 5 business days ago; your recent orders usually got a shipping label after 3."), late)
        XCTAssertTrue(late.contains("the delay is at Slant"), late)
        XCTAssertFalse(late.contains("may not be late"), late)
        // Paid Wednesday 4 Nov: 1 business day, under the usual 3.
        let early = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder("SUBMITTED", processedAt: "2026-11-04T09:00:00Z"),
                                                       typical: typical, now: now, timeZone: utc))
        XCTAssertTrue(early.contains("Paid 1 business day ago; your recent orders usually got a shipping label after 3. It may not be late yet."), early)
        // Without a usual time, or a paid date, the plain advice.
        let plain = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder("PRINTING"), typical: nil, now: now, timeZone: utc))
        XCTAssertFalse(plain.contains("usually"))
        let unpaid = try XCTUnwrap(orderProblemGuidance(.late, order: slantOrder("PRINTING", processedAt: nil), typical: typical, now: now, timeZone: utc))
        XCTAssertFalse(unpaid.contains("usually"))
        for text in [late, early] {
            for word in ["within", "claim", "guarantee", "refund", "median"] { XCTAssertFalse(text.lowercased().contains(word), word) }
        }
    }

    func testTrackParcelOnlyForALateOrderWithARecognisedCarrier() {
        let shipped = slantOrder("SHIPPED", fulfillment: ["provider": "SHIPPO", "trackingNumbers": ["LS123456785US"]])
        XCTAssertEqual(orderProblemTrackingCarrier(.late, order: shipped)?.name, "USPS")
        XCTAssertNil(orderProblemTrackingCarrier(.damaged, order: shipped))
        XCTAssertNil(orderProblemTrackingCarrier(nil, order: shipped))
        XCTAssertNil(orderProblemTrackingCarrier(.late, order: slantOrder("SHIPPED", fulfillment: ["trackingNumbers": ["TEST0001"]])),
                     "not recognised")
        XCTAssertNil(orderProblemTrackingCarrier(.late, order: slantOrder("SHIPPED", fulfillment: ["provider": "UPS", "trackingNumbers": ["LS123456785US"]])),
                     "never another carrier than the one Slant named")
        XCTAssertNil(orderProblemTrackingCarrier(.late, order: slantOrder("PRINTING")), "still at Slant")
        let dapiShipped = insightOrder(status: .shipped, tracking: "1Z999AA10123456784")
        XCTAssertEqual(dapiProblemTrackingCarrier(.late, order: dapiShipped)?.name, "UPS")
        XCTAssertNil(dapiProblemTrackingCarrier(.late, order: insightOrder(status: .shipped, carrier: "DHL", tracking: "1Z999AA10123456784")))
        XCTAssertNil(dapiProblemTrackingCarrier(.late, order: insightOrder(status: .paid, tracking: "1Z999AA10123456784")))
        XCTAssertNil(dapiProblemTrackingCarrier(.other, order: dapiShipped))
    }

    // MARK: 3DAPI late stage

    func testDapiLateGuidanceAndMessage() throws {
        let paid = insightOrder(status: .paid, created: date("2026-10-30T10:00:00Z"))
        XCTAssertEqual(dapiLateStage(paid), .notShipped)
        let notShipped = try XCTUnwrap(dapiProblemGuidance(.late, order: paid))
        XCTAssertTrue(notShipped.contains("hasn’t shipped this order yet"), notShipped)
        let message = dapiProblemMessage(order: paid, problem: .late, details: "", timeZone: utc, now: now)
        XCTAssertTrue(message.contains("Shipped: not yet (created 6 days ago)"), message)

        let shipped = insightOrder(status: .shipped, carrier: "DHL", tracking: "JD0001")
        XCTAssertEqual(dapiLateStage(shipped), .withCarrier)
        XCTAssertTrue(try XCTUnwrap(dapiProblemGuidance(.late, order: shipped)).contains("most likely a carrier delay"))
        XCTAssertTrue(dapiProblemMessage(order: shipped, problem: .late, details: "", timeZone: utc, now: now).contains("Tracking number: JD0001"))
        let shippedNoTracking = insightOrder(status: .shipped)
        XCTAssertTrue(try XCTUnwrap(dapiProblemGuidance(.late, order: shippedNoTracking)).contains("hasn’t given a tracking number"))

        // Other kinds and statuses keep the earlier guidance.
        XCTAssertEqual(dapiProblemGuidance(.lostParcel, order: shipped), dapiProblemGuidance(.lostParcel))
        XCTAssertNil(dapiLateStage(insightOrder(status: .cancelled)))
        XCTAssertNil(dapiLateStage(insightOrder(status: .unknown("weird"))))
        let other = dapiProblemMessage(order: paid, problem: .other, details: "", timeZone: utc, now: now)
        XCTAssertFalse(other.contains("not yet"))
    }

    func testDapiReprintFollowsDuplicate() {
        let withLines = insightOrder(status: .shipped, items: [insightItem(1)])
        XCTAssertNil(dapiReprintBlockedReason(withLines, duplicateBlockedReason: nil))
        XCTAssertEqual(dapiReprintBlockedReason(withLines, duplicateBlockedReason: "Close it first."), "Close it first.")
        XCTAssertNotNil(dapiReprintBlockedReason(insightOrder(status: .shipped, items: nil), duplicateBlockedReason: nil))
        XCTAssertNotNil(dapiReprintBlockedReason(insightOrder(status: .shipped, items: []), duplicateBlockedReason: nil))
        XCTAssertTrue(dapiReprintButtonHelp.contains("Place Order"))
    }

    // MARK: Reprint metadata

    private func fields(_ count: Int) -> [String: Any] {
        Dictionary(uniqueKeysWithValues: (0..<count).map { ("field\($0)", "value\($0)") })
    }

    func testReprintLinkAddedAfterTheMarkerWithinTheCap() {
        let marked = orderMetadataAddingDraftMarker([:], marker: "abc")
        let linked = orderMetadataAddingReprintOf(marked, original: "  SLANT_TEST1 ")
        XCTAssertEqual(linked[orderReprintOfKey] as? String, "SLANT_TEST1")
        XCTAssertEqual(linked[studioDraftMarkerKey] as? String, "abc")
        // 8 seller fields: marker and link both fit (10).
        let eight = orderMetadataAddingReprintOf(orderMetadataAddingDraftMarker(fields(8), marker: "abc"), original: "SLANT_TEST1")
        XCTAssertEqual(eight.count, 10)
        XCTAssertNotNil(eight[orderReprintOfKey])
        // 9 seller fields: the marker takes the last one, and the link is left out (never the marker or a seller field).
        let nine = orderMetadataAddingReprintOf(orderMetadataAddingDraftMarker(fields(9), marker: "abc"), original: "SLANT_TEST1")
        XCTAssertEqual(nine.count, 10)
        XCTAssertNotNil(nine[studioDraftMarkerKey])
        XCTAssertNil(nine[orderReprintOfKey])
        for key in fields(9).keys { XCTAssertNotNil(nine[key], key) }
        // 10 seller fields: neither is added.
        XCTAssertEqual(orderMetadataAddingReprintOf(orderMetadataAddingDraftMarker(fields(10), marker: "abc"), original: "SLANT_TEST1").count, 10)
        // The seller's own reprintOf is kept as typed.
        let own = orderMetadataAddingReprintOf(["reprintOf": "mine"], original: "SLANT_TEST1")
        XCTAssertEqual(own["reprintOf"] as? String, "mine")
        // Nothing to link, or not an order number.
        XCTAssertNil(orderMetadataAddingReprintOf([:], original: nil)[orderReprintOfKey])
        XCTAssertNil(orderMetadataAddingReprintOf([:], original: "   ")[orderReprintOfKey])
        XCTAssertNil(orderMetadataAddingReprintOf([:], original: "A\nB")[orderReprintOfKey])
        XCTAssertNil(orderMetadataAddingReprintOf([:], original: String(repeating: "9", count: 101))[orderReprintOfKey])
    }

    func testReprintLinkNoteAgreesWithCreateDraft() throws {
        XCTAssertNil(orderReprintLinkNote(original: nil, sellerMetadata: [:]))
        // Normally one short line, with no internal key names.
        XCTAssertEqual(orderReprintLinkNote(original: "SLANT_TEST1", sellerMetadata: [:]), "Marked as a reprint of order SLANT_TEST1.")
        XCTAssertEqual(orderReprintLinkNote(original: " SLANT_TEST1 ", sellerMetadata: fields(8)), "Marked as a reprint of order SLANT_TEST1.")
        // The longer explanation only when the link can't go with the draft.
        let full = try XCTUnwrap(orderReprintLinkNote(original: "SLANT_TEST1", sellerMetadata: fields(9)))
        XCTAssertTrue(full.contains("full") && full.contains("won’t be marked"), full)
        XCTAssertFalse(full.contains(orderReprintOfKey), full)
        let own = try XCTUnwrap(orderReprintLinkNote(original: "SLANT_TEST1", sellerMetadata: ["reprintOf": "x"]))
        XCTAssertTrue(own.contains("already include") && own.contains("won’t mark"), own)
        for unusable in [String(repeating: "9", count: 101), "A\nB"] {
            let note = try XCTUnwrap(orderReprintLinkNote(original: unusable, sellerMetadata: [:]))
            XCTAssertTrue(note.contains("can’t be recorded"), note)
            XCTAssertFalse(note.contains(unusable))
            // It agrees with Create Draft, which adds no link either.
            XCTAssertNil(orderMetadataAddingReprintOf([:], original: unusable)[orderReprintOfKey])
        }
    }

    func testDuplicatePrefillCopiesNoMetadataAndOnlyAReprintNamesItsOriginal() throws {
        let order = Record(values: [
            "publicId": "SLANT_TEST1", "status": "SHIPPED",
            "metadata": ["source": "etsy", "sourceOrderId": "1234", "sourceShop": "x.myshopify.com", "sourceItems": "1",
                         "studioDraftId": "abc", "reprintOf": "SLANT_OLD"],
            "items": [["type": "PRINT", "quantity": 1, "printItem": ["publicFileServiceId": "f1"]]]
        ])
        let duplicate = orderComposerPrefill(reordering: order)
        XCTAssertNil(duplicate.reprintOf)
        XCTAssertEqual(duplicate.sourceOrderNumber, "SLANT_TEST1")
        let reprint = orderComposerPrefill(reordering: order, asReprint: true)
        // A reprint of a reprint names the order the problem was reported on, never the older original.
        XCTAssertEqual(reprint.reprintOf, "SLANT_TEST1")
        XCTAssertEqual(reprint.lines.count, duplicate.lines.count)
        XCTAssertEqual(orderComposerHeading(sourceOrderNumber: reprint.sourceOrderNumber, isReprint: true), "Reprint of order SLANT_TEST1")
        XCTAssertEqual(orderComposerHeading(sourceOrderNumber: "SLANT_TEST1"), "Duplicate of order SLANT_TEST1")
        XCTAssertEqual(orderComposerHeading(sourceOrderNumber: nil, isReprint: true), "New order draft")
        // The prefill has no metadata at all, so the marketplace keys the duplicate checks read are never copied.
        let labels = Mirror(reflecting: reprint).children.compactMap(\.label)
        XCTAssertFalse(labels.contains { $0.lowercased().contains("metadata") }, "\(labels)")
    }

    func testReprintOfReaderAndOriginal() throws {
        XCTAssertEqual(orderReprintOf(["metadata": ["reprintOf": " SLANT_TEST1 "]]), "SLANT_TEST1")
        XCTAssertEqual(orderReprintOf(["order": ["metadata": ["reprintOf": 12345]]]), "12345")
        XCTAssertNil(orderReprintOf(["metadata": ["reprintOf": true]]))
        XCTAssertNil(orderReprintOf(["metadata": ["reprintOf": ["x": 1]]]))
        XCTAssertNil(orderReprintOf(["metadata": ["reprintOf": ""]]))
        XCTAssertNil(orderReprintOf(["metadata": NSNull()]))
        XCTAssertNil(orderReprintOf([:]))
        XCTAssertEqual(orderReprintOfLine(["metadata": ["reprintOf": "SLANT_TEST1"]]), "Reprint of order SLANT_TEST1")

        let original = Record(values: ["publicId": "SLANT_TEST1", "status": "SHIPPED"])
        let reprint: [String: Any] = ["publicId": "SLANT_TEST2", "metadata": ["reprintOf": "SLANT_TEST1"]]
        XCTAssertEqual(orderReprintOriginal(of: reprint, loaded: [Record(values: reprint), original])?.id, "SLANT_TEST1")
        XCTAssertNil(orderReprintOriginal(of: reprint, loaded: [Record(values: reprint)]), "original not loaded")
        let selfLinked: [String: Any] = ["publicId": "SLANT_TEST2", "metadata": ["reprintOf": "SLANT_TEST2"]]
        XCTAssertNil(orderReprintOriginal(of: selfLinked, loaded: [Record(values: selfLinked)]))
        XCTAssertTrue(orderReprintButtonHelp(orderNumber: "SLANT_TEST1").contains("reprint of order SLANT_TEST1"))
        XCTAssertFalse(orderReprintButtonHelp(orderNumber: "").contains("reprint of order"))
        XCTAssertFalse(orderReprintButtonHelp(orderNumber: "SLANT_TEST1").contains(orderReprintOfKey))
    }

    // MARK: Spending Report reprints

    func testReprintSpendUsesTheReportsRules() {
        func order(_ number: String, _ status: String, total: String = "10.00", currency: String? = nil,
                   reprintOf: String? = "SLANT_ORIG", created: String? = "2026-10-20T10:00:00Z") -> Record {
            var values: [String: Any] = ["publicId": number, "status": status, "printingCost": total, "deliveryCost": "0"]
            if let created { values["createdAt"] = created }
            if let currency { values["currency"] = currency }
            if let reprintOf { values["metadata"] = ["reprintOf": reprintOf] }
            return Record(values: values)
        }
        let records = [
            order("R1", "SUBMITTED", total: "12.50"),
            order("R1", "SUBMITTED", total: "12.50"),      // repeated in the list: counted once
            order("R2", "SHIPPED", total: "7.25"),
            order("R3", "DRAFT"),                           // not spend
            order("R4", "CANCELLED"),                       // not spend
            order("R5", "SOMETHING_NEW"),                   // unknown: not spend
            order("R6", "PRINTING", currency: "EUR"),       // counted, but no USD total
            order("R7", "PRINTING", created: nil),          // undated: the report leaves it out
            order("N1", "SHIPPED", total: "99.00", reprintOf: nil)
        ]
        let reprints = spendReportReprints(orders: records)
        XCTAssertEqual(reprints.orders, 3)
        XCTAssertEqual(reprints.spend, Decimal(string: "19.75"))
        XCTAssertEqual(reprints.ordersWithoutTotal, 1)
        let line = spendReportReprintLine(reprints) ?? ""
        XCTAssertTrue(line.hasPrefix("3 reprints cost $19.75"), line)
        XCTAssertTrue(line.contains("1 has no USD total"), line)
        XCTAssertTrue(spendReportReprintText(reprints).contains("Reprints\n"))
        XCTAssertTrue(spendReportReprintCSV(reprints).contains("Reprints,3,19.75,1"))
        XCTAssertNil(spendReportReprintLine(SpendReportReprints()))
        XCTAssertEqual(spendReportReprintText(SpendReportReprints()), "")
        XCTAssertEqual(spendReportReprintCSV(SpendReportReprints()), "")
        // Inside the main report's totals, never added on top.
        let report = spendReport(orders: records)
        XCTAssertEqual(report.countedOrders, 4)
        XCTAssertEqual(report.undated, 1)
    }
}
