import XCTest
@testable import Plinth

final class ImportedSaleAmountsTests: XCTestCase {
    // MARK: Fixtures

    private let etsyHeader = "Sale Date,Item Name,Buyer,Quantity,Price,Coupon Code,Coupon Details,Discount Amount,Shipping Discount,Order Shipping,Order Sales Tax,Item Total,Currency,Transaction ID,Listing ID,Date Paid,Date Shipped,Ship Name,Ship Address1,Ship Address2,Ship City,Ship State,Ship Zipcode,Ship Country,Order ID,Variations,SKU"

    /// One Etsy item row: quantity, price, discount, shipping discount, order shipping, item total, currency, order ID.
    private func etsyRow(_ quantity: String, _ price: String, discount: String = "0.00", shippingDiscount: String = "0.00",
                         shipping: String = "4.50", itemTotal: String? = nil, currency: String = "USD", order: String = "T-1001",
                         sku: String = "TIDY") -> String {
        let total = itemTotal ?? ""
        return "10/01/26,Desk Tidy,ana,\(quantity),\(price),,,\(discount),\(shippingDiscount),\(shipping),0.80,\(total),\(currency),1,2,10/01/26,,Ana Lee,1 Main St,,Austin,TX,78701,United States,\(order),,\(sku)"
    }

    private func parse(_ lines: [String]) throws -> OrderImportParse {
        try orderImportParse(data: Data(lines.joined(separator: "\n").utf8))
    }

    private func amounts(_ lines: [String], order index: Int = 0) throws -> ImportedSaleParse {
        importedSaleAmounts(for: try parse(lines).orders[index])
    }

    private func usd(_ result: ImportedSaleParse, file: StaticString = #filePath, line: UInt = #line) throws -> ImportedSaleAmounts {
        guard case .amounts(let amounts) = result else {
            XCTFail("Expected USD amounts, got \(result)", file: file, line: line)
            throw XCTSkip()
        }
        return amounts
    }

    private let shopifyHeader = "Name,Email,Financial Status,Fulfillment Status,Currency,Subtotal,Shipping,Taxes,Total,Discount Amount,Lineitem quantity,Lineitem name,Lineitem sku,Shipping Name,Shipping Address1,Shipping City,Shipping Zip,Shipping Province,Shipping Country,Refunded Amount"

    private func shopifyFirst(subtotal: String = "30.00", shipping: String = "5.00", taxes: String = "2.50", total: String = "37.50",
                              discount: String = "0.00", quantity: String = "2", refunded: String = "0.00", currency: String = "USD") -> String {
        "#1001,ana@example.com,paid,unfulfilled,\(currency),\(subtotal),\(shipping),\(taxes),\(total),\(discount),\(quantity),Desk Tidy,TIDY,Ana Lee,1 Main St,Boston,02134,MA,US,\(refunded)"
    }
    private let shopifyFollowOn = "#1001,ana@example.com,,,,,,,,,1,Cable Clip,CLIP-2,,,,,,,"

    // MARK: Etsy

