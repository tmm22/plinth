import XCTest
@testable import Plinth

// MARK: - Stubs

/// A stub that answers every request from the Slant and storage hosts with a real redirect (through
/// `wasRedirectedTo`, so the session's redirect delegate is consulted) to `elsewhere`, and records every URL it sees.
/// `/files/direct-upload` answers with an upload link so an upload reaches its storage PUT.
final class RedirectingStubProtocol: URLProtocol {
    static let elsewhere = URL(string: "https://elsewhere.example.net/landing")!
    static let storageURL = "https://storage.example.com/bucket/model.stl?X-Signature=abc"
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: [URL] = []

    static func reset() { lock.lock(); seen = []; lock.unlock() }
    static var requested: [URL] { lock.lock(); defer { lock.unlock() }; return seen }
    static var reachedElsewhere: Bool { requested.contains { $0.host == elsewhere.host } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.seen.append(url); Self.lock.unlock()
        if url.host == Self.elsewhere.host {
            finish(status: 200, headers: ["Content-Type": "application/json"], body: Data(#"{"data":{"id":"x"}}"#.utf8))
            return
        }
        if url.path == "/v2/api/files/direct-upload" {
            let body = #"{"data":{"presignedUrl":"\#(Self.storageURL)","filePlaceholder":{"id":"placeholder-1"}}}"#
            finish(status: 200, headers: ["Content-Type": "application/json"], body: Data(body.utf8))
            return
        }
        let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": Self.elsewhere.absoluteString, "Content-Length": "0"])!
        var next = URLRequest(url: Self.elsewhere)
        next.httpMethod = request.httpMethod
        client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
        // When the session refuses the redirect, the 3xx itself is the reply.
        client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private func finish(status: Int, headers: [String: String], body: Data) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

/// Answers every request 200 with the given headers and STL-like bytes, so rate-limit headers can be read back.
final class RateLimitHeaderStubProtocol: URLProtocol {
    nonisolated(unsafe) static var headers: [String: String] = [:]
    nonisolated(unsafe) static var body = Data()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class StageLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [UploadStage] = []
    func append(_ stage: UploadStage) { lock.lock(); stages.append(stage); lock.unlock() }
    var last: UploadStage? { lock.lock(); defer { lock.unlock() }; return stages.last }
}

// MARK: - Redirects (M-64)

final class ClientRedirectRefusalTests: XCTestCase {
    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingStubProtocol.self]
        return APIClient(apiKey: "sl-test-key-0000", configuration: configuration)
    }

    override func setUp() {
        super.setUp()
        RedirectingStubProtocol.reset()
    }

    private func assertRedirectStatus(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case .http(let status, _, _, _)? = error as? APIError else {
            return XCTFail("expected the 3xx as an HTTP error, got \(error)", file: file, line: line)
        }
        XCTAssertEqual(status, 302, file: file, line: line)
    }

    /// Without a refusing delegate the same stub's redirect is followed, so the tests below prove the refusal.
    func testTheStubsRedirectIsFollowedByAPlainSession() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RedirectingStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: URL(string: "https://slant3dapi.com/v2/api/files")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(RedirectingStubProtocol.reachedElsewhere)
    }

    func testAPIRequestRefusesRedirects() async {
        do {
            _ = try await client().request("GET", path: "/files")
            XCTFail("a redirect must not succeed")
        } catch { assertRedirectStatus(error) }
        XCTAssertFalse(RedirectingStubProtocol.reachedElsewhere, "the key must never follow a redirect")
        XCTAssertEqual(RedirectingStubProtocol.requested.count, 1)
    }

    func testStoragePUTRefusesRedirects() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("redirect-\(UUID().uuidString).stl")
        try Data("solid x\nendsolid x\n".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let log = StageLog()
        do {
            _ = try await client().upload(file: file, name: "Part", platformId: "platform-1", ownerId: "") { log.append($0) }
            XCTFail("a redirected PUT must not succeed")
        } catch { assertRedirectStatus(error) }
        XCTAssertEqual(log.last, .uploading, "stops at the PUT; confirm-upload is never sent")
        XCTAssertFalse(RedirectingStubProtocol.reachedElsewhere, "model bytes must never go to a host Slant didn't name")
        XCTAssertFalse(RedirectingStubProtocol.requested.contains { $0.path.hasSuffix("/confirm-upload") })
    }

    func testModelDownloadRefusesRedirects() async {
        do {
            _ = try await client().downloadModel(from: URL(string: "https://files.example.com/model.stl")!)
            XCTFail("a redirected download must not succeed")
        } catch { assertRedirectStatus(error) }
        XCTAssertFalse(RedirectingStubProtocol.reachedElsewhere)
    }

    func testAPISpecFetchRefusesRedirects() async {
        do {
            _ = try await SlantAPISpecFetcher(protocolClasses: [RedirectingStubProtocol.self])
                .fetch(slantAPISpecRequest(etag: nil, lastModified: nil))
            XCTFail("a redirected spec fetch must not succeed")
        } catch {
            XCTAssertEqual(error as? SlantAPISpecFetchError, .redirected(302))
        }
        XCTAssertFalse(RedirectingStubProtocol.reachedElsewhere)
    }
}

// MARK: - Redaction (M-31) and OpenSCAD's rate-limit headers (M-17)

final class ClientTransportRound17Tests: XCTestCase {
    func testBothSlantKeyFormsAreRedacted() {
        XCTAssertEqual(apiMessageRedactingCredentials("Key sl-abc123DEF_456 isn't allowed"), "Key sl-… isn't allowed")
        XCTAssertEqual(apiMessageRedactingCredentials("Key sl_abc123DEF-456 isn't allowed"), "Key sl_… isn't allowed")
        XCTAssertEqual(shortAPIMessage(from: #"{"message":"Bad key sl_live0000aaaa"}"#), "Bad key sl_…")
        // Short or embedded look-alikes are left alone.
        XCTAssertEqual(apiMessageRedactingCredentials("Use sl_abc here"), "Use sl_abc here")
        XCTAssertEqual(apiMessageRedactingCredentials("Basl_abcdefgh"), "Basl_abcdefgh")
    }

    func testPathSegmentsEncodeEverySeparator() {
        XCTAssertEqual(encodedSegment("model a/b"), "model%20a%2Fb")
        XCTAssertEqual(encodedSegment(".."), "%2E%2E")
        XCTAssertEqual(encodedSegment("a?b#c%d"), "a%3Fb%23c%25d")
        XCTAssertEqual(encodedSegment("SLANT_ab-12"), "SLANT_ab-12")
        XCTAssertTrue(encodedSegment("Café №1").unicodeScalars.allSatisfy(\.isASCII))
    }

    func testOpenSCADRepliesNeverCarryASharedRateLimit() {
        XCTAssertFalse(slantReplyRateLimitIsShared(path: "/files/openScad"))
        XCTAssertFalse(slantReplyRateLimitIsShared(path: "/files/openscad/"))
        XCTAssertTrue(slantReplyRateLimitIsShared(path: "/files"))
        XCTAssertTrue(slantReplyRateLimitIsShared(path: "/files/openScad-like"))
        XCTAssertTrue(slantReplyRateLimitIsShared(path: nil))
        let headers = ["X-RateLimit-Limit": "5", "X-RateLimit-Remaining": "4", "X-RateLimit-Reset": "1792720000000"]
        XCTAssertFalse(APIResponse(data: Data(), statusCode: 200, headers: headers, requestPath: "/files/openScad").rateLimit.hasValues)
        let minute = APIResponse(data: Data(), statusCode: 200, headers: ["X-RateLimit-Limit": "100", "X-RateLimit-Remaining": "97"],
                                 requestPath: "/orders").rateLimit
        XCTAssertEqual(minute.limit, 100)
        XCTAssertEqual(minute.remaining, 97)
    }

    func testClientRepliesNameTheirPathSoOpenSCADHeadersStayOut() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RateLimitHeaderStubProtocol.self]
        let client = APIClient(apiKey: "sl-test-key-0000", configuration: configuration)
        RateLimitHeaderStubProtocol.headers = ["Content-Type": "application/sla", "X-RateLimit-Limit": "5", "X-RateLimit-Remaining": "4"]
        RateLimitHeaderStubProtocol.body = Data("solid generated\nendsolid generated\n".utf8)
        let generated = try await client.request("POST", path: "/files/openScad", body: ["scadCode": "cube(1);"])
        XCTAssertEqual(generated.requestPath, "/files/openScad")
        XCTAssertFalse(generated.rateLimit.hasValues, "OpenSCAD's hourly limiter must never reach the shared figure")
        RateLimitHeaderStubProtocol.headers = ["Content-Type": "application/json", "X-RateLimit-Limit": "100", "X-RateLimit-Remaining": "88"]
        RateLimitHeaderStubProtocol.body = Data(#"{"data":[]}"#.utf8)
        let files = try await client.request("GET", path: "/files")
        XCTAssertEqual(files.rateLimit.remaining, 88)
    }
}

// MARK: - Platforms (M-36 to M-42)

final class PlatformRound17Tests: XCTestCase {
    private func http(_ status: Int) -> APIError { .http(status: status, body: "", retryAfter: nil, rateLimitReset: nil) }

