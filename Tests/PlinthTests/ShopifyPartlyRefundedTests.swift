import XCTest
@testable import Plinth

/// Round 24 (owner decision, delegated, 13 Nov 2026): Fetch from Shopify also reads partly refunded orders, which start
/// unticked on both paths, unpaid fetched orders are left out, and no order showing a refund keeps imported sale
/// amounts. No request reaches a shop.
final class ShopifyPartlyRefundedTests: XCTestCase {
    private let shop = "p.myshopify.com"

    private func product(_ name: String, sku: String) -> SavedProduct {
        var line = SavedProductLine()
        line.reference = "file-\(sku)"
        line.filamentID = "filament-1"
        line.name = name
        return SavedProduct(name: name, sku: sku, lines: [line])
    }

    private var context: OrderImportContext {
        OrderImportContext(products: [product("Vase", sku: "VASE"), product("Mug", sku: "MUG")], platformID: "p1")
    }

    private func money(_ amount: String) -> [String: Any] {
        ["shopMoney": ["amount": amount, "currencyCode": "USD"]]
    }

    private func line(_ id: Int, sku: String, quantity: Int, current: Int, unfulfilled: Int) -> [String: Any] {
        ["id": "gid://shopify/LineItem/\(id)", "name": sku.capitalized, "sku": sku, "quantity": quantity,
         "currentQuantity": current, "unfulfilledQuantity": unfulfilled, "customAttributes": []]
    }

    /// A fetched order. `financial` nil leaves `displayFinancialStatus` out of the reply.
    private func node(name: String = "#1001", financial: String? = "PAID", fulfilment: String = "UNFULFILLED",
                      refunded: String = "0.00", lines: [[String: Any]]? = nil) -> [String: Any] {
        var node: [String: Any] = [
            "name": name, "email": "ana@example.com", "displayFulfillmentStatus": fulfilment,
            "shippingAddress": ["name": "Ana Lima", "address1": "1 Main St", "city": "Boston", "provinceCode": "MA",
                                "zip": "02134", "countryCodeV2": "US"],
            "subtotalPriceSet": money("30.00"), "totalShippingPriceSet": money("5.00"), "totalTaxSet": money("0.00"),
            "totalDiscountsSet": money("0.00"), "totalPriceSet": money("35.00"), "totalRefundedSet": money(refunded),
            "lineItems": ["pageInfo": ["hasNextPage": false], "nodes": lines ?? [
                line(111, sku: "VASE", quantity: 2, current: 2, unfulfilled: 2),
                line(222, sku: "MUG", quantity: 1, current: 1, unfulfilled: 1)
            ]]
        ]
        if let financial { node["displayFinancialStatus"] = financial }
        return node
    }

