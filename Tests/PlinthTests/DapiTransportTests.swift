import XCTest
@testable import Plinth

// The real 3DAPI transport (`URLSessionDapiTransport` and its capped task delegate), driven through a stub
// `URLProtocol`: nothing reaches the network.

/// Answers every request as `mode` says and records each URL it sees. Static, so one test at a time (XCTest runs a
/// class's tests one after another).
final class DapiTransportStubProtocol: URLProtocol {
    enum Mode {
        /// A real redirect (through `wasRedirectedTo`, so the session's delegates are asked) to `elsewhere`; when it is
        /// refused, the 3xx itself is the reply.
        case redirect
        /// A reply in pieces, with these headers.
        case reply(status: Int, headers: [String: String], chunks: [Data])
        /// A reply that isn't HTTP.
        case notHTTP
        /// Never answers until stopped.
        case hang
    }

    static let elsewhere = URL(string: "https://elsewhere.example.net/landing")!
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _mode: Mode = .hang
    nonisolated(unsafe) private static var _seen: [URL] = []
    nonisolated(unsafe) private static var _stopped = 0

    static func reset(_ mode: Mode) { lock.withLock { _mode = mode; _seen = []; _stopped = 0 } }
    static var requested: [URL] { lock.withLock { _seen } }
    static var stopped: Int { lock.withLock { _stopped } }
    static var reachedElsewhere: Bool { requested.contains { $0.host == elsewhere.host } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let mode = Self.lock.withLock { () -> Mode in Self._seen.append(url); return Self._mode }
        if url.host == Self.elsewhere.host {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"kind":"integrator"}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        switch mode {
        case .redirect:
            let redirect = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": Self.elsewhere.absoluteString, "Content-Length": "0"])!
            var next = URLRequest(url: Self.elsewhere)
            next.httpMethod = request.httpMethod
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
            client?.urlProtocol(self, didReceive: redirect, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case .reply(let status, let headers, let chunks):
            let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            for chunk in chunks { client?.urlProtocol(self, didLoad: chunk) }
            client?.urlProtocolDidFinishLoading(self)
        case .notHTTP:
            let response = URLResponse(url: url, mimeType: "text/plain", expectedContentLength: 2, textEncodingName: nil)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .hang:
            break
        }
    }

    override func stopLoading() { Self.lock.withLock { Self._stopped += 1 } }
}

private let transportTestKey = "sk_3f9a1c2b7d4e5f60718293a4b5c6d7e8f90123456789abcdef0123456789abcd"

final class DapiTransportTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("DapiTransportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
        DapiTransportStubProtocol.reset(.hang)
    }

    private func transport() -> URLSessionDapiTransport { URLSessionDapiTransport(protocolClasses: [DapiTransportStubProtocol.self]) }
    private func client() -> DapiClient { DapiClient(apiKey: transportTestKey, transport: transport()) }

    private func modelFile() throws -> URL {
        let url = folder.appendingPathComponent("plinth-0123456789abcdef.stl")
        try Data("solid x\nendsolid x\n".utf8).write(to: url)
        return url
    }

    private func putRequest() -> URLRequest {
        var put = URLRequest(url: URL(string: "https://files.example.com/temp/a.stl?X-Amz-Signature=abc")!)
        put.httpMethod = "PUT"
        put.httpShouldHandleCookies = false
        put.setValue("model/stl", forHTTPHeaderField: "Content-Type")
        return put
    }

    // MARK: Redirects

