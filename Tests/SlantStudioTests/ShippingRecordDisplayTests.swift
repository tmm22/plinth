import XCTest
@testable import SlantStudio

/// Round 16: Slant's order status can lag its own shipping record (29 Oct 2026: PRINTING with `fulfillment.status`
/// SHIPPED, tracking and a printed label). Studio shows the record's word and drops read-only alarms, and the cancel
/// re-check stops when the record changes; nothing here may ever enable a write.
final class ShippingRecordDisplayTests: XCTestCase {
    private func order(_ status: String = "PRINTING", fulfillment: Any? = nil, id: String = "SLANT_1") -> [String: Any] {
        var order: [String: Any] = [
            "publicId": id, "status": status, "createdAt": "2026-10-01T10:00:00.000Z",
            "processedAt": "2026-10-01T10:01:00.000Z", "printingCost": "14.20", "deliveryCost": "41.20",
            "items": [["type": "PRINT", "price": "14.20", "currency": "USD", "quantity": 1]]
        ]
        if let fulfillment { order["fulfillment"] = fulfillment }
        return order
    }
    private let shipped: [String: Any] = [
        "status": "SHIPPED", "provider": "SHIPPO", "deliveryMethod": "INTERNATIONAL", "trackingNumbers": ["TEST0001US"],
        "deliveryInstructions": NSNull(), "providerStatus": NSNull(), "labelPrinted": true
    ]

    // MARK: What the seller sees

    func testTheNoteNamesBothWordsWithoutClaimingHandover() {
        XCTAssertEqual(orderStatusLagNote(order(fulfillment: shipped)),
                       "Slant’s shipping record says Shipped; its order status still says Printing.")
        XCTAssertEqual(orderStatusLagNote(order("submitted", fulfillment: ["status": "delivered"])),
                       "Slant’s shipping record says Delivered; its order status still says Submitted.")
        XCTAssertNil(orderStatusLagNote(order(fulfillment: NSNull())))
        XCTAssertNil(orderStatusLagNote(order("SHIPPED", fulfillment: shipped)))
        let note = orderStatusLagNote(order(fulfillment: shipped)) ?? ""
        XCTAssertFalse(note.lowercased().contains("carrier"))
        XCTAssertFalse(note.contains("Canceled"))
    }

    func testTrackingForYourShopShowsTheShippingRecordsWord() throws {
        let entry = try XCTUnwrap(shopFollowUpEntry(Record(values: order(fulfillment: shipped))))
        XCTAssertEqual(entry.status, "PRINTING", "Slant's own status is kept")
        XCTAssertEqual(entry.displayStatus, "SHIPPED")
        let plain = try XCTUnwrap(shopFollowUpEntry(Record(values: order(fulfillment: ["trackingNumbers": ["1Z"]]))))
        XCTAssertEqual(plain.displayStatus, "PRINTING")
    }

    func testSortingStaysOnSlantsStatus() {
        let lagging = OrderTableRow(record: Record(values: order(fulfillment: shipped, id: "A")))
        let printing = OrderTableRow(record: Record(values: order(id: "B")))
        let shippedRow = OrderTableRow(record: Record(values: order("SHIPPED", id: "C")))
        XCTAssertEqual(lagging.status, "Shipped")
        XCTAssertEqual(lagging.statusSortKey, "Printing")
        XCTAssertNotNil(lagging.statusNote)
        XCTAssertNil(printing.statusNote)
        let sorted = orderTableRowsSorted([shippedRow, lagging, printing], using: [KeyPathComparator(\OrderTableRow.statusSortKey)])
        XCTAssertEqual(sorted.map(\.id), ["A", "B", "C"])
    }

    func testStatusFilterHint() {
        let lagging = Record(values: order(fulfillment: shipped))
        let plain = Record(values: order())
        XCTAssertEqual(orderStatusFilterLagHintText(status: "SHIPPED", loaded: []), orderStatusFilterLagHint)
        XCTAssertEqual(orderStatusFilterLagHintText(status: "PRINTING", loaded: [plain, lagging]), orderStatusFilterLagHint)
        XCTAssertNil(orderStatusFilterLagHintText(status: "PRINTING", loaded: [plain]))
        XCTAssertNil(orderStatusFilterLagHintText(status: nil, loaded: [lagging]))
        XCTAssertNil(orderStatusFilterLagHintText(status: "DRAFT", loaded: [lagging]))
        XCTAssertTrue(orderFilterEmptyDetail(OrderFilter(status: "SHIPPED")).hasSuffix(orderStatusFilterLagHint))
        XCTAssertTrue(orderFilterEmptyDetail(OrderFilter(status: "SHIPPED"), moreOnServer: true).hasSuffix(orderStatusFilterLagHint))
        XCTAssertEqual(orderFilterEmptyDetail(OrderFilter(status: "PRINTING")), "No orders with the status “Printing”.")
        let notes = spendReportScopeNotes(searchActive: false, statusFilter: "SHIPPED", hasDateRange: false, moreOnServer: false)
        XCTAssertEqual(notes.count, 1)
        XCTAssertTrue(notes[0].hasSuffix(orderStatusFilterLagHint))
        XCTAssertFalse(spendReportScopeNotes(searchActive: false, statusFilter: "PRINTING", hasDateRange: false,
                                             moreOnServer: false)[0].contains("shipping record"))
    }

