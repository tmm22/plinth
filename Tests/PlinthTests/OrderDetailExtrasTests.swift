import XCTest
@testable import SlantStudio

final class OrderDetailExtrasTests: XCTestCase {
    private let gb = Locale(identifier: "en_GB")
    private let utc = TimeZone(identifier: "UTC")!
    private var now: Date { ISO8601DateFormatter().date(from: "2026-10-23T12:00:00Z")! }

    // MARK: Production progress

    /// The live draft shape (23 Oct 2026): status PROCESSING, an empty `assignments` and a null estimate.
    private var liveDraftItem: [String: Any] {
        ["status": "PROCESSING", "estimatedPrintCompletion": NSNull(), "quantity": 1, "type": "PRINT",
         "printItem": ["assignments": [Any](), "estimatedPrintCompletion": NSNull(), "publicFileServiceId": "f1"]]
    }

    func testNothingShownForDraftsOrWithoutProgressFields() {
        XCTAssertNil(orderItemProgress(liveDraftItem, orderStatus: "DRAFT"))
        // Item status alone is not progress, whatever the order's status.
        XCTAssertNil(orderItemProgress(liveDraftItem, orderStatus: "QUEUED"))
        XCTAssertNil(orderItemProgress(["status": "PROCESSING"], orderStatus: "PRINTING"))
        // A draft never shows progress even if fields are present.
        let busy: [String: Any] = ["printItem": ["assignments": [["status": "PRINTING"]]]]
        XCTAssertNil(orderItemProgress(busy, orderStatus: "draft"))
        for finished in ["CANCELED", "SHIPPED", "DELIVERED", "PAYMENT_ERROR"] {
            XCTAssertNil(orderItemProgress(busy, orderStatus: finished), finished)
        }
        XCTAssertNotNil(orderItemProgress(busy, orderStatus: "PRINTING"))
    }

    func testStageFromNestedOrFlatAssignments() {
        let nested: [String: Any] = ["printItem": ["assignments": [["status": "PRINTING", "krakenStatus": "X", "printer": ["model": "MK4"]]]]]
        XCTAssertEqual(orderItemProgress(nested, orderStatus: "PRINTING")?.stage, "Printing")
        let flat: [String: Any] = ["assignments": [["status": "ON_SHELF"]]]
        XCTAssertEqual(orderItemProgress(flat, orderStatus: "ITEMS_ON_SHELF")?.stage, "On the shelf")
        // printItem wins when both carry assignments, so nothing is counted twice.
        let both: [String: Any] = ["assignments": [["status": "QUEUED"]], "printItem": ["assignments": [["status": "PRINTING"]]]]
        XCTAssertEqual(orderItemProgress(both, orderStatus: "PRINTING")?.stage, "Printing")
    }

    func testMixedAssignmentsAreCountedInPipelineOrder() {
        let assignments: [[String: Any]] = [
            ["status": "ON_SHELF"], ["status": "printing"], ["status": "PRINTING"], ["status": "QUEUED"], ["status": "WEIRD_STEP"]
        ]
        XCTAssertEqual(orderAssignmentStageSummary(assignments), "1 in queue · 2 printing · 1 on the shelf · 1 weird step")
        XCTAssertEqual(orderAssignmentStageSummary([["status": "PRINTING"], ["status": "PRINTING"]]), "Printing")
        XCTAssertEqual(orderAssignmentStageSummary([["status": "ITEMS_ON_SHELF"], ["status": "ON_SHELF"]]), "On the shelf")
    }

    func testOddAssignmentShapesAreIgnored() {
        XCTAssertNil(orderAssignmentStageSummary([]))
        XCTAssertNil(orderAssignmentStageSummary([["status": 3], ["status": NSNull()], ["status": "  "], [:]]))
        let odd: [String: Any] = ["printItem": ["assignments": ["PRINTING", 4, NSNull()]], "assignments": "PRINTING"]
        XCTAssertTrue(orderItemAssignments(odd).isEmpty)
        XCTAssertNil(orderItemProgress(odd, orderStatus: "PRINTING"))
        let notArray: [String: Any] = ["printItem": "nope", "estimatedPrintCompletion": true]
        XCTAssertNil(orderItemProgress(notArray, orderStatus: "PRINTING"))
    }