    /// Without the transport's refusal the same stub's redirect is followed, so the tests below prove the refusal.
    func testTheStubsRedirectIsFollowedByAPlainSession() async throws {
        DapiTransportStubProtocol.reset(.redirect)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [DapiTransportStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (_, response) = try await session.data(from: URL(string: "https://public-api.dapi.digital/v2/me")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(DapiTransportStubProtocol.reachedElsewhere)
    }

    func testAnAPIRedirectComesBackAsTheReplyAndIsNeverFollowed() async throws {
        DapiTransportStubProtocol.reset(.redirect)
        let request = try client().makeAPIRequest(method: "GET", path: "/v2/me")
        let reply = try await transport().send(request)
        XCTAssertEqual(reply.status, 302)
        XCTAssertFalse(DapiTransportStubProtocol.reachedElsewhere, "the key must never follow a redirect")
        XCTAssertEqual(DapiTransportStubProtocol.requested.count, 1)

        // Through the client: a read fails, a write's outcome is unknown, and neither is followed.
        DapiTransportStubProtocol.reset(.redirect)
        do {
            _ = try await client().account()
            XCTFail("a redirect must not succeed")
        } catch let error as DapiError {
            guard case .readFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("redirect"), message)
        }
        DapiTransportStubProtocol.reset(.redirect)
        do {
            _ = try await client().createQuote(uploadID: "upl_abc123", name: "Plinth 0123456789abcdef", idempotencyKey: "idem-1")
            XCTFail("a redirect must not succeed")
        } catch let error as DapiError {
            guard case .outcomeUnknown = error else { return XCTFail("\(error)") }
        }
        XCTAssertFalse(DapiTransportStubProtocol.reachedElsewhere)
        XCTAssertEqual(DapiTransportStubProtocol.requested.count, 1)
    }

    func testAStoragePutRedirectComesBackAsTheReplyAndIsNeverFollowed() async throws {
        DapiTransportStubProtocol.reset(.redirect)
        let reply = try await transport().upload(putRequest(), fromFile: try modelFile())
        XCTAssertEqual(reply.status, 302)
        XCTAssertFalse(DapiTransportStubProtocol.reachedElsewhere, "model bytes must never go to a host 3DAPI didn't name")
        XCTAssertEqual(DapiTransportStubProtocol.requested.count, 1)
        // And the client counts it as an unclear transfer.
        let error = dapiClassifyReply(reply, operation: .storagePut)
        guard case .outcomeUnknown = error else { return XCTFail("\(error)") }
    }

    // MARK: Reply caps

    func testAReplyOverTheCapIsRefusedByItsLength() async throws {
        DapiTransportStubProtocol.reset(.reply(status: 200, headers: ["Content-Length": String(dapiMaxResponseBytes + 1)],
                                               chunks: [Data("{}".utf8)]))
        do {
            _ = try await transport().send(try client().makeAPIRequest(method: "GET", path: "/v2/me"))
            XCTFail("an over-large reply must not be read")
        } catch let error as DapiTransportError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testAReplyOverTheCapIsStoppedWhileStreaming() async throws {
        // No Content-Length: the running total stops it.
        let piece = Data(repeating: 0x20, count: 256 * 1024)
        DapiTransportStubProtocol.reset(.reply(status: 200, headers: [:], chunks: Array(repeating: piece, count: 9)))
        do {
            _ = try await transport().send(try client().makeAPIRequest(method: "GET", path: "/v2/me"))
            XCTFail("an over-large reply must not be read")
        } catch let error as DapiTransportError {
            XCTAssertEqual(error, .responseTooLarge)
        }
        // Through the client, a read that was too large is a read failure.
        DapiTransportStubProtocol.reset(.reply(status: 200, headers: [:], chunks: Array(repeating: piece, count: 9)))
        do {
            _ = try await client().account()
            XCTFail("an over-large reply must not be read")
        } catch let error as DapiError {
            guard case .readFailed(let message) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(message.contains("too large"), message)
        }
    }

    func testTheStorageReplyHasItsOwnSmallerCap() async throws {
        let over = Data(repeating: 0x20, count: dapiMaxStorageResponseBytes + 1)
        DapiTransportStubProtocol.reset(.reply(status: 200, headers: [:], chunks: [over]))
        do {
            _ = try await transport().upload(putRequest(), fromFile: try modelFile())
            XCTFail("an over-large storage reply must not be read")
        } catch let error as DapiTransportError {
            XCTAssertEqual(error, .responseTooLarge)
        }
        DapiTransportStubProtocol.reset(.reply(status: 200, headers: ["Content-Length": String(dapiMaxStorageResponseBytes + 1)], chunks: []))
        do {
            _ = try await transport().upload(putRequest(), fromFile: try modelFile())
            XCTFail("an over-large storage reply must not be read")
        } catch let error as DapiTransportError {
            XCTAssertEqual(error, .responseTooLarge)
        }
    }

    func testRepliesWithinTheCapsAreReadWhole() async throws {
        let body = Data(#"{"kind":"integrator","approval":"approved","effective_scopes":["quotes:read"]}"#.utf8)
        DapiTransportStubProtocol.reset(.reply(status: 200, headers: ["Content-Type": "application/json", "X-RateLimit-Reset": "1794447743"],
                                               chunks: [body.prefix(10), body.dropFirst(10)]))
        let reply = try await transport().send(try client().makeAPIRequest(method: "GET", path: "/v2/me"))
        XCTAssertEqual(reply.status, 200)
        XCTAssertEqual(reply.body, body)
        XCTAssertEqual(reply.header("x-ratelimit-reset"), "1794447743")

        DapiTransportStubProtocol.reset(.reply(status: 200, headers: [:], chunks: [Data(repeating: 0x20, count: dapiMaxStorageResponseBytes)]))
        let stored = try await transport().upload(putRequest(), fromFile: try modelFile())
        XCTAssertEqual(stored.status, 200)
        XCTAssertEqual(stored.body.count, dapiMaxStorageResponseBytes)
    }

    func testAReplyThatIsntHTTPIsRefused() async throws {
        DapiTransportStubProtocol.reset(.notHTTP)
        do {
            _ = try await transport().send(try client().makeAPIRequest(method: "GET", path: "/v2/me"))
            XCTFail("a reply that isn't HTTP must not be read")
        } catch let error as DapiTransportError {
            XCTAssertEqual(error, .notHTTP)
        }
    }

    // MARK: Cancellation

    func testCancellingTheCallerCancelsTheRequest() async throws {
        DapiTransportStubProtocol.reset(.hang)
        let transport = transport()
        let request = try client().makeAPIRequest(method: "GET", path: "/v2/me")
        let task = Task { try await transport.send(request) }
        for _ in 0..<2_000 where DapiTransportStubProtocol.requested.isEmpty { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(DapiTransportStubProtocol.requested.count, 1)
        let cancelled = Date()
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled request must not return a reply")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelled), 10)
        for _ in 0..<2_000 where DapiTransportStubProtocol.stopped == 0 { try await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertEqual(DapiTransportStubProtocol.stopped, 1, "the URL task itself was stopped")
    }

    func testCancellingBeforeTheRequestStartsSendsNothing() async throws {
        DapiTransportStubProtocol.reset(.hang)
        let transport = transport()
        let request = try client().makeAPIRequest(method: "GET", path: "/v2/me")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await transport.send(request)
        }
        do {
            _ = try await task.value
            XCTFail("a cancelled request must not return a reply")
        } catch {
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        XCTAssertTrue(DapiTransportStubProtocol.requested.isEmpty)
    }
}
