import XCTest
@testable import Plinth

// Every number here is synthetic, made to pass (or, one digit off, to fail) its check digit. None is from a live order.
final class CarrierTrackingTests: XCTestCase {
    private func carrier(_ number: String) -> DetectedCarrier? { detectCarrier(number).carrier }

    // MARK: UPU S10

    func testS10NumbersNameTheIssuingPostalOperator() throws {
        let usps = try XCTUnwrap(carrier("LS123456785US"))
        XCTAssertEqual(usps.name, "USPS")
        XCTAssertEqual(usps.shopifyCompany, "USPS")
        XCTAssertEqual(usps.trackingURL?.absoluteString, "https://tools.usps.com/go/TrackConfirmAction?tLabels=LS123456785US")
        XCTAssertEqual(carrier("RR202401015GB")?.name, "Royal Mail")
        XCTAssertEqual(carrier("RR202401015GB")?.trackingURL?.absoluteString,
                       "https://www.royalmail.com/track-your-item#/tracking-results/RR202401015GB")
        XCTAssertEqual(carrier("RR202401015CA")?.name, "Canada Post")
        XCTAssertEqual(carrier("RR202401015AU")?.name, "Australia Post")
        XCTAssertEqual(carrier("RR202401015NZ")?.shopifyCompany, "New Zealand Post")
        let germany = try XCTUnwrap(carrier("RR202401015DE"))
        XCTAssertEqual(germany.name, "Deutsche Post")
        XCTAssertNil(germany.trackingURL, "no page Plinth can rely on, so no link")
        XCTAssertEqual(germany.shopifyCompany, "Deutsche Post")
        let france = try XCTUnwrap(carrier("RR202401015FR"))
        XCTAssertNil(france.shopifyCompany, "Shopify lists no plain La Poste")
        XCTAssertEqual(carrier("RR202401015IE")?.shopifyCompany, "An Post")
    }

    func testS10CheckDigitRules() {
        XCTAssertNil(carrier("LS123456786US"), "wrong check digit")
        XCTAssertEqual(carrier("LS000000080US")?.name, "USPS", "a remainder giving 10 makes the check digit 0")
        XCTAssertEqual(carrier("LS000000005US")?.name, "USPS", "a remainder giving 11 makes the check digit 5")
        XCTAssertFalse(carrierS10CheckDigitValid("LS12345678US"))
        XCTAssertFalse(carrierS10CheckDigitValid("1S123456785US"))
    }

    func testS10FromAnUnlistedCountryIsNotRecognised() {
        XCTAssertEqual(detectCarrier("RR202401015XX"), .notRecognised)
        XCTAssertEqual(detectCarrier("RR202401015CV"), .notRecognised, "a real country Plinth has no operator for")
    }

    // MARK: UPS, USPS

    func testUPS() {
        XCTAssertEqual(carrier("1Z999AA10123456784")?.name, "UPS")
        XCTAssertEqual(carrier("1Z999AA10123456784")?.trackingURL?.absoluteString, "https://www.ups.com/track?tracknum=1Z999AA10123456784")
        XCTAssertEqual(carrier("1ZA1B2C3D4E5F6G7H0")?.name, "UPS", "letters in the body count by their UPS values")
        XCTAssertNil(carrier("1Z999AA10123456785"))
        XCTAssertNil(carrier("1Z999AA1012345678"), "too short")
    }

    func testUSPSIntelligentMailNumbers() {
        XCTAssertEqual(carrier("9400100000000000001232")?.name, "USPS")
        XCTAssertEqual(carrier("94001000000000000000123453")?.name, "USPS", "26 digits")
        XCTAssertEqual(carrier("9505500000000000000992")?.name, "USPS")
        XCTAssertEqual(carrier("9361289878700317633795")?.name, "USPS")
        XCTAssertNil(carrier("9400100000000000001233"), "wrong check digit")
        XCTAssertEqual(detectCarrier("9611020987654312345673"), .notRecognised, "96 isn't a USPS prefix")
    }