    func testASecretMayHaveChangedUnlessSlantDefinitelyRefused() {
        XCTAssertTrue(webhookSecretMayHaveChanged(after: WebhookSecretNotReturned()))
        for error: Error in [http(500), http(502), http(408), http(409), http(302), URLError(.timedOut), URLError(.networkConnectionLost),
                             APIError.invalidResponse("x"), StudioError("unreadable")] {
            XCTAssertTrue(webhookSecretMayHaveChanged(after: error), "\(error)")
            XCTAssertNotNil(webhookSecretUnclearMessage(error, saving: false), "\(error)")
        }
        for error: Error in [http(400), http(401), http(404), http(422), http(429), APIError.invalidRequest("no key"), URLError(.badURL),
                             URLError(.cannotFindHost)] {
            XCTAssertFalse(webhookSecretMayHaveChanged(after: error), "\(error)")
            XCTAssertNil(webhookSecretUnclearMessage(error, saving: true), "\(error)")
        }
        let missing = webhookSecretUnclearMessage(WebhookSecretNotReturned(), saving: false) ?? ""
        XCTAssertTrue(missing.hasPrefix("Slant didn’t return the new secret, so"), missing)
        XCTAssertTrue(missing.contains("Reload Platform"), missing)
        XCTAssertFalse(missing.lowercased().contains("try again"), "never suggests rotating again")
        let saving = webhookSecretUnclearMessage(http(503), saving: true) ?? ""
        XCTAssertTrue(saving.contains("may already have saved the new webhook secret"), saving)
    }

