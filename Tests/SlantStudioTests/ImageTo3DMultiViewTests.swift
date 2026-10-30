import XCTest
@testable import SlantStudio

/// Each request takes the next scripted reply; records every request. Never touches the network.
private final class MultiViewTransport: ImageTo3DTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private var sent: [URLRequest] = []
    var downloadError: Error?

    init(_ replies: [(Int, String)]) { self.replies = replies }

    var requests: [URLRequest] { lock.withLock { sent } }
    var paths: [String] { requests.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" } }

    func send(_ request: URLRequest) async throws -> ImageTo3DHTTPReply {
        let next: (Int, String)? = lock.withLock {
            sent.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let next else { throw ImageTo3DError.transport("No scripted reply") }
        return ImageTo3DHTTPReply(status: next.0, headers: [:], body: Data(next.1.utf8))
    }

    func download(_ url: URL, into folder: URL, fileName: String, maxBytes: Int64) async throws -> URL {
        if let downloadError { throw downloadError }
        let file = folder.appendingPathComponent(fileName)
        try Data("solid test\nendsolid test\n".utf8).write(to: file)
        return file
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}

/// Multiple photos, Meshy's and Tripo's new options, routing, resume and cost (round 8). Stubbed transports only.
final class ImageTo3DMultiViewTests: XCTestCase {
    private let jpeg = ImageTo3DImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]), mediaType: "image/jpeg")
    private let png = ImageTo3DImage(data: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 9]), mediaType: "image/png")
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
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

    private func views(_ list: [ImageTo3DPhotoView]) -> [ImageTo3DViewImage] {
        list.map { ImageTo3DViewImage(view: $0, image: $0 == .front ? png : jpeg) }
    }

    // MARK: Photos

    func testViewChecksAndOrder() {
        XCTAssertEqual(ImageTo3DPhotoView.allCases.map(\.rawValue), ["front", "left", "back", "right"], "Tripo's keys, in slot order")
        XCTAssertEqual(ImageTo3DPhotoView.allCases.map(\.title), ["Front", "Left side", "Back", "Right side"])
        XCTAssertEqual(imageTo3DViewsProblem([]), "Choose a photo of the object.")
        XCTAssertEqual(imageTo3DViewsProblem(views([.back, .left])), "Add a front photo: both services need the front view.")
        XCTAssertEqual(imageTo3DViewsProblem(views([.front, .front])), "Use one photo for the front view.")
        XCTAssertNotNil(imageTo3DViewsProblem(views([.front, .left, .back, .right, .back])), "at most four")
        XCTAssertNil(imageTo3DViewsProblem(views([.front])))
        XCTAssertNil(imageTo3DViewsProblem(views([.right, .front, .back, .left])))
        let bad = [ImageTo3DViewImage(view: .front, image: jpeg), ImageTo3DViewImage(view: .back, image: ImageTo3DImage(data: Data([1, 2]), mediaType: "image/jpeg"))]
        XCTAssertEqual(imageTo3DViewsProblem(bad), "Back photo: The photo isn’t a JPEG image.")
        XCTAssertEqual(imageTo3DOrderedViews(views([.right, .back, .front])).map(\.view), [.front, .back, .right])
        XCTAssertEqual(ImageTo3DTaskKind.generation(photoCount: 1), .generation)
        XCTAssertEqual(ImageTo3DTaskKind.generation(photoCount: 3), .multiImageGeneration)
        XCTAssertTrue(ImageTo3DTaskKind.multiImageGeneration.isGeneration)
        XCTAssertFalse(ImageTo3DTaskKind.conversion.isGeneration)
    }

    // MARK: Meshy

    func testMeshyBodiesAskForNoRemeshAndOnlyTickedExtras() {
        let plain = meshyImageTo3DBody(imageDataURI: "data:image/jpeg;base64,AA==", options: ImageTo3DOptions(targetTriangles: 100_000))
        XCTAssertEqual(plain["should_remesh"] as? Bool, false, "Meshy: leaving it off gives the highest-quality model")
        XCTAssertNil(plain["topology"])
        XCTAssertNil(plain["target_polycount"])
        XCTAssertEqual(plain["image_enhancement"] as? Bool, false, "Meshy redraws the photo unless told not to; never sent true")
        XCTAssertNil(plain["geometry_resolution"])
        XCTAssertNil(plain["symmetry_mode"], "deprecated")
        XCTAssertEqual(plain["should_texture"] as? Bool, false)
        XCTAssertEqual(plain["ai_model"] as? String, "meshy-7.1")
        XCTAssertNil(plain["image_urls"])

        let extras = meshyImageTo3DBody(imageDataURI: "x", options: ImageTo3DOptions(higherDetail: true))
        XCTAssertEqual(extras["image_enhancement"] as? Bool, false)
        XCTAssertEqual(extras["geometry_resolution"] as? String, "2k", "never 4k: the same price, and a larger model of undocumented size")

        let multi = meshyMultiImageTo3DBody(imageDataURIs: ["data:image/png;base64,AQ==", "data:image/jpeg;base64,Ag=="],
                                            options: ImageTo3DOptions(higherDetail: true))
        XCTAssertEqual(multi["image_urls"] as? [String], ["data:image/png;base64,AQ==", "data:image/jpeg;base64,Ag=="])
        XCTAssertEqual(multi["geometry_resolution"] as? String, "2k", "Multi-Image to 3D accepts only 2k")
        XCTAssertEqual(multi["should_remesh"] as? Bool, false)
        XCTAssertEqual(multi["image_enhancement"] as? Bool, false)
        XCTAssertNil(multi["image_url"])
        XCTAssertNil(multi["target_polycount"])
    }

    func testMeshyRoutesByPhotoCountAndPutsTheFrontFirst() async throws {
        // One photo: Image to 3D.
        let single = MultiViewTransport([(202, #"{"result":"s1"}"#)])
        let one = await MeshyClient(apiKey: "msy_secretkey1", transport: single)
            .createGeneration(views: views([.front]), options: ImageTo3DOptions(), proceed: { true })
        XCTAssertEqual(one, .created(taskID: "s1"))
        XCTAssertEqual(single.paths, ["POST /openapi/v1/image-to-3d"])
        XCTAssertEqual(body(single.requests[0])["image_url"] as? String, meshyImageDataURI(png))

        // Three photos, given out of order: Multi-Image to 3D, front first, then slot order; then its own read path.
        let transport = MultiViewTransport([
            (202, #"{"result":"m1"}"#),
            (200, #"{"id":"m1","status":"IN_PROGRESS","progress":30}"#),
            (200, #"{"id":"m1","status":"SUCCEEDED","progress":100,"model_urls":{"stl":"https://assets.meshy.ai/m1/model.stl?Expires=1"}}"#)
        ])
        let result = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport),
                                                  views: views([.right, .front, .back]), options: ImageTo3DOptions(),
                                                  sleep: { _ in }, makeFolder: { try self.makeFolder() })
        guard case .success(let model) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(model.sourceKind, .multiImageGeneration)
        XCTAssertEqual(transport.paths, ["POST /openapi/v1/multi-image-to-3d", "GET /openapi/v1/multi-image-to-3d/m1",
                                         "GET /openapi/v1/multi-image-to-3d/m1"])
        let sent = body(transport.requests[0])
        XCTAssertEqual(sent["image_urls"] as? [String], [meshyImageDataURI(png), meshyImageDataURI(jpeg), meshyImageDataURI(jpeg)])
        XCTAssertTrue((sent["image_urls"] as? [String])?.first?.hasPrefix("data:image/png;base64,") == true, "the PNG keeps its media type")
        XCTAssertEqual(sent["image_enhancement"] as? Bool, false)
    }

    func testKeepWaitingOnAMultiImageTaskReadsItsOwnEndpoint() async {
        let transport = MultiViewTransport([
            (200, #"{"id":"m1","status":"SUCCEEDED","progress":100,"model_urls":{"stl":"https://assets.meshy.ai/m1/model.stl"}}"#)
        ])
        let point = ImageTo3DResumePoint(sourceTaskID: "m1", sourceKind: .multiImageGeneration, conversionTaskID: nil)
        let result = await resumeImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), from: point,
                                                     options: ImageTo3DOptions(), sleep: { _ in }, makeFolder: { try self.makeFolder() })
        guard case .success(let model) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(model.sourceKind, .multiImageGeneration)
        XCTAssertEqual(transport.paths, ["GET /openapi/v1/multi-image-to-3d/m1"], "nothing is created again")
        XCTAssertEqual(MeshyClient.readPath(.multiImageGeneration), "/openapi/v1/multi-image-to-3d")
        XCTAssertEqual(MeshyClient.readPath(.generation), "/openapi/v1/image-to-3d")
    }

    func testStopsCarryTheMultiImageKind() async {
        // A read that can't be made sense of five times over: Keep Waiting resumes the multi-image task.
        let transport = MultiViewTransport([(202, #"{"result":"m1"}"#)] + Array(repeating: (503, "{}"), count: 5))
        let result = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport),
                                                  views: views([.front, .back]), options: ImageTo3DOptions(),
                                                  sleep: { _ in }, makeFolder: { try self.makeFolder() })
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .statusUnreadable)
        XCTAssertEqual(stop.resumePoint, ImageTo3DResumePoint(sourceTaskID: "m1", sourceKind: .multiImageGeneration, conversionTaskID: nil))
        XCTAssertEqual(stop.requestKind, .multiImageGeneration)

        // An unknown create has no resume point, but still says which kind of request it was.
        let unknown = MultiViewTransport([(504, "")])
        let lost = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: unknown),
                                                views: views([.front, .left]), options: ImageTo3DOptions(), sleep: { _ in })
        guard case .failure(let lostStop) = lost else { return XCTFail() }
        XCTAssertEqual(lostStop.reason, .outcomeUnknown)
        XCTAssertNil(lostStop.resumePoint)
        XCTAssertEqual(lostStop.requestKind, .multiImageGeneration)
        XCTAssertEqual(unknown.requests.count, 1, "sent once")
    }

    @MainActor func testUnconfirmedRecordsCarryTheKind() throws {
        let suite = "SlantStudioTests.r8.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = ImageTo3DConnection(defaults: defaults)
        let unknown = ImageTo3DStop(reason: .outcomeUnknown, stage: .sending, service: .meshy, taskID: nil, detail: "",
                                    requestKind: .multiImageGeneration)
        connection.rememberUnconfirmed(unknown, at: Date(timeIntervalSince1970: 0))
        let waiting = ImageTo3DStop(reason: .timedOut, stage: .generating, service: .tripo, taskID: "t2", detail: "",
                                    resumePoint: ImageTo3DResumePoint(sourceTaskID: "t2", sourceKind: .multiImageGeneration, conversionTaskID: nil))
        connection.rememberUnconfirmed(waiting, at: Date(timeIntervalSince1970: 0))
        let single = ImageTo3DStop(reason: .timedOut, stage: .generating, service: .meshy, taskID: "s3", detail: "",
                                   resumePoint: ImageTo3DResumePoint(sourceTaskID: "s3", sourceKind: .generation, conversionTaskID: nil))
        connection.rememberUnconfirmed(single, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(connection.unconfirmedRequests.map(\.sourceKind), [.multiImageGeneration, .multiImageGeneration, .generation])
        let labels = connection.unconfirmedRequests.map { imageTo3DUnconfirmedLabel($0, timeText: { _ in "14:32" }) }
        XCTAssertEqual(labels, ["Meshy at 14:32 (multi-image)", "Tripo at 14:32 (multi-image task t2)", "Meshy at 14:32 (task s3)"])
        XCTAssertNil(defaults.dictionaryRepresentation().keys.first { $0.contains("nconfirmed") }, "memory only")
    }

    // MARK: Tripo

    func testTripoMultiviewUploadsEveryPhotoBeforeOneCreate() async {
        let transport = MultiViewTransport([
            (200, #"{"code":0,"data":{"file_token":"tok_front"}}"#),
            (200, #"{"code":0,"data":{"file_token":"tok_left"}}"#),
            (200, #"{"code":0,"data":{"file_token":"tok_right"}}"#),
            (200, #"{"code":0,"data":{"task_id":"task_mv"}}"#)
        ])
        let result = await TripoClient(apiKey: "tsk_secretkey1", transport: transport)
            .createGeneration(views: views([.right, .front, .left]), options: ImageTo3DOptions(targetTriangles: 3_000_000, higherDetail: true),
                              proceed: { true })
        XCTAssertEqual(result, .created(taskID: "task_mv"))
        XCTAssertEqual(transport.paths, ["POST /v3/files", "POST /v3/files", "POST /v3/files", "POST /v3/generation/multiview-to-model"])
        let sent = body(transport.requests[3])
        XCTAssertEqual(sent["inputs"] as? [[String: String]], [["front": "tok_front"], ["left": "tok_left"], ["right": "tok_right"]])
        XCTAssertNil(sent["input"])
        XCTAssertEqual(sent["geometry_quality"] as? String, "detailed")
        XCTAssertEqual(sent["face_limit"] as? Int, 2_000_000, "detailed geometry allows up to 2M")
        XCTAssertEqual(sent["texture"] as? Bool, false)
        XCTAssertEqual(sent["pbr"] as? Bool, false)
        XCTAssertTrue(String(decoding: transport.requests[0].httpBody ?? Data(), as: UTF8.self).contains("filename=\"photo.png\""),
                      "the front PNG is uploaded as a PNG")
    }

    func testTripoBodiesCapTheFaceLimitAndAddDetailOnlyWhenTicked() {
        let standard = tripoImageToModelBody(fileToken: "f", options: ImageTo3DOptions(targetTriangles: 3_000_000))
        XCTAssertEqual(standard["face_limit"] as? Int, 1_500_000)
        XCTAssertNil(standard["geometry_quality"])
        let detailed = tripoImageToModelBody(fileToken: "f", options: ImageTo3DOptions(targetTriangles: 100_000, higherDetail: true))
        XCTAssertEqual(detailed["face_limit"] as? Int, 100_000)
        XCTAssertEqual(detailed["geometry_quality"] as? String, "detailed")
        XCTAssertNil(tripoImageToModelBody(fileToken: "f", options: ImageTo3DOptions())["image_enhancement"])
        let multiview = tripoMultiviewToModelBody(fileTokens: [(.front, "a"), (.back, "b")], options: ImageTo3DOptions())
        XCTAssertEqual(multiview["inputs"] as? [[String: String]], [["front": "a"], ["back": "b"]])
        XCTAssertNil(tripoConvertBody(taskID: "t", options: ImageTo3DOptions(originAtBottom: false))["face_limit"],
                     "the conversion keeps every face")
    }

    func testTripoOnePhotoStaysOnImageToModel() async {
        let transport = MultiViewTransport([
            (200, #"{"code":0,"data":{"file_token":"tok"}}"#),
            (200, #"{"code":0,"data":{"task_id":"task_1"}}"#)
        ])
        let result = await TripoClient(apiKey: "tsk_secretkey1", transport: transport)
            .createGeneration(views: views([.front]), options: ImageTo3DOptions(), proceed: { true })
        XCTAssertEqual(result, .created(taskID: "task_1"))
        XCTAssertEqual(transport.paths, ["POST /v3/files", "POST /v3/generation/image-to-model"])
        XCTAssertEqual(body(transport.requests[1])["input"] as? String, "tok")
    }

    func testTripoUploadFailingOnPhotoThreeOfFourCreatesNothing() async {
        for failure in [(500, #"{"code":1,"message":"busy"}"#), (400, #"{"code":2002,"message":"bad image"}"#), (200, #"{"code":0,"data":{}}"#)] {
            let transport = MultiViewTransport([
                (200, #"{"code":0,"data":{"file_token":"tok_front"}}"#),
                (200, #"{"code":0,"data":{"file_token":"tok_left"}}"#),
                failure
            ])
            let result = await runImageTo3DGeneration(provider: TripoClient(apiKey: "tsk_secretkey1", transport: transport),
                                                      views: views([.front, .left, .back, .right]), options: ImageTo3DOptions(), sleep: { _ in })
            guard case .failure(let stop) = result else { return XCTFail() }
            XCTAssertEqual(stop.reason, .notSent, "\(failure)")
            XCTAssertFalse(stop.creditsMayHaveBeenSpent)
            XCTAssertNil(stop.resumePoint)
            XCTAssertTrue(stop.userMessage.contains("back photo"), stop.userMessage)
            XCTAssertEqual(transport.paths, ["POST /v3/files", "POST /v3/files", "POST /v3/files"], "no fourth upload and no create")
            XCTAssertFalse(stop.userMessage.contains("tsk_secretkey1"))
        }
    }

    func testStopDuringTheUploadsSendsNoCreate() async {
        // Stop is pressed while the second photo uploads: the third upload and the create are never sent.
        let transport = MultiViewTransport([
            (200, #"{"code":0,"data":{"file_token":"tok_front"}}"#),
            (200, #"{"code":0,"data":{"file_token":"tok_left"}}"#),
            (200, #"{"code":0,"data":{"file_token":"tok_back"}}"#),
            (200, #"{"code":0,"data":{"task_id":"task_mv"}}"#)
        ])
        let asked = Counter()
        let result = await runImageTo3DGeneration(provider: TripoClient(apiKey: "tsk_secretkey1", transport: transport),
                                                  views: views([.front, .left, .back]), options: ImageTo3DOptions(), sleep: { _ in },
                                                  proceed: { asked.next() <= 3 })
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .cancelled)
        XCTAssertNil(stop.taskID)
        XCTAssertFalse(stop.creditsMayHaveBeenSpent)
        XCTAssertEqual(stop.userMessage, "Stopped before anything was sent.")
        XCTAssertEqual(transport.paths, ["POST /v3/files", "POST /v3/files"])

        // Meshy has no uploads: a stop before the send sends nothing at all.
        let meshy = MultiViewTransport([(202, #"{"result":"m1"}"#)])
        let none = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: meshy),
                                                views: views([.front, .back]), options: ImageTo3DOptions(), sleep: { _ in },
                                                proceed: { false })
        guard case .failure(let meshyStop) = none else { return XCTFail() }
        XCTAssertEqual(meshyStop.reason, .cancelled)
        XCTAssertTrue(meshy.requests.isEmpty)
    }

    // MARK: Cost

    func testCostWithAndWithoutHigherDetail() {
        let transport = MultiViewTransport([])
        let meshy = MeshyClient(apiKey: "msy_testkey123", transport: transport)
        XCTAssertEqual(meshy.estimatedCost(for: ImageTo3DOptions()).credits, 20)
        XCTAssertEqual(meshy.estimatedCost(for: ImageTo3DOptions(), photoCount: 4).credits, 20, "the same price with more photos")
        let meshyDetail = meshy.estimatedCost(for: ImageTo3DOptions(higherDetail: true), photoCount: 2)
        XCTAssertEqual(meshyDetail.credits, 25)
        XCTAssertEqual(meshyDetail.summary,
                       "About 25 Meshy credits (Multi-Image to 3D, mesh only 20 + 5 for higher detail). Approximate: Meshy’s prices may have changed.")

        let tripo = TripoClient(apiKey: "tsk_testkey123", transport: transport)
        let plain = ImageTo3DOptions(originAtBottom: false)
        XCTAssertEqual(tripo.estimatedCost(for: plain).credits, 25)
        XCTAssertEqual(tripo.estimatedCost(for: plain, photoCount: 3).credits, 25)
        var detailed = plain
        detailed.higherDetail = true
        let tripoDetail = tripo.estimatedCost(for: detailed, photoCount: 3)
        XCTAssertEqual(tripoDetail.credits, 45)
        XCTAssertEqual(tripoDetail.breakdown, "multiview to model 20 + 20 for higher detail, conversion to STL 5")
        XCTAssertEqual(tripo.estimatedCost(for: ImageTo3DOptions(higherDetail: true)).credits, 50)

        XCTAssertEqual(replicaCostEstimate(service: .meshy, purpose: .display, photoCount: 3, higherDetail: true).credits, 25)
        XCTAssertEqual(replicaCostEstimate(service: .tripo, purpose: .display, photoCount: 2, higherDetail: true).credits, 45)
        XCTAssertEqual(replicaCostEstimate(service: .tripo, purpose: .functional, photoCount: 2, higherDetail: true).credits, 25,
                       "a functional part never pays for detail it would lose")
        XCTAssertEqual(replicaCostEstimate(service: .tripo, photoCount: 2).credits, 25)
        XCTAssertTrue(replicaCostLine(replicaCostEstimate(service: .meshy, photoCount: 2), photoCount: 2).hasSuffix("Extra photos don’t change the price."))
        XCTAssertFalse(replicaCostLine(replicaCostEstimate(service: .meshy), photoCount: 1).contains("Extra photos"))
    }

    func testHigherDetailOnlyForADisplayPiece() {
        XCTAssertTrue(replicaGenerationOptions(for: .meshy, purpose: .display, higherDetail: true).higherDetail)
        XCTAssertFalse(replicaGenerationOptions(for: .tripo, purpose: .display).higherDetail, "off unless ticked")
        XCTAssertFalse(replicaGenerationOptions(for: .meshy, purpose: .functional, higherDetail: true).higherDetail,
                       "a functional part is simplified to 20,000 triangles, so the detail would be lost")
        XCTAssertTrue(replicaHigherDetailAvailable(for: .display))
        XCTAssertFalse(replicaHigherDetailAvailable(for: .functional))
        XCTAssertEqual(replicaHigherDetailFunctionalNote, "Functional parts are simplified to 20,000 triangles, so higher detail would be lost.")
        XCTAssertTrue(replicaHigherDetailNote(service: .meshy).contains("Ultra 2K"))
        XCTAssertTrue(replicaHigherDetailNote(service: .meshy).contains("Plinth keeps up to 200,000 triangles"))
        XCTAssertTrue(replicaHigherDetailNote(service: .tripo).contains("20 more credits"))
    }

    func testAModelTooLargeToDownloadIsAFinalStop() async {
        let transport = MultiViewTransport([
            (202, #"{"result":"m1"}"#),
            (200, #"{"id":"m1","status":"SUCCEEDED","progress":100,"model_urls":{"stl":"https://assets.meshy.ai/m1/model.stl"}}"#)
        ])
        transport.downloadError = ImageTo3DError.modelTooLarge
        let result = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport),
                                                  views: views([.front, .back]), options: ImageTo3DOptions(higherDetail: true),
                                                  sleep: { _ in }, makeFolder: { try self.makeFolder() })
        guard case .failure(let stop) = result else { return XCTFail() }
        XCTAssertEqual(stop.reason, .modelTooLarge)
        XCTAssertNil(stop.resumePoint, "downloading it again can't work")
        XCTAssertNil(replicaResumeAction(for: stop), "no Try Download Again")
        XCTAssertTrue(stop.creditsMayHaveBeenSpent)
        XCTAssertFalse(imageTo3DStopIsUnconfirmed(stop), "a known outcome, explained in the sheet")
        for phrase in ["too detailed for Plinth", "over 128 MB", "credits for it were spent", "Meshy’s dashboard",
                       "Meshy keeps it for 3 days", "without Higher detail"] {
            XCTAssertTrue(stop.userMessage.contains(phrase), "\(phrase): \(stop.userMessage)")
        }
        XCTAssertEqual(stop.activityDetail, "Meshy: downloading, model too large, task m1")
        XCTAssertFalse(imageTo3DCreateOutcomeUnknown(ImageTo3DError.modelTooLarge))
    }

    func testAConversionIsNotLabelledMultiImage() {
        let conversion = ImageTo3DUnconfirmedRequest(id: UUID(), service: .tripo, sourceTaskID: "gen", taskID: "conv",
                                                     time: Date(timeIntervalSince1970: 0), sourceKind: .multiImageGeneration)
        XCTAssertEqual(imageTo3DUnconfirmedLabel(conversion, timeText: { _ in "09:00" }), "Tripo at 09:00 (task conv)")
        let generation = ImageTo3DUnconfirmedRequest(id: UUID(), service: .tripo, sourceTaskID: "gen", taskID: "gen",
                                                     time: Date(timeIntervalSince1970: 0), sourceKind: .multiImageGeneration)
        XCTAssertEqual(imageTo3DUnconfirmedLabel(generation, timeText: { _ in "09:00" }), "Tripo at 09:00 (multi-image task gen)")
    }
}