    func testUSPS92NumbersAreAmbiguous() {
        // FedEx Ground Economy and other services that hand parcels to USPS print 92 numbers too.
        guard case .ambiguous(let names) = detectCarrier("9261290876543210987652") else { return XCTFail("expected ambiguous") }
        XCTAssertTrue(names.contains("USPS"))
        XCTAssertTrue(names.contains("FedEx Ground Economy"))
        XCTAssertNil(carrier("9261290876543210987652"))
    }

    func testPlainDigitNumbersNameNoCarrier() {
        // FedEx 12 and 15 and DHL Express 10 aren't detected: their check digits are too weak to tell them from another
        // carrier's plain digits, and a false match would send the wrong company to Shopify and the buyer. These pass
        // the check digits those carriers use.
        for number in ["123456789012", "987654321098", "123456789012343", "555555555555550", "1234567891", "9876543213"] {
            XCTAssertEqual(detectCarrier(number), .notRecognised, number)
            XCTAssertNil(carrierDetected(forNumber: number, namedCarrier: nil), number)
            let entry = ShopFollowUpEntry(id: "S", slantOrderNumber: "S", marketplaceID: "#1", source: "shopify",
                                          recipientFirstName: nil, provider: "SHIPPO", trackingNumbers: [number], status: "SHIPPED", created: nil)
            XCTAssertEqual(shopifyTrackingCompany(entry), "", number)
            XCTAssertNil(shopFollowUpDetectedCarrier(entry), number)
        }
    }

    // MARK: Input handling

    func testNumbersAreReadWithoutSpacesAndInAnyCase() {
        XCTAssertEqual(carrier(" ls 123 456 785 us ")?.trackingURL?.absoluteString,
                       "https://tools.usps.com/go/TrackConfirmAction?tLabels=LS123456785US")
        XCTAssertEqual(carrier("1z999aa10123456784")?.name, "UPS")
        XCTAssertEqual(carrierTrackingNumberKey("9400 1000 0000 0000 0012 32"), "9400100000000000001232")
    }

    func testOddInputIsNotRecognised() {
        for value in ["", "   ", "LS-123456785-US", "LS123456785US!", "１Z999AA10123456784", "LS123456785US🙂",
                      String(repeating: "1", count: 41), "0"] {
            XCTAssertEqual(detectCarrier(value), .notRecognised, value)
        }
        // All zeros passes several check digits but is a placeholder.
        XCTAssertEqual(detectCarrier("000000000000"), .notRecognised)
        XCTAssertEqual(detectCarrier("0000000000"), .notRecognised)
        XCTAssertNil(carrierTrackingNumberKey(String(repeating: "A", count: carrierTrackingNumberMaxLength + 1)))
    }

    func testTrackingURLsAreHTTPSAndEncodeTheNumber() {
        XCTAssertEqual(carrierURL("https://track.example.com/?q=", "A B&C#D")?.absoluteString, "https://track.example.com/?q=A%20B%26C%23D")
        XCTAssertNil(carrierURL("http://track.example.com/?q=", "123"), "never plain http")
        XCTAssertNil(carrierURL("https:///?q=", "123"), "never without a host")
    }

    // MARK: Several numbers and named carriers

    func testSeveralNumbersMustAgree() {
        XCTAssertEqual(detectCarrier(forNumbers: ["LS123456785US", "LS876543216US"])?.name, "USPS")
        XCTAssertNil(detectCarrier(forNumbers: ["LS123456785US", "1Z999AA10123456784"]), "different carriers")
        XCTAssertNil(detectCarrier(forNumbers: ["LS123456785US", "NOTANUMBER"]), "one not recognised")
        XCTAssertNil(detectCarrier(forNumbers: []))
    }

    func testLabelServicesAreRecognisedByName() {
        XCTAssertEqual(carrierLabelServiceName("SHIPPO"), "Shippo")
        XCTAssertEqual(carrierLabelServiceName(" shippo "), "Shippo")
        XCTAssertEqual(carrierLabelServiceName("Ship Station"), "ShipStation")
        XCTAssertEqual(carrierLabelServiceName("EASYPOST"), "EasyPost")
        XCTAssertNil(carrierLabelServiceName("UPS"))
        XCTAssertNil(carrierLabelServiceName(nil))
    }

