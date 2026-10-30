import XCTest
@testable import SlantStudio

/// Round 14 transport fixes: error copy (401, 409, 2xx failures, 429), query encoding, the User-Agent, upload copy by
/// step, Upload from URL, real record IDs, file refresh, platform edits, failed deliveries, catalog prices and the
/// download cap.
final class TransportRound14Tests: XCTestCase {
    private func http(_ status: Int, _ body: String = "", retryAfter: String? = nil, reset: String? = nil) -> APIError {
        APIError.http(status: status, body: body, retryAfter: retryAfter, rateLimitReset: reset)
    }

    // MARK: 401

    func testUnauthorizedAboutTheKeySaysReconnect() {
        let reconnect = "Slant rejected the saved key. Reconnect in Settings."
        // Slant's live unauthenticated reply (28 Oct 2026).
        let live = #"{"error":"Unauthorized","message":"Bearer token required in Authorization header","statusCode":401}"#
        XCTAssertEqual(http(401, live).userMessage, reconnect)
        XCTAssertEqual(http(401).userMessage, reconnect, "no message")
        XCTAssertEqual(http(401, "<html>").userMessage, reconnect, "unreadable body")
        XCTAssertEqual(http(401, #"{"message":"Invalid API key"}"#).userMessage, reconnect)
        XCTAssertEqual(http(401, #"{"error":"Unauthorized"}"#).userMessage, reconnect)
        XCTAssertEqual(http(401, #"{"message":"Not authorised"}"#).userMessage, reconnect)
        XCTAssertEqual(http(401, live).activityDetail, "\(reconnect) (HTTP 401)")
    }

    func testUnauthorizedAboutOwnershipQuotesSlant() {
        let body = #"{"success":false,"error":{"message":"Order belongs to another creator","statusCode":401}}"#
        XCTAssertEqual(http(401, body).userMessage, "Slant refused this request. Order belongs to another creator")
        XCTAssertEqual(http(401, #"{"message":"File belongs to another creator"}"#).activityDetail,
                       "Slant refused this request. File belongs to another creator (HTTP 401)")
        XCTAssertFalse(unauthorizedMessageIsAboutKey("Order belongs to another creator"))
        XCTAssertTrue(unauthorizedMessageIsAboutKey("Bearer token required in Authorization header"))
        // Classification is unchanged: a 401 is still a definite refusal.
        XCTAssertTrue(orderMutationErrorProvesNoEffect(http(401, body)))
    }

    // MARK: 409

    func testConflictCopyIsNeutralAndKeepsTheOutcomeUnknown() {
        XCTAssertEqual(http(409).userMessage,
                       "Slant reported a conflict. Refresh to see the current state before trying again.")
        XCTAssertEqual(http(409, #"{"message":"Order is being processed"}"#).userMessage,
                       "Slant reported a conflict: “Order is being processed.” Refresh to see the current state before trying again.")
        XCTAssertEqual(http(409, #"{"message":"Busy!"}"#).activityDetail,
                       "Slant reported a conflict: “Busy!” Refresh to see the current state before trying again. (HTTP 409)")
        XCTAssertFalse(http(409, #"{"message":"x"}"#).userMessage.contains("couldn’t accept"))
        XCTAssertFalse(orderMutationErrorProvesNoEffect(http(409)), "a 409 stays an unknown outcome")
        // 400 and 422 keep their copy.
        XCTAssertEqual(http(422, #"{"message":"Bad"}"#).userMessage, "Slant couldn’t accept those details. Bad")
    }

    // MARK: 2xx with success: false

    func testReportedFailureQuotesSlantButStaysUnknown() {
        let pretty = """
        {
          "message" : "Out of stock",
          "success" : false
        }
        """
        let error = APIError.invalidResponse("\(slantReportedFailurePrefix)200):\n\(pretty)")
        XCTAssertEqual(error.userMessage, "Slant reported a problem: Out of stock")
        XCTAssertEqual(error.activityDetail, "Slant reported a problem: Out of stock")
        XCTAssertFalse(orderMutationErrorProvesNoEffect(error), "still an unknown outcome")
        XCTAssertEqual(batchPersonaliseUploadOutcome(error: error), .unknown(batchPersonaliseUploadOutcome(error: error).unknownText))

        let nested = APIError.invalidResponse("\(slantReportedFailurePrefix)201):\n{\"error\":{\"message\":\"Try later\"},\"success\":false}")
        XCTAssertEqual(nested.userMessage, "Slant reported a problem: Try later")
        // No message, a JSON-looking one, or another invalid response: the plain copy, no body.
        for diagnostic in ["\(slantReportedFailurePrefix)200):\n{\"success\":false}",
                           "\(slantReportedFailurePrefix)200):\n{\"message\":\"{\\\"a\\\":1}\",\"success\":false}",
                           "\(slantReportedFailurePrefix)200)",
                           "The server returned a non-HTTP response.",
                           "Some other text:\n{\"message\":\"Should not show\"}"] {
            XCTAssertEqual(APIError.invalidResponse(diagnostic).userMessage, "Slant couldn’t complete that request. Try again.", diagnostic)
        }
        // The prefix matches what APIClient.checked throws.
        XCTAssertTrue(slantReportedFailurePrefix.hasPrefix("The API reported a failure"))
    }

    // MARK: 429

    func testRetryAfterSecondsAreReadAsAWait() {
        XCTAssertEqual(retryAfterSeconds("12"), 12)
        XCTAssertEqual(retryAfterSeconds(" 30 "), 30)
        XCTAssertEqual(retryAfterSeconds("1.5"), 1.5)
        XCTAssertEqual(retryAfterSeconds("0"), 0)
        for odd in [nil, "", "abc", "-1", "1e3", "Wed, 21 Oct 2026 07:28:00 GMT", "inf", "nan", "100000", "１２", "12s"] {
            XCTAssertNil(retryAfterSeconds(odd), String(describing: odd))
        }
        XCTAssertEqual(rateLimitUserMessage(retryAfter: "12", rateLimitReset: nil), "Too many requests. Try again in about 12 seconds.")
        XCTAssertEqual(rateLimitUserMessage(retryAfter: "0", rateLimitReset: nil), "Too many requests. Try again in about 1 second.")
        XCTAssertEqual(rateLimitUserMessage(retryAfter: "300", rateLimitReset: nil), "Too many requests. Try again in about 5 minutes.")
        // Not a number: the reset header, else the generic copy.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(rateLimitUserMessage(retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT", rateLimitReset: "1800000040000", now: now),
                       "Too many requests. Try again in about 40 seconds.")
        XCTAssertEqual(rateLimitUserMessage(retryAfter: "soon", rateLimitReset: nil, now: now),
                       "Too many requests. Wait a moment, then try again.")
        XCTAssertEqual(http(429, retryAfter: "soon").userMessage, "Too many requests. Wait a moment, then try again.")
    }

    // MARK: Query encoding

    func testQueryValuesEncodePlusSoSlantDoesNotReadASpace() throws {
        let url = try XCTUnwrap(slantAPIURL(path: "/orders", query: [
            "endDate": "2026-10-28T00:00:00+10:00", "status": "SUBMITTED", "q": "a b&c", "name": "Café"
        ]))
        let query = try XCTUnwrap(url.query(percentEncoded: true))
        XCTAssertTrue(query.contains("endDate=2026-10-28T00:00:00%2B10:00"), query)
        XCTAssertFalse(query.contains("+"), query)
        XCTAssertTrue(query.contains("q=a%20b%26c"), query)
        XCTAssertTrue(query.contains("name=Caf%C3%A9"), query)
        // Sorted by name, and the values read back unchanged.
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.map(\.name), ["endDate", "name", "q", "status"])
        XCTAssertEqual(items.first { $0.name == "endDate" }?.value, "2026-10-28T00:00:00+10:00")
        XCTAssertEqual(items.first { $0.name == "q" }?.value, "a b&c")
        XCTAssertEqual(items.first { $0.name == "name" }?.value, "Café")
        XCTAssertEqual(url.host, "slant3dapi.com")
        XCTAssertEqual(url.path, "/v2/api/orders")
    }

    func testAPIURLWithoutQueryAndTheWebhookPrefix() throws {
        XCTAssertEqual(slantAPIURL(path: "/files/abc", query: [:])?.absoluteString, "https://slant3dapi.com/v2/api/files/abc")
        XCTAssertEqual(slantAPIURL(path: "/slant/webhook", query: [:])?.absoluteString, "https://slant3dapi.com/v2/slant/webhook")
        XCTAssertEqual(slantAPIURL(path: "/orders", query: ["publicId": "SLANT_12"])?.absoluteString,
                       "https://slant3dapi.com/v2/api/orders?publicId=SLANT_12")
        XCTAssertEqual(slantAPIURL(path: "/orders", query: ["k+ey": "1+1=2"])?.query(percentEncoded: true), "k%2Bey=1%2B1%3D2")
    }

    // MARK: User-Agent

    func testUserAgentNamesTheAppAndMacOS() {
        let sonoma = OperatingSystemVersion(majorVersion: 14, minorVersion: 5, patchVersion: 0)
        XCTAssertEqual(slantUserAgent(appVersion: "1.4.0", os: sonoma), "Plinth/1.4.0 (macOS 14.5)")
        XCTAssertEqual(slantUserAgent(appVersion: " 2.0 ", os: OperatingSystemVersion(majorVersion: 15, minorVersion: 1, patchVersion: 2)),
                       "Plinth/2.0 (macOS 15.1.2)")
        XCTAssertEqual(slantUserAgent(appVersion: nil, os: sonoma), "Plinth/dev (macOS 14.5)")
        XCTAssertEqual(slantUserAgent(appVersion: "", os: sonoma), "Plinth/dev (macOS 14.5)")
        XCTAssertEqual(slantUserAgent(appVersion: "1.0\r\nX-Evil: 1", os: sonoma), "Plinth/dev (macOS 14.5)")
        XCTAssertEqual(slantUserAgent(appVersion: "1.0 (beta)", os: sonoma), "Plinth/dev (macOS 14.5)")
        XCTAssertEqual(slantUserAgent(appVersion: String(repeating: "9", count: 40), os: sonoma), "Plinth/dev (macOS 14.5)")
        XCTAssertTrue(slantStudioUserAgent.hasPrefix("Plinth/"))
        XCTAssertTrue(slantStudioUserAgent.contains("(macOS "))
    }

    // MARK: Upload copy by step

    func testUploadFailureCopyByStep() {
        // Asking for a link: nothing is stored, and a local file is never told to use a secure link.
        let noLink = uploadFailureMessage(stage: .preparing, error: APIError.invalidResponse(uploadLinkMissingMessage))
        XCTAssertEqual(noLink, uploadLinkMissingMessage)
        XCTAssertFalse(noLink.localizedCaseInsensitiveContains("https"))
        XCTAssertEqual(uploadFailureMessage(stage: .preparing, error: http(400, #"{"message":"Bad type"}"#)),
                       "Slant couldn’t accept those details. Bad type")
        XCTAssertFalse(uploadOutcomeUnknown(stage: .preparing, error: URLError(.timedOut)))

        // The storage PUT: a 403 is the link, not the key.
        let refusedLink = uploadFailureMessage(stage: .uploading, error: http(403, "<Error><Code>AccessDenied</Code></Error>"))
        XCTAssertTrue(refusedLink.contains("refused the upload link"), refusedLink)
        XCTAssertFalse(refusedLink.contains("API key"))
        XCTAssertTrue(uploadFailureMessage(stage: .uploading, error: http(500)).contains("(HTTP 500)"))
        XCTAssertTrue(uploadFailureMessage(stage: .uploading, error: URLError(.networkConnectionLost)).contains("interrupted"))
        XCTAssertFalse(uploadOutcomeUnknown(stage: .uploading, error: http(500)), "nothing is in Slant's files before the confirm")

        // The confirm: anything but a definite refusal may have kept the file.
        for unknown: Error in [URLError(.timedOut), URLError(.networkConnectionLost), http(500), http(503), http(408), http(409),
                               APIError.invalidResponse("\(slantReportedFailurePrefix)200):\n{\"success\":false}"),
                               UploadConfirmMissingFileID()] {
            XCTAssertTrue(uploadOutcomeUnknown(stage: .confirming, error: unknown), "\(unknown)")
            XCTAssertEqual(uploadFailureMessage(stage: .confirming, error: unknown), uploadUnconfirmedMessage)
        }
        XCTAssertTrue(uploadUnconfirmedMessage.contains("Refresh"))
        XCTAssertFalse(uploadOutcomeUnknown(stage: .confirming, error: http(400, #"{"message":"Bad placeholder"}"#)))
        XCTAssertEqual(uploadFailureMessage(stage: .confirming, error: http(400, #"{"message":"Bad placeholder"}"#)),
                       "Slant couldn’t accept those details. Bad placeholder")
        // Before any request (no stage yet).
        XCTAssertEqual(uploadFailureMessage(stage: nil, error: APIError.invalidRequest("Select a readable local model file.")),
                       "Select a readable local model file.")
        XCTAssertFalse(uploadOutcomeUnknown(stage: nil, error: URLError(.timedOut)))
    }

    func testBatchPersonaliseClassificationIsUnchanged() {
        // The link message changed wording only: still an unknown outcome for personalised uploads.
        if case .unknown = batchPersonaliseUploadOutcome(error: APIError.invalidResponse(uploadLinkMissingMessage)) {} else {
            XCTFail("a missing upload link stays unknown")
        }
        if case .refused = batchPersonaliseUploadOutcome(error: http(403)) {} else { XCTFail("a 403 stays refused") }
        if case .unknown = batchPersonaliseUploadOutcome(error: http(409)) {} else { XCTFail("a 409 stays unknown") }
    }

    func testUploadStageProgressText() {
        XCTAssertEqual(UploadStage.preparing.progressText, "Preparing upload…")
        XCTAssertEqual(UploadStage.uploading.progressText, "Uploading model…")
        XCTAssertEqual(UploadStage.confirming.progressText, "Confirming upload and processing model…")
        let box = UploadStageBox()
        XCTAssertNil(box.value)
        box.value = .confirming
        XCTAssertEqual(box.value, .confirming)
    }

    // MARK: Upload from URL

    func testUploadFromURLExplainsAWithdrawnEndpoint() {
        let message = uploadFromURLUnavailableMessage(http(404))
        XCTAssertEqual(message, uploadFromURLUnavailableMessage(http(405)))
        XCTAssertTrue(message?.contains("Import Model…") == true)
        XCTAssertNil(uploadFromURLUnavailableMessage(http(400)))
        XCTAssertNil(uploadFromURLUnavailableMessage(http(500)))
        XCTAssertNil(uploadFromURLUnavailableMessage(URLError(.timedOut)))
    }

    // MARK: Real IDs

    func testRecordIDsNeverFallBackToTheName() {
        XCTAssertNil(uploadedFileID(["name": "Bracket"]))
        XCTAssertNil(uploadedFileID(["publicFileServiceId": "  ", "name": "Bracket"]))
        XCTAssertNil(uploadedFileID(["publicFileServiceId": NSNull(), "id": true]))
        XCTAssertEqual(uploadedFileID(["publicFileServiceId": " f-1 ", "id": "x"]), "f-1")
        XCTAssertNil(uploadedFileID(["id": 42]), "a number is the upload placeholder's internal ID, not a file ID")
        XCTAssertEqual(uploadedFileID(["id": "f-2"]), "f-2")
        XCTAssertNil(platformRecordID(["name": "My shop"]))
        XCTAssertEqual(platformRecordID(["publicId": "p-1", "id": "x"]), "p-1")
        XCTAssertEqual(platformRecordID(["id": "p-2", "name": "Shop"]), "p-2")
        XCTAssertNil(platformRecordID(["publicFileServiceId": "f-1"]), "a file ID isn't a platform ID")
    }

    // MARK: Check Again

    func testFilesUpdatingReplacesOnlyThatRowInPlace() {
        let files = [Record(values: ["publicFileServiceId": "a", "name": "A"]),
                     Record(values: ["publicFileServiceId": "b", "name": "B", "metrics": [:] as [String: Any], "type": "stl"]),
                     Record(values: ["publicFileServiceId": "c", "name": "C"])]
        let fresh: [String: Any] = ["publicFileServiceId": "b", "name": "B", "metrics": ["weight": 12.5]]
        let updated = filesUpdating(files, with: fresh, id: "b")
        XCTAssertEqual(updated.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(updated[1].metrics["weight"] as? Double, 12.5)
        XCTAssertEqual(updated[1].string("type"), "stl", "fields the single read leaves out are kept")
        XCTAssertEqual(filesUpdating(files, with: fresh, id: "zzz").map(\.id), ["a", "b", "c"])
    }

    // MARK: Platform edits

    func testPlatformEditSendsOnlyChangedFields() throws {
        let noWebhook = Record(values: ["id": "p", "name": "Shop", "url": "https://shop.example", "description": ""])
        var rename = PlatformDraft(platform: noWebhook)
        rename.name = "  New name "
        let renamed = try rename.payload()
        XCTAssertEqual(renamed as NSDictionary, ["name": "New name"] as NSDictionary, "no empty webhookURL or description")

        XCTAssertTrue(try PlatformDraft(platform: noWebhook).payload().isEmpty, "nothing changed, nothing to send")

        let full = Record(values: ["id": "p", "name": "Shop", "url": "https://shop.example", "description": "Prints",
                                   "webhookURL": "https://hooks.example/slant"])
        var cleared = PlatformDraft(platform: full)
        cleared.webhookURL = "  "
        cleared.description = ""
        let clearedBody = try cleared.payload()
        XCTAssertEqual(clearedBody["webhookURL"] as? String, "", "an explicit clear is still sent")
        XCTAssertEqual(clearedBody["description"] as? String, "")
        XCTAssertNil(clearedBody["name"])
        XCTAssertNil(clearedBody["url"])

        var secret = PlatformDraft(platform: full)
        secret.webhookSecret = String(repeating: "s", count: 32)
        XCTAssertEqual(try secret.payload() as NSDictionary, ["webhookSecret": String(repeating: "s", count: 32)] as NSDictionary)
        secret.webhookSecret = "short"
        XCTAssertThrowsError(try secret.payload())

        var badHook = PlatformDraft(platform: full)
        badHook.webhookURL = "http://hooks.example"
        XCTAssertThrowsError(try badHook.payload())
    }

    func testDashboardHTTPAddressBlocksOnlyWhenChanged() throws {
        let dashboard = Record(values: ["id": "p", "name": "Shop", "url": "http://legacy.example"])
        var rename = PlatformDraft(platform: dashboard)
        rename.description = "Prints"
        XCTAssertEqual(try rename.payload() as NSDictionary, ["description": "Prints"] as NSDictionary)
        var changeURL = PlatformDraft(platform: dashboard)
        changeURL.url = "http://other.example"
        XCTAssertThrowsError(try changeURL.payload())
        changeURL.url = "https://other.example"
        XCTAssertEqual(try changeURL.payload()["url"] as? String, "https://other.example")
        var blank = PlatformDraft(platform: dashboard)
        blank.name = " "
        XCTAssertThrowsError(try blank.payload(), "a name is still required")
    }

    func testCreateAndLegacyEditPayloadsAreUnchanged() throws {
        let create = try PlatformDraft(name: "Shop", url: "https://shop.example").payload()
        XCTAssertEqual(create as NSDictionary, ["name": "Shop", "url": "https://shop.example"] as NSDictionary)
        XCTAssertThrowsError(try PlatformDraft(name: "Shop", url: "http://shop.example").payload())
        let legacy = try PlatformDraft(name: "Shop", url: "https://shop.example", clearsWebhookWhenBlank: true).payload()
        XCTAssertEqual(legacy["webhookURL"] as? String, "")
    }

    // MARK: Failed deliveries

    func testDeadWebhookRowsShowTheEventAndLastAttempt() {
        let row = Record(values: [
            "id": "3f1c0d5e-0000-4000-8000-000000000001", "eventType": "order.shipped", "status": "failed",
            "lastStatus": 502, "lastError": "502 Bad Gateway", "lastAttemptAt": "2026-10-27T09:15:00.000Z",
            "attempts": 10, "retryable": true, "expired": false
        ])
        XCTAssertEqual(deadWebhookTitle(row), "Order shipped")
        XCTAssertEqual(deadWebhookCaption(row, formatter: { _ in "27 Oct" }),
                       "Failed · HTTP 502 · 502 Bad Gateway · last tried 27 Oct · 10 attempts")
        XCTAssertNil(deadWebhookResendBlockedReason(row))
        XCTAssertEqual(deadWebhookID(row), "3f1c0d5e-0000-4000-8000-000000000001")

        XCTAssertEqual(deadWebhookTitle(Record(values: ["eventType": "payment_failed"])), "Payment failed")
        XCTAssertEqual(deadWebhookTitle(Record(values: ["id": "x"])), "Webhook delivery")
        XCTAssertEqual(deadWebhookTitle(Record(values: ["eventType": NSNull()])), "Webhook delivery")
        XCTAssertEqual(deadWebhookCaption(Record(values: [:])), "")
        XCTAssertEqual(deadWebhookCaption(Record(values: ["lastStatus": NSNull(), "lastError": NSNull(), "lastAttemptAt": "bad",
                                                          "attempts": "two", "status": "unknown"])), "")
        XCTAssertNil(deadWebhookID(Record(values: ["name": "x"])))
        let long = deadWebhookCaption(Record(values: ["lastError": String(repeating: "e", count: 400) + "\nsecond line"]))
        XCTAssertEqual(long.count, 160)
        XCTAssertFalse(long.contains("second line"))
    }

    func testTryAgainIsOfferedOnlyWhenSlantCanResend() {
        XCTAssertNotNil(deadWebhookResendBlockedReason(Record(values: ["status": "delivered"])))
        XCTAssertNotNil(deadWebhookResendBlockedReason(Record(values: ["status": "failed", "succeededAt": "2026-10-27T09:15:00Z"])))
        XCTAssertNotNil(deadWebhookResendBlockedReason(Record(values: ["status": "expired"])))
        XCTAssertNotNil(deadWebhookResendBlockedReason(Record(values: ["status": "failed", "expired": true])))
        XCTAssertNil(deadWebhookResendBlockedReason(Record(values: ["status": "retrying"])))
        XCTAssertNil(deadWebhookResendBlockedReason(Record(values: ["status": "failed", "succeededAt": NSNull()])))
        // retryable: false stops only Slant's automatic retries; a manual resend after fixing the endpoint stays open.
        let refused = Record(values: ["status": "failed", "retryable": false, "lastStatus": 400])
        XCTAssertNil(deadWebhookResendBlockedReason(refused))
        XCTAssertTrue(deadWebhookCaption(refused).contains("Slant has stopped retrying it"))
    }

    func testSingleResendResultInWords() {
        func result(success: Bool = false, status: Int? = nil, error: String? = nil, already: Bool = false, expired: Bool = false) -> WebhookSingleResendResult {
            WebhookSingleResendResult(success: success, status: status, error: error, alreadyDelivered: already, expired: expired)
        }
        XCTAssertEqual(webhookSingleResendResultMessage(result(success: true, status: 200)), "Delivered. Your endpoint returned HTTP 200.")
        XCTAssertEqual(webhookSingleResendResultMessage(result(success: true)), "Delivered.")
        XCTAssertEqual(webhookSingleResendResultMessage(result(status: 500, error: "Internal Server Error")),
                       "Not delivered. Your endpoint returned HTTP 500: Internal Server Error")
        XCTAssertEqual(webhookSingleResendResultMessage(result(status: 404)), "Not delivered. Your endpoint returned HTTP 404.")
        XCTAssertEqual(webhookSingleResendResultMessage(result(error: "getaddrinfo ENOTFOUND")), "Not delivered: getaddrinfo ENOTFOUND")
        XCTAssertEqual(webhookSingleResendResultMessage(result()), "Not delivered. Slant didn’t say why.")
        XCTAssertEqual(webhookSingleResendResultMessage(result(already: true)), "Already delivered, so Slant didn’t send it again.")
        XCTAssertEqual(webhookSingleResendResultMessage(result(expired: true)), "Past Slant’s 30-day window, so Slant didn’t send it.")
        let parsed = parseWebhookSingleResendResult(from: ["success": false, "status": NSNull(), "error": NSNull(), "expired": true])
        XCTAssertEqual(webhookSingleResendResultMessage(parsed), "Past Slant’s 30-day window, so Slant didn’t send it.")
    }

    // MARK: Catalog prices

    func testPriceUnitCurrencyIsNotShownAsAUnit() {
        XCTAssertEqual(catalogPriceText("4.50", priceUnit: "USD"), "$4.50")
        XCTAssertEqual(catalogPriceText(4.5, priceUnit: "usd"), "$4.50")
        XCTAssertEqual(catalogPriceText("4.50", priceUnit: "EUR"), "4.50 EUR")
        XCTAssertEqual(catalogPriceText("4.50", priceUnit: "each"), "$4.50 / each")
        XCTAssertEqual(catalogPriceText("4.50", priceUnit: "pcs"), "$4.50 / pcs")
        XCTAssertEqual(catalogPriceText("4.50", priceUnit: " "), "$4.50")
        XCTAssertEqual(catalogPriceText("4.50", priceUnit: ""), "$4.50")
        XCTAssertEqual(catalogPriceText(1234.5, priceUnit: "USD"), "$1,234.50")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: componentFactRows(Record(values: ["price": "4.50", "priceUnit": "USD"])))["Price"], "$4.50")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: stationeryFactRows(Record(values: ["price": 0.25, "priceUnit": "USD"])))["Price"], "$0.25")
    }

    // MARK: Check Cost

    func testUnavailableCatalogItemsAreFlaggedNotPriced() {
        var slip = SavedProductLine(); slip.type = "STATIONERY"; slip.reference = "slip"; slip.quantity = 1
        var feet = SavedProductLine(); feet.type = "COMPONENT"; feet.reference = "feet"; feet.quantity = 1
        var card = SavedProductLine(); card.type = "STATIONERY"; card.reference = "card"; card.quantity = 1
        let product = SavedProduct(name: "Kit", lines: [slip, feet, card])
        let stationery = [Record(values: ["id": "slip", "name": "Slip", "price": 0.25, "available": false]),
                          Record(values: ["id": "card", "name": "Card", "price": 0.5, "available": true])]
        let components = [Record(values: ["id": "feet", "name": "Feet", "price": 0.5, "priceUnit": "USD", "available": false])]
        let parts = productCostParts(product, units: 1, localModels: [], filaments: [], components: components,
                                     stationery: stationery, loadedCatalogs: [.components, .stationery])
        guard case .unavailable(let slipReason) = parts[0].state, case .unavailable = parts[1].state else {
            return XCTFail("unavailable items must be flagged")
        }
        XCTAssertTrue(slipReason.contains("not available"))
        XCTAssertEqual(parts[2].state.total, Decimal(string: "0.5"))
        XCTAssertFalse(productCostSummary(parts, units: 1).complete)
    }

    // MARK: Download cap

    func testDownloadCapAllowsSlantsUploadLimitWithAMargin() {
        XCTAssertEqual(slantDownloadMaxBytes, 300 * 1024 * 1024)
        XCTAssertTrue(slantDownloadMaxBytes > 250 * 1024 * 1024)
        XCTAssertTrue(slantDownloadLengthAllowed(-1), "an unknown length is checked while reading")
        XCTAssertTrue(slantDownloadLengthAllowed(250 * 1024 * 1024))
        XCTAssertTrue(slantDownloadLengthAllowed(slantDownloadMaxBytes))
        XCTAssertFalse(slantDownloadLengthAllowed(slantDownloadMaxBytes + 1))
        XCTAssertFalse(slantDownloadLengthAllowed(10, maxBytes: 5))
        XCTAssertTrue(slantDownloadTooLargeMessage.contains("300 MB"))
    }
}

private extension BatchPersonaliseUploadOutcome {
    var unknownText: String {
        if case .unknown(let text) = self { return text }
        return ""
    }
}
