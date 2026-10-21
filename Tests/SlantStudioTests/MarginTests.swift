import XCTest
@testable import SlantStudio

final class MarginTests: XCTestCase {
    private func dec(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    // MARK: Maths

    func testEtsyPresetLineByLine() {
        let result = profitCheck(itemTotal: 20, shippingCharged: 5, preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates,
                                 offsiteAds: false, itemsSold: 2, slantTotal: dec("12.34"))
        XCTAssertEqual(result.revenue, 25)
        // 6.5% of 25 = 1.625 → 1.63; 3% of 25 + 0.25 = 1.00; 2 × 0.20 = 0.40.
        XCTAssertEqual(result.lines.map(\.amount), [20, 5, dec("-1.63"), dec("-1.00"), dec("-0.40"), dec("-12.34")])
        XCTAssertEqual(result.fees, dec("3.03"))
        XCTAssertEqual(result.slantTotal, dec("12.34"))
        XCTAssertEqual(result.profit, dec("9.63"))
        XCTAssertEqual(result.marginPercent, dec("38.5"))
    }

    func testEtsyOffsiteAdsAddsFifteenPercentAndIsCapped() {
        let rates = ProfitFeePreset.etsyUS.defaultRates
        let withAds = profitCheck(itemTotal: 20, shippingCharged: 5, preset: .etsyUS, rates: rates, offsiteAds: true, itemsSold: 2, slantTotal: dec("12.34"))
        XCTAssertEqual(withAds.fees, dec("6.78"))
        XCTAssertEqual(withAds.profit, dec("5.88"))
        XCTAssertEqual(withAds.marginPercent, dec("23.5"))

        let large = profitCheck(itemTotal: 1000, shippingCharged: 0, preset: .etsyUS, rates: rates, offsiteAds: true, itemsSold: 1, slantTotal: 0)
        XCTAssertTrue(large.lines.contains { $0.label.hasPrefix("Offsite Ads") && $0.amount == -100 })

        // Offsite Ads only applies to the Etsy preset.
        let shopify = profitCheck(itemTotal: 20, shippingCharged: 5, preset: .shopifyBasicUS, rates: rates, offsiteAds: true, itemsSold: 1, slantTotal: 0)
        XCTAssertFalse(shopify.lines.contains { $0.label.hasPrefix("Offsite Ads") })
    }

    func testShopifyBasicPreset() {
        let result = profitCheck(itemTotal: 30, shippingCharged: 0, preset: .shopifyBasicUS, rates: ProfitFeePreset.shopifyBasicUS.defaultRates,
                                 offsiteAds: false, itemsSold: 3, slantTotal: 10)
        // 2.9% of 30 = 0.87 + 0.30; no transaction or listing fee lines.
        XCTAssertEqual(result.fees, dec("1.17"))
        XCTAssertEqual(result.profit, dec("18.83"))
        XCTAssertEqual(result.marginPercent, dec("62.8"))
        XCTAssertEqual(result.lines.count, 4)
    }

    func testNonePresetChargesNoFees() {
        let result = profitCheck(itemTotal: 15, shippingCharged: dec("4.99"), preset: .none, rates: ProfitFeePreset.etsyUS.defaultRates,
                                 offsiteAds: true, itemsSold: 1, slantTotal: dec("9.99"))
        XCTAssertEqual(result.fees, 0)
        XCTAssertEqual(result.profit, dec("10.00"))
    }

    func testCustomPercentAndFixedFees() {
        let rates = ProfitFeeRates(transactionPercent: 10, processingPercent: 0, processingFixed: dec("0.50"), listingFeePerItem: 1, offsiteAdsPercent: 0)
        let result = profitCheck(itemTotal: dec("9.99"), shippingCharged: 0, preset: .custom, rates: rates, offsiteAds: false, itemsSold: 0, slantTotal: 5)
        // 10% of 9.99 = 0.999 → 1.00; fixed 0.50; listing uses at least one item.
        XCTAssertEqual(result.fees, dec("2.50"))
        XCTAssertEqual(result.profit, dec("2.49"))
    }

    func testZeroRevenueHasNoFeesAndNoMargin() {
        let result = profitCheck(itemTotal: 0, shippingCharged: 0, preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates,
                                 offsiteAds: true, itemsSold: 1, slantTotal: 8)
        XCTAssertEqual(result.fees, 0)
        XCTAssertEqual(result.profit, -8)
        XCTAssertNil(result.marginPercent)
    }

    func testNegativeInputsAreClampedAndLossesAreNegative() {
        let result = profitCheck(itemTotal: -5, shippingCharged: -1, preset: .none, rates: ProfitFeeRates(), offsiteAds: false, itemsSold: 1, slantTotal: 3)
        XCTAssertEqual(result.revenue, 0)
        let loss = profitCheck(itemTotal: 5, shippingCharged: 0, preset: .none, rates: ProfitFeeRates(), offsiteAds: false, itemsSold: 1, slantTotal: 10)
        XCTAssertEqual(loss.profit, -5)
        XCTAssertEqual(loss.marginPercent, -100)
        XCTAssertEqual(profitMoney(-5), "−$5.00")
        XCTAssertEqual(profitMoney(dec("12.3")), "$12.30")
    }

    func testAmountsRoundToCentsWithoutDoubleDrift() {
        let result = profitCheck(itemTotal: dec("0.1"), shippingCharged: dec("0.2"), preset: .none, rates: ProfitFeeRates(),
                                 offsiteAds: false, itemsSold: 1, slantTotal: dec("0.104"))
        XCTAssertEqual(result.revenue, dec("0.3"))
        XCTAssertEqual(result.slantTotal, dec("0.10"))
        XCTAssertEqual(result.profit, dec("0.2"))
        let huge = profitCheck(itemTotal: profitMoneyInputLimit, shippingCharged: profitMoneyInputLimit, preset: .etsyUS,
                               rates: ProfitFeePreset.etsyUS.defaultRates, offsiteAds: true, itemsSold: 10_000, slantTotal: 1)
        XCTAssertEqual(huge.revenue, 2_000_000)
        XCTAssertNotNil(huge.marginPercent)
    }

    // MARK: Input parsing

    func testParsesTypedAmounts() {
        XCTAssertEqual(parseProfitAmount("12.50", decimalSeparator: "."), dec("12.5"))
        XCTAssertEqual(parseProfitAmount(" $24.99 ", decimalSeparator: "."), dec("24.99"))
        XCTAssertEqual(parseProfitAmount("US$5", decimalSeparator: "."), 5)
        XCTAssertEqual(parseProfitAmount("24.99 USD", decimalSeparator: "."), dec("24.99"))
        XCTAssertEqual(parseProfitAmount("12,50", decimalSeparator: "."), dec("12.5"))
        XCTAssertEqual(parseProfitAmount("12,50", decimalSeparator: ","), dec("12.5"))
        XCTAssertEqual(parseProfitAmount("1,234.56", decimalSeparator: "."), dec("1234.56"))
        XCTAssertEqual(parseProfitAmount("1.234,56", decimalSeparator: ","), dec("1234.56"))
        XCTAssertEqual(parseProfitAmount("1 234,50", decimalSeparator: ","), dec("1234.5"))
        XCTAssertEqual(parseProfitAmount("1,234", decimalSeparator: "."), 1234)
        XCTAssertEqual(parseProfitAmount("1,234", decimalSeparator: ","), dec("1.234"))
        XCTAssertEqual(parseProfitAmount("1.234", decimalSeparator: "."), dec("1.234"))
        XCTAssertEqual(parseProfitAmount("1.234", decimalSeparator: ","), 1234)
        XCTAssertEqual(parseProfitAmount("123,456", decimalSeparator: "."), 123_456)
        XCTAssertNil(parseProfitAmount("1,234,567", decimalSeparator: "."), "above the input limit")
        XCTAssertEqual(parseProfitAmount("0", decimalSeparator: "."), 0)
        XCTAssertEqual(parseProfitAmount(".5", decimalSeparator: "."), dec("0.5"))
    }

    func testRejectsNonNumericNegativeAndHugeAmounts() {
        for text in ["", " ", "abc", "-5", "1e5", "12.3.4", "1,2,3", "12abc", "$", "１２", "NaN", "1,23.45", "1.234.5,6,7", "2000000", "9999999999999999999999"] {
            XCTAssertNil(parseProfitAmount(text, decimalSeparator: "."), text)
        }
        XCTAssertEqual(parseProfitAmount("1000000", decimalSeparator: "."), 1_000_000)
    }

    func testParsesPercentages() {
        XCTAssertEqual(parseProfitPercent("6.5%", decimalSeparator: "."), dec("6.5"))
        XCTAssertEqual(parseProfitPercent("6,5", decimalSeparator: ","), dec("6.5"))
        XCTAssertEqual(parseProfitPercent("100", decimalSeparator: "."), 100)
        XCTAssertNil(parseProfitPercent("150", decimalSeparator: "."))
        XCTAssertNil(parseProfitPercent("-3", decimalSeparator: "."))
    }

    // MARK: Slant total

    func testSlantTotalReadsNumbersAndStrings() {
        XCTAssertEqual(profitCheckSlantTotal(["total": "12.50"]), .amount(dec("12.5")))
        XCTAssertEqual(profitCheckSlantTotal(["totalCost": NSNumber(value: 9.99)]), .amount(dec("9.99")))
        XCTAssertEqual(profitCheckSlantTotal(["printingCost": "8.00", "deliveryCost": "4.34", "status": "DRAFT"]), .amount(dec("12.34")))
        XCTAssertEqual(profitCheckSlantTotal(["printingCost": 8, "deliveryCost": "4.345"]), .amount(dec("12.35")))
        // Draft envelope totals are merged into the order first.
        let merged = mergeOrderDraftEnvelope(["order": ["publicId": "SLANT_1"], "totals": ["printingCost": "3", "deliveryCost": "2", "totalCost": "5.00"]])
        XCTAssertEqual(profitCheckSlantTotal(merged), .amount(5))
    }

    func testSlantTotalExplainsWhenUnavailable() {
        func reason(_ order: [String: Any]) -> String? {
            if case .unavailable(let text) = profitCheckSlantTotal(order) { return text }
            return nil
        }
        XCTAssertNotNil(reason([:]))
        XCTAssertNotNil(reason(["total": NSNull()]))
        XCTAssertNotNil(reason(["total": "abc"]))
        XCTAssertNotNil(reason(["total": true]))
        XCTAssertNotNil(reason(["total": "-4"]))
        XCTAssertNotNil(reason(["printingCost": "8.00"]), "a partial cost isn't a total")
        XCTAssertTrue(reason(["printingCost": "8.00"])?.contains("part") == true)
        XCTAssertTrue(reason(["total": "10", "status": "CANCELED"])?.contains("cancelled") == true)
        XCTAssertTrue(reason(["total": "10", "currency": "EUR"])?.contains("EUR") == true)
        XCTAssertEqual(profitCheckSlantTotal(["total": "10", "currency": "usd"]), .amount(10))
    }

    func testItemsSoldSumsQuantities() {
        XCTAssertEqual(profitCheckItemsSold(["items": [["quantity": 2], ["quantity": "3"]]]), 5)
        XCTAssertNil(profitCheckItemsSold([:]))
        XCTAssertNil(profitCheckItemsSold(["items": [["quantity": 2], ["name": "x"]]]))
        XCTAssertNil(profitCheckItemsSold(["items": [["quantity": Int.max], ["quantity": Int.max]]]))
        XCTAssertNil(profitCheckItemsSold(["items": [["quantity": -2]]]))
    }

    // MARK: Saved settings

    func testSettingsPersistOnlyPresetAndRates() throws {
        let suite = "MarginTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(ProfitFeeSettings.loadPreset(defaults), .none)
        XCTAssertEqual(ProfitFeeSettings.loadRates(.etsyUS, defaults), ProfitFeePreset.etsyUS.defaultRates)

        var rates = ProfitFeePreset.etsyUS.defaultRates
        rates.offsiteAdsPercent = 12
        ProfitFeeSettings.save(preset: .etsyUS, rates: rates, defaults)
        XCTAssertEqual(ProfitFeeSettings.loadPreset(defaults), .etsyUS)
        XCTAssertEqual(ProfitFeeSettings.loadRates(.etsyUS, defaults), rates)
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []),
                       [ProfitFeeSettings.presetKey, ProfitFeeSettings.ratesKey(.etsyUS)])

