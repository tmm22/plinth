import XCTest
@testable import Plinth

/// Round 21 Shopify fixes: partially fulfilled orders, scopes read again, field-level protected data, mutation replies
/// with errors, several fulfillment orders, carrier names, wording, stopping before a send, cancelled Slant orders and
/// the redirect refusal through a stubbed transport. No request reaches a shop.
final class ShopifyRound21Tests: XCTestCase {
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

    private func fetchedNode(name: String = "#1001", fulfilment: String = "UNFULFILLED",
                             lines: [[String: Any]]? = nil) -> [String: Any] {
        [
            "name": name, "email": "ana@example.com", "displayFinancialStatus": "PAID", "displayFulfillmentStatus": fulfilment,
            "shippingAddress": ["name": "Ana Lima", "address1": "1 Main St", "city": "Boston", "provinceCode": "MA",
                                "zip": "02134", "countryCodeV2": "US"],
            "lineItems": ["pageInfo": ["hasNextPage": false], "nodes": lines ?? [
                ["id": "gid://shopify/LineItem/111", "name": "Vase", "sku": "VASE", "quantity": 3, "currentQuantity": 3,
                 "unfulfilledQuantity": 3, "customAttributes": []]
            ]]
        ]
    }

    // MARK: A2-1 · Partially fulfilled orders (and NEW-1)

    func testTheImportAsksForUnfulfilledQuantities() {
        XCTAssertTrue(shopifyImportOrdersQuery.contains("unfulfilledQuantity"))
    }

    func testOnlyUnitsStillToFulfilAreDrafted() {
        XCTAssertEqual(shopifyImportLineUnits(["quantity": 3, "currentQuantity": 3, "unfulfilledQuantity": 1]), 1)
        XCTAssertEqual(shopifyImportLineUnits(["quantity": 3, "currentQuantity": 2, "unfulfilledQuantity": 3]), 2,
                       "a removed unit Shopify still counts as unfulfilled is never drafted")
        XCTAssertEqual(shopifyImportLineUnits(["quantity": 3, "currentQuantity": 3, "unfulfilledQuantity": 0]), 0)
        XCTAssertEqual(shopifyImportLineUnits(["quantity": 3, "currentQuantity": 2]), 2, "an older reply without the field")
        XCTAssertEqual(shopifyImportLineUnits(["quantity": 3, "unfulfilledQuantity": 5]), 3)
        XCTAssertEqual(shopifyImportLineUnits(["quantity": 4]), 4)
        XCTAssertNil(shopifyImportLineUnits(["quantity": true]), "a boolean is never a count")
        XCTAssertNil(shopifyImportLineUnits([:]))

        var row = 1
        let node = fetchedNode(fulfilment: "PARTIALLY_FULFILLED", lines: [
            ["id": "gid://shopify/LineItem/111", "name": "Vase", "sku": "VASE", "quantity": 3, "currentQuantity": 3,
             "unfulfilledQuantity": 1, "customAttributes": []],
            ["id": "gid://shopify/LineItem/222", "name": "Mug", "sku": "MUG", "quantity": 1, "currentQuantity": 1,
             "unfulfilledQuantity": 0, "customAttributes": []]
        ])
        let order = shopifyImportOrder(node, nextRow: &row).order
        XCTAssertEqual(order?.items.map(\.sku), ["VASE"], "a line with nothing left to fulfil is dropped")
        XCTAssertEqual(order?.items.map(\.quantityText), ["1"])
        // The draft's recorded items match Send Tracking's remaining units.
        XCTAssertEqual(order.flatMap { shopifyDraftSourceItems($0, itemProductIDs: nil) }.flatMap { shopifySourceItems(fromMetadata: $0) },
                       [ShopifySourceItem(key: .lineItem("111"), quantity: 1)])
    }