    func testEtsySingleRowTakesPriceTimesQuantityLessDiscountAndShipping() throws {
        let result = try usd(amounts([etsyHeader, etsyRow("2", "10.00", discount: "2.00", itemTotal: "20.00")]))
        XCTAssertEqual(result.source, .etsy)
        XCTAssertEqual(result.sourceOrderID, "T-1001")
        XCTAssertEqual(result.itemTotal, 18)
        XCTAssertEqual(result.shipping, Decimal(string: "4.5"))
        XCTAssertEqual(result.unitsSold, 2)
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testEtsyItemTotalAlreadyAfterDiscountGivesTheSameAmount() throws {
        let result = try usd(amounts([etsyHeader, etsyRow("2", "10.00", discount: "2.00", itemTotal: "18.00")]))
        XCTAssertEqual(result.itemTotal, 18)
    }

    func testEtsyItemTotalThatDoesNotAgreeIsLeftForTheSeller() throws {
        let result = try usd(amounts([etsyHeader, etsyRow("2", "10.00", itemTotal: "25.00")]))
        XCTAssertNil(result.itemTotal)
        XCTAssertEqual(result.shipping, Decimal(string: "4.5"))
        XCTAssertTrue(result.notes.contains { $0.hasPrefix("Enter the item total") })
    }

    func testEtsyRowsWithDifferentShippingAreAddedUp() throws {
        let result = try usd(amounts([etsyHeader, etsyRow("1", "10.00", shipping: "4.00"),
                                      etsyRow("3", "2.00", shipping: "1.00", sku: "CLIP")]))
        XCTAssertEqual(result.itemTotal, 16)
        XCTAssertEqual(result.shipping, 5)
        XCTAssertEqual(result.unitsSold, 4)
    }

    func testEtsySameShippingOnEveryRowIsNotGuessed() throws {
        let result = try usd(amounts([etsyHeader, etsyRow("1", "10.00", shipping: "4.50"),
                                      etsyRow("1", "2.00", shipping: "4.50", sku: "CLIP")]))
        XCTAssertEqual(result.itemTotal, 12)
        XCTAssertNil(result.shipping)
        XCTAssertTrue(result.notes.contains { $0.contains("same shipping on each item") })
    }

    func testEtsySameDiscountOnEveryRowIsNotGuessed() throws {
        let result = try usd(amounts([etsyHeader, etsyRow("1", "10.00", discount: "1.00", shipping: "4.00"),
                                      etsyRow("1", "2.00", discount: "1.00", shipping: "0.00", sku: "CLIP")]))
        XCTAssertNil(result.itemTotal)
        XCTAssertEqual(result.shipping, 4)
    }

    func testEtsyShippingDiscountLeavesShippingForTheSeller() throws {
        let result = try usd(amounts([etsyHeader, etsyRow("1", "10.00", shippingDiscount: "4.50")]))
        XCTAssertEqual(result.itemTotal, 10)
        XCTAssertNil(result.shipping)
        XCTAssertTrue(result.notes.contains { $0.contains("shipping discount") })
    }

    func testEtsyBadAmountsAreRejected() throws {
        let result = try usd(amounts([etsyHeader, etsyRow("1", "ten", shipping: "4.00")]))
        XCTAssertNil(result.itemTotal)
        XCTAssertEqual(result.shipping, 4)
        // Neither amount usable: nothing is kept.
        XCTAssertEqual(try amounts([etsyHeader, etsyRow("1", "-3.00", shipping: "abc")]), .none)
    }

    func testOtherCurrenciesAreNotKept() throws {
        XCTAssertEqual(try amounts([etsyHeader, etsyRow("1", "10.00", currency: "EUR")]), .otherCurrency("EUR"))
        // Lower case is still recognised as USD.
        XCTAssertNotNil(try? usd(amounts([etsyHeader, etsyRow("1", "10.00", currency: "usd")])))
    }

    func testMissingOrMixedCurrencyIsNeverAssumed() throws {
        XCTAssertEqual(try amounts([etsyHeader, etsyRow("1", "10.00", currency: "")]), .none)
        XCTAssertEqual(try amounts([etsyHeader, etsyRow("1", "10.00", currency: "USD"),
                                    etsyRow("1", "2.00", currency: "CAD", sku: "CLIP")]), .none)
    }

    func testFilesWithoutAmountColumnsHaveNone() throws {
        let etsy = ["Order ID,Ship Name,Ship Address1,Ship City,Ship State,Ship Zipcode,Ship Country,SKU,Quantity,Price",
                    "555,Ana,1 Main St,Austin,TX,78701,US,TIDY,1,10.00"]
        // A price but no currency: not kept.
        XCTAssertEqual(try amounts(etsy), .none)
        let template = [orderImportTemplateHeader.joined(separator: ","), "1001,Alex,alex@example.com,1 St,,Springfield,IL,62701,US,TIDY,1"]
        XCTAssertEqual(try amounts(template), .none)
        XCTAssertTrue(try parse(template).orders[0].saleRows.isEmpty)
    }

    func testEtsyOrderAmountRules() {
        XCTAssertEqual(importedEtsyOrderAmount(["4.50"]), .value(Decimal(string: "4.5")!))
        XCTAssertEqual(importedEtsyOrderAmount(["", ""]), .missing)
        XCTAssertEqual(importedEtsyOrderAmount(["0.00", "0"]), .value(0))
        XCTAssertEqual(importedEtsyOrderAmount(["4.50", "0.00"]), .value(Decimal(string: "4.5")!))
        XCTAssertEqual(importedEtsyOrderAmount(["4.50", "4.50"]), .ambiguous)
        XCTAssertEqual(importedEtsyOrderAmount(["4.50", "4.50", "0"]), .value(9))
        XCTAssertEqual(importedEtsyOrderAmount(["4.50", "1.50"]), .value(6))
        XCTAssertEqual(importedEtsyOrderAmount(["4.50", "x"]), .invalid)
    }

    // MARK: Shopify

    func testShopifyTakesSubtotalAndShippingFromTheFirstRow() throws {
        let result = try usd(amounts([shopifyHeader, shopifyFirst(), shopifyFollowOn]))
        XCTAssertEqual(result.source, .shopify)
        XCTAssertEqual(result.itemTotal, 30)
        XCTAssertEqual(result.shipping, 5)
        XCTAssertEqual(result.unitsSold, 3)
        XCTAssertTrue(result.notes.isEmpty)
    }

    func testShopifyTaxInclusiveTotalIsAccepted() throws {
        let result = try usd(amounts([shopifyHeader, shopifyFirst(taxes: "2.50", total: "35.00")]))
        XCTAssertEqual(result.itemTotal, 30)
        XCTAssertEqual(result.shipping, 5)
    }

    func testShopifyDiscountStillInSubtotalIsTakenOffWhenTheTotalSaysSo() throws {
        let result = try usd(amounts([shopifyHeader, shopifyFirst(subtotal: "30.00", total: "34.50", discount: "3.00")]))
        XCTAssertEqual(result.itemTotal, 27)
        XCTAssertEqual(result.shipping, 5)
    }

    func testShopifyTotalThatDoesNotAddUpLeavesShipping() throws {
        let result = try usd(amounts([shopifyHeader, shopifyFirst(total: "50.00")]))
        XCTAssertEqual(result.itemTotal, 30)
        XCTAssertNil(result.shipping)
        XCTAssertTrue(result.notes.contains { $0.contains("isn’t its subtotal, shipping and taxes") })
    }

    func testShopifyRefundIsNoted() throws {
        let result = try usd(amounts([shopifyHeader, shopifyFirst(refunded: "10.00")]))
        XCTAssertTrue(result.notes.contains { $0.contains("$10.00 refunded") })
    }

    func testShopifyConflictingSubtotalsAreNotGuessed() throws {
        let second = "#1001,ana@example.com,,,USD,40.00,,,,,1,Cable Clip,CLIP-2,,,,,,,"
        XCTAssertEqual(try amounts([shopifyHeader, shopifyFirst(shipping: "", total: ""), second]), .none)
    }

    func testShopifyOrderAmountRules() {
        XCTAssertEqual(importedShopifyOrderAmount(["30.00", "", ""]), .value(30))
        XCTAssertEqual(importedShopifyOrderAmount(["", ""]), .missing)
        XCTAssertEqual(importedShopifyOrderAmount(["30.00", "30"]), .value(30))
        XCTAssertEqual(importedShopifyOrderAmount(["30.00", "31.00"]), .invalid)
        XCTAssertEqual(importedShopifyOrderAmount(["$1,234.50"]), .value(Decimal(string: "1234.5")!))
        XCTAssertEqual(importedShopifyOrderAmount(["-5"]), .invalid)
    }

    func testUnitsNeedWholeQuantities() {
        func item(_ quantity: String) -> OrderImportItem { OrderImportItem(sku: "A", quantityText: quantity, itemName: "", row: 2) }
        XCTAssertEqual(importedSaleUnits([item("2"), item("3")]), 5)
        XCTAssertNil(importedSaleUnits([item("2"), item("1.5")]))
        XCTAssertNil(importedSaleUnits([]))
        XCTAssertNil(importedSaleUnits([item("10000"), item("1")]))
    }

    // MARK: Drafts and the sheet

    func testDraftBodiesNeverCarryWhatTheBuyerPaid() throws {
        var line = SavedProductLine()
        line.reference = "file-TIDY"
        line.filamentID = "filament-1"
        line.name = "Desk Tidy"
        let context = OrderImportContext(products: [SavedProduct(name: "Desk Tidy", sku: "TIDY", lines: [line])],
                                         platformID: "platform-1", fallbackEmail: "shop@example.com")
        let order = try parse([etsyHeader, etsyRow("2", "13.37", shipping: "4.21")]).orders[0]
        let check = orderImportCheck(order, context: context)
        let body = try XCTUnwrap(check.body)
        let json = String(data: try JSONSerialization.data(withJSONObject: body), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("13.37"))
        XCTAssertFalse(json.contains("26.74"))
        XCTAssertFalse(json.contains("4.21"))
    }

    func testSheetNoticeSaysWhatIsKeptAndWhatIsIgnored() throws {
        let orders = try parse([etsyHeader, etsyRow("1", "10.00"), etsyRow("1", "8.00", currency: "EUR", order: "T-2")]).orders
        let notice = try XCTUnwrap(orderImportSaleAmountsNotice(orders))
        XCTAssertTrue(notice.contains("kept in memory until you quit"))
        XCTAssertTrue(notice.contains("Amounts in EUR aren’t used"))
        XCTAssertEqual(importedSaleAmountsByOrder(orders).count, 1)
        XCTAssertNil(orderImportSaleAmountsNotice(try parse([orderImportTemplateHeader.joined(separator: ","),
                                                             "1001,Alex,a@example.com,1 St,,Springfield,IL,62701,US,TIDY,1"]).orders))
    }

    func testLookupMatchesAnyOfTheOrdersIDs() {
        let amounts = ImportedSaleAmounts(source: .etsy, sourceOrderID: "T-1", itemTotal: 10)
        XCTAssertEqual(importedSaleAmountsLookup(["ord_1": amounts], order: ["publicId": "ord_1"]), amounts)
        XCTAssertEqual(importedSaleAmountsLookup(["ord_1": amounts], order: ["id": "ord_1"]), amounts)
        XCTAssertNil(importedSaleAmountsLookup(["ord_1": amounts], order: ["publicId": "ord_2"]))
        XCTAssertNil(importedSaleAmountsLookup([:], order: ["publicId": "ord_1"]))
    }

    // MARK: Profit check prefill

    func testFieldTextUsesTwoDecimalsAndTheMacsDecimalMark() {
        XCTAssertEqual(importedSaleFieldText(Decimal(string: "12.5")!, decimalSeparator: "."), "12.50")
        XCTAssertEqual(importedSaleFieldText(1234, decimalSeparator: ","), "1234,00")
        XCTAssertEqual(importedSaleFieldText(0, decimalSeparator: "."), "0.00")
        // Round trip through the panel's parser in both locales.
        XCTAssertEqual(parseProfitAmount(importedSaleFieldText(1234, decimalSeparator: ","), decimalSeparator: ","), 1234)
        XCTAssertEqual(parseProfitAmount(importedSaleFieldText(Decimal(string: "1.5")!, decimalSeparator: "."), decimalSeparator: "."), Decimal(string: "1.5"))
    }

    func testPrefillOnlyFillsEmptyFields() {
        let amounts = ImportedSaleAmounts(source: .etsy, sourceOrderID: "T-1", itemTotal: 18, shipping: Decimal(string: "4.5"), unitsSold: 2)
        XCTAssertEqual(importedSalePrefill(amounts, itemText: "", shippingText: " ", unitsText: "1", decimalSeparator: "."),
                       ImportedSalePrefill(itemText: "18.00", shippingText: "4.50", unitsText: "2"))
        XCTAssertEqual(importedSalePrefill(amounts, itemText: "20", shippingText: "3", unitsText: "5", decimalSeparator: "."),
                       ImportedSalePrefill())
        let partial = ImportedSaleAmounts(source: .shopify, sourceOrderID: "#1", itemTotal: 30)
        XCTAssertEqual(importedSalePrefill(partial, itemText: "", shippingText: "", unitsText: "1", decimalSeparator: "."),
                       ImportedSalePrefill(itemText: "30.00"))
    }

    func testCaptionNamesTheMarketplaceOrderAndNotes() {
        var amounts = ImportedSaleAmounts(source: .etsy, sourceOrderID: "T-1001", itemTotal: 18)
        XCTAssertEqual(importedSaleCaption(amounts), "From the imported Etsy order T-1001 (this session only). Edit them if they differ.")
        amounts.notes = ["Enter the shipping charged: why."]
        XCTAssertTrue(importedSaleCaption(amounts).hasSuffix(" Enter the shipping charged: why."))
        XCTAssertTrue(importedSaleCaption(ImportedSaleAmounts(source: .shopify, sourceOrderID: "#1001")).hasPrefix("From the imported Shopify order #1001"))
    }

    // MARK: Pay review

    private func draft(total: String = "12.00", status: String = "DRAFT", currency: String? = nil) -> [String: Any] {
        var order: [String: Any] = ["publicId": "ord_1", "status": status, "total": total]
        if let currency { order["currency"] = currency }
        return order
    }

    func testReviewEstimateWithoutFees() throws {
        let amounts = ImportedSaleAmounts(source: .etsy, sourceOrderID: "T-1", itemTotal: 30, shipping: 5, unitsSold: 1)
        let estimate = try XCTUnwrap(importedSaleReviewEstimate(amounts, order: draft(), preset: .none, rates: ProfitFeeRates()))
        XCTAssertEqual(estimate, ImportedSaleReviewEstimate(text: "Estimated profit: $23.00 (65.7%) before marketplace fees", isLoss: false))
    }

    func testReviewEstimateUsesSavedRatesAndUnits() throws {
        let amounts = ImportedSaleAmounts(source: .etsy, sourceOrderID: "T-1", itemTotal: 20, shipping: 0, unitsSold: 2)
        let estimate = try XCTUnwrap(importedSaleReviewEstimate(amounts, order: draft(total: "10.00"), preset: .etsyUS,
                                                                rates: ProfitFeePreset.etsyUS.defaultRates))
        // 20 − 1.30 transaction − (0.60 + 0.25) processing − 0.40 listing − 10 Slant = 7.45.
        XCTAssertEqual(estimate.text, "Estimated profit: $7.45 (37.3%) at your saved fee rates")
        XCTAssertFalse(estimate.isLoss)
    }

    func testReviewEstimateWarnsAboutALoss() throws {
        let amounts = ImportedSaleAmounts(source: .etsy, sourceOrderID: "T-1", itemTotal: 8, shipping: 0, unitsSold: 1)
        let estimate = try XCTUnwrap(importedSaleReviewEstimate(amounts, order: draft(total: "12.00"), preset: .none, rates: ProfitFeeRates()))
        XCTAssertEqual(estimate, ImportedSaleReviewEstimate(text: "This order would lose about $4.00 (−50%) before marketplace fees", isLoss: true))
    }

    func testReviewEstimateNeedsADraftAUsableTotalAndBothAmounts() {
        let full = ImportedSaleAmounts(source: .etsy, sourceOrderID: "T-1", itemTotal: 20, shipping: 5, unitsSold: 1)
        XCTAssertNil(importedSaleReviewEstimate(nil, order: draft(), preset: .none, rates: ProfitFeeRates()))
        XCTAssertNil(importedSaleReviewEstimate(full, order: draft(status: "QUEUED"), preset: .none, rates: ProfitFeeRates()))
        XCTAssertNil(importedSaleReviewEstimate(full, order: draft(currency: "EUR"), preset: .none, rates: ProfitFeeRates()))
        XCTAssertNil(importedSaleReviewEstimate(full, order: ["status": "DRAFT"], preset: .none, rates: ProfitFeeRates()))
        var noShipping = full
        noShipping.shipping = nil
        XCTAssertNil(importedSaleReviewEstimate(noShipping, order: draft(), preset: .none, rates: ProfitFeeRates()))
        // A per-unit listing fee needs the units; Shopify's fees don't.
        var noUnits = full
        noUnits.unitsSold = nil
        XCTAssertNil(importedSaleReviewEstimate(noUnits, order: draft(), preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates))
        XCTAssertNotNil(importedSaleReviewEstimate(noUnits, order: draft(), preset: .shopifyBasicUS, rates: ProfitFeePreset.shopifyBasicUS.defaultRates))
    }

    func testReviewItemListMakesRoomForExtraReceiptLines() {
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 4, extraReceiptLines: 0).scrolls, false)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 5, extraReceiptLines: 0).scrolls, true)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 5, extraReceiptLines: 0).height, 128)
        // Each extra line gives up one item's worth of space, so the sheet's total height is unchanged.
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 4, extraReceiptLines: 1).scrolls, true)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 3, extraReceiptLines: 1).scrolls, false)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 3, extraReceiptLines: 2).scrolls, true)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 2, extraReceiptLines: 2).scrolls, false)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 9, extraReceiptLines: 2).height, 86)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 9, extraReceiptLines: 7).height, 86)
        XCTAssertEqual(orderReviewItemListLayout(itemCount: 9, extraReceiptLines: -1).height, 128)
    }
}