    func testEstimateParsing() {
        XCTAssertEqual(orderProgressDate("2026-10-24T15:10:00Z")?.date, ISO8601DateFormatter().date(from: "2026-10-24T15:10:00Z"))
        XCTAssertNotNil(orderProgressDate("2026-10-24T15:10:00.123Z"))
        XCTAssertEqual(orderProgressDate("2026-10-24")?.dateOnly, true)
        XCTAssertEqual(orderProgressDate(1_792_854_600_000)?.date, Date(timeIntervalSince1970: 1_792_854_600))
        XCTAssertEqual(orderProgressDate(1_792_854_600)?.date, Date(timeIntervalSince1970: 1_792_854_600))
        for bad: Any in [NSNull(), true, false, "", "soon", "24/10/2026", 0, -5, 12, Double.nan, ["at": "x"], "1890-01-01T00:00:00Z"] {
            XCTAssertNil(orderProgressDate(bad), "\(bad)")
        }
        XCTAssertNil(orderProgressDate(nil))
    }

    func testEstimateFromFlatItemThenPrintItem() {
        let flat: [String: Any] = ["estimatedPrintCompletion": "2026-10-24T15:10:00Z",
                                   "printItem": ["estimatedPrintCompletion": "2026-11-01T00:00:00Z"]]
        XCTAssertEqual(orderItemProgress(flat, orderStatus: "QUEUED")?.estimatedCompletion,
                       ISO8601DateFormatter().date(from: "2026-10-24T15:10:00Z"))
        let nested: [String: Any] = ["estimatedPrintCompletion": NSNull(),
                                     "printItem": ["estimatedPrintCompletion": "2026-11-01T00:00:00Z"]]
        XCTAssertEqual(orderItemProgress(nested, orderStatus: "QUEUED")?.estimatedCompletion,
                       ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z"))
    }

    func testProgressLineFormatting() {
        let date = ISO8601DateFormatter().date(from: "2026-10-24T15:10:00Z")!
        let text = orderProgressDateText(date, now: now, locale: gb, timeZone: utc)
        XCTAssertTrue(text.contains("24 Oct"), text)
        XCTAssertTrue(text.contains("15:10"), text)
        XCTAssertFalse(text.contains("2026"), text)
        let nextYear = orderProgressDateText(ISO8601DateFormatter().date(from: "2027-01-02T09:00:00Z")!, now: now, locale: gb, timeZone: utc)
        XCTAssertTrue(nextYear.contains("2027"), nextYear)
        let both = orderItemProgressLine(OrderItemProgress(stage: "Printing", estimatedCompletion: date), now: now, locale: gb, timeZone: utc)
        XCTAssertEqual(both, "Printing · due to finish \(text)")
        XCTAssertEqual(orderItemProgressLine(OrderItemProgress(stage: "On the shelf"), now: now, locale: gb, timeZone: utc), "On the shelf")
        let dayOnly = orderItemProgressLine(OrderItemProgress(stage: nil, estimatedCompletion: orderProgressDate("2026-10-24")!.date, estimateIsDateOnly: true),
                                            now: now, locale: gb, timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(dayOnly, "Due to finish 24 Oct")
        XCTAssertNil(orderItemProgressLine(OrderItemProgress(), now: now, locale: gb, timeZone: utc))
    }

    // MARK: Label address

    private func order(shipping: [String: Any]?, label: Any?) -> [String: Any] {
        var order: [String: Any] = ["status": "SHIPPED"]
        if let shipping { order["customer"] = ["details": ["email": "a@example.com", "address": shipping]] }
        if let label { order["fulfillment"] = ["address": label] }
        return order
    }
    private let shipping: [String: Any] = ["name": "Ada", "line1": "123 Main Street", "city": "Springfield", "zip": "62704", "country": "US", "state": "IL"]

    func testMatchingLabelAddressesShowNothing() {
        let label: [String: Any] = ["street1": "123 MAIN ST.", "city": " springfield ", "postalCode": "62704-1234", "country": "United States"]
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: shipping, label: label)))
        // Missing either side, or a label without comparable parts, shows nothing.
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: shipping, label: nil)))
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: nil, label: label)))
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: shipping, label: NSNull())))
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: shipping, label: ["name": "Ada"])))
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: shipping, label: ["city": "SPRINGFIELD", "zip": 62704])))
        var gbShipping = shipping
        gbShipping["zip"] = "SW1A 1AA"; gbShipping["country"] = "GB"; gbShipping["city"] = "London"; gbShipping["line1"] = "10 Downing Street"
        // A unit number on the label's line 2 but on the order's line 1 is the same street.
        XCTAssertTrue(orderLabelAddressDifferences(
            label: OrderComparableAddress(line1: "123 Main St", line2: "Apt 4", city: "Springfield"),
            shipping: OrderComparableAddress(line1: "123 Main Street, Apartment 4", city: "Springfield")).isEmpty)
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: gbShipping, label: ["line1": "10 Downing St", "city": "LONDON", "zip": "sw1a1aa", "country": "gb"])))
    }

    func testDifferentLabelAddressIsNamed() {
        let label: [String: Any] = ["line1": "125 Main Street", "city": "Springfield", "zip": "62705", "country": "US", "state": "IL"]
        let advisory = orderLabelAddressAdvisory(order(shipping: shipping, label: label))
        XCTAssertEqual(advisory?.line, "The shipping label was made for: 125 Main Street, Springfield, IL, 62705, US. Check with Slant if this is wrong.")
        XCTAssertEqual(advisory?.differences, ["street", "postcode"])
        let otherCountry = orderLabelAddressDifferences(
            label: OrderComparableAddress(line1: "", city: "Springfield", zip: "", country: "CA"),
            shipping: OrderComparableAddress(line1: "123 Main St", city: "Springfield", zip: "62704", country: "US"))
        XCTAssertEqual(otherCountry, ["country"])
    }

    /// Live Slant nests the label address like the order's own details: `fulfillment.address` is
    /// `{email, address: {name, line1, line2, city, state, zip, country}}` (invented values here).
    func testNestedLiveLabelAddressIsCompared() {
        func nested(_ address: [String: Any]) -> [String: Any] { ["email": "label@example.com", "address": address] }
        let same: [String: Any] = ["name": "Ada", "line1": "123 MAIN ST", "line2": "", "city": "SPRINGFIELD", "state": "IL",
                                   "zip": "62704", "country": "US"]
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: shipping, label: nested(same))))
        var otherCity = same; otherCity["city"] = "Shelbyville"
        let advisory = orderLabelAddressAdvisory(order(shipping: shipping, label: nested(otherCity)))
        XCTAssertEqual(advisory?.differences, ["city"])
        XCTAssertEqual(advisory?.line, "The shipping label was made for: 123 MAIN ST, Shelbyville, IL, 62704, US. Check with Slant if this is wrong.")
        // The label's email and name are never shown.
        XCTAssertFalse(advisory?.line.contains("label@example.com") ?? true)
        XCTAssertFalse(advisory?.line.contains("Ada") ?? true)
        // A nested object without comparable parts shows nothing.
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: shipping, label: nested(["name": "Ada"]))))
        XCTAssertNil(orderLabelAddressAdvisory(order(shipping: shipping, label: ["email": "label@example.com", "address": NSNull()])))
    }

    func testProblemReportCaptionNamesSlantSupportAsTextOnly() {
        XCTAssertTrue(orderProblemReportCaption.contains("support@slant3d.com"))
        XCTAssertFalse(orderProblemReportCaption.contains("mailto:"))
        XCTAssertTrue(orderProblemReportCaption.contains("doesn’t send anything"))
    }

    func testPostcodeMatching() {
        XCTAssertTrue(orderPostcodesMatch("62704", "62704-1234"))
        XCTAssertTrue(orderPostcodesMatch("627041234", "62704"))
        XCTAssertTrue(orderPostcodesMatch("SW1A 1AA", "sw1a1aa"))
        XCTAssertFalse(orderPostcodesMatch("62704", "62705-1234"))
        XCTAssertFalse(orderPostcodesMatch("2000", "20001"))
    }

    // MARK: Support message

    func testProblemMessageHasOrderFactsButNoPersonalDetails() {
        let order: [String: Any] = [
            "publicId": "SLANT_123", "status": "DELIVERED", "createdAt": "2026-10-20T10:00:00Z",
            "customer": ["details": ["email": "ada@example.com", "address": ["name": "Ada Lovelace", "line1": "1 Secret Lane", "city": "London"]]],
            "fulfillment": ["trackingNumbers": ["1Z999"]],
            "items": [
                ["quantity": 2, "name": "Bracket", "filamentName": "PLA Black"],
                ["quantity": 1, "type": "PRINT", "printItem": ["publicFileServiceId": "f1"]]
            ]
        ]
        let message = orderProblemMessage(order: order, problem: .damaged, details: "  Arrived cracked.  ", modelNames: ["f1": "Clip"])
        XCTAssertTrue(message.contains("I’d like to report a problem with order SLANT_123: damaged item."))
        XCTAssertTrue(message.contains("Order number: SLANT_123"))
        XCTAssertTrue(message.contains("Status: Delivered"))
        XCTAssertTrue(message.contains("Tracking number: 1Z999"))
        XCTAssertTrue(message.contains("Problem: Damaged item"))
        XCTAssertTrue(message.contains("- 2 × Bracket (PLA Black)"))
        XCTAssertTrue(message.contains("- 1 × Clip"))
        XCTAssertTrue(message.contains("What happened:\nArrived cracked.\n"))
        for secret in ["Ada", "Lovelace", "Secret Lane", "ada@example.com", "London"] {
            XCTAssertFalse(message.contains(secret), secret)
        }
    }

    func testProblemMessageWithSparseOrder() {
        let message = orderProblemMessage(order: [:], problem: .other, details: " ")
        XCTAssertTrue(message.contains("a problem with my order: other."))
        XCTAssertFalse(message.contains("Items:"))
        XCTAssertFalse(message.contains("What happened"))
        XCTAssertTrue(message.hasSuffix("Thank you."))
        XCTAssertEqual(OrderProblemKind.allCases.map(\.title),
                       ["Damaged item", "Wrong item", "Missing item", "Print defect", "Late delivery", "Other"])
    }

    func testProblemReportOfferedOnlyForPlacedOrders() {
        XCTAssertFalse(orderOffersProblemReport(status: "DRAFT"))
        XCTAssertFalse(orderOffersProblemReport(status: " draft "))
        XCTAssertFalse(orderOffersProblemReport(status: ""))
        XCTAssertTrue(orderOffersProblemReport(status: "DELIVERED"))
        XCTAssertTrue(orderOffersProblemReport(status: "PRINTING"))
    }

    // MARK: Next draft

    private let rows: [(id: String, status: String)] = [
        ("a", "PAID"), ("b", "DRAFT"), ("c", "draft"), ("d", "QUEUED"), ("e", "DRAFT"), ("", "DRAFT")
    ]

    func testNextDraftFollowsListOrderAndSkipsLockedAndNonDrafts() {
        XCTAssertEqual(orderNextDraftToReview(rows: rows, after: nil, isLocked: { _ in false }), "b")
        XCTAssertEqual(orderNextDraftToReview(rows: rows, after: "b", isLocked: { _ in false }), "c")
        XCTAssertEqual(orderNextDraftToReview(rows: rows, after: "c", isLocked: { _ in false }), "e")
        XCTAssertEqual(orderNextDraftToReview(rows: rows, after: "b", isLocked: { $0 == "c" }), "e")
        XCTAssertEqual(orderNextDraftToReview(rows: rows, after: "a", isLocked: { $0 != "e" }), "e")
        XCTAssertNil(orderNextDraftToReview(rows: rows, after: nil, isLocked: { _ in true }))
    }

    func testNextDraftStopsAtTheEndAndNeverReturnsTheCurrentOrder() {
        // The last draft has nothing after it; it never wraps round to "b".
        XCTAssertNil(orderNextDraftToReview(rows: rows, after: "e", isLocked: { _ in false }))
        XCTAssertNil(orderNextDraftToReview(rows: [], after: nil, isLocked: { _ in false }))
        XCTAssertNil(orderNextDraftToReview(rows: [("x", "DRAFT")], after: "x", isLocked: { _ in false }))
        // A current order no longer in the list starts from the top but is never offered again itself.
        XCTAssertEqual(orderNextDraftToReview(rows: rows, after: "gone", isLocked: { _ in false }), "b")
        let duplicate: [(id: String, status: String)] = [("b", "DRAFT"), ("z", "DRAFT")]
        XCTAssertEqual(orderNextDraftToReview(rows: duplicate, after: "missing", isLocked: { _ in false }), "b")
        // A just-placed order whose list row still says DRAFT is skipped because it is the current one.
        XCTAssertEqual(orderNextDraftToReview(rows: [("p", "DRAFT"), ("q", "DRAFT")], after: "p", isLocked: { _ in false }), "q")
    }

    func testProblemKindsFitTheStatus() {
        XCTAssertEqual(orderProblemKinds(status: "PRINTING"), [.late, .other])
        XCTAssertEqual(orderProblemKinds(status: "awaiting_shipment"), [.late, .other])
        XCTAssertEqual(orderProblemKinds(status: "SHIPPED"), [.damaged, .wrongItem, .missingItem, .printDefect, .late, .other])
        XCTAssertEqual(orderProblemKinds(status: " DELIVERED "), [.damaged, .wrongItem, .missingItem, .printDefect, .other])
        for status in ["CANCELED", "PAYMENT_ERROR", "SOMETHING_NEW", ""] {
            XCTAssertEqual(orderProblemKinds(status: status), [.other], status)
        }
    }

    func testNextDraftUsesTheSnapshotWithCurrentStatuses() {
        // The list when the run began: b, then c, then e. Since then b was paid and, with Needs Attention on, has
        // left the visible list, and the list was re-sorted; the snapshot still says c comes next.
        let orders = [
            Record(values: ["publicId": "e", "status": "DRAFT"]),
            Record(values: ["publicId": "c", "status": "DRAFT"]),
            Record(values: ["publicId": "b", "status": "PAID"]),
            Record(values: ["publicId": "d", "status": "DRAFT"])
        ]
        let snapshot = ["a", "b", "c", "e"]
        let rows = orderDraftReviewRows(snapshotIDs: snapshot, orders: orders)
        XCTAssertEqual(rows.map(\.id), snapshot)
        XCTAssertEqual(rows.map(\.status), ["", "PAID", "DRAFT", "DRAFT"], "an order no longer loaded has no status")
        XCTAssertEqual(orderNextDraftToReview(rows: rows, after: "b", isLocked: { _ in false }), "c")
        // Paid meanwhile (status now from the store) and locked orders are skipped; d, added later, is never offered.
        var paid = orders
        paid[1] = Record(values: ["publicId": "c", "status": "PAID"])
        let later = orderDraftReviewRows(snapshotIDs: snapshot, orders: paid)
        XCTAssertEqual(orderNextDraftToReview(rows: later, after: "b", isLocked: { _ in false }), "e")
        XCTAssertNil(orderNextDraftToReview(rows: later, after: "b", isLocked: { $0 == "e" }))
        XCTAssertNil(orderNextDraftToReview(rows: rows, after: "e", isLocked: { _ in false }), "never wraps round")
        XCTAssertTrue(orderDraftReviewRows(snapshotIDs: [], orders: orders).isEmpty)
    }

    func testReviewRowsReadSlantStatusAndCaptions() {
        let records = [Record(values: ["publicId": "o1", "status": "DRAFT"]), Record(values: ["order": ["publicId": "o2", "status": "PAID"]])]
        let mapped = orderDraftReviewRows(records)
        XCTAssertEqual(mapped.map(\.status), ["DRAFT", "PAID"])
        XCTAssertEqual(orderNextDraftCaption(recipient: "Ada", number: "SLANT_1"), "Next: Ada · SLANT_1")
        XCTAssertEqual(orderNextDraftCaption(recipient: "Order", number: "SLANT_1"), "Next: SLANT_1")
        XCTAssertEqual(orderNextDraftCaption(recipient: " ", number: ""), "Next: another draft")
    }
}
