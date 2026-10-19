import XCTest
@testable import SlantStudio

final class OrdersUXTests: XCTestCase {
    func testStatusTitlesCoverKnownAndFallback() {
        XCTAssertEqual(orderStatusTitle("DRAFT"), "Draft")
        XCTAssertEqual(orderStatusTitle("PAID"), "Paid")
        XCTAssertEqual(orderStatusTitle("QUEUED"), "In queue")
        XCTAssertEqual(orderStatusTitle("PROCESSING"), "Processing")
        XCTAssertEqual(orderStatusTitle("PRINTING"), "Printing")
        XCTAssertEqual(orderStatusTitle("ITEMS_ON_SHELF"), "On the shelf")
        XCTAssertEqual(orderStatusTitle("POST_PROCESSING"), "Finishing")
        XCTAssertEqual(orderStatusTitle("COMPLETED"), "Printed")
        XCTAssertEqual(orderStatusTitle("IN_REVIEW"), "In review")
        XCTAssertEqual(orderStatusTitle("AWAITING_SHIPMENT"), "Awaiting shipment")
        XCTAssertEqual(orderStatusTitle("SHIPPED"), "Shipped")
        XCTAssertEqual(orderStatusTitle("DELIVERED"), "Delivered")
        XCTAssertEqual(orderStatusTitle("CANCELED"), "Canceled")
        XCTAssertEqual(orderStatusTitle("PAYMENT_ERROR"), "Payment problem")
        XCTAssertEqual(orderStatusTitle("weird_status"), "Weird Status")
    }

    func testCancellationEligibilityAndBlockedReasons() {
        for status in orderKnownStatuses where status != "CANCELED" {
            XCTAssertTrue(orderCanRequestCancellation(status), status)
            XCTAssertNil(orderCancellationBlockedReason(status), status)
        }
        XCTAssertTrue(orderKnownStatuses.contains("PROCESSING"))
        XCTAssertFalse(orderCanRequestCancellation("CANCELED"))
        XCTAssertFalse(orderCanRequestCancellation(""))
        XCTAssertFalse(orderCanRequestCancellation("UNKNOWN"))
        XCTAssertEqual(orderCancellationBlockedReason("CANCELED"), "This order was already canceled.")
        XCTAssertTrue(orderCancellationIsRefundOnly("SHIPPED"))
        XCTAssertTrue(orderCancellationIsRefundOnly("DELIVERED"))
        XCTAssertFalse(orderCancellationIsRefundOnly("PRINTING"))
        XCTAssertFalse(orderCancellationIsRefundOnly("DRAFT"))
    }

    func testCancelActionCopyMatrix() {
        XCTAssertEqual(orderCancelActionTitle("DRAFT"), "Cancel Draft…")
        XCTAssertEqual(orderCancelSheetButtonTitle("DRAFT"), "Cancel Draft")
        XCTAssertEqual(orderCancelSheetBody("DRAFT"), "Nothing has been charged.")
        XCTAssertEqual(orderCancelActionTitle("QUEUED"), "Cancel & Refund…")
        XCTAssertEqual(orderCancelActionTitle("PRINTING"), "Cancel & Refund…")
        XCTAssertEqual(orderCancelActionTitle("AWAITING_SHIPMENT"), "Cancel & Refund…")
        XCTAssertEqual(orderCancelActionTitle("PROCESSING"), "Cancel & Refund…")
        XCTAssertEqual(orderCancelSheetButtonTitle("PROCESSING"), "Cancel & Refund")
        XCTAssertEqual(orderCancelActionTitle("SHIPPED"), "Request Refund…")
        XCTAssertEqual(orderCancelSheetButtonTitle("DELIVERED"), "Request Refund")
        XCTAssertEqual(orderCancelActionTitle("PAYMENT_ERROR"), "Cancel Order…")
        XCTAssertFalse(orderCancelSheetBody("PAYMENT_ERROR").localizedCaseInsensitiveContains("will refund"))
    }

