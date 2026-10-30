import XCTest
@testable import SlantStudio

/// A scripted network: each request takes the next reply in order. Records every request and download.
private final class ScriptedTransport: ImageTo3DTransport, @unchecked Sendable {
    enum Step {
        case reply(Int, String, [String: String])
        case fail(ImageTo3DError)
    }
    private let lock = NSLock()
    private var steps: [Step]
    private(set) var requests: [URLRequest] = []
    private(set) var downloads: [URL] = []
    var downloadError: Error?

    init(_ steps: [Step]) { self.steps = steps }

    func send(_ request: URLRequest) async throws -> ImageTo3DHTTPReply {
        lock.lock()
        requests.append(request)
        let step = steps.isEmpty ? nil : steps.removeFirst()
        lock.unlock()
        switch step {
        case .reply(let status, let body, let headers)?:
            return ImageTo3DHTTPReply(status: status, headers: headers, body: Data(body.utf8))
        case .fail(let error)?:
            throw error
        case nil:
            throw ImageTo3DError.transport("No scripted reply")
        }
    }

    func download(_ url: URL, into folder: URL, fileName: String, maxBytes: Int64) async throws -> URL {
        lock.lock()
        downloads.append(url)
        let error = downloadError
        lock.unlock()
        if let error { throw error }
        let file = folder.appendingPathComponent(fileName)
        try Data("solid test\nendsolid test\n".utf8).write(to: file)
        return file
    }

    var posts: [URLRequest] { requests.filter { $0.httpMethod == "POST" } }
    var paths: [String] { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }
}

/// A clock that moves forward only when the run sleeps.
private final class FakeTime: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_800_000_000)
    private(set) var sleeps: [TimeInterval] = []
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func sleep(_ seconds: TimeInterval) {
        lock.lock(); sleeps.append(seconds); current = current.addingTimeInterval(seconds); lock.unlock()
    }
}

