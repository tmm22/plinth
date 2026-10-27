import XCTest
@testable import SlantStudio

final class WorkflowTests: XCTestCase {
    private func response(_ object: Any) throws -> APIResponse {
        APIResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
    }

    func testCatalogIncludesAllDocumentedOperationsWithoutDuplicates() {
        let endpoints = EndpointCatalog.load()
        XCTAssertEqual(endpoints.count, 42)
        XCTAssertEqual(Set(endpoints.map(\.id)).count, endpoints.count)
        for id in ["POST /files", "POST /files/direct-upload", "POST /files/confirm-upload", "POST /files/openScad", "POST /files/{publicFileId}/estimate", "POST /orders", "POST /orders/{publicOrderId}", "POST /slant/webhook", "PATCH /platforms/{platformId}/enable"] {
            XCTAssertTrue(endpoints.contains { $0.id == id }, "Missing \(id)")
        }
        XCTAssertFalse(endpoints.contains { $0.path.contains("customers") || $0.path.contains("checkout") })
    }

    func testAuthenticationAvailabilityMatchesPublishedSpec() throws {
        let endpoints = EndpointCatalog.load()
        XCTAssertEqual(Set(endpoints.filter(\.sessionOnly).map(\.id)), ["GET /apiKey", "POST /apiKey"])
        let health = try XCTUnwrap(endpoints.first { $0.path == "/health/status" })
        XCTAssertFalse(health.requiresAuth)
        XCTAssertTrue(endpoints.filter { $0.path != "/health/status" }.allSatisfy(\.requiresAuth))
    }

