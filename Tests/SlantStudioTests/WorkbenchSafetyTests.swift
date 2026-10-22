import XCTest
@testable import SlantStudio

final class WorkbenchSafetyTests: XCTestCase {
    func testWorkbenchChargeAllowedRequiresLoadedDraft() {
        XCTAssertEqual(workbenchChargeAllowed(status: nil, loaded: false).0, false)
        XCTAssertEqual(workbenchChargeAllowed(status: nil, loaded: false).1, "Couldn’t load this order’s costs.")
        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: false).0, false)
        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: false).1, "Couldn’t load this order’s costs.")

        XCTAssertEqual(workbenchChargeAllowed(status: nil, loaded: true).0, false)
        XCTAssertEqual(workbenchChargeAllowed(status: nil, loaded: true).1, "Only drafts can be placed.")
        XCTAssertEqual(workbenchChargeAllowed(status: "PAID", loaded: true).0, false)
        XCTAssertEqual(workbenchChargeAllowed(status: "PAID", loaded: true).1, "Only drafts can be placed.")
        XCTAssertEqual(workbenchChargeAllowed(status: "printing", loaded: true).1, "Only drafts can be placed.")

        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: true).0, true)
        XCTAssertNil(workbenchChargeAllowed(status: "DRAFT", loaded: true).1)
        XCTAssertEqual(workbenchChargeAllowed(status: "draft", loaded: true).0, true)
        XCTAssertNil(workbenchChargeAllowed(status: "Draft", loaded: true).1)
    }

    func testWorkbenchChargeAllowedRequiresNumericTotal() {
        let noTotal: [String: Any] = ["status": "DRAFT"]
        XCTAssertFalse(workbenchOrderHasNumericTotal(noTotal))
        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: noTotal).0, false)
        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: noTotal).1, "Order total isn’t available yet.")
        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: nil).0, false)

        // Printing-only must not pass (orderTotalMoney fallback would still format a number).
        let printingOnly: [String: Any] = ["status": "DRAFT", "printingCost": "4.00"]
        XCTAssertFalse(workbenchOrderHasNumericTotal(printingOnly))
        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: printingOnly).0, false)
        let deliveryOnly: [String: Any] = ["status": "DRAFT", "deliveryCost": "2.00"]
        XCTAssertFalse(workbenchOrderHasNumericTotal(deliveryOnly))

        let bothCosts: [String: Any] = ["status": "DRAFT", "printingCost": "4.00", "deliveryCost": "2.50"]
        XCTAssertTrue(workbenchOrderHasNumericTotal(bothCosts))
        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: bothCosts).0, true)

        let withTotal: [String: Any] = ["status": "DRAFT", "total": "12.50"]
        XCTAssertTrue(workbenchOrderHasNumericTotal(withTotal))
        XCTAssertEqual(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: withTotal).0, true)
        XCTAssertNil(workbenchChargeAllowed(status: "DRAFT", loaded: true, order: withTotal).1)

        // “—” == “—” must not pass recheck matching
        XCTAssertFalse(workbenchOrderPreviewMatches(noTotal, noTotal))
        XCTAssertFalse(workbenchOrderPreviewMatches(printingOnly, printingOnly))
        XCTAssertTrue(workbenchOrderPreviewMatches(bothCosts, bothCosts))
    }

    func testWorkbenchMutationSendLocksAfterAttempt() {
        XCTAssertEqual(workbenchMutationSendAllowed(attempted: false, succeeded: false).0, true)
        XCTAssertNil(workbenchMutationSendAllowed(attempted: false, succeeded: false).1)

        let locked = workbenchMutationSendAllowed(attempted: true, succeeded: false)
        XCTAssertFalse(locked.0)
        XCTAssertEqual(locked.1, "The result is unknown. Check Orders (or reload this order) before trying again.")

        XCTAssertFalse(workbenchMutationSendAllowed(attempted: true, succeeded: true).0)
        XCTAssertFalse(workbenchMutationSendAllowed(attempted: false, succeeded: true).0)
    }

    func testWorkbenchUnknownOutcomeBlockMessage() {
        XCTAssertEqual(
            workbenchUnknownOutcomeBlockMessage,
            "A previous attempt for this order has an unknown result. Reload the order; if its status hasn’t changed, check it in your Slant dashboard before trying again."
        )
    }

    func testOutcomeResolvedPayAndCancel() {
        XCTAssertFalse(outcomeResolved(action: .pay, reviewedStatus: "DRAFT", reloadedStatus: "DRAFT"))
        XCTAssertTrue(outcomeResolved(action: .pay, reviewedStatus: "DRAFT", reloadedStatus: "QUEUED"))
        XCTAssertTrue(outcomeResolved(action: .pay, reviewedStatus: "DRAFT", reloadedStatus: "PAID"))
        XCTAssertFalse(outcomeResolved(action: .cancel, reviewedStatus: "QUEUED", reloadedStatus: "QUEUED"))
        XCTAssertTrue(outcomeResolved(action: .cancel, reviewedStatus: "QUEUED", reloadedStatus: "CANCELED"))
    }

    func testWorkbenchCancelAllowedMirrorsOrdersEligibility() {
        XCTAssertEqual(workbenchCancelAllowed(status: nil, loaded: false).0, false)
        XCTAssertEqual(workbenchCancelAllowed(status: nil, loaded: false).1, "Couldn’t load this order.")
        XCTAssertEqual(workbenchCancelAllowed(status: "DRAFT", loaded: false).1, "Couldn’t load this order.")

        for status in ["DRAFT", "PAID", "QUEUED", "PROCESSING", "PRINTING", "IN_REVIEW", "PAYMENT_ERROR",
                       "AWAITING_SHIPMENT", "COMPLETED", "draft", "queued"] {
            XCTAssertEqual(workbenchCancelAllowed(status: status, loaded: true).0, true, status)
            XCTAssertNil(workbenchCancelAllowed(status: status, loaded: true).1, status)
        }

        XCTAssertEqual(workbenchCancelAllowed(status: "CANCELED", loaded: true).1, "This order was already cancelled.")
        XCTAssertEqual(workbenchCancelAllowed(status: "SHIPPED", loaded: true).0, true)
        XCTAssertNil(workbenchCancelAllowed(status: "SHIPPED", loaded: true).1)
        XCTAssertEqual(workbenchCancelAllowed(status: nil, loaded: true).0, false)
    }

    func testWorkbenchConfirmSendNeverUsesReturnDefaultForMutatingEndpoints() {
        let endpoints: [(String, String)] = [
            ("POST", "/orders"),
            ("POST", "/orders/{publicOrderId}"),
            ("POST", "/orders/batch"),
            ("DELETE", "/orders/{publicOrderId}"),
            ("DELETE", "/platforms/{platformId}"),
            ("DELETE", "/files/{publicFileId}"),
            ("PATCH", "/platforms/{platformId}"),
            ("PATCH", "/platforms/{platformId}/enable"),
            ("PATCH", "/platforms/{platformId}/webhook-secret"),
            ("PATCH", "/files/{publicFileId}"),
            ("POST", "/platforms/{platformId}/webhook/dummy"),
            ("POST", "/platforms/{platformId}/webhook/resend"),
            ("POST", "/platforms/{platformId}/webhook/{webhookId}/resend"),
            ("POST", "/slant/webhook"),
            ("POST", "/files"),
            ("POST", "/files/direct-upload"),
            ("POST", "/files/confirm-upload"),
            ("POST", "/files/batch"),
            ("POST", "/files/openScad"),
            ("POST", "/files/{publicFileId}/estimate"),
            ("POST", "/platforms"),
            ("GET", "/usage"),
            ("GET", "/orders/{publicOrderId}")
        ]
        for (method, path) in endpoints {
            XCTAssertFalse(
                workbenchConfirmSendUsesReturnDefault(method: method, path: path),
                "\(method) \(path) must not bind Return on the confirm-sheet send"
            )
        }
    }

    func testWorkbenchOrderPreviewMatchesStatusAndCosts() {
        let preview: [String: Any] = [
            "status": "DRAFT",
            "printingCost": "4.00",
            "deliveryCost": "2.50",
            "total": "6.50"
        ]
        XCTAssertTrue(workbenchOrderPreviewMatches(preview, preview))
        XCTAssertTrue(workbenchOrderPreviewMatches(preview, [
            "status": "draft",
            "printingCost": 4,
            "deliveryCost": "2.50",
            "total": "6.50"
        ]))
        XCTAssertNil(workbenchOrderPreviewMismatchMessage(preview: preview, fresh: preview))

        XCTAssertFalse(workbenchOrderPreviewMatches(preview, [
            "status": "PAID",
            "printingCost": "4.00",
            "deliveryCost": "2.50",
            "total": "6.50"
        ]))
        XCTAssertEqual(
            workbenchOrderPreviewMismatchMessage(preview: preview, fresh: [
                "status": "DRAFT",
                "printingCost": "5.00",
                "deliveryCost": "2.50",
                "total": "7.50"
            ]),
            "This order changed since you reviewed it. Go back and review again."
        )
        XCTAssertFalse(workbenchOrderPreviewMatches(preview, [
            "status": "DRAFT",
            "printingCost": "4.00",
            "deliveryCost": "3.00",
            "total": "7.00"
        ]))
    }

    func testWorkbenchTypedConfirmationFailClosedOnEmptyTarget() {
        let emptyPlatform = workbenchBakedConfirmPhrase(method: "DELETE", templatePath: "/platforms/{platformId}", resolvedPath: "/platforms/")
        XCTAssertEqual(emptyPlatform, "")
        let emptyGate = workbenchTypedConfirmationAllowed(bakedPhrase: emptyPlatform, typed: "")
        XCTAssertFalse(emptyGate.0)
        XCTAssertEqual(emptyGate.1, "Enter the target id to confirm.")

        let emptyFile = workbenchBakedConfirmPhrase(method: "DELETE", templatePath: "/files/{publicFileId}", resolvedPath: "/files/")
        XCTAssertEqual(emptyFile, "")
        XCTAssertEqual(workbenchTypedConfirmationAllowed(bakedPhrase: emptyFile, typed: "anything").1, "Enter the target id to confirm.")

        // High-risk ops never return nil (nil would fail-open).
        XCTAssertNotNil(workbenchBakedConfirmPhrase(method: "DELETE", templatePath: "/platforms/{platformId}", resolvedPath: "/platforms/"))
        XCTAssertNotNil(workbenchBakedConfirmPhrase(method: "DELETE", templatePath: "/files/{publicFileId}", resolvedPath: "/files/"))
        XCTAssertNotNil(workbenchBakedConfirmPhrase(method: "PATCH", templatePath: "/platforms/{platformId}/webhook-secret", resolvedPath: "/platforms//webhook-secret"))
    }

    func testWorkbenchTypedConfirmationUsesBakedTargetNotLiveFields() {
        XCTAssertEqual(
            workbenchBakedConfirmPhrase(method: "DELETE", templatePath: "/platforms/{platformId}", resolvedPath: "/platforms/plat-baked"),
            "plat-baked"
        )
        XCTAssertEqual(
            workbenchBakedConfirmPhrase(method: "DELETE", templatePath: "/files/{publicFileId}", resolvedPath: "/files/file-baked"),
            "file-baked"
        )
        XCTAssertEqual(
            workbenchBakedConfirmPhrase(method: "PATCH", templatePath: "/platforms/{platformId}/webhook-secret", resolvedPath: "/platforms/plat-1/webhook-secret"),
            "rotate"
        )
        XCTAssertNil(workbenchBakedConfirmPhrase(method: "POST", templatePath: "/orders", resolvedPath: "/orders"))
        XCTAssertNil(workbenchBakedConfirmPhrase(method: "DELETE", templatePath: "/orders/{publicOrderId}", resolvedPath: "/orders/ord-1"))

        let baked = workbenchBakedConfirmPhrase(method: "DELETE", templatePath: "/platforms/{platformId}", resolvedPath: "/platforms/plat-baked")
        XCTAssertTrue(workbenchTypedConfirmationAllowed(bakedPhrase: baked, typed: "plat-baked").0)
        XCTAssertTrue(workbenchTypedConfirmationAllowed(bakedPhrase: baked, typed: "  plat-baked  ").0)
        XCTAssertFalse(workbenchTypedConfirmationAllowed(bakedPhrase: baked, typed: "plat-live-field").0)
        XCTAssertTrue(workbenchTypedConfirmationAllowed(bakedPhrase: "rotate", typed: "rotate").0)
        XCTAssertFalse(workbenchTypedConfirmationAllowed(bakedPhrase: "rotate", typed: "Rotate").0)
        XCTAssertTrue(workbenchTypedConfirmationAllowed(bakedPhrase: nil, typed: "").0)
    }

    func testWorkbenchDisplayedResponseRedactsSecretsWhenToggleOff() {
        let json: [String: Any] = [
            "name": "Shop",
            "webhookSecret": "super-secret-value",
            "nested": ["apiSecret": "nested-secret"]
        ]
        let redacted = workbenchDisplayedResponse(path: "/platforms/{platformId}", json: json, fallback: "fallback", showSecrets: false)
        XCTAssertFalse(redacted.contains("super-secret-value"))
        XCTAssertFalse(redacted.contains("nested-secret"))
        XCTAssertTrue(redacted.contains("Hidden"))
        XCTAssertTrue(redacted.contains("Shop"))

        let revealed = workbenchDisplayedResponse(path: "/platforms/{platformId}", json: json, fallback: "fallback", showSecrets: true)
        XCTAssertTrue(revealed.contains("super-secret-value"))
        XCTAssertTrue(revealed.contains("nested-secret"))
    }

    func testWorkbenchDisplayedResponseLeavesOpenSCADFallbackAlone() {
        let stlNote = "STL generated successfully · 12 KB\nSave the STL or import it into your model library."
        let json: [String: Any] = ["webhookSecret": "should-not-appear"]
        XCTAssertEqual(
            workbenchDisplayedResponse(path: "/files/openScad", json: json, fallback: stlNote, showSecrets: false),
            stlNote
        )
    }

    func testWorkbenchUnwrapOrderPrefersNestedOrder() {
        let nested = workbenchUnwrapOrder(["order": ["status": "DRAFT", "printingCost": "1.00"], "extra": true])
        XCTAssertEqual(nested["status"] as? String, "DRAFT")
        let flat = workbenchUnwrapOrder(["status": "PAID", "printingCost": "2.00"])
        XCTAssertEqual(flat["status"] as? String, "PAID")
    }

    func testWorkbenchDeleteWarningIsPerTarget() {
        XCTAssertEqual(
            workbenchDeleteWarning(path: "/orders/{publicOrderId}"),
            "Cancels the order and refunds it. If it already shipped, Slant only refunds it."
        )
        XCTAssertEqual(workbenchDeleteWarning(path: "/platforms/{platformId}"), "Disables this platform.")
        XCTAssertEqual(workbenchDeleteWarning(path: "/files/{publicFileId}"), "Deletes this uploaded model.")
    }

    func testValidateJSONEnforcesStringLengthPatternAndEnum() throws {
        try validateJSON("stl", schema: ["type": "string", "enum": ["stl", "obj", "3mf"]], path: "type")
        XCTAssertThrowsError(try validateJSON("step", schema: ["type": "string", "enum": ["stl", "obj", "3mf"]], path: "type"))
        XCTAssertThrowsError(try validateJSON("ab", schema: ["type": "string", "minLength": 3], path: "name"))
        XCTAssertThrowsError(try validateJSON("abcdef", schema: ["type": "string", "maxLength": 5], path: "name"))
        try validateJSON("#a1a1a1", schema: ["type": "string", "pattern": "^#[0-9a-f]{6}$"], path: "hex")
        XCTAssertThrowsError(try validateJSON("#ZZZZZZ", schema: ["type": "string", "pattern": "^#[0-9a-f]{6}$"], path: "hex"))
    }

    func testValidateQueryParameterEnumAndBounds() throws {
        try validateQueryParameter(name: "limit", value: "50", schema: ["type": "integer", "minimum": 1, "maximum": 200])
        XCTAssertThrowsError(try validateQueryParameter(name: "limit", value: "201", schema: ["type": "integer", "minimum": 1, "maximum": 200]))
        XCTAssertThrowsError(try validateQueryParameter(name: "status", value: "NOPE", schema: ["type": "string", "enum": ["DRAFT", "QUEUED"]]))
        try validateQueryParameter(name: "status", value: "DRAFT", schema: ["type": "string", "enum": ["DRAFT", "QUEUED"]])
    }

    func testValidateOrderMetadataLimitsKeysAndDepth() throws {
        try validateOrderMetadata(["a": 1, "b": 2])
        let eleven = Dictionary(uniqueKeysWithValues: (0..<11).map { ("k\($0)", $0 as Any) })
        XCTAssertThrowsError(try validateOrderMetadata(eleven))
        try validateOrderMetadata(["a": ["b": ["c": 1]]])
        XCTAssertThrowsError(try validateOrderMetadata(["a": ["b": ["c": ["d": 1]]]]))
    }

    func testCatalogAcceptsObjAnd3mfFileTypes() throws {
        let endpoints = EndpointCatalog.load()
        XCTAssertFalse(endpoints.isEmpty)
        guard let direct = endpoints.first(where: { $0.id == "POST /files/direct-upload" }) else {
            return XCTFail("missing direct-upload endpoint")
        }
        XCTAssertTrue(direct.bodySchema.contains("\"obj\""))
        XCTAssertTrue(direct.bodySchema.contains("\"3mf\""))
        try validateJSON("obj", schema: ["type": "string", "enum": ["stl", "obj", "3mf"]], path: "type")
        try validateJSON("3mf", schema: ["type": "string", "enum": ["stl", "obj", "3mf"]], path: "type")
    }
}