    func testEmailValidationAcceptsReasonableAddresses() {
        XCTAssertTrue(isEmailAddress("buyer@example.com"))
        XCTAssertTrue(isEmailAddress("  name+tag@sub.domain.io "))
        XCTAssertFalse(isEmailAddress(""))
        XCTAssertFalse(isEmailAddress("not-an-email"))
        XCTAssertFalse(isEmailAddress("@missing.local"))
        XCTAssertFalse(isEmailAddress("missing@"))
        XCTAssertFalse(isEmailAddress("spaces emma@example.com"))
    }

    func testDraftPayloadOmitsEmptyOptionsAndMetadata() throws {
        let body = try orderDraftPayload(
            platformID: "platform", ownerID: "", email: "buyer@example.com", recipientName: "Buyer",
            line1: "1 Main St", line2: "", city: "Austin", state: "TX", zip: "78701", country: "US",
            paymentID: "", metadata: [:], options: [:],
            lines: [OrderLine(reference: "file", filamentID: "filament", quantity: 1)]
        )
        XCTAssertNil(body["metadata"])
        XCTAssertNil(body["options"])
        XCTAssertNil(body["ownerId"])
        let item = try XCTUnwrap((body["items"] as? [[String: Any]])?.first)
        XCTAssertNil(item["options"])
        XCTAssertEqual((body["customer"] as? [String: Any]).flatMap { ($0["details"] as? [String: Any])?["address"] as? [String: String] }?["country"], "US")
    }