    func testAnUncertainSecretIsNeitherCachedNorShown() {
        let row = Record(values: ["id": "platform-a", "name": "Shop", "webhookSecret": "old-secret", "secret": "older", "webhookURL": NSNull()])
        let cleared = platformRecordClearingWebhookSecret(row)
        XCTAssertNil(cleared.values["webhookSecret"])
        XCTAssertNil(cleared.values["secret"])
        XCTAssertEqual(cleared.id, "platform-a")
        XCTAssertEqual(cleared.string("name"), "Shop")
        XCTAssertEqual(displayedWebhookSecret(rotatedSecret: "new", currentSecret: "old", uncertain: true), "")
        XCTAssertEqual(displayedWebhookSecret(rotatedSecret: nil, currentSecret: "old", uncertain: false), "old")
    }

    func testEnableByIDIsNotOfferedForAnEnabledPlatform() {
        let listed = [Record(values: ["id": "platform-a", "name": "Shop", "enabled": true])]
        XCTAssertNotNil(platformEnableCandidateBlockedReason(Record(values: ["id": "platform-a", "name": "Shop"]), listed: listed))
        XCTAssertNotNil(platformEnableCandidateBlockedReason(Record(values: ["id": "platform-b", "enabled": true]), listed: listed))
        XCTAssertNil(platformEnableCandidateBlockedReason(Record(values: ["id": "platform-b", "enabled": false]), listed: listed))
        XCTAssertNil(platformEnableCandidateBlockedReason(Record(values: ["id": "platform-b"]), listed: listed), "unknown: Slant decides")
        XCTAssertNil(platformEnableCandidateBlockedReason(Record(values: ["id": "platform-b", "enabled": 1]), listed: listed), "only a real boolean")
    }

    func testCreatePlatformBecomesTheDefaultOnlyWithoutOne() {
        XCTAssertTrue(platformCreateBecomesDefault(currentDefault: ""))
        XCTAssertTrue(platformCreateBecomesDefault(currentDefault: "  "))
        XCTAssertFalse(platformCreateBecomesDefault(currentDefault: "platform-a"))
        XCTAssertTrue(platformComposerDefaultNote(currentDefault: "").contains("becomes your default"))
        XCTAssertTrue(platformComposerDefaultNote(currentDefault: "platform-a").contains("stays as it is"))
    }