    // MARK: Read-only advice

    func testAShippedPerRecordOrderIsNeverLateOrStuck() throws {
        let now = try XCTUnwrap(orderTimestamp("2026-10-29T12:00:00Z"))
        var late = order(fulfillment: shipped)
        late["arriveByDate"] = "2026-10-25"
        XCTAssertNil(orderAttention(late, now: now))
        XCTAssertNil(orderAttention(order(fulfillment: shipped), now: now))
        // Without the record, both alarms stand.
        late["fulfillment"] = NSNull()
        XCTAssertEqual(orderAttention(late, now: now), .pastArriveBy(try XCTUnwrap(orderArriveByDate(late))))
        if case .notShipped? = orderAttention(order(), now: now) {} else { XCTFail("expected Not shipped") }
        // A record that only says a label is waiting removes nothing.
        if case .notShipped? = orderAttention(order(fulfillment: ["status": "AWAITING_SHIPMENT", "labelPrinted": true]), now: now) {} else {
            XCTFail("expected Not shipped")
        }
        // A payment problem is never hidden by a record.
        XCTAssertEqual(orderAttention(order("PAYMENT_ERROR", fulfillment: shipped), now: now), .paymentProblem)
    }

    func testTheProblemMessageCarriesBothWords() {
        let message = orderProblemMessage(order: order(fulfillment: shipped), problem: .damaged, details: "")
        XCTAssertTrue(message.contains("Status: Printing · Shipping record: Shipped"), message)
        XCTAssertTrue(message.contains("Tracking number: TEST0001US"))
        let same = orderProblemMessage(order: order("SHIPPED", fulfillment: shipped), problem: .damaged, details: "")
        XCTAssertTrue(same.contains("Status: Shipped\n"), same)
        XCTAssertFalse(same.contains("Shipping record"))
        let waiting = orderProblemMessage(order: order(fulfillment: ["status": "AWAITING_SHIPMENT"]), problem: .late, details: "")
        XCTAssertTrue(waiting.contains("Status: Printing · Shipping record: Awaiting shipment"), waiting)
        let bare = orderProblemMessage(order: order(fulfillment: ["status": 3]), problem: .late, details: "")
        XCTAssertTrue(bare.contains("Status: Printing\n"), bare)
    }

    // MARK: Cancelling

    func testTheCancelReviewSaysSlantMayOnlyRefund() {
        let lagging = order(fulfillment: shipped)
        XCTAssertEqual(orderCancelSheetBody(order: lagging),
                       "Slant’s shipping record says this order has shipped, so Slant may only refund it; it can’t stop the delivery.")
        XCTAssertEqual(orderCancelSheetTitle(orderDisplayStatus(lagging)), "Request a refund?")
        XCTAssertEqual(orderCancelActionTitle(orderDisplayStatus(lagging)), "Request Refund…")
        XCTAssertTrue(orderCancellationIsRefundOnly(orderDisplayStatus(lagging)))
        // Everything else keeps its own wording.
        XCTAssertEqual(orderCancelSheetBody(order: order()), orderCancelSheetBody("PRINTING"))
        XCTAssertEqual(orderCancelSheetBody(order: order(fulfillment: ["status": "AWAITING_SHIPMENT"])), orderCancelSheetBody("PRINTING"))
        XCTAssertEqual(orderCancelSheetBody(order: order("SHIPPED", fulfillment: shipped)), orderCancelSheetBody("SHIPPED"))
        XCTAssertEqual(orderCancelSheetBody(order: nil), orderCancelSheetBody(""))
        // Offering Cancel is still Slant's status alone.
        XCTAssertTrue(orderCanRequestCancellation("PRINTING"))
        XCTAssertFalse(orderCanRequestCancellation((order("CANCELLED", fulfillment: shipped)["status"] as? String) ?? ""))
    }