    func testAllBodyTemplatesAndSchemasAreValidJSON() throws {
        for endpoint in EndpointCatalog.load() where !endpoint.bodyTemplate.isEmpty {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(endpoint.bodyTemplate.utf8)), endpoint.id)
            let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(endpoint.bodySchema.utf8)) as? [String: Any])
            XCTAssertEqual(schema["type"] as? String, "object", endpoint.id)
            XCTAssertFalse(endpoint.bodySchema.contains("\"$ref\""), "Unresolved reference: \(endpoint.id)")
        }
    }

    func testDraftSchemaIncludesResolvedAddressAndOptionalMetadata() throws {
        let endpoint = try XCTUnwrap(EndpointCatalog.load().first { $0.id == "POST /orders" })
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(endpoint.bodySchema.utf8)) as? [String: Any])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertNotNil(properties["metadata"])
        XCTAssertNotNil(properties["options"])
        XCTAssertTrue(endpoint.bodySchema.contains("line1"))
        XCTAssertTrue(endpoint.bodySchema.contains("componentId"))
        XCTAssertTrue(endpoint.bodySchema.contains("stationeryId"))
        let template = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(endpoint.bodyTemplate.utf8)) as? [String: Any])
        let item = try XCTUnwrap((template["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["type"] as? String, "PRINT")
        XCTAssertNotNil(item["publicFileServiceId"])
        XCTAssertNotNil(item["filamentId"])
        XCTAssertEqual(item["quantity"] as? Int, 1)
    }

    func testOptionalFieldsDoNotGenerateInvalidEmptyIdentifiers() throws {
        let endpoint = try XCTUnwrap(EndpointCatalog.load().first { $0.id == "POST /files/{publicFileId}/estimate" })
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(endpoint.bodyTemplate.utf8)) as? [String: Any])
        XCTAssertTrue(body.isEmpty, "Omitting options uses one PLA Black print without invalid empty IDs")
        let patch = try XCTUnwrap(EndpointCatalog.load().first { $0.id == "PATCH /platforms/{platformId}" })
        let patchBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(patch.bodyTemplate.utf8)) as? [String: Any])
        XCTAssertNil(patchBody["webhookSecret"], "Do not suggest clearing a live signing secret")
    }

    func testRecordIdentifiersMatchFilePlatformFilamentAndOrderSchemas() {
        XCTAssertEqual(Record(values: ["id": 123, "publicFileServiceId": "file-uuid", "name": "model"]).id, "file-uuid")
        XCTAssertEqual(Record(values: ["id": "platform-uuid", "name": "Store"]).id, "platform-uuid")
        XCTAssertEqual(Record(values: ["publicId": "filament-uuid", "name": "PLA Black"]).id, "filament-uuid")
        XCTAssertEqual(Record(values: ["publicId": "SLANT_123", "id": 99]).id, "SLANT_123")
    }

    func testListResponsesAcceptDirectAndNestedDataArrays() throws {
        let records: [[String: Any]] = [["publicId": "SLANT_1"], ["publicId": "SLANT_2"]]
        XCTAssertEqual(responseRecords(try response(["success": true, "data": records])).map(\.id), ["SLANT_1", "SLANT_2"])
        XCTAssertEqual(responseRecords(try response(["success": true, "data": ["orders": records]])).map(\.id), ["SLANT_1", "SLANT_2"])
        XCTAssertTrue(responseRecords(try response(["success": true, "data": []])).isEmpty)
    }

    func testObjectResponsesPreserveBothDocumentedOrderShapesAndMetrics() throws {
        let direct = responseObject(try response(["success": true, "data": ["publicId": "SLANT_1", "status": "PAID"]]))
        XCTAssertEqual(direct["publicId"] as? String, "SLANT_1")
        let nested = responseObject(try response(["success": true, "data": ["order": ["publicId": "SLANT_1"], "totals": ["totalCost": 10.0]]]))
        XCTAssertEqual((nested["order"] as? [String: Any])?["publicId"] as? String, "SLANT_1")
        XCTAssertNotNil(nested["totals"])
        let record = Record(values: ["metrics": ["x": 20], "STLMetrics": ["x": 10]])
        XCTAssertEqual(record.metrics["x"] as? Int, 20)
    }

    func testOrderLinesUseTypeSpecificReferencesAndPreserveOptions() throws {
        let printItem = try OrderLine(reference: "file", filamentID: "filament", quantity: 3, name: "Widget", sku: "SKU-1", optionsJSON: "{\"custom\":true}").payload()
        XCTAssertEqual(printItem["publicFileServiceId"] as? String, "file")
        XCTAssertEqual(printItem["filamentId"] as? String, "filament")
        XCTAssertEqual(printItem["quantity"] as? Int, 3)
        XCTAssertEqual(printItem["name"] as? String, "Widget")
        XCTAssertEqual(printItem["SKU"] as? String, "SKU-1")
        XCTAssertEqual((printItem["options"] as? [String: Bool])?["custom"], true)
        let component = try OrderLine(type: "COMPONENT", reference: "component").payload()
        XCTAssertEqual(component["componentId"] as? String, "component")
        XCTAssertNil(component["publicFileServiceId"])
        let stationery = try OrderLine(type: "STATIONERY", reference: "card", imageURL: "https://example.com/card.png").payload()
        XCTAssertEqual(stationery["stationeryId"] as? String, "card")
        XCTAssertEqual(stationery["imageUrl"] as? String, "https://example.com/card.png")
    }

    func testOrderLineRejectsMissingReferenceInvalidQuantityAndNonObjectOptions() {
        XCTAssertThrowsError(try OrderLine(reference: "  ").payload())
        XCTAssertThrowsError(try OrderLine(reference: "file", filamentID: "filament", quantity: 0).payload())
        XCTAssertThrowsError(try OrderLine(reference: "file").payload(), "PRINT items require a material")
        XCTAssertThrowsError(try OrderLine(reference: "file", filamentID: "filament", optionsJSON: "[]").payload())
        XCTAssertThrowsError(try OrderLine(reference: "file", filamentID: "filament", optionsJSON: "invalid").payload())
    }

    func testCompleteOrderDraftPayloadMatchesGuidedFields() throws {
        let body = try orderDraftPayload(
            platformID: "platform", ownerID: "owner", email: "buyer@example.com", recipientName: "Buyer",
            line1: "1 Main St", line2: "", city: "Melbourne", state: "VIC", zip: "3000", country: "Australia",
            paymentID: "payment", metadata: ["source": "test"], options: ["priority": true],
            lines: [OrderLine(reference: "file", filamentID: "filament", quantity: 2)]
        )
        XCTAssertEqual(body["platformId"] as? String, "platform")
        XCTAssertEqual(body["ownerId"] as? String, "owner")
        XCTAssertEqual((body["options"] as? [String: Bool])?["priority"], true)
        let customer = try XCTUnwrap(body["customer"] as? [String: Any])
        let details = try XCTUnwrap(customer["details"] as? [String: Any])
        XCTAssertEqual(details["email"] as? String, "buyer@example.com")
        let address = try XCTUnwrap(details["address"] as? [String: String])
        XCTAssertEqual(address["country"], "AUSTRALIA")
        let item = try XCTUnwrap((body["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["filamentId"] as? String, "filament")
        XCTAssertEqual(item["quantity"] as? Int, 2)
    }

    func testCancellationOnlyOfferedBeforeProduction() {
        for status in ["PAID", "SUBMITTED", "QUEUED", "PROCESSING", "PRINTING", "IN_REVIEW", "PAYMENT_ERROR",
                       "AWAITING_SHIPMENT", "POST_PROCESSING", "COMPLETED", "ITEMS_ON_SHELF", "SHIPPED", "DELIVERED"] {
            XCTAssertTrue(orderCanRequestCancellation(status), status)
        }
        // Slant refuses to cancel drafts.
        for status in ["DRAFT", "CANCELED", "UNKNOWN", ""] {
            XCTAssertFalse(orderCanRequestCancellation(status), status)
        }
    }

    func testMoneyUsesDecimalParsing() {
        XCTAssertEqual(money("4.06"), "$4.06")
        XCTAssertEqual(money("12345678901234567890.12"), "$12,345,678,901,234,567,890.12")
        XCTAssertEqual(money(nil), "—")
    }

    func testOrdersBatchAcceptsRenderedDocumentationKey() throws {
        let normalized = try XCTUnwrap(normalizedRequestBody(["publicIds": ["SLANT_1"]], endpointID: "POST /orders/batch") as? [String: Any])
        XCTAssertNil(normalized["publicIds"])
        XCTAssertEqual(normalized["public_ids"] as? [String], ["SLANT_1"])
        let endpoint = try XCTUnwrap(EndpointCatalog.load().first { $0.id == "POST /orders/batch" })
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(endpoint.bodySchema.utf8)) as? [String: Any])
        XCTAssertNoThrow(try validateJSON(normalized, schema: schema))
    }

    func testRequestValidationChecksNestedRequiredFieldsAndBounds() throws {
        let source: [String: Any] = ["type": "object", "required": ["name"], "properties": ["quantity": ["type": "integer", "minimum": 1], "type": ["type": "string", "enum": ["PRINT", "COMPONENT"]]]]
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: source)) as? [String: Any])
        XCTAssertThrowsError(try validateJSON(["name": " "], schema: schema))
        XCTAssertThrowsError(try validateJSON(["name": "model", "quantity": 0], schema: schema))
        XCTAssertThrowsError(try validateJSON(["name": "model", "type": "INVALID"], schema: schema))
        XCTAssertNoThrow(try validateJSON(["name": "model", "quantity": 1, "type": "PRINT"], schema: schema))
    }

    func testPlatformDraftSendsRequiredFieldsAndOmitsBlankOptionals() throws {
        let body = try PlatformDraft(name: "  My shop ", url: " https://shop.example.com ", description: "  ", webhookURL: "").payload()
        XCTAssertEqual(body["name"] as? String, "My shop")
        XCTAssertEqual(body["url"] as? String, "https://shop.example.com")
        XCTAssertNil(body["description"])
        XCTAssertNil(body["webhookURL"])
        let full = try PlatformDraft(name: "Shop", url: "https://shop.example.com", description: "Prints", webhookURL: "https://shop.example.com/hooks").payload()
        XCTAssertEqual(full["description"] as? String, "Prints")
        XCTAssertEqual(full["webhookURL"] as? String, "https://shop.example.com/hooks")
    }

    func testPlatformDraftRejectsMissingNameAndInvalidURLs() {
        XCTAssertThrowsError(try PlatformDraft(name: " ", url: "https://shop.example.com").payload())
        XCTAssertThrowsError(try PlatformDraft(name: "Shop", url: "").payload())
        XCTAssertThrowsError(try PlatformDraft(name: "Shop", url: "shop.example.com").payload())
        XCTAssertThrowsError(try PlatformDraft(name: "Shop", url: "ftp://shop.example.com").payload())
        XCTAssertThrowsError(try PlatformDraft(name: "Shop", url: "https://shop.example.com", webhookURL: "http://shop.example.com/hooks").payload())
    }

    func testPlatformDraftMatchesPublishedCreateSchema() throws {
        let endpoint = try XCTUnwrap(EndpointCatalog.load().first { $0.id == "POST /platforms" })
        let schema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(endpoint.bodySchema.utf8)) as? [String: Any])
        XCTAssertEqual(Set(schema["required"] as? [String] ?? []), ["name", "url"])
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let body = try PlatformDraft(name: "Shop", url: "https://shop.example.com", description: "Prints", webhookURL: "https://shop.example.com/hooks").payload()
        XCTAssertTrue(Set(body.keys).isSubset(of: Set(properties.keys)))
        XCTAssertNoThrow(try validateJSON(body, schema: schema))
    }
}
