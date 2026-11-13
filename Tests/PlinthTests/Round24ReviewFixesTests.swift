import XCTest
@testable import Plinth

/// Round 24's post-merge review fixes: Pay Several Drafts' duplicate check for drafts sharing a Shopify line item, the
/// Profit check for fetched orders listing fewer units than were sold, fulfilment statuses that start unticked,
/// unreadable line counts, duplicate fetched names, reasons across CSV rows and the import copy. No request reaches a
/// shop or Slant. (The 3DAPI fixes are in the `DapiOrdersTests` extension below.)
final class Round24ReviewFixesTests: XCTestCase {
    private let shop = "p.myshopify.com"

    // MARK: 1. Pay Several Drafts: drafts sharing a line item are one sale

    private func order(_ status: String = "DRAFT", id: String = "#1001", shop: String? = "a.myshopify.com",
                       items: String?) -> [String: Any] {
        var metadata: [String: Any] = ["source": "shopify", "sourceOrderId": id]
        if let shop { metadata["sourceShop"] = shop }
        if let items { metadata["sourceItems"] = items }
        return ["status": status, "metadata": metadata]
    }

    private func record(_ id: String, _ order: [String: Any]) -> Record {
        var values = order
        values["publicId"] = id
        return Record(values: values)
    }

    private func lineItems(_ entries: [(String, Int)]) -> String {
        "[" + entries.map { "{\"lineItem\":\"\($0.0)\",\"quantity\":\($0.1)}" }.joined(separator: ",") + "]"
    }

    private func skus(_ entries: [(String, Int)]) -> String {
        "[" + entries.map { "{\"quantity\":\($0.1),\"sku\":\"\($0.0)\"}" }.joined(separator: ",") + "]"
    }

    private func match(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        batchPayMarketplaceKeysMatch(batchPayMarketplaceKey(a)!, batchPayMarketplaceKey(b)!)
    }

    func testDraftsSharingALineItemAreOneSaleWhateverTheirUnits() {
        // Fetched while paid (3 units), then again after a partial refund (2 units).
        let before = order(items: lineItems([("111", 3)]))
        let after = order(items: lineItems([("111", 2)]))
        XCTAssertTrue(match(before, after))
        XCTAssertTrue(match(after, before))
        // One shared line item among others.
        XCTAssertTrue(match(order(items: lineItems([("111", 1), ("222", 1)])), order(items: lineItems([("222", 4), ("333", 1)]))))
        // Through the batch: only the first is included, either way round.
        let reasons = batchPayDuplicateExclusions([(id: "A", order: before), (id: "B", order: after)], placedKeys: [])
        XCTAssertEqual(Set(reasons.keys), ["B"])
        XCTAssertTrue(reasons["B"]?.contains("Only the first is included") == true, "\(reasons)")
        XCTAssertEqual(Set(batchPayDuplicateExclusions([(id: "B", order: after), (id: "A", order: before)], placedKeys: []).keys), ["A"])
        // A placed order for the first holds the sale against the second, in the batch and in the pay review.
        let placed = batchPayPlacedMarketplaceKeys([record("P", order("SUBMITTED", items: lineItems([("111", 3)])))])
        XCTAssertTrue(batchPayDuplicateExclusions([(id: "B", order: after)], placedKeys: placed)["B"]?.contains("already placed") == true)
        XCTAssertEqual(orderReviewMarketplaceDuplicateNotice(after, orderID: "B",
                                                             loaded: [record("P", order("SUBMITTED", items: lineItems([("111", 3)])))]),
                       "Possible duplicate: Shopify order #1001 already has a placed order.")
        // A left-out or hidden draft holds it too.
        XCTAssertTrue(batchPayDuplicateExclusions([(id: "A", order: before), (id: "B", order: after)], placedKeys: [],
                                                  excludedIDs: ["A"])["B"]?.contains("was left out") == true)
    }

