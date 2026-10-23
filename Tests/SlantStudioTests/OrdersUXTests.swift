import XCTest
@testable import SlantStudio

final class OrdersUXTests: XCTestCase {
    func testDeliveryCountryDefaultsToMacRegion() {
        for code in ["AU", "US", "GB", "NZ", "CA"] {
            let country = defaultDeliveryCountry(regionCode: code)
            XCTAssertEqual(country.selection, code)
            XCTAssertEqual(country.customCode, "")
        }
        XCTAssertEqual(defaultDeliveryCountry(regionCode: "au").selection, "AU")
    }

    func testRegionOutsideShortlistUsesOtherWithPrefilledCode() {
        let country = defaultDeliveryCountry(regionCode: "SE")
        XCTAssertEqual(country.selection, orderCountryOtherTag)
        XCTAssertEqual(country.customCode, "SE")
    }

    func testUnknownOrNonCountryRegionRequiresExplicitChoice() {
        for code in [nil, "", "001", "ZZ", "Australia"] as [String?] {
            let country = defaultDeliveryCountry(regionCode: code)
            XCTAssertEqual(country.selection, "")
            XCTAssertEqual(country.customCode, "")
        }
    }

    func testExplicitDeliveryCountryOverridesRegionalDefault() {
        let delivery = DeliveryDetails(countrySelection: "JP", customCountry: "")
        XCTAssertEqual(delivery.countrySelection, "JP")
        let custom = DeliveryDetails(countrySelection: orderCountryOtherTag, customCountry: "SE")
        XCTAssertEqual(custom.customCountry, "SE")
    }

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
        XCTAssertEqual(orderStatusTitle("CANCELED"), "Cancelled")
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
        XCTAssertEqual(orderCancellationBlockedReason("CANCELED"), "This order was already cancelled.")
        XCTAssertTrue(orderCancellationIsRefundOnly("SHIPPED"))
        XCTAssertTrue(orderCancellationIsRefundOnly("DELIVERED"))
        XCTAssertFalse(orderCancellationIsRefundOnly("PRINTING"))
        XCTAssertFalse(orderCancellationIsRefundOnly("DRAFT"))
    }

    func testOrderDetailCancelNoteSkipsFinishedStatuses() {
        // The status heading already says the order is finished, so the detail pane doesn't repeat it.
        for status in ["CANCELED", "canceled", "SHIPPED", "DELIVERED", "COMPLETE"] {
            XCTAssertNil(orderDetailCancelBlockedNote(status), status)
        }
        // Still explained where it's informative; the review sheet and Workbench keep the full reason.
        XCTAssertEqual(orderDetailCancelBlockedNote("ON_HOLD"), "This order can’t be cancelled.")
        XCTAssertEqual(orderDetailCancelBlockedNote(""), "This order can’t be cancelled.")
        XCTAssertNil(orderDetailCancelBlockedNote("PRINTING"))
        XCTAssertEqual(orderCancellationBlockedReason("CANCELED"), "This order was already cancelled.")
    }

    func testOrderSearchFindsSlantStatusWordToo() {
        let record = Record(values: ["publicId": "SLANT_7", "status": "CANCELED"])
        XCTAssertTrue(orderMatchesSearch(record, query: "Cancelled"))
        XCTAssertTrue(orderMatchesSearch(record, query: "canceled"))
        let waiting = Record(values: ["publicId": "SLANT_8", "status": "AWAITING_SHIPMENT"])
        XCTAssertTrue(orderMatchesSearch(waiting, query: "awaiting shipment"))
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
        XCTAssertEqual(orderItemDisplayName(["type": "PRINT"]), "3D print")
        XCTAssertEqual(orderItemDisplayName(["type": "COMPONENT"]), "Component")
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

    func testCountryShortlistIsLocalizedAndKeepsOrder() {
        let order = ["US", "CA", "GB", "AU", "NZ", "IE", "DE", "FR", "NL", "JP"]
        for identifier in ["en_US", "de_DE", "ja_JP"] {
            let locale = Locale(identifier: identifier)
            let shortlist = orderCountryShortlist(locale: locale)
            XCTAssertEqual(shortlist.map(\.code), order, identifier)
            for entry in shortlist {
                XCTAssertEqual(entry.name, locale.localizedString(forRegionCode: entry.code), "\(identifier) \(entry.code)")
            }
        }
        XCTAssertEqual(orderCountryShortlist(locale: Locale(identifier: "en_US")).first?.name, "United States")
        XCTAssertEqual(orderCountryShortlist(locale: Locale(identifier: "de_DE")).first { $0.code == "DE" }?.name, "Deutschland")
        XCTAssertEqual(orderCountryChoices.map(\.code), order)
    }

    func testNonCountryRegionCodesStayUnselectedNeverUS() {
        for code in ["EU", "eu", "UN", "EZ", "QO", "AC", "IC"] {
            let country = defaultDeliveryCountry(regionCode: code)
            XCTAssertEqual(country.selection, "", code)
            XCTAssertEqual(country.customCode, "", code)
            let fromSlant = orderCountrySelection(fromAddressCountry: code, locale: Locale(identifier: "en_US"))
            XCTAssertEqual(fromSlant.selection, "", code)
            XCTAssertEqual(fromSlant.customCode, "", code)
        }
        let english = Locale(identifier: "en_US")
        for name in ["European Union", "United Nations", "Eurozone"] {
            XCTAssertEqual(orderCountrySelection(fromAddressCountry: name, locale: english).selection, "", name)
        }
        let address: [String: Any] = ["name": "Pat", "line1": "1 Road", "city": "Town", "zip": "123", "country": "EU"]
        let delivery = deliveryDetails(fromOrder: ["customer": ["details": ["email": "p@example.com", "address": address]]])
        XCTAssertEqual(delivery.map(orderCountryPickerValue), "")
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

    // MARK: - Reorder

    func testReorderMapsFlatSpecItemsWithoutPrices() throws {
        let order = Record(values: ["publicId": "SLANT_1", "items": [
            ["type": "PRINT", "publicFileServiceId": "file-1", "filamentId": "fil-1", "quantity": 3,
             "name": "Widget", "SKU": "W-1", "price": "9.99", "options": ["infill": 20]],
            ["type": "COMPONENT", "componentId": "comp-1", "quantity": 2, "price": "1.00"],
            ["type": "STATIONERY", "stationeryId": "card-1", "quantity": 1, "imageUrl": "https://example.com/a.png"]
        ]])
        let result = orderLinesForReorder(order)
        XCTAssertEqual(result.skipped, [])
        XCTAssertEqual(result.lines.count, 3)
        let print = result.lines[0]
        XCTAssertEqual(print.type, "PRINT")
        XCTAssertEqual(print.reference, "file-1")
        XCTAssertEqual(print.filamentID, "fil-1")
        XCTAssertEqual(print.quantity, 3)
        XCTAssertEqual(print.name, "Widget")
        XCTAssertEqual(print.sku, "W-1")
        XCTAssertEqual(print.optionsJSON, #"{"infill":20}"#)
        XCTAssertEqual(result.lines[1].type, "COMPONENT")
        XCTAssertEqual(result.lines[1].reference, "comp-1")
        XCTAssertEqual(result.lines[1].quantity, 2)
        XCTAssertEqual(result.lines[1].filamentID, "")
        XCTAssertEqual(result.lines[2].type, "STATIONERY")
        XCTAssertEqual(result.lines[2].reference, "card-1")
        XCTAssertEqual(result.lines[2].imageURL, "https://example.com/a.png")
        // The new draft payload carries references and quantities, never the old price.
        let payload = try print.payload()
        XCTAssertNil(payload["price"])
        XCTAssertEqual(payload["publicFileServiceId"] as? String, "file-1")
    }

    func testReorderMapsNestedItemShapesAndInfersType() {
        let order = Record(values: ["order": ["publicId": "SLANT_2", "items": [
            ["printItem": ["publicFileServiceId": "file-2", "filamentId": "fil-2", "name": "Gadget", "sku": "G-2"], "quantity": "4"],
            ["componentItem": ["componentId": "comp-2", "componentName": "Bracket"], "quantity": 1],
            ["type": "STATIONERY", "stationeryItem": ["stationeryId": "card-2", "stationeryName": "Card", "imageUrl": "http://insecure.example/a.png"]]
        ]]])
        let result = orderLinesForReorder(order)
        // Every item is copied; the stationery item had no quantity, which is called out rather than silently set.
        XCTAssertEqual(result.skipped, ["“Card”: quantity not copied, set to 1. Check it before creating the draft."])
        XCTAssertEqual(result.lines.map(\.type), ["PRINT", "COMPONENT", "STATIONERY"])
        XCTAssertEqual(result.lines[2].quantity, 1)
        XCTAssertEqual(result.lines[0].reference, "file-2")
        XCTAssertEqual(result.lines[0].filamentID, "fil-2")
        XCTAssertEqual(result.lines[0].quantity, 4)
        XCTAssertEqual(result.lines[0].name, "Gadget")
        XCTAssertEqual(result.lines[0].sku, "G-2")
        XCTAssertEqual(result.lines[1].reference, "comp-2")
        XCTAssertEqual(result.lines[1].name, "", "catalog names are not copied as custom item names")
        XCTAssertEqual(result.lines[2].reference, "card-2")
        XCTAssertEqual(result.lines[2].quantity, 1, "missing quantity defaults to 1")
        XCTAssertEqual(result.lines[2].imageURL, "", "non-https image links are dropped")
    }

    func testReorderSkipsItemsWithoutReferencesAndUnknownTypes() {
        let order = Record(values: ["items": [
            ["type": "PRINT", "name": "Lost part", "quantity": 2],
            ["type": "COMPONENT", "componentItem": ["componentName": "Hinge"]],
            ["type": "STATIONERY", "stationeryId": "  "],
            ["type": "GIFT_CARD", "name": "Voucher"],
            ["quantity": 1]
        ]])
        let result = orderLinesForReorder(order)
        XCTAssertTrue(result.lines.isEmpty)
        XCTAssertEqual(result.skipped, [
            "“Lost part”: the order doesn’t include its uploaded model ID.",
            "“Hinge”: the order doesn’t include its component ID.",
            "“Stationery”: the order doesn’t include its stationery ID.",
            "“Voucher”: this item type can’t be reordered here.",
            "“Item”: this item type can’t be reordered here."
        ])
    }

    func testReorderComponentOnlyAndEmptyOrders() {
        let components = orderLinesForReorder(Record(values: ["items": [["type": "COMPONENT", "componentId": "c", "quantity": 5]]]))
        XCTAssertEqual(components.lines.count, 1)
        XCTAssertEqual(components.lines[0].type, "COMPONENT")
        XCTAssertTrue(components.skipped.isEmpty)
        for values in [[:], ["items": []], ["items": "not a list"]] as [[String: Any]] {
            let result = orderLinesForReorder(Record(values: values))
            XCTAssertTrue(result.lines.isEmpty)
            XCTAssertTrue(result.skipped.isEmpty)
        }
    }

    func testReorderQuantityParsingRejectsInvalidValues() {
        XCTAssertEqual(orderItemQuantity(["quantity": 7]), 7)
        XCTAssertEqual(orderItemQuantity(["quantity": NSNumber(value: 12)]), 12)
        XCTAssertEqual(orderItemQuantity(["quantity": " 9 "]), 9)
        XCTAssertNil(orderItemQuantity(["quantity": 2.5]))
        XCTAssertNil(orderItemQuantity(["quantity": true]))
        XCTAssertNil(orderItemQuantity(["quantity": "ten"]))
        XCTAssertNil(orderItemQuantity([:]))
        // Zero or negative quantities never reach a new line; it starts at 1 for the user to set.
        for bad in [0, -3] {
            let result = orderLinesForReorder(Record(values: ["items": [["type": "PRINT", "publicFileServiceId": "f", "quantity": bad]]]))
            XCTAssertEqual(result.lines.first?.quantity, 1)
        }
    }

    func testDeliveryDetailsFromOrderMapsAddressAndCountry() {
        let order: [String: Any] = ["customer": ["details": [
            "email": "sam@example.com",
            "address": ["name": "Sam Lee", "line1": "1 Main St", "line2": "Unit 4", "city": "Sydney", "state": "NSW", "zip": "2000", "country": "AU"]
        ]]]
        let delivery = deliveryDetails(fromOrder: order)
        XCTAssertEqual(delivery?.email, "sam@example.com")
        XCTAssertEqual(delivery?.name, "Sam Lee")
        XCTAssertEqual(delivery?.line1, "1 Main St")
        XCTAssertEqual(delivery?.line2, "Unit 4")
        XCTAssertEqual(delivery?.city, "Sydney")
        XCTAssertEqual(delivery?.state, "NSW")
        XCTAssertEqual(delivery?.zip, "2000")
        XCTAssertEqual(delivery?.countrySelection, "AU")
        XCTAssertEqual(delivery?.customCountry, "")

        let wrapped = deliveryDetails(fromOrder: ["order": ["customer": ["details": ["address": ["name": "Kai", "line1": "Gatan 1", "country": "se"]]]]])
        XCTAssertEqual(wrapped?.countrySelection, orderCountryOtherTag)
        XCTAssertEqual(wrapped?.customCountry, "SE")
    }

    func testDeliveryDetailsUnknownCountryStaysUnselectedNeverUS() {
        for country in [nil, "", "ZZ", "Atlantis", "USA", "001"] as [String?] {
            var address: [String: Any] = ["name": "Pat", "line1": "1 Road", "city": "Town", "zip": "123"]
            if let country { address["country"] = country }
            let delivery = deliveryDetails(fromOrder: ["customer": ["details": ["email": "p@example.com", "address": address]]])
            XCTAssertEqual(delivery?.countrySelection, "", String(describing: country))
            XCTAssertEqual(delivery?.customCountry, "", String(describing: country))
            XCTAssertEqual(delivery.map(orderCountryPickerValue), "")
        }
    }

    func testCountryNamesFromSlantMapToCodes() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(orderCountrySelection(fromAddressCountry: "United States", locale: english).selection, "US")
        XCTAssertEqual(orderCountrySelection(fromAddressCountry: "australia", locale: english).selection, "AU")
        let sweden = orderCountrySelection(fromAddressCountry: "Sweden", locale: english)
        XCTAssertEqual(sweden.selection, orderCountryOtherTag)
        XCTAssertEqual(sweden.customCode, "SE")
        XCTAssertEqual(orderCountrySelection(fromAddressCountry: 42, locale: english).selection, "")
    }

    func testDeliveryDetailsMissingAddressReturnsNil() {
        XCTAssertNil(deliveryDetails(fromOrder: [:]))
        XCTAssertNil(deliveryDetails(fromOrder: ["customer": ["details": ["address": ["country": "US"]]]]))
        XCTAssertEqual(deliveryDetails(fromOrder: ["customer": ["details": ["email": "a@example.com"]]])?.email, "a@example.com")
        XCTAssertEqual(deliveryDetails(fromOrder: ["customer": ["details": ["name": "Fallback", "address": ["line1": "x"]]]])?.name, "Fallback")
    }

    func testReorderQuantityNotCopiedIsExplained() {
        let order = Record(values: ["items": [
            ["type": "PRINT", "publicFileServiceId": "ok", "name": "Good", "quantity": 3],
            ["type": "PRINT", "publicFileServiceId": "missing", "name": "Missing"],
            ["type": "PRINT", "publicFileServiceId": "fraction", "name": "Fraction", "quantity": 2.5],
            ["type": "PRINT", "publicFileServiceId": "text", "name": "Text", "quantity": "lots"],
            ["type": "PRINT", "publicFileServiceId": "zero", "name": "Zero", "quantity": 0]
        ]])
        let mapped = orderLinesForReorder(order)
        XCTAssertEqual(mapped.lines.map(\.reference), ["ok", "missing", "fraction", "text", "zero"], "items are still copied")
        XCTAssertEqual(mapped.lines.map(\.quantity), [3, 1, 1, 1, 1])
        XCTAssertEqual(mapped.skipped.count, 4)
        for (name, note) in zip(["Missing", "Fraction", "Text", "Zero"], mapped.skipped) {
            XCTAssertTrue(note.contains("“\(name)”"), note)
            XCTAssertTrue(note.contains("quantity not copied, set to 1"), note)
        }
        XCTAssertFalse(mapped.skipped.contains { $0.contains("Good") })
    }

    func testComposerPrefillForReorderCarriesSourceAndProvider() {
        let order = Record(values: [
            "publicId": "SLANT_9", "platformId": "plat-1", "options": ["shippingProvider": "shippo"],
            "metadata": ["externalOrder": "123"], "printingCost": "50.00", "totalCost": "60.00",
            "items": [["type": "PRINT", "publicFileServiceId": "f", "quantity": 2], ["type": "PRINT", "quantity": 1]],
            "customer": ["details": ["email": "a@example.com", "address": ["name": "A", "line1": "1", "city": "C", "zip": "Z", "country": "GB"]]]
        ])
        let prefill = orderComposerPrefill(reordering: order)
        XCTAssertEqual(prefill.sourceOrderNumber, "SLANT_9")
        XCTAssertEqual(prefill.platformID, "plat-1")
        XCTAssertEqual(prefill.shippingProvider, "SHIPPO")
        XCTAssertEqual(prefill.lines.count, 1)
        XCTAssertEqual(prefill.skippedItems.count, 1)
        XCTAssertEqual(prefill.delivery?.countrySelection, "GB")
        XCTAssertEqual(orderComposerPrefill(reordering: Record(values: ["options": ["shippingProvider": "FEDEX"]])).shippingProvider, "")
        XCTAssertNil(orderComposerPrefill(reordering: Record(values: [:])).sourceOrderNumber)
    }

    func testDuplicateBlockedReasons() {
        XCTAssertNil(orderDuplicateBlockedReason(draftBlockedReason: nil, composerOpen: false, outcomeUnknown: false, busy: false))
        XCTAssertEqual(orderDuplicateBlockedReason(draftBlockedReason: "Connect your account first.", composerOpen: false, outcomeUnknown: false, busy: false), "Connect your account first.")
        XCTAssertEqual(orderDuplicateBlockedReason(draftBlockedReason: nil, composerOpen: false, outcomeUnknown: true, busy: false), unknownOutcomeBlockMessage)
        XCTAssertEqual(orderDuplicateBlockedReason(draftBlockedReason: nil, composerOpen: true, outcomeUnknown: false, busy: false), "Finish or close the open order draft first.")
        XCTAssertEqual(orderDuplicateBlockedReason(draftBlockedReason: nil, composerOpen: false, outcomeUnknown: false, busy: true), "Working…")
    }

    func testComposerSeedsLinesFromPrefillDuplicateOrDefault() {
        let fallback = OrderLine(reference: "selected-model", quantity: 3)
        let single = orderComposerInitialLines(prefill: OrderComposerPrefill(lines: [OrderLine(reference: "one")])) { fallback }
        XCTAssertEqual(single.map(\.reference), ["one"])
        let multi = orderComposerInitialLines(prefill: OrderComposerPrefill(lines: [OrderLine(reference: "a"), OrderLine(reference: "b")])) { fallback }
        XCTAssertEqual(multi.map(\.reference), ["a", "b"])
        XCTAssertEqual(orderComposerInitialLines(prefill: nil) { fallback }.map(\.reference), ["selected-model"])
        let emptyDuplicate = orderComposerInitialLines(prefill: OrderComposerPrefill(lines: [], sourceOrderNumber: "SLANT_1")) { fallback }
        XCTAssertEqual(emptyDuplicate.map(\.reference), [""], "a duplicate with nothing copyable starts blank, not with an unrelated model")
    }

    func testDuplicateNeverFallsBackToAnotherOrdersAddress() {
        let session = DeliveryDetails(email: "other@example.com", name: "Other Customer", countrySelection: "US")
        let copied = DeliveryDetails(email: "a@example.com", name: "Source", countrySelection: "GB")
        XCTAssertEqual(orderComposerDeliverySeed(prefill: OrderComposerPrefill(lines: [], delivery: copied, sourceOrderNumber: "S"), lastDelivery: session), .copiedFromOrder(copied))
        XCTAssertEqual(orderComposerDeliverySeed(prefill: OrderComposerPrefill(lines: [], sourceOrderNumber: "S"), lastDelivery: session), .blank(missingFromSourceOrder: true))
        XCTAssertEqual(orderComposerDeliverySeed(prefill: OrderComposerPrefill(lines: [OrderLine()]), lastDelivery: session), .lastUsed(session))
        XCTAssertEqual(orderComposerDeliverySeed(prefill: nil, lastDelivery: session), .lastUsed(session))
        XCTAssertEqual(orderComposerDeliverySeed(prefill: nil, lastDelivery: nil), .blank(missingFromSourceOrder: false))
    }

    func testMissingModelWarningOnlyWhenFileListComplete() {
        let files = [Record(values: ["publicFileServiceId": "file-1"])]
        let deleted = OrderLine(reference: "file-gone")
        XCTAssertTrue(orderLineModelLooksMissing(deleted, files: files, filesFullyLoaded: true))
        XCTAssertFalse(orderLineModelLooksMissing(deleted, files: files, filesFullyLoaded: false), "partial pages never warn")
        XCTAssertFalse(orderLineModelLooksMissing(OrderLine(reference: "file-1"), files: files, filesFullyLoaded: true))
        XCTAssertFalse(orderLineModelLooksMissing(OrderLine(), files: files, filesFullyLoaded: true))
        var component = OrderLine(reference: "comp"); component.type = "COMPONENT"
        XCTAssertFalse(orderLineModelLooksMissing(component, files: files, filesFullyLoaded: true))
    }

    // MARK: - Unsaved input

    func testUnsavedInputFalseWhenUnchangedFromPrefill() {
        let lines = [OrderLine(reference: "f", filamentID: "m", quantity: 2)]
        let copy = lines.map { line -> OrderLine in
            var fresh = OrderLine(); fresh.type = line.type; fresh.reference = line.reference
            fresh.filamentID = line.filamentID; fresh.quantity = line.quantity; return fresh
        }
        let delivery = DeliveryDetails(email: "a@example.com", name: "A", countrySelection: "US")
        XCTAssertFalse(orderComposerHasUnsavedInput(lines: lines, initialLines: lines, delivery: delivery, initialDelivery: delivery, metadataFields: [], paymentID: ""))
        XCTAssertTrue(orderLinesHaveSameContent(lines, copy), "content comparison ignores line identity")
        XCTAssertFalse(orderComposerHasUnsavedInput(lines: lines, initialLines: lines, delivery: delivery, initialDelivery: delivery, metadataFields: [OrderMetadataField()], paymentID: "  "))
    }

    func testUnsavedInputDetectsTypedDeliveryAndLineChanges() {
        let lines = [OrderLine(reference: "f", filamentID: "m", quantity: 2)]
        let empty = DeliveryDetails(countrySelection: "")
        var typed = empty; typed.line1 = "1 Main St"
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: lines, initialLines: lines, delivery: typed, initialDelivery: empty, metadataFields: [], paymentID: ""))
        var changedCountry = empty; changedCountry.countrySelection = "JP"
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: lines, initialLines: lines, delivery: changedCountry, initialDelivery: empty, metadataFields: [], paymentID: ""))
        var more = lines; more[0].quantity = 20
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: more, initialLines: lines, delivery: empty, initialDelivery: empty, metadataFields: [], paymentID: ""))
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: lines + [OrderLine()], initialLines: lines, delivery: empty, initialDelivery: empty, metadataFields: [], paymentID: ""))
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: [], initialLines: lines, delivery: empty, initialDelivery: empty, metadataFields: [], paymentID: ""))
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: lines, initialLines: lines, delivery: empty, initialDelivery: empty, metadataFields: [OrderMetadataField(key: "k")], paymentID: ""))
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: lines, initialLines: lines, delivery: empty, initialDelivery: empty, metadataFields: [], paymentID: "pay_1"))
    }

    func testUnsavedInputIncludesShippingProviderAndPlatform() {
        let lines = [OrderLine(reference: "f", filamentID: "m", quantity: 2)]
        let delivery = DeliveryDetails(email: "a@example.com", name: "A", countrySelection: "GB")
        func unsaved(provider: String, initialProvider: String, platform: String, initialPlatform: String) -> Bool {
            orderComposerHasUnsavedInput(lines: lines, initialLines: lines, delivery: delivery, initialDelivery: delivery,
                                         metadataFields: [], paymentID: "",
                                         shippingProvider: provider, initialShippingProvider: initialProvider,
                                         platformID: platform, initialPlatformID: initialPlatform)
        }
        // A duplicate opens with both seeded; leaving them alone closes without a prompt.
        XCTAssertFalse(unsaved(provider: "SHIPPO", initialProvider: "SHIPPO", platform: "plat-1", initialPlatform: "plat-1"))
        // An untouched new draft.
        XCTAssertFalse(unsaved(provider: "", initialProvider: "", platform: "", initialPlatform: ""))
        XCTAssertTrue(unsaved(provider: "", initialProvider: "SHIPPO", platform: "plat-1", initialPlatform: "plat-1"))
        XCTAssertTrue(unsaved(provider: "SHIPSTATION", initialProvider: "", platform: "plat-1", initialPlatform: "plat-1"))
        XCTAssertTrue(unsaved(provider: "SHIPPO", initialProvider: "SHIPPO", platform: "plat-2", initialPlatform: "plat-1"))
        XCTAssertTrue(unsaved(provider: "", initialProvider: "", platform: "plat-1", initialPlatform: ""))
    }

    func testAppliedLocationSuggestionCountsAsUnsavedInput() {
        let start = DeliveryDetails(email: "a@example.com", name: "A", countrySelection: "")
        let suggestion = DeliveryAddressSuggestion(street: "1 Main St", city: "Sydney", state: "NSW", postalCode: "2000", countryCode: "AU")
        let applied = suggestion.applying(to: start)
        let lines = [OrderLine(reference: "f")]
        XCTAssertTrue(orderComposerHasUnsavedInput(lines: lines, initialLines: lines, delivery: applied, initialDelivery: start, metadataFields: [], paymentID: ""))
    }

    // MARK: - Large quantities

    func testLargeQuantityThresholdBoundaries() {
        XCTAssertEqual(orderLargeQuantityThreshold, 25)
        XCTAssertFalse(isLargeOrderQuantity(24))
        XCTAssertTrue(isLargeOrderQuantity(25))
        XCTAssertTrue(isLargeOrderQuantity(100))
        XCTAssertFalse(isLargeOrderQuantity(0))
        XCTAssertFalse(isLargeOrderQuantity(-50))
        XCTAssertFalse(isLargeOrderQuantity(1_000, threshold: 0), "a disabled threshold never flags")
        XCTAssertTrue(isLargeOrderQuantity(10, threshold: 10))
    }

    func testLargeQuantityLinesAndComposerWarning() {
        let lines = [OrderLine(reference: "a", quantity: 10), OrderLine(reference: "b", quantity: 100), OrderLine(reference: "c", quantity: 25)]
        XCTAssertEqual(largeQuantityLines(lines).map(\.reference), ["b", "c"])
        XCTAssertEqual(largeQuantityLines(lines, threshold: 101).count, 0)
        XCTAssertNil(largeQuantityNotice(24))
        XCTAssertEqual(largeQuantityNotice(25), "Large quantity (25) — check for an extra zero.")
        XCTAssertEqual(largeQuantityNotice(100), "Large quantity (100) — check for an extra zero.")
    }

    func testModelsQuantityFieldUsesSameLargeQuantityNotice() {
        XCTAssertNil(printQuantityNotice("24"))
        XCTAssertEqual(printQuantityNotice("25"), largeQuantityNotice(25))
        XCTAssertEqual(printQuantityNotice("100"), "Large quantity (100) — check for an extra zero.")
        // Invalid entries show the whole-number message instead, never both.
        for text in ["", "0", "2.5", "abc", "10001", "-30"] { XCTAssertNil(printQuantityNotice(text), text) }
    }

    func testReviewLineHighlightUsesSlantItems() {
        for item in [["quantity": 24], ["quantity": "3"], [:], ["quantity": 0], ["quantity": -30], ["quantity": true]] as [[String: Any]] {
            XCTAssertFalse(orderItemHasLargeQuantity(item))
        }
        XCTAssertTrue(orderItemHasLargeQuantity(["quantity": "25"]))
        XCTAssertTrue(orderItemHasLargeQuantity(["quantity": NSNumber(value: 30)]))
    }

    // MARK: - Country list

    func testOtherCountryChoicesAreCompleteSortedAndExcludeShortlist() {
        let english = Locale(identifier: "en_US")
        let choices = orderOtherCountryChoices(locale: english)
        let codes = choices.map(\.code)
        XCTAssertEqual(Set(codes).count, codes.count)
        for code in ["SE", "CH", "ES", "MX", "BR", "IN", "ZA", "SG", "XK"] { XCTAssertTrue(codes.contains(code), code) }
        for code in orderCountryChoices.map(\.code) { XCTAssertFalse(codes.contains(code), code) }
        for code in ["EU", "EZ", "UN", "QO", "ZZ", "001"] { XCTAssertFalse(codes.contains(code), code) }
        XCTAssertTrue(codes.allSatisfy(isCountryCode))
        XCTAssertEqual(choices.first { $0.code == "CH" }?.name, "Switzerland")
        let names = choices.map(\.name)
        XCTAssertEqual(names, names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
        XCTAssertGreaterThan(choices.count, 200)
    }

    func testCountryPickerMapsToStoredSelection() {
        let base = DeliveryDetails(name: "A", countrySelection: "")
        XCTAssertEqual(orderCountryPickerValue(base), "")
        let japan = deliveryApplyingCountryPick("JP", to: base)
        XCTAssertEqual(japan.countrySelection, "JP")
        XCTAssertEqual(japan.customCountry, "")
        XCTAssertEqual(japan.name, "A")
        let sweden = deliveryApplyingCountryPick("SE", to: japan)
        XCTAssertEqual(sweden.countrySelection, orderCountryOtherTag)
        XCTAssertEqual(sweden.customCountry, "SE")
        XCTAssertEqual(orderCountryPickerValue(sweden), "SE")
        let back = deliveryApplyingCountryPick("US", to: sweden)
        XCTAssertEqual(back.countrySelection, "US")
        XCTAssertEqual(back.customCountry, "", "switching back to the shortlist clears the other code")
        let cleared = deliveryApplyingCountryPick("", to: sweden)
        XCTAssertEqual(cleared.countrySelection, "")
        XCTAssertEqual(cleared.customCountry, "")
        // A region default outside the shortlist shows that country in the single picker.
        let regional = defaultDeliveryCountry(regionCode: "SE")
        XCTAssertEqual(orderCountryPickerValue(DeliveryDetails(countrySelection: regional.selection, customCountry: regional.customCode)), "SE")
    }
}