    private func reason(_ financial: String, fulfilment: String = "unfulfilled", fetched: Bool = false) -> String? {
        orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: fulfilment, cancelledAt: "",
                                        financialStatus: financial, fetched: fetched)
    }

    // MARK: The query

    func testTheQueryAsksForPaidOrPartlyRefundedOrdersOnly() {
        let now = ISO8601DateFormatter().date(from: "2026-11-13T12:00:00Z")!
        let query = shopifyImportSearchQuery(now: now)
        XCTAssertEqual(query, "(financial_status:paid OR financial_status:partially_refunded) fulfillment_status:unfulfilled status:open created_at:>=2026-09-14")
        for never in ["partially_paid", "pending", "authorized", "expired", "financial_status:refunded", "voided"] {
            XCTAssertFalse(query.contains(never), never)
        }
    }

    // MARK: The status key and the reasons

    func testStatusesAreComparedAsOneKey() {
        for spelling in ["PARTIALLY_REFUNDED", "partially_refunded", "Partially Refunded", "partially-refunded",
                         "  partially  refunded \n", "Partially__Refunded", "partially - refunded"] {
            XCTAssertEqual(orderImportStatusKey(spelling), "partially_refunded", spelling)
        }
        XCTAssertEqual(orderImportStatusKey("In Progress"), "in_progress")
        XCTAssertEqual(orderImportStatusKey("FULFILLMENT_NOT_REQUIRED"), "fulfillment_not_required")
        XCTAssertEqual(orderImportStatusKey("   "), "")
        XCTAssertEqual(orderImportStatusKey(""), "")
    }

    func testAPartlyRefundedOrderStartsUntickedWhereverItCameFrom() {
        for spelling in ["partially_refunded", "Partially Refunded", "partially-refunded", "PARTIALLY_REFUNDED"] {
            XCTAssertEqual(reason(spelling), orderImportPartlyRefundedCSVReason, spelling)
            XCTAssertEqual(reason(spelling, fulfilment: "UNFULFILLED", fetched: true), orderImportPartlyRefundedFetchedReason, spelling)
        }
        XCTAssertNil(reason("paid"), "the control: a paid, unfulfilled CSV row")
        XCTAssertNil(reason("PAID", fulfilment: "UNFULFILLED", fetched: true), "the control: a paid, unfulfilled fetch")
        // Refunded and voided keep their own reasons, whatever the spelling.
        XCTAssertEqual(reason(" Refunded "), "Shopify shows this order as refunded.")
        XCTAssertEqual(reason("VOIDED", fetched: true), "Shopify shows this order’s payment as voided.")
    }

    func testAPartialFulfilmentAndAPartialRefundAreBothSaid() {
        XCTAssertEqual(reason("partially_refunded", fulfilment: "partial"),
                       "Shopify shows part of this order as fulfilled, but the export lists every item, including any already sent. "
                       + orderImportPartlyRefundedCSVReason)
        XCTAssertEqual(reason("PARTIALLY_REFUNDED", fulfilment: "PARTIALLY_FULFILLED", fetched: true),
                       "Shopify shows part of this order as fulfilled. Only the items still to fulfil are listed. "
                       + orderImportPartlyRefundedFetchedReason)
        XCTAssertEqual(reason("partially_paid", fulfilment: "In Progress"),
                       "Shopify shows this order as in progress or with a fulfilment service. " + orderImportNotFullyPaidReason)
    }

    func testAFetchedOrderNotShownAsPaidStartsUnticked() {
        for status in ["", "  ", "UNKNOWN_STATUS", "PENDING", "AUTHORIZED"] {
            XCTAssertEqual(reason(status, fulfilment: "UNFULFILLED", fetched: true), orderImportNotShownPaidReason, status)
        }
        // A cancelled order keeps its own reason, with or without a financial status.
        XCTAssertEqual(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: "", cancelledAt: "2026-10-01",
                                                       financialStatus: "", fetched: true),
                       "Shopify shows this order as cancelled.")
    }

    func testACSVRowNotFullyPaidStartsUnticked() {
        for status in ["pending", "authorized", "partially_paid", "Partially Paid", "expired", "PENDING"] {
            XCTAssertEqual(reason(status), orderImportNotFullyPaidReason, status)
        }
        // A blank status (Shopify's follow-on item rows) and paid say nothing; nor do other formats.
        XCTAssertNil(reason(""))
        XCTAssertNil(reason("Paid"))
        XCTAssertNil(orderImportAlreadyHandledReason(format: .template, dateShipped: "", fulfillmentStatus: "",
                                                     cancelledAt: "", financialStatus: "pending"))
        XCTAssertNil(orderImportAlreadyHandledReason(format: .etsy, dateShipped: "", fulfillmentStatus: "",
                                                     cancelledAt: "", financialStatus: "partially_refunded"))
    }

    // MARK: Fetch from Shopify

    func testAPartlyRefundedFetchedOrderIsKeptUntickedWithOnlyUnitsStillDue() throws {
        let refundedNode = node(financial: "PARTIALLY_REFUNDED", refunded: "10.00", lines: [
            line(111, sku: "VASE", quantity: 3, current: 2, unfulfilled: 3),   // one unit refunded
            line(222, sku: "MUG", quantity: 2, current: 2, unfulfilled: 2)     // a money-only refund leaves it due
        ])
        let parse = try shopifyImportParse([refundedNode], shop: shop, truncated: false)
        let order = try XCTUnwrap(parse.orders.first)
        XCTAssertEqual(order.items.map(\.quantityText), ["2", "2"])
        XCTAssertEqual(order.alreadyHandled, orderImportPartlyRefundedFetchedReason)
        XCTAssertTrue(order.shopifyShowsRefund)
        let check = orderImportCheck(order, context: context)
        XCTAssertFalse(check.tickedByDefault)
        XCTAssertTrue(check.canTick, "the seller may still tick it")
        XCTAssertTrue(check.warnings.contains { $0.hasPrefix(orderImportPartlyRefundedFetchedReason) })
        XCTAssertTrue(parse.notices[0].contains("paid and partly refunded"))
        XCTAssertTrue(parse.notices[0].contains("Partly refunded orders start unticked"))
        // The draft records only the units it holds, so Send Tracking can't fulfil more.
        XCTAssertEqual(shopifyDraftSourceItems(order, itemProductIDs: nil).flatMap { shopifySourceItems(fromMetadata: $0) },
                       [ShopifySourceItem(key: .lineItem("111"), quantity: 2), ShopifySourceItem(key: .lineItem("222"), quantity: 2)])

        let paid = try shopifyImportParse([node()], shop: shop, truncated: false).orders[0]
        XCTAssertNil(paid.alreadyHandled)
        XCTAssertFalse(paid.shopifyShowsRefund)
        XCTAssertTrue(orderImportCheck(paid, context: context).tickedByDefault, "the control: a paid order is ticked")
    }

    func testAPartialFulfilmentAndAPartialRefundOnAFetchedOrder() throws {
        let both = node(financial: "PARTIALLY_REFUNDED", fulfilment: "PARTIALLY_FULFILLED", lines: [
            // Five ordered: two sent, one refunded, so two are still due.
            line(111, sku: "VASE", quantity: 5, current: 4, unfulfilled: 2),
            // Refunded after one was sent: nothing left.
            line(222, sku: "MUG", quantity: 2, current: 1, unfulfilled: 0)
        ])
        let order = try shopifyImportParse([both], shop: shop, truncated: false).orders[0]
        XCTAssertEqual(order.items.map(\.sku), ["VASE"])
        XCTAssertEqual(order.items.map(\.quantityText), ["2"])
        XCTAssertEqual(order.alreadyHandled,
                       "Shopify shows part of this order as fulfilled. Only the items still to fulfil are listed. "
                       + orderImportPartlyRefundedFetchedReason)
        XCTAssertFalse(orderImportCheck(order, context: context).tickedByDefault)
    }

    func testAnOrderWithEveryItemRefundedButShippingKeptIsLeftOut() throws {
        let nothingLeft = node(name: "#1002", financial: "PARTIALLY_REFUNDED", refunded: "30.00", lines: [
            line(111, sku: "VASE", quantity: 2, current: 0, unfulfilled: 2),
            line(222, sku: "MUG", quantity: 1, current: 0, unfulfilled: 0)
        ])
        let parse = try shopifyImportParse([node(), nothingLeft], shop: shop, truncated: false)
        XCTAssertEqual(parse.orders.map(\.sourceOrderID), ["#1001"])
        XCTAssertTrue(parse.notices.contains(shopifyImportNothingLeftNotice(["#1002"])!))
        // Alone, the fetch says why it found nothing to import.
        XCTAssertThrowsError(try shopifyImportParse([nothingLeft], shop: shop, truncated: false)) { error in
            let message = (error as? StudioError)?.message ?? ""
            XCTAssertTrue(message.contains("#1002") && message.contains("nothing left to make"), message)
        }
        // A later copy of an order already listed (the list shifting between pages) adds no notice.
        let shifted = try shopifyImportParse([node(name: "#1002"), nothingLeft], shop: shop, truncated: false)
        XCTAssertEqual(shifted.orders.map(\.items.count), [2])
        XCTAssertFalse(shifted.notices.contains(shopifyImportNothingLeftNotice(["#1002"])!))
        // An order Shopify sent without any lines isn't blamed on a refund: it stays, and its check says it has no items.
        let bare = try shopifyImportParse([node(name: "#1003", lines: [])], shop: shop, truncated: false)
        XCTAssertEqual(bare.orders.map(\.sourceOrderID), ["#1003"])
        XCTAssertTrue(orderImportCheck(bare.orders[0], context: context).blockers.contains("This order has no items."))
    }

    func testUnpaidFetchedOrdersAreLeftOutWithANotice() throws {
        let unpaid = ["PENDING", "AUTHORIZED", "PARTIALLY_PAID", "EXPIRED", "partially paid"]
        let nodes = unpaid.enumerated().map { node(name: "#20\($0.offset)", financial: $0.element) }
        let parse = try shopifyImportParse(nodes + [node(name: "#3000")], shop: shop, truncated: false)
        XCTAssertEqual(parse.orders.map(\.sourceOrderID), ["#3000"])
        for index in unpaid.indices {
            XCTAssertTrue(parse.notices.contains("Order #20\(index) isn’t fully paid in Shopify, so it was left out."), unpaid[index])
        }
        XCTAssertThrowsError(try shopifyImportParse(nodes, shop: shop, truncated: false)) { error in
            let message = (error as? StudioError)?.message ?? ""
            XCTAssertTrue(message.contains("#200") && message.contains("#204") && message.contains("fully paid"), message)
        }
        var row = 1
        XCTAssertNil(shopifyImportOrder(node(financial: "PENDING"), nextRow: &row).order)
        XCTAssertEqual(row, 1, "a left-out order numbers no rows")
    }

    func testAFetchedOrderWithoutAFinancialStatusIsKeptUnticked() throws {
        for status: String? in [nil, "", "SOMETHING_NEW"] {
            let order = try shopifyImportParse([node(financial: status)], shop: shop, truncated: false).orders[0]
            XCTAssertEqual(order.alreadyHandled, orderImportNotShownPaidReason, status ?? "missing")
            XCTAssertFalse(order.shopifyShowsRefund)
            XCTAssertFalse(orderImportCheck(order, context: context).tickedByDefault, status ?? "missing")
        }
    }

    func testFetchedOrdersShowingARefundKeepNoSaleAmounts() throws {
        let paid = try shopifyImportParse([node()], shop: shop, truncated: false).orders[0]
        guard case .amounts(let amounts) = importedSaleAmounts(for: paid) else { return XCTFail("the control keeps its amounts") }
        XCTAssertEqual(amounts.itemTotal, 30)

        let partly = try shopifyImportParse([node(financial: "PARTIALLY_REFUNDED", refunded: "0.00")], shop: shop, truncated: false).orders[0]
        XCTAssertEqual(importedSaleAmounts(for: partly), .none, "the status alone withholds them")
        let paidWithRefund = try shopifyImportParse([node(refunded: "5.00")], shop: shop, truncated: false).orders[0]
        XCTAssertEqual(importedSaleAmounts(for: paidWithRefund), .none, "a refund total above zero withholds them")
        XCTAssertTrue(importedSaleAmountsByOrder([paid, partly, paidWithRefund]).keys.elementsEqual([paid.id]))
        let notice = try XCTUnwrap(orderImportSaleAmountsNotice([paid, partly]))
        XCTAssertTrue(notice.contains("kept in memory") && notice.contains(importedSaleRefundWithheldNote), notice)
        XCTAssertEqual(orderImportSaleAmountsNotice([partly]), importedSaleRefundWithheldNote)
        XCTAssertNil(orderImportSaleAmountsNotice([]))
    }

    func testCopyNoLongerSendsSellersToACSVExportForPartlyRefundedOrders() throws {
        XCTAssertEqual(shopifyImportIntroHint(shop: shop),
                       "Or use Fetch from Shopify to read paid and partly refunded, unfulfilled orders straight from \(shop).")
        let parse = try shopifyImportParse([node()], shop: shop, truncated: false)
        XCTAssertFalse(parse.notices[0].contains("CSV export"), parse.notices[0])
        XCTAssertThrowsError(try shopifyImportParse([], shop: shop, truncated: false)) { error in
            XCTAssertEqual((error as? StudioError)?.message,
                           "Shopify has no paid or partly refunded, unfulfilled orders from the last \(shopifyImportDays) days for \(shop).")
        }
    }

    // MARK: A Shopify CSV export

    private let header = "Name,Email,Financial Status,Fulfillment Status,Currency,Subtotal,Shipping,Taxes,Total,Discount Amount,Lineitem quantity,Lineitem name,Lineitem sku,Shipping Name,Shipping Address1,Shipping City,Shipping Zip,Shipping Province,Shipping Country,Refunded Amount"

    private func csvRow(_ name: String, financial: String, fulfilment: String = "unfulfilled", refunded: String = "",
                        sku: String = "VASE", quantity: String = "2") -> String {
        "\(name),ana@example.com,\(financial),\(fulfilment),USD,30.00,5.00,0.00,35.00,0.00,\(quantity),Vase,\(sku),Ana Lima,1 Main St,Boston,02134,MA,US,\(refunded)"
    }

    private func csv(_ rows: [String]) throws -> OrderImportParse {
        try orderImportParse(data: Data(([header] + rows).joined(separator: "\r\n").utf8))
    }

    func testAPartlyRefundedCSVRowStartsUntickedAndKeepsNoAmounts() throws {
        let followOn = "#1001,ana@example.com,,,,,,,,,1,Mug,MUG,,,,,,,"
        let parse = try csv([csvRow("#1001", financial: "partially_refunded", refunded: "10.00"), followOn,
                             csvRow("#1002", financial: "Partially Refunded"),
                             csvRow("#1003", financial: "paid"),
                             csvRow("#1004", financial: "paid", refunded: "4.00"),
                             csvRow("#1005", financial: "pending")])
        let orders = parse.orders
        XCTAssertEqual(orders.map(\.sourceOrderID), ["#1001", "#1002", "#1003", "#1004", "#1005"])
        // The follow-on row's blank status doesn't clear the first row's.
        XCTAssertEqual(orders[0].alreadyHandled, orderImportPartlyRefundedCSVReason)
        XCTAssertTrue(orders[0].shopifyShowsRefund)
        XCTAssertEqual(orders[0].items.map(\.quantityText), ["2", "1"], "the export's quantities are left as written")
        XCTAssertEqual(orders[1].alreadyHandled, orderImportPartlyRefundedCSVReason)
        XCTAssertTrue(orders[1].shopifyShowsRefund)
        XCTAssertNil(orders[2].alreadyHandled)
        XCTAssertNil(orders[3].alreadyHandled)
        XCTAssertEqual(orders[4].alreadyHandled, orderImportNotFullyPaidReason)

        XCTAssertFalse(orderImportCheck(orders[0], context: context).tickedByDefault)
        XCTAssertFalse(orderImportCheck(orders[4], context: context).tickedByDefault)
        XCTAssertTrue(orderImportCheck(orders[2], context: context).tickedByDefault)

        XCTAssertEqual(importedSaleAmounts(for: orders[0]), .none)
        XCTAssertEqual(importedSaleAmounts(for: orders[1]), .none, "a blank Refunded Amount doesn't bring them back")
        XCTAssertEqual(importedSaleAmounts(for: orders[3]), .none, "a refund on a paid row withholds them too")
        guard case .amounts(let kept) = importedSaleAmounts(for: orders[2]) else { return XCTFail("the control keeps its amounts") }
        XCTAssertEqual(kept.itemTotal, 30)
        XCTAssertEqual(kept.shipping, 5)
        XCTAssertTrue(kept.notes.isEmpty)
        XCTAssertEqual(Set(importedSaleAmountsByOrder(orders).keys), [orders[2].id, orders[4].id])
        let notice = try XCTUnwrap(orderImportSaleAmountsNotice(orders))
        XCTAssertTrue(notice.hasSuffix(importedSaleRefundWithheldNote), notice)
    }

    func testOtherOrdersAreNeverWithheldForARefund() throws {
        var etsy = OrderImportOrder(source: .etsy, sourceOrderID: "T-1")
        etsy.shopifyShowsRefund = true
        var row = OrderImportSaleRow()
        row.refunded = "5.00"
        etsy.saleRows = [row]
        XCTAssertFalse(importedSaleWithheldForRefund(etsy))
        var bare = OrderImportOrder(source: .shopify, sourceOrderID: "#1")
        bare.shopifyShowsRefund = true
        XCTAssertFalse(importedSaleWithheldForRefund(bare), "no sale rows, nothing to withhold")
    }
}
