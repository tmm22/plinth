import XCTest
@testable import Plinth

/// A scripted network for the ordering half of `DapiClient`: each request takes the next step, every request is
/// recorded, and a `.wait` step holds the request until the test releases it. Nothing reaches the network.
private final class ScriptedOrderTransport: DapiTransport, @unchecked Sendable {
    enum Step {
        case reply(Int, String)
        case fail(Error)
        /// Holds the request until `release()`, then answers with this reply.
        case wait(Int, String)
    }
    private let lock = NSLock()
    private var steps: [Step]
    private var waiting: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var requests: [URLRequest] = []

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> DapiHTTPReply {
        lock.lock()
        requests.append(request)
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        switch step {
        case .reply(let status, let body)?:
            return DapiHTTPReply(status: status, headers: [:], body: Data(body.utf8))
        case .fail(let error)?:
            throw error
        case .wait(let status, let body)?:
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if released {
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting = continuation
                    lock.unlock()
                }
            }
            return DapiHTTPReply(status: status, headers: [:], body: Data(body.utf8))
        case nil:
            throw URLError(.resourceUnavailable)
        }
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> DapiHTTPReply {
        XCTFail("No upload expected")
        throw URLError(.resourceUnavailable)
    }

    func release() {
        lock.lock()
        released = true
        let continuation = waiting
        waiting = nil
        lock.unlock()
        continuation?.resume()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var sentRequests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

private let orderTestKey = "sk_0000000000test0000000000000000000000000000000000000000000000000"

private func json(_ request: URLRequest) -> [String: Any]? {
    request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
}

private func errorBody(_ status: Int, _ code: String, message: String = "Refused.", details: String = "{}") -> String {
    #"{"status_code":\#(status),"error":"Error","code":"\#(code)","message":"\#(message)","details":\#(details)}"#
}

/// A spec-shaped `IntegratorOrder` with made-up IDs and details only.
private func orderJSON(id: String = "ord_TestOrder0001", status: String = "paid", reference: String? = "plinth-test-0001",
                       items: Bool = true, customer: Bool = true) -> String {
    let ref = reference.map { "\"\($0)\"" } ?? "null"
    let customerJSON = customer
        ? #"{"name":"Test Person","email":"person@example.com","phone":null,"company":null}"#
        : "null"
    let itemsJSON = items ? #""items":[{"id":"itm_TestItem0001","object":"order_item","quote":{"id":"qte_TestQuote0001","object":"quote","name":"Plinth 0123456789abcdef"},"materials":[{"id":"mat_TestBlue","object":"material","name":"PLA Blue"},{"id":"mat_TestRed","object":"material","name":"PLA Red"}],"material_slots":[{"slot":3,"material":{"id":"mat_TestBlue","object":"material","name":"PLA Blue"}},{"slot":1,"material":{"id":"mat_TestRed","object":"material","name":"PLA Red"}}],"quantity":3,"unit_price":{"amount":450,"currency":"usd"},"production_unit_price":{"amount":450,"currency":"usd"},"extras":[],"total":{"amount":1350,"currency":"usd"}}],"# : ""
    return """
    {"id":"\(id)","object":"order","number":"2APTEST0001","channel":"integrator_wallet","status":"\(status)",
     "customer":\(customerJSON),
     "shipping_address":{"formatted":\(customer ? "\"1 Test Street, Testville, TE1 1ST, United Kingdom\"" : "null"),"city":\(customer ? "\"Testville\"" : "null"),"country":"United Kingdom","country_code":"GB"},
     "charges":{"paid_by":"you","items":{"amount":1350,"currency":"usd"},"shipping":{"amount":599,"currency":"usd"},
                "vat":{"amount":{"amount":0,"currency":"usd"},"rate":0.2,"included":false,"country":"GB"},
                "sample_credit":null,"total":{"amount":1949,"currency":"usd"}},
     "earnings":null,
     "shipping":{"tier":"small","carrier":null,"tracking_number":null,"shipped_at":null},
     "customer_notes":null,"created_at":"2026-10-30T21:42:13.550Z","updated_at":"2026-10-30T21:42:14Z","mode":"wallet","checkout":null,
     "item_count":3,\(itemsJSON)
     "refunds":[{"id":"rfd_TestRefund01","amount":{"amount":100,"currency":"usd"},"created_at":"2026-10-31T09:00:00Z"}],
     "reference":\(ref)}
    """
}

private func recipient() -> DapiOrderRecipient {
    DapiOrderRecipient(name: " Test Person ", email: "person@example.com", phone: "", line1: "1 Test Street", line2: nil,
                       city: "Testville", state: "  ", postalCode: "TE1 1ST", countryCode: "gb")
}

private func orderRequest(lines: [DapiOrderLineRequest]? = nil, recipient: DapiOrderRecipient = recipient(),
                          reference: String = "plinth-test-0001", notes: String? = nil) -> DapiOrderRequest {
    DapiOrderRequest(lines: lines ?? [DapiOrderLineRequest(quoteID: "qte_TestQuote0001", quantity: 3, materials: .suggested)],
                     recipient: recipient, reference: reference, customerNotes: notes)
}

final class DapiOrderClientTests: XCTestCase {
    private func makeClient(_ steps: [ScriptedOrderTransport.Step]) -> (DapiClient, ScriptedOrderTransport) {
        let transport = ScriptedOrderTransport(steps)
        return (DapiClient(apiKey: orderTestKey, transport: transport), transport)
    }

    private func dapiError(_ work: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async -> DapiError? {
        do {
            try await work()
            XCTFail("Expected an error", file: file, line: line)
            return nil
        } catch let error as DapiError {
            return error
        } catch {
            XCTFail("Unexpected error \(error)", file: file, line: line)
            return nil
        }
    }

    private func isOutcomeUnknown(_ error: DapiError?) -> Bool {
        if case .outcomeUnknown? = error { return true }
        return false
    }

    // MARK: Request bodies and validation

    func testBodyForSuggestedMaterials() throws {
        let body = dapiOrderRequestBody(orderRequest(notes: "  "))
        let data = try JSONSerialization.data(withJSONObject: body)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["mode", "items", "shipping_address", "customer", "reference", "customer_notes"])
        XCTAssertEqual(object["mode"] as? String, "wallet")
        XCTAssertEqual(object["reference"] as? String, "plinth-test-0001")
        XCTAssertTrue(object["customer_notes"] is NSNull)
        let item = try XCTUnwrap((object["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(item.keys), ["quote", "quantity", "use_suggested_materials"])
        XCTAssertEqual(item["use_suggested_materials"] as? Bool, true)
        XCTAssertEqual(item["quantity"] as? Int, 3)
        let address = try XCTUnwrap(object["shipping_address"] as? [String: Any])
        XCTAssertEqual(address["country_code"] as? String, "GB")
        XCTAssertTrue(address["line2"] is NSNull)
        XCTAssertTrue(address["state"] is NSNull)
        XCTAssertEqual(address["postal_code"] as? String, "TE1 1ST")
        let customer = try XCTUnwrap(object["customer"] as? [String: Any])
        XCTAssertEqual(customer["name"] as? String, "Test Person")
        XCTAssertTrue(customer["phone"] is NSNull)
        for forbidden in ["use_sample_credit", "checkout", "unit_sales_price", "extras"] {
            XCTAssertFalse(String(data: data, encoding: .utf8)!.contains(forbidden), forbidden)
        }
    }

    func testBodyForSlotMaterials() throws {
        let slots = [DapiMaterialSlot(slot: 2, materialID: "mat_TestBlue"), DapiMaterialSlot(slot: 1, materialID: "mat_TestRed")]
        let body = dapiOrderRequestBody(orderRequest(lines: [DapiOrderLineRequest(quoteID: "qte_TestQuote0001", quantity: 1, materials: .slots(slots))],
                                                     notes: "Leave with a neighbour"))
        let item = try XCTUnwrap((body["items"] as? [[String: Any]])?.first)
        XCTAssertNil(item["use_suggested_materials"])
        let materials = try XCTUnwrap(item["materials"] as? [[String: Any]])
        XCTAssertEqual(materials.map { $0["slot"] as? Int }, [1, 2])
        XCTAssertEqual(materials.map { $0["material"] as? String }, ["mat_TestRed", "mat_TestBlue"])
        XCTAssertEqual(body["customer_notes"] as? String, "Leave with a neighbour")
    }

    func testValidationProblems() {
        XCTAssertNil(dapiOrderRequestProblem(orderRequest()))
        func problem(_ request: DapiOrderRequest) -> String? { dapiOrderRequestProblem(request) }
        let line = DapiOrderLineRequest(quoteID: "qte_TestQuote0001", quantity: 1, materials: .suggested)
        XCTAssertNotNil(problem(orderRequest(lines: [])))
        XCTAssertNotNil(problem(orderRequest(lines: Array(repeating: line, count: 101))))
        XCTAssertNil(problem(orderRequest(lines: Array(repeating: line, count: 100))))
        XCTAssertNotNil(problem(orderRequest(lines: [DapiOrderLineRequest(quoteID: "qte_bad/../x", quantity: 1, materials: .suggested)])))
        XCTAssertNotNil(problem(orderRequest(lines: [DapiOrderLineRequest(quoteID: "qte_TestQuote0001", quantity: 0, materials: .suggested)])))
        XCTAssertNotNil(problem(orderRequest(lines: [DapiOrderLineRequest(quoteID: "qte_TestQuote0001", quantity: 10_001, materials: .suggested)])))
        XCTAssertNil(problem(orderRequest(lines: [DapiOrderLineRequest(quoteID: "qte_TestQuote0001", quantity: 10_000, materials: .suggested)])))
        func slots(_ slots: [DapiMaterialSlot]) -> DapiOrderRequest {
            orderRequest(lines: [DapiOrderLineRequest(quoteID: "qte_TestQuote0001", quantity: 1, materials: .slots(slots))])
        }
        XCTAssertNotNil(problem(slots([])))
        XCTAssertNotNil(problem(slots([DapiMaterialSlot(slot: 1, materialID: "mat_A"), DapiMaterialSlot(slot: 1, materialID: "mat_B")])))
        XCTAssertNotNil(problem(slots([DapiMaterialSlot(slot: 0, materialID: "mat_A")])))
        XCTAssertNotNil(problem(slots([DapiMaterialSlot(slot: 17, materialID: "mat_A")])))
        XCTAssertNotNil(problem(slots([DapiMaterialSlot(slot: 1, materialID: "pla-red")])))
        XCTAssertNil(problem(slots([DapiMaterialSlot(slot: 1, materialID: "mat_A"), DapiMaterialSlot(slot: 4, materialID: "mat_B")])))

        XCTAssertNotNil(problem(orderRequest(reference: "")))
        XCTAssertNotNil(problem(orderRequest(reference: "has space")))
        XCTAssertNotNil(problem(orderRequest(reference: String(repeating: "a", count: 101))))
        XCTAssertNil(problem(orderRequest(reference: String(repeating: "a", count: 100))))

        func with(_ change: (inout DapiOrderRecipient) -> Void) -> DapiOrderRequest {
            var value = recipient()
            change(&value)
            return orderRequest(recipient: value)
        }
        XCTAssertNotNil(problem(with { $0.name = "  " }))
        XCTAssertNotNil(problem(with { $0.name = String(repeating: "n", count: 201) }))
        XCTAssertNotNil(problem(with { $0.email = "" }))
        XCTAssertNotNil(problem(with { $0.email = "person" }))
        XCTAssertNotNil(problem(with { $0.email = "person@example" }))
        XCTAssertNotNil(problem(with { $0.email = "a b@example.com" }))
        XCTAssertNotNil(problem(with { $0.email = "a@b@example.com" }))
        XCTAssertNotNil(problem(with { $0.phone = String(repeating: "1", count: 41) }))
        XCTAssertNotNil(problem(with { $0.line1 = "" }))
        XCTAssertNotNil(problem(with { $0.line1 = String(repeating: "x", count: 201) }))
        XCTAssertNotNil(problem(with { $0.line1 = "1 Test\nStreet" }))
        XCTAssertNotNil(problem(with { $0.line2 = String(repeating: "x", count: 201) }))
        XCTAssertNotNil(problem(with { $0.city = "" }))
        XCTAssertNotNil(problem(with { $0.state = String(repeating: "x", count: 101) }))
        XCTAssertNotNil(problem(with { $0.postalCode = String(repeating: "1", count: 21) }))
        XCTAssertNotNil(problem(with { $0.countryCode = "" }))
        XCTAssertNotNil(problem(with { $0.countryCode = "GBR" }))
        XCTAssertNotNil(problem(orderRequest(notes: String(repeating: "x", count: 2001))))
        XCTAssertNil(problem(orderRequest(notes: "Line one\nLine two")))
    }

    // MARK: Order list queries

    func testListQueryItems() throws {
        var query = DapiOrderListQuery()
        query.statuses = [.paid, .shipped, .paid]
        query.reference = " plinth-test-0001 "
        query.search = "  " + String(repeating: "7", count: 150) + " "
        query.createdAfter = Date(timeIntervalSince1970: 1_793_000_000)
        query.createdBefore = Date(timeIntervalSince1970: 1_793_086_400.75)
        query.limit = 500
        query.cursor = "cur_abc"
        let items = try dapiOrderListQueryItems(query)
        XCTAssertEqual(items.filter { $0.0 == "status" }.map(\.1), ["paid", "shipped"])
        XCTAssertEqual(items.first { $0.0 == "reference" }?.1, "plinth-test-0001")
        XCTAssertEqual(items.first { $0.0 == "search" }?.1.count, 100)
        XCTAssertEqual(items.first { $0.0 == "created_after" }?.1, "2026-10-26T07:33:20Z")
        XCTAssertEqual(items.first { $0.0 == "created_before" }?.1, "2026-10-27T07:33:20Z")
        XCTAssertEqual(items.first { $0.0 == "limit" }?.1, "100")
        XCTAssertEqual(items.first { $0.0 == "cursor" }?.1, "cur_abc")
        XCTAssertEqual(items.last?.0, "expand[]")
        XCTAssertEqual(items.last?.1, "items")

        query = DapiOrderListQuery()
        query.limit = 0
        query.expandItems = false
        let plain = try dapiOrderListQueryItems(query)
        XCTAssertEqual(plain.map(\.0), ["limit"])
        XCTAssertEqual(plain.first?.1, "1")

        query.statuses = [.unknown("lost")]
        XCTAssertThrowsError(try dapiOrderListQueryItems(query))
        query.statuses = []
        query.reference = String(repeating: "r", count: 101)
        XCTAssertThrowsError(try dapiOrderListQueryItems(query))
        query.reference = nil
        query.cursor = ""
        XCTAssertThrowsError(try dapiOrderListQueryItems(query))
    }

    func testListRequestRepeatsStatusAndEncodesExpand() async throws {
        let page = #"{"object":"list","data":[\#(orderJSON()), {"id":"bad"}],"has_more":true,"next_cursor":"cur_next"}"#
        let (client, transport) = makeClient([.reply(200, page)])
        var query = DapiOrderListQuery()
        query.statuses = [.paid, .inProduction]
        query.search = "2AP"
        let result = try await client.orders(query)
        XCTAssertEqual(result.orders.count, 1)
        XCTAssertTrue(result.hasMore)
        XCTAssertEqual(result.nextCursor, "cur_next")
        let request = try XCTUnwrap(transport.sentRequests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.host, dapiAPIHost)
        XCTAssertEqual(request.url?.path, "/v2/integrator/orders")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), orderTestKey)
        XCTAssertNil(request.value(forHTTPHeaderField: "Idempotency-Key"))
        let encoded = try XCTUnwrap(request.url?.query(percentEncoded: true))
        XCTAssertTrue(encoded.hasPrefix("status=paid&status=in_production&search=2AP&limit=50"), encoded)
        XCTAssertTrue(encoded.hasSuffix("&expand%5B%5D=items"), encoded)
        XCTAssertFalse(encoded.contains("status%5B%5D"))
        let names = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
        XCTAssertTrue(names.contains("expand[]"))
    }

    func testListPageChecks() async throws {
        // `has_more` without a cursor, or with the cursor just sent, is unreadable.
        let (noCursor, _) = makeClient([.reply(200, #"{"object":"list","data":[],"has_more":true,"next_cursor":null}"#)])
        guard case .readFailed? = await dapiError({ _ = try await noCursor.orders(DapiOrderListQuery()) }) else { return XCTFail() }
        var query = DapiOrderListQuery()
        query.cursor = "cur_same"
        let (repeated, _) = makeClient([.reply(200, #"{"object":"list","data":[],"has_more":true,"next_cursor":"cur_same"}"#)])
        guard case .readFailed? = await dapiError({ _ = try await repeated.orders(query) }) else { return XCTFail() }
        // A reference lookup fails on an order it can't read instead of skipping it.
        var lookup = DapiOrderListQuery()
        lookup.reference = "plinth-test-0001"
        let (lookupClient, _) = makeClient([.reply(200, #"{"object":"list","data":[{"id":"ord_TestOrder0001","status":"paid"}],"has_more":false,"next_cursor":null}"#)])
        guard case .readFailed? = await dapiError({ _ = try await lookupClient.orders(lookup) }) else { return XCTFail() }
        let (missingData, _) = makeClient([.reply(200, #"{"object":"list"}"#)])
        guard case .readFailed? = await dapiError({ _ = try await missingData.orders(DapiOrderListQuery()) }) else { return XCTFail() }
        let (serverError, _) = makeClient([.reply(500, "")])
        guard case .readFailed? = await dapiError({ _ = try await serverError.orders(DapiOrderListQuery()) }) else { return XCTFail() }
        // An unknown status in the filter is never sent.
        var unknown = DapiOrderListQuery()
        unknown.statuses = [.unknown("misplaced")]
        let (unsent, transport) = makeClient([])
        guard case .notSent? = await dapiError({ _ = try await unsent.orders(unknown) }) else { return XCTFail() }
        XCTAssertEqual(transport.count, 0)
    }

    // MARK: Parsing

    func testParsesFullOrder() throws {
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(orderJSON().utf8)) as? [String: Any])
        let order = try XCTUnwrap(dapiParseOrder(object))
        XCTAssertEqual(order.id, "ord_TestOrder0001")
        XCTAssertEqual(order.number, "2APTEST0001")
        XCTAssertEqual(order.status, .paid)
        XCTAssertEqual(order.mode, "wallet")
        XCTAssertEqual(order.reference, "plinth-test-0001")
        XCTAssertEqual(order.customerName, "Test Person")
        XCTAssertEqual(order.customerEmail, "person@example.com")
        XCTAssertEqual(order.city, "Testville")
        XCTAssertEqual(order.countryName, "United Kingdom")
        XCTAssertEqual(order.countryCode, "GB")
        let charges = try XCTUnwrap(order.charges)
        XCTAssertEqual(charges.paidBy, "you")
        XCTAssertEqual(charges.total, DapiMoney(amountMinor: 1949, currency: "usd"))
        XCTAssertEqual(charges.vatRate, Decimal(string: "0.2"))
        XCTAssertEqual(charges.vatCountry, "GB")
        XCTAssertFalse(charges.vatIncluded)
        XCTAssertNil(charges.sampleCredit)
        XCTAssertEqual(order.shipping.tier, "small")
        XCTAssertNil(order.shipping.trackingNumber)
        XCTAssertEqual(order.itemCount, 3)
        let item = try XCTUnwrap(order.items?.first)
        XCTAssertEqual(item.quoteID, "qte_TestQuote0001")
        XCTAssertEqual(item.quoteName, "Plinth 0123456789abcdef")
        XCTAssertEqual(item.materials.map(\.slot), [1, 3])
        XCTAssertEqual(item.materials.map(\.materialName), ["PLA Red", "PLA Blue"])
        XCTAssertEqual(item.quantity, 3)
        XCTAssertEqual(item.unitPrice?.amountMinor, 450)
        XCTAssertEqual(item.total?.amountMinor, 1350)
        XCTAssertEqual(order.refunds.map(\.amount.amountMinor), [100])
        XCTAssertNotNil(order.createdAt)
        XCTAssertNotNil(order.updatedAt)
    }

    func testParsesLeniently() throws {
        func parse(_ text: String) -> DapiOrder? {
            ((try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]).flatMap(dapiParseOrder)
        }
        let unknown = try XCTUnwrap(parse(orderJSON(status: "Lost_In_Space", items: false, customer: false)))
        XCTAssertEqual(unknown.status, .unknown("Lost_In_Space"))
        XCTAssertFalse(unknown.status.canRequestCancellation)
        XCTAssertNil(unknown.items)
        XCTAssertNil(unknown.customerName)
        XCTAssertNil(unknown.formattedAddress)
        XCTAssertEqual(unknown.countryCode, "GB")
        XCTAssertEqual(parse(orderJSON(status: "CANCELLED"))?.status, .cancelled)
        XCTAssertNil(parse(orderJSON(reference: nil))?.reference)

        let minimal = try XCTUnwrap(parse(#"{"id":"ord_TestOrder0002","number":"2APTEST0002","status":"shipped","customer":null,"shipping_address":null,"charges":{"items":{"amount":"12"}},"shipping":null,"refunds":"none","items":[{"id":"itm_x","quote":{"id":"qte_bad/x"},"quantity":1},{"id":"itm_y","quote":{"id":"qte_TestQuote0001"},"quantity":2,"material_slots":[{"slot":99,"material":{"id":"mat_A"}}]}],"channel":"integrator_wallet","created_at":"nope"}"#))
        XCTAssertNil(minimal.charges)
        XCTAssertEqual(minimal.mode, "wallet")
        XCTAssertEqual(minimal.items?.count, 1)
        XCTAssertEqual(minimal.items?.first?.materials, [])
        XCTAssertEqual(minimal.itemCount, 2)
        XCTAssertEqual(minimal.refunds, [])
        XCTAssertNil(minimal.createdAt)

        XCTAssertNil(parse(#"{"id":"ord_TestOrder0003","status":"paid"}"#))
        XCTAssertNil(parse(#"{"id":"ord_TestOrder0003","number":"2AP"}"#))
        XCTAssertNil(parse(#"{"id":"ord_../x","number":"2AP","status":"paid"}"#))
        XCTAssertNil(parse(#"{"id":"qte_TestOrder0003","number":"2AP","status":"paid"}"#))

        // Lists are capped.
        let manyItems = (0..<150).map { #"{"id":"itm_\#($0)","quote":{"id":"qte_TestQuote0001"},"quantity":1}"# }.joined(separator: ",")
        let manyRefunds = (0..<80).map { #"{"id":"rfd_\#($0)","amount":{"amount":1,"currency":"usd"}}"# }.joined(separator: ",")
        let big = try XCTUnwrap(parse(#"{"id":"ord_TestOrder0004","number":"2AP","status":"paid","items":[\#(manyItems)],"refunds":[\#(manyRefunds)]}"#))
        XCTAssertEqual(big.items?.count, dapiMaxOrderLines)
        XCTAssertEqual(big.refunds.count, dapiMaxOrderRefunds)
    }

    func testOnboardingOrderBlockers() {
        let base: [String: Any] = ["status": "approved", "approved_files": 10, "required_files": 10,
                                   "uploads": ["used": 3, "limit": NSNull()]]
        XCTAssertEqual(dapiParseOnboarding(base)?.orderBlockers, [])
        var withStrings = base
        withStrings["order_blockers"] = ["billing_details_missing", "billing_details_missing"]
        XCTAssertEqual(dapiParseOnboarding(withStrings)?.orderBlockers, ["billing_details_missing"])
        var withObjects = base
        withObjects["order_blockers"] = [["code": "Billing_Details_Missing"], ["code": "new-thing"], 42]
        XCTAssertEqual(dapiParseOnboarding(withObjects)?.orderBlockers, ["billing_details_missing", "unrecognised"])
        XCTAssertNotNil(dapiOrderingProblem(account: DapiAccount(kind: "integrator", approval: "approved", effectiveScopes: ["orders:write"]),
                                            onboardingOrderBlockers: dapiParseOnboarding(withObjects)?.orderBlockers ?? []))
    }

    func testMaterialsPaging() async throws {
        let first = ##"{"object":"list","data":[{"id":"mat_TestRed","object":"material","name":"PLA Red","custom":false,"technology":"fdm","color":"Red","color_hex":"#c12e1f","filament_type":"PLA"},{"id":null,"name":"Custom"}],"has_more":true,"next_cursor":"cur_2"}"##
        let second = #"{"object":"list","data":[{"id":"mat_TestBlue","name":"PETG Blue","color_hex":"blue","filament_type":"petg"}],"has_more":false,"next_cursor":null}"#
        let (client, transport) = makeClient([.reply(200, first), .reply(200, second)])
        let materials = try await client.materials()
        XCTAssertEqual(materials.map(\.id), ["mat_TestRed", "mat_TestBlue"])
        XCTAssertEqual(materials.first?.colorHex, "#C12E1F")
        XCTAssertEqual(materials.first?.filamentType, "pla")
        XCTAssertNil(materials.last?.colorHex)
        XCTAssertEqual(transport.count, 2)
        XCTAssertEqual(transport.sentRequests.last?.url?.query, "limit=100&cursor=cur_2")
        XCTAssertEqual(transport.sentRequests.first?.url?.path, "/v2/materials")

        let (looping, _) = makeClient([.reply(200, first), .reply(200, first)])
        guard case .readFailed? = await dapiError({ _ = try await looping.materials() }) else { return XCTFail() }
        let (noCursor, _) = makeClient([.reply(200, #"{"object":"list","data":[],"has_more":true}"#)])
        guard case .readFailed? = await dapiError({ _ = try await noCursor.materials() }) else { return XCTFail() }
        let endless = (1...6).map { ScriptedOrderTransport.Step.reply(200, #"{"object":"list","data":[],"has_more":true,"next_cursor":"cur_\#($0)"}"#) }
        let (tooMany, tooManyTransport) = makeClient(endless)
        guard case .readFailed? = await dapiError({ _ = try await tooMany.materials() }) else { return XCTFail() }
        XCTAssertEqual(tooManyTransport.count, dapiMaterialPageLimit)
    }

    func testWallet() async throws {
        let (client, transport) = makeClient([.reply(200, #"{"object":"wallet","balance":{"amount":2500,"currency":"usd"},"sample_credit":{"amount":1500,"currency":"usd"},"sample_credit_expires_at":"2026-11-30T00:00:00Z","pending_withdrawals":{"amount":0,"currency":"usd"}}"#)])
        let wallet = try await client.wallet()
        XCTAssertEqual(wallet.balance.usd, 25)
        XCTAssertEqual(wallet.sampleCredit?.amountMinor, 1500)
        XCTAssertNotNil(wallet.sampleCreditExpiresAt)
        XCTAssertEqual(transport.sentRequests.first?.url?.path, "/v2/wallet")
        XCTAssertNil(dapiParseWallet(["balance": ["amount": 1.5, "currency": "usd"]]))
        let (noScope, _) = makeClient([.reply(403, errorBody(403, "missing_scope", details: #"{"required_scopes":["wallet:read"]}"#))])
        let error = await dapiError { _ = try await noScope.wallet() }
        guard case .refused(403, "missing_scope", _)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(error?.userMessage.contains("wallet:read") ?? false, error?.userMessage ?? "")
    }

    func testMultiLineShippingEstimate() async throws {
        let (client, transport) = makeClient([.reply(200, #"{"object":"shipping_estimate","country_code":"DE","zone":{"code":"eu-core","name":"EU-Core"},"tier":"medium","additional_items":2,"total":{"amount":1299,"currency":"usd"}}"#)])
        let lines = [DapiOrderLineRequest(quoteID: "qte_TestQuote0001", quantity: 2, materials: .suggested),
                     DapiOrderLineRequest(quoteID: "qte_TestQuote0002", quantity: 1, materials: .slots([DapiMaterialSlot(slot: 1, materialID: "mat_A")]))]
        let estimate = try await client.shippingEstimate(lines: lines, countryCode: " de ")
        XCTAssertEqual(estimate.total.amountMinor, 1299)
        XCTAssertEqual(estimate.tier, "medium")
        let body = try XCTUnwrap(json(try XCTUnwrap(transport.sentRequests.first)))
        XCTAssertEqual(body["country"] as? String, "DE")
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(Set(items[1].keys), ["quote", "quantity"])
        XCTAssertNil(transport.sentRequests.first?.value(forHTTPHeaderField: "Idempotency-Key"))

        let (unsent, unsentTransport) = makeClient([])
        guard case .notSent? = await dapiError({ _ = try await unsent.shippingEstimate(lines: [], countryCode: "DE") }) else { return XCTFail() }
        guard case .notSent? = await dapiError({ _ = try await unsent.shippingEstimate(lines: Array(repeating: lines[0], count: 101), countryCode: "DE") }) else { return XCTFail() }
        guard case .notSent? = await dapiError({ _ = try await unsent.shippingEstimate(lines: [DapiOrderLineRequest(quoteID: "qte_A", quantity: 10_001, materials: .suggested)], countryCode: "DE") }) else { return XCTFail() }
        guard case .notSent? = await dapiError({ _ = try await unsent.shippingEstimate(lines: lines, countryCode: "Germany") }) else { return XCTFail() }
        XCTAssertEqual(unsentTransport.count, 0)
    }

    func testGetOrder() async throws {
        let (client, transport) = makeClient([.reply(200, orderJSON())])
        let order = try await client.order(id: "ord_TestOrder0001")
        XCTAssertEqual(order.number, "2APTEST0001")
        XCTAssertEqual(transport.sentRequests.first?.url?.path, "/v2/integrator/orders/ord_TestOrder0001")
        XCTAssertEqual(transport.sentRequests.first?.httpMethod, "GET")

        let (unsafe, unsafeTransport) = makeClient([])
        for id in ["ord_../wallet", "qte_TestQuote0001", "ord_", "ord_a?b=c", ""] {
            guard case .notSent? = await dapiError({ _ = try await unsafe.order(id: id) }) else { return XCTFail(id) }
        }
        XCTAssertEqual(unsafeTransport.count, 0)
        let (other, _) = makeClient([.reply(200, orderJSON(id: "ord_SomeoneElse"))])
        guard case .readFailed? = await dapiError({ _ = try await other.order(id: "ord_TestOrder0001") }) else { return XCTFail() }
        let (missing, _) = makeClient([.reply(404, errorBody(404, "order_not_found"))])
        let error = await dapiError { _ = try await missing.order(id: "ord_TestOrder0001") }
        guard case .refused(404, "order_not_found", _)? = error else { return XCTFail() }
        XCTAssertTrue(error?.userMessage.contains("no order") ?? false)
    }

    // MARK: Placing an order

    func testPlaceOrderSendsOnceWithIdempotencyKey() async throws {
        let (client, transport) = makeClient([.reply(201, orderJSON())])
        let order = try await client.placeOrder(orderRequest(), idempotencyKey: "idem-0001")
        XCTAssertEqual(order.id, "ord_TestOrder0001")
        XCTAssertEqual(transport.count, 1)
        let request = try XCTUnwrap(transport.sentRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://\(dapiAPIHost)/v2/integrator/orders")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-0001")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), orderTestKey)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(json(request)?["mode"] as? String, "wallet")
    }

    func testPlaceOrderReturnsWhateverStatus3DAPISays() async throws {
        let (client, _) = makeClient([.reply(201, orderJSON(status: "cancelled"))])
        let order = try await client.placeOrder(orderRequest(), idempotencyKey: "idem-0002")
        XCTAssertEqual(order.status, .cancelled)
        XCTAssertFalse(order.status.countsAsPlaced)
    }

    func testPlaceOrderLocalProblemsSendNothing() async throws {
        let (client, transport) = makeClient([])
        guard case .notSent? = await dapiError({ _ = try await client.placeOrder(orderRequest(reference: "bad ref"), idempotencyKey: "k") }) else { return XCTFail() }
        guard case .notSent? = await dapiError({ _ = try await client.placeOrder(orderRequest(), idempotencyKey: "") }) else { return XCTFail() }
        guard case .notSent? = await dapiError({ _ = try await client.placeOrder(orderRequest(), idempotencyKey: String(repeating: "k", count: 256)) }) else { return XCTFail() }
        guard case .notSent? = await dapiError({ _ = try await client.placeOrder(orderRequest(), idempotencyKey: "has space") }) else { return XCTFail() }
        XCTAssertEqual(transport.count, 0)
        let (noKey, noKeyTransport) = (DapiClient(apiKey: "", transport: transport), transport)
        guard case .missingKey? = await dapiError({ _ = try await noKey.placeOrder(orderRequest(), idempotencyKey: "k") }) else { return XCTFail() }
        XCTAssertEqual(noKeyTransport.count, 0)
    }

    func testPlaceOrderRefusals() async throws {
        let cases: [(Int, String)] = [
            (402, "payment_failed"), (402, "insufficient_balance"), (403, "compliance_blocked"), (404, "quote_not_found"),
            (409, "production_unavailable"), (422, "quote_not_ready"), (422, "quote_rejected"), (422, "quote_not_approved"),
            (422, "material_not_allowed"), (422, "material_slots_mismatch"), (422, "suggestions_unavailable"),
            (422, "currency_not_supported"), (422, "shipping_destination_not_served"), (422, "vat_number_invalid"),
            (422, "extra_not_found"), (422, "extra_not_approved"), (400, "validation_failed"), (401, "invalid_api_key"),
            (503, "card_payments_unavailable")
        ]
        for (status, code) in cases {
            let (client, transport) = makeClient([.reply(status, errorBody(status, code, message: "raw 3DAPI text"))])
            let error = await dapiError { _ = try await client.placeOrder(orderRequest(), idempotencyKey: "idem-\(code)") }
            guard case .refused(status, code, _)? = error else { return XCTFail("\(code): \(String(describing: error))") }
            XCTAssertEqual(transport.count, 1, code)
            XCTAssertEqual(error?.activityDetail, "HTTP \(status) \(code)")
            if code != "validation_failed" { XCTAssertFalse(error?.userMessage.contains("raw 3DAPI text") ?? true, code) }
        }
        let (limited, _) = makeClient([.reply(429, errorBody(429, "rate_limited"))])
        guard case .rateLimited("rate_limited", _)? = await dapiError({ _ = try await limited.placeOrder(orderRequest(), idempotencyKey: "k") }) else { return XCTFail() }
    }

    func testPlaceOrderUnknownOutcomes() async throws {
        let unknownReplies: [(Int, String)] = [
            (408, errorBody(408, "request_timeout")), (500, errorBody(500, "internal_error")), (502, ""),
            (503, errorBody(503, "service_unavailable")), (503, ""), (302, ""), (422, "not json"),
            (201, "not json"), (201, "{}"), (201, #"{"id":"ord_TestOrder0001","status":"paid"}"#),
            (201, orderJSON(reference: "someone-else")), (201, orderJSON(reference: nil)), (200, "[]"),
            (422, "{}"), (402, #"{"message":"Payment Required"}"#), (400, #"{"code":"Not A Code"}"#)
        ]
        for (status, body) in unknownReplies {
            let (client, transport) = makeClient([.reply(status, body)])
            let error = await dapiError { _ = try await client.placeOrder(orderRequest(), idempotencyKey: "idem-u") }
            XCTAssertTrue(isOutcomeUnknown(error), "\(status) \(body): \(String(describing: error))")
            XCTAssertEqual(transport.count, 1)
            XCTAssertEqual(error?.activityDetail, "Outcome unknown")
            XCTAssertTrue(error?.userMessage.contains("didn’t send it again") ?? false)
        }
        // A bare 4xx body is still a refusal for a read.
        let (read, _) = makeClient([.reply(404, "{}")])
        guard case .refused(404, nil, nil)? = await dapiError({ _ = try await read.order(id: "ord_TestOrder0001") }) else { return XCTFail() }
        // An unrecognised status word is redacted before it is kept.
        let leaky = ((try? JSONSerialization.jsonObject(with: Data(orderJSON(status: "sk_leak123").utf8))) as? [String: Any]).flatMap(dapiParseOrder)
        XCTAssertFalse(leaky?.status.raw.contains("leak123") ?? true)
        // 503 card_payments_unavailable means no order only for placing one.
        let (cancel, _) = makeClient([.reply(503, errorBody(503, "card_payments_unavailable"))])
        let cancelError = await dapiError { _ = try await cancel.cancelOrder(id: "ord_TestOrder0001", idempotencyKey: "k") }
        XCTAssertTrue(isOutcomeUnknown(cancelError))
    }

    func testPlaceOrderTransportFailures() async throws {
        for code: URLError.Code in [.cannotFindHost, .dnsLookupFailed, .badURL, .appTransportSecurityRequiresSecureConnection] {
            let (client, _) = makeClient([.fail(URLError(code))])
            guard case .notSent? = await dapiError({ _ = try await client.placeOrder(orderRequest(), idempotencyKey: "k") }) else { return XCTFail("\(code)") }
        }
        let after: [Error] = [URLError(.timedOut), URLError(.networkConnectionLost), URLError(.notConnectedToInternet),
                              URLError(.secureConnectionFailed), URLError(.cancelled), CancellationError(),
                              DapiTransportError.responseTooLarge, DapiTransportError.notHTTP]
        for failure in after {
            let (client, _) = makeClient([.fail(failure)])
            let error = await dapiError { _ = try await client.placeOrder(orderRequest(), idempotencyKey: "k") }
            XCTAssertTrue(isOutcomeUnknown(error), "\(failure): \(String(describing: error))")
        }
        // Reads keep a cancellation as a stop.
        let (read, _) = makeClient([.fail(CancellationError())])
        do {
            _ = try await read.order(id: "ord_TestOrder0001")
            XCTFail("Expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testCancellingTheCallerDoesNotCutOffAnOrder() async throws {
        let (client, transport) = makeClient([.wait(201, orderJSON())])
        let task = Task { try await client.placeOrder(orderRequest(), idempotencyKey: "idem-wait") }
        for _ in 0..<500 where transport.count == 0 { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(transport.count, 1)
        task.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        transport.release()
        let order = try await task.value
        XCTAssertEqual(order.id, "ord_TestOrder0001")
        XCTAssertEqual(transport.count, 1)
    }

    func testCancelledBeforeSendingSendsNothing() async throws {
        let (client, transport) = makeClient([.reply(201, orderJSON())])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.placeOrder(orderRequest(), idempotencyKey: "idem-early")
        }
        do {
            _ = try await task.value
            XCTFail("Expected a cancellation")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertEqual(transport.count, 0)
    }

    // MARK: Cancelling an order

    func testCancelOrder() async throws {
        let (client, transport) = makeClient([.reply(200, orderJSON(status: "cancelled"))])
        let order = try await client.cancelOrder(id: "ord_TestOrder0001", idempotencyKey: "idem-cancel")
        XCTAssertEqual(order.status, .cancelled)
        let request = try XCTUnwrap(transport.sentRequests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v2/integrator/orders/ord_TestOrder0001/cancel")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), "idem-cancel")
        XCTAssertNil(request.httpBody)

        let (refused, _) = makeClient([.reply(409, errorBody(409, "order_not_cancellable"))])
        let error = await dapiError { _ = try await refused.cancelOrder(id: "ord_TestOrder0001", idempotencyKey: "k") }
        guard case .refused(409, "order_not_cancellable", _)? = error else { return XCTFail() }
        XCTAssertTrue(error?.userMessage.contains("contact@dapi.digital") ?? false)

        for step: ScriptedOrderTransport.Step in [.reply(500, ""), .reply(408, ""), .reply(200, "nope"),
                                                  .reply(200, orderJSON(id: "ord_SomeoneElse")), .fail(URLError(.timedOut)),
                                                  .fail(CancellationError())] {
            let (client, _) = makeClient([step])
            let error = await dapiError { _ = try await client.cancelOrder(id: "ord_TestOrder0001", idempotencyKey: "k") }
            XCTAssertTrue(isOutcomeUnknown(error), "\(step): \(String(describing: error))")
            XCTAssertTrue(error?.userMessage.contains("cancelled the order") ?? false)
        }
        let (unsafe, unsafeTransport) = makeClient([])
        guard case .notSent? = await dapiError({ _ = try await unsafe.cancelOrder(id: "ord_x/../y", idempotencyKey: "k") }) else { return XCTFail() }
        guard case .notSent? = await dapiError({ _ = try await unsafe.cancelOrder(id: "ord_TestOrder0001", idempotencyKey: "") }) else { return XCTFail() }
        XCTAssertEqual(unsafeTransport.count, 0)
    }

    // MARK: Error copy

    func testErrorDetailsAndCopy() {
        let validation = errorBody(400, "validation_failed", message: "Invalid body.",
                                   details: #"{"errors":[{"field":"customer.email","message":"must be an email"},{"path":["items",0,"quantity"],"message":"too large for \#(orderTestKey)"},"reference is invalid","x","y","z"]}"#)
        let parsed = dapiErrorBody(Data(validation.utf8), secrets: [orderTestKey])
        let message = parsed?.message ?? ""
        XCTAssertTrue(message.contains("customer.email: must be an email"), message)
        XCTAssertTrue(message.contains("items.0.quantity: too large"), message)
        XCTAssertTrue(message.contains("and 1 more"), message)
        XCTAssertFalse(message.contains("0000test"), message)
        let validationError = DapiError.refused(status: 400, code: "validation_failed", message: message)
        XCTAssertTrue(validationError.userMessage.contains("customer.email"), validationError.userMessage)

        let mapShape = dapiErrorDetailsSummary(code: "validation_failed", details: ["errors": ["customer.name": ["is required"]]])
        XCTAssertEqual(mapShape, "Fields: customer.name: is required.")

        let compliance = errorBody(403, "compliance_blocked", message: "Add billing details at https://dapi.digital/finance?token=abc123",
                                   details: #"{"requirements":["billing_details_missing"],"fix_url":"https://dapi.digital/fix?session=secret999"}"#)
        let complianceBody = dapiErrorBody(Data(compliance.utf8))
        XCTAssertFalse(complianceBody?.message?.contains("secret999") ?? true)
        XCTAssertFalse(complianceBody?.message?.contains("abc123") ?? true)
        let complianceError = DapiError.refused(status: 403, code: "compliance_blocked", message: complianceBody?.message)
        XCTAssertTrue(complianceError.userMessage.contains("billing details"), complianceError.userMessage)
        XCTAssertTrue(complianceError.userMessage.contains("3DAPI’s dashboard"))
        XCTAssertFalse(complianceError.userMessage.contains("http"))

        let scope = dapiErrorBody(Data(errorBody(403, "missing_scope", details: #"{"scope":"orders:write"}"#).utf8))
        XCTAssertTrue(DapiError.refused(status: 403, code: "missing_scope", message: scope?.message).userMessage.contains("orders:write"))
        let customerScope = DapiError.refused(status: 403, code: "missing_scope", message: "Needs orders:read_customer.").userMessage
        XCTAssertTrue(customerScope.contains("orders:read_customer"), customerScope)
        let generic = DapiError.refused(status: 403, code: "missing_scope", message: "Nope.").userMessage
        XCTAssertTrue(generic.contains("permission"))
        XCTAssertNil(dapiScopeNamed(in: "admin:everything"))

        for code in ["payment_failed", "insufficient_balance", "production_unavailable", "card_payments_unavailable", "quote_not_approved",
                     "compliance_blocked", "vat_number_invalid", "material_not_allowed", "material_slots_mismatch",
                     "suggestions_unavailable", "extra_not_found"] {
            let text = DapiError.refused(status: 402, code: code, message: nil).userMessage
            XCTAssertTrue(text.localizedCaseInsensitiveContains("nothing was charged"), "\(code): \(text)")
        }
        // Activity stays status-only, whatever the message holds.
        let detailed = DapiError.refused(status: 422, code: "material_slots_mismatch", message: "ord_TestOrder0001 for person@example.com, 1 Test Street")
        XCTAssertEqual(detailed.activityDetail, "HTTP 422 material_slots_mismatch")
        XCTAssertEqual(DapiError.outcomeUnknown("ord_TestOrder0001 plinth-test-0001").activityDetail, "Outcome unknown")
    }

    // MARK: Parity review fixes

    func testSampleCreditIsSentOnlyWhenTicked() throws {
        var ticked = orderRequest()
        ticked.useSampleCredit = true
        XCTAssertEqual(dapiOrderRequestBody(ticked)["use_sample_credit"] as? Bool, true)
        XCTAssertEqual(dapiOrderRequestBody(ticked)["mode"] as? String, "wallet")
        // Off (the default): the key is omitted, never sent as false.
        XCTAssertFalse(dapiOrderRequestBody(orderRequest()).keys.contains("use_sample_credit"))
        let data = try JSONSerialization.data(withJSONObject: dapiOrderRequestBody(orderRequest()))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("use_sample_credit"))
    }

    func testPlaceOrderSendsSampleCreditOnlyWhenTicked() async throws {
        var ticked = orderRequest()
        ticked.useSampleCredit = true
        let (client, transport) = makeClient([.reply(201, orderJSON())])
        _ = try await client.placeOrder(ticked, idempotencyKey: "plinth-order-0001")
        let body = try XCTUnwrap(transport.sentRequests.first.flatMap(json))
        XCTAssertEqual(body["use_sample_credit"] as? Bool, true)
    }

    func testSuggestedMaterialIDsAreParsedAndValidated() throws {
        let quote: [String: Any] = [
            "id": "qte_TestQuote0001", "status": "ready",
            "suggested_materials": [
                ["slot": 1, "material": ["id": "mat_TestRed", "name": "PLA Red"], "match": "exact"],
                ["slot": 2, "material": ["id": "mat_bad/../x", "name": "PLA Odd"]],
                ["slot": 3, "material": ["name": "PLA Blue"]],
                ["slot": 4, "material": ["id": "qte_NotAMaterial"]],
                ["slot": 5]
            ]
        ]
        let parsed = try XCTUnwrap(dapiParseQuote(quote))
        XCTAssertEqual(parsed.suggestedMaterials.map(\.materialID), ["mat_TestRed", nil, nil, nil, nil])
        XCTAssertEqual(parsed.suggestedMaterials.map(\.slot), [1, 2, 3, 4, 5])
        XCTAssertEqual(parsed.suggestedMaterials.first?.materialName, "PLA Red")
    }

    func testRefusalCopyForOrdering() {
        let paused = DapiError.refused(status: 409, code: "production_unavailable", message: "Production is paused.").userMessage
        XCTAssertEqual(paused, "3DAPI has paused production, so it isn’t taking orders right now. Nothing was charged. Try again later.")

        let notCancellable = DapiError.refused(status: 409, code: "order_not_cancellable", message: nil).userMessage
        XCTAssertTrue(notCancellable.contains("already cancelled"), notCancellable)
        XCTAssertTrue(notCancellable.contains("production partner already has it"), notCancellable)
        XCTAssertFalse(notCancellable.contains("charged"), "a refused cancel says nothing about charges")

        // `details.expected_slots` is named, through `dapiErrorBody`.
        let mismatch = errorBody(422, "material_slots_mismatch", message: "Slots don't match.", details: #"{"expected_slots":[2,1]}"#)
        let mismatchBody = dapiErrorBody(Data(mismatch.utf8))
        let mismatchText = DapiError.refused(status: 422, code: "material_slots_mismatch", message: mismatchBody?.message).userMessage
        XCTAssertTrue(mismatchText.contains("This quote needs a material for slots 1 and 2."), mismatchText)
        XCTAssertTrue(mismatchText.contains("nothing was charged"), mismatchText)
        XCTAssertEqual(dapiExpectedSlotsSentence([3]), "This quote needs a material for slot 3.")
        XCTAssertEqual(dapiExpectedSlotsSentence([1, 2, 3, 3]), "This quote needs a material for slots 1, 2 and 3.")
        XCTAssertEqual(dapiExpectedSlotsSentence([["slot": 2], ["slot": 1]]), "This quote needs a material for slots 1 and 2.")
        XCTAssertNil(dapiExpectedSlotsSentence([0, 17, "x", true] as [Any]))
        XCTAssertNil(dapiExpectedSlotsSentence(nil))
        let noSlots = DapiError.refused(status: 422, code: "material_slots_mismatch", message: "Nope.").userMessage
        XCTAssertTrue(noSlots.contains("each slot the quote lists"), noSlots)

        // Any refused Place Order says nothing was charged; other refusals don't claim it.
        let generic = dapiRefusalMessage(status: 400, code: "validation_failed", message: "Bad.", placingOrder: true)
        XCTAssertTrue(generic.hasSuffix(dapiNothingChargedSentence), generic)
        XCTAssertFalse(dapiRefusalMessage(status: 400, code: "validation_failed", message: "Bad.").contains("charged"))
        let alreadySays = dapiRefusalMessage(status: 409, code: "production_unavailable", message: nil, placingOrder: true)
        XCTAssertEqual(alreadySays.components(separatedBy: "charged").count, 2, "said once: \(alreadySays)")
        // Still redacted.
        let leaky = dapiRefusalMessage(status: 400, code: "something_new", message: "key \(orderTestKey) refused", placingOrder: true)
        XCTAssertFalse(leaky.contains("0000test"), leaky)
    }

    func testEveryDocumentedScopeIsNamed() {
        for scope in ["products:read", "products:write", "stocks:read", "stocks:write", "qc:read", "qc:write",
                      "quotes:read", "quotes:write", "orders:read", "orders:write", "orders:read_customer", "extras:read",
                      "extras:write", "wallet:read", "webhooks:read"] {
            XCTAssertEqual(dapiScopeNamed(in: "Scope needed: \(scope)."), scope)
            XCTAssertTrue(DapiError.refused(status: 403, code: "missing_scope", message: "Needs \(scope).").userMessage.contains(scope))
        }
    }

    func testAListPageWithoutItemsIsNotAnError() async throws {
        let page = #"{"object":"list","data":[\#(orderJSON(items: false))],"has_more":false,"next_cursor":null}"#
        let (client, _) = makeClient([.reply(200, page)])
        let result = try await client.orders(DapiOrderListQuery())
        XCTAssertEqual(result.orders.count, 1)
        XCTAssertNil(result.orders.first?.items, "no lines read, not an empty list")
        XCTAssertEqual(result.orders.first?.itemCount, 3, "the count still comes from item_count")
    }

    func testOrderingProblemTellsRejectedFromPending() {
        let rejected = dapiOrderingProblem(account: DapiAccount(kind: "integrator", approval: "rejected", effectiveScopes: ["orders:write"]),
                                           onboardingOrderBlockers: [])
        XCTAssertEqual(rejected, "3DAPI turned down this account’s approval. Check 3DAPI’s dashboard or email contact@dapi.digital.")
        for pending in ["pending", nil, "something_new"] as [String?] {
            let text = dapiOrderingProblem(account: DapiAccount(kind: "integrator", approval: pending, effectiveScopes: ["orders:write"]),
                                           onboardingOrderBlockers: [])
            XCTAssertEqual(text, "3DAPI hasn’t approved this account yet. Ordering opens once 3DAPI approves it.", "\(String(describing: pending))")
        }
        XCTAssertNil(dapiOrderingProblem(account: DapiAccount(kind: "integrator", approval: "Approved", effectiveScopes: ["orders:write"]),
                                         onboardingOrderBlockers: []))
    }
}