    func testDraftsSharingASKUAreOneSale() {
        XCTAssertTrue(match(order(shop: nil, items: skus([("MUG-1", 2)])), order(shop: nil, items: skus([("MUG-1", 1)]))))
        XCTAssertTrue(match(order(shop: nil, items: skus([("MUG-1", 1)])), order(shop: nil, items: skus([(" mug-1 ", 1)]))),
                      "SKUs compare as Saved Products do: trimmed, any case")
        XCTAssertTrue(match(order(shop: nil, items: skus([("MUG-1", 1), ("MUG-2", 1)])), order(shop: nil, items: skus([("MUG-2", 3)]))))
        XCTAssertTrue(match(order(shop: nil, items: "[{\"name\":\"Mug\",\"quantity\":1}]"),
                            order(shop: nil, items: "[{\"name\":\"mug\",\"quantity\":2}]")), "the same name")
    }

    func testOnlyDraftsWithNothingInCommonStayASplit() {
        XCTAssertFalse(match(order(items: lineItems([("111", 1)])), order(items: lineItems([("222", 1)]))))
        XCTAssertFalse(match(order(items: lineItems([("111", 1), ("333", 2)])), order(items: lineItems([("222", 1), ("444", 1)]))))
        XCTAssertFalse(match(order(shop: nil, items: skus([("MUG-1", 1)])), order(shop: nil, items: skus([("MUG-2", 1)]))))
        XCTAssertFalse(match(order(shop: nil, items: skus([("Mug", 1)])), order(shop: nil, items: "[{\"name\":\"Mug\",\"quantity\":1}]")),
                       "a SKU and a name are never the same entry")
        XCTAssertEqual(batchPayDuplicateExclusions([(id: "A", order: order(items: lineItems([("111", 1)]))),
                                                    (id: "B", order: order(items: lineItems([("222", 1)])))], placedKeys: []), [:])
        // A shared line item never joins two stores' orders, or two order numbers.
        XCTAssertFalse(match(order(shop: "a.myshopify.com", items: lineItems([("111", 1)])),
                             order(shop: "b.myshopify.com", items: lineItems([("111", 1)]))))
        XCTAssertFalse(match(order(id: "#1001", items: lineItems([("111", 1)])), order(id: "#1002", items: lineItems([("111", 1)]))))
        // Round 22's widening is unchanged: items recorded differently, mixed or unreadable are one sale.
        XCTAssertTrue(match(order(shop: nil, items: skus([("MUG-1", 1)])), order(items: lineItems([("111", 1)]))))
        XCTAssertTrue(match(order(items: "[{\"lineItem\":\"1\",\"quantity\":1},{\"quantity\":1,\"sku\":\"X\"}]"),
                            order(items: lineItems([("2", 1)]))))
        XCTAssertTrue(match(order(items: "not json"), order(items: lineItems([("2", 1)]))))
    }

    // MARK: Fetched orders

    private func money(_ amount: String) -> [String: Any] {
        ["shopMoney": ["amount": amount, "currencyCode": "USD"]]
    }

    private func line(_ id: Int, sku: String = "VASE", quantity: Any? = 3, current: Any? = 3, unfulfilled: Any? = 3) -> [String: Any] {
        var line: [String: Any] = ["id": "gid://shopify/LineItem/\(id)", "name": sku.capitalized, "sku": sku, "customAttributes": []]
        if let quantity { line["quantity"] = quantity }
        if let current { line["currentQuantity"] = current }
        if let unfulfilled { line["unfulfilledQuantity"] = unfulfilled }
        return line
    }

    private func node(name: String = "#1001", financial: String = "PAID", fulfilment: String = "UNFULFILLED",
                      shipping: String? = "5.00", lines: [[String: Any]]? = nil) -> [String: Any] {
        var node: [String: Any] = [
            "name": name, "email": "ana@example.com", "displayFinancialStatus": financial, "displayFulfillmentStatus": fulfilment,
            "shippingAddress": ["name": "Ana Lima", "address1": "1 Main St", "city": "Boston", "provinceCode": "MA",
                                "zip": "02134", "countryCodeV2": "US"],
            "subtotalPriceSet": money("60.00"), "totalTaxSet": money("0.00"), "totalDiscountsSet": money("0.00"),
            "totalRefundedSet": money("0.00"),
            "lineItems": ["pageInfo": ["hasNextPage": false], "nodes": lines ?? [line(111)]]
        ]
        if let shipping {
            node["totalShippingPriceSet"] = money(shipping)
            node["totalPriceSet"] = money(String(format: "%.2f", 60 + (Double(shipping) ?? 0)))
        }
        return node
    }