    func testDetectionMustAgreeWithACarrierTheServiceNamed() {
        XCTAssertEqual(carrierDetected(forNumber: "LS123456785US", namedCarrier: "SHIPPO")?.name, "USPS", "a label service isn't a carrier")
        XCTAssertEqual(carrierDetected(forNumber: "LS123456785US", namedCarrier: nil)?.name, "USPS")
        XCTAssertEqual(carrierDetected(forNumber: "LS123456785US", namedCarrier: " ")?.name, "USPS")
        XCTAssertEqual(carrierDetected(forNumber: "LS123456785US", namedCarrier: "USPS_INTERNATIONAL")?.name, "USPS")
        XCTAssertEqual(carrierDetected(forNumber: "1Z999AA10123456784", namedCarrier: "United Parcel Service")?.name, "UPS")
        XCTAssertNil(carrierDetected(forNumber: "123456789012", namedCarrier: "FEDEX"), "FedEx numbers aren't detected")
        XCTAssertNil(carrierDetected(forNumber: "LS123456785US", namedCarrier: "UPS"), "never a link to another carrier than the one named")
        XCTAssertNil(carrierDetected(forNumbers: ["LS123456785US", "1Z999AA10123456784"], namedCarrier: "SHIPPO"))
        XCTAssertTrue(carrierNamesAgree("FedEx", "FEDEX"))
        XCTAssertFalse(carrierNamesAgree("", "USPS"))
    }
}

// MARK: - Order detail, export, Tracking for Your Shop, 3DAPI

final class CarrierTrackingDisplayTests: XCTestCase {
    /// The shape of a live shipped order's shipping record (1 Nov 2026), with a synthetic number.
    private func shippedOrder(status: String = "SHIPPED", fulfillment extra: [String: Any] = [:]) -> [String: Any] {
        var fulfillment: [String: Any] = [
            "provider": "SHIPPO", "deliveryMethod": "INTERNATIONAL", "providerStatus": NSNull(), "status": "SHIPPED",
            "labelPrinted": true, "trackingNumbers": ["LS123456785US"]
        ]
        fulfillment.merge(extra) { _, new in new }
        return ["publicId": "SLANT_TEST_1", "status": status, "fulfillment": fulfillment]
    }

    func testTrackingFactsNameTheLabelServiceAsOne() {
        let facts = trackingFacts(shippedOrder()["fulfillment"])
        XCTAssertEqual(facts.first { $0.0 == "Label service" }?.1, "SHIPPO", "Slant's value, unchanged for copies")
        XCTAssertNil(facts.first { $0.0 == "Carrier" })
        XCTAssertNil(facts.first { $0.0 == "Carrier status" }, "a null providerStatus adds nothing")
        XCTAssertEqual(trackingFacts(["provider": "UPS"]).first?.0, "Carrier")
        XCTAssertEqual(trackingFacts(["providerStatus": "IN_TRANSIT"]).first { $0.0 == "Carrier status" }?.1, "IN_TRANSIT")
    }

    func testDetailRowsForALiveShapedShippedOrder() throws {
        let rows = orderTrackingDisplayRows(shippedOrder())
        XCTAssertEqual(rows.map(\.label), ["Carrier", "Service", "Tracking number"],
                       "one Carrier row stands in for the label service; the shipment status repeating the header is left out")
        XCTAssertEqual(rows[0].value, "USPS")
        XCTAssertEqual(rows[0].help, "Worked out from the tracking number. Label made through Shippo.")
        XCTAssertEqual(rows[1].value, "International")
        let number = rows[2]
        XCTAssertEqual(number.kind, .number)
        XCTAssertEqual(number.value, "LS123456785US")
        XCTAssertEqual(number.trackCarrier, "USPS")
        XCTAssertEqual(number.trackURL?.absoluteString, "https://tools.usps.com/go/TrackConfirmAction?tLabels=LS123456785US")
    }