    func testVerificationRecipeNamesTheTimestampHeaderAndItsUnit() {
        XCTAssertTrue(webhookVerificationRecipe.contains("X-Webhook-Timestamp"))
        XCTAssertTrue(webhookVerificationRecipe.contains("milliseconds"))
        XCTAssertTrue(webhookVerificationRecipe.contains("exactly as received"))
        XCTAssertTrue(webhookVerificationRecipe.contains("X-Webhook-Signature-256"))
    }

    func testTestWebhookResultIsWordedAndClipped() {
        XCTAssertEqual(webhookTestResultMessage(WebhookTestResult(attempted: true, endpointStatus: 204, message: nil)),
                       "Delivered. Your endpoint returned HTTP 204.")
        let long = String(repeating: "x", count: 400) + "\nsecond line"
        let failed = webhookTestResultMessage(WebhookTestResult(attempted: false, endpointStatus: nil, message: long))
        XCTAssertTrue(failed.hasPrefix("Not delivered: "), failed)
        XCTAssertLessThanOrEqual(failed.count, "Not delivered: ".count + 160)
        XCTAssertFalse(failed.contains("second line"))
        XCTAssertEqual(webhookTestResultMessage(WebhookTestResult(attempted: false, endpointStatus: nil, message: "Request timed out after 10s")),
                       "Not delivered: Request timed out after 10s")
        XCTAssertEqual(webhookTestResultMessage(WebhookTestResult(attempted: false, endpointStatus: nil, message: "  ")), "Test webhook failed.")
    }
}

// MARK: - Workbench (M-44, M-45, M-48, M-50)

final class WorkbenchRound17Tests: XCTestCase {
    private func http(_ status: Int, _ body: String = "") -> APIError { .http(status: status, body: body, retryAfter: nil, rateLimitReset: nil) }

    func testSendFailureNoteSeparatesRefusalsFromUnknownOutcomes() {
        let refused = workbenchSendFailureNote(http(400, #"{"message":"name is required"}"#), method: "POST", sent: true)
        XCTAssertTrue(refused.hasPrefix("Slant refused this request (HTTP 400), so nothing changed."), refused)
        XCTAssertTrue(refused.contains("name is required"), refused)
        XCTAssertTrue(workbenchSendFailureNote(http(403), method: "DELETE", sent: true).hasPrefix("Slant refused this request (HTTP 403)"))
        XCTAssertTrue(workbenchSendFailureNote(URLError(.cannotFindHost), method: "POST", sent: true).hasPrefix("The request didn’t reach Slant"))
        for error: Error in [http(500), http(408), http(409), URLError(.timedOut), APIError.invalidResponse("x"),
                             StudioError("Slant didn’t return an order number, so this draft may have been created."),
                             URLError(.cannotFindHost)] {
            let method = (error as? URLError)?.code == .cannotFindHost ? "DELETE" : "POST"
            let note = workbenchSendFailureNote(error, method: method, sent: true)
            XCTAssertTrue(note.contains("the result is unknown"), "\(error): \(note)")
            XCTAssertFalse(note.contains("nothing changed"), "\(error)")
        }
        // A request never sent says why, without claiming anything about Slant.
        XCTAssertEqual(workbenchSendFailureNote(StudioError("Slant’s OpenSCAD limit was reached."), method: "POST", sent: false),
                       "Slant’s OpenSCAD limit was reached.")
    }

    func testOnlyAnUnclearSecretChangeDropsTheCachedSecret() {
        XCTAssertTrue(workbenchSecretChangeMayHaveHappened(endpointID: "PATCH /platforms/{platformId}/webhook-secret", body: nil, error: http(500)))
        XCTAssertFalse(workbenchSecretChangeMayHaveHappened(endpointID: "PATCH /platforms/{platformId}/webhook-secret", body: nil, error: http(404)))
        XCTAssertTrue(workbenchSecretChangeMayHaveHappened(endpointID: "PATCH /platforms/{platformId}",
                                                           body: ["webhookSecret": String(repeating: "a", count: 32)], error: URLError(.timedOut)))
        XCTAssertFalse(workbenchSecretChangeMayHaveHappened(endpointID: "PATCH /platforms/{platformId}", body: ["name": "Shop"], error: URLError(.timedOut)))
        XCTAssertFalse(workbenchSecretChangeMayHaveHappened(endpointID: "POST /platforms", body: ["webhookSecret": "x"], error: http(500)))
    }

    func testReviewTitleLowersOnlyTheFirstLetter() {
        XCTAssertEqual(workbenchReviewTitle("Get multiple orders by IDs"), "Review get multiple orders by IDs")
        XCTAssertEqual(workbenchReviewTitle("Convert OpenSCAD code to STL"), "Review convert OpenSCAD code to STL")
        XCTAssertEqual(workbenchReviewTitle("STL upload"), "Review STL upload")
        XCTAssertEqual(workbenchReviewTitle("  "), "Review request")
    }

    func testEmptyIDFieldsAreRefused() throws {
        let schema: [String: Any] = ["type": "object", "properties": ["filamentId": ["type": "string", "format": "uuid"]]]
        XCTAssertThrowsError(try validateJSON(["filamentId": ""], schema: schema))
        XCTAssertThrowsError(try validateJSON(["filamentId": "  "], schema: schema))
        XCTAssertNoThrow(try validateJSON(["filamentId": "6f1c2b9e-0000-4000-8000-000000000001"], schema: schema))
        XCTAssertNoThrow(try validateJSON([String: Any](), schema: schema), "an absent optional ID is fine")
        XCTAssertNoThrow(try validateJSON(["name": ""], schema: ["type": "object", "properties": ["name": ["type": "string"]]]))
        // The draft template keeps `filamentId` for PRINT items, but it can't be sent empty.
        let endpoint = try XCTUnwrap(EndpointCatalog.load().first { $0.id == "POST /orders" })
        let template = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(endpoint.bodyTemplate.utf8)) as? [String: Any])
        let item = try XCTUnwrap((template["items"] as? [[String: Any]])?.first)
        XCTAssertEqual(item["filamentId"] as? String, "")
        let bodySchema = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(endpoint.bodySchema.utf8)) as? [String: Any])
        let itemSchema = try XCTUnwrap(((bodySchema["properties"] as? [String: Any])?["items"] as? [String: Any])?["items"] as? [String: Any])
        var filled = item
        filled["publicFileServiceId"] = "6f1c2b9e-0000-4000-8000-000000000002"
        XCTAssertThrowsError(try validateJSON(filled, schema: itemSchema, path: "body.items[0]")) { error in
            XCTAssertTrue(error.localizedDescription.contains("filamentId is empty"), error.localizedDescription)
        }
    }