    private func fetched(_ node: [String: Any]) throws -> OrderImportOrder {
        try XCTUnwrap(shopifyImportParse([node], shop: shop, truncated: false).orders.first)
    }

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

    // MARK: 2. Fewer units listed than sold keep only shipping

    func testAPartlyFulfilledFetchedOrderKeepsOnlyShipping() throws {
        // $60 for 3 units, 1 still to make: the Profit check must not count $60 against 1 unit.
        let partial = try fetched(node(fulfilment: "PARTIALLY_FULFILLED", lines: [line(111, quantity: 3, current: 3, unfulfilled: 1)]))
        XCTAssertEqual(partial.items.map(\.quantityText), ["1"])
        XCTAssertTrue(partial.saleCoversItemsNotListed)
        guard case .amounts(let kept) = importedSaleAmounts(for: partial) else { return XCTFail("shipping is kept") }
        XCTAssertNil(kept.itemTotal)
        XCTAssertNil(kept.unitsSold)
        XCTAssertEqual(kept.shipping, 5)
        XCTAssertEqual(kept.notes.first, importedSalePartlyListedNote)
        XCTAssertEqual(importedSaleAmountsByOrder([partial])[partial.id], kept)

        // The control: every unit still to make keeps the whole order's amounts.
        let whole = try fetched(node())
        XCTAssertFalse(whole.saleCoversItemsNotListed)
        guard case .amounts(let all) = importedSaleAmounts(for: whole) else { return XCTFail("the control keeps its amounts") }
        XCTAssertEqual(all.itemTotal, 60)
        XCTAssertEqual(all.unitsSold, 3)
    }

    func testAnyLineListingFewerUnitsThanOrderedKeepsOnlyShipping() throws {
        let cases: [(String, [[String: Any]])] = [
            ("a removed unit", [line(111, quantity: 3, current: 2, unfulfilled: 3)]),
            ("a line fulfilled in full, dropped", [line(111), line(222, sku: "MUG", quantity: 1, current: 1, unfulfilled: 0)]),
            ("no ordered count to compare with", [line(111, quantity: nil)]),
            ("an unreadable line", [line(111), line(222, sku: "MUG", quantity: "1", current: "1", unfulfilled: "1")])
        ]
        for (label, lines) in cases {
            // Shopify's display status still says unfulfilled: the lines decide.
            let order = try fetched(node(lines: lines))
            XCTAssertTrue(order.saleCoversItemsNotListed, label)
            guard case .amounts(let kept) = importedSaleAmounts(for: order) else { XCTFail(label); continue }
            XCTAssertNil(kept.itemTotal, label)
            XCTAssertEqual(kept.shipping, 5, label)
        }
        // Nothing to keep without shipping.
        let noShipping = try fetched(node(fulfilment: "PARTIALLY_FULFILLED", shipping: nil,
                                          lines: [line(111, quantity: 3, current: 3, unfulfilled: 1)]))
        XCTAssertEqual(importedSaleAmounts(for: noShipping), .none)
    }

    func testAPartlyFulfilledCSVOrderKeepsOnlyShipping() throws {
        let header = "Name,Email,Financial Status,Fulfillment Status,Currency,Subtotal,Shipping,Taxes,Total,Discount Amount,Lineitem quantity,Lineitem name,Lineitem sku,Shipping Name,Shipping Address1,Shipping City,Shipping Zip,Shipping Province,Shipping Country,Refunded Amount"
        let rows = [
            "#1001,ana@example.com,paid,partial,USD,30.00,5.00,0.00,35.00,0.00,2,Vase,VASE,Ana Lima,1 Main St,Boston,02134,MA,US,",
            "#1002,bo@example.com,paid,unfulfilled,USD,30.00,5.00,0.00,35.00,0.00,2,Vase,VASE,Bo Chen,2 High St,Boston,02134,MA,US,",
            // A file combined from two exports: the second row of #1003 says partly fulfilled.
            "#1003,cy@example.com,paid,unfulfilled,USD,30.00,5.00,0.00,35.00,0.00,2,Vase,VASE,Cy Diaz,3 Low St,Boston,02134,MA,US,",
            "#1003,cy@example.com,,partial,,,,,,,1,Mug,MUG,,,,,,,"
        ]
        let orders = try orderImportParse(data: Data(([header] + rows).joined(separator: "\r\n").utf8)).orders
        XCTAssertEqual(orders.map(\.saleCoversItemsNotListed), [true, false, true])
        guard case .amounts(let partial) = importedSaleAmounts(for: orders[0]) else { return XCTFail("shipping is kept") }
        XCTAssertNil(partial.itemTotal)
        XCTAssertEqual(partial.shipping, 5)
        guard case .amounts(let whole) = importedSaleAmounts(for: orders[1]) else { return XCTFail("the control") }
        XCTAssertEqual(whole.itemTotal, 30)
        // Match products leaving items out too: one note, not two.
        let byOrder = importedSaleAmountsByOrder([orders[0]], leavingOutItemsIn: [orders[0].id])
        XCTAssertEqual(byOrder[orders[0].id]?.notes.filter { $0 == importedSaleLeftOutNote || $0 == importedSalePartlyListedNote },
                       [importedSaleLeftOutNote])
        // Other sources never use the flag.
        var etsy = OrderImportOrder(source: .etsy, sourceOrderID: "T-1")
        etsy.saleCoversItemsNotListed = true
        XCTAssertEqual(importedSaleAmounts(for: etsy), .none, "no sale rows: nothing either way")
    }