    func testShipmentStatusIsKeptWhenItSaysSomethingElse() {
        // The header shows Shipped while Slant's status lags its shipping record, so the row still adds nothing.
        XCTAssertFalse(orderTrackingDisplayRows(shippedOrder(status: "PRINTING")).contains { $0.label == "Shipment status" })
        let moving = orderTrackingDisplayRows(shippedOrder(fulfillment: ["status": "IN_TRANSIT"]))
        XCTAssertEqual(moving.first { $0.label == "Shipment status" }?.value, "In transit")
        let carrier = orderTrackingDisplayRows(shippedOrder(fulfillment: ["providerStatus": "DELIVERED"]))
        XCTAssertEqual(carrier.first { $0.label == "Carrier status" }?.value, "Delivered")
    }

    func testANamedCarrierWinsAndLinksOnlyWhenTheNumberAgrees() {
        let ups = orderTrackingDisplayRows(shippedOrder(fulfillment: ["provider": "UPS", "trackingNumbers": ["1Z999AA10123456784"]]))
        XCTAssertEqual(ups.filter { $0.label == "Carrier" }.map(\.value), ["UPS"], "no second, worked-out carrier row")
        XCTAssertNotNil(ups.first { $0.kind == .number }?.trackURL)
        let disagree = orderTrackingDisplayRows(shippedOrder(fulfillment: ["provider": "UPS"]))
        XCTAssertNil(disagree.first { $0.kind == .number }?.trackURL, "never a link to another carrier than Slant's")
    }

    func testUnrecognisedOddOrMissingNumbers() {
        let unknown = orderTrackingDisplayRows(shippedOrder(fulfillment: ["trackingNumbers": ["LS123456786US"]]))
        XCTAssertFalse(unknown.contains { $0.label == "Carrier" }, "nothing when not recognised")
        XCTAssertEqual(unknown.first?.label, "Label service", "the label service is named as one")
        XCTAssertEqual(unknown.first?.value, "Shippo")
        let noService = orderTrackingDisplayRows(shippedOrder(fulfillment: ["provider": NSNull()]))
        XCTAssertEqual(noService.first?.label, "Carrier")
        XCTAssertEqual(noService.first?.help, "Worked out from the tracking number.", "no label service to name")
        XCTAssertNil(unknown.first { $0.kind == .number }?.trackURL)
        let empty = orderTrackingDisplayRows(shippedOrder(fulfillment: ["trackingNumbers": [String]()]))
        XCTAssertFalse(empty.contains { $0.kind == .number || $0.label == "Carrier" })
        let numeric = orderTrackingDisplayRows(shippedOrder(fulfillment: ["trackingNumbers": [NSNumber(value: 123456789012 as Int64), NSNull()]]))
        XCTAssertEqual(numeric.filter { $0.kind == .number }.map(\.value), ["123456789012"], "numbers sent as numbers still read")
        XCTAssertNil(numeric.first { $0.kind == .number }?.trackCarrier, "plain digits name no carrier")
        let mixed = orderTrackingDisplayRows(shippedOrder(fulfillment: ["trackingNumbers": ["LS123456785US", "1Z999AA10123456784"]]))
        XCTAssertFalse(mixed.contains { $0.label == "Carrier" }, "numbers that disagree name no single carrier")
        XCTAssertEqual(mixed.filter { $0.kind == .number }.compactMap(\.trackCarrier), ["USPS", "UPS"], "each number keeps its own link")
    }