    func testTheCancelReCheckStopsWhenShippingDetailsChange() {
        let shown = order()
        let blocked = OrderConfirmRecheckResult.statusBlocked(orderShippingDetailsChangedMessage)
        // A record appeared, changed, or its tracking changed: stop, whatever the order status says.
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shown, latest: order(fulfillment: shipped)), blocked)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: order(fulfillment: ["status": "AWAITING_SHIPMENT"]),
                                           latest: order(fulfillment: ["status": "SHIPPED"])), blocked)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: order(fulfillment: shipped),
                                           latest: order(fulfillment: ["status": "SHIPPED", "trackingNumbers": ["TEST0001US", "NEW"]])), blocked)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: order(fulfillment: shipped), latest: order(fulfillment: NSNull())), blocked)
        // Unchanged details, including null vs absent and a reordered or repeated tracking list, go on as before.
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shown, latest: order(fulfillment: NSNull())), .proceed)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: order(fulfillment: shipped), latest: order(fulfillment: shipped)), .proceed)
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE",
                                           shown: order(fulfillment: ["status": "SHIPPED", "trackingNumbers": ["A", "B"]]),
                                           latest: order(fulfillment: ["status": " shipped ", "trackingNumbers": ["B", "A", "A"]])),
                       .proceed)
        // It only adds a stop: a status change or an uncancellable status still stops with its own reason.
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shown, latest: order("SHIPPED", fulfillment: shipped)),
                       .statusBlocked("This order’s status changed. Review it again."))
        if case .proceed = orderConfirmRecheck(method: "DELETE", shown: order("CANCELLED", fulfillment: shipped),
                                               latest: order("CANCELLED", fulfillment: shipped)) {
            XCTFail("a cancelled order is never cancellable")
        }
    }

    func testPayIsNeverBlockedByAShippingRecord() {
        let draft = order("DRAFT")
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: draft, latest: order("DRAFT", fulfillment: shipped)), .proceed)
        XCTAssertNil(workbenchCancelShippingDetailsMessage(method: "POST", preview: draft, fresh: order("DRAFT", fulfillment: shipped)))
        // Nor can a record ever make a non-draft payable.
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: order(fulfillment: shipped), latest: order(fulfillment: shipped)),
                       .statusBlocked("Only drafts can be placed."))
    }

    func testTheWorkbenchCancelStopsToo() {
        XCTAssertEqual(workbenchCancelShippingDetailsMessage(method: "DELETE", preview: order(), fresh: order(fulfillment: shipped)),
                       orderShippingDetailsChangedMessage)
        XCTAssertNil(workbenchCancelShippingDetailsMessage(method: "DELETE", preview: order(fulfillment: shipped),
                                                          fresh: order(fulfillment: shipped)))
        XCTAssertNil(workbenchCancelShippingDetailsMessage(method: "GET", preview: order(), fresh: order(fulfillment: shipped)))
    }

    // MARK: The display status never reaches a write path

    /// A source check: the display status and its helpers appear only in display and read-only advice code, never in
    /// the files or lines that decide pay, cancel, the lock, Pay Several Drafts or spend.
    func testTheDisplayStatusStaysOutOfEveryWritePath() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SlantStudio")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        let displayNames = ["orderDisplayStatus", "orderStatusLagsShippingRecord", "copyStatus", "orderStatusLagNote"]
        let forbiddenFiles = ["BatchPay.swift", "SpendReport.swift", "StudioStore.swift", "APIWorkbenchView.swift"]
        let writeNames = ["orderCanRequestCancellation", "orderConfirmRecheck", "markOutcomeUnknown", "reviewedStatus",
                          "batchPayOutcomeAfterSuccess", "batchPayAcceptedOutcomeStaysLocked", "orderPlacedStatuses",
                          "spendReportCountedStatuses", "unknownOutcomeResolvedByReload", "orderCancelConfirmAllowed",
                          "workbenchCancelAllowed", "orderConfirmFinalActionEnabled", "workbenchChargeAllowed",
                          "canCancelSelected", "batchPayIsDraft", "batchPayExclusionReason"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            if forbiddenFiles.contains(name) {
                for display in displayNames {
                    XCTAssertFalse(text.contains(display), "\(name) uses \(display)")
                }
            }
            for line in text.components(separatedBy: "\n") where displayNames.contains(where: line.contains) {
                for write in writeNames {
                    XCTAssertFalse(line.contains(write), "\(name): \(line)")
                }
            }
        }
    }
}