final class ImageTo3DTests: XCTestCase {
    private let jpeg = ImageTo3DImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]), mediaType: "image/jpeg")
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private func json(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(imageTo3DTempFolderPrefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        folders.append(folder)
        return folder
    }

    private func body(_ request: URLRequest) -> [String: Any] {
        request.httpBody.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    }

    private func run(_ provider: ImageTo3DProvider, options: ImageTo3DOptions = ImageTo3DOptions(), time: FakeTime = FakeTime(),
                     timeout: TimeInterval = imageTo3DPollTimeout) async -> Result<ImageTo3DGeneratedModel, ImageTo3DStop> {
        await runImageTo3DGeneration(provider: provider, image: jpeg, options: options, timeout: timeout,
                                     sleep: { time.sleep($0) }, now: { time.now }, makeFolder: { try self.makeFolder() })
    }

    // MARK: Meshy fixtures (docs.meshy.ai/api/image-to-3d, analyze-printability, balance)

    static let meshySucceeded = """
    {"id":"018a210d-8ba4-705c-b111-1f1776f7f578","type":"image-to-3d",
     "model_urls":{"glb":"https://assets.meshy.ai/x/tasks/018a/output/model.glb?Expires=1","stl":"https://assets.meshy.ai/x/tasks/018a/output/model.stl?Expires=1&Signature=abc","usdz":"http://assets.meshy.ai/insecure.usdz"},
     "progress":100,"started_at":1692771667037,"created_at":1692771650657,"expires_at":1692771679037,"finished_at":1692771669037,
     "status":"SUCCEEDED","texture_urls":[],"preceding_tasks":0,"task_error":{"message":""},"consumed_credits":20}
    """

    func testMeshyCreateAndTaskParsing() {
        XCTAssertEqual(meshyCreatedTaskID(json(#"{"result":"018a210d-8ba4-705c-b111-1f1776f7f578"}"#)), "018a210d-8ba4-705c-b111-1f1776f7f578")
        XCTAssertNil(meshyCreatedTaskID(json(#"{"result":"../etc"}"#)))
        XCTAssertNil(meshyCreatedTaskID(json(#"{"message":"bad"}"#)))

        let done = meshyTaskStatus(json(Self.meshySucceeded))
        XCTAssertEqual(done?.state, .succeeded)
        XCTAssertEqual(done?.progress, 100)
        XCTAssertNil(done?.message)
        XCTAssertEqual(done?.modelURLs["stl"]?.host, "assets.meshy.ai")
        XCTAssertNil(done?.modelURLs["usdz"], "http links are dropped")
        XCTAssertEqual(done.flatMap { imageTo3DPrintableLink($0.modelURLs, preferred: .threeMF) }?.format, .stl)

        let running = meshyTaskStatus(json(#"{"id":"t1","status":"IN_PROGRESS","progress":45,"task_error":null}"#), suggestedDelay: 3)
        XCTAssertEqual(running?.state, .running)
        XCTAssertEqual(running?.progress, 45)
        XCTAssertEqual(running?.suggestedDelay, 3)
        XCTAssertEqual(meshyTaskStatus(json(#"{"id":"t1","status":"PENDING","progress":0}"#))?.state, .queued)
        XCTAssertEqual(meshyTaskStatus(json(#"{"id":"t1","status":"CANCELED"}"#))?.state, .cancelled)
        XCTAssertEqual(meshyTaskStatus(json(#"{"id":"t1","status":"NEW_THING"}"#))?.state, .other("NEW_THING"))
        XCTAssertEqual(meshyTaskStatus(json(#"{"id":"t1","status":"IN_PROGRESS","progress":250}"#))?.progress, 100)

        let failed = meshyTaskStatus(json(#"{"id":"t1","status":"FAILED","task_error":{"type":"invalid_input","message":"Image too complex","code":"image_too_complex"}}"#))
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.message, "Image too complex")
        let banned = meshyTaskStatus(json(#"{"id":"t1","status":"FAILED","task_error":{"message":"Blocked","code":"moderation_blocked"}}"#))
        XCTAssertEqual(banned?.state, .banned)
        XCTAssertNil(meshyTaskStatus(json(#"{"status":"SUCCEEDED"}"#)))
    }

    func testMeshyBalanceAndErrors() {
        let balance = meshyBalance(json(#"{"balance":1000,"monthly_credits":600,"permanent_credits":400,"monthly_resets_at":1793491200000}"#))
        XCTAssertEqual(balance?.credits, 1000)
        XCTAssertEqual(balance?.summary, "1000 Meshy credits available.")
        XCTAssertNil(meshyBalance(json(#"{"message":"nope"}"#)))

        XCTAssertEqual(meshyError(status: 402, body: Data(#"{"message":"Insufficient credits"}"#.utf8), retryAfter: nil, secrets: []),
                       .paymentRequired(service: .meshy, message: "Insufficient credits"))
        XCTAssertEqual(meshyError(status: 429, body: Data(), retryAfter: "12", secrets: []), .rateLimited(service: .meshy, retryAfter: 12))
        XCTAssertEqual(meshyError(status: 400, body: Data(#"{"message":"Invalid model file extension: .3dm"}"#.utf8), retryAfter: nil, secrets: []),
                       .http(service: .meshy, status: 400, code: nil, message: "Invalid model file extension: .3dm"))
    }

    func testMeshyAnalyzeReport() {
        let report = meshyPrintabilityReport(json("""
        {"id":"0193bfc5","type":"print-analyze","status":"SUCCEEDED","progress":100,"task_error":null,
         "printability":{"_version":"v1","status":"warning","issue_count":1,"error_count":0,"warning_count":1,
           "metrics":{"is_watertight":true,"volume":1.316,"non_manifold_edges":0,"degenerate_faces":43242,"holes":0},
           "intended_print":{"printer_type":"fdm","height_mm":100,"longest_side_mm":118,"wall_thickness_mm":1.0,"dimensions_mm":[118,72.41,99.87]},
           "thin_walls":{"thin_area_ratio":0.083,"has_thin_walls":true,"status":"error"},
           "evaluated_at":1700000001000},"consumed_credits":0}
        """))
        XCTAssertEqual(report?.verdict, .warning)
        XCTAssertEqual(report?.warningCount, 1)
        XCTAssertEqual(report?.isWatertight, true)
        XCTAssertEqual(report?.degenerateFaces, 43242)
        XCTAssertEqual(report?.hasThinWalls, true)
        XCTAssertEqual(report?.dimensionsMM, [118, 72.41, 99.87])
        XCTAssertEqual(report?.findings, ["43242 degenerate faces", "Thin walls thinner than 1.0 mm (8% of the surface)"])
        XCTAssertEqual(report?.summary, "Meshy found possible printability problems: 43242 degenerate faces, Thin walls thinner than 1.0 mm (8% of the surface).")

        let healthy = meshyPrintabilityReport(json(#"{"id":"a","status":"SUCCEEDED","printability":{"status":"healthy","metrics":{"is_watertight":true,"holes":0}}}"#))
        XCTAssertEqual(healthy?.summary, "Meshy found no printability problems.")
        XCTAssertEqual(meshyPrintabilityReport(json(#"{"id":"a","printability":{"status":"strange"}}"#))?.verdict, .unknown)
        XCTAssertNil(meshyPrintabilityReport(json(#"{"id":"a","status":"PENDING"}"#)))
    }

    func testMeshyRequestBodies() {
        let body = meshyImageTo3DBody(imageDataURI: "data:image/jpeg;base64,AA==", options: ImageTo3DOptions(targetTriangles: 50))
        XCTAssertEqual(body["should_texture"] as? Bool, false)
        XCTAssertEqual(body["should_remesh"] as? Bool, false, "not remeshed: Meshy keeps the detail it generates")
        XCTAssertNil(body["topology"])
        XCTAssertNil(body["target_polycount"])
        XCTAssertEqual(body["target_formats"] as? [String], ["stl"])
        XCTAssertEqual(body["ai_model"] as? String, meshyAIModel)
        XCTAssertEqual(body["auto_size"] as? Bool, true)
        XCTAssertEqual(body["origin_at"] as? String, "bottom")
        XCTAssertNil(body["enable_pbr"])

        let flat = meshyImageTo3DBody(imageDataURI: "x", options: ImageTo3DOptions(format: .threeMF, originAtBottom: false))
        XCTAssertEqual(flat["target_formats"] as? [String], ["3mf"])
        XCTAssertNil(flat["auto_size"])
        XCTAssertNil(flat["origin_at"])

        XCTAssertEqual(meshyImageDataURI(ImageTo3DImage(data: Data([1, 2, 3]), mediaType: "image/JPEG")), "data:image/jpeg;base64,AQID")

        XCTAssertEqual(meshyPrintabilityBody(inputTaskID: "t", longestSideMM: 118.04)["intended_print_longest_side_mm"] as? Double, 118)
        XCTAssertEqual(meshyPrintabilityBody(inputTaskID: "t", longestSideMM: 118)["printer_type"] as? String, "fdm")
        XCTAssertNil(meshyPrintabilityBody(inputTaskID: "t", longestSideMM: 5000)["intended_print_longest_side_mm"])
        XCTAssertNil(meshyPrintabilityBody(inputTaskID: "t", longestSideMM: .nan)["printer_type"])

        let convert = meshyConvertBody(inputTaskID: "r1", modelURL: nil, format: .stl)
        XCTAssertEqual(convert["input_task_id"] as? String, "r1")
        XCTAssertEqual(convert["target_formats"] as? [String], ["stl"])
        XCTAssertEqual(meshyConvertBody(inputTaskID: nil, modelURL: URL(string: "https://assets.meshy.ai/m.glb"), format: .threeMF)["model_url"] as? String,
                       "https://assets.meshy.ai/m.glb")
    }

    // MARK: Tripo fixtures (developers.tripo3d.ai/en/docs: files, task-query, models-convert, account, error-handling)

    func testTripoParsing() {
        XCTAssertEqual(tripoEnvelopeData(json(#"{"code":0,"data":{"file_token":"file_abc123"}}"#))?["file_token"] as? String, "file_abc123")
        XCTAssertNil(tripoEnvelopeData(json(#"{"code":2010,"data":{}}"#)))

        let success = tripoTaskStatus(json("""
        {"code":0,"data":{"task_id":"task_abc123","type":"text_to_model","status":"success","progress":100,
         "output":{"model_url":"https://cdn.tripo3d.ai/output/model.stl?sig=1","rendered_image_url":"https://cdn.tripo3d.ai/output/preview.png"},
         "credits_consumed":100.00,"created_at":"2026-04-28T12:00:00Z","completed_at":"2026-04-28T12:01:30Z"}}
        """))
        XCTAssertEqual(success?.taskID, "task_abc123")
        XCTAssertEqual(success?.state, .succeeded)
        XCTAssertEqual(success?.modelURLs["stl"]?.host, "cdn.tripo3d.ai")

        let noExtension = tripoTaskStatus(json(#"{"code":0,"data":{"task_id":"task_1","status":"success","output":{"model_url":"https://cdn.example.com/abc"}}}"#))
        XCTAssertNotNil(noExtension?.modelURLs["model"])
        XCTAssertEqual(tripoTaskStatus(json(#"{"code":0,"data":{"task_id":"task_1","status":"running","progress":40}}"#))?.state, .running)
        XCTAssertEqual(tripoTaskStatus(json(#"{"code":0,"data":{"task_id":"task_1","status":"queued"}}"#))?.state, .queued)
        XCTAssertEqual(tripoTaskStatus(json(#"{"code":0,"data":{"task_id":"task_1","status":"banned"}}"#))?.state, .banned)
        XCTAssertEqual(tripoTaskStatus(json(#"{"code":0,"data":{"task_id":"task_1","status":"expired"}}"#))?.state, .expired)
        XCTAssertEqual(tripoTaskStatus(json(#"{"code":0,"data":{"task_id":"task_1","status":"cancelled"}}"#))?.state, .cancelled)
        XCTAssertEqual(tripoTaskStatus(json(#"{"code":0,"data":{"task_id":"task_1","status":"unknown"}}"#))?.state, .other("unknown"))
        let failed = tripoTaskStatus(json(#"{"code":0,"data":{"task_id":"task_1","status":"failed","error_code":2018,"error_message":"Model too complex"}}"#))
        XCTAssertEqual(failed?.state, .failed)
        XCTAssertEqual(failed?.message, "Model too complex")
        XCTAssertNil(tripoTaskStatus(json(#"{"code":1000,"message":"Invalid API Key"}"#)))

        let balance = tripoBalance(json(#"{"code":0,"data":{"balance":10000.00,"frozen":200.50}}"#))
        XCTAssertEqual(balance?.credits, 10000)
        XCTAssertEqual(balance?.frozen, 200.5)
        XCTAssertEqual(balance?.summary, "10000 Tripo credits available (200.5 held for running tasks).")
    }

    func testTripoErrors() {
        let credits = Data(#"{"code":2010,"status":"error","message":"You don't have enough credit to create this task","suggestion":"Please purchase more credit","request_id":"req_abc123"}"#.utf8)
        XCTAssertEqual(tripoError(status: 403, body: credits, retryAfter: nil, secrets: []),
                       .paymentRequired(service: .tripo, message: "You don't have enough credit to create this task Please purchase more credit"))
        XCTAssertEqual(tripoError(status: 429, body: Data(#"{"code":2000,"message":"You have exceeded the limit of generation"}"#.utf8), retryAfter: "30", secrets: []),
                       .rateLimited(service: .tripo, retryAfter: 30))
        XCTAssertEqual(tripoError(status: 429, body: Data(#"{"code":1007}"#.utf8), retryAfter: nil, secrets: []), .rateLimited(service: .tripo, retryAfter: nil))
        if case .http(_, let status, let code, _) = tripoError(status: 401, body: Data(#"{"code":1000,"message":"Invalid API Key"}"#.utf8), retryAfter: nil, secrets: []) {
            XCTAssertEqual(status, 401); XCTAssertEqual(code, 1000)
        } else { XCTFail() }
        // A 200 carrying an error code is a definite refusal, never an unknown outcome.
        let refusal = tripoError(status: 200, body: Data(#"{"code":2008,"message":"Content policy violation"}"#.utf8), retryAfter: nil, secrets: [])
        XCTAssertEqual(refusal, .http(service: .tripo, status: 400, code: 2008, message: "Content policy violation"))
        XCTAssertFalse(imageTo3DCreateOutcomeUnknown(refusal))

        // Tripo's codes never turn a 5xx, 408, 409 or redirect into a definite refusal: a create stays unknown.
        for status in [500, 502, 503, 408, 409, 302] {
            for code in [2010, 2000, 1007, 1000, 2008] {
                let error = tripoError(status: status, body: Data(#"{"code":\#(code),"message":"m"}"#.utf8), retryAfter: "5", secrets: [])
                XCTAssertEqual(error, .http(service: .tripo, status: status, code: code, message: "m"), "\(status) \(code)")
                XCTAssertTrue(imageTo3DCreateOutcomeUnknown(error), "\(status) \(code)")
            }
        }
        XCTAssertEqual(tripoError(status: 429, body: Data(#"{"code":2010}"#.utf8), retryAfter: nil, secrets: []),
                       .paymentRequired(service: .tripo, message: ""), "a plain 4xx still reads Tripo's code")
    }

    func testTripoUnknownCreateIsNotTakenForARefusal() async {
        // A 503 whose body carries Tripo's "not enough credits" code may still have created the task.
        let transport = ScriptedTransport([
            .reply(200, #"{"code":0,"data":{"file_token":"file_1"}}"#, [:]),
            .reply(503, #"{"code":2010,"message":"Not enough credit"}"#, [:])
        ])
        let result = await TripoClient(apiKey: "tsk_secretkey1", transport: transport)
            .createGeneration(image: jpeg, options: ImageTo3DOptions())
        guard case .unknown(nil, .http(_, 503, 2010, _)) = result else { return XCTFail("\(result)") }
    }

    func testTripoRequestBodies() {
        let body = tripoImageToModelBody(fileToken: "file_abc", options: ImageTo3DOptions())
        XCTAssertEqual(body["input"] as? String, "file_abc")
        XCTAssertEqual(body["texture"] as? Bool, false)
        XCTAssertEqual(body["pbr"] as? Bool, false)
        XCTAssertEqual(body["face_limit"] as? Int, 20_000)
        XCTAssertEqual(body["model"] as? String, tripoModelVersion)
        XCTAssertNil(body["smart_low_poly"])

        let convert = tripoConvertBody(taskID: "task_1", options: ImageTo3DOptions(format: .threeMF))
        XCTAssertEqual(convert["input"] as? String, "task_1")
        XCTAssertEqual(convert["format"] as? String, "3MF")
        XCTAssertEqual(convert["pivot_to_center_bottom"] as? Bool, true)
        XCTAssertNil(tripoConvertBody(taskID: "task_1", options: ImageTo3DOptions(originAtBottom: false))["pivot_to_center_bottom"])

        let multipart = String(decoding: tripoUploadBody(image: jpeg, boundary: "B"), as: UTF8.self)
        XCTAssertTrue(multipart.hasPrefix("--B\r\nContent-Disposition: form-data; name=\"file\"; filename=\"photo.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"))
        XCTAssertTrue(multipart.hasSuffix("\r\n--B--\r\n"))

        XCTAssertEqual(TripoRegion.international.apiHost, "openapi.tripo3d.ai")
        XCTAssertEqual(TripoRegion.chinaMainland.apiHost, "openapi.tripo3d.com")
    }

    func testCostEstimates() {
        let transport = ScriptedTransport([])
        let meshy = MeshyClient(apiKey: "msy_testkey123", transport: transport).estimatedCost(for: ImageTo3DOptions())
        XCTAssertEqual(meshy.credits, 20)
        XCTAssertTrue(meshy.summary.contains("Approximate"))
        XCTAssertEqual(MeshyClient.repairCost.credits, 11)
        let tripo = TripoClient(apiKey: "tsk_testkey123", transport: transport)
        XCTAssertEqual(tripo.estimatedCost(for: ImageTo3DOptions()).credits, 30)
        XCTAssertEqual(tripo.estimatedCost(for: ImageTo3DOptions(originAtBottom: false)).credits, 25)
    }

    // MARK: Hosts and links

    func testDownloadLinkChecks() {
        XCTAssertNil(imageTo3DDownloadURLProblem(URL(string: "https://assets.meshy.ai/a/model.stl?Expires=1")!))
        for bad in ["http://assets.meshy.ai/model.stl", "https://user:pw@assets.meshy.ai/m.stl", "https://assets.meshy.ai/m.stl#x",
                    "https://127.0.0.1/m.stl", "https://[::1]/m.stl", "https://localhost/m.stl", "https://printer.local/m.stl",
                    "file:///tmp/m.stl", "ftp://example.com/m.stl"] {
            XCTAssertNotNil(imageTo3DDownloadURLProblem(URL(string: bad)!), bad)
        }
        let source = URL(string: "https://cdn.tripo3d.ai/a.stl")
        XCTAssertTrue(imageTo3DRedirectAllowed(from: source, to: URL(string: "https://d1.cloudfront.net/a.stl?sig=1")))
        XCTAssertFalse(imageTo3DRedirectAllowed(from: source, to: URL(string: "http://d1.cloudfront.net/a.stl")))
        XCTAssertFalse(imageTo3DRedirectAllowed(from: source, to: URL(string: "https://10.0.0.1/a.stl")))
        XCTAssertFalse(imageTo3DRedirectAllowed(from: URL(string: "http://cdn.example.com/a"), to: URL(string: "https://cdn.example.com/b")))
        XCTAssertFalse(imageTo3DRedirectAllowed(from: source, to: nil))

        XCTAssertTrue(imageTo3DDownloadLengthAllowed(-1))
        XCTAssertTrue(imageTo3DDownloadLengthAllowed(imageTo3DMaxDownloadBytes))
        XCTAssertFalse(imageTo3DDownloadLengthAllowed(imageTo3DMaxDownloadBytes + 1))
        XCTAssertEqual(imageTo3DMaxDownloadBytes, 128 * 1024 * 1024)

        XCTAssertEqual(imageTo3DModelURLs(["STL": "https://a.example.com/m.stl", "glb": "http://a.example.com/m.glb", "x": 5]).keys.sorted(), ["stl"])
    }

    func testAPIURLsStayOnKnownHosts() {
        XCTAssertEqual(imageTo3DAPIURL(host: "api.meshy.ai", path: "/openapi/v1/balance")?.absoluteString, "https://api.meshy.ai/openapi/v1/balance")
        XCTAssertEqual(imageTo3DAPIURL(host: "openapi.tripo3d.ai", path: "/v3/tasks/task_1")?.absoluteString, "https://openapi.tripo3d.ai/v3/tasks/task_1")
        XCTAssertNil(imageTo3DAPIURL(host: "evil.example.com", path: "/v3/tasks"))
        XCTAssertNil(imageTo3DAPIURL(host: "api.meshy.ai", path: "/openapi/../x"))
        XCTAssertNil(imageTo3DAPIURL(host: "api.meshy.ai", path: "/a?b=c"))
        XCTAssertNil(imageTo3DAPIURL(host: "api.meshy.ai", path: "relative"))

        XCTAssertTrue(imageTo3DTaskIDIsSafe("018a210d-8ba4-705c-b111-1f1776f7f578"))
        XCTAssertTrue(imageTo3DTaskIDIsSafe("task_abc123"))
        for bad in ["", "a/b", "..", "a b", "a?b", "é", String(repeating: "a", count: 129)] {
            XCTAssertFalse(imageTo3DTaskIDIsSafe(bad), bad)
        }
    }

    func testImageChecks() {
        XCTAssertNil(imageTo3DImageProblem(jpeg))
        XCTAssertNil(imageTo3DImageProblem(ImageTo3DImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0]), mediaType: "image/png")))
        XCTAssertNotNil(imageTo3DImageProblem(ImageTo3DImage(data: Data(), mediaType: "image/jpeg")))
        XCTAssertNotNil(imageTo3DImageProblem(ImageTo3DImage(data: Data([1, 2, 3]), mediaType: "image/jpeg")))
        XCTAssertNotNil(imageTo3DImageProblem(ImageTo3DImage(data: jpeg.data, mediaType: "image/heic")))
        XCTAssertNotNil(imageTo3DImageProblem(ImageTo3DImage(data: jpeg.data + Data(count: imageTo3DMaxImageBytes), mediaType: "image/jpeg")))
    }

    // MARK: Redaction and keys

    func testRedaction() {
        let text = "Bearer msy_ABCdef123 failed for tsk_zzz999 and sk-ant-api03-xyz; my-secret-key\nhttps://assets.meshy.ai/t/model.stl?Expires=1&Signature=abc"
        let redacted = imageTo3DRedacted(text, secrets: ["my-secret-key"])
        for leak in ["msy_ABCdef123", "tsk_zzz999", "sk-ant-api03", "my-secret-key", "Signature=abc", "\n"] {
            XCTAssertFalse(redacted.contains(leak), leak)
        }
        XCTAssertTrue(redacted.contains("https://assets.meshy.ai/t/model.stl?[redacted]"))
        XCTAssertLessThanOrEqual(imageTo3DRedacted(String(repeating: "x", count: 1000)).count, 241)
        XCTAssertEqual(imageTo3DServiceMessage(from: Data(#"{"message":"bad key msy_secret1"}"#.utf8), secrets: []), "bad key [redacted]")
        XCTAssertEqual(imageTo3DServiceMessage(from: Data("<html>oops</html>".utf8), secrets: []), "")
    }

    func testKeyChecksAndAdvice() {
        XCTAssertNotNil(imageTo3DKeyProblem("", service: .meshy))
        XCTAssertNotNil(imageTo3DKeyProblem("short", service: .meshy))
        XCTAssertNotNil(imageTo3DKeyProblem("msy_abc def ghi", service: .meshy))
        XCTAssertNotNil(imageTo3DKeyProblem(String(repeating: "a", count: 300), service: .tripo))
        XCTAssertNil(imageTo3DKeyProblem("  msy_abcdefgh123\n", service: .meshy))

        XCTAssertNil(imageTo3DKeyPrefixAdvice("msy_abcdefgh", service: .meshy))
        XCTAssertNotNil(imageTo3DKeyPrefixAdvice("abcdefgh", service: .meshy))
        XCTAssertNil(imageTo3DKeyPrefixAdvice("tsk_abcdefgh", service: .tripo))
        XCTAssertNil(imageTo3DKeyPrefixAdvice("sk-abcdefgh", service: .tripo), "Tripo's docs show both prefixes")
        XCTAssertEqual(imageTo3DKeyPrefixAdvice("msy_abcdefgh", service: .tripo), "This looks like a Meshy key. Choose Meshy above, or paste a Tripo key.")
        XCTAssertNotNil(imageTo3DKeyPrefixAdvice("sk-ant-api03-x", service: .meshy))
        XCTAssertEqual(ImageTo3DService.meshy.keychainAccount, "meshy-api-key")
        XCTAssertEqual(ImageTo3DService.tripo.keychainAccount, "tripo-api-key")
    }

    @MainActor func testConnectionPreferencesHoldNoSecrets() {
        let suite = testDefaultsSuiteName("ImageTo3DTests")
        let defaults = UserDefaults(suiteName: suite)!
        defer { removeTestDefaultsSuite(defaults, named: suite) }
        let connection = ImageTo3DConnection(defaults: defaults)
        XCTAssertEqual(connection.selectedService, .meshy)
        XCTAssertEqual(connection.tripoRegion, .international)
        connection.selectedService = .tripo
        connection.tripoRegion = .chinaMainland
        let reloaded = ImageTo3DConnection(defaults: defaults)
        XCTAssertEqual(reloaded.selectedService, .tripo)
        XCTAssertEqual(reloaded.tripoRegion, .chinaMainland)
        XCTAssertEqual(ImageTo3DService.meshy.sharingService, .meshy)
        XCTAssertEqual(ImageTo3DService.tripo.sharingService, .tripo)

        XCTAssertNil(reloaded.keyChangeBlockedReason)
        reloaded.beginWork()
        XCTAssertNotNil(reloaded.keyChangeBlockedReason)
        reloaded.endWork(); reloaded.endWork()
        XCTAssertEqual(reloaded.activeWork, 0)
        XCTAssertTrue(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("imageTo3D") }.allSatisfy {
            ["imageTo3DService", "imageTo3DTripoRegion", "imageTo3DSavedKeyServices"].contains($0)
        })
    }

    func testTempFolderIsCleanedAtLaunch() {
        XCTAssertTrue(isPersonalisationTempFolderName("\(imageTo3DTempFolderPrefix)\(UUID().uuidString)"))
        XCTAssertFalse(isPersonalisationTempFolderName("\(imageTo3DTempFolderPrefix)not-a-uuid"))
        XCTAssertEqual(personalisationTempFolderPrefixes[0], "SlantStudio-OpenSCAD-")
        XCTAssertEqual(personalisationTempFolderPrefixes[1], "SlantStudio-Personalised-")
    }

    // MARK: Retry-After and backoff

    func testRetryAfterParsing() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(imageTo3DRetryAfterSeconds("7", now: now), 7)
        XCTAssertEqual(imageTo3DRetryAfterSeconds(" 2.5 ", now: now), 2.5)
        XCTAssertEqual(imageTo3DRetryAfterSeconds("100000", now: now), imageTo3DMaxRetryAfter)
        XCTAssertNil(imageTo3DRetryAfterSeconds("-3", now: now))
        XCTAssertNil(imageTo3DRetryAfterSeconds("soon", now: now))
        XCTAssertNil(imageTo3DRetryAfterSeconds(nil, now: now))
        XCTAssertNil(imageTo3DRetryAfterSeconds("", now: now))
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        XCTAssertEqual(imageTo3DRetryAfterSeconds(formatter.string(from: now.addingTimeInterval(30)), now: now), 30)
        XCTAssertEqual(imageTo3DRetryAfterSeconds(formatter.string(from: now.addingTimeInterval(-30)), now: now), 0)

        XCTAssertEqual(imageTo3DPollDelay(consecutiveFailures: 0, retryAfter: nil), imageTo3DPollInterval)
        XCTAssertEqual(imageTo3DPollDelay(consecutiveFailures: 2, retryAfter: nil), imageTo3DPollInterval * 4)
        XCTAssertEqual(imageTo3DPollDelay(consecutiveFailures: 10, retryAfter: nil), 60)
        XCTAssertEqual(imageTo3DPollDelay(consecutiveFailures: 0, retryAfter: 45), 45)
        XCTAssertEqual(imageTo3DPollDelay(consecutiveFailures: 0, retryAfter: nil, suggested: 1), 2)
        XCTAssertEqual(imageTo3DPollDelay(consecutiveFailures: 0, retryAfter: nil, suggested: 500), 30)
    }

    // MARK: Unknown outcomes

    func testCreateOutcomeClassification() {
        for unknown: ImageTo3DError in [.transport("timed out"), .invalidResponse("x"), .responseTooLarge,
                                        .http(service: .meshy, status: 500, code: nil, message: ""),
                                        .http(service: .meshy, status: 503, code: nil, message: ""),
                                        .http(service: .tripo, status: 408, code: nil, message: ""),
                                        .http(service: .tripo, status: 409, code: nil, message: ""),
                                        .http(service: .tripo, status: 302, code: nil, message: "")] {
            XCTAssertTrue(imageTo3DCreateOutcomeUnknown(unknown), "\(unknown)")
        }
        for refused: ImageTo3DError in [.http(service: .meshy, status: 400, code: nil, message: ""),
                                        .http(service: .meshy, status: 401, code: nil, message: ""),
                                        .http(service: .tripo, status: 403, code: nil, message: ""),
                                        .rateLimited(service: .meshy, retryAfter: 3), .paymentRequired(service: .tripo, message: ""),
                                        .notConfigured(.meshy), .invalidInput("x")] {
            XCTAssertFalse(imageTo3DCreateOutcomeUnknown(refused), "\(refused)")
        }
        XCTAssertTrue(imageTo3DCreateOutcomeUnknown(CancellationError()), "cancelled mid-request may have been created")
        XCTAssertEqual(imageTo3DCreateResult(.success("t1"), knownTaskID: nil), .created(taskID: "t1"))
        XCTAssertEqual(imageTo3DCreateResult(.failure(ImageTo3DError.transport("x")), knownTaskID: "g1"),
                       .unknown(taskID: "g1", error: .transport("x")))
        XCTAssertEqual(imageTo3DCreateResult(.failure(ImageTo3DError.paymentRequired(service: .meshy, message: "")), knownTaskID: "g1"),
                       .notSent(.paymentRequired(service: .meshy, message: "")))

        XCTAssertTrue(imageTo3DReadIsTransient(ImageTo3DError.http(service: .meshy, status: 502, code: nil, message: "")))
        XCTAssertFalse(imageTo3DReadIsTransient(ImageTo3DError.http(service: .meshy, status: 404, code: nil, message: "")))
    }

    func testStopMessages() {
        let unknown = ImageTo3DStop(reason: .outcomeUnknown, stage: .sending, service: .meshy, taskID: nil, detail: "")
        XCTAssertTrue(unknown.creditsMayHaveBeenSpent)
        XCTAssertTrue(unknown.userMessage.contains("wasn’t sent again"))
        XCTAssertTrue(unknown.userMessage.contains("dashboard"))
        let refused = ImageTo3DStop(reason: .notSent, stage: .sending, service: .tripo, taskID: nil, detail: "No credits.")
        XCTAssertFalse(refused.creditsMayHaveBeenSpent)
        XCTAssertFalse(ImageTo3DStop(reason: .cancelled, stage: .sending, service: .tripo, taskID: nil, detail: "").creditsMayHaveBeenSpent)
        let timedOut = ImageTo3DStop(reason: .timedOut, stage: .generating, service: .tripo, taskID: "task_1", detail: "")
        XCTAssertEqual(timedOut.activityDetail, "Tripo: generating, timed out, task task_1")
    }

    // MARK: State machine

    func testTripoRunUploadsGeneratesConvertsAndDownloads() async throws {
        let transport = ScriptedTransport([
            .reply(200, #"{"code":0,"data":{"file_token":"file_abc123"}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen"}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen","status":"queued","progress":0}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen","status":"running","progress":50}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen","status":"success","progress":100,"output":{"model_url":"https://cdn.tripo3d.ai/out/model.glb"}}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_conv"}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_conv","status":"success","progress":100,"output":{"model_url":"https://cdn.tripo3d.ai/out/model.stl?sig=1"}}}"#, [:])
        ])
        let client = TripoClient(apiKey: "tsk_secretkey1", transport: transport)
        let result = await run(client)
        guard case .success(let model) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(model.format, .stl)
        XCTAssertEqual(model.sourceTaskID, "task_gen")
        XCTAssertEqual(model.conversionTaskID, "task_conv")
        XCTAssertTrue(FileManager.default.fileExists(atPath: model.fileURL.path))
        XCTAssertEqual(model.fileURL.lastPathComponent, "tripo-task_conv.stl")
        XCTAssertEqual(transport.paths, ["POST /v3/files", "POST /v3/generation/image-to-model", "GET /v3/tasks/task_gen",
                                         "GET /v3/tasks/task_gen", "GET /v3/tasks/task_gen", "POST /v3/models/convert", "GET /v3/tasks/task_conv"])
        XCTAssertTrue(transport.requests.allSatisfy { $0.url?.host == "openapi.tripo3d.ai" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer tsk_secretkey1" })
        XCTAssertEqual(transport.downloads.map(\.absoluteString), ["https://cdn.tripo3d.ai/out/model.stl?sig=1"])
        XCTAssertEqual(body(transport.requests[1])["input"] as? String, "file_abc123")
        XCTAssertEqual(body(transport.requests[5])["input"] as? String, "task_gen")
        XCTAssertEqual(transport.requests[0].value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary="), true)
    }

    func testMeshyRunHonoursRetryAfterAndDownloadsSTL() async throws {
        let time = FakeTime()
        let transport = ScriptedTransport([
            .reply(202, #"{"result":"018a"}"#, [:]),
            .reply(200, #"{"id":"018a","status":"IN_PROGRESS","progress":45}"#, ["Retry-After": "9"]),
            .reply(200, Self.meshySucceeded.replacingOccurrences(of: "018a210d-8ba4-705c-b111-1f1776f7f578\",\"type", with: "018a\",\"type"), [:])
        ])
        let result = await run(MeshyClient(apiKey: "msy_secretkey1", transport: transport), time: time)
        guard case .success(let model) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(model.format, .stl)
        XCTAssertNil(model.conversionTaskID)
        XCTAssertEqual(time.sleeps, [9])
        XCTAssertEqual(transport.paths, ["POST /openapi/v1/image-to-3d", "GET /openapi/v1/image-to-3d/018a", "GET /openapi/v1/image-to-3d/018a"])
        XCTAssertEqual(transport.downloads.first?.host, "assets.meshy.ai")
        XCTAssertEqual(body(transport.requests[0])["image_url"] as? String, meshyImageDataURI(jpeg))
    }

    func testCreateIsNeverRetriedAfterAnUnknownOutcome() async {
        for step: ScriptedTransport.Step in [.reply(500, #"{"message":"oops"}"#, [:]), .fail(.transport("The request timed out.")),
                                             .reply(202, #"{"unexpected":true}"#, [:]), .reply(504, "", [:])] {
            let transport = ScriptedTransport([step])
            let result = await run(MeshyClient(apiKey: "msy_secretkey1", transport: transport))
            guard case .failure(let stop) = result else { return XCTFail() }
            XCTAssertEqual(stop.reason, .outcomeUnknown)
            XCTAssertNil(stop.resumePoint)
            XCTAssertEqual(transport.requests.count, 1, "sent once")
            XCTAssertFalse(stop.userMessage.contains("msy_secretkey1"))
        }
    }

    func testRefusedCreateSpendsNothing() async {
        let transport = ScriptedTransport([.reply(402, #"{"message":"Free plan: Creating a task requires a paid plan"}"#, [:])])
        let result = await run(MeshyClient(apiKey: "msy_secretkey1", transport: transport))
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .notSent)
        XCTAssertFalse(stop.creditsMayHaveBeenSpent)
        XCTAssertTrue(stop.userMessage.contains("paid plan"))

        let tripo = ScriptedTransport([.fail(.transport("offline"))])
        let upload = await run(TripoClient(apiKey: "tsk_secretkey1", transport: tripo))
        guard case .failure(let uploadStop) = upload else { return XCTFail() }
        XCTAssertEqual(uploadStop.reason, .notSent, "a failed upload never created a task")
        XCTAssertEqual(tripo.requests.count, 1)

        let empty = ScriptedTransport([])
        let bad = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: empty),
                                               image: ImageTo3DImage(data: Data(), mediaType: "image/jpeg"), options: ImageTo3DOptions())
        guard case .failure(let badStop) = bad else { return XCTFail() }
        XCTAssertEqual(badStop.reason, .notSent)
        XCTAssertTrue(empty.requests.isEmpty)
    }

    func testPollingRetriesTransientReadsThenGivesUpWithAResumePoint() async {
        let time = FakeTime()
        var steps: [ScriptedTransport.Step] = [.reply(202, #"{"result":"t1"}"#, [:]),
                                               .reply(503, "", [:]), .reply(200, #"{"id":"t1","status":"PENDING"}"#, [:])]
        steps += Array(repeating: .fail(.transport("lost")), count: imageTo3DMaxConsecutivePollFailures)
        let transport = ScriptedTransport(steps)
        let result = await run(MeshyClient(apiKey: "msy_secretkey1", transport: transport), time: time)
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .statusUnreadable)
        XCTAssertEqual(stop.resumePoint, ImageTo3DResumePoint(sourceTaskID: "t1", sourceKind: .generation, conversionTaskID: nil))
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertEqual(time.sleeps.first, imageTo3DPollInterval * 2, "backs off after a failure")

        let fatal = ScriptedTransport([.reply(202, #"{"result":"t1"}"#, [:]), .reply(401, #"{"message":"bad"}"#, [:])])
        let stopped = await run(MeshyClient(apiKey: "msy_secretkey1", transport: fatal))
        guard case .failure(let fatalStop) = stopped else { return XCTFail() }
        XCTAssertEqual(fatalStop.reason, .statusUnreadable)
        XCTAssertEqual(fatal.requests.count, 2, "a 401 read isn't repeated")
    }

    func testPolling429WaitsForRetryAfter() async {
        let time = FakeTime()
        let transport = ScriptedTransport([
            .reply(202, #"{"result":"t1"}"#, [:]),
            .reply(429, #"{"message":"Rate limit exceeded"}"#, ["Retry-After": "17"]),
            .reply(200, #"{"id":"t1","status":"FAILED","task_error":{"message":"Image too complex"}}"#, [:])
        ])
        let result = await run(MeshyClient(apiKey: "msy_secretkey1", transport: transport), time: time)
        XCTAssertEqual(time.sleeps, [17])
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .taskEnded(.failed))
        XCTAssertEqual(stop.detail, "Image too complex")
        XCTAssertNil(stop.resumePoint)
        XCTAssertTrue(stop.userMessage.contains("Image too complex"))
    }

    func testPollingStopsAtTheOverallLimit() async {
        let time = FakeTime()
        var steps: [ScriptedTransport.Step] = [.reply(202, #"{"result":"t1"}"#, [:])]
        steps += Array(repeating: .reply(200, #"{"id":"t1","status":"IN_PROGRESS","progress":10}"#, [:]), count: 400)
        let transport = ScriptedTransport(steps)
        let result = await run(MeshyClient(apiKey: "msy_secretkey1", transport: transport), time: time, timeout: 60)
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .timedOut)
        XCTAssertNotNil(stop.resumePoint)
        XCTAssertLessThanOrEqual(time.sleeps.reduce(0, +), 60)
        XCTAssertEqual(transport.posts.count, 1)
    }

    func testCancellingWhileWaitingKeepsAResumePoint() async {
        let transport = ScriptedTransport([.reply(202, #"{"result":"t1"}"#, [:]), .reply(200, #"{"id":"t1","status":"PENDING"}"#, [:])])
        let result = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), image: jpeg,
                                                  options: ImageTo3DOptions(), sleep: { _ in throw CancellationError() },
                                                  makeFolder: { try self.makeFolder() })
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .cancelled)
        XCTAssertEqual(stop.resumePoint?.sourceTaskID, "t1")
        XCTAssertTrue(stop.creditsMayHaveBeenSpent)
    }

    func testUnknownConversionIsNotResent() async {
        let transport = ScriptedTransport([
            .reply(200, #"{"code":0,"data":{"file_token":"file_1"}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen"}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen","status":"success","output":{"model_url":"https://cdn.tripo3d.ai/m.glb"}}}"#, [:]),
            .reply(502, "", [:])
        ])
        let result = await run(TripoClient(apiKey: "tsk_secretkey1", transport: transport))
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .outcomeUnknown)
        XCTAssertEqual(stop.stage, .converting)
        XCTAssertEqual(stop.taskID, "task_gen")
        XCTAssertNil(stop.resumePoint, "carrying on could convert (and charge) twice")
        XCTAssertEqual(transport.posts.count, 3)
    }

    func testRefusedConversionCanCarryOnLater() async {
        let transport = ScriptedTransport([
            .reply(200, #"{"code":0,"data":{"file_token":"file_1"}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen"}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen","status":"success","output":{"model_url":"https://cdn.tripo3d.ai/m.glb"}}}"#, [:]),
            .reply(403, #"{"code":2010,"message":"You don't have enough credit to create this task"}"#, [:])
        ])
        let client = TripoClient(apiKey: "tsk_secretkey1", transport: transport)
        let result = await run(client)
        guard case .failure(let stop) = result, let point = stop.resumePoint else { return XCTFail() }
        XCTAssertEqual(stop.reason, .conversionRefused)
        XCTAssertEqual(point, ImageTo3DResumePoint(sourceTaskID: "task_gen", sourceKind: .generation, conversionTaskID: nil))

        let later = ScriptedTransport([
            .reply(200, #"{"code":0,"data":{"task_id":"task_gen","status":"success","output":{"model_url":"https://cdn.tripo3d.ai/m.glb"}}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_conv"}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_conv","status":"success","output":{"model_url":"https://cdn.tripo3d.ai/m.3mf"}}}"#, [:])
        ])
        let time = FakeTime()
        let resumed = await resumeImageTo3DGeneration(provider: TripoClient(apiKey: "tsk_secretkey1", transport: later), from: point,
                                                      options: ImageTo3DOptions(), sleep: { time.sleep($0) }, now: { time.now },
                                                      makeFolder: { try self.makeFolder() })
        guard case .success(let model) = resumed else { return XCTFail("\(resumed)") }
        XCTAssertEqual(model.format, .threeMF, "the link's own extension wins")
        XCTAssertEqual(later.posts.count, 1)
    }

    func testResumingAKnownConversionSendsNoCreate() async {
        let transport = ScriptedTransport([
            .reply(200, #"{"code":0,"data":{"task_id":"task_conv","status":"running","progress":80}}"#, [:]),
            .reply(200, #"{"code":0,"data":{"task_id":"task_conv","status":"success","output":{"model_url":"https://cdn.tripo3d.ai/m.stl"}}}"#, [:])
        ])
        let time = FakeTime()
        let result = await resumeImageTo3DGeneration(provider: TripoClient(apiKey: "tsk_secretkey1", transport: transport),
                                                     from: ImageTo3DResumePoint(sourceTaskID: "task_gen", sourceKind: .generation, conversionTaskID: "task_conv"),
                                                     options: ImageTo3DOptions(), sleep: { time.sleep($0) }, now: { time.now },
                                                     makeFolder: { try self.makeFolder() })
        guard case .success(let model) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(model.conversionTaskID, "task_conv")
        XCTAssertTrue(transport.posts.isEmpty)
    }

    func testAPaidModelWithoutALinkCanBeFetchedAgain() async {
        // A finished conversion with an unusual link is accepted; one with none stops with a resume point, never a create.
        let transport = ScriptedTransport([
            .reply(200, #"{"code":0,"data":{"task_id":"task_conv","status":"success","output":{}}}"#, [:])
        ])
        let point = ImageTo3DResumePoint(sourceTaskID: "task_gen", sourceKind: .generation, conversionTaskID: "task_conv")
        let result = await resumeImageTo3DGeneration(provider: TripoClient(apiKey: "tsk_secretkey1", transport: transport), from: point,
                                                     options: ImageTo3DOptions(), sleep: { _ in }, makeFolder: { try self.makeFolder() })
        guard case .failure(let stop) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(stop.reason, .downloadFailed)
        XCTAssertEqual(stop.resumePoint, point)
        XCTAssertTrue(transport.posts.isEmpty)
    }

    func testFailedDownloadRemovesItsFolderAndCanBeTriedAgain() async {
        let transport = ScriptedTransport([
            .reply(202, #"{"result":"t1"}"#, [:]),
            .reply(200, #"{"id":"t1","status":"SUCCEEDED","model_urls":{"stl":"https://assets.meshy.ai/m.stl"}}"#, [:])
        ])
        transport.downloadError = ImageTo3DError.downloadRefused("The model link has expired or was removed (HTTP 403).")
        var made: URL?
        let result = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), image: jpeg,
                                                  options: ImageTo3DOptions(), sleep: { _ in },
                                                  makeFolder: { let folder = try self.makeFolder(); made = folder; return folder })
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .downloadFailed)
        XCTAssertEqual(stop.resumePoint, ImageTo3DResumePoint(sourceTaskID: "t1", sourceKind: .generation, conversionTaskID: nil))
        XCTAssertTrue(stop.userMessage.contains("expired"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: made?.path ?? "/"))
    }

    func testMeshyGLBOnlyResultIsConvertedAndARefusalFallsBackToItsLinkOnce() async {
        let transport = ScriptedTransport([
            .reply(202, #"{"result":"t1"}"#, [:]),
            .reply(200, #"{"id":"t1","status":"SUCCEEDED","model_urls":{"glb":"https://assets.meshy.ai/m.glb"}}"#, [:]),
            .reply(400, #"{"message":"Invalid input task"}"#, [:]),
            .reply(400, #"{"message":"still no"}"#, [:])
        ])
        // Meshy converts a GLB-only result (as after a repair); a refused conversion stops without an unknown outcome.
        let result = await run(MeshyClient(apiKey: "msy_secretkey1", transport: transport))
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .conversionRefused)
        XCTAssertEqual(transport.paths.suffix(2), ["POST /openapi/v1/convert", "POST /openapi/v1/convert"])
        XCTAssertEqual(body(transport.requests[2])["input_task_id"] as? String, "t1")
        XCTAssertEqual(body(transport.requests[3])["model_url"] as? String, "https://assets.meshy.ai/m.glb")
    }

    func testMeshyRepairConvertsItsGLB() async {
        let time = FakeTime()
        let transport = ScriptedTransport([
            .reply(202, #"{"result":"rep1"}"#, [:]),
            .reply(200, #"{"id":"rep1","type":"print-repair","status":"SUCCEEDED","progress":100,"task_error":null,"model_urls":{"glb":"https://assets.meshy.ai/r.glb?Expires=1"},"consumed_credits":10}"#, [:]),
            .reply(202, #"{"result":"conv1"}"#, [:]),
            .reply(200, #"{"id":"conv1","type":"convert","model_urls":{"stl":"https://assets.meshy.ai/r.stl?Expires=1"},"progress":100,"status":"SUCCEEDED","task_error":null,"consumed_credits":1}"#, [:])
        ])
        let client = MeshyClient(apiKey: "msy_secretkey1", transport: transport)
        let result = await runMeshyRepair(client: client, ofTask: "gen1", longestSideMM: 80, options: ImageTo3DOptions(),
                                          sleep: { time.sleep($0) }, now: { time.now }, makeFolder: { try self.makeFolder() })
        guard case .success(let model) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(model.sourceKind, .repair)
        XCTAssertEqual(model.sourceTaskID, "rep1")
        XCTAssertEqual(model.conversionTaskID, "conv1")
        XCTAssertEqual(transport.paths, ["POST /openapi/v1/print/repair", "GET /openapi/v1/print/repair/rep1",
                                         "POST /openapi/v1/convert", "GET /openapi/v1/convert/conv1"])
        XCTAssertEqual(body(transport.requests[0])["input_task_id"] as? String, "gen1")
        XCTAssertEqual(body(transport.requests[0])["intended_print_longest_side_mm"] as? Double, 80)
    }

    func testMeshyAnalyzeWaitsForItsResult() async throws {
        let time = FakeTime()
        let transport = ScriptedTransport([
            .reply(202, #"{"result":"an1"}"#, [:]),
            .reply(200, #"{"id":"an1","type":"print-analyze","status":"IN_PROGRESS","progress":50}"#, ["Retry-After": "3"]),
            .reply(500, "", [:]),
            .reply(200, #"{"id":"an1","type":"print-analyze","status":"SUCCEEDED","progress":100,"printability":{"status":"error","error_count":1,"metrics":{"is_watertight":false,"holes":12,"non_manifold_edges":60,"degenerate_faces":0}},"consumed_credits":0}"#, [:])
        ])
        let report = try await MeshyClient(apiKey: "msy_secretkey1", transport: transport)
            .analyzePrintability(ofTask: "gen1", longestSideMM: nil, sleep: { time.sleep($0) }, now: { time.now })
        XCTAssertEqual(report.verdict, .error)
        XCTAssertEqual(report.findings, ["Not watertight", "12 holes", "60 non-manifold edges"])
        XCTAssertEqual(transport.posts.count, 1)
        XCTAssertEqual(time.sleeps.first, 3)
        XCTAssertNil(body(transport.requests[0])["printer_type"])

        let failing = ScriptedTransport([.reply(202, #"{"result":"an2"}"#, [:]),
                                         .reply(200, #"{"id":"an2","status":"FAILED","task_error":{"message":"Bad input"}}"#, [:])])
        do {
            _ = try await MeshyClient(apiKey: "msy_secretkey1", transport: failing)
                .analyzePrintability(ofTask: "gen1", longestSideMM: 50, sleep: { time.sleep($0) }, now: { time.now })
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(failing.requests.count, 2, "a failed analysis isn't read again")
        }
    }

    func testBalanceReads() async throws {
        let meshy = ScriptedTransport([.reply(200, #"{"balance":42}"#, [:])])
        let meshyBalance = try await MeshyClient(apiKey: "msy_secretkey1", transport: meshy).readBalance()
        XCTAssertEqual(meshyBalance.credits, 42)
        XCTAssertEqual(meshy.paths, ["GET /openapi/v1/balance"])

        let tripo = ScriptedTransport([.reply(200, #"{"code":0,"data":{"balance":12.5,"frozen":0}}"#, [:])])
        let tripoBalance = try await TripoClient(apiKey: "tsk_secretkey1", region: .chinaMainland, transport: tripo).readBalance()
        XCTAssertEqual(tripoBalance.summary, "12.5 Tripo credits available.")
        XCTAssertEqual(tripo.requests.first?.url?.absoluteString, "https://openapi.tripo3d.com/v3/account/balance")

        let refused = ScriptedTransport([.reply(401, #"{"code":1000,"message":"Invalid API Key tsk_secretkey1"}"#, [:])])
        do {
            _ = try await TripoClient(apiKey: "tsk_secretkey1", transport: refused).readBalance()
            XCTFail("expected a failure")
        } catch let error as ImageTo3DError {
            XCTAssertFalse(error.userMessage.contains("tsk_secretkey1"))
            XCTAssertFalse(error.activityDetail.contains("tsk_secretkey1"))
            XCTAssertTrue(error.userMessage.contains("rejected the API key"))
        }

        let empty = ScriptedTransport([])
        do {
            _ = try await MeshyClient(apiKey: "", transport: empty).readBalance()
            XCTFail("expected a failure")
        } catch {
            XCTAssertEqual(error as? ImageTo3DError, .notConfigured(.meshy))
            XCTAssertTrue(empty.requests.isEmpty)
        }
    }
}