    // MARK: 3. Fulfilment statuses that need a second look

    func testHeldScheduledDeclinedAndRestockedOrdersStartUnticked() throws {
        let expected = [
            "ON_HOLD": "Shopify shows this order as on hold.",
            "SCHEDULED": "Shopify shows this order as scheduled for later.",
            "REQUEST_DECLINED": "Shopify shows a declined fulfilment request on this order.",
            "RESTOCKED": "Shopify shows this order’s items as restocked."
        ]
        for (status, reason) in expected {
            let order = try fetched(node(fulfilment: status))
            XCTAssertEqual(order.alreadyHandled, reason, status)
            let check = orderImportCheck(order, context: context)
            XCTAssertFalse(check.tickedByDefault, status)
            XCTAssertTrue(check.canTick, "the seller may still tick it: \(status)")
            XCTAssertTrue(check.warnings.contains { $0.hasPrefix(reason) }, status)
            // Any spelling, and in a CSV too.
            XCTAssertEqual(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: status.lowercased()
                                                            .replacingOccurrences(of: "_", with: " "),
                                                           cancelledAt: "", financialStatus: "paid"), reason, status)
        }
        XCTAssertTrue(orderImportCheck(try fetched(node()), context: context).tickedByDefault, "the control")
    }

    // MARK: 4. Unreadable line counts

    func testCountsThatArentWholeNumbersFromZeroAreUnreadable() {
        let unreadable: [Any] = [-1, 1.5, "2", true, ["n": 1]]
        for bad in unreadable {
            XCTAssertNil(shopifyImportLineUnits(["quantity": 3, "currentQuantity": bad, "unfulfilledQuantity": 3]), "\(bad)")
            XCTAssertNil(shopifyImportLineUnits(["quantity": bad, "currentQuantity": 3, "unfulfilledQuantity": 3]), "\(bad)")
        }
        XCTAssertEqual(shopifyImportLineUnits(["quantity": 3, "currentQuantity": NSNull(), "unfulfilledQuantity": 2]), 2,
                       "null is missing, as before")
        XCTAssertEqual(shopifyImportLineUnits(["quantity": 3, "currentQuantity": 3.0, "unfulfilledQuantity": 1]), 1)
        XCTAssertEqual(shopifyImportLineCount(["q": 0], "q"), .value(0))
        XCTAssertEqual(shopifyImportLineCount([:], "q"), .missing)
    }

    func testAnOrderWhoseCountsCantBeReadIsKeptAndCantBeTicked() throws {
        let unreadable = node(name: "#1002", lines: [line(111, quantity: nil, current: nil, unfulfilled: nil),
                                                      line(222, sku: "MUG", quantity: "x", current: 1, unfulfilled: 1)])
        let parse = try shopifyImportParse([unreadable], shop: shop, truncated: false)
        XCTAssertEqual(parse.orders.map(\.sourceOrderID), ["#1002"])
        XCTAssertFalse(parse.notices.contains { $0.contains("nothing left to make") }, "\(parse.notices)")
        let order = parse.orders[0]
        XCTAssertEqual(order.unreadableItemCount, 2)
        XCTAssertTrue(order.items.isEmpty)
        let check = orderImportCheck(order, context: context)
        XCTAssertEqual(check.blockers, [orderImportUnreadableItemsBlocker])
        XCTAssertFalse(check.canTick)
        // Readable zeros with one unreadable line: still not "nothing left".
        let mixed = try shopifyImportParse([node(lines: [line(111, current: 0, unfulfilled: 0), line(222, sku: "MUG", current: -1)])],
                                           shop: shop, truncated: false)
        XCTAssertEqual(mixed.orders.count, 1)
        XCTAssertFalse(orderImportCheck(mixed.orders[0], context: context).canTick)
    }

    func testAnUnreadableLineBesideReadableOnesStartsUnticked() throws {
        let order = try fetched(node(lines: [line(111), line(222, sku: "MUG", quantity: 1, current: 1.5, unfulfilled: 1)]))
        XCTAssertEqual(order.items.map(\.sku), ["VASE"])
        XCTAssertEqual(order.unreadableItemCount, 1)
        let check = orderImportCheck(order, context: context)
        XCTAssertTrue(check.canTick)
        XCTAssertFalse(check.tickedByDefault, "never drafted without a line the seller wasn't told about")
        XCTAssertTrue(check.warnings.contains(orderImportUnreadableItemsWarning(1)))
        XCTAssertTrue(orderImportUnreadableItemsWarning(1).contains("1 item"))
        XCTAssertTrue(orderImportUnreadableItemsWarning(2).contains("2 items") && orderImportUnreadableItemsWarning(2).contains("them"))
    }

    func testOnlyOrdersWhoseReadableLinesAllComeToNothingAreLeftOut() throws {
        let nothing = node(name: "#1002", lines: [line(111, current: 0, unfulfilled: 3), line(222, sku: "MUG", quantity: 1, current: 1, unfulfilled: 0)])
        let parse = try shopifyImportParse([node(), nothing], shop: shop, truncated: false)
        XCTAssertEqual(parse.orders.map(\.sourceOrderID), ["#1001"])
        XCTAssertTrue(parse.notices.contains(shopifyImportNothingLeftNotice(["#1002"])!))
    }

    // MARK: 5. One name fetched twice

    func testAFetchedNameSeenTwiceIsDecidedOnceByItsFirstCopy() throws {
        // Kept, then a copy that would be left out: no contradicting notice.
        let kept = try shopifyImportParse([node(), node(financial: "PENDING")], shop: shop, truncated: false)
        XCTAssertEqual(kept.orders.map(\.sourceOrderID), ["#1001"])
        XCTAssertFalse(kept.notices.contains { $0.contains("isn’t fully paid") }, "\(kept.notices)")
        // Left out twice: one notice.
        let twice = try shopifyImportParse([node(financial: "PENDING"), node(financial: "PENDING"), node(name: "#2")],
                                           shop: shop, truncated: false)
        XCTAssertEqual(twice.notices.filter { $0.contains("#1001") }.count, 1)
        // Left out first, then a paid copy: still left out, never listed beside its notice.
        let leftFirst = try shopifyImportParse([node(financial: "PENDING"), node(), node(name: "#2")], shop: shop, truncated: false)
        XCTAssertEqual(leftFirst.orders.map(\.sourceOrderID), ["#2"])
        // Nothing left, then a listed copy: left out once.
        let empty = node(lines: [line(111, current: 0)])
        let shifted = try shopifyImportParse([empty, node(), node(name: "#2")], shop: shop, truncated: false)
        XCTAssertEqual(shifted.orders.map(\.sourceOrderID), ["#2"])
    }

    func testNoTwoRowsOrNoticesShareAnID() throws {
        let nodes = [node(), node(), node(name: ""), node(name: "  "), node(name: "#3", financial: "PENDING"),
                     node(name: "#3", financial: "PENDING"), node(name: "#4", lines: [line(1, current: 0)]),
                     node(name: "#5", lines: [line(1, current: 0)]), node(name: "#6")]
        let parse = try shopifyImportParse(nodes, shop: shop, truncated: true)
        XCTAssertEqual(parse.orders.count, Set(parse.orders.map(\.id)).count)
        XCTAssertEqual(parse.orders.map(\.sourceOrderID), ["#1001", "#6"])
        XCTAssertEqual(parse.notices.count, Set(parse.notices).count, "\(parse.notices)")
        XCTAssertTrue(parse.notices.contains("2 orders without a name were left out."))
        XCTAssertEqual(parse.notices.filter { $0.contains("nothing left to make") }.count, 1)
        XCTAssertEqual(shopifyImportNamelessNotice(1), "An order without a name was left out.")
        XCTAssertNil(shopifyImportNamelessNotice(0))
        XCTAssertEqual(orderImportUniqueNotices(["a", "b", "a", "c", "b"]), ["a", "b", "c"])
        // Every order left out: the error says each reason once.
        XCTAssertThrowsError(try shopifyImportParse([node(financial: "PENDING"), node(financial: "PENDING"), node(name: "")],
                                                    shop: shop, truncated: false)) { error in
            let message = (error as? StudioError)?.message ?? ""
            XCTAssertEqual(message, "Order #1001 isn’t fully paid in Shopify, so it was left out. An order without a name was left out.")
        }
    }

    // MARK: 6. Reasons across CSV rows, and statuses Plinth doesn't know

    private let csvHeader = "Name,Email,Financial Status,Fulfillment Status,Lineitem quantity,Lineitem name,Lineitem sku,Shipping Name,Shipping Address1,Shipping City,Shipping Zip,Shipping Province,Shipping Country"

    private func csv(_ rows: [String]) throws -> [OrderImportOrder] {
        try orderImportParse(data: Data(([csvHeader] + rows).joined(separator: "\r\n").utf8)).orders
    }

    private func csvRow(_ name: String, financial: String, fulfilment: String, sku: String = "VASE") -> String {
        "\(name),ana@example.com,\(financial),\(fulfilment),1,Vase,\(sku),Ana Lima,1 Main St,Boston,02134,MA,US"
    }

    func testEveryRowsReasonsAreGivenOnce() throws {
        let partial = "Shopify shows part of this order as fulfilled, but the export lists every item, including any already sent."
        let orders = try csv([
            csvRow("#1", financial: "paid", fulfilment: "partial"), csvRow("#1", financial: "refunded", fulfilment: "", sku: "MUG"),
            csvRow("#2", financial: "partially_refunded", fulfilment: "unfulfilled"),
            csvRow("#2", financial: "partially_refunded", fulfilment: "partial", sku: "MUG"),
            csvRow("#3", financial: "paid", fulfilment: "partial"), csvRow("#3", financial: "pending", fulfilment: "partial", sku: "MUG"),
            csvRow("#4", financial: "paid", fulfilment: "unfulfilled"), csvRow("#4", financial: "", fulfilment: "", sku: "MUG")
        ])
        XCTAssertEqual(orders[0].alreadyHandled, partial + " Shopify shows this order as refunded.")
        XCTAssertEqual(orders[1].alreadyHandled, orderImportPartlyRefundedCSVReason + " " + partial, "each once, in row order")
        XCTAssertEqual(orders[2].alreadyHandled, partial + " " + orderImportNotFullyPaidReason)
        XCTAssertNil(orders[3].alreadyHandled, "the control: blank follow-on rows say nothing")
        XCTAssertEqual(orderImportAlreadyHandledReasons(format: .shopify, dateShipped: "", fulfillmentStatus: "partial",
                                                        cancelledAt: "", financialStatus: "partially_refunded"),
                       [partial, orderImportPartlyRefundedCSVReason])
    }

    func testACSVStatusPlinthDoesntKnowStartsUnticked() throws {
        for status in ["unpaid", "Something New", "PAYMENT_DUE"] {
            XCTAssertEqual(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: "unfulfilled",
                                                           cancelledAt: "", financialStatus: status),
                           orderImportNotShownPaidReason, status)
        }
        XCTAssertEqual(orderImportNotShownPaidReason, "Shopify doesn’t show this order as paid.")
        let orders = try csv([csvRow("#1", financial: "unpaid", fulfilment: "unfulfilled"), csvRow("#2", financial: "paid", fulfilment: "unfulfilled")])
        XCTAssertFalse(orderImportCheck(orders[0], context: context).tickedByDefault)
        XCTAssertTrue(orderImportCheck(orders[1], context: context).tickedByDefault, "the control")
        // Only Shopify: a blank status, Etsy and the template say nothing.
        XCTAssertNil(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: "", cancelledAt: "", financialStatus: " "))
        XCTAssertNil(orderImportAlreadyHandledReason(format: .etsy, dateShipped: "", fulfillmentStatus: "", cancelledAt: "", financialStatus: "unpaid"))
        XCTAssertNil(orderImportAlreadyHandledReason(format: .template, dateShipped: "", fulfillmentStatus: "", cancelledAt: "", financialStatus: "unpaid"))
    }

    // MARK: 10. Import copy

    func testTheRefundSentenceReadsOnItsOwn() {
        XCTAssertEqual(importedSaleRefundWithheldNote,
                       "The Profit check isn’t filled in for orders Shopify shows a refund on, because Shopify’s refund total doesn’t say what it covered.")
    }

    func testTheFetchNoticeMentionsPartlyRefundedOrdersOnlyWhenOneWasFetched() throws {
        let plain = try shopifyImportParse([node()], shop: shop, truncated: false)
        XCTAssertEqual(plain.notices[0],
                       "Fetched from \(shop): paid and partly refunded, unfulfilled orders from the last \(shopifyImportDays) days, oldest first.")
        let refunded = try shopifyImportParse([node(), node(name: "#2", financial: "PARTIALLY_REFUNDED")], shop: shop, truncated: false)
        XCTAssertTrue(refunded.notices[0].hasSuffix("Partly refunded orders start unticked: check which items still need making."))
        // A partly refunded order left out with nothing to make doesn't count.
        let gone = try shopifyImportParse([node(), node(name: "#2", financial: "PARTIALLY_REFUNDED", lines: [line(1, current: 0)])],
                                          shop: shop, truncated: false)
        XCTAssertFalse(gone.notices[0].contains("Partly refunded"))
    }

    func testNothingLeftNoticesAreOneLine() throws {
        XCTAssertNil(shopifyImportNothingLeftNotice([]))
        XCTAssertEqual(shopifyImportNothingLeftNotice(["#1"]),
                       "Shopify shows nothing left to make in order #1 (its items were refunded, removed or fulfilled), so it was left out.")
        XCTAssertEqual(shopifyImportNothingLeftNotice(["#1", "#2", "#3"]),
                       "Shopify shows nothing left to make in orders #1, #2 and #3 (their items were refunded, removed or fulfilled), so they were left out.")
        let many = (1...12).map { "#\($0)" }
        let text = try XCTUnwrap(shopifyImportNothingLeftNotice(many))
        XCTAssertTrue(text.contains("#10 and 2 more"), text)
        XCTAssertFalse(text.contains("#11"), text)
        let nodes = [node(name: "#7")] + (1...3).map { node(name: "#\($0)", lines: [line(1, current: 0)]) }
        let parse = try shopifyImportParse(nodes, shop: shop, truncated: false)
        XCTAssertEqual(parse.notices.filter { $0.contains("nothing left to make") },
                       [shopifyImportNothingLeftNotice(["#1", "#2", "#3"])!])
    }
}

