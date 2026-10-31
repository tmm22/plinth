import XCTest
@testable import Plinth

/// A scripted network for `DapiClient`: each request (API or storage PUT) takes the next step in order, and every
/// request is recorded. Nothing reaches the network.
private final class ScriptedDapiTransport: DapiTransport, @unchecked Sendable {
    enum Step {
        case reply(Int, String, [String: String])
        case fail(Error)
    }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private(set) var uploadedFiles: [URL] = []

    init(_ steps: [Step]) { self.steps = steps }

    private func next(_ request: URLRequest, file: URL?) throws -> DapiHTTPReply {
        lock.lock()
        requests.append(request)
        if let file { uploadedFiles.append(file) }
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        switch step {
        case .reply(let status, let body, let headers)?:
            return DapiHTTPReply(status: status, headers: headers, body: Data(body.utf8))
        case .fail(let error)?:
            throw error
        case nil:
            throw URLError(.resourceUnavailable)
        }
    }

    func send(_ request: URLRequest) async throws -> DapiHTTPReply { try next(request, file: nil) }
    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> DapiHTTPReply { try next(request, file: fileURL) }

    var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

private let testKey = "sk_3f9a1c2b7d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcd"

private func bodyJSON(_ request: URLRequest) -> [String: Any]? {
    request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
}

private func queryItems(_ request: URLRequest) -> [String: String] {
    var items: [String: String] = [:]
    for item in URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [] { items[item.name] = item.value }
    return items
}

private let readyQuoteJSON = """
{ "id":"qte_bfP0GSqKoZFrD72H5Os0rc7HV9XP6eQJu", "object":"quote", "name":"Phone stand v2",
  "file":{ "name":"phone-stand-v2.3mf", "size_bytes":2758723,
           "download_url":"https://files.example.com/q/abc.3mf?signature=secret",
           "production_version":{ "name":"p.3mf", "format":"3mf", "size_bytes":2913004,
                                  "download_url":"https://files.example.com/q/p.3mf?signature=s", "prepared_at":"2026-04-21T07:34:06Z" } },
  "status":"ready",
  "price":{ "amount":1245, "currency":"usd" },
  "suggested_materials":[ { "slot":1, "file_color":"#C12E1F", "file_filament_type":"PLA",
       "material":{ "id":"mat_x","object":"material","name":"PLA Red","custom":false },
       "match":"exact" } ],
  "failure_reason":null,
  "approval":{ "status":"not_submitted", "reason":null },
  "created_at":"2026-10-30T21:42:13.550Z", "finished_at":"2026-10-30T21:44:00Z" }
"""

private func quoteJSON(id: String, name: String, status: String = "ready") -> String {
    #"{"id":"\#(id)","object":"quote","name":"\#(name)","status":"\#(status)","price":null,"failure_reason":null,"suggested_materials":null,"created_at":"2026-10-30T21:42:13Z"}"#
}

private func listJSON(_ quotes: [String], hasMore: Bool, cursor: String?) -> String {
    let next = cursor.map { "\"\($0)\"" } ?? "null"
    return #"{"object":"list","data":[\#(quotes.joined(separator: ","))],"has_more":\#(hasMore),"next_cursor":\#(next)}"#
}

private let uploadReplyJSON = """
{ "id":"upl_bfP0GSqKoZFrD72H5Os0rc7HV9XP6eQJu", "object":"upload", "purpose":"quote_file",
  "upload_url":"https://files.example.com/temp/7f3a.stl?X-Amz-Signature=abc", "method":"PUT",
  "headers":{"Content-Type":"model/stl"}, "expires_at":"2026-10-15T10:00:00Z" }
"""

private func uploadReply(url: String = "https://files.example.com/temp/7f3a.stl?X-Amz-Signature=abc",
                         method: String = "PUT", headers: String = #"{"Content-Type":"model/stl"}"#) -> String {
    #"{"id":"upl_abc123","object":"upload","purpose":"quote_file","upload_url":"\#(url)","method":"\#(method)","headers":\#(headers),"expires_at":"2026-10-15T10:00:00Z"}"#
}

/// `createUpload` for the file's current size, then `sendUploadBytes`: what the quote runner does, minus its stops.
@discardableResult
private func uploadBoth(_ client: DapiClient, file: URL, name: String, type: String, key: String) async throws -> String {
    let size = ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.int64Value ?? 1
    let target = try await client.createUpload(fileName: name, contentType: type, sizeBytes: size, idempotencyKey: key)
    try await client.sendUploadBytes(target, fileURL: file)
    return target.uploadID
}

final class DapiClientTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DapiClientTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func modelFile(bytes: Int = 84, name: String = "stand.stl") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(repeating: 0x41, count: bytes).write(to: url)
        return url
    }

    private func makeClient(_ steps: [ScriptedDapiTransport.Step], key: String = testKey) -> (DapiClient, ScriptedDapiTransport) {
        let transport = ScriptedDapiTransport(steps)
        return (DapiClient(apiKey: key, transport: transport), transport)
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

    private func assertAPIHeaders(_ request: URLRequest, idempotencyKey: String? = nil, json: Bool = false,
                                  file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(request.url?.scheme, "https", file: file, line: line)
        XCTAssertEqual(request.url?.host, dapiAPIHost, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), testKey, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json", file: file, line: line)
        XCTAssertTrue(request.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("Plinth/") ?? false, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Idempotency-Key"), idempotencyKey, file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), json ? "application/json" : nil, file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), file: file, line: line)
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"), file: file, line: line)
        XCTAssertFalse(request.httpShouldHandleCookies, file: file, line: line)
    }

    // MARK: Endpoints

    func testAccountRequestAndParsing() async throws {
        let (client, transport) = makeClient([.reply(200, """
            {"object":"actor","user_id":"6a1f","kind":"Integrator","authenticated_with":"api_key","scopes":["quotes:read"],
             "effective_scopes":["quotes:read","quotes:write","orders:read"],"approval":"pending"}
            """, ["X-RateLimit-Remaining": "499"])])
        let account = try await client.account()
        XCTAssertEqual(account, DapiAccount(kind: "integrator", approval: "pending", effectiveScopes: ["quotes:read", "quotes:write", "orders:read"]))
        XCTAssertTrue(account.isIntegrator)
        XCTAssertEqual(transport.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://public-api.dapi.digital/v2/me")
        XCTAssertNil(request.httpBody)
        assertAPIHeaders(request)
    }

    func testDesignerAccountHasNullApprovalAndScopes() async throws {
        let (client, _) = makeClient([.reply(200, #"{"object":"actor","kind":"designer","approval":null,"scopes":null,"effective_scopes":null}"#, [:])])
        let account = try await client.account()
        XCTAssertEqual(account, DapiAccount(kind: "designer", approval: nil, effectiveScopes: []))
        XCTAssertFalse(account.isIntegrator)
    }

    func testOnboardingParsing() async throws {
        let (client, transport) = makeClient([.reply(200, """
            {"object":"integrator_onboarding","status":"collecting","approved_files":3,"required_files":10,
             "uploads":{"used":7,"limit":25},"files_to_submit":10,"current_request":null,"order_blockers":["billing_details_missing"]}
            """, [:])])
        let onboarding = try await client.onboarding()
        XCTAssertEqual(onboarding, DapiOnboarding(status: "collecting", approvedFiles: 3, requiredFiles: 10, uploadsUsed: 7, uploadsLimit: 25,
                                                    orderBlockers: ["billing_details_missing"]))
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://public-api.dapi.digital/v2/integrator/onboarding")
        XCTAssertEqual(transport.requests[0].httpMethod, "GET")
        assertAPIHeaders(transport.requests[0])
    }

    func testOnboardingNullLimitIsUnlimitedButMissingLimitIsUnreadable() async throws {
        let approved = #"{"status":"approved","approved_files":10,"required_files":10,"uploads":{"used":40,"limit":null}}"#
        let (client, _) = makeClient([.reply(200, approved, [:])])
        let onboarding = try await client.onboarding()
        XCTAssertNil(onboarding.uploadsLimit)

        let missing = #"{"status":"collecting","approved_files":0,"required_files":10,"uploads":{"used":2}}"#
        let (second, _) = makeClient([.reply(200, missing, [:])])
        let error = await dapiError { _ = try await second.onboarding() }
        guard case .readFailed? = error else { return XCTFail("\(String(describing: error))") }

        XCTAssertNil(dapiParseOnboarding(["status": "collecting", "approved_files": -1, "required_files": 10, "uploads": ["used": 0, "limit": 25]]))
        XCTAssertNil(dapiParseOnboarding(["status": "collecting", "approved_files": 1, "required_files": 10, "uploads": ["used": true, "limit": 25]]))
    }

    func testQuoteRequestAndParsing() async throws {
        let (client, transport) = makeClient([.reply(200, readyQuoteJSON, [:])])
        let quote = try await client.quote(id: "qte_bfP0GSqKoZFrD72H5Os0rc7HV9XP6eQJu")
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://public-api.dapi.digital/v2/quotes/qte_bfP0GSqKoZFrD72H5Os0rc7HV9XP6eQJu")
        XCTAssertEqual(transport.requests[0].httpMethod, "GET")
        assertAPIHeaders(transport.requests[0])
        XCTAssertEqual(quote.id, "qte_bfP0GSqKoZFrD72H5Os0rc7HV9XP6eQJu")
        XCTAssertEqual(quote.name, "Phone stand v2")
        XCTAssertTrue(quote.isReady)
        XCTAssertEqual(quote.price, DapiMoney(amountMinor: 1245, currency: "usd"))
        XCTAssertEqual(quote.price?.usd, Decimal(string: "12.45"))
        XCTAssertNil(quote.failureReason)
        XCTAssertEqual(quote.suggestedMaterials, [DapiSuggestedMaterial(slot: 1, materialName: "PLA Red", fileFilamentType: "PLA", match: "exact")])
        XCTAssertEqual(quote.createdAt?.timeIntervalSince1970 ?? 0, 1_793_396_533.55, accuracy: 0.001)
    }

    func testFailedQuoteReasonIsRedactedAndCapped() {
        let reason = "Slicing failed for https://files.example.com/a.stl?X-Amz-Signature=abc key \(testKey) " + String(repeating: "x", count: 600)
        let quote = dapiParseQuote(["id": "qte_abc", "status": "FAILED", "price": NSNull(), "failure_reason": reason], secrets: [testKey])
        XCTAssertEqual(quote?.status, "failed")
        XCTAssertTrue(quote?.isFailed ?? false)
        let text = quote?.failureReason ?? ""
        XCTAssertFalse(text.contains("X-Amz-Signature=abc"))
        XCTAssertFalse(text.contains("sk_3f9a"))
        XCTAssertLessThanOrEqual(text.count, dapiMaxFailureReasonLength + 1)
        XCTAssertGreaterThan(text.count, dapiMaxMessageLength, "failure reasons get more room than other messages")
    }

    func testApprovalStatusIsParsed() {
        XCTAssertEqual(dapiParseQuote(["id": "qte_a", "status": "ready", "approval": ["status": "REJECTED", "reason": "x"]])?.approvalStatus, "rejected")
        XCTAssertTrue(dapiParseQuote(["id": "qte_a", "status": "ready", "approval": ["status": "rejected"]])?.isRejected ?? false)
        XCTAssertNil(dapiParseQuote(["id": "qte_a", "status": "ready", "approval": NSNull()])?.approvalStatus)
        XCTAssertNil(dapiParseQuote(["id": "qte_a", "status": "ready"])?.approvalStatus)
        XCTAssertFalse(dapiParseQuote(["id": "qte_a", "status": "ready"])?.isUsable ?? true, "ready without a price")
        XCTAssertTrue(dapiParseQuote(["id": "qte_a", "status": "ready", "price": ["amount": 100, "currency": "usd"],
                                      "approval": ["status": "not_submitted"]])?.isUsable ?? false)
    }

    func testUnknownQuoteStatusIsKeptLowerCasedAndNotReady() {
        let quote = dapiParseQuote(["id": "qte_abc", "status": "Queued"])
        XCTAssertEqual(quote?.status, "queued")
        XCTAssertFalse(quote?.isReady ?? true)
        XCTAssertFalse(quote?.isProcessing ?? true)
        XCTAssertNil(dapiParseQuote(["id": "qte_a/b", "status": "ready"]))
        XCTAssertNil(dapiParseQuote(["id": "qte_abc"]))
        XCTAssertNil(dapiParseQuote(["id": 12, "status": "ready"]))
    }

    func testQuotesListPagesAndFiltersExactly() async throws {
        let page1 = listJSON([quoteJSON(id: "qte_a1", name: "Stand"), quoteJSON(id: "qte_a2", name: "stand"), quoteJSON(id: "qte_a3", name: "Stand ")],
                             hasMore: true, cursor: "c1+/=&x")
        let page2 = listJSON([quoteJSON(id: "qte_b1", name: "Stand", status: "processing"), quoteJSON(id: "qte_b2", name: "Other")],
                             hasMore: false, cursor: nil)
        let (client, transport) = makeClient([.reply(200, page1, [:]), .reply(200, page2, [:])])
        let quotes = try await client.quotes(named: "Stand", maxPages: 5)
        XCTAssertEqual(quotes.map(\.id), ["qte_a1", "qte_b1"])
        XCTAssertEqual(transport.count, 2)
        XCTAssertEqual(transport.requests[0].url?.absoluteString, "https://public-api.dapi.digital/v2/quotes?limit=100")
        XCTAssertEqual(transport.requests[1].url?.path, "/v2/quotes")
        XCTAssertEqual(transport.requests[1].url?.query, "limit=100&cursor=c1%2B%2F%3D%26x")
        XCTAssertEqual(queryItems(transport.requests[1]), ["limit": "100", "cursor": "c1+/=&x"])
        for request in transport.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            assertAPIHeaders(request)
        }
    }

    func testQuotesListStopsAtMaxPagesClamped() async throws {
        let endless = { (n: Int) in ScriptedDapiTransport.Step.reply(200, listJSON([], hasMore: true, cursor: "c\(n)"), [:]) }
        let (client, transport) = makeClient((0..<20).map(endless))
        _ = try await client.quotes(named: "Stand", maxPages: 3)
        XCTAssertEqual(transport.count, 3)

        let (many, manyTransport) = makeClient((0..<20).map(endless))
        _ = try await many.quotes(named: "Stand", maxPages: 50)
        XCTAssertEqual(manyTransport.count, 10)

        let (none, noneTransport) = makeClient((0..<20).map(endless))
        _ = try await none.quotes(named: "Stand", maxPages: 0)
        XCTAssertEqual(noneTransport.count, 1)
    }

    func testQuotesListFailsOnAMissingOrRepeatedCursor() async throws {
        // `has_more` without a cursor: the rest can't be read, and a partial answer could hide a quote.
        let (client, transport) = makeClient([.reply(200, listJSON([quoteJSON(id: "qte_a1", name: "Stand")], hasMore: true, cursor: nil), [:])])
        let missing = await dapiError { _ = try await client.quotes(named: "Stand", maxPages: 10) }
        guard case .readFailed? = missing else { return XCTFail("\(String(describing: missing))") }
        XCTAssertEqual(transport.count, 1)

        let repeated = listJSON([], hasMore: true, cursor: "same")
        let (second, secondTransport) = makeClient([.reply(200, repeated, [:]), .reply(200, repeated, [:]), .reply(200, repeated, [:])])
        let looped = await dapiError { _ = try await second.quotes(named: "Stand", maxPages: 10) }
        guard case .readFailed? = looped else { return XCTFail("\(String(describing: looped))") }
        XCTAssertEqual(secondTransport.count, 2)

        let (blank, _) = makeClient([.reply(200, #"{"object":"list","data":[],"has_more":true,"next_cursor":""}"#, [:])])
        let blankCursor = await dapiError { _ = try await blank.quotes(named: "Stand", maxPages: 10) }
        guard case .readFailed? = blankCursor else { return XCTFail("\(String(describing: blankCursor))") }

        let (empty, emptyTransport) = makeClient([.reply(200, #"{"object":"list","data":[],"has_more":false,"next_cursor":null}"#, [:])])
        let found = try await empty.quotes(named: "Stand", maxPages: 10)
        XCTAssertEqual(found, [])
        XCTAssertEqual(emptyTransport.count, 1)
    }

    func testQuotesListFailsOnALaterPageAndOnAnUnreadableMatch() async throws {
        let page1 = listJSON([quoteJSON(id: "qte_a1", name: "Stand")], hasMore: true, cursor: "c1")
        let (client, transport) = makeClient([.reply(200, page1, [:]), .reply(503, "{}", [:])])
        let error = await dapiError { _ = try await client.quotes(named: "Stand", maxPages: 5) }
        guard case .readFailed? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(transport.count, 2)

        let broken = #"{"object":"list","data":[{"id":"bad id","name":"Stand","status":"ready"},{"id":"qte_ok","name":"Other","status":"ready"}],"has_more":false,"next_cursor":null}"#
        let (second, _) = makeClient([.reply(200, broken, [:])])
        let unreadable = await dapiError { _ = try await second.quotes(named: "Stand", maxPages: 1) }
        guard case .readFailed? = unreadable else { return XCTFail("\(String(describing: unreadable))") }

        let skippable = #"{"object":"list","data":[{"id":"bad id","name":"Other","status":"ready"},7,{"id":"qte_ok","name":"Stand","status":"ready"}],"has_more":false,"next_cursor":null}"#
        let (third, _) = makeClient([.reply(200, skippable, [:])])
        let found = try await third.quotes(named: "Stand", maxPages: 1)
        XCTAssertEqual(found.map(\.id), ["qte_ok"])

        let (fourth, _) = makeClient([.reply(200, #"{"object":"list","data":{},"has_more":false}"#, [:])])
        let notList = await dapiError { _ = try await fourth.quotes(named: "Stand", maxPages: 1) }
        guard case .readFailed? = notList else { return XCTFail("\(String(describing: notList))") }
    }

    func testUploadQuoteFileSendsCreateThenPresignedPut() async throws {
        let file = try modelFile(bytes: 84)
        let (client, transport) = makeClient([.reply(201, uploadReplyJSON, [:]), .reply(200, "", [:])])
        let uploadID = try await uploadBoth(client, file: file, name: "Phone stand.stl", type: "model/stl", key: "idem-1")
        XCTAssertEqual(uploadID, "upl_bfP0GSqKoZFrD72H5Os0rc7HV9XP6eQJu")
        XCTAssertEqual(transport.count, 2)

        let create = transport.requests[0]
        XCTAssertEqual(create.httpMethod, "POST")
        XCTAssertEqual(create.url?.absoluteString, "https://public-api.dapi.digital/v2/uploads")
        assertAPIHeaders(create, idempotencyKey: "idem-1", json: true)
        let body = try XCTUnwrap(bodyJSON(create))
        XCTAssertEqual(body["purpose"] as? String, "quote_file")
        XCTAssertEqual(body["file_name"] as? String, "Phone stand.stl")
        XCTAssertEqual(body["content_type"] as? String, "model/stl")
        XCTAssertEqual(body["size_bytes"] as? Int, 84)
        XCTAssertEqual(Set(body.keys), ["purpose", "file_name", "content_type", "size_bytes"])

        let put = transport.requests[1]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.absoluteString, "https://files.example.com/temp/7f3a.stl?X-Amz-Signature=abc")
        XCTAssertEqual(put.value(forHTTPHeaderField: "Content-Type"), "model/stl")
        XCTAssertNil(put.value(forHTTPHeaderField: "x-api-key"))
        XCTAssertNil(put.value(forHTTPHeaderField: "User-Agent"))
        XCTAssertNil(put.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertNil(put.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(put.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(put.httpBody)
        XCTAssertFalse(put.httpShouldHandleCookies)
        XCTAssertEqual(transport.uploadedFiles, [file])
        for (_, value) in put.allHTTPHeaderFields ?? [:] { XCTAssertFalse(value.contains(testKey)) }
    }

    func testUploadDropsUnsafeStorageHeaders() async throws {
        let file = try modelFile()
        let headers = #"{"Content-Type":"model/stl","Authorization":"Bearer x","Cookie":"a=b","x-api-key":"k","Host":"evil.example","Content-Length":"9","Proxy-Thing":"1","x-amz-meta-plinth":"ok","X-Bad":"line\r\nInjected: 1","X-Key":"\#(testKey)","x-number":5,"X-Accent":"café"}"#
        let (client, transport) = makeClient([.reply(201, uploadReply(headers: headers), [:]), .reply(200, "", [:])])
        _ = try await uploadBoth(client, file: file, name: "a.stl", type: "model/stl", key: "k1")
        let put = transport.requests[1]
        let names = Set((put.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() })
        XCTAssertEqual(names, ["content-type", "x-amz-meta-plinth"])
    }

    func testUploadWithoutStorageHeadersSendsDeclaredContentType() async throws {
        let file = try modelFile(name: "part.3mf")
        let (client, transport) = makeClient([.reply(201, uploadReply(headers: "{}"), [:]), .reply(200, "", [:])])
        _ = try await uploadBoth(client, file: file, name: "part.3mf", type: "Model/3MF", key: "k1")
        XCTAssertEqual(bodyJSON(transport.requests[0])?["content_type"] as? String, "model/3mf")
        XCTAssertEqual(transport.requests[1].value(forHTTPHeaderField: "Content-Type"), "model/3mf")
    }

    func testUnsafePresignedLinksAreRefusedWithoutSendingBytes() async throws {
        let file = try modelFile()
        let unsafe = [
            "http://files.example.com/a.stl?sig=1", "https://127.0.0.1/a.stl", "https://[::1]/a.stl", "https://localhost/a.stl",
            "https://printer.local/a.stl", "https://user:pass@files.example.com/a.stl", "https://files.example.com:8443/a.stl",
            "https://storage/a.stl", "https://0x7f.0.0.1/a.stl", "https://2130706433/a.stl", "https://files.example.com/a.stl#frag",
            "https://files.example.com/a.stl?key=\(testKey)", "ftp://files.example.com/a.stl", "not a url"
        ]
        for link in unsafe {
            let (client, transport) = makeClient([.reply(201, uploadReply(url: link), [:]), .reply(200, "", [:])])
            let error = await dapiError { _ = try await uploadBoth(client, file: file, name: "a.stl", type: "model/stl", key: "k") }
            guard case .notSent(let message)? = error else { XCTFail("\(link): \(String(describing: error))"); continue }
            XCTAssertFalse(message.contains(testKey), link)
            XCTAssertEqual(transport.count, 1, link)
            XCTAssertTrue(transport.uploadedFiles.isEmpty, link)
        }
        let (client, transport) = makeClient([.reply(201, uploadReply(method: "POST"), [:])])
        let error = await dapiError { _ = try await uploadBoth(client, file: file, name: "a.stl", type: "model/stl", key: "k") }
        guard case .notSent? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(transport.count, 1)
        XCTAssertNil(dapiUploadURLProblem(URL(string: "https://dapi-uploads.s3.eu-central-1.amazonaws.com/temp/a.stl?X-Amz-Signature=x")!))
        XCTAssertNil(dapiUploadURLProblem(URL(string: "https://files.example.com:443/a.stl")!))
    }

    func testUploadReplyWithoutAValidIDIsAnUnknownOutcome() async throws {
        let file = try modelFile()
        let reply = #"{"id":"upl_../x","upload_url":"https://files.example.com/a","method":"PUT","headers":{}}"#
        let (client, transport) = makeClient([.reply(201, reply, [:])])
        let error = await dapiError { _ = try await uploadBoth(client, file: file, name: "a.stl", type: "model/stl", key: "k") }
        guard case .outcomeUnknown? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(transport.count, 1)
    }

    func testUploadRequestChecksHappenBeforeAnythingIsSent() async throws {
        let cases: [(String, String, Int64)] = [
            ("picture.png", "model/stl", 84), ("noextension", "model/stl", 84), ("a.stl", "image/png", 84), ("", "model/stl", 84),
            (String(repeating: "a", count: 300) + ".stl", "model/stl", 84), ("bad\nname.stl", "model/stl", 84),
            ("a.stl", "model/stl", 0), ("a.stl", "model/stl", dapiMaxQuoteFileBytes + 1),
            // The content type must match the extension: 3DAPI refuses a mismatch.
            ("a.stl", "model/obj", 84), ("a.obj", "model/stl", 84), ("a.stl", "application/octet-stream", 84),
            ("a.3mf", "model/stl", 84), ("a.step", "model/step", 84)
        ]
        for (name, type, size) in cases {
            let (client, transport) = makeClient([.reply(201, uploadReplyJSON, [:])])
            let error = await dapiError { _ = try await client.createUpload(fileName: name, contentType: type, sizeBytes: size, idempotencyKey: "k") }
            guard case .notSent? = error else { XCTFail("\(name) \(type): \(String(describing: error))"); continue }
            XCTAssertEqual(transport.count, 0, name)
        }
        let (client, _) = makeClient([])
        let png = await dapiError { _ = try await client.createUpload(fileName: "a.png", contentType: "image/png", sizeBytes: 1, idempotencyKey: "k") }
        XCTAssertEqual(png, .notSent("Plinth can quote STL, OBJ and 3MF models. Nothing was sent."))
        // Exactly the limit is allowed, and each format goes with its own type.
        for (name, type) in [("limit.stl", "model/stl"), ("a.OBJ", "model/obj"), ("a.3mf", "model/3mf")] {
            let (ok, transport) = makeClient([.reply(201, uploadReplyJSON, [:])])
            _ = try await ok.createUpload(fileName: name, contentType: type, sizeBytes: dapiMaxQuoteFileBytes, idempotencyKey: "k")
            XCTAssertEqual(bodyJSON(transport.requests[0])?["size_bytes"] as? Int64, dapiMaxQuoteFileBytes)
            XCTAssertEqual(bodyJSON(transport.requests[0])?["content_type"] as? String, type)
        }
    }

    func testBytesAreCheckedBeforeThePut() async throws {
        let file = try modelFile(bytes: 84)
        let missing = folder.appendingPathComponent("missing.stl")
        func target(size: Int64 = 84, url: String = "https://files.example.com/temp/a.stl?sig=1") -> DapiUploadTarget {
            DapiUploadTarget(uploadID: "upl_abc", uploadURL: URL(string: url)!, headers: [:], contentType: "model/stl", sizeBytes: size)
        }
        let cases: [(DapiUploadTarget, URL)] = [
            (target(size: 85), file), // the file changed size since the upload request
            (target(), missing), (target(), folder), (target(), URL(string: "https://example.com/a.stl")!),
            (target(url: "http://files.example.com/a.stl"), file), (target(url: "https://127.0.0.1/a.stl"), file)
        ]
        for (uploadTarget, url) in cases {
            let (client, transport) = makeClient([.reply(200, "", [:])])
            let error = await dapiError { try await client.sendUploadBytes(uploadTarget, fileURL: url) }
            guard case .notSent? = error else { XCTFail("\(url): \(String(describing: error))"); continue }
            XCTAssertEqual(transport.count, 0)
        }
        let (client, transport) = makeClient([.reply(200, "", [:])])
        try await client.sendUploadBytes(target(), fileURL: file)
        XCTAssertEqual(transport.uploadedFiles, [file])
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Content-Type"), "model/stl")
        XCTAssertNil(transport.requests[0].value(forHTTPHeaderField: "x-api-key"))
    }

    func testCancelledPutThrowsCancellation() async throws {
        let file = try modelFile(bytes: 84)
        let (client, transport) = makeClient([.fail(URLError(.cancelled))])
        let target = DapiUploadTarget(uploadID: "upl_abc", uploadURL: URL(string: "https://files.example.com/a.stl")!, headers: [:],
                                      contentType: "model/stl", sizeBytes: 84)
        do {
            try await client.sendUploadBytes(target, fileURL: file)
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.count, 1)
    }

    func testIdempotencyKeyIsValidatedBeforeSending() async throws {
        let file = try modelFile()
        for key in ["", "has space", "line\nbreak", String(repeating: "k", count: 256), "é"] {
            let (client, transport) = makeClient([.reply(201, uploadReplyJSON, [:])])
            let error = await dapiError { _ = try await uploadBoth(client, file: file, name: "a.stl", type: "model/stl", key: key) }
            guard case .notSent? = error else { XCTFail("\(key): \(String(describing: error))"); continue }
            XCTAssertEqual(transport.count, 0)
        }
    }

    func testCreateQuoteRequestAndParsing() async throws {
        let (client, transport) = makeClient([.reply(201, quoteJSON(id: "qte_new1", name: "Plinth stand", status: "processing"), [:])])
        let quote = try await client.createQuote(uploadID: "upl_abc123", name: "Plinth stand", idempotencyKey: "idem-2")
        XCTAssertEqual(quote.id, "qte_new1")
        XCTAssertTrue(quote.isProcessing)
        XCTAssertNil(quote.price)
        XCTAssertEqual(quote.suggestedMaterials, [])
        XCTAssertEqual(transport.count, 1)
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://public-api.dapi.digital/v2/quotes")
        assertAPIHeaders(request, idempotencyKey: "idem-2", json: true)
        let body = try XCTUnwrap(bodyJSON(request))
        XCTAssertEqual((body["file"] as? [String: Any])?["upload"] as? String, "upl_abc123")
        XCTAssertEqual(body["name"] as? String, "Plinth stand")
        XCTAssertEqual(Set(body.keys), ["file", "name"])
    }

    func testCreateQuoteChecksIDAndNameBeforeSending() async throws {
        for (id, name) in [("upl_a/b", "x"), ("qte_abc", "x"), ("upl_", "x"), ("upl_abc", ""), ("upl_abc", String(repeating: "n", count: 201)),
                           ("upl_abc", "a\u{0}b")] {
            let (client, transport) = makeClient([.reply(201, "{}", [:])])
            let error = await dapiError { _ = try await client.createQuote(uploadID: id, name: name, idempotencyKey: "k") }
            guard case .notSent? = error else { XCTFail("\(id): \(String(describing: error))"); continue }
            XCTAssertEqual(transport.count, 0)
        }
    }

    func testShippingEstimateRequestAndParsing() async throws {
        let reply = #"{"object":"shipping_estimate","country_code":"DE","zone":{"code":"eu-core","name":"EU-Core"},"tier":"small","additional_items":3,"total":{"amount":1099,"currency":"usd"}}"#
        let (client, transport) = makeClient([.reply(200, reply, [:])])
        let estimate = try await client.shippingEstimate(quoteID: "qte_abc", quantity: 4, countryCode: " de ")
        XCTAssertEqual(estimate, DapiShippingEstimate(countryCode: "DE", zoneName: "EU-Core", tier: "small", total: DapiMoney(amountMinor: 1099, currency: "usd")))
        let request = transport.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://public-api.dapi.digital/v2/integrator/orders/shipping-estimate")
        assertAPIHeaders(request, json: true)
        let body = try XCTUnwrap(bodyJSON(request))
        XCTAssertEqual(body["country"] as? String, "DE")
        let items = try XCTUnwrap(body["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0]["quote"] as? String, "qte_abc")
        XCTAssertEqual(items[0]["quantity"] as? Int, 4)
        XCTAssertEqual(Set(items[0].keys), ["quote", "quantity"])
    }

    func testShippingEstimateFlatRateAndUnreadableTotal() async throws {
        let flat = #"{"object":"shipping_estimate","country_code":"US","zone":null,"tier":null,"additional_items":0,"total":{"amount":749,"currency":"usd"}}"#
        let (client, _) = makeClient([.reply(200, flat, [:])])
        let estimate = try await client.shippingEstimate(quoteID: "qte_abc", quantity: 1, countryCode: "US")
        XCTAssertNil(estimate.zoneName)
        XCTAssertNil(estimate.tier)

        let negative = #"{"country_code":"US","total":{"amount":-5,"currency":"usd"}}"#
        let (second, transport) = makeClient([.reply(200, negative, [:])])
        let error = await dapiError { _ = try await second.shippingEstimate(quoteID: "qte_abc", quantity: 1, countryCode: "US") }
        guard case .readFailed? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(transport.count, 1)
    }

    func testShippingEstimateChecksBeforeSending() async throws {
        for (id, quantity, country) in [("qte_abc", 0, "US"), ("qte_abc", 10_001, "US"), ("qte_abc", 1, "USA"), ("qte_abc", 1, "U1"),
                                        ("qte_abc", 1, ""), ("qte_a.b", 1, "US"), ("upl_abc", 1, "US"), ("qte_abc", 1, "Ü1")] {
            let (client, transport) = makeClient([.reply(200, "{}", [:])])
            let error = await dapiError { _ = try await client.shippingEstimate(quoteID: id, quantity: quantity, countryCode: country) }
            guard case .notSent? = error else { XCTFail("\(id) \(quantity) \(country): \(String(describing: error))"); continue }
            XCTAssertEqual(transport.count, 0)
        }
    }

    // MARK: IDs and URLs

    func testQuoteIDsAreValidatedBeforeAnyRequest() async throws {
        for id in ["", "qte_", "qte_abc/def", "qte_../me", "qte_abc?x=1", "qte_abc#x", "qte_ab-c", "qte_ab_c", "QTE_abc", " qte_abc",
                   "qte_abc ", "qte_%2F", "qte_é", "qte_" + String(repeating: "a", count: 200), "upl_abc"] {
            let (client, transport) = makeClient([.reply(200, readyQuoteJSON, [:])])
            let error = await dapiError { _ = try await client.quote(id: id) }
            guard case .notSent? = error else { XCTFail("\(id): \(String(describing: error))"); continue }
            XCTAssertEqual(transport.count, 0, id)
        }
        XCTAssertTrue(dapiQuoteIDIsSafe("qte_bfP0GSqKoZFrD72H5Os0rc7HV9XP6eQJu"))
        XCTAssertTrue(dapiUploadIDIsSafe("upl_bfP0GSqKoZFrD72H5Os0rc7HV9XP6eQJu"))
        XCTAssertFalse(dapiUploadIDIsSafe("qte_bfP0"))
    }

    func testAPIURLRefusesUnsafePaths() {
        XCTAssertEqual(dapiAPIURL(path: "/v2/me")?.absoluteString, "https://public-api.dapi.digital/v2/me")
        for path in ["/v1/me", "v2/me", "/v2/../v1/me", "/v2/./me", "/v2//me", "/v2/me?x=1", "/v2/me#x", "/v2/a%2Fb", "/v2/a b", "//evil.example/v2/me"] {
            XCTAssertNil(dapiAPIURL(path: path), path)
        }
        XCTAssertEqual(dapiAPIURL(path: "/v2/quotes", query: [("limit", "100"), ("cursor", "a b&c=d+e")])?.query, "limit=100&cursor=a%20b%26c%3Dd%2Be")
    }

    // MARK: Keys

    func testKeyIsTrimmedAndRefusedWithInnerWhitespace() async throws {
        let (client, transport) = makeClient([.reply(200, #"{"kind":"integrator"}"#, [:])], key: "  \(testKey)\n")
        _ = try await client.account()
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "x-api-key"), testKey)

        let (spaced, spacedTransport) = makeClient([.reply(200, "{}", [:])], key: "sk_abc def")
        let error = await dapiError { _ = try await spaced.account() }
        guard case .notSent? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(spacedTransport.count, 0)

        let (empty, emptyTransport) = makeClient([.reply(200, "{}", [:])], key: "   ")
        let missing = await dapiError { _ = try await empty.account() }
        XCTAssertEqual(missing, .missingKey)
        XCTAssertEqual(emptyTransport.count, 0)
    }

    // MARK: Outcome classification

    func testDefiniteRefusalsIncluding409() async throws {
        let body = #"{"status_code":409,"error":"Conflict","code":"upload_limit_reached","message":"You used the 25 uploads of this onboarding round.","details":{"request_id":"req_1"}}"#
        let (client, transport) = makeClient([.reply(409, body, [:])])
        let error = await dapiError { _ = try await client.createQuote(uploadID: "upl_abc", name: "n", idempotencyKey: "k") }
        XCTAssertEqual(error, .refused(status: 409, code: "upload_limit_reached", message: "You used the 25 uploads of this onboarding round."))
        XCTAssertEqual(transport.count, 1)

        let invalid = #"{"status_code":422,"code":"invalid_file","message":"Not an STL","details":{"expected":"model/stl"}}"#
        let (second, _) = makeClient([.reply(422, invalid, [:])])
        let refusal = await dapiError { _ = try await second.createQuote(uploadID: "upl_abc", name: "n", idempotencyKey: "k") }
        XCTAssertEqual(refusal, .refused(status: 422, code: "invalid_file", message: "Not an STL"))

        let (third, _) = makeClient([.reply(404, #"{"code":"quote_not_found","message":"No such quote"}"#, [:])])
        let notFound = await dapiError { _ = try await third.quote(id: "qte_abc") }
        XCTAssertEqual(notFound, .refused(status: 404, code: "quote_not_found", message: "No such quote"))

        let (fourth, _) = makeClient([.reply(403, #"{"code":"Not A Code!","message":"x"}"#, [:])])
        let odd = await dapiError { _ = try await fourth.account() }
        XCTAssertEqual(odd, .refused(status: 403, code: nil, message: "x"))
    }

    func testWritesWithUnclearFailuresAreUnknownAndReadsAreReadFailed() async throws {
        let unclear: [ScriptedDapiTransport.Step] = [
            .reply(408, #"{"code":"request_timeout"}"#, [:]), .reply(500, #"{"code":"internal"}"#, [:]), .reply(503, "", [:]),
            .reply(302, "", ["Location": "https://elsewhere.example/"]), .reply(200, "not json", [:]), .reply(201, "[1,2]", [:]),
            .reply(422, "<html>bad gateway</html>", [:]), .reply(100, "", [:]),
            .fail(URLError(.timedOut)), .fail(URLError(.networkConnectionLost)), .fail(URLError(.notConnectedToInternet)),
            .fail(URLError(.secureConnectionFailed)), .fail(DapiTransportError.responseTooLarge), .fail(DapiTransportError.notHTTP),
            .fail(NSError(domain: "x", code: 1))
        ]
        for step in unclear {
            let (writer, writes) = makeClient([step])
            let writeError = await dapiError { _ = try await writer.createQuote(uploadID: "upl_abc", name: "n", idempotencyKey: "k") }
            guard case .outcomeUnknown? = writeError else { XCTFail("create \(step): \(String(describing: writeError))"); continue }
            XCTAssertEqual(writes.count, 1)

            let file = try modelFile()
            let (uploader, uploads) = makeClient([step])
            let uploadError = await dapiError { _ = try await uploadBoth(uploader, file: file, name: "a.stl", type: "model/stl", key: "k") }
            guard case .outcomeUnknown? = uploadError else { XCTFail("upload \(step): \(String(describing: uploadError))"); continue }
            XCTAssertEqual(uploads.count, 1)

            let (reader, reads) = makeClient([step])
            let readError = await dapiError { _ = try await reader.quote(id: "qte_abc") }
            guard case .readFailed? = readError else { XCTFail("read \(step): \(String(describing: readError))"); continue }
            XCTAssertEqual(reads.count, 1)

            let (estimator, estimates) = makeClient([step])
            let estimateError = await dapiError { _ = try await estimator.shippingEstimate(quoteID: "qte_abc", quantity: 1, countryCode: "GB") }
            guard case .readFailed? = estimateError else { XCTFail("estimate \(step): \(String(describing: estimateError))"); continue }
            XCTAssertEqual(estimates.count, 1)
        }
    }

    func testFailuresBeforeSendingAreNotSent() async throws {
        for code in [URLError.Code.badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection, .cannotFindHost, .dnsLookupFailed] {
            let (client, transport) = makeClient([.fail(URLError(code))])
            let error = await dapiError { _ = try await client.createQuote(uploadID: "upl_abc", name: "n", idempotencyKey: "k") }
            guard case .notSent? = error else { XCTFail("\(code): \(String(describing: error))"); continue }
            XCTAssertEqual(transport.count, 1)
        }
        // A GET may be resent on a fresh connection, so a DNS failure isn't proof for it.
        let (reader, _) = makeClient([.fail(URLError(.cannotFindHost))])
        let readError = await dapiError { _ = try await reader.account() }
        guard case .readFailed? = readError else { return XCTFail("\(String(describing: readError))") }
        XCTAssertTrue(dapiURLErrorIsBeforeSending(.cannotFindHost, method: "POST"))
        XCTAssertFalse(dapiURLErrorIsBeforeSending(.cannotFindHost, method: "PUT"))
        XCTAssertFalse(dapiURLErrorIsBeforeSending(.notConnectedToInternet, method: "POST"))
        XCTAssertFalse(dapiURLErrorIsBeforeSending(.timedOut, method: "POST"))
    }

    func testStoragePutOutcomes() async throws {
        let file = try modelFile()
        let cases: [(ScriptedDapiTransport.Step, String)] = [
            (.reply(403, "<Error><Code>SignatureDoesNotMatch</Code></Error>", [:]), "refused"),
            (.reply(400, "", [:]), "refused"),
            (.reply(408, "", [:]), "unknown"), (.reply(500, "", [:]), "unknown"), (.reply(307, "", ["Location": "https://x.example/"]), "unknown"),
            (.reply(429, "", ["Retry-After": "5"]), "rate"),
            (.fail(URLError(.timedOut)), "unknown"), (.fail(URLError(.cannotFindHost)), "unknown"), (.fail(URLError(.networkConnectionLost)), "unknown"),
            (.fail(URLError(.badURL)), "notSent")
        ]
        for (step, expected) in cases {
            let (client, transport) = makeClient([.reply(201, uploadReplyJSON, [:]), step])
            let error = await dapiError { _ = try await uploadBoth(client, file: file, name: "a.stl", type: "model/stl", key: "k") }
            switch (error, expected) {
            case (.refused(let status, nil, nil)?, "refused"): XCTAssertTrue((400..<500).contains(status))
            case (.outcomeUnknown?, "unknown"), (.rateLimited(nil, _)?, "rate"), (.notSent?, "notSent"): break
            default: XCTFail("\(step): \(String(describing: error)) expected \(expected)")
            }
            XCTAssertEqual(transport.count, 2)
            XCTAssertEqual(transport.uploadedFiles.count, 1)
        }
    }

    func testRateLimitsWithRetryAfterAndResetSeconds() async throws {
        let now = Date()
        let (client, transport) = makeClient([.reply(429, #"{"code":"rate_limited","message":"Too many"}"#, ["retry-after": "30", "X-RateLimit-Reset": "1"])])
        let error = await dapiError { _ = try await client.quote(id: "qte_abc") }
        guard case .rateLimited(let code, let retryAt)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertEqual(code, "rate_limited")
        XCTAssertEqual(retryAt?.timeIntervalSince(now) ?? 0, 30, accuracy: 5)
        XCTAssertEqual(transport.count, 1)

        let reset = Int(now.timeIntervalSince1970) + 45
        let (second, _) = makeClient([.reply(429, #"{"code":"daily_quote_limit_reached","message":"Daily"}"#, ["X-RateLimit-Reset": "\(reset)"])])
        let daily = await dapiError { _ = try await second.createQuote(uploadID: "upl_abc", name: "n", idempotencyKey: "k") }
        guard case .rateLimited(let dailyCode, let dailyAt)? = daily else { return XCTFail("\(String(describing: daily))") }
        XCTAssertEqual(dailyCode, "daily_quote_limit_reached")
        XCTAssertEqual(dailyAt?.timeIntervalSince1970 ?? 0, Double(reset), accuracy: 1)

        let (third, _) = makeClient([.reply(429, "", [:])])
        let bare = await dapiError { _ = try await third.account() }
        XCTAssertEqual(bare, .rateLimited(code: nil, retryAt: nil))
    }

    func testRetryAtIgnoresNonsenseAndCapsAtAnHour() {
        let now = Date(timeIntervalSince1970: 1_793_396_535)
        XCTAssertEqual(dapiRetryAt(retryAfter: "0", rateLimitReset: nil, now: now), now)
        XCTAssertEqual(dapiRetryAt(retryAfter: "86400", rateLimitReset: nil, now: now), now.addingTimeInterval(3600))
        XCTAssertNil(dapiRetryAt(retryAfter: "-5", rateLimitReset: nil, now: now))
        XCTAssertNil(dapiRetryAt(retryAfter: "soon", rateLimitReset: nil, now: now))
        XCTAssertNil(dapiRetryAt(retryAfter: "nan", rateLimitReset: nil, now: now))
        XCTAssertNil(dapiRetryAt(retryAfter: "Fri, 30 Oct 2026 21:43:15 GMT", rateLimitReset: nil, now: now))
        XCTAssertEqual(dapiRetryAt(retryAfter: "-5", rateLimitReset: "1793396595", now: now), Date(timeIntervalSince1970: 1_793_396_595))
        XCTAssertNil(dapiRetryAt(retryAfter: nil, rateLimitReset: "1793396500", now: now))
        XCTAssertNil(dapiRetryAt(retryAfter: nil, rateLimitReset: "1793396595000", now: now))
        XCTAssertEqual(dapiRetryAt(retryAfter: nil, rateLimitReset: "1893396595", now: now), now.addingTimeInterval(3600))
        XCTAssertNil(dapiRetryAt(retryAfter: nil, rateLimitReset: "inf", now: now))
        XCTAssertNil(dapiRetryAt(retryAfter: nil, rateLimitReset: nil, now: now))
    }

    func testCancellationPassesThrough() async throws {
        let (client, transport) = makeClient([.fail(CancellationError())])
        do {
            _ = try await client.createQuote(uploadID: "upl_abc", name: "n", idempotencyKey: "k")
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
        XCTAssertEqual(transport.count, 1)

        let (second, _) = makeClient([.fail(URLError(.cancelled))])
        do {
            _ = try await second.account()
            XCTFail("Expected cancellation")
        } catch is CancellationError {
        } catch { XCTFail("\(error)") }
    }

    // MARK: Parsing details

    func testMoneyParsing() {
        XCTAssertEqual(dapiMoney(["amount": 1245, "currency": "usd"]), DapiMoney(amountMinor: 1245, currency: "usd"))
        XCTAssertEqual(dapiMoney(["amount": 0, "currency": "USD"]), DapiMoney(amountMinor: 0, currency: "usd"))
        let euro = dapiMoney(["amount": 500, "currency": "eur"])
        XCTAssertEqual(euro?.currency, "eur")
        XCTAssertNil(euro?.usd)
        XCTAssertNil(dapiMoney(["amount": -1, "currency": "usd"]))
        XCTAssertNil(dapiMoney(["amount": 12.5, "currency": "usd"]))
        XCTAssertNil(dapiMoney(["amount": "1245", "currency": "usd"]))
        XCTAssertNil(dapiMoney(["amount": true, "currency": "usd"]))
        XCTAssertNil(dapiMoney(["amount": 1e30, "currency": "usd"]))
        XCTAssertNil(dapiMoney(["amount": 100, "currency": "us"]))
        XCTAssertNil(dapiMoney(["amount": 100, "currency": "u$d"]))
        XCTAssertNil(dapiMoney(["amount": 100]))
        XCTAssertNil(dapiMoney(NSNull()))
    }

    func testDateParsing() {
        XCTAssertEqual(dapiDate("2026-10-30T21:42:13.550Z")?.timeIntervalSince1970 ?? 0, 1_793_396_533.55, accuracy: 0.001)
        XCTAssertEqual(dapiDate("2026-10-30T21:42:13Z"), Date(timeIntervalSince1970: 1_793_396_533))
        XCTAssertNil(dapiDate("yesterday"))
        XCTAssertNil(dapiDate(12))
        XCTAssertNil(dapiDate(nil))
    }

    func testMalformedJSONTypesAreHandled() {
        XCTAssertNil(dapiParseAccount(["kind": 3]))
        XCTAssertEqual(dapiParseAccount(["kind": "designer", "effective_scopes": "quotes:read"])?.effectiveScopes, [])
        let quote = dapiParseQuote(["id": "qte_x", "status": "ready", "price": ["amount": "12"], "suggested_materials": [["slot": "1"], 4, ["slot": 2, "material": "PLA"]],
                                    "name": 5, "created_at": "nope"])
        XCTAssertNotNil(quote)
        XCTAssertNil(quote?.price)
        XCTAssertNil(quote?.name)
        XCTAssertNil(quote?.createdAt)
        XCTAssertEqual(quote?.suggestedMaterials, [DapiSuggestedMaterial(slot: 2, materialName: nil, fileFilamentType: nil, match: nil)])
        XCTAssertNil(dapiErrorBody(Data("[]".utf8)))
        XCTAssertNil(dapiErrorBody(Data()))
    }

    // MARK: Redaction and copy

    func testRedaction() {
        let text = "key \(testKey) and sk_live99 and x-api-key: other123 at https://bucket.s3.amazonaws.com/a.stl?X-Amz-Signature=deadbeef&X-Amz-Credential=AKIA1 X-Amz-Signature=cafe"
        let redacted = dapiRedacted(text, secrets: [testKey])
        XCTAssertFalse(redacted.contains("3f9a1c2b"))
        XCTAssertFalse(redacted.contains("sk_live99"))
        XCTAssertFalse(redacted.contains("other123"))
        XCTAssertFalse(redacted.contains("deadbeef"))
        XCTAssertFalse(redacted.contains("AKIA1"))
        XCTAssertFalse(redacted.contains("cafe"))
        XCTAssertTrue(redacted.contains("https://bucket.s3.amazonaws.com/a.stl"))
        XCTAssertEqual(dapiRedacted("risk_score stays"), "risk_score stays")
        XCTAssertLessThanOrEqual(dapiRedacted(String(repeating: "a", count: 2000)).count, dapiMaxMessageLength + 1)
        XCTAssertFalse(dapiRedacted("line one\nline two").contains("\n"))
    }

    func testRefusedMessagesAreRedacted() async throws {
        let body = #"{"code":"validation_failed","message":"Bad key \#(testKey) for https://x.example/a?signature=abc"}"#
        let (client, _) = makeClient([.reply(400, body, [:])])
        let error = await dapiError { _ = try await client.account() }
        guard case .refused(400, "validation_failed", let message?)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertFalse(message.contains("3f9a1c2b"))
        XCTAssertFalse(message.contains("signature=abc"))
        XCTAssertFalse(error?.userMessage.contains("3f9a1c2b") ?? true)
        XCTAssertTrue(error?.userMessage.hasPrefix("3DAPI said the request wasn’t valid") ?? false)
    }

    func testActivityDetailIsStatusOnly() {
        XCTAssertEqual(DapiError.refused(status: 422, code: "invalid_file", message: "file stand.stl at https://x.example?sig=1").activityDetail, "HTTP 422 invalid_file")
        XCTAssertEqual(DapiError.refused(status: 403, code: "Bad Code", message: nil).activityDetail, "HTTP 403")
        XCTAssertEqual(DapiError.rateLimited(code: "rate_limited", retryAt: nil).activityDetail, "Rate limited")
        XCTAssertEqual(DapiError.rateLimited(code: "daily_quote_limit_reached", retryAt: nil).activityDetail, "Daily quote limit reached")
        XCTAssertEqual(DapiError.outcomeUnknown("qte_abc stand.stl").activityDetail, "Outcome unknown")
        XCTAssertEqual(DapiError.readFailed("qte_abc").activityDetail, "Read failed")
        XCTAssertEqual(DapiError.notSent("stand.stl").activityDetail, "Not sent")
        XCTAssertEqual(DapiError.missingKey.activityDetail, "No key")
    }

    func testUserMessagesForKnownCodes() {
        func message(_ code: String, _ status: Int = 422) -> String { DapiError.refused(status: status, code: code, message: "raw text").userMessage }
        XCTAssertTrue(message("actor_not_allowed", 403).contains("integrator"))
        XCTAssertTrue(message("upload_limit_reached", 409).contains("25"))
        XCTAssertTrue(message("shipping_destination_not_served").contains("Russia, Belarus, Iran and Syria"))
        XCTAssertTrue(message("invalid_api_key", 401).contains("key"))
        for code in ["invalid_api_key", "missing_scope", "actor_not_allowed", "purpose_not_allowed", "file_type_not_allowed", "file_too_large",
                     "invalid_file", "upload_expired", "upload_already_used", "upload_limit_reached", "approval_in_review",
                     "daily_quote_limit_reached", "quote_not_found", "quote_not_ready", "quote_rejected", "shipping_destination_not_served",
                     "idempotency_key_reused", "rate_limited"] {
            XCTAssertFalse(message(code).contains("raw text"), code)
        }
        XCTAssertEqual(DapiError.refused(status: 418, code: "teapot", message: "I’m a teapot").userMessage, "3DAPI refused the request (HTTP 418): I’m a teapot")
        XCTAssertEqual(DapiError.refused(status: 418, code: nil, message: nil).userMessage, "3DAPI refused the request (HTTP 418).")
        XCTAssertTrue(DapiError.rateLimited(code: "daily_quote_limit_reached", retryAt: nil).userMessage.contains("midnight UTC"))
        let now = Date()
        XCTAssertTrue(DapiError.rateLimited(code: "rate_limited", retryAt: now.addingTimeInterval(30)).userMessage(now: now).contains("in a minute"))
        XCTAssertTrue(DapiError.rateLimited(code: nil, retryAt: now.addingTimeInterval(600)).userMessage(now: now).contains("about 10 minutes"))
        XCTAssertFalse(DapiError.missingKey.userMessage.isEmpty)
    }

    func testUnknownUploadMessagesSayNothingWasSentAgain() async throws {
        let (client, _) = makeClient([.fail(URLError(.timedOut))])
        let error = await dapiError { _ = try await client.createQuote(uploadID: "upl_abc", name: "n", idempotencyKey: "k") }
        XCTAssertTrue(error?.userMessage.contains("didn’t send it again") ?? false)
        XCTAssertEqual(error?.activityDetail, "Outcome unknown")
    }

    func testUploadResourceTimeoutScalesWithSize() {
        XCTAssertEqual(dapiUploadResourceTimeout(bytes: 1), 300)
        XCTAssertGreaterThan(dapiUploadResourceTimeout(bytes: dapiMaxQuoteFileBytes), 1200)
        XCTAssertLessThanOrEqual(dapiUploadResourceTimeout(bytes: .max), 3600)
        XCTAssertEqual(dapiQuoteFileContentType(forExtension: "STL"), "model/stl")
        XCTAssertNil(dapiQuoteFileContentType(forExtension: "png"))
    }

    func testSessionConfigurationKeepsNoState() {
        let configuration = dapiSessionConfiguration(requestTimeout: 30, resourceTimeout: 60)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 60)
    }
}