    func testWriteTemplatesNeverPrefillExampleStrings() throws {
        let endpoints = EndpointCatalog.load()
        let patchFile = try XCTUnwrap(endpoints.first { $0.id == "PATCH /files/{publicFileId}" })
        let patchBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(patchFile.bodyTemplate.utf8)) as? [String: Any])
        XCTAssertEqual(patchBody["ownerId"] as? String, "", "the spec's example owner \"1\" must not be sent by default")

        // Every non-empty string in any template is a spec default or an enum value, never an example.
        let url = try XCTUnwrap(EndpointCatalog.specificationURL())
        let spec = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)))
        var allowed = Set<String>()
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                if let text = object["default"] as? String { allowed.insert(text) }
                for option in object["enum"] as? [Any] ?? [] { if let text = option as? String { allowed.insert(text) } }
                object.values.forEach(collect)
            } else if let array = value as? [Any] { array.forEach(collect) }
        }
        collect(spec)
        func strings(_ value: Any) -> [String] {
            if let text = value as? String { return [text] }
            if let object = value as? [String: Any] { return object.values.flatMap(strings) }
            if let array = value as? [Any] { return array.flatMap(strings) }
            return []
        }
        for endpoint in endpoints where !endpoint.bodyTemplate.isEmpty {
            let template = try JSONSerialization.jsonObject(with: Data(endpoint.bodyTemplate.utf8))
            for text in strings(template) where !text.isEmpty {
                XCTAssertTrue(allowed.contains(text), "\(endpoint.id) pre-fills \"\(text)\"")
            }
        }
        // Defaults stay: the direct upload's file type.
        let upload = try XCTUnwrap(endpoints.first { $0.id == "POST /files/direct-upload" })
        let uploadBody = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(upload.bodyTemplate.utf8)) as? [String: Any])
        if let type = uploadBody["type"] as? String { XCTAssertEqual(type, "stl") }
    }
}
