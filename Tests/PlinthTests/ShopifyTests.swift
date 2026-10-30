import XCTest
@testable import SlantStudio

final class ShopifyTests: XCTestCase {
    private func json(_ text: String) -> [String: Any] {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    // MARK: Shop address

    func testShopDomainAcceptsHandlesAndMyshopifyAddresses() {
        XCTAssertEqual(shopifyShopDomain("my-shop"), "my-shop.myshopify.com")
        XCTAssertEqual(shopifyShopDomain("  My-Shop.myshopify.com "), "my-shop.myshopify.com")
        XCTAssertEqual(shopifyShopDomain("https://my-shop.myshopify.com/admin/orders"), "my-shop.myshopify.com")
        XCTAssertEqual(shopifyShopDomain("https://admin.shopify.com/store/my-shop/orders"), "my-shop.myshopify.com")
        XCTAssertEqual(shopifyShopDomain("shop2"), "shop2.myshopify.com")
    }

    func testShopDomainRefusesOtherHosts() {
        for bad in ["", "shop.example.com", "https://evil.com/my-shop.myshopify.com", "my-shop.myshopify.com.evil.com",
                    "user@my-shop.myshopify.com", "my-shop.myshopify.com:8443", "my shop", "-shop", "shop-",
                    "my_shop", "my-shop.myshopify.com?x=1", "admin.shopify.com/settings", "evil.com/x",
                    "my-shop.myshopify.com#frag", "%6dy-shop.myshopify.com", String(repeating: "a", count: 64)] {
            XCTAssertNil(shopifyShopDomain(bad), bad)
        }
    }

    func testEndpointsStayOnTheValidatedHost() {
        XCTAssertEqual(shopifyGraphQLURL(shop: "my-shop.myshopify.com")?.absoluteString,
                       "https://my-shop.myshopify.com/admin/api/\(shopifyAPIVersion)/graphql.json")
        XCTAssertEqual(shopifyTokenURL(shop: "my-shop.myshopify.com")?.absoluteString,
                       "https://my-shop.myshopify.com/admin/oauth/access_token")
        XCTAssertNil(shopifyGraphQLURL(shop: "evil.com"))
        XCTAssertNil(shopifyTokenURL(shop: "my-shop"))
    }

    // MARK: Credentials

    func testCredentialFieldChecks() {
        XCTAssertNotNil(shopifyCredentialFieldProblem("", name: "client ID"))
        XCTAssertNotNil(shopifyCredentialFieldProblem("abc def", name: "client ID"))
        XCTAssertNotNil(shopifyCredentialFieldProblem(String(repeating: "a", count: 300), name: "client ID"))
        XCTAssertNil(shopifyCredentialFieldProblem("  0123456789abcdef\n", name: "client ID"))
        guard case .success(.app(let id, let secret)) = shopifyFormCredential(kind: .app, clientID: " id1 ", clientSecret: "shpss_1\n", accessToken: "") else {
            return XCTFail("expected app credential")
        }
        XCTAssertEqual(id, "id1")
        XCTAssertEqual(secret, "shpss_1")
        guard case .failure = shopifyFormCredential(kind: .accessToken, clientID: "x", clientSecret: "y", accessToken: " ") else {
            return XCTFail("expected a problem")
        }
    }

    func testStoredConnectionRoundTrip() throws {
        let app = ShopifyStoredConnection(shop: "a.myshopify.com", credential: .app(clientID: "id", clientSecret: "secret"))
        let decoded = try JSONDecoder().decode(ShopifyStoredConnection.self, from: JSONEncoder().encode(app))
        XCTAssertEqual(decoded.credential, .app(clientID: "id", clientSecret: "secret"))
        let token = ShopifyStoredConnection(shop: "a.myshopify.com", credential: .accessToken("shpat_abc"))
        XCTAssertEqual(token.credential, .accessToken("shpat_abc"))
        XCTAssertNil(token.clientSecret)
    }

    func testTokenRequestIsFormEncoded() {
        let body = String(decoding: shopifyTokenRequestBody(clientID: "abc", clientSecret: "s+cr&t=1"), as: UTF8.self)
        XCTAssertEqual(body, "grant_type=client_credentials&client_id=abc&client_secret=s%2Bcr%26t%3D1")
    }

    func testTokenResponseParsing() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let token = try shopifyAccessToken(fromTokenResponse: Data(#"{"access_token":"shpat_tok","scope":"read_orders,write_merchant_managed_fulfillment_orders","expires_in":86399}"#.utf8), now: now)
        XCTAssertEqual(token.value, "shpat_tok")
        XCTAssertEqual(token.scopes, ["read_orders", "write_merchant_managed_fulfillment_orders"])
        XCTAssertEqual(token.expires, now.addingTimeInterval(86_399 - 60))
        XCTAssertThrowsError(try shopifyAccessToken(fromTokenResponse: Data(#"{"error":"invalid_client"}"#.utf8)))
        XCTAssertTrue(shopifyScopeSummary(token.scopes).canFulfil)
        XCTAssertEqual(shopifyScopeSummary(["read_orders"]), ShopifyScopeSummary(canReadOrders: true, canFulfil: false))
    }

    func testTokenRefusalMessagesNeverEchoTheSecret() {
        let secret = "shpss_supersecretvalue"
        let message = shopifyTokenRefusalMessage(status: 400, body: #"{"error":"weird","client_secret":"\#(secret)"}"#, secrets: [secret, "client123"])
        XCTAssertFalse(message.contains(secret))
        XCTAssertTrue(shopifyTokenRefusalMessage(status: 400, body: "Oauth error shop_not_permitted: Client credentials cannot be performed on this shop.", secrets: []).contains("organisation"))
        XCTAssertTrue(shopifyTokenRefusalMessage(status: 401, body: "", secrets: []).contains("client ID or secret"))
    }

    // MARK: Redaction

    func testRedactionRemovesTokensSecretsAndLongText() {
        let text = "Failed with X-Shopify-Access-Token shpat_0123456789abcdef and {\"access_token\":\"abc123\"} for client 9f8e7d6c\nsecond line"
        let redacted = shopifyRedacted(text, secrets: ["9f8e7d6c"])
        XCTAssertFalse(redacted.contains("shpat_0123456789abcdef"))
        XCTAssertFalse(redacted.contains("abc123"))
        XCTAssertFalse(redacted.contains("9f8e7d6c"))
        XCTAssertFalse(redacted.contains("\n"))
        XCTAssertTrue(redacted.contains("[redacted]"))
        XCTAssertLessThanOrEqual(shopifyRedacted(String(repeating: "x", count: 1000)).count, 241)
        // Short values aren't treated as secrets, so ordinary words survive.
        XCTAssertEqual(shopifyRedacted("abc", secrets: ["ab"]), "abc")
    }

    // MARK: Replies and throttle

    func testGraphQLErrorsAreClassified() {
        XCTAssertNil(shopifyGraphQLError(fromResponse: json(#"{"data":{}}"#)))
        XCTAssertEqual(shopifyGraphQLError(fromResponse: json(#"{"errors":[{"message":"Throttled","extensions":{"code":"THROTTLED"}}]}"#)), .throttled)
        XCTAssertEqual(shopifyGraphQLError(fromResponse: json(#"{"data":{"orders":null},"errors":[{"message":"This app is not approved to access the Customer object.","path":["orders"]}]}"#)),
                       .protectedCustomerData)
        let denied = shopifyGraphQLError(fromResponse: json(#"{"errors":[{"message":"Access denied for orders field.","extensions":{"code":"ACCESS_DENIED"}}]}"#))
        XCTAssertEqual(denied, .graphQL(messages: ["Access denied for orders field."], codes: ["ACCESS_DENIED"]))
        XCTAssertEqual(shopifyGraphQLError(fromResponse: json(#"{"errors":"[API] Invalid API key or access token (unrecognized login or wrong password)"}"#)),
                       .graphQL(messages: ["[API] Invalid API key or access token (unrecognized login or wrong password)"], codes: []))
    }

    func testThrottleStatusAndWait() {
        let now = Date(timeIntervalSince1970: 5_000)
        let root = json(#"{"extensions":{"cost":{"requestedQueryCost":620,"actualQueryCost":120,"throttleStatus":{"maximumAvailable":2000,"currentlyAvailable":100,"restoreRate":100}}}}"#)
        let status = shopifyThrottleStatus(fromResponse: root, now: now)
        XCTAssertEqual(status, ShopifyThrottleStatus(maximumAvailable: 2000, currentlyAvailable: 100, restoreRate: 100, observedAt: now))
        XCTAssertEqual(shopifyRequestedCost(fromResponse: root), 620)
        XCTAssertEqual(shopifyThrottleWait(cost: 620, status: status, now: now), 6)
        // Two seconds later 200 points have come back.
        XCTAssertEqual(shopifyThrottleWait(cost: 620, status: status, now: now.addingTimeInterval(2)), 4)
        XCTAssertEqual(shopifyThrottleWait(cost: 50, status: status, now: now), 0)
        XCTAssertEqual(shopifyThrottleWait(cost: 620, status: nil, now: now), 0)
        // Never longer than the cap, and a cost above the bucket only waits for a full bucket.
        let slow = ShopifyThrottleStatus(maximumAvailable: 1000, currentlyAvailable: 0, restoreRate: 1, observedAt: now)
        XCTAssertEqual(shopifyThrottleWait(cost: 5000, status: slow, now: now), shopifyMaxThrottleWait)
        let stuck = ShopifyThrottleStatus(maximumAvailable: 1000, currentlyAvailable: 0, restoreRate: 0, observedAt: now)
        XCTAssertEqual(shopifyThrottleWait(cost: 10, status: stuck, now: now), shopifyMaxThrottleWait)
        XCTAssertEqual(shopifyRetryAfterSeconds("2.0"), 2)
        XCTAssertEqual(shopifyRetryAfterSeconds("9999"), shopifyMaxThrottleWait)
        XCTAssertNil(shopifyRetryAfterSeconds("soon"))
    }

    func testMutationOutcomeClassification() {
        XCTAssertTrue(shopifyMutationOutcomeUnknown(ShopifyError.transport("timed out")))
        XCTAssertTrue(shopifyMutationOutcomeUnknown(ShopifyError.http(status: 502, message: "")))
        XCTAssertTrue(shopifyMutationOutcomeUnknown(ShopifyError.http(status: 408, message: "")))
        XCTAssertTrue(shopifyMutationOutcomeUnknown(ShopifyError.invalidResponse("x")))
        XCTAssertTrue(shopifyMutationOutcomeUnknown(ShopifyError.graphQL(messages: ["x"], codes: ["INTERNAL_SERVER_ERROR"])))
        XCTAssertFalse(shopifyMutationOutcomeUnknown(ShopifyError.http(status: 403, message: "")))
        XCTAssertFalse(shopifyMutationOutcomeUnknown(ShopifyError.throttled))
        XCTAssertFalse(shopifyMutationOutcomeUnknown(ShopifyError.graphQL(messages: ["x"], codes: ["ACCESS_DENIED"])))
        XCTAssertFalse(shopifyMutationOutcomeUnknown(ShopifyError.tokenRefused("no")))
        XCTAssertFalse(shopifyMutationOutcomeUnknown(CancellationError()))
    }

    func testConnectionTestMustBeTheTypedStore() throws {
        let data = json(#"{"shop":{"name":"Prints Ltd","myshopifyDomain":"prints.myshopify.com"},"currentAppInstallation":{"accessScopes":[{"handle":"read_orders"},{"handle":"write_merchant_managed_fulfillment_orders"}]}}"#)
        let result = try shopifyConnectionTest(data, expectedShop: "prints.myshopify.com")
        XCTAssertEqual(result.shopName, "Prints Ltd")
        XCTAssertEqual(result.scopes, ShopifyScopeSummary(canReadOrders: true, canFulfil: true))
        XCTAssertThrowsError(try shopifyConnectionTest(data, expectedShop: "other.myshopify.com"))
        XCTAssertEqual(shopifyScopeStatusLine(ShopifyScopeSummary(canReadOrders: true, canFulfil: false)).contains("write_merchant_managed_fulfillment_orders"), true)
    }

    // MARK: Import

    private let pageFixture = #"""
    {
      "orders": {
        "pageInfo": { "hasNextPage": true, "endCursor": "eyJsYXN0X2lkIjo0NTY3fQ==" },
        "nodes": [
          {
            "name": "#1001", "email": "ana@example.com", "createdAt": "2026-10-20T09:00:00Z", "cancelledAt": null,
            "displayFinancialStatus": "PAID", "displayFulfillmentStatus": "UNFULFILLED",
            "shippingAddress": { "name": "Ana Lima", "firstName": "Ana", "lastName": "Lima", "company": null,
              "address1": "1 Main St", "address2": "Apt 2", "city": "Springfield", "province": "California",
              "provinceCode": "CA", "zip": "02134", "countryCodeV2": "US" },
            "lineItems": { "pageInfo": { "hasNextPage": false }, "nodes": [
              { "name": "Vase - Blue", "sku": "VASE-BLU", "quantity": 3, "currentQuantity": 2,
                "customAttributes": [ { "key": "_hidden", "value": "x" } ] },
              { "name": "Removed thing", "sku": "GONE", "quantity": 1, "currentQuantity": 0, "customAttributes": [] },
              { "name": "Name tag", "sku": "", "quantity": 1, "currentQuantity": 1,
                "customAttributes": [ { "key": "Engraving", "value": "Emma" } ] }
            ] }
          },
          {
            "name": "#1002", "email": null, "createdAt": "2026-10-21T09:00:00Z", "cancelledAt": null,
            "displayFinancialStatus": "PAID", "displayFulfillmentStatus": "UNFULFILLED",
            "shippingAddress": { "name": "", "firstName": "Bo", "lastName": "Chen", "company": "Chen Co",
              "address1": "2 High St", "address2": null, "city": "London", "province": null,
              "provinceCode": null, "zip": "SW1A 1AA", "countryCodeV2": "GB" },
            "lineItems": { "pageInfo": { "hasNextPage": false }, "nodes": [
              { "name": "Mug", "sku": "MUG", "quantity": 1, "currentQuantity": 1,
                "customAttributes": [ { "key": "Personalization", "value": "Happy birthday" }, { "key": "Colour", "value": "Red" } ] }
            ] }
          },
          {
            "name": "#1003", "email": "c@example.com", "createdAt": "2026-10-22T09:00:00Z", "cancelledAt": null,
            "displayFinancialStatus": "PAID", "displayFulfillmentStatus": "UNFULFILLED", "shippingAddress": null,
            "lineItems": { "pageInfo": { "hasNextPage": true }, "nodes": [] }
          },
          {
            "name": "#1001", "email": "ana@example.com", "shippingAddress": null,
            "lineItems": { "pageInfo": { "hasNextPage": false }, "nodes": [] }
          }
        ]
      }
    }
    """#

    func testOrdersPageAndConversionMatchTheCSVStructures() throws {
        let page = try shopifyOrdersPage(json(pageFixture))
        XCTAssertEqual(page.nodes.count, 4)
        XCTAssertTrue(page.hasNextPage)
        XCTAssertEqual(page.endCursor, "eyJsYXN0X2lkIjo0NTY3fQ==")
        let parse = try shopifyImportParse(page.nodes, shop: "prints.myshopify.com", truncated: false)
        XCTAssertEqual(parse.format, .shopify)
        XCTAssertEqual(parse.orders.map(\.sourceOrderID), ["#1001", "#1002"])
        XCTAssertTrue(parse.notices.contains { $0.contains("#1003") && $0.contains("more than") })
        let first = parse.orders[0]
        // Same ledger key as a CSV import of the same order.
        XCTAssertEqual(first.id, OrderImportLedger.key(source: .shopify, sourceOrderID: "#1001"))
        XCTAssertEqual(first.name, "Ana Lima")
        XCTAssertEqual(first.email, "ana@example.com")
        XCTAssertEqual(first.line1, "1 Main St")
        XCTAssertEqual(first.line2, "Apt 2")
        XCTAssertEqual(first.state, "CA")
        XCTAssertEqual(first.zip, "02134")
        XCTAssertEqual(first.countryCode, "US")
        XCTAssertNil(first.alreadyHandled)
        // The removed line is left out; current quantities are used.
        XCTAssertEqual(first.items.map(\.sku), ["VASE-BLU", ""])
        XCTAssertEqual(first.items.map(\.quantityText), ["2", "1"])
        XCTAssertEqual(first.items[0].personalisation, "")
        XCTAssertEqual(first.items[1].personalisation, "Engraving: Emma")
        let second = parse.orders[1]
        XCTAssertEqual(second.name, "Bo Chen")
        XCTAssertEqual(second.email, "")
        XCTAssertEqual(second.company, "Chen Co")
        XCTAssertEqual(second.state, "")
        XCTAssertEqual(second.countryCode, "GB")
        XCTAssertEqual(second.items[0].personalisation, "Happy birthday")
        XCTAssertEqual(second.items[0].options, "Personalization: Happy birthday, Colour: Red")
    }

    func testConvertedOrdersGoThroughTheImportChecks() throws {
        let page = try shopifyOrdersPage(json(pageFixture))
        let parse = try shopifyImportParse(page.nodes, shop: "prints.myshopify.com", truncated: true)
        XCTAssertTrue(parse.notices.contains { $0.contains("\(shopifyImportMaxOrders)") })
        var ledger = OrderImportLedger()
        ledger.record(.created(orderID: "SLANT_9"), source: .shopify, sourceOrderID: "#1001")
        let check = orderImportCheck(parse.orders[0], context: OrderImportContext(products: [], platformID: "p1", ledger: ledger))
        XCTAssertTrue(check.warnings.contains(orderImportAlreadyImportedWarning("SLANT_9")))
        XCTAssertTrue(check.blockers.contains { $0.contains("VASE-BLU") })
        XCTAssertNil(check.body)
        // The email falls back exactly as for a CSV without one.
        let noEmail = orderImportCheck(parse.orders[1], context: OrderImportContext(products: [], platformID: "p1"))
        XCTAssertTrue(noEmail.blockers.contains(orderImportMissingEmailBlocker))
    }

    func testAlreadyHandledOrdersAreFlagged() {
        var row = 1
        let refunded = shopifyImportOrder(json(##"{"name":"#7","displayFinancialStatus":"REFUNDED","displayFulfillmentStatus":"UNFULFILLED","lineItems":{"nodes":[]}}"##), nextRow: &row)
        XCTAssertEqual(refunded.order?.alreadyHandled, "Shopify shows this order as refunded.")
        let cancelled = shopifyImportOrder(json(##"{"name":"#8","cancelledAt":"2026-10-01T00:00:00Z","lineItems":{"nodes":[]}}"##), nextRow: &row)
        XCTAssertEqual(cancelled.order?.alreadyHandled, "Shopify shows this order as cancelled.")
        let nameless = shopifyImportOrder(json(#"{"name":"  "}"#), nextRow: &row)
        XCTAssertNil(nameless.order)
        XCTAssertNotNil(nameless.leftOut)
        XCTAssertThrowsError(try shopifyImportParse([], shop: "a.myshopify.com", truncated: false))
    }

    func testPaginationCursorHandling() {
        let more = ShopifyOrdersPage(nodes: [], hasNextPage: true, endCursor: "c2")
        XCTAssertEqual(shopifyNextCursor(more, used: ["c1"], fetched: 10), "c2")
        XCTAssertNil(shopifyNextCursor(more, used: ["c2"], fetched: 10), "a repeated cursor would loop")
        XCTAssertNil(shopifyNextCursor(more, used: [], fetched: shopifyImportMaxOrders))
        XCTAssertNil(shopifyNextCursor(ShopifyOrdersPage(nodes: [], hasNextPage: false, endCursor: "c3"), used: [], fetched: 0))
        XCTAssertNil(shopifyNextCursor(ShopifyOrdersPage(nodes: [], hasNextPage: true, endCursor: nil), used: [], fetched: 0))
        XCTAssertNil(try? shopifyOrdersPage(["orders": "nope"]))
        let empty = try? shopifyOrdersPage(json(#"{"orders":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[]}}"#))
        XCTAssertNil(empty?.endCursor)
        XCTAssertEqual(shopifyImportVariables(after: nil, searchQuery: "q")["after"] as? String, nil)
        XCTAssertEqual(shopifyImportVariables(after: "c9", searchQuery: "q")["after"] as? String, "c9")
        XCTAssertEqual(shopifyImportVariables(after: nil, searchQuery: "q")["first"] as? Int, shopifyImportPageSize)
    }

    func testSearchQueryCoversTheLastSixtyDays() {
        let now = ISO8601DateFormatter().date(from: "2026-10-24T01:00:00Z")!
        XCTAssertEqual(shopifyImportSearchQuery(now: now),
                       "financial_status:paid fulfillment_status:unfulfilled status:open created_at:>=2026-08-25")
    }

    // MARK: Tracking

    private func entry(_ id: String, source: String? = "shopify", reference: String? = "#1001", numbers: [String] = ["1Z999"],
                       provider: String? = "UPS") -> ShopFollowUpEntry {
        ShopFollowUpEntry(id: id, slantOrderNumber: id, marketplaceID: reference, source: source, recipientFirstName: "Ana",
                          provider: provider, trackingNumbers: numbers, status: "SHIPPED", created: nil)
    }

    func testTrackingCandidatesAreImportedShopifyOrdersWithTracking() {
        let entries = [entry("S1"), entry("S2", source: "etsy"), entry("S3", reference: nil), entry("S4", numbers: []),
                       entry("S5", reference: " #1005 ", provider: "SHIPPO"), entry("S6"), entry("S1")]
        let candidates = shopifyTrackingCandidates(entries, done: ["S6"])
        XCTAssertEqual(candidates.map(\.id), ["S1", "S5"])
        XCTAssertEqual(candidates[1].orderName, "#1005")
        XCTAssertEqual(candidates[1].company, "", "label services aren't carriers")
        XCTAssertEqual(candidates[0].company, "UPS")
        let many = (0..<80).map { entry("M\($0)") }
        XCTAssertEqual(shopifyTrackingCandidates(many, done: []).count, shopifyTrackingMaxOrders)
    }

    func testCarrierNamesUseShopifySpelling() {
        XCTAssertEqual(shopifyTrackingCompanyName("fedex"), "FedEx")
        XCTAssertEqual(shopifyTrackingCompanyName("Royal Mail"), "Royal Mail")
        XCTAssertEqual(shopifyTrackingCompanyName("royal_mail"), "Royal Mail")
        XCTAssertEqual(shopifyTrackingCompanyName("DHL"), "DHL Express")
        XCTAssertEqual(shopifyTrackingCompanyName(" Local Courier "), "Local Courier")
        XCTAssertEqual(shopifyTrackingCompanyName(""), "")
    }

    func testOrderNameSearchAndExactMatch() {
        XCTAssertEqual(shopifyOrderNameSearch(" #1001 "), "name:\"#1001\"")
        XCTAssertNil(shopifyOrderNameSearch("#10\"01"))
        XCTAssertNil(shopifyOrderNameSearch("a\\b"))
        XCTAssertNil(shopifyOrderNameSearch(""))
        let found = json(##"{"orders":{"nodes":[{"id":"gid://shopify/Order/2","name":"#10010"},{"id":"gid://shopify/Order/1","name":"#1001"}]}}"##)
        XCTAssertEqual(shopifyOrderID(named: "#1001", in: found), "gid://shopify/Order/1")
        XCTAssertNil(shopifyOrderID(named: "#100", in: found))
        let twice = json(##"{"orders":{"nodes":[{"id":"gid://shopify/Order/1","name":"#1"},{"id":"gid://shopify/Order/2","name":"#1"}]}}"##)
        XCTAssertNil(shopifyOrderID(named: "#1", in: twice), "an ambiguous name is never guessed")
        XCTAssertNil(shopifyOrderID(named: "#1", in: json(##"{"orders":{"nodes":[{"id":"https://evil","name":"#1"}]}}"##)))
    }

    private func checkData(cancelled: String? = nil, status: String = "UNFULFILLED", existing: [String] = [],
                           fulfillmentOrders: [[String: Any]]) -> [String: Any] {
        var order: [String: Any] = [
            "name": "#1001", "displayFulfillmentStatus": status,
            "fulfillments": existing.map { ["trackingInfo": [["number": $0]]] },
            "fulfillmentOrders": ["nodes": fulfillmentOrders]
        ]
        if let cancelled { order["cancelledAt"] = cancelled }
        return ["order": order]
    }

    private func fulfillmentOrder(_ id: Int, fulfillable: Bool = true) -> [String: Any] {
        [
            "id": "gid://shopify/FulfillmentOrder/\(id)", "status": fulfillable ? "OPEN" : "CLOSED",
            "supportedActions": fulfillable ? [["action": "CREATE_FULFILLMENT"], ["action": "HOLD"]] : [["action": "CANCEL_FULFILLMENT_ORDER"]],
            "lineItems": ["pageInfo": ["hasNextPage": false], "nodes": [
                ["id": "gid://shopify/FulfillmentOrderLineItem/\(id)1", "remainingQuantity": 2,
                 "lineItem": ["id": "gid://shopify/LineItem/71", "sku": "VASE", "name": "Vase"]],
                ["id": "gid://shopify/FulfillmentOrderLineItem/\(id)2", "remainingQuantity": 0,
                 "lineItem": ["id": "gid://shopify/LineItem/72", "sku": "DONE", "name": "Done"]]
            ]]
        ]
    }

    private let vase = [ShopifySourceItem(key: .sku("VASE"), quantity: 2)]

    private func check(_ data: [String: Any]) -> ShopifyFulfilmentCheck {
        shopifyFulfilmentCheck(data, trackingNumbers: ["1Z9"], sourceItems: vase, identity: nil)
    }

    func testFulfilmentCheck() {
        XCTAssertEqual(check(checkData(fulfillmentOrders: [fulfillmentOrder(5)])),
                       .ready(ShopifyFulfilmentPlan(fulfillmentOrderID: "gid://shopify/FulfillmentOrder/5",
                                                    lines: [ShopifyFulfilmentLine(id: "gid://shopify/FulfillmentOrderLineItem/51", quantity: 2)],
                                                    items: ["2 × Vase"], remaining: [], matchedByAddress: false)))
        XCTAssertEqual(check(checkData(existing: ["1z9"], fulfillmentOrders: [fulfillmentOrder(5)])), .alreadyHasTracking)
        XCTAssertEqual(check(checkData(status: "FULFILLED", fulfillmentOrders: [fulfillmentOrder(5, fulfillable: false)])), .alreadyFulfilled)
        XCTAssertEqual(check(checkData(cancelled: "2026-10-01T00:00:00Z", fulfillmentOrders: [fulfillmentOrder(5)])), .cancelled)
        XCTAssertEqual(check(checkData(fulfillmentOrders: [fulfillmentOrder(5), fulfillmentOrder(6)])), .severalLocations)
        if case .unavailable = check(checkData(status: "ON_HOLD", fulfillmentOrders: [fulfillmentOrder(5, fulfillable: false)])) {} else {
            XCTFail("an order on hold isn't ready")
        }
        XCTAssertEqual(check(["order": NSNull()]), .notFound)
    }

    func testFulfillmentInputPayload() {
        let plan = ShopifyFulfilmentPlan(fulfillmentOrderID: "gid://shopify/FulfillmentOrder/5",
                                         lines: [ShopifyFulfilmentLine(id: "gid://shopify/FulfillmentOrderLineItem/51", quantity: 2)],
                                         items: [], remaining: [], matchedByAddress: false)
        let one = shopifyFulfillmentInput(plan, trackingNumbers: [" 1Z9 "], company: "UPS", notifyCustomer: false)
        XCTAssertEqual(one["notifyCustomer"] as? Bool, false)
        let group = (one["lineItemsByFulfillmentOrder"] as? [[String: Any]])?.first
        XCTAssertEqual(group?["fulfillmentOrderId"] as? String, "gid://shopify/FulfillmentOrder/5")
        let lines = group?["fulfillmentOrderLineItems"] as? [[String: Any]]
        XCTAssertEqual(lines?.count, 1, "only the draft's items, never every remaining item")
        XCTAssertEqual(lines?.first?["id"] as? String, "gid://shopify/FulfillmentOrderLineItem/51")
        XCTAssertEqual(lines?.first?["quantity"] as? Int, 2)
        let tracking = one["trackingInfo"] as? [String: Any]
        XCTAssertEqual(tracking?["number"] as? String, "1Z9")
        XCTAssertEqual(tracking?["company"] as? String, "UPS")
        XCTAssertNil(tracking?["url"])
        let several = shopifyFulfillmentInput(plan, trackingNumbers: ["A", "B", ""], company: "", notifyCustomer: true)
        XCTAssertEqual((several["trackingInfo"] as? [String: Any])?["numbers"] as? [String], ["A", "B"])
        XCTAssertNil((several["trackingInfo"] as? [String: Any])?["company"])
        XCTAssertEqual(several["notifyCustomer"] as? Bool, true)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(["fulfillment": several]))
    }

    func testTrackingOutcomes() {
        XCTAssertEqual(shopifyTrackingOutcome(response: json(#"{"fulfillmentCreate":{"fulfillment":{"id":"gid://shopify/Fulfillment/1","status":"SUCCESS"},"userErrors":[]}}"#)), .sent)
        XCTAssertEqual(shopifyTrackingOutcome(response: json(#"{"fulfillmentCreate":{"fulfillment":null,"userErrors":[{"field":["fulfillment"],"message":"Fulfillment order is closed."}]}}"#)),
                       .refused("Fulfillment order is closed."))
        if case .unknown = shopifyTrackingOutcome(response: json(#"{"fulfillmentCreate":{"fulfillment":null,"userErrors":[]}}"#)) {} else { XCTFail() }
        if case .unknown = shopifyTrackingOutcome(response: [:]) {} else { XCTFail() }
        if case .unknown = shopifyTrackingOutcome(error: ShopifyError.transport("The request timed out.")) {} else { XCTFail() }
        if case .refused = shopifyTrackingOutcome(error: ShopifyError.throttled) {} else { XCTFail() }
        XCTAssertEqual(shopifyTrackingActivityDetail(sent: 2, refused: 1, unknown: 0, skipped: 3), "2 sent, 1 refused, 3 not needed")
        XCTAssertEqual(shopifyTrackingActivityDetail(sent: 1, refused: 0, unknown: 1, skipped: 0), "1 sent, 1 not confirmed")
    }
}
