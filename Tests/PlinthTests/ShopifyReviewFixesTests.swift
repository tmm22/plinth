import XCTest
@testable import SlantStudio

/// Round 5 review fixes for the Shopify connection: the store and items recorded on drafts, fulfilling only what
/// Slant made, the same-order check, plan limits, sale amounts and the fetch/token edge cases.
final class ShopifyReviewFixesTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    private func product(_ name: String, sku: String) -> SavedProduct {
        var line = SavedProductLine()
        line.reference = "file-\(sku)"
        line.filamentID = "filament-1"
        line.name = name
        return SavedProduct(name: name, sku: sku, lines: [line])
    }

    private func money(_ amount: String, _ currency: String = "USD") -> [String: Any] {
        ["shopMoney": ["amount": amount, "currencyCode": currency]]
    }

    private func fetchedNode(name: String = "#1001", currency: String = "USD", address: Bool = true) -> [String: Any] {
        var node: [String: Any] = [
            "name": name, "email": "ana@example.com", "displayFinancialStatus": "PAID", "displayFulfillmentStatus": "UNFULFILLED",
            "subtotalPriceSet": money("30.00", currency), "totalShippingPriceSet": money("5.00", currency),
            "totalTaxSet": money("0.00", currency), "totalDiscountsSet": money("0.00", currency),
            "totalPriceSet": money("35.00", currency), "totalRefundedSet": money("0.00", currency),
            "lineItems": ["pageInfo": ["hasNextPage": false], "nodes": [
                ["id": "gid://shopify/LineItem/111", "name": "Vase", "sku": "VASE", "quantity": 2, "currentQuantity": 2, "customAttributes": []],
                ["id": "gid://shopify/LineItem/222", "name": "Mug", "sku": "MUG", "quantity": 1, "currentQuantity": 1, "customAttributes": []]
            ]]
        ]
        if address {
            node["shippingAddress"] = ["name": "Ana Lima", "address1": "1 Main St", "city": "Boston", "provinceCode": "MA",
                                       "zip": "02134", "countryCodeV2": "US"]
        }
        return node
    }

    // MARK: 1. The store and the items on the draft

    func testFetchedDraftsRecordTheirStoreAndLineItems() throws {
        let parse = try shopifyImportParse([fetchedNode()], shop: "prints.myshopify.com", truncated: false)
        let order = parse.orders[0]
        XCTAssertEqual(order.sourceShop, "prints.myshopify.com")
        XCTAssertEqual(order.items.map(\.sourceLineItemID), ["111", "222"])
        let context = OrderImportContext(products: [product("Vase", sku: "VASE"), product("Mug", sku: "MUG")], platformID: "p1")
        let body = try XCTUnwrap(orderImportCheck(order, context: context, draftMarker: "m1").body)
        let metadata = try XCTUnwrap(body["metadata"] as? [String: Any])
        XCTAssertEqual(metadata["sourceShop"] as? String, "prints.myshopify.com")
        XCTAssertEqual(metadata["source"] as? String, "shopify")
        XCTAssertEqual(metadata["sourceOrderId"] as? String, "#1001")
        XCTAssertEqual(metadata[studioDraftMarkerKey] as? String, "m1")
        XCTAssertLessThanOrEqual(metadata.count, orderMetadataFieldLimit)
        XCTAssertEqual(shopifySourceItems(fromMetadata: metadata["sourceItems"]),
                       [ShopifySourceItem(key: .lineItem("111"), quantity: 2), ShopifySourceItem(key: .lineItem("222"), quantity: 1)])
    }

    func testLeftOutItemsAreNotRecordedAndOtherSourcesRecordNothing() throws {
        var order = OrderImportOrder(source: .shopify, sourceOrderID: "#7")
        order.items = [OrderImportItem(sku: "VASE", quantityText: "2", itemName: "Vase", row: 1),
                       OrderImportItem(sku: "", quantityText: "1", itemName: "Shipping protection", row: 2)]
        let recorded = shopifyDraftSourceItems(order, itemProductIDs: [UUID(), nil])
        XCTAssertEqual(shopifySourceItems(fromMetadata: recorded), [ShopifySourceItem(key: .sku("VASE"), quantity: 2)])
        // A CSV import has no store: no sourceShop field at all.
        XCTAssertNil(orderImportMetadata(source: .shopify, sourceOrderID: "#7", sourceShop: "")["sourceShop"])
        var etsy = OrderImportOrder(source: .etsy, sourceOrderID: "555")
        etsy.items = order.items
        XCTAssertNil(shopifyDraftSourceItems(etsy, itemProductIDs: nil))
    }

    func testSourceItemsEncodingIsStrictAndBounded() {
        let items = [ShopifySourceItem(key: .sku("A"), quantity: 1), ShopifySourceItem(key: .name("Name  tag"), quantity: 3)]
        XCTAssertEqual(shopifySourceItems(fromMetadata: shopifySourceItemsMetadata(items)), items)
        // Repeated keys are added up.
        let repeated = shopifySourceItems([OrderImportItem(sku: "a", quantityText: "1", itemName: "", row: 1),
                                           OrderImportItem(sku: " A ", quantityText: "2", itemName: "", row: 2)])
        XCTAssertEqual(repeated, [ShopifySourceItem(key: .sku("a"), quantity: 3)])
        // An item with nothing to match by means nothing is recorded.
        XCTAssertNil(shopifySourceItems([OrderImportItem(sku: "", quantityText: "1", itemName: " ", row: 1)]))
        XCTAssertNil(shopifySourceItemsMetadata([]))
        let long = (0..<50).map { ShopifySourceItem(key: .name(String(repeating: "x", count: 40) + "\($0)"), quantity: 1) }
        XCTAssertNil(shopifySourceItemsMetadata(long), "too long to record")
        for bad in [#"[{"sku":"A"}]"#, #"[{"sku":"A","quantity":0}]"#, #"[{"sku":"A","quantity":1.5}]"#,
                    #"[{"sku":"A","name":"B","quantity":1}]"#, #"[{"lineItem":"12a","quantity":1}]"#, #"[]"#, "nope",
                    #"[{"sku":"A","quantity":true}]"#] {
            XCTAssertNil(shopifySourceItems(fromMetadata: bad), bad)
        }
        XCTAssertNil(shopifySourceItems(fromMetadata: 5))
        XCTAssertEqual(shopifyNumericID("gid://shopify/LineItem/123", type: "LineItem"), "123")
        XCTAssertNil(shopifyNumericID("gid://shopify/Order/123", type: "LineItem"))
    }

    func testFollowUpEntriesReadTheStoreAndItems() {
        let order: [String: Any] = [
            "publicId": "S1", "status": "SHIPPED",
            "fulfillment": ["trackingNumber": "1Z9", "provider": "UPS"],
            "customer": ["details": ["address": ["name": "Ana Lima", "zip": "02134"]]],
            "metadata": ["source": "shopify", "sourceOrderId": "#1001", "sourceShop": " Prints.myshopify.com ",
                         "sourceItems": #"[{"quantity":2,"sku":"VASE"}]"#]
        ]
        let entry = shopFollowUpEntry(Record(values: order))
        XCTAssertEqual(entry?.sourceShop, "prints.myshopify.com")
        XCTAssertEqual(entry?.sourceItems, [ShopifySourceItem(key: .sku("VASE"), quantity: 2)])
        XCTAssertEqual(entry?.recipientName, "Ana Lima")
        XCTAssertEqual(entry?.postcode, "02134")
        if let entry {
            let candidate = shopifyTrackingCandidates([entry], done: []).first
            XCTAssertEqual(candidate?.sourceShop, "prints.myshopify.com")
            XCTAssertEqual(candidate?.sourceItems?.count, 1)
        }
    }

    // MARK: Same order, for CSV imports

    func testIdentityCheck() {
        XCTAssertNil(shopifyIdentityProblem(shopifyName: "ana  lima", shopifyPostcode: "02134-1234", slantName: "Ana Lima", slantPostcode: "02134"))
        XCTAssertNil(shopifyIdentityProblem(shopifyName: "José Núñez", shopifyPostcode: "sw1a1aa", slantName: "Jose Nunez", slantPostcode: "SW1A 1AA"))
        XCTAssertNotNil(shopifyIdentityProblem(shopifyName: "Ana Lima", shopifyPostcode: "02135", slantName: "Ana Lima", slantPostcode: "02134"))
        XCTAssertNotNil(shopifyIdentityProblem(shopifyName: "Bo Chen", shopifyPostcode: "02134", slantName: "Ana Lima", slantPostcode: "02134"))
        XCTAssertNotNil(shopifyIdentityProblem(shopifyName: "", shopifyPostcode: "", slantName: "Ana Lima", slantPostcode: "02134"),
                        "withheld address can't confirm")
        XCTAssertNotNil(shopifyIdentityProblem(shopifyName: "Ana", shopifyPostcode: "1", slantName: "", slantPostcode: ""))
        XCTAssertFalse(shopifyPostcodesMatch("1234", "12345"))
        XCTAssertFalse(shopifyPostcodesMatch("123456", "12345"))
    }

    private func orderData(address: [String: Any]? = nil, lines: [[String: Any]], fulfillmentOrders count: Int = 1) -> [String: Any] {
        var order: [String: Any] = [
            "name": "#1001", "displayFulfillmentStatus": "UNFULFILLED", "fulfillments": [],
            "fulfillmentOrders": ["nodes": (0..<count).map { index in [
                "id": "gid://shopify/FulfillmentOrder/\(index + 5)", "supportedActions": [["action": "CREATE_FULFILLMENT"]],
                "lineItems": ["pageInfo": ["hasNextPage": false], "nodes": lines]
            ] }]
        ]
        if let address { order["shippingAddress"] = address }
        return ["order": order]
    }

    private func line(_ id: Int, remaining: Int, lineItem: Int, sku: String, name: String) -> [String: Any] {
        ["id": "gid://shopify/FulfillmentOrderLineItem/\(id)", "remainingQuantity": remaining,
         "lineItem": ["id": "gid://shopify/LineItem/\(lineItem)", "sku": sku, "name": name]]
    }

    func testCSVImportsMustMatchByAddressAndAreNeverTickedForTheSeller() {
        let lines = [line(1, remaining: 2, lineItem: 111, sku: "VASE", name: "Vase")]
        let items = [ShopifySourceItem(key: .sku("vase"), quantity: 2)]
        let identity = ShopifyIdentityExpectation(recipientName: "Ana Lima", postcode: "02134")
        let matched = shopifyFulfilmentCheck(orderData(address: ["name": "Ana Lima", "zip": "02134"], lines: lines),
                                             trackingNumbers: ["1Z9"], sourceItems: items, identity: identity)
        XCTAssertEqual(matched.plan?.matchedByAddress, true)
        XCTAssertFalse(shopifyTrackingTickedByDefault(matched, hasUnconfirmedSend: false))
        XCTAssertTrue(matched.summary.contains("recipient and postcode"))
        let other = shopifyFulfilmentCheck(orderData(address: ["name": "Bo Chen", "zip": "90210"], lines: lines),
                                           trackingNumbers: ["1Z9"], sourceItems: items, identity: identity)
        XCTAssertFalse(other.isReady)
        XCTAssertTrue(other.summary.contains("another store"))
        let withheld = shopifyFulfilmentCheck(orderData(lines: lines), trackingNumbers: ["1Z9"], sourceItems: items, identity: identity)
        XCTAssertFalse(withheld.isReady)
        // Fetched from the connected store: ticked.
        let sameShop = shopifyFulfilmentCheck(orderData(lines: lines), trackingNumbers: ["1Z9"], sourceItems: items, identity: nil)
        XCTAssertTrue(shopifyTrackingTickedByDefault(sameShop, hasUnconfirmedSend: false))
        XCTAssertFalse(shopifyTrackingTickedByDefault(sameShop, hasUnconfirmedSend: true))
        XCTAssertEqual(ShopifyFulfilmentCheck.otherShop("a.myshopify.com").summary, "Imported from a.myshopify.com, not the connected store. Not sent.")
        XCTAssertFalse(shopifyFulfilmentCheckQuery(includeAddress: false).contains("shippingAddress"))
        XCTAssertTrue(shopifyFulfilmentCheckQuery(includeAddress: true).contains("shippingAddress { name zip }"))
    }

    // MARK: 2. Fulfil only what Slant made

    func testOnlyTheDraftsItemsAreFulfilledAndASplitWorksForTheRest() {
        let lines = [line(1, remaining: 2, lineItem: 111, sku: "VASE", name: "Vase"),
                     line(2, remaining: 1, lineItem: 222, sku: "MUG", name: "Mug")]
        let first = shopifyFulfilmentCheck(orderData(lines: lines), trackingNumbers: ["1Z1"],
                                           sourceItems: [ShopifySourceItem(key: .lineItem("111"), quantity: 2)], identity: nil)
        XCTAssertEqual(first.plan?.lines, [ShopifyFulfilmentLine(id: "gid://shopify/FulfillmentOrderLineItem/1", quantity: 2)])
        XCTAssertEqual(first.plan?.remaining, ["1 × Mug"])
        // The second draft, after the first was sent: only the mug is left.
        let afterFirst = [line(1, remaining: 0, lineItem: 111, sku: "VASE", name: "Vase"),
                          line(2, remaining: 1, lineItem: 222, sku: "MUG", name: "Mug")]
        let second = shopifyFulfilmentCheck(orderData(lines: afterFirst), trackingNumbers: ["1Z2"],
                                            sourceItems: [ShopifySourceItem(key: .sku("mug"), quantity: 1)], identity: nil)
        XCTAssertEqual(second.plan?.lines, [ShopifyFulfilmentLine(id: "gid://shopify/FulfillmentOrderLineItem/2", quantity: 1)])
        XCTAssertEqual(second.plan?.remaining, [])
        // Not enough units left, an unknown item, or nothing recorded: blocked, never "fulfil everything".
        for items in [[ShopifySourceItem(key: .sku("VASE"), quantity: 3)], [ShopifySourceItem(key: .name("Lamp"), quantity: 1)]] {
            let blocked = shopifyFulfilmentCheck(orderData(lines: lines), trackingNumbers: ["1Z1"], sourceItems: items, identity: nil)
            XCTAssertFalse(blocked.isReady)
        }
        XCTAssertFalse(shopifyFulfilmentCheck(orderData(lines: lines), trackingNumbers: ["1Z1"], sourceItems: nil, identity: nil).isReady)
        // A list Shopify cut short can't be matched safely.
        var cut = orderData(lines: lines)
        var order = cut["order"] as! [String: Any]
        var fo = (order["fulfillmentOrders"] as! [String: Any])["nodes"] as! [[String: Any]]
        fo[0]["lineItems"] = ["pageInfo": ["hasNextPage": true], "nodes": lines]
        order["fulfillmentOrders"] = ["nodes": fo]
        cut["order"] = order
        XCTAssertFalse(shopifyFulfilmentCheck(cut, trackingNumbers: ["1Z1"], sourceItems: [ShopifySourceItem(key: .sku("VASE"), quantity: 1)], identity: nil).isReady)
    }

    func testAllocationSpreadsUnitsOverLinesWithTheSameSKU() {
        let lines = [ShopifyFulfilmentOrderLine(id: "a", remaining: 1, lineItemID: "1", sku: "VASE", name: "Vase"),
                     ShopifyFulfilmentOrderLine(id: "b", remaining: 2, lineItemID: "2", sku: "vase", name: "Vase (gift)")]
        XCTAssertEqual(try shopifyAllocateFulfilment([ShopifySourceItem(key: .sku("VASE"), quantity: 2)], lines: lines).get(),
                       [ShopifyFulfilmentLine(id: "a", quantity: 1), ShopifyFulfilmentLine(id: "b", quantity: 1)])
        XCTAssertThrowsError(try shopifyAllocateFulfilment([ShopifySourceItem(key: .sku(""), quantity: 1)],
                                                           lines: [ShopifyFulfilmentOrderLine(id: "c", remaining: 1, lineItemID: nil, sku: "", name: "")]).get())
    }

    // MARK: 4. Plan limits

    func testPlanNameAndCustomerDataWarnings() throws {
        let data = json(#"{"shop":{"name":"Prints","myshopifyDomain":"prints.myshopify.com","plan":{"publicDisplayName":"Basic","partnerDevelopment":false}},"currentAppInstallation":{"accessScopes":[{"handle":"read_orders"}]}}"#)
        let result = try shopifyConnectionTest(data, expectedShop: "prints.myshopify.com")
        XCTAssertEqual(result.planName, "Basic")
        XCTAssertTrue(result.customerDataLikelyWithheld)
        XCTAssertTrue(shopifyConnectionStatusLine(result).hasPrefix("Connected to Prints (Basic plan)."))
        XCTAssertFalse(shopifyPlanLikelyWithholdsCustomerData(planName: "Grow", partnerDevelopment: false))
        XCTAssertFalse(shopifyPlanLikelyWithholdsCustomerData(planName: "Basic", partnerDevelopment: true))
        XCTAssertTrue(shopifyPlanLikelyWithholdsCustomerData(planName: "Starter", partnerDevelopment: false))
        XCTAssertFalse(shopifyPlanLikelyWithholdsCustomerData(planName: nil, partnerDevelopment: false))
        XCTAssertTrue(shopifyTestQuery.contains("publicDisplayName"))
        // Without a plan in the reply, nothing is claimed.
        let bare = try shopifyConnectionTest(json(#"{"shop":{"name":"P","myshopifyDomain":"prints.myshopify.com"}}"#), expectedShop: "prints.myshopify.com")
        XCTAssertNil(bare.planName)
        XCTAssertEqual(shopifyConnectionStatusLine(bare).hasPrefix("Connected to P. "), true)
    }

    func testOneSheetNoticeWhenMostOrdersLackCustomerData() throws {
        let withheld = try shopifyImportParse([fetchedNode(name: "#1", address: false), fetchedNode(name: "#2", address: false),
                                               fetchedNode(name: "#3")], shop: "p.myshopify.com", truncated: false)
        XCTAssertEqual(withheld.notices.filter { $0.contains("Basic and Starter") }.count, 1)
        let fine = try shopifyImportParse([fetchedNode(name: "#1"), fetchedNode(name: "#2", address: false)],
                                          shop: "p.myshopify.com", truncated: false)
        XCTAssertFalse(fine.notices.contains { $0.contains("Basic and Starter") }, "half isn't most")
    }

    // MARK: 5. Sale amounts

    func testFetchedAmountsFillTheSameSaleRowsAsTheCSV() throws {
        let order = try shopifyImportParse([fetchedNode()], shop: "p.myshopify.com", truncated: false).orders[0]
        XCTAssertEqual(order.saleRows.count, 1)
        guard case .amounts(let amounts) = importedSaleAmounts(for: order) else { return XCTFail("USD amounts are read") }
        XCTAssertEqual(amounts.itemTotal, 30)
        XCTAssertEqual(amounts.shipping, 5)
        XCTAssertEqual(amounts.unitsSold, 3)
        let euros = try shopifyImportParse([fetchedNode(currency: "EUR")], shop: "p.myshopify.com", truncated: false).orders[0]
        XCTAssertEqual(importedSaleAmounts(for: euros), .otherCurrency("EUR"))
        var mixed = fetchedNode()
        mixed["totalShippingPriceSet"] = money("5.00", "CAD")
        XCTAssertEqual(shopifyImportSaleRow(mixed)?.currency, "", "different currencies are never used")
        XCTAssertNil(shopifyImportSaleRow(["name": "#1"]))
        var refunded = fetchedNode()
        refunded["totalRefundedSet"] = money("10.00")
        XCTAssertEqual(shopifyImportSaleRow(refunded)?.refunded, "10.00")
    }

    // MARK: 3, 6, 8. Fetch result, token failures, wording

    func testFetchActivityAndHints() {
        XCTAssertEqual(shopifyImportFetchActivityDetail(count: 1, used: true), "1 order")
        XCTAssertEqual(shopifyImportFetchActivityDetail(count: 4, used: false), "4 orders, not used")
        XCTAssertNil(shopifyImportIntroHint(shop: nil))
        XCTAssertTrue(shopifyImportIntroHint(shop: "p.myshopify.com")?.contains("Fetch from Shopify") == true)
        XCTAssertEqual(shopifyImportEmptyHint(connected: false), orderImportEmptyHint)
        XCTAssertTrue(shopifyImportEmptyHint(connected: true).contains("Fetch from Shopify"))
    }

    func testFailuresBeforeAMutationIsSentAreNotUnknown() {
        XCTAssertFalse(shopifyMutationOutcomeUnknown(ShopifyError.notSent("no token")))
        XCTAssertFalse(shopifyMutationOutcomeUnknown(ShopifyError.shopChanged))
        if case .refused = shopifyTrackingOutcome(error: ShopifyError.notSent("Not sent")) {} else { XCTFail() }
        XCTAssertTrue(shopifyMutationOutcomeUnknown(ShopifyError.transport("timed out")), "a send without a reply stays unknown")
    }

    func testConnectionChangesWaitForTrackingAndRequests() {
        XCTAssertNotNil(shopifyConnectionChangeBlockedReason(busy: false, openTrackingSheets: 1))
        XCTAssertNotNil(shopifyConnectionChangeBlockedReason(busy: true, openTrackingSheets: 0))
        XCTAssertNil(shopifyConnectionChangeBlockedReason(busy: false, openTrackingSheets: 0))
    }
}
