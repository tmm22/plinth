import XCTest
@testable import Plinth

/// Check Cost's listing price check (Margin.swift, ProductCostCheck.swift): memory only, the Profit check's fee maths.
extension MarginTests {
    private func cents(_ text: String) -> Decimal { Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))! }

    func testListingPriceCheckUsesTheProfitChecksFees() {
        let result = listingPriceCheck(listingPricePerUnit: 20, shippingCharged: 5, units: 1, productCost: cents("8.00"),
                                       delivery: cents("4.34"), preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates, offsiteAds: false)
        // 6.5% of 25 → 1.63; 3% of 25 + 0.25 → 1.00; 1 × 0.20.
        XCTAssertEqual(result.lines.map(\.amount), [20, 5, cents("-1.63"), cents("-1.00"), cents("-0.20"), cents("-8.00"), cents("-4.34")])
        XCTAssertEqual(result.lines.first?.label, "Listing price")
        XCTAssertEqual(result.lines[1].label, "Shipping you charge")
        XCTAssertEqual(result.lines[5].label, listingPriceCostLineLabel)
        XCTAssertEqual(result.lines[6].label, listingPriceDeliveryLineLabel)
        XCTAssertEqual(result.fees, cents("2.83"))
        XCTAssertEqual(result.cost, cents("12.34"))
        XCTAssertEqual(result.profit, cents("9.83"))
        XCTAssertEqual(result.marginPercent, cents("39.3"))
        // The same figures as the order Profit check would give for that sale.
        let order = profitCheck(itemTotal: 20, shippingCharged: 5, preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates,
                                offsiteAds: false, unitsSold: 1, slantTotal: cents("12.34"))
        XCTAssertEqual(order.profit, result.profit)
    }

    func testListingPriceCheckPerUnitAndMissingDelivery() {
        let result = listingPriceCheck(listingPricePerUnit: 10, shippingCharged: 0, units: 3, productCost: 15, delivery: nil,
                                       preset: .none, rates: ProfitFeeRates(), offsiteAds: false)
        // No shipping line when nothing is charged, no delivery line without a hint.
        XCTAssertEqual(result.lines.map(\.label), ["Listing price (3 × $10.00)", listingPriceCostLineLabel])
        XCTAssertEqual(result.revenue, 30)
        XCTAssertEqual(result.profit, 15)
        XCTAssertEqual(result.profitPerUnit, 5)
        XCTAssertEqual(result.feesPerUnit, 0)
        XCTAssertEqual(result.marginPercent, 50)
        // Etsy's listing fee counts every unit; per-unit figures round to the cent.
        let etsy = listingPriceCheck(listingPricePerUnit: 10, shippingCharged: 0, units: 3, productCost: 10, delivery: nil,
                                     preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates, offsiteAds: false)
        // 6.5% of 30 = 1.95; 3% + 0.25 = 1.15; 3 × 0.20 = 0.60 → 3.70.
        XCTAssertEqual(etsy.fees, cents("3.70"))
        XCTAssertEqual(etsy.profit, cents("16.30"))
        XCTAssertEqual(etsy.profitPerUnit, cents("5.43"))
        XCTAssertEqual(etsy.feesPerUnit, cents("1.23"))
    }

    func testListingPriceCheckRoundsAndClamps() {
        let rounded = listingPriceCheck(listingPricePerUnit: cents("10.005"), shippingCharged: 0, units: 1, productCost: cents("3.333"),
                                        delivery: nil, preset: .none, rates: ProfitFeeRates(), offsiteAds: false)
        XCTAssertEqual(rounded.revenue, cents("10.01"))
        XCTAssertEqual(rounded.cost, cents("3.33"))
        XCTAssertEqual(rounded.profit, cents("6.68"))
        // Zero price: no revenue, no fees, no margin, a loss of the cost.
        let zero = listingPriceCheck(listingPricePerUnit: 0, shippingCharged: 0, units: 1, productCost: 5, delivery: 2,
                                     preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates, offsiteAds: false)
        XCTAssertEqual(zero.fees, 0)
        XCTAssertNil(zero.marginPercent)
        XCTAssertEqual(zero.profit, -7)
        // Negative inputs are treated as zero; zero units count as one.
        let negative = listingPriceCheck(listingPricePerUnit: -5, shippingCharged: -1, units: 0, productCost: -3, delivery: -1,
                                         preset: .none, rates: ProfitFeeRates(), offsiteAds: false)
        XCTAssertEqual(negative.units, 1)
        XCTAssertEqual(negative.profit, 0)
        // Fees larger than the price give a loss, never a positive figure.
        let costly = ProfitFeeRates(transactionPercent: 60, processingPercent: 40, processingFixed: 1)
        let loss = listingPriceCheck(listingPricePerUnit: 10, shippingCharged: 0, units: 1, productCost: 2, delivery: nil,
                                     preset: .custom, rates: costly, offsiteAds: false)
        XCTAssertEqual(loss.fees, 11)
        XCTAssertEqual(loss.profit, -3)
        XCTAssertEqual(loss.marginPercent, -30)
    }

    /// The solved price keeps the margin with the shown (cent-rounded) maths, and a cent less doesn't.
    private func assertLowestPrice(_ target: Decimal, shipping: Decimal, units: Int, cost: Decimal, delivery: Decimal?,
                                   preset: ProfitFeePreset, rates: ProfitFeeRates, ads: Bool, file: StaticString = #filePath, line: UInt = #line) {
        guard case .price(let price) = listingPriceForTargetMargin(target, shippingCharged: shipping, units: units, productCost: cost,
                                                                   delivery: delivery, preset: preset, rates: rates, offsiteAds: ads) else {
            return XCTFail("Expected a price", file: file, line: line)
        }
        func keeps(_ p: Decimal) -> Bool {
            let check = listingPriceCheck(listingPricePerUnit: p, shippingCharged: shipping, units: units, productCost: cost,
                                          delivery: delivery, preset: preset, rates: rates, offsiteAds: ads)
            return check.revenue > 0 && check.profit * 100 >= target * check.revenue
        }
        XCTAssertEqual(price, roundedToCents(price), file: file, line: line)
        XCTAssertTrue(keeps(price), "\(price) should keep \(target)%", file: file, line: line)
        if price > cents("0.01") { XCTAssertFalse(keeps(price - cents("0.01")), "\(price) isn’t the lowest", file: file, line: line) }
    }

    func testTargetMarginGivesTheLowestPriceThatKeepsIt() {
        XCTAssertEqual(listingPriceForTargetMargin(50, shippingCharged: 0, units: 1, productCost: 15, delivery: nil,
                                                   preset: .none, rates: ProfitFeeRates(), offsiteAds: false), .price(30))
        let etsy = ProfitFeePreset.etsyUS.defaultRates
        assertLowestPrice(30, shipping: 5, units: 1, cost: cents("8.00"), delivery: cents("4.34"), preset: .etsyUS, rates: etsy, ads: false)
        assertLowestPrice(25, shipping: 0, units: 4, cost: cents("31.17"), delivery: nil, preset: .etsyUS, rates: etsy, ads: false)
        assertLowestPrice(0, shipping: 0, units: 1, cost: cents("9.99"), delivery: nil, preset: .etsyUS, rates: etsy, ads: false)
        assertLowestPrice(40, shipping: cents("3.50"), units: 2, cost: 12, delivery: 6, preset: .shopifyBasicUS,
                          rates: ProfitFeePreset.shopifyBasicUS.defaultRates, ads: false)
        // Offsite Ads below and above Etsy's $100 cap.
        assertLowestPrice(20, shipping: 0, units: 1, cost: 10, delivery: nil, preset: .etsyUS, rates: etsy, ads: true)
        assertLowestPrice(10, shipping: 0, units: 1, cost: 1000, delivery: nil, preset: .etsyUS, rates: etsy, ads: true)
        // Offsite Ads only counts for a preset that offers it.
        XCTAssertEqual(listingPriceForTargetMargin(50, shippingCharged: 0, units: 1, productCost: 15, delivery: nil,
                                                   preset: .shopifyBasicUS, rates: ProfitFeeRates(offsiteAdsPercent: 15), offsiteAds: true),
                       listingPriceForTargetMargin(50, shippingCharged: 0, units: 1, productCost: 15, delivery: nil,
                                                   preset: .shopifyBasicUS, rates: ProfitFeeRates(), offsiteAds: false))
    }

    func testTargetMarginThatCantBeReached() {
        let etsy = ProfitFeePreset.etsyUS.defaultRates
        func reason(_ target: ListingPriceTarget) -> String? { if case .unreachable(let text) = target { return text }; return nil }
        // 100% or more.
        XCTAssertNotNil(reason(listingPriceForTargetMargin(100, shippingCharged: 0, units: 1, productCost: 5, delivery: nil,
                                                           preset: .none, rates: ProfitFeeRates(), offsiteAds: false)))
        // Percentage fees of 100% or more.
        let all = ProfitFeeRates(transactionPercent: 60, processingPercent: 40)
        let full = reason(listingPriceForTargetMargin(0, shippingCharged: 0, units: 1, productCost: 5, delivery: nil,
                                                      preset: .custom, rates: all, offsiteAds: false))
        XCTAssertEqual(full, "Can’t reach 0%: fees of 100% of the sale plus that margin leave nothing to cover the cost.")
        // Fees plus margin past 100%.
        XCTAssertNotNil(reason(listingPriceForTargetMargin(95, shippingCharged: 0, units: 1, productCost: 5, delivery: nil,
                                                           preset: .etsyUS, rates: etsy, offsiteAds: false)))
        // A price beyond the input limit.
        let huge = reason(listingPriceForTargetMargin(99, shippingCharged: 0, units: 1, productCost: 999_999, delivery: nil,
                                                      preset: .none, rates: ProfitFeeRates(), offsiteAds: false))
        XCTAssertEqual(huge, "Would need a listing price over $1,000,000.00 a unit.")
        // Negative targets aren't offered (the parser refuses them), and are refused here too.
        XCTAssertNotNil(reason(listingPriceForTargetMargin(-5, shippingCharged: 0, units: 1, productCost: 5, delivery: nil,
                                                           preset: .none, rates: ProfitFeeRates(), offsiteAds: false)))
    }

    func testShippingAloneCanKeepTheMargin() {
        XCTAssertEqual(listingPriceForTargetMargin(50, shippingCharged: 20, units: 1, productCost: 5, delivery: nil,
                                                   preset: .none, rates: ProfitFeeRates(), offsiteAds: false), .coveredByShipping)
        // Nothing to cover at all: the smallest price.
        XCTAssertEqual(listingPriceForTargetMargin(10, shippingCharged: 0, units: 1, productCost: 0, delivery: nil,
                                                   preset: .none, rates: ProfitFeeRates(), offsiteAds: false), .price(cents("0.01")))
    }

    func testListingPriceTextsAndCost() {
        XCTAssertEqual(listingPriceTargetText(.price(cents("18.4")), targetPercent: 30), "List at $18.40 a unit or more to keep a 30% margin.")
        XCTAssertEqual(listingPriceTargetText(.coveredByShipping, targetPercent: cents("12.5")),
                       "The shipping you charge already keeps a 12.5% margin, whatever the listing price.")
        XCTAssertEqual(listingPriceTargetText(.unreachable("No."), targetPercent: 30), "No.")
        // Delivery is an average of past orders, never a quote; a missing hint says the profit is before delivery.
        XCTAssertTrue(listingPriceDeliveryNote(nil).contains("before delivery"))
        let hint = listingPriceDeliveryNote(ProductDeliveryHint(countryCode: "US", orders: 3, average: 5))
        XCTAssertTrue(hint.contains("average"))
        XCTAssertTrue(hint.contains("3 past orders"))
        XCTAssertTrue(hint.contains("not a quote"))
        // Only a complete cost is used.
        let priced = ProductCostPart(id: 0, type: "PRINT", title: "A", quantity: 1, perOrder: false, state: .priced(total: 7, detail: ""))
        let failed = ProductCostPart(id: 1, type: "PRINT", title: "B", quantity: 1, perOrder: false, state: .failed("No"))
        XCTAssertEqual(listingPriceCheckCost(productCostSummary([priced], units: 1)), 7)
        XCTAssertNil(listingPriceCheckCost(productCostSummary([priced, failed], units: 1)))
        XCTAssertNil(listingPriceCheckUnavailableText(productCostSummary([priced], units: 1)))
        XCTAssertTrue(listingPriceCheckUnavailableText(productCostSummary([priced, failed], units: 1))!.contains("overstate"))
        XCTAssertTrue(listingPriceCheckUnavailableText(productCostSummary([], units: 1))!.hasPrefix("Check the cost first"))
    }
}