    func testExportNeverCallsALabelServiceTheCarrier() throws {
        let column = try XCTUnwrap(ordersCSVBaseColumns.firstIndex(of: "Carrier"))
        let detected = try XCTUnwrap(ordersCSVBaseColumns.firstIndex(of: "Carrier (from tracking number)"))
        XCTAssertEqual(detected, column + 1, "right after Slant's Carrier")
        let row = ordersCSVRow(Record(values: shippedOrder()), includeAddresses: false)
        XCTAssertEqual(row[column], "", "Carrier holds only what Slant returned, and Slant named only the label service")
        XCTAssertEqual(row[detected], "USPS")
        let ups = ordersCSVRow(Record(values: shippedOrder(fulfillment: ["provider": "UPS"])), includeAddresses: false)
        XCTAssertEqual(ups[column], "UPS")
        XCTAssertEqual(ups[detected], "", "the number disagrees with the carrier Slant named")
        for numbers in [["LS123456786US"], ["9261290876543210987652"], ["LS123456785US", "1Z999AA10123456784"], ["123456789012"]] {
            let values = shippedOrder(fulfillment: ["trackingNumbers": numbers])
            XCTAssertEqual(ordersCSVRow(Record(values: values), includeAddresses: false)[detected], "", "\(numbers)")
        }
    }

    // MARK: Tracking for Your Shop

    private func entry(numbers: [String], provider: String? = "SHIPPO", reference: String? = "#1001") -> ShopFollowUpEntry {
        ShopFollowUpEntry(id: "SLANT_TEST_2", slantOrderNumber: "SLANT_TEST_2", marketplaceID: reference, source: "shopify",
                          recipientFirstName: "Ana", provider: provider, trackingNumbers: numbers, status: "SHIPPED", created: nil)
    }

    func testCopyOrderAndTrackingAddsTheCarrierAndLink() {
        XCTAssertEqual(shopFollowUpOrderAndTrackingText(entry(numbers: ["LS123456785US"])),
                       "#1001 — LS123456785US (USPS: https://tools.usps.com/go/TrackConfirmAction?tLabels=LS123456785US)")
        XCTAssertEqual(shopFollowUpOrderAndTrackingText(entry(numbers: ["RR202401015DE"])), "#1001 — RR202401015DE (Deutsche Post)")
        XCTAssertEqual(shopFollowUpOrderAndTrackingText(entry(numbers: ["LS123456786US"])), "#1001 — LS123456786US")
        XCTAssertEqual(shopFollowUpOrderAndTrackingText(entry(numbers: ["LS123456785US"], provider: "UPS")), "#1001 — LS123456785US")
        XCTAssertFalse(shopFollowUpOrderAndTrackingText(entry(numbers: ["LS123456785US"])).contains("Ana"))
        XCTAssertEqual(shopFollowUpTrackingText(entry(numbers: ["LS123456785US"])), "LS123456785US", "Copy Tracking stays the bare number")
    }

    func testCarrierCaption() {
        let detected = shopFollowUpCarrierCaption(entry(numbers: ["LS123456785US"]))
        XCTAssertEqual(detected?.text, "USPS", "just the carrier's name")
        XCTAssertEqual(detected?.help, "Worked out from the tracking number. Label made through Shippo.")
        XCTAssertEqual(shopFollowUpCarrierCaption(entry(numbers: ["LS123456785US"], provider: "UPS"))?.text, "UPS")
        XCTAssertEqual(shopFollowUpCarrierCaption(entry(numbers: ["1Z999AA10123456784"], provider: nil))?.help,
                       "Worked out from the tracking number.")
        XCTAssertNil(shopFollowUpCarrierCaption(entry(numbers: ["X1"], provider: nil)))
        XCTAssertEqual(shopFollowUpCarrierCaption(entry(numbers: ["X1"]))?.text, "Label service: Shippo")
    }

    func testShopifyCompanyUsesOnlyAnUnambiguousDetectionShopifyNames() {
        XCTAssertEqual(shopifyTrackingCompany(entry(numbers: ["LS123456785US"])), "USPS")
        XCTAssertEqual(shopifyTrackingCompany(entry(numbers: ["1Z999AA10123456784"], provider: nil)), "UPS")
        XCTAssertEqual(shopifyTrackingCompany(entry(numbers: ["RR202401015FR"])), "", "Shopify lists no plain La Poste")
        XCTAssertEqual(shopifyTrackingCompany(entry(numbers: ["9261290876543210987652"])), "", "ambiguous")
        XCTAssertEqual(shopifyTrackingCompany(entry(numbers: ["LS123456785US", "1Z999AA10123456784"])), "", "numbers disagree")
        XCTAssertEqual(shopifyTrackingCompany(entry(numbers: ["LS123456786US"])), "", "wrong check digit")
        XCTAssertEqual(shopifyTrackingCompany(entry(numbers: ["LS123456785US"], provider: "UPS")), "UPS", "Slant's carrier, as before")
        XCTAssertEqual(shopifyTrackingCSVRows([entry(numbers: ["LS123456785US"])]), [["#1001", "LS123456785US", "USPS"]])
    }