    func testPartlyFulfilledOrdersStartUnticked() throws {
        let context = OrderImportContext(products: [product("Vase", sku: "VASE")], platformID: "p1")
        let open = try shopifyImportParse([fetchedNode()], shop: "p.myshopify.com", truncated: false).orders[0]
        XCTAssertNil(open.alreadyHandled)
        XCTAssertTrue(orderImportCheck(open, context: context).tickedByDefault, "the control: an unfulfilled order is ticked")

        let partial = try shopifyImportParse([fetchedNode(fulfilment: "PARTIALLY_FULFILLED")], shop: "p.myshopify.com", truncated: false).orders[0]
        XCTAssertEqual(partial.alreadyHandled, "Shopify shows part of this order as fulfilled. Only the items still to fulfil are listed.")
        XCTAssertFalse(orderImportCheck(partial, context: context).tickedByDefault)

        for status in ["IN_PROGRESS", "PENDING_FULFILLMENT"] {
            let sent = try shopifyImportParse([fetchedNode(fulfilment: status)], shop: "p.myshopify.com", truncated: false).orders[0]
            XCTAssertEqual(sent.alreadyHandled, "Shopify shows this order as sent to a fulfilment service.", status)
            XCTAssertFalse(orderImportCheck(sent, context: context).tickedByDefault, status)
        }
        let nothing = try shopifyImportParse([fetchedNode(fulfilment: "FULFILLMENT_NOT_REQUIRED")], shop: "p.myshopify.com", truncated: false).orders[0]
        XCTAssertEqual(nothing.alreadyHandled, "Shopify shows nothing in this order to fulfil.")
        for status in ["UNFULFILLED", "OPEN", "SCHEDULED", "ON_HOLD", ""] {
            XCTAssertNil(orderImportAlreadyHandledReason(format: .shopify, dateShipped: "", fulfillmentStatus: status,
                                                         cancelledAt: "", financialStatus: "paid"), status)
        }
        XCTAssertNil(orderImportAlreadyHandledReason(format: .template, dateShipped: "", fulfillmentStatus: "partial",
                                                     cancelledAt: "", financialStatus: ""))
    }

    func testAPartialCSVExportSaysItListsEveryItem() throws {
        let csv = """
        Name,Email,Financial Status,Fulfillment Status,Lineitem quantity,Lineitem name,Lineitem sku,Shipping Name,Shipping Address1,Shipping City,Shipping Zip,Shipping Province,Shipping Country\r
        #1001,ana@example.com,paid,partial,3,Vase,VASE,Ana Lima,1 Main St,Boston,'02134,MA,US\r
        #1002,bo@example.com,paid,unfulfilled,1,Vase,VASE,Bo Chen,2 High St,Boston,02134,MA,US\r
        """
        let parse = try orderImportParse(data: Data(csv.utf8))
        XCTAssertEqual(parse.orders[0].alreadyHandled, "Shopify shows part of this order as fulfilled, and the export lists every item.")
        XCTAssertNil(parse.orders[1].alreadyHandled)
        let context = OrderImportContext(products: [product("Vase", sku: "VASE")], platformID: "p1")
        XCTAssertFalse(orderImportCheck(parse.orders[0], context: context).tickedByDefault)
        XCTAssertTrue(orderImportCheck(parse.orders[1], context: context).tickedByDefault)
    }

    // MARK: B3-9 · Every fetched order left out

    func testAFetchWhoseOrdersWereAllLeftOutSaysWhy() {
        var big = fetchedNode(name: "#2001")
        big["lineItems"] = ["pageInfo": ["hasNextPage": true], "nodes": []]
        var bigger = fetchedNode(name: "#2002")
        bigger["lineItems"] = ["pageInfo": ["hasNextPage": true], "nodes": []]
        XCTAssertThrowsError(try shopifyImportParse([big, bigger], shop: "p.myshopify.com", truncated: false)) { error in
            let message = (error as? StudioError)?.message ?? ""
            XCTAssertTrue(message.contains("#2001") && message.contains("#2002"), message)
            XCTAssertTrue(message.contains("CSV export"), message)
            XCTAssertFalse(message.contains("no paid, unfulfilled orders"), message)
        }
        XCTAssertThrowsError(try shopifyImportParse([], shop: "p.myshopify.com", truncated: false)) { error in
            XCTAssertTrue(((error as? StudioError)?.message ?? "").contains("no paid, unfulfilled orders"))
        }
    }

    // MARK: A2-2 / B3-2 · Scopes read again

    func testScopesAreReadAgainOnlyWhenTheyCantFulfil() {
        XCTAssertTrue(shopifyScopesNeedReread(nil))
        XCTAssertTrue(shopifyScopesNeedReread([]))
        XCTAssertTrue(shopifyScopesNeedReread(["read_orders"]))
        XCTAssertFalse(shopifyScopesNeedReread(["read_orders", "write_merchant_managed_fulfillment_orders"]))
        XCTAssertFalse(shopifyScopesNeedReread(["write_assigned_fulfillment_orders"]))
    }