// MARK: - 3DAPI (7, 8, 9)

extension DapiOrdersTests {
    /// A stop for a wallet that can't be read at the press lists whatever else that read found changed, so Check Again
    /// never shows new figures as if nothing had changed. Nothing is sent.
    func testAWalletStopListsWhatElseChanged() async {
        let stub = ScriptedDapiOrders()
        stub.scriptQuote("qte_1", [.success(DapiOrdersTests.quote("qte_1"))])
        stub.scriptShipping([.success(DapiOrdersTests.shipping(699)), .success(DapiOrdersTests.shipping(899))])
        stub.walletResult = .success(wallet(10_000))
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        XCTAssertNotNil(runner.figures?.wallet)
        stub.walletResult = .failure(.readFailed("offline"))
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(runner.phase, .blocked(dapiWalletUnreadableBeforeSending))
        XCTAssertEqual(runner.changes, ["Shipping: \(dapiMoneyText(DapiOrdersTests.usd(699))) → \(dapiMoneyText(DapiOrdersTests.usd(899)))."])
        XCTAssertNil(runner.figures)
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertEqual(harness.begun, 0)
        XCTAssertEqual(harness.keys, 0)
        XCTAssertTrue(harness.unconfirmed.isEmpty)

        // Check Again shows the new figures as the review; the list goes with the stop.
        stub.walletResult = .success(wallet(10_000))
        runner.checkAgain()
        await waitUntil { runner.phase != .checking }
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertTrue(runner.changes.isEmpty)
        XCTAssertEqual(runner.figures?.shipping.total, DapiOrdersTests.usd(899))
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(stub.count("place"), 1)
        XCTAssertEqual(harness.begun, 1)
    }

