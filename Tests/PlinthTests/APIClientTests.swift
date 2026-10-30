import XCTest
@testable import SlantStudio

private final class StubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, [String: String], Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, headers, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private final class UploadStageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stages: [UploadStage] = []
    func append(_ stage: UploadStage) { lock.lock(); stages.append(stage); lock.unlock() }
    var all: [UploadStage] { lock.lock(); defer { lock.unlock() }; return stages }
}

private final class PathRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    func append(_ path: String) { lock.lock(); paths.append(path); lock.unlock() }
    func reset() { lock.lock(); paths = []; lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return paths }
}

final class APIClientTests: XCTestCase {
    private func client() -> APIClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        return APIClient(apiKey: "sl_test", configuration: configuration)
    }

    override func tearDown() {
        StubProtocol.handler = nil
        super.tearDown()
    }

    func testQueryEncodingAndAuthentication() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "slant3dapi.com")
            XCTAssertEqual(request.url?.path, "/v2/api/files")
            let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(items?.first?.value, "A&B + C")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sl_test")
            return (200, [:], Data("{\"data\":[]}".utf8))
        }
        let result = try await client().request("GET", path: "/files", query: ["ownerId": "A&B + C"])
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertNotNil(result.json)
    }

    func testPublicHealthNeedsNoAPIKey() async throws {
        StubProtocol.handler = { request in
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            XCTAssertEqual(request.url?.path, "/v2/api/health/status")
            return (200, [:], Data("{}".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        _ = try await APIClient(apiKey: "", configuration: configuration).request("GET", path: "/health/status")
    }

    func testWebhookUsesOperationSpecificServer() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v2/slant/webhook")
            return (200, [:], Data("{}".utf8))
        }
        _ = try await client().request("POST", path: "/slant/webhook", body: ["test": true])
    }

    func testEncodedIDIsNotEncodedTwice() async throws {
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://slant3dapi.com/v2/api/files/model%20a%2Fb")
            return (200, [:], Data("{}".utf8))
        }
        _ = try await client().request("GET", path: "/files/model%20a%2Fb")
    }

    func testEncodedTraversalRejected() async throws {
        StubProtocol.handler = { _ in
            XCTFail("Traversal must not be sent")
            return (200, [:], Data())
        }
        do {
            _ = try await client().request("GET", path: "/files/%2E%2E/platforms")
            XCTFail("Expected validation failure")
        } catch APIError.invalidRequest { }
    }

    func testHTTP200EnvelopeFailureIsAnError() async throws {
        StubProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"], Data("{\"success\":false,\"error\":\"Conversion failed\"}".utf8))
        }
        do {
            _ = try await client().request("POST", path: "/files/openScad", body: ["scadCode": "cube(1);"])
            XCTFail("Expected API envelope failure")
        } catch APIError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("Conversion failed"))
            XCTAssertTrue(message.contains("HTTP 200"))
        }
    }

    func testNestedWebhookFailureIsStillAValidResponse() async throws {
        StubProtocol.handler = { _ in
            (200, ["Content-Type": "application/json; charset=utf-8"], Data("{\"success\":true,\"data\":{\"success\":false}}".utf8))
        }
        let result = try await client().request("POST", path: "/slant/webhook", body: ["test": true])
        XCTAssertEqual(result.contentType, "application/json; charset=utf-8")
        XCTAssertNotNil(result.json)
    }

    func testOpenSCADRejectsJSONInsteadOfModelBytes() async throws {
        StubProtocol.handler = { _ in
            (200, ["Content-Type": "application/json"], Data("{\"success\":true}".utf8))
        }
        do {
            _ = try await client().request("POST", path: "/files/openScad", body: ["scadCode": "cube(1);"])
            XCTFail("JSON must not be saved as an STL")
        } catch APIError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("instead of STL"))
        }
    }

    func testOpenSCADAcceptsSTLWithDeclaredContentType() async throws {
        let stl = Data("solid test\nendsolid test".utf8)
        StubProtocol.handler = { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Accept")?.contains("application/sla") == true)
            return (200, ["Content-Type": "application/sla"], stl)
        }
        let result = try await client().request("POST", path: "/files/openScad", body: ["scadCode": "cube(1);"])
        XCTAssertEqual(result.data, stl)
        XCTAssertEqual(result.contentType, "application/sla")
    }

    func testHTTPErrorPreservesRetryAfterAndDoesNotRetry() async throws {
        var calls = 0
        StubProtocol.handler = { _ in
            calls += 1
            return (429, ["Retry-After": "30"], Data("{\"error\":\"Rate limited\"}".utf8))
        }
        do {
            _ = try await client().request("POST", path: "/files", body: ["name": "test"])
            XCTFail("Expected HTTP failure")
        } catch APIError.http(let status, let body, let retryAfter, let rateLimitReset) {
            XCTAssertEqual(status, 429)
            XCTAssertEqual(retryAfter, "30")
            XCTAssertNil(rateLimitReset)
            XCTAssertTrue(body.contains("Rate limited"))
        }
        XCTAssertEqual(calls, 1)
    }

    func testResponseKeepsRateLimitHeaders() async throws {
        StubProtocol.handler = { _ in
            (200, [
                "Content-Type": "application/json",
                "X-RateLimit-Limit": "100",
                "X-RateLimit-Remaining": "99",
                "X-RateLimit-Reset": "1700000100",
                "X-RateLimit-Role": "pro"
            ], Data("{\"data\":[]}".utf8))
        }
        let result = try await client().request("GET", path: "/files")
        XCTAssertEqual(result.rateLimit.limit, 100)
        XCTAssertEqual(result.rateLimit.remaining, 99)
        XCTAssertEqual(result.rateLimit.role, "pro")
        XCTAssertEqual(result.rateLimit.reset, Date(timeIntervalSince1970: 1_700_000_100))
        XCTAssertEqual(result.headers["X-RateLimit-Limit"], "100")
    }

    func testUploadOmitsTypeForSTLIncludesTypeForOBJ() async throws {
        let stl = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".stl")
        let obj = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".obj")
        try Data("solid test\nendsolid test".utf8).write(to: stl)
        try Data("v 0 0 0\n".utf8).write(to: obj)
        defer {
            try? FileManager.default.removeItem(at: stl)
            try? FileManager.default.removeItem(at: obj)
        }

        var stlBodyType: Any?
        StubProtocol.handler = { request in
            switch request.url!.path {
            case "/v2/api/files/direct-upload":
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                stlBodyType = body["type"]
                return (200, [:], Data("{\"data\":{\"presignedUrl\":\"https://storage.example/model.stl\",\"filePlaceholder\":{\"id\":\"stl\"}}}".utf8))
            case "/model.stl":
                return (200, [:], Data())
            case "/v2/api/files/confirm-upload":
                return (200, [:], Data("{\"data\":{\"id\":\"stl\"}}".utf8))
            default:
                return (500, [:], Data())
            }
        }
        _ = try await client().upload(file: stl, name: "cube", platformId: "platform", ownerId: "", stage: { _ in })
        XCTAssertNil(stlBodyType)

        var objBodyType: Any?
        StubProtocol.handler = { request in
            switch request.url!.path {
            case "/v2/api/files/direct-upload":
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open(); defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                objBodyType = body["type"]
                return (200, [:], Data("{\"data\":{\"presignedUrl\":\"https://storage.example/model.obj\",\"filePlaceholder\":{\"id\":\"obj\"}}}".utf8))
            case "/model.obj":
                return (200, [:], Data())
            case "/v2/api/files/confirm-upload":
                return (200, [:], Data("{\"data\":{\"id\":\"obj\"}}".utf8))
            default:
                return (500, [:], Data())
            }
        }
        _ = try await client().upload(file: obj, name: "cube", platformId: "platform", ownerId: "", stage: { _ in })
        XCTAssertEqual(objBodyType as? String, "obj")
    }

    func testUploadUsesThreeStagesAndPreservesPlaceholder() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".stl")
        try Data("solid test\nendsolid test".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var paths: [String] = []
        StubProtocol.handler = { request in
            paths.append(request.url!.path)
            switch request.url!.path {
            case "/v2/api/files/direct-upload":
                XCTAssertEqual(request.httpMethod, "POST")
                return (200, [:], Data("{\"data\":{\"presignedUrl\":\"https://storage.example/model.stl?signature=test\",\"filePlaceholder\":{\"id\":\"abc\",\"futureField\":{\"preserve\":true}}}}".utf8))
            case "/model.stl":
                XCTAssertEqual(request.httpMethod, "PUT")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/octet-stream")
                return (200, [:], Data())
            case "/v2/api/files/confirm-upload":
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sl_test")
                var data = request.httpBody ?? Data()
                if let stream = request.httpBodyStream {
                    stream.open()
                    defer { stream.close() }
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while stream.hasBytesAvailable {
                        let count = stream.read(&buffer, maxLength: buffer.count)
                        if count <= 0 { break }
                        data.append(contentsOf: buffer.prefix(count))
                    }
                }
                let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                let placeholder = body["filePlaceholder"] as! [String: Any]
                XCTAssertEqual(placeholder["id"] as? String, "abc")
                XCTAssertEqual((placeholder["futureField"] as? [String: Bool])?["preserve"], true)
                return (200, [:], Data("{\"data\":{\"id\":\"abc\"}}".utf8))
            default:
                XCTFail("Unexpected request")
                return (500, [:], Data())
            }
        }
        let result = try await client().upload(file: file, name: "model.stl", platformId: "platform", ownerId: "", stage: { _ in })
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(paths, ["/v2/api/files/direct-upload", "/model.stl", "/v2/api/files/confirm-upload"])
    }

    func testUploadRejectsInsecurePresignedURLBeforeSendingFile() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        var count = 0
        StubProtocol.handler = { _ in
            count += 1
            return (200, [:], Data("{\"data\":{\"presignedUrl\":\"http://storage.example/model\",\"filePlaceholder\":{\"id\":\"abc\"}}}".utf8))
        }
        do {
            _ = try await client().upload(file: file, name: "model.stl", platformId: "platform", ownerId: "", stage: { _ in })
            XCTFail("Expected insecure URL rejection")
        } catch APIError.invalidResponse(let message) {
            // Still an invalid response (unknown to Import Orders' personalised uploads); a local file isn't told to
            // use a secure link.
            XCTAssertEqual(message, uploadLinkMissingMessage)
        }
        XCTAssertEqual(count, 1)
    }

    func testUserAgentGoesOnlyToSlantsAPIAndPlusIsEncoded() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let stages = UploadStageRecorder()
        StubProtocol.handler = { request in
            let agent = request.value(forHTTPHeaderField: "User-Agent") ?? ""
            switch request.url?.path {
            case "/v2/api/files/direct-upload":
                XCTAssertEqual(agent, slantStudioUserAgent)
                return (200, [:], Data("{\"data\":{\"presignedUrl\":\"https://storage.example/model.stl\",\"filePlaceholder\":{\"id\":\"abc\"}}}".utf8))
            case "/model.stl":
                XCTAssertNotEqual(agent, slantStudioUserAgent, "the storage PUT keeps URLSession's own User-Agent")
                XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
                return (200, [:], Data())
            case "/v2/api/files/confirm-upload":
                XCTAssertEqual(agent, slantStudioUserAgent)
                return (200, [:], Data("{\"data\":{\"publicFileServiceId\":\"f-1\"}}".utf8))
            case "/v2/api/orders":
                XCTAssertEqual(agent, slantStudioUserAgent)
                XCTAssertTrue(request.url?.absoluteString.contains("endDate=2026-10-29T00:00:00%2B10:00") == true,
                              request.url?.absoluteString ?? "")
                return (200, [:], Data("{\"data\":[]}".utf8))
            default:
                XCTFail("Unexpected request \(request.url?.absoluteString ?? "")")
                return (500, [:], Data())
            }
        }
        _ = try await client().upload(file: file, name: "model.stl", platformId: "platform", ownerId: "", stage: { stages.append($0) })
        XCTAssertEqual(stages.all, [.preparing, .uploading, .confirming])
        _ = try await client().request("GET", path: "/orders", query: ["endDate": "2026-10-29T00:00:00+10:00"])
    }

    func testStoragePUTFailureLeavesTheStageAtUploading() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        StubProtocol.handler = { request in
            if request.url?.path == "/v2/api/files/direct-upload" {
                return (200, [:], Data("{\"data\":{\"presignedUrl\":\"https://storage.example/model.stl\",\"filePlaceholder\":{\"id\":\"abc\"}}}".utf8))
            }
            XCTAssertEqual(request.url?.path, "/model.stl", "nothing is confirmed after a refused PUT")
            return (403, [:], Data("<Error><Code>AccessDenied</Code></Error>".utf8))
        }
        let stage = UploadStageBox()
        do {
            _ = try await client().upload(file: file, name: "model.stl", platformId: "platform", ownerId: "", stage: { stage.value = $0 })
            XCTFail("Expected the storage refusal")
        } catch {
            XCTAssertEqual(stage.value, .uploading)
            XCTAssertFalse(uploadOutcomeUnknown(stage: stage.value, error: error))
            XCTAssertTrue(uploadFailureMessage(stage: stage.value, error: error).contains("refused the upload link"))
        }
    }

    /// The pre-PUT guard: a placeholder naming a protected file stops the upload before any bytes are sent, with the
    /// stage still `.preparing` (nothing stored, not unknown), and an unprotected one goes ahead. Invented IDs only.
    func testPlaceholderGuardStopsBeforeThePUT() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("model".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let paths = PathRecorder()
        StubProtocol.handler = { request in
            paths.append(request.url?.path ?? "")
            switch request.url?.path {
            case "/v2/api/files/direct-upload":
                return (200, [:], Data(#"{"data":{"presignedUrl":"https://storage.example/model.stl","filePlaceholder":{"id":7,"publicFileServiceId":" file-kept "}}}"#.utf8))
            case "/model.stl":
                return (200, [:], Data())
            case "/v2/api/files/confirm-upload":
                return (200, [:], Data(#"{"data":{"publicFileServiceId":"file-kept"}}"#.utf8))
            default:
                XCTFail("Unexpected request \(request.url?.absoluteString ?? "")")
                return (500, [:], Data())
            }
        }
        let protected = ["file-kept": "Bracket"]
        let stage = UploadStageBox()
        do {
            _ = try await client().upload(file: file, name: "Bracket 2", platformId: "platform", ownerId: "", checkPlaceholder: { placeholder in
                if let hit = uploadPlaceholderProtectedFile(placeholder, protectedFiles: protected) {
                    throw UploadWouldOverwriteExistingFile(fileID: hit.id, fileName: hit.name)
                }
            }, stage: { stage.value = $0 })
            XCTFail("Expected the guard to stop the upload")
        } catch let error as UploadWouldOverwriteExistingFile {
            XCTAssertEqual(error, UploadWouldOverwriteExistingFile(fileID: "file-kept", fileName: "Bracket"))
            XCTAssertEqual(stage.value, .preparing)
            XCTAssertFalse(uploadOutcomeUnknown(stage: stage.value, error: error))
            XCTAssertFalse(uploadReplacementMayBePartial(stage: stage.value, replacingFileID: "file-other"))
            XCTAssertEqual(uploadFailureMessage(stage: stage.value, error: error),
                           "Nothing was uploaded: Slant would have saved this into your existing file “Bracket”. Choose another name and upload again.")
            XCTAssertEqual(batchPersonaliseUploadOutcome(error: error), .refused(batchPersonaliseWouldOverwriteMessage))
        }
        XCTAssertEqual(paths.all, ["/v2/api/files/direct-upload"], "no PUT and no confirm after the guard stops")

        // The file the seller chose to replace isn't protected, so the same reply goes ahead.
        paths.reset()
        _ = try await client().upload(file: file, name: "Bracket", platformId: "platform", ownerId: "", checkPlaceholder: { placeholder in
            if let hit = uploadPlaceholderProtectedFile(placeholder, protectedFiles: [:]) {
                throw UploadWouldOverwriteExistingFile(fileID: hit.id, fileName: hit.name)
            }
        }, stage: { _ in })
        XCTAssertEqual(paths.all, ["/v2/api/files/direct-upload", "/model.stl", "/v2/api/files/confirm-upload"])
    }

    func testModelDownloadStopsAtTheSizeCap() async throws {
        StubProtocol.handler = { _ in (200, [:], Data(repeating: 7, count: 4096)) }
        do {
            let url = try await client().downloadModel(from: URL(string: "https://storage.example/big.stl")!, maxBytes: 1000)
            try? FileManager.default.removeItem(at: url)
            XCTFail("Expected the size cap")
        } catch {
            XCTAssertEqual(error.localizedDescription, slantDownloadTooLargeMessage)
        }
        StubProtocol.handler = { _ in (200, ["Content-Length": "5000"], Data(repeating: 7, count: 5000)) }
        do {
            let url = try await client().downloadModel(from: URL(string: "https://storage.example/big.stl")!, maxBytes: 1000)
            try? FileManager.default.removeItem(at: url)
            XCTFail("Expected the Content-Length cap")
        } catch {
            XCTAssertEqual(error.localizedDescription, slantDownloadTooLargeMessage)
        }
        StubProtocol.handler = { _ in (200, [:], Data()) }
        do {
            let url = try await client().downloadModel(from: URL(string: "https://storage.example/empty.stl")!)
            try? FileManager.default.removeItem(at: url)
            XCTFail("Expected an empty download to be refused")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("empty"))
        }
        // Exactly at the cap is accepted, and spans the 1 MB write buffer.
        let payload = Data((0..<(1 << 20) + 17).map { UInt8($0 & 0xFF) })
        StubProtocol.handler = { _ in (200, [:], payload) }
        let url = try await client().downloadModel(from: URL(string: "https://storage.example/ok.stl")!, maxBytes: Int64(payload.count))
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(try Data(contentsOf: url), payload)
    }

    func testModelDownloadRefusalIsReported() async throws {
        StubProtocol.handler = { _ in (403, [:], Data("denied".utf8)) }
        do {
            _ = try await client().downloadModel(from: URL(string: "https://storage.example/model.stl")!)
            XCTFail("Expected the refusal")
        } catch APIError.http(let status, _, _, _) {
            XCTAssertEqual(status, 403)
        }
    }

    func testModelDownloadUsesStorageSessionWithoutBearerToken() async throws {
        let bytes = Data("solid test\nendsolid test".utf8)
        StubProtocol.handler = { request in
            XCTAssertEqual(request.url?.host, "storage.example")
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, ["Content-Type": "application/sla"], bytes)
        }
        let temporaryURL = try await client().downloadModel(from: URL(string: "https://storage.example/model.stl?signature=test")!)
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        XCTAssertEqual(try Data(contentsOf: temporaryURL), bytes)
    }

    func testModelDownloadRejectsInsecureURLBeforeRequest() async throws {
        StubProtocol.handler = { _ in
            XCTFail("Insecure download must not be sent")
            return (200, [:], Data())
        }
        do {
            _ = try await client().downloadModel(from: URL(string: "http://storage.example/model.stl")!)
            XCTFail("Expected insecure URL rejection")
        } catch APIError.invalidResponse(let message) {
            XCTAssertTrue(message.contains("HTTPS"))
        }
    }
}