    @MainActor
    func testNoteAndForgetScopes() throws {
        let client = try XCTUnwrap(ShopifyClient(shop: "a.myshopify.com", credential: .accessToken("shpat_x")))
        XCTAssertNil(client.grantedScopes)
        client.noteScopes(["read_orders"])
        XCTAssertEqual(client.grantedScopes, ["read_orders"])
        client.forgetScopes()
        XCTAssertNil(client.grantedScopes)
    }

    // MARK: A2-3 · Field-level protected customer data

    func testFieldLevelProtectedDataIsRecognised() {
        let field = json(#"{"data":{"order":{"shippingAddress":null}},"errors":[{"message":"This app is not approved to use the name field. See https://partners.shopify.com/1/apps/2/customer_data for more details.","path":["order","shippingAddress","name"]}]}"#)
        XCTAssertEqual(shopifyGraphQLError(fromResponse: field), .protectedCustomerData)
        let object = json(#"{"data":{"orders":null},"errors":[{"message":"This app is not approved to access the Customer object.","path":["orders"]}]}"#)
        XCTAssertEqual(shopifyGraphQLError(fromResponse: object), .protectedCustomerData)
        // A throttle is still a throttle, and an unrelated "not approved" message isn't protected data.
        XCTAssertEqual(shopifyGraphQLError(fromResponse: json(#"{"errors":[{"message":"This app is not approved to use the name field.","extensions":{"code":"THROTTLED"}}]}"#)), .throttled)
        XCTAssertFalse(shopifyMessageIsProtectedCustomerData("The discount is not approved to use yet."))
        let text = ShopifyError.protectedCustomerData.errorDescription ?? ""
        XCTAssertTrue(text.contains("Grow plan"))
        XCTAssertTrue(text.contains("CSV"))
        XCTAssertFalse(text.contains("Dev Dashboard"), "a merchant's Dev Dashboard app has no such setting")
    }

    // MARK: B3-3 · Mutation replies carrying errors

    func testMutationErrorRepliesThatMayHaveRunAreUnknown() {
        let table: [(String, Bool, String)] = [
            (#"{"errors":[{"message":"Throttled","extensions":{"code":"THROTTLED"}}]}"#, false, "THROTTLED is checked before running"),
            (#"{"data":{"fulfillmentCreate":null},"errors":[{"message":"Throttled","extensions":{"code":"THROTTLED"}}]}"#, false, "THROTTLED first"),
            (#"{"data":{"fulfillmentCreate":{"fulfillment":{"id":"gid://shopify/Fulfillment/1"}}},"errors":[{"message":"x","extensions":{"code":"SOME_OTHER_CODE"}}]}"#, true, "a data object means it ran"),
            (#"{"data":{"fulfillmentCreate":null},"errors":[{"message":"x","extensions":{"code":"ACCESS_DENIED"}}]}"#, true, "a data object, even with a refusal code"),
            (#"{"data":{"order":{"shippingAddress":null}},"errors":[{"message":"This app is not approved to use the name field."}]}"#, true, "field-level protected data comes with data"),
            (#"{"data":null,"errors":[{"message":"x","extensions":{"code":"SOME_OTHER_CODE"}}]}"#, true, "data: null with an unknown code"),
            (#"{"errors":[{"message":"Field 'nope' doesn't exist","extensions":{"code":"undefinedField"}}]}"#, false, "no data key: failed validation"),
            (#"{"data":null,"errors":[{"message":"Access denied","extensions":{"code":"ACCESS_DENIED"}}]}"#, false, "ACCESS_DENIED without data"),
            (#"{"errors":[{"message":"Shop inactive","extensions":{"code":"SHOP_INACTIVE"}}]}"#, false, "SHOP_INACTIVE"),
            (#"{"data":null,"errors":[{"message":"Too costly","extensions":{"code":"MAX_COST_EXCEEDED"}}]}"#, false, "MAX_COST_EXCEEDED"),
            (#"{"data":null,"errors":[{"message":"a","extensions":{"code":"ACCESS_DENIED"}},{"message":"b","extensions":{"code":"SOME_OTHER_CODE"}}]}"#, true, "a mixed list with data: null"),
            (#"{"errors":[{"message":"Internal error","extensions":{"code":"INTERNAL_SERVER_ERROR"}}]}"#, true, "INTERNAL_SERVER_ERROR"),
            (#"{"errors":[{"message":"Something went wrong"}]}"#, true, "no code"),
            (#"{"errors":[{"message":"a","extensions":{"code":"ACCESS_DENIED"}},{"message":"b"}]}"#, true, "one error without a code"),
            (#"{"errors":"Something went wrong"}"#, true, "errors as text"),
        ]
        for (reply, mayHaveRun, why) in table {
            XCTAssertEqual(shopifyMutationErrorReplyMayHaveRun(json(reply)), mayHaveRun, why)
        }
    }

    func testThrownErrorsMapToTheRightOutcome() {
        if case .unknown = shopifyTrackingOutcome(error: ShopifyError.invalidResponse("Shopify answered with an error and didn’t confirm whether it made the change.")) {} else {
            XCTFail("an error reply that may have run is unconfirmed")
        }
        if case .refused = shopifyTrackingOutcome(error: ShopifyError.graphQL(messages: ["x"], codes: ["undefinedField"])) {} else { XCTFail() }
        if case .refused = shopifyTrackingOutcome(error: ShopifyError.graphQL(messages: ["x"], codes: ["ACCESS_DENIED"])) {} else { XCTFail() }
        if case .refused = shopifyTrackingOutcome(error: ShopifyError.notSent("Stopped before anything was sent to Shopify.")) {} else { XCTFail() }
    }

    // MARK: A2-4 · Several fulfillment orders

    private func line(_ id: Int, remaining: Int, lineItem: Int, sku: String, name: String) -> [String: Any] {
        ["id": "gid://shopify/FulfillmentOrderLineItem/\(id)", "remainingQuantity": remaining,
         "lineItem": ["id": "gid://shopify/LineItem/\(lineItem)", "sku": sku, "name": name]]
    }

    private func fulfilmentOrder(_ id: Int, lines: [[String: Any]], fulfillable: Bool = true, more: Bool = false) -> [String: Any] {
        ["id": "gid://shopify/FulfillmentOrder/\(id)",
         "supportedActions": fulfillable ? [["action": "CREATE_FULFILLMENT"]] : [["action": "RELEASE_HOLD"]],
         "lineItems": ["pageInfo": ["hasNextPage": more], "nodes": lines]]
    }

    private func orderData(_ fulfilmentOrders: [[String: Any]], status: String = "PARTIALLY_FULFILLED", moreOrders: Bool = false) -> [String: Any] {
        ["order": ["name": "#1001", "displayFulfillmentStatus": status, "fulfillments": [],
                   "fulfillmentOrders": ["pageInfo": ["hasNextPage": moreOrders], "nodes": fulfilmentOrders]]]
    }

    private func check(_ data: [String: Any], items: [ShopifySourceItem]) -> ShopifyFulfilmentCheck {
        shopifyFulfilmentCheck(data, trackingNumbers: ["1Z9"], sourceItems: items, identity: nil)
    }

    func testTheCheckReadsDisplayableFulfilmentOrdersAndTheirPaging() {
        let query = shopifyFulfilmentCheckQuery(includeAddress: false)
        XCTAssertTrue(query.contains("fulfillmentOrders(first: \(shopifyFulfilmentOrdersRead), displayable: true)"))
        XCTAssertTrue(query.filter { !$0.isWhitespace }.contains("displayable:true){pageInfo{hasNextPage}nodes{"), query)
        let vase = [ShopifySourceItem(key: .lineItem("111"), quantity: 1)]
        let more = check(orderData([fulfilmentOrder(5, lines: [line(51, remaining: 1, lineItem: 111, sku: "VASE", name: "Vase")])],
                                   moreOrders: true), items: vase)
        XCTAssertEqual(more, .unavailable("This order has more fulfilment orders in Shopify than Plinth reads. Add its tracking in Shopify."))
    }

    func testExactlyOneFulfilmentOrderHoldingTheDraftIsSent() {
        // Slant made the vase; the mug ships from another location (or on another shipping rate).
        let vaseOrder = fulfilmentOrder(5, lines: [line(51, remaining: 2, lineItem: 111, sku: "VASE", name: "Vase")])
        let mugOrder = fulfilmentOrder(6, lines: [line(61, remaining: 1, lineItem: 222, sku: "MUG", name: "Mug")])
        let result = check(orderData([mugOrder, vaseOrder]), items: [ShopifySourceItem(key: .lineItem("111"), quantity: 2)])
        XCTAssertEqual(result, .ready(ShopifyFulfilmentPlan(
            fulfillmentOrderID: "gid://shopify/FulfillmentOrder/5",
            lines: [ShopifyFulfilmentLine(id: "gid://shopify/FulfillmentOrderLineItem/51", quantity: 2)],
            items: ["2 × Vase"], remaining: ["1 × Mug"], matchedByAddress: false)))
        // One that can't fulfil (on hold) doesn't count, and isn't a candidate either.
        let held = fulfilmentOrder(7, lines: [line(71, remaining: 2, lineItem: 111, sku: "VASE", name: "Vase")], fulfillable: false)
        XCTAssertEqual(check(orderData([held, vaseOrder]), items: [ShopifySourceItem(key: .lineItem("111"), quantity: 2)]).plan?.fulfillmentOrderID,
                       "gid://shopify/FulfillmentOrder/5")
    }

    func testAmbiguousOrSplitDraftsAreNeverSent() {
        // The draft's units spread over two shipments: neither holds them all.
        let first = fulfilmentOrder(5, lines: [line(51, remaining: 1, lineItem: 111, sku: "VASE", name: "Vase")])
        let second = fulfilmentOrder(6, lines: [line(61, remaining: 1, lineItem: 111, sku: "VASE", name: "Vase")])
        XCTAssertEqual(check(orderData([first, second]), items: [ShopifySourceItem(key: .lineItem("111"), quantity: 2)]), .severalShipments)
        // Both could hold one vase: Plinth can't tell which is Slant's parcel.
        XCTAssertEqual(check(orderData([first, second]), items: [ShopifySourceItem(key: .sku("VASE"), quantity: 1)]), .severalShipments)
        XCTAssertEqual(ShopifyFulfilmentCheck.severalShipments.summary,
                       "Shopify splits this order into several shipments, so Plinth can’t tell which one Slant’s parcel is. Add its tracking in Shopify.")
        XCTAssertFalse(ShopifyFulfilmentCheck.severalShipments.summary.contains("location"))
        // Any fulfillment order Plinth can't read in full stops the check.
        let cut = fulfilmentOrder(6, lines: [line(61, remaining: 1, lineItem: 222, sku: "MUG", name: "Mug")], more: true)
        XCTAssertFalse(check(orderData([first, cut]), items: [ShopifySourceItem(key: .lineItem("111"), quantity: 1)]).isReady)
        let unreadable: [String: Any] = ["id": "https://evil", "supportedActions": [["action": "CREATE_FULFILLMENT"]],
                                         "lineItems": ["pageInfo": ["hasNextPage": false], "nodes": []]]
        XCTAssertEqual(check(orderData([first, unreadable]), items: [ShopifySourceItem(key: .lineItem("111"), quantity: 1)]),
                       .unavailable("Shopify’s reply couldn’t be read. Not sent."))
        // With one fulfillment order, the allocation's own reason is kept.
        if case .unavailable(let reason) = check(orderData([first]), items: [ShopifySourceItem(key: .lineItem("111"), quantity: 2)]) {
            XCTAssertTrue(reason.contains("unfulfilled unit"), reason)
        } else { XCTFail("too few units is never ready") }
    }

    // MARK: A2-9 · Statuses and not found

    func testNothingToFulfilAndNotFoundWording() {
        let none = check(orderData([fulfilmentOrder(5, lines: [], fulfillable: false)], status: "FULFILLMENT_NOT_REQUIRED"),
                         items: [ShopifySourceItem(key: .lineItem("111"), quantity: 1)])
        XCTAssertEqual(none, .unavailable("Shopify shows nothing left to fulfil in this order (removed or refunded). Not sent."))
        XCTAssertEqual(check(orderData([], status: "FULFILLED"), items: [ShopifySourceItem(key: .lineItem("1"), quantity: 1)]), .alreadyFulfilled)
        XCTAssertTrue(ShopifyFulfilmentCheck.notFound.summary.contains("60 days"))
    }

    // MARK: A2-5, A2-6 · Carrier names

    private func entry(_ id: String = "S1", provider: String? = "UPS", numbers: [String] = ["X1"], status: String = "SHIPPED") -> ShopFollowUpEntry {
        ShopFollowUpEntry(id: id, slantOrderNumber: id, marketplaceID: "#1001", source: "shopify", recipientFirstName: nil,
                          provider: provider, trackingNumbers: numbers, status: status, created: nil)
    }

    func testCarrierNamesMatchShopifysListExactly() {
        XCTAssertEqual(shopifyTrackingCompanyName("LASERSHIP"), "Lasership")
        XCTAssertEqual(shopifyTrackingCompanyName("LaserShip"), "Lasership")
        XCTAssertEqual(shopifyTrackingCompanyName("Amazon Logistics"), "Amazon Logistics", "no “Amazon Logistics US” in Shopify's list")
        XCTAssertEqual(shopifyTrackingCompanyName("La Poste"), "La Poste", "never renamed to a name Shopify doesn't list")
        XCTAssertEqual(shopifyTrackingCompanyName("DHL eCommerce"), "DHL eCommerce")
        XCTAssertEqual(detectCarrier("RR202401015CH").carrier?.shopifyCompany, "Swiss Post")
        XCTAssertEqual(detectCarrier("RR202401015CH").carrier?.name, "Swiss Post")
        XCTAssertNil(detectCarrier("RR202401015JP").carrier?.shopifyCompany)
    }

    func testTheTrackingCSVAndSendNameTheCompanyAlike() {
        XCTAssertEqual(shopifyTrackingCSVRows([entry(provider: "fedex")]).first?.last, "FedEx")
        XCTAssertEqual(shopifyTrackingCSVRows([entry(provider: "DHL")]).first?.last, "DHL")
        XCTAssertEqual(shopifyTrackingCSVRows([entry(provider: "SHIPPO")]).first?.last, "", "a label service is never the company")
        for provider in ["fedex", "DHL", "lasership", "SHIPPO", "Local Courier"] {
            let candidate = shopifyTrackingCandidates([entry(provider: provider)], done: []).first
            XCTAssertEqual(candidate?.company, shopifyTrackingCSVRows([entry(provider: provider)]).first?.last, provider)
        }
    }

    // MARK: B3-4 · Cancelled Slant orders

    func testCancelledSlantOrdersAreNeverOffered() {
        let entries = [entry("A", status: "CANCELLED"), entry("B", status: " canceled "), entry("C", status: "CANCELED"),
                       entry("D", status: "SHIPPED"), entry("E", status: "PRINTING")]
        XCTAssertEqual(shopifyTrackingCandidates(entries, done: []).map(\.id), ["D", "E"])
    }

    // MARK: A2-7, A2-8 · Wording

    func testForbiddenAndScopeWording() {
        let forbidden = ShopifyError.http(status: 403, message: "").errorDescription ?? ""
        XCTAssertFalse(forbidden.lowercased().contains("scope"), forbidden)
        XCTAssertTrue(forbidden.contains("IP allowlist"), forbidden)
        XCTAssertFalse(shopifyMutationOutcomeUnknown(ShopifyError.http(status: 403, message: "")), "a 403 is still a refusal")
        let line = shopifyScopeStatusLine(ShopifyScopeSummary(canReadOrders: false, canFulfil: true))
        XCTAssertTrue(line.contains("read_orders") && line.contains("send tracking"), line)
        XCTAssertFalse(line.contains("can send tracking"), line)
    }

    // MARK: B3-1 · Stopping before a send

    func testStopRules() {
        let rows: [(Bool, Bool, Bool, Int, Int, Bool)] = [
            // stopRequested, cancelled, shopMatches, unknown, refusedInRow → stop
            (false, false, true, 0, 0, false),
            (true, false, true, 0, 0, true),
            (false, true, true, 0, 0, true),
            (false, false, false, 0, 0, true),
            (false, false, true, 1, 0, true),
            (false, false, true, 0, shopifyTrackingMaxConsecutiveRefusals - 1, false),
            (false, false, true, 0, shopifyTrackingMaxConsecutiveRefusals, true),
        ]
        for (stop, cancelled, matches, unknown, refused, expected) in rows {
            XCTAssertEqual(shopifyTrackingShouldStop(stopRequested: stop, cancelled: cancelled, shopMatches: matches,
                                                     unknown: unknown, refusedInRow: refused), expected,
                           "\(stop) \(cancelled) \(matches) \(unknown) \(refused)")
        }
    }

    // MARK: B3-8 · A failed re-check

    func testAFailedRecheckIsNotASuccess() {
        XCTAssertTrue(shopifyTrackingRunSucceeded(refused: 0, unknown: 0, checkFailed: false))
        XCTAssertFalse(shopifyTrackingRunSucceeded(refused: 0, unknown: 0, checkFailed: true))
        XCTAssertFalse(shopifyTrackingRunSucceeded(refused: 1, unknown: 0, checkFailed: false))
        XCTAssertFalse(shopifyTrackingRunSucceeded(refused: 0, unknown: 1, checkFailed: false))
        XCTAssertEqual(shopifyTrackingActivityDetail(sent: 1, refused: 0, unknown: 0, skipped: 0, checkFailed: true),
                       "1 sent, stopped: Shopify couldn’t be read")
        XCTAssertEqual(shopifyTrackingActivityDetail(sent: 2, refused: 0, unknown: 0, skipped: 1), "2 sent, 1 not needed")
    }
}

// MARK: - Stubbed transport (B3-10)

/// Answers requests to the shop by path and records every URL asked for. A route may redirect to `elsewhere`, which
/// answers 200 so a followed redirect would show.
final class ShopifyStubProtocol: URLProtocol {
    enum Route { case redirect, reply(Int, String) }
    static let elsewhere = URL(string: "https://elsewhere.example.net/landing")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var routes: [String: Route] = [:]
    nonisolated(unsafe) private static var seen: [URL] = []

    static func reset(_ newRoutes: [String: Route]) { lock.lock(); routes = newRoutes; seen = []; lock.unlock() }
    static var requested: [URL] { lock.lock(); defer { lock.unlock() }; return seen }
    static func count(path: String) -> Int { requested.filter { $0.path == path }.count }
    static var reachedElsewhere: Bool { requested.contains { $0.host == elsewhere.host } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.seen.append(url); let route = Self.routes[url.path]; Self.lock.unlock()
        if url.host == Self.elsewhere.host {
            return finish(200, #"{"access_token":"shpat_elsewhere","scope":"read_orders","data":{}}"#)
        }
        switch route {
        case .redirect?:
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": Self.elsewhere.absoluteString, "Content-Length": "0"])!
            var next = URLRequest(url: Self.elsewhere)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            // When the session refuses the redirect, the 3xx itself is the reply.
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .reply(let status, let body)?:
            finish(status, body)
        case nil:
            finish(404, #"{"errors":"Not Found"}"#)
        }
    }

    override func stopLoading() {}

    private func finish(_ status: Int, _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}

@MainActor
final class ShopifyClientTransportTests: XCTestCase {
    private let shop = "prints.myshopify.com"
    private let tokenPath = "/admin/oauth/access_token"
    private var graphQLPath: String { "/admin/api/\(shopifyAPIVersion)/graphql.json" }

    private func client(_ credential: ShopifyCredential) throws -> ShopifyClient {
        try XCTUnwrap(ShopifyClient(shop: shop, credential: credential, protocolClasses: [ShopifyStubProtocol.self]))
    }

    func testATokenRequestIsNeverRedirected() async throws {
        ShopifyStubProtocol.reset([tokenPath: .redirect, graphQLPath: .reply(200, #"{"data":{"shop":{"name":"P"}}}"#)])
        let client = try client(.app(clientID: "client-id-0000", clientSecret: "client-secret-0000"))
        do {
            _ = try await client.query("query { shop { name } }")
            XCTFail("a redirected token request must fail")
        } catch ShopifyError.tokenRefused(let message) {
            XCTAssertTrue(message.contains("302"), message)
            XCTAssertFalse(message.contains("client-secret-0000"))
        }
        XCTAssertFalse(ShopifyStubProtocol.reachedElsewhere, "the redirect was followed")
        XCTAssertEqual(ShopifyStubProtocol.count(path: graphQLPath), 0, "nothing goes out without a token")
    }

    func testAMutationIsNeverRedirectedAndItsOutcomeIsUnknown() async throws {
        ShopifyStubProtocol.reset([graphQLPath: .redirect])
        let client = try client(.accessToken("shpat_test_0000"))
        do {
            _ = try await client.mutate(shopifyFulfillmentCreateMutation, variables: ["fulfillment": ["notifyCustomer": false]])
            XCTFail("a redirected mutation must fail")
        } catch {
            XCTAssertEqual(error as? ShopifyError, .http(status: 302, message: ""))
            XCTAssertTrue(shopifyMutationOutcomeUnknown(error))
            if case .unknown = shopifyTrackingOutcome(error: error) {} else { XCTFail("a redirected send is unconfirmed") }
        }
        XCTAssertFalse(ShopifyStubProtocol.reachedElsewhere, "the redirect was followed")
        XCTAssertEqual(ShopifyStubProtocol.count(path: graphQLPath), 1, "sent once, never again")
    }

    func testAMutationReplyWithDataAndErrorsIsUnknown() async throws {
        ShopifyStubProtocol.reset([graphQLPath: .reply(200, #"{"data":{"fulfillmentCreate":{"fulfillment":{"id":"gid://shopify/Fulfillment/1"},"userErrors":[]}},"errors":[{"message":"Something else","extensions":{"code":"SOME_OTHER_CODE"}}]}"#)])
        let client = try client(.accessToken("shpat_test_0000"))
        do {
            _ = try await client.mutate(shopifyFulfillmentCreateMutation, variables: ["fulfillment": ["notifyCustomer": false]])
            XCTFail("an error reply must throw")
        } catch {
            if case .unknown = shopifyTrackingOutcome(error: error) {} else { XCTFail("it may have run: \(error)") }
        }
        XCTAssertEqual(ShopifyStubProtocol.count(path: graphQLPath), 1)
    }

    func testAMutationRefusedBeforeRunningIsRefused() async throws {
        ShopifyStubProtocol.reset([graphQLPath: .reply(200, #"{"errors":[{"message":"Field 'nope' doesn't exist","extensions":{"code":"undefinedField"}}]}"#)])
        let client = try client(.accessToken("shpat_test_0000"))
        do {
            _ = try await client.mutate(shopifyFulfillmentCreateMutation, variables: ["fulfillment": ["notifyCustomer": false]])
            XCTFail("an error reply must throw")
        } catch {
            if case .refused = shopifyTrackingOutcome(error: error) {} else { XCTFail("failed validation is a refusal: \(error)") }
        }
        // The same reply to a read is just its error, as before.
        do {
            _ = try await client.query("query { nope }")
            XCTFail()
        } catch {
            XCTAssertEqual(error as? ShopifyError, .graphQL(messages: ["Field 'nope' doesn't exist"], codes: ["undefinedField"]))
        }
    }

    func testAMutationStoppedAfterItsWaitSendsNothing() async throws {
        ShopifyStubProtocol.reset([graphQLPath: .reply(200, #"{"data":{"fulfillmentCreate":{"fulfillment":{"id":"gid://shopify/Fulfillment/1"},"userErrors":[]}}}"#)])
        let client = try client(.accessToken("shpat_test_0000"))
        do {
            _ = try await client.mutate(shopifyFulfillmentCreateMutation, variables: ["fulfillment": ["notifyCustomer": false]]) { false }
            XCTFail("a stopped mutation must not be sent")
        } catch {
            XCTAssertEqual(error as? ShopifyError, .notSent("Stopped before anything was sent to Shopify."))
            XCTAssertFalse(shopifyMutationOutcomeUnknown(error))
        }
        XCTAssertTrue(ShopifyStubProtocol.requested.isEmpty, "nothing reached Shopify")
    }

    func testScopesAreReadAgainWithAFreshTokenOnlyWhenNeeded() async throws {
        ShopifyStubProtocol.reset([
            tokenPath: .reply(200, #"{"access_token":"shpat_token_0000","scope":"read_orders","expires_in":86399}"#),
            graphQLPath: .reply(200, #"{"data":{"currentAppInstallation":{"accessScopes":[{"handle":"read_orders"}]}}}"#)
        ])
        let client = try client(.app(clientID: "client-id-0000", clientSecret: "client-secret-0000"))
        let scopes = try await client.accessScopes()
        XCTAssertEqual(scopes, ["read_orders"])
        XCTAssertEqual(ShopifyStubProtocol.count(path: tokenPath), 1)
        // Remembered: no second read.
        _ = try await client.accessScopes()
        XCTAssertEqual(ShopifyStubProtocol.count(path: graphQLPath), 1)
        // Can't fulfil: Send Tracking's check reads them again, with a new token.
        XCTAssertTrue(shopifyScopesNeedReread(client.grantedScopes))
        client.forgetScopes()
        _ = try await client.accessScopes()
        XCTAssertEqual(ShopifyStubProtocol.count(path: tokenPath), 2)
        XCTAssertEqual(ShopifyStubProtocol.count(path: graphQLPath), 2)
        // Test Connection's live scopes: the same ones keep the token; a newly granted one replaces it.
        client.noteScopes(["read_orders"])
        _ = try await client.query("query { shop { name } }")
        XCTAssertEqual(ShopifyStubProtocol.count(path: tokenPath), 2)
        client.noteScopes(["read_orders", "write_merchant_managed_fulfillment_orders"])
        XCTAssertFalse(shopifyScopesNeedReread(client.grantedScopes))
        _ = try await client.query("query { shop { name } }")
        XCTAssertEqual(ShopifyStubProtocol.count(path: tokenPath), 3)
        XCTAssertFalse(ShopifyStubProtocol.reachedElsewhere)
    }
}