    /// Sample credit's own stop still comes first, keeps the tick, and lists the other changes too.
    func testTheSampleCreditStopListsWhatElseChanged() async {
        let stub = ScriptedDapiOrders()
        stub.scriptQuote("qte_1", [.success(DapiOrdersTests.quote("qte_1", cents: 500)),
                                   .success(DapiOrdersTests.quote("qte_1", cents: 700))])
        stub.scriptShipping([.success(DapiOrdersTests.shipping(699))])
        stub.walletResult = .success(sampleCreditWallet(1_500))
        var own = draft()
        own.addressIsSellersOwn = true
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness, draft: own)
        XCTAssertTrue(runner.useSampleCredit)
        stub.walletResult = .failure(.rateLimited(code: nil, retryAt: nil))
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(runner.phase, .blocked(dapiSampleCreditWalletUnreadable))
        XCTAssertEqual(runner.changes.count, 1, "\(runner.changes)")
        XCTAssertTrue(runner.changes.first?.contains("per unit") == true)
        XCTAssertTrue(runner.useSampleCredit, "never unticked")
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertTrue(harness.unconfirmed.isEmpty)
    }

    /// Nothing else changed: the stop shows no list, as before.
    func testAWalletStopWithNothingElseChangedListsNothing() async {
        let stub = scriptedReady()
        stub.walletResult = .success(wallet(10_000))
        let runner = await readyRunner(stub, PlaceHarness())
        stub.walletResult = .failure(.readFailed("offline"))
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(runner.phase, .blocked(dapiWalletUnreadableBeforeSending))
        XCTAssertTrue(runner.changes.isEmpty)
    }

    func testTheChangesHeadingFollowsThePhase() {
        XCTAssertTrue(dapiPlaceChangesHeading(blocked: false).contains("press Place Order again"))
        XCTAssertFalse(dapiPlaceChangesHeading(blocked: true).contains("Place Order"), "Check Again is the button while stopped")
        XCTAssertTrue(DapiPlacePhase.blocked("x").isBlocked)
        XCTAssertFalse(DapiPlacePhase.ready.isBlocked)
        XCTAssertFalse(DapiPlacePhase.rechecking.isBlocked)
    }

    /// A debt that grows between the review and the press is a larger shortfall: nothing is sent.
    func testAGrowingDebtStopsTheOrder() async {
        let stub = scriptedReady()
        stub.walletResult = .success(wallet(-500))
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        let upTo = 500 * 2 + 699
        XCTAssertEqual(runner.figures.map { dapiWalletCover(upTo: dapiReviewUpToTotal($0.snapshot), wallet: $0.wallet) },
                       .short(DapiOrdersTests.usd(upTo + 500)))
        stub.walletResult = .success(wallet(-2_000))
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(runner.changes, [dapiWalletShortfallChange(reviewed: .short(DapiOrdersTests.usd(upTo + 500)),
                                                                  current: .short(DapiOrdersTests.usd(upTo + 2_000)))!])
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertTrue(harness.unconfirmed.isEmpty)
    }

    /// The auto top-up sentence appears once: the general note only when no shortfall line is shown.
    func testTheWalletNoteIsShownOnlyWithoutAShortfallLine() {
        XCTAssertFalse(dapiWalletNoteShown(.short(DapiOrdersTests.usd(500))))
        XCTAssertTrue(dapiWalletNoteShown(.covered))
        XCTAssertTrue(dapiWalletNoteShown(.notKnown))
        XCTAssertTrue(dapiWalletShortfallText(DapiOrdersTests.usd(500)).contains(dapiAutoTopUpClause))
        XCTAssertTrue(dapiWalletNote.contains(dapiAutoTopUpClause))
    }
}