    func testDraftPayloadStateRequiredOnlyForUSCAAU() throws {
        XCTAssertTrue(orderStateIsRequired("US"))
        XCTAssertTrue(orderStateIsRequired("ca"))
        XCTAssertTrue(orderStateIsRequired("AU"))
        XCTAssertFalse(orderStateIsRequired("GB"))
        XCTAssertFalse(orderStateIsRequired("DE"))

        XCTAssertThrowsError(try orderDraftPayload(
            platformID: "platform", ownerID: "", email: "buyer@example.com", recipientName: "Buyer",
            line1: "1 Main", line2: "", city: "Austin", state: "", zip: "78701", country: "US",
            paymentID: "", metadata: [:], options: [:],
            lines: [OrderLine(reference: "file", filamentID: "filament")]
        ))

        let gb = try orderDraftPayload(
            platformID: "platform", ownerID: "", email: "buyer@example.com", recipientName: "Buyer",
            line1: "1 High St", line2: "", city: "London", state: "", zip: "SW1A", country: "GB",
            paymentID: "", metadata: [:], options: [:],
            lines: [OrderLine(reference: "file", filamentID: "filament")]
        )
        let gbAddress = try XCTUnwrap(((gb["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any])
        XCTAssertNil(gbAddress["state"])
        XCTAssertEqual(gbAddress["country"] as? String, "GB")

        let de = try orderDraftPayload(
            platformID: "platform", ownerID: "", email: "buyer@example.com", recipientName: "Buyer",
            line1: "1 Strasse", line2: "", city: "Berlin", state: "BE", zip: "10115", country: "DE",
            paymentID: "", metadata: [:], options: [:],
            lines: [OrderLine(reference: "file", filamentID: "filament")]
        )
        let deAddress = try XCTUnwrap(((de["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any])
        XCTAssertEqual(deAddress["state"] as? String, "BE")
    }

    func testOrderLinePayloadOmitsEmptyOptionsObject() throws {
        let item = try OrderLine(reference: "file", filamentID: "filament", optionsJSON: "{}").payload()
        XCTAssertNil(item["options"])
    }

    func testOrderItemHelpersAndTotal() {
        XCTAssertEqual(orderItemDisplayName(["name": "Widget"]), "Widget")
        XCTAssertEqual(orderItemDisplayName(["type": "PRINT"]), "Print")
        XCTAssertEqual(orderItemDisplayName(["componentItem": ["componentName": "Bracket"]]), "Bracket")
        XCTAssertEqual(orderItemDisplayName(["stationeryItem": ["stationeryName": "Card"]]), "Card")
        XCTAssertEqual(orderItemDisplayName(["printItem": ["name": "Gadget"]]), "Gadget")
        XCTAssertEqual(orderItemMaterialName(["filamentName": "PLA Black"]), "PLA Black")
        let filaments = [Record(values: ["id": "fil-1", "name": "PETG Blue"])]
        XCTAssertEqual(orderItemMaterialName(["printItem": ["filamentId": "fil-1"]], filaments: filaments), "PETG Blue")
        XCTAssertEqual(orderTotalMoney(["printingCost": "10.00", "deliveryCost": "2.50"]), "$12.50")
        XCTAssertEqual(orderTotalMoney(["total": "99.00"]), "$99.00")
    }

    func testCountryChoicesIncludeRequiredISOCodes() {
        let codes = Set(orderCountryChoices.map(\.code))
        for required in ["US", "CA", "GB", "AU", "NZ", "IE", "DE", "FR", "NL", "JP"] {
            XCTAssertTrue(codes.contains(required), required)
        }
        XCTAssertEqual(orderCountryOtherTag, "__OTHER__")
    }

    func testOrderObjectUnwrapsEnvelopeForSummaryAndTracking() {
        let envelope: [String: Any] = [
            "order": [
                "status": "SHIPPED",
                "printingCost": "10.00",
                "deliveryCost": "3.00",
                "publicId": "SLANT_SHIP_1",
                "items": [["name": "Widget", "quantity": 2]],
                "customer": ["details": ["address": ["name": "Ada Lovelace", "city": "London"]]],
                "fulfillment": [
                    "provider": "UPS",
                    "deliveryMethod": "Ground",
                    "status": "IN_TRANSIT",
                    "trackingNumbers": ["1Z999AA10123456784"]
                ]
            ] as [String: Any]
        ]
        let order = orderObject(envelope)
        XCTAssertEqual(order["status"] as? String, "SHIPPED")
        XCTAssertEqual(orderStatusTitle(order["status"] as? String ?? ""), "Shipped")
        XCTAssertEqual(orderTotalMoney(order), "$13.00")
        XCTAssertEqual(orderItemDisplayName((order["items"] as? [[String: Any]])?.first ?? [:]), "Widget")
        let facts = trackingFacts(order["fulfillment"])
        XCTAssertEqual(facts.first(where: { $0.0 == "Carrier" })?.1, "UPS")
        XCTAssertEqual(facts.first(where: { $0.0 == "Service" })?.1, "Ground")
        XCTAssertEqual(facts.first(where: { $0.0 == "Shipment status" })?.1, "IN_TRANSIT")
        XCTAssertEqual(facts.first(where: { $0.0 == "Tracking number" })?.1, "1Z999AA10123456784")
        XCTAssertEqual(orderObject(order)["status"] as? String, "SHIPPED", "Already-unwrapped orders stay unchanged")
    }

    func testTrackingFactsLegacyKeysStillWork() {
        let facts = trackingFacts([
            "carrier": "USPS",
            "service": "Priority",
            "trackingNumber": "9400",
            "trackingUrl": "https://example.com/t/9400"
        ] as [String: Any])
        XCTAssertEqual(facts.first(where: { $0.0 == "Carrier" })?.1, "USPS")
        XCTAssertEqual(facts.first(where: { $0.0 == "Service" })?.1, "Priority")
        XCTAssertEqual(facts.first(where: { $0.0 == "Tracking number" })?.1, "9400")
        XCTAssertEqual(facts.first(where: { $0.0 == "Tracking link" })?.1, "https://example.com/t/9400")
    }

    func testMergeOrderDraftEnvelopePrefersOrderFields() {
        let data: [String: Any] = [
            "order": [
                "publicId": "SLANT_1",
                "status": "DRAFT",
                "printingCost": "9.00",
                "items": [["name": "FromOrder"]]
            ],
            "items": [["name": "FromEnvelope"]],
            "totals": ["printingCost": "1.00", "deliveryCost": "2.00", "totalCost": "3.00"],
            "customer": ["details": ["address": ["name": "Buyer"]]]
        ]
        let merged = mergeOrderDraftEnvelope(data)
        XCTAssertEqual((merged["items"] as? [[String: Any]])?.first?["name"] as? String, "FromOrder")
        XCTAssertEqual(merged["printingCost"] as? String, "9.00")
        XCTAssertEqual(merged["deliveryCost"] as? String, "2.00")
        XCTAssertEqual(merged["totalCost"] as? String, "3.00")
        XCTAssertEqual(orderRecipientName(merged), "Buyer")
    }

    func testShippingProviderAndMetadataPayload() throws {
        XCTAssertTrue(orderShippingOptions(provider: "").isEmpty)
        XCTAssertEqual(orderShippingOptions(provider: "shippo")["shippingProvider"] as? String, "SHIPPO")
        var fields = [OrderMetadataField(key: "source", value: "studio"), OrderMetadataField(key: "batch", value: "1")]
        let metadata = try orderMetadataDictionary(fields)
        XCTAssertEqual(metadata["source"] as? String, "studio")
        XCTAssertEqual(metadata.count, 2)
        fields.append(OrderMetadataField(key: "source", value: "dup"))
        XCTAssertThrowsError(try orderMetadataDictionary(fields))
        let body = try orderDraftPayload(
            platformID: "platform", ownerID: "", email: "buyer@example.com", recipientName: "Buyer",
            line1: "1 Main", line2: "", city: "Austin", state: "TX", zip: "78701", country: "US",
            paymentID: "", metadata: metadata, options: orderShippingOptions(provider: "SHIPSTATION"),
            lines: [OrderLine(reference: "file", filamentID: "filament")]
        )
        XCTAssertEqual((body["options"] as? [String: String])?["shippingProvider"], "SHIPSTATION")
        XCTAssertEqual((body["metadata"] as? [String: String])?["source"], "studio")
    }

    func testUnavailableMaterialDetection() {
        let available = Record(values: ["id": "a", "name": "PLA", "available": true])
        let unavailable = Record(values: ["id": "b", "name": "ABS", "available": false])
        XCTAssertFalse(orderLinesUseUnavailableMaterial([OrderLine(reference: "f", filamentID: "a")], filaments: [available, unavailable]))
        XCTAssertTrue(orderLinesUseUnavailableMaterial([OrderLine(reference: "f", filamentID: "b")], filaments: [available, unavailable]))
        XCTAssertEqual(filamentAvailabilityLabel(unavailable), "Out of stock")
    }

    func testOrderSearchMatchesDisplayFieldsNotRawJSONKeys() {
        let record = Record(values: [
            "publicId": "SLANT_42",
            "status": "SHIPPED",
            "customer": ["details": ["address": ["name": "Ada Lovelace", "city": "London"]]],
            "items": [["name": "Widget"]],
            "secretNoise": "should-not-matter"
        ])
        XCTAssertTrue(orderMatchesSearch(record, query: "Ada"))
        XCTAssertTrue(orderMatchesSearch(record, query: "london"))
        XCTAssertTrue(orderMatchesSearch(record, query: "Widget"))
        XCTAssertTrue(orderMatchesSearch(record, query: "Shipped"))
        XCTAssertTrue(orderMatchesSearch(record, query: "SLANT_42"))
        XCTAssertFalse(orderMatchesSearch(record, query: "secretNoise"))
        XCTAssertEqual(orderDetailCaption(orderObject(record.values)), "Order for Ada Lovelace")
    }

    func testPlatformMissingUsesPlainLanguage() {
        XCTAssertThrowsError(try orderDraftPayload(
            platformID: " ", ownerID: "", email: "buyer@example.com", recipientName: "Buyer",
            line1: "1 Main", line2: "", city: "Austin", state: "TX", zip: "78701", country: "US",
            paymentID: "", metadata: [:], options: [:],
            lines: [OrderLine(reference: "file", filamentID: "filament")]
        )) { error in
            XCTAssertEqual((error as? StudioError)?.message, "Choose a platform first.")
        }
    }

    func testOtherCountryCodeValidation() throws {
        XCTAssertTrue(isCountryCode("us"))
        XCTAssertTrue(isCountryCode("AU"))
        XCTAssertFalse(isCountryCode("USA"))
        XCTAssertEqual(try normalizedCountryCode(" au "), "AU")
        XCTAssertThrowsError(try normalizedCountryCode("Australia"))
    }

    func testStationeryImageURLRequiresHTTPSHost() throws {
        XCTAssertTrue(isHTTPSImageURL("https://cdn.example.com/card.png"))
        XCTAssertFalse(isHTTPSImageURL("http://cdn.example.com/card.png"))
        let ok = try OrderLine(type: "STATIONERY", reference: "card", imageURL: "https://cdn.example.com/a.png").payload()
        XCTAssertEqual(ok["imageUrl"] as? String, "https://cdn.example.com/a.png")
        XCTAssertThrowsError(try OrderLine(type: "STATIONERY", reference: "card", imageURL: "http://insecure.example/a.png").payload())
    }

    func testDecimalAmountUsesPOSIXLocale() {
        let posix = Locale(identifier: "en_US_POSIX")
        XCTAssertEqual(decimalAmount("12.50"), Decimal(string: "12.50", locale: posix))
        XCTAssertNotEqual(decimalAmount("12,50"), Decimal(string: "12.50", locale: posix))
        XCTAssertEqual(orderTotalMoney(["printingCost": "4.06", "deliveryCost": "1.00"]), "$5.06")
    }

    func testFreshStatusGatesPayAndCancel() {
        XCTAssertTrue(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: ["total": "12.50"]).0)
        XCTAssertTrue(orderCancelConfirmAllowed(status: "PRINTING", loaded: true).0)
        XCTAssertTrue(orderCancelConfirmAllowed(status: "PROCESSING", loaded: true).0)
        XCTAssertTrue(orderCancelConfirmAllowed(status: "SHIPPED", loaded: true).0)
        XCTAssertFalse(orderCancelConfirmAllowed(status: "CANCELED", loaded: true).0)
    }

    func testLineValidationUsesPlainLanguage() {
        XCTAssertThrowsError(try OrderLine(reference: "  ").payload()) { error in
            XCTAssertEqual((error as? StudioError)?.message, "Choose an item and a quantity of at least 1 for every line.")
        }
    }

    func testConfirmRecheckDetectsStatusAndPriceChanges() {
        let shown: [String: Any] = ["status": "DRAFT", "printingCost": "10.00", "deliveryCost": "2.00"]
        XCTAssertEqual(orderConfirmRecheck(method: "POST", shown: shown, latest: shown), .proceed)
        XCTAssertEqual(
            orderConfirmRecheck(method: "POST", shown: shown, latest: ["status": "PAID", "printingCost": "10.00", "deliveryCost": "2.00"]),
            .statusBlocked("Only drafts can be placed.")
        )
        let awaiting: [String: Any] = ["status": "AWAITING_SHIPMENT", "printingCost": "10.00", "deliveryCost": "2.00"]
        let shipped: [String: Any] = ["status": "SHIPPED", "printingCost": "10.00", "deliveryCost": "2.00"]
        XCTAssertEqual(
            orderConfirmRecheck(method: "DELETE", shown: awaiting, latest: shipped),
            .statusBlocked("This order’s status changed. Review it again.")
        )
        XCTAssertEqual(orderConfirmRecheck(method: "DELETE", shown: shipped, latest: shipped), .proceed)
        XCTAssertEqual(
            orderConfirmRecheck(method: "DELETE", shown: shown, latest: ["status": "CANCELED", "printingCost": "10.00", "deliveryCost": "2.00"]),
            .statusBlocked("This order’s status changed. Review it again.")
        )
    }

    func testPayRecheckRequiresNumericTotals() {
        let blank: [String: Any] = ["status": "DRAFT"]
        XCTAssertEqual(
            orderConfirmRecheck(method: "POST", shown: blank, latest: blank),
            .statusBlocked("Couldn’t confirm a total for this order.")
        )
        XCTAssertFalse(workbenchOrderHasNumericTotal(blank))
        XCTAssertEqual(orderTotalMoney(blank), "—")
    }

    func testConfirmLoadStateTransitions() {
        XCTAssertEqual(orderConfirmLoadStateAfterRun(succeeded: true, skippedBusy: false), .loaded)
        XCTAssertEqual(orderConfirmLoadStateAfterRun(succeeded: false, skippedBusy: true), .loading)
        XCTAssertEqual(orderConfirmLoadStateAfterRun(succeeded: false, skippedBusy: false), .failed)
    }

    func testBusySkipStaysLoadingNotFailed() {
        XCTAssertEqual(orderConfirmLoadStateAfterRun(succeeded: false, skippedBusy: true), .loading)
        XCTAssertNotEqual(orderConfirmLoadStateAfterRun(succeeded: false, skippedBusy: true), .failed)
    }

    func testWriteSuccessKeepsFinalActionDisabledEvenIfPreviewStillDraft() {
        let withTotal: [String: Any] = ["total": "12.50"]
        XCTAssertFalse(orderConfirmFinalActionEnabled(writeSucceeded: true, loaded: true, status: "DRAFT", isPay: true, order: withTotal))
        XCTAssertTrue(orderConfirmFinalActionEnabled(writeSucceeded: false, loaded: true, status: "DRAFT", isPay: true, order: withTotal))
        XCTAssertFalse(orderConfirmFinalActionEnabled(writeSucceeded: false, loaded: true, status: "DRAFT", isPay: true, order: nil))
    }

    func testWriteAttemptLocksActionAfterUnknownOutcome() {
        let withTotal: [String: Any] = ["total": "12.50"]
        XCTAssertEqual(orderConfirmMutationSendAllowed(attempted: false, succeeded: false).0, true)
        XCTAssertNil(orderConfirmMutationSendAllowed(attempted: false, succeeded: false).1)
        let locked = orderConfirmMutationSendAllowed(attempted: true, succeeded: false)
        XCTAssertFalse(locked.0)
        XCTAssertEqual(locked.1, "The result is unknown. Reload the order before trying again.")
        XCTAssertFalse(orderConfirmFinalActionEnabled(
            writeSucceeded: false, writeAttempted: true, loaded: true, status: "DRAFT", isPay: true, order: withTotal
        ))
        XCTAssertFalse(orderConfirmFinalActionEnabled(
            writeSucceeded: false, writeAttempted: true, loaded: true, status: "QUEUED", isPay: false, order: withTotal
        ))
    }

    func testRecheckAbortThrowsStudioError() {
        let shown: [String: Any] = ["status": "DRAFT", "printingCost": "10.00", "deliveryCost": "2.00"]
        let price = orderConfirmRecheck(method: "POST", shown: shown, latest: ["status": "DRAFT", "printingCost": "12.00", "deliveryCost": "2.00"])
        XCTAssertEqual(orderConfirmRecheckAbortError(price)?.message, "The price changed. Review the new total.")
        XCTAssertNil(orderConfirmRecheckAbortError(.proceed))
    }
}