    func testSendTrackingCandidatesCarryTheDetectedCompany() throws {
        let candidates = shopifyTrackingCandidates([entry(numbers: ["LS123456785US"]), entry(numbers: ["X1"], provider: "UPS")]
            .enumerated().map { offset, item in
                ShopFollowUpEntry(id: "S\(offset)", slantOrderNumber: "S\(offset)", marketplaceID: "#100\(offset)", source: "shopify",
                                  recipientFirstName: nil, provider: item.provider, trackingNumbers: item.trackingNumbers,
                                  status: "SHIPPED", created: nil)
            }, done: [])
        XCTAssertEqual(candidates.map(\.company), ["USPS", "UPS"])
        XCTAssertEqual(candidates.map(\.companyFromNumber), [true, false])
        XCTAssertEqual(shopifyTrackingCompanyText(candidates[0]), "USPS", "how it was worked out goes in the help")
        XCTAssertEqual(shopifyTrackingCompanyHelp(candidates[0]), "Worked out from the tracking number.")
        XCTAssertEqual(shopifyTrackingCompanyText(candidates[1]), "UPS")
        XCTAssertEqual(shopifyTrackingCompanyHelp(candidates[1]), "The carrier Slant named.")
        let plan = ShopifyFulfilmentPlan(fulfillmentOrderID: "gid://shopify/FulfillmentOrder/5",
                                         lines: [ShopifyFulfilmentLine(id: "gid://shopify/FulfillmentOrderLineItem/51", quantity: 1)],
                                         items: [], remaining: [], matchedByAddress: false)
        let input = shopifyFulfillmentInput(plan, trackingNumbers: candidates[0].trackingNumbers, company: candidates[0].company, notifyCustomer: false)
        XCTAssertEqual((input["trackingInfo"] as? [String: Any])?["company"] as? String, "USPS")
        let message = shopifyTrackingConfirmationMessage(jobs: candidates, notifyCustomer: false)
        XCTAssertTrue(message.contains("Carrier sent: UPS for 1 order, USPS for 1 order."), message)
        XCTAssertTrue(message.contains("Customers aren’t emailed."))
        let blank = ShopifyTrackingCandidate(id: "B", orderName: "#9", trackingNumbers: ["X"], company: "")
        XCTAssertFalse(shopifyTrackingConfirmationMessage(jobs: [blank], notifyCustomer: true).contains("Carrier sent"))
        XCTAssertEqual(shopifyTrackingCompanySentence([candidates[0], candidates[0], blank]),
                       "Carrier sent: USPS for 2 orders; Shopify works out the rest.")
        XCTAssertNil(shopifyTrackingCompanyText(blank))
    }

    // MARK: 3DAPI