        // A corrupted saved value falls back to that field's default.
        defaults.set(["transactionPercent": "lots"], forKey: ProfitFeeSettings.ratesKey(.etsyUS))
        XCTAssertEqual(ProfitFeeSettings.loadRates(.etsyUS, defaults).transactionPercent, dec("6.5"))
        ProfitFeeSettings.resetRates(.etsyUS, defaults)
        XCTAssertEqual(ProfitFeeSettings.loadRates(.etsyUS, defaults), ProfitFeePreset.etsyUS.defaultRates)
        defaults.set("bogus", forKey: ProfitFeeSettings.presetKey)
        XCTAssertEqual(ProfitFeeSettings.loadPreset(defaults), .none)
    }

    func testPresetRatesMatchPublishedAssumptions() {
        let etsy = ProfitFeePreset.etsyUS.defaultRates
        XCTAssertEqual(etsy, ProfitFeeRates(transactionPercent: dec("6.5"), processingPercent: 3, processingFixed: dec("0.25"),
                                            listingFeePerItem: dec("0.2"), offsiteAdsPercent: 15))
        XCTAssertEqual(ProfitFeePreset.shopifyBasicUS.defaultRates, ProfitFeeRates(processingPercent: dec("2.9"), processingFixed: dec("0.3")))
        XCTAssertEqual(ProfitFeePreset.none.defaultRates, ProfitFeeRates())
        XCTAssertEqual(profitRateText(dec("6.5")), "6.5")
    }

    // MARK: Duplicate-draft guard

    func testDraftCreateOutcomeTransitions() {
        let timeout = URLError(.timedOut)
        let serverError = APIError.http(status: 502, body: "", retryAfter: nil, rateLimitReset: nil)
        let conflict = APIError.http(status: 409, body: "", retryAfter: nil, rateLimitReset: nil)
        let refused = APIError.http(status: 400, body: "bad address", retryAfter: nil, rateLimitReset: nil)
        let notSent = APIError.invalidRequest("Connect your account in Connection first.")
        let noOrderNumber = StudioError("Slant didn’t return an order number.")

        for error in [timeout, serverError, conflict, noOrderNumber] as [Error] {
            XCTAssertTrue(draftCreateOutcomeUnknown(previous: false, attempt: .failed(error)), "\(error)")
        }
        XCTAssertTrue(draftCreateOutcomeUnknown(previous: false, attempt: .failed(APIError.invalidResponse("garbled"))))
        // A definite refusal or a request never sent proves nothing about an earlier unknown attempt.
        XCTAssertFalse(draftCreateOutcomeUnknown(previous: false, attempt: .failed(refused)))
        XCTAssertTrue(draftCreateOutcomeUnknown(previous: true, attempt: .failed(refused)))
        XCTAssertFalse(draftCreateOutcomeUnknown(previous: false, attempt: .failed(notSent)))
        XCTAssertTrue(draftCreateOutcomeUnknown(previous: true, attempt: .notSent))
        XCTAssertFalse(draftCreateOutcomeUnknown(previous: false, attempt: .notSent))
        // Only a confirmed creation clears it.
        XCTAssertFalse(draftCreateOutcomeUnknown(previous: true, attempt: .succeeded))
    }

    func testDraftCreateConfirmationAndDiscardCopy() {
        XCTAssertTrue(draftCreateNeedsConfirmation(outcomeUnknown: true, confirmed: false))
        XCTAssertFalse(draftCreateNeedsConfirmation(outcomeUnknown: true, confirmed: true))
        XCTAssertFalse(draftCreateNeedsConfirmation(outcomeUnknown: false, confirmed: false))
        // Draft creation is never retried, by the client or the alert’s Try again.
        XCTAssertFalse(isRetryableAPICall(method: "POST", path: "/orders"))
        XCTAssertTrue(orderComposerDiscardMessage(outcomeUnknown: false).contains("Nothing has been sent"))
        XCTAssertFalse(orderComposerDiscardMessage(outcomeUnknown: true).contains("Nothing has been sent"))
        XCTAssertTrue(orderComposerDiscardMessage(outcomeUnknown: true).contains("Orders › Drafts"))
    }

    // MARK: Marketplace reference

    func testMarketplaceReferenceFromMetadata() {
        let etsy = orderMarketplaceReference(["metadata": ["sourceOrderId": " 3141592653 ", "source": "Etsy"]])
        XCTAssertEqual(etsy?.id, "3141592653")
        XCTAssertEqual(etsy?.source, "Etsy")
        XCTAssertEqual(orderMarketplaceReferenceLabel(source: etsy?.source), "Etsy order")

        let numeric = orderMarketplaceReference(["metadata": ["sourceOrderId": 1042]])
        XCTAssertEqual(numeric?.id, "1042")
        XCTAssertNil(numeric?.source)
        XCTAssertEqual(orderMarketplaceReferenceLabel(source: nil), "Marketplace order")

        XCTAssertNil(orderMarketplaceReference([:]))
        XCTAssertNil(orderMarketplaceReference(["metadata": NSNull()]))
        XCTAssertNil(orderMarketplaceReference(["metadata": "text"]))
        XCTAssertNil(orderMarketplaceReference(["metadata": ["source": "Etsy"]]))
        XCTAssertNil(orderMarketplaceReference(["metadata": ["sourceOrderId": "  "]]))
        XCTAssertNil(orderMarketplaceReference(["metadata": ["sourceOrderId": ["nested": 1]]]))
        XCTAssertNil(orderMarketplaceReference(["metadata": ["sourceOrderId": true]]))
        XCTAssertNil(orderMarketplaceReference(["metadata": ["sourceOrderId": "1", "source": ["x"]]])?.source)
    }
}