    func testDapiShippingPrefersItsCarrierAndLinksOnlyWhenTheNumberAgrees() {
        let none = DapiOrderShipping(tier: nil, carrier: nil, trackingNumber: "LS123456785US", shippedAt: nil)
        XCTAssertEqual(dapiShippingCarrierText(none), "USPS")
        XCTAssertEqual(dapiShippingCarrierHelp(none), "Worked out from the tracking number.")
        XCTAssertNotNil(dapiShippingDetectedCarrier(none)?.trackingURL)
        XCTAssertNil(dapiShippingTrackingNote(none), "Track Parcel covers it")
        let named = DapiOrderShipping(tier: nil, carrier: "USPS", trackingNumber: "LS123456785US", shippedAt: nil)
        XCTAssertEqual(dapiShippingCarrierText(named), "USPS")
        XCTAssertNil(dapiShippingCarrierHelp(named), "3DAPI's own name needs no explanation")
        XCTAssertNotNil(dapiShippingDetectedCarrier(named))
        let other = DapiOrderShipping(tier: nil, carrier: "Royal Mail", trackingNumber: "LS123456785US", shippedAt: nil)
        XCTAssertEqual(dapiShippingCarrierText(other), "Royal Mail")
        XCTAssertNil(dapiShippingDetectedCarrier(other))
        XCTAssertNotNil(dapiShippingTrackingNote(other))
        let unknown = DapiOrderShipping(tier: nil, carrier: nil, trackingNumber: "ABC", shippedAt: nil)
        XCTAssertNil(dapiShippingCarrierText(unknown))
        XCTAssertNotNil(dapiShippingTrackingNote(unknown))
        XCTAssertNil(dapiShippingTrackingNote(DapiOrderShipping(tier: "small", carrier: nil, trackingNumber: nil, shippedAt: nil)))
    }
}

// MARK: - Remembered done marks

final class ShopFollowUpDoneTests: XCTestCase {
    func testMarksKeepTheirOrderAndOnlyTheNewestAreKept() {
        var record = ShopFollowUpDoneRecord()
        record = record.updating(to: ["B", "A"])
        XCTAssertEqual(record.order, ["A", "B"], "several added at once land sorted")
        record = record.updating(to: ["A", "B", "C"])
        XCTAssertEqual(record.order, ["A", "B", "C"])
        record = record.updating(to: ["A", "C"])
        XCTAssertEqual(record.order, ["A", "C"])
        XCTAssertEqual(record.ids, ["A", "C"])
        let many = ShopFollowUpDoneRecord(order: (0...shopFollowUpDoneLimit).map { "O\($0)" })
        XCTAssertEqual(many.order.count, shopFollowUpDoneLimit)
        XCTAssertEqual(many.order.first, "O1", "the oldest goes first")
        XCTAssertEqual(ShopFollowUpDoneRecord(order: ["A", "A", "B"]).order, ["A", "B"])
    }

    func testFileRoundTripsAndHoldsOnlyOrderIDs() throws {
        let record = ShopFollowUpDoneRecord(order: ["SLANT_TEST_1", "SLANT_TEST_2"])
        let data = try XCTUnwrap(encodeShopFollowUpDone(record))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["version", "orderIDs"])
        XCTAssertEqual(decodeShopFollowUpDone(data), record)
    }

    func testDecodingIsLenient() {
        XCTAssertEqual(decodeShopFollowUpDone(Data("not json".utf8)), ShopFollowUpDoneRecord())
        XCTAssertEqual(decodeShopFollowUpDone(Data("[\"A\"]".utf8)), ShopFollowUpDoneRecord())
        XCTAssertEqual(decodeShopFollowUpDone(Data("{\"orderIDs\":\"A\"}".utf8)), ShopFollowUpDoneRecord())
        let long = String(repeating: "x", count: shopFollowUpDoneMaxIDLength + 1)
        let json = "{\"orderIDs\":[\" A \",1,null,\"\",\"B\\u0000\",\"\(long)\",\"C\",\"A\"],\"extra\":true}"
        XCTAssertEqual(decodeShopFollowUpDone(Data(json.utf8)).order, ["A", "C"])
    }

    func testSaveAndLoadInATemporaryFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PlinthTests-done-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(shopFollowUpDoneFileName)
        XCTAssertEqual(loadShopFollowUpDone(from: url), ShopFollowUpDoneRecord(), "no file, no marks")
        let record = ShopFollowUpDoneRecord(order: ["SLANT_TEST_1"])
        saveShopFollowUpDone(record, to: url)
        XCTAssertEqual(loadShopFollowUpDone(from: url), record)
        try Data("{corrupt".utf8).write(to: url)
        XCTAssertEqual(loadShopFollowUpDone(from: url), ShopFollowUpDoneRecord(), "a damaged file gives no marks")
        saveShopFollowUpDone(ShopFollowUpDoneRecord(), to: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "no marks, no file")
    }
}
