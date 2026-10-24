import XCTest
import simd
@testable import SlantStudio

/// Each request takes the next scripted reply; records every request and download. Never touches the network.
private final class ReplicaScriptedTransport: ImageTo3DTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [(Int, String)]
    private(set) var requests: [URLRequest] = []
    private(set) var downloads: [URL] = []
    let modelData: Data

    init(_ replies: [(Int, String)], modelData: Data = Data()) {
        self.replies = replies
        self.modelData = modelData
    }

    func send(_ request: URLRequest) async throws -> ImageTo3DHTTPReply {
        let next: (Int, String)? = lock.withLock {
            requests.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let next else { throw ImageTo3DError.transport("No scripted reply") }
        return ImageTo3DHTTPReply(status: next.0, headers: [:], body: Data(next.1.utf8))
    }

    func download(_ url: URL, into folder: URL, fileName: String, maxBytes: Int64) async throws -> URL {
        lock.withLock { downloads.append(url) }
        let file = folder.appendingPathComponent(fileName)
        try modelData.write(to: file)
        return file
    }

    var posts: Int { lock.withLock { requests.filter { $0.httpMethod == "POST" }.count } }
}

private final class ResultBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T?
    var value: T? { lock.withLock { stored } }
    func set(_ value: T) { lock.withLock { stored = value } }
}

final class ReplicaGeneratorTests: XCTestCase {
    private let jpeg = ImageTo3DImage(data: Data([0xFF, 0xD8, 0xFF, 0xE0, 1, 2, 3, 4]), mediaType: "image/jpeg")
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(replicaTempFolderPrefix)\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        folders.append(folder)
        return folder
    }

    private func box(_ scale: SIMD3<Float>, offset: SIMD3<Float> = .zero) throws -> STLMesh {
        try MeshRepairTests.mesh(MeshRepairTests.cubePoints().map { $0 * scale + offset }, MeshRepairTests.cubeTriangles)
    }

    private func size(_ axis: ReplicaSizeAxis, _ mm: Double) -> ReplicaSize { ReplicaSize(axis: axis, millimetres: mm) }

    // MARK: Inputs

    func testSizeParsing() {
        XCTAssertEqual(replicaSizeProblem(""), "Enter the real size in millimetres.")
        XCTAssertNotNil(replicaSizeProblem("abc"))
        XCTAssertNotNil(replicaSizeProblem("-5"))
        XCTAssertNotNil(replicaSizeProblem("1e2"))
        XCTAssertNotNil(replicaSizeProblem("4.9"), "below the minimum")
        XCTAssertNotNil(replicaSizeProblem("220.5"), "larger than the build volume")
        XCTAssertNil(replicaSizeProblem("5"))
        XCTAssertNil(replicaSizeProblem("220"))
        XCTAssertEqual(replicaSize(axis: .height, text: "120 mm"), size(.height, 120))
        XCTAssertEqual(replicaSize(axis: .width, text: "85,5"), size(.width, 85.5))
        XCTAssertNil(replicaSize(axis: .depth, text: "300"))
        XCTAssertEqual(size(.height, 120).reviewNote, "Height should be 120 mm (typed by the seller)")
        XCTAssertEqual(size(.longest, 85.5).label, "Longest side 85.5 mm")
    }

    func testAxisMapping() {
        let extent = SIMD3<Float>(1, 2, 3)
        XCTAssertEqual(ReplicaSizeAxis.width.length(of: extent), 1)
        XCTAssertEqual(ReplicaSizeAxis.depth.length(of: extent), 2)
        XCTAssertEqual(ReplicaSizeAxis.height.length(of: extent), 3)
        XCTAssertEqual(ReplicaSizeAxis.longest.length(of: SIMD3(5, 2, 3)), 5)
        XCTAssertEqual(ReplicaSizeAxis.height.meshFitAxis, .z)
        XCTAssertEqual(ReplicaSizeAxis.longest.meshFitAxis, .longest)
    }

    func testNamesAndCopyNames() {
        XCTAssertNotNil(replicaNameProblem(""))
        XCTAssertNotNil(replicaNameProblem("a/b"))
        XCTAssertNotNil(replicaNameProblem("..."), "only full stops would leave nothing")
        XCTAssertNotNil(replicaNameProblem(String(repeating: "x", count: maximumModelNameLength)), "room for the suffix")
        XCTAssertNil(replicaNameProblem("Dragon figure"))
        XCTAssertEqual(replicaCopyName("  Dragon "), "Dragon (replica)")
        XCTAssertEqual(replicaCopyName("..hidden"), "hidden (replica)")
        XCTAssertEqual(replicaCopyName("Dragon", upright: true), "Dragon (replica, upright)")
        let longest = String(repeating: "x", count: maximumModelNameLength - replicaUprightNameSuffix.count)
        XCTAssertNil(replicaNameProblem(longest))
        XCTAssertNil(modelNameProblem(replicaCopyName(longest, upright: true)), "the saved name stays within the library's limit")
        XCTAssertNil(replicaInputs(name: "", axis: .height, sizeText: "100", purpose: .display))
        XCTAssertNil(replicaInputs(name: "Cat", axis: .height, sizeText: "", purpose: .display))
        XCTAssertEqual(replicaInputs(name: " Cat ", axis: .height, sizeText: "100", purpose: .functional),
                       ReplicaInputs(name: "Cat", size: size(.height, 100), purpose: .functional))
    }

    func testPurposeIntent() {
        XCTAssertEqual(ReplicaPurpose.display.partIntent?.purpose, .decorative)
        XCTAssertNil(ReplicaPurpose.functional.partIntent, "a functional part needs the seller's load direction")
    }

    func testOptionsAndCostWithoutAKey() {
        let meshy = replicaGenerationOptions(for: .meshy)
        XCTAssertEqual(meshy.targetTriangles, 20_000)
        XCTAssertEqual(meshy.format, .stl)
        XCTAssertTrue(meshy.originAtBottom)
        XCTAssertFalse(replicaGenerationOptions(for: .tripo).originAtBottom, "Studio places the model itself; the option costs Tripo credits")
        XCTAssertEqual(replicaCostEstimate(service: .meshy).credits, meshyImageTo3DMeshOnlyCredits)
        XCTAssertEqual(replicaCostEstimate(service: .tripo).credits, tripoImageToModelCredits + tripoConvertBasicCredits)
    }

    func testBlockedReasonsInOrder() {
        let all = replicaGenerateBlockedReasons(photoReady: false, photoPreparing: false, nameText: "", sizeText: "",
                                                service: .meshy, hasKey: false)
        XCTAssertEqual(all.count, 4)
        XCTAssertEqual(all[0], "Choose a photo of the object.")
        XCTAssertEqual(all[1], "Enter a name for the replica.")
        XCTAssertTrue(all[3].contains("Meshy API key"))
        XCTAssertEqual(replicaGenerateBlockedReasons(photoReady: false, photoPreparing: true, nameText: "A", sizeText: "50",
                                                     service: .tripo, hasKey: true),
                       ["Wait while Studio prepares the photo."])
        XCTAssertTrue(replicaGenerateBlockedReasons(photoReady: true, photoPreparing: false, nameText: "A", sizeText: "50",
                                                    service: .tripo, hasKey: true).isEmpty)
    }

    // MARK: Pipeline

    func testPipelineScalesPlacesAndChecksInOrder() throws {
        // Services send metres (probably): a 2 cm cube far from the origin.
        let mesh = try MeshRepairTests.cube(size: 0.02, offset: SIMD3(3, -4, 1))
        let result = try processReplicaModel(mesh.binarySTL(), format: .stl, size: size(.height, 40))
        XCTAssertEqual(result.steps, [.read, .scale, .repair, .check])
        XCTAssertEqual(result.extentMM.z, 40, accuracy: 0.001)
        XCTAssertEqual(result.mesh.minimum.z, 0, accuracy: 0.0001, "base on the bed")
        XCTAssertEqual(result.mesh.minimum.x, -result.mesh.maximum.x, accuracy: 0.001, "centred")
        XCTAssertTrue(meshHealthIsSound(result.health))
        XCTAssertEqual(result.originalTriangles, 12)
        XCTAssertEqual(try STLMesh.parse(result.stlData).triangleCount, 12)
        XCTAssertTrue(result.changes.first?.hasPrefix("Scaled to Height 40 mm") == true)
        XCTAssertTrue(replicaChecksFoundNoProblems(result), "a 40 mm solid cube has no thin walls")
        let lines = replicaSummaryLines(result)
        XCTAssertEqual(lines.first, "Size: 40.0 × 40.0 × 40.0 mm (width × depth × height).")
        XCTAssertEqual(lines[1], "12 triangles.")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Mesh check: closed and consistent") })
    }

    func testPipelineRunsTwiceToTheSameBytes() throws {
        let sphere = try MeshRepairTests.sphere(levels: 3, radius: 0.05)
        let data = sphere.binarySTL()
        let first = try processReplicaModel(data, format: .stl, size: size(.longest, 60), triangleTarget: 300)
        let second = try processReplicaModel(data, format: .stl, size: size(.longest, 60), triangleTarget: 300)
        XCTAssertEqual(first.stlData, second.stlData)
        XCTAssertEqual(first.changes, second.changes)
        XCTAssertTrue(first.steps.contains(.simplify))
        XCTAssertEqual(Array(first.steps.prefix(4)), [.read, .scale, .repair, .simplify])
        XCTAssertEqual(first.steps.last, .check)
        XCTAssertLessThan(first.mesh.triangleCount, sphere.triangleCount)
        XCTAssertEqual(Double(first.extentMM.max()), 60, accuracy: 0.01, "the size still holds after simplifying")
        XCTAssertTrue(replicaSummaryLines(first)[1].contains("the service sent \(sphere.triangleCount.formatted())"))
    }

    func testSimplifySkippedAtOrUnderTheTarget() throws {
        let sphere = try MeshRepairTests.sphere(levels: 2, radius: 1)
        let result = try processReplicaModel(sphere.binarySTL(), format: .stl, size: size(.width, 30), triangleTarget: sphere.triangleCount)
        XCTAssertFalse(result.steps.contains(.simplify))
    }

    func testUprightTurnsYUpToZUpKeepingFacesOutward() throws {
        // Y-up: 1 wide, 3 tall (Y), 2 deep (Z).
        let mesh = try box(SIMD3(1, 3, 2))
        let result = try processReplicaModel(mesh.binarySTL(), format: .stl, size: size(.height, 30), upAxis: .y)
        XCTAssertEqual(result.steps, [.read, .turnUpright, .scale, .repair, .check])
        XCTAssertEqual(result.extentMM.x, 10, accuracy: 0.001)
        XCTAssertEqual(result.extentMM.y, 20, accuracy: 0.001)
        XCTAssertEqual(result.extentMM.z, 30, accuracy: 0.001)
        XCTAssertTrue(meshHealthIsSound(result.health), "a rotation keeps the faces pointing outward")
        XCTAssertEqual(result.upAxis, .y)
        let again = try processReplicaModel(mesh.binarySTL(), format: .stl, size: size(.height, 30), upAxis: .y)
        XCTAssertEqual(result.stlData, again.stlData)
    }

    func testTooLargeForTheBuildVolumeSaysProcessAgain() throws {
        let tall = try box(SIMD3(1, 1, 4))
        XCTAssertThrowsError(try processReplicaModel(tall.binarySTL(), format: .stl, size: size(.width, 100))) { error in
            guard case ReplicaProcessingError.exceedsBuildVolume(let wanted, let longest)? = error as? ReplicaProcessingError else {
                return XCTFail("\(error)")
            }
            XCTAssertEqual(wanted, self.size(.width, 100))
            XCTAssertEqual(longest, 400, accuracy: 0.5)
            XCTAssertTrue(error.localizedDescription.contains("Process Again"))
        }
    }

    func testLooseFragmentRemovalIsFollowedByAResize() throws {
        // A 10 mm cube and a tiny closed fragment far to the side that repair removes, which shrinks the width.
        let cube = try MeshRepairTests.cube(size: 10)
        let tetraPoints: [SIMD3<Float>] = [SIMD3(50, 0, 0), SIMD3(50.1, 0, 0), SIMD3(50, 0.1, 0), SIMD3(50, 0, 0.1)]
        let tetra: [SIMD3<Int32>] = [SIMD3(0, 2, 1), SIMD3(0, 1, 3), SIMD3(0, 3, 2), SIMD3(1, 2, 3)]
        let combined = try STLMesh.validated(cube.vertices + meshSoup(points: tetraPoints, triangles: tetra))
        let result = try processReplicaModel(combined.binarySTL(), format: .stl, size: size(.width, 30))
        XCTAssertTrue(result.steps.contains(.resize), "\(result.steps)")
        XCTAssertEqual(result.extentMM.x, 30, accuracy: 0.01)
        XCTAssertEqual(result.mesh.triangleCount, 12)
        XCTAssertEqual(result.mesh.minimum.z, 0, accuracy: 0.0001)
        XCTAssertTrue(result.changes.contains { $0.contains("loose fragment") })
    }

    func testUnreadableAndCancelledRunsSaveNothing() throws {
        XCTAssertThrowsError(try processReplicaModel(Data("not a model".utf8), format: .stl, size: size(.height, 40))) { error in
            guard case ReplicaProcessingError.unreadable? = error as? ReplicaProcessingError else { return XCTFail("\(error)") }
        }
        let cube = try MeshRepairTests.cube(size: 1)
        XCTAssertThrowsError(try processReplicaModel(cube.binarySTL(), format: .stl, size: size(.height, 40), isCancelled: { true })) { error in
            XCTAssertEqual(error as? MeshToolError, .cancelled)
        }
    }

    // MARK: Stop and resume

    private func stop(_ reason: ImageTo3DStopReason, stage: ImageTo3DStage = .generating, taskID: String? = "t1",
                      resume: Bool = true) -> ImageTo3DStop {
        ImageTo3DStop(reason: reason, stage: stage, service: .meshy, taskID: taskID, detail: "",
                      resumePoint: resume ? ImageTo3DResumePoint(sourceTaskID: "t1", sourceKind: .generation, conversionTaskID: nil) : nil)
    }

    func testResumeActions() {
        XCTAssertEqual(replicaResumeAction(for: stop(.timedOut)), .keepWaiting)
        XCTAssertEqual(replicaResumeAction(for: stop(.statusUnreadable)), .keepWaiting)
        XCTAssertEqual(replicaResumeAction(for: stop(.cancelled)), .keepWaiting)
        XCTAssertEqual(replicaResumeAction(for: stop(.cancelled, stage: .downloading)), .tryDownloadAgain)
        XCTAssertEqual(replicaResumeAction(for: stop(.downloadFailed, stage: .downloading)), .tryDownloadAgain)
        XCTAssertEqual(replicaResumeAction(for: stop(.conversionRefused, stage: .converting)), .tryConversionAgain)
        XCTAssertNil(replicaResumeAction(for: stop(.outcomeUnknown, resume: false)), "an unknown create is never resumed")
        XCTAssertNil(replicaResumeAction(for: stop(.outcomeUnknown, resume: true)), "even if a resume point were set")
        XCTAssertNil(replicaResumeAction(for: stop(.notSent, taskID: nil, resume: false)))
        XCTAssertNil(replicaResumeAction(for: stop(.taskEnded(.failed), resume: false)))
        XCTAssertNil(replicaResumeAction(for: stop(.timedOut, resume: false)))
        XCTAssertEqual(ReplicaResumeAction.keepWaiting.title, "Keep Waiting")
    }

    func testGeneratingAgainNeedsConfirmationAfterPossibleSpend() {
        XCTAssertFalse(replicaGenerateNeedsConfirmation(lastStop: nil, modelAlreadyMade: false))
        XCTAssertFalse(replicaGenerateNeedsConfirmation(lastStop: stop(.notSent, taskID: nil, resume: false), modelAlreadyMade: false))
        XCTAssertFalse(replicaGenerateNeedsConfirmation(lastStop: stop(.cancelled, taskID: nil, resume: false), modelAlreadyMade: false),
                       "stopped before anything was sent")
        XCTAssertTrue(replicaGenerateNeedsConfirmation(lastStop: stop(.outcomeUnknown, resume: false), modelAlreadyMade: false))
        XCTAssertTrue(replicaGenerateNeedsConfirmation(lastStop: stop(.timedOut), modelAlreadyMade: false))
        XCTAssertTrue(replicaGenerateNeedsConfirmation(lastStop: nil, modelAlreadyMade: true))
        let message = replicaGenerateAgainMessage(lastStop: stop(.outcomeUnknown, resume: false), estimate: replicaCostEstimate(service: .meshy))
        XCTAssertTrue(message.contains("task t1"))
        XCTAssertTrue(message.contains("About 20 Meshy credits"))
        XCTAssertTrue(replicaGenerateAgainMessage(lastStop: nil, estimate: replicaCostEstimate(service: .tripo)).contains("Process Again"))
        let switched = replicaGenerateAgainMessage(lastStop: stop(.timedOut), estimate: replicaCostEstimate(service: .tripo))
        XCTAssertTrue(switched.hasPrefix("Meshy may already"), "names the service the earlier request went to")
        XCTAssertTrue(switched.contains("Tripo credits"), "and prices the new one")
        XCTAssertEqual(replicaCreditsNote(stop(.notSent, taskID: nil, resume: false)), "No credits were spent.")
        XCTAssertEqual(replicaCreditsNote(stop(.outcomeUnknown, resume: false)), "Meshy may have charged for this.")
    }

    func testStopOnlyCancelsAtSafePoints() async {
        let creating = ImageTo3DProgress(stage: .sending, taskID: nil, state: nil, percent: nil)
        let converting = ImageTo3DProgress(stage: .converting, taskID: "t1", state: nil, percent: nil)
        let polled = ImageTo3DProgress(stage: .generating, taskID: "t1", state: .running, percent: 40)
        let downloading = ImageTo3DProgress(stage: .downloading, taskID: "t1", state: .succeeded, percent: nil)
        XCTAssertFalse(replicaProgressAllowsStop(creating))
        XCTAssertFalse(replicaProgressAllowsStop(converting), "a conversion create follows")
        XCTAssertTrue(replicaProgressAllowsStop(polled))
        XCTAssertTrue(replicaProgressAllowsStop(downloading))
        XCTAssertFalse(replicaStopCancelsAtOnce(last: nil))
        XCTAssertFalse(replicaStopCancelsAtOnce(last: polled), "a create may be starting right after a status read")
        XCTAssertTrue(replicaStopCancelsAtOnce(last: downloading))

        let control = ReplicaRunControl()
        let task = Task<Void, Never> { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        control.attach(task)
        control.report(creating)
        control.requestStop()
        XCTAssertFalse(task.isCancelled, "never mid-create")
        control.report(converting)
        XCTAssertFalse(task.isCancelled)
        control.report(polled)
        XCTAssertTrue(task.isCancelled)
        await task.value

        let downloadControl = ReplicaRunControl()
        let downloadTask = Task<Void, Never> { try? await Task.sleep(nanoseconds: 5_000_000_000) }
        downloadControl.attach(downloadTask)
        downloadControl.report(downloading)
        downloadControl.requestStop()
        XCTAssertTrue(downloadTask.isCancelled, "a download spends nothing, so it stops at once")
        await downloadTask.value
    }

    func testInterruptibleSleepEndsEarlyOnStop() async throws {
        let slept = ResultBox<[TimeInterval]>()
        slept.set([])
        let control = ReplicaRunControl()
        let sleep = replicaInterruptibleSleep(control, slice: 0.25) { seconds in
            slept.set((slept.value ?? []) + [seconds])
        }
        try await sleep(1)
        XCTAssertEqual(slept.value, [0.25, 0.25, 0.25, 0.25])

        slept.set([])
        let stopping = replicaInterruptibleSleep(control, slice: 0.25) { seconds in
            slept.set((slept.value ?? []) + [seconds])
            if slept.value?.count == 2 { control.requestStop() }
        }
        do {
            try await stopping(4)
            XCTFail("should stop")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(slept.value?.count, 2)
    }

    func testStopDuringTheCreateLetsItAnswerThenStopsWithKeepWaiting() async {
        let transport = ReplicaScriptedTransport([(202, #"{"result":"t1"}"#), (200, #"{"id":"t1","status":"PENDING","progress":0}"#)])
        let client = MeshyClient(apiKey: "msy_secretkey1", transport: transport)
        let control = ReplicaRunControl()
        control.requestStop()  // pressed while the create is on its way
        let box = ResultBox<Result<ImageTo3DGeneratedModel, ImageTo3DStop>>()
        let task = Task<Void, Never> {
            let result = await runImageTo3DGeneration(provider: client, image: self.jpeg, options: replicaGenerationOptions(for: .meshy),
                                                      sleep: replicaInterruptibleSleep(control, base: { _ in }),
                                                      makeFolder: { try self.makeFolder() },
                                                      progress: { control.report($0) })
            box.set(result)
        }
        control.attach(task)
        await task.value
        guard case .failure(let stop)? = box.value else { return XCTFail("\(String(describing: box.value))") }
        XCTAssertEqual(transport.posts, 1, "sent once, never again")
        XCTAssertEqual(stop.reason, .cancelled)
        XCTAssertEqual(stop.taskID, "t1")
        XCTAssertEqual(replicaResumeAction(for: stop), .keepWaiting)
        XCTAssertTrue(stop.creditsMayHaveBeenSpent)
    }

    func testStopBeforeTheDownloadOffersTryDownloadAgain() async {
        let finished = #"{"id":"t1","status":"SUCCEEDED","progress":100,"model_urls":{"stl":"https://assets.meshy.ai/t1/model.stl"}}"#
        let transport = ReplicaScriptedTransport([(202, #"{"result":"t1"}"#), (200, finished)])
        let client = MeshyClient(apiKey: "msy_secretkey1", transport: transport)
        let control = ReplicaRunControl()
        control.requestStop()
        let box = ResultBox<Result<ImageTo3DGeneratedModel, ImageTo3DStop>>()
        let task = Task<Void, Never> {
            box.set(await runImageTo3DGeneration(provider: client, image: self.jpeg, options: replicaGenerationOptions(for: .meshy),
                                                 sleep: replicaInterruptibleSleep(control, base: { _ in }),
                                                 makeFolder: { try self.makeFolder() }, progress: { control.report($0) }))
        }
        control.attach(task)
        await task.value
        guard case .failure(let stop)? = box.value else { return XCTFail() }
        XCTAssertEqual(stop.reason, .cancelled)
        XCTAssertEqual(stop.stage, .downloading)
        XCTAssertEqual(replicaResumeAction(for: stop), .tryDownloadAgain)
        XCTAssertTrue(transport.downloads.isEmpty)
        XCTAssertEqual(transport.posts, 1)
    }

    func testDownloadedModelGoesThroughThePipeline() async throws {
        let cube = try MeshRepairTests.cube(size: 0.05)
        let finished = #"{"id":"t1","status":"SUCCEEDED","progress":100,"model_urls":{"stl":"https://assets.meshy.ai/t1/model.stl"}}"#
        let transport = ReplicaScriptedTransport([(202, #"{"result":"t1"}"#), (200, finished)], modelData: cube.binarySTL())
        let result = await runImageTo3DGeneration(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), image: jpeg,
                                                  options: replicaGenerationOptions(for: .meshy), sleep: { _ in },
                                                  makeFolder: { try self.makeFolder() })
        guard case .success(let model) = result else { return XCTFail("\(result)") }
        let processed = try processReplicaModel(Data(contentsOf: model.fileURL), format: model.format, size: size(.height, 25))
        XCTAssertEqual(processed.extentMM.z, 25, accuracy: 0.001)
        XCTAssertEqual(transport.posts, 1)
    }

    // MARK: Hand-off and records

    func testPrintReviewContext() {
        let plain = replicaPrintReviewContext(service: .tripo, size: size(.height, 120), purpose: .functional, meshyReport: nil)
        XCTAssertEqual(plain.origin, "Generated by Tripo3D from a photo")
        XCTAssertEqual(plain.intendedSizeNote, "Height should be 120 mm (typed by the seller)")
        XCTAssertEqual(plain.purpose, "Functional part")
        XCTAssertEqual(plain.findings.count, 1)
        XCTAssertTrue(plain.findings[0].contains("one photo"))

        let report = MeshyPrintabilityReport(taskID: "a1", verdict: .warning, errorCount: 0, warningCount: 1, isWatertight: false,
                                             holes: 2, nonManifoldEdges: nil, degenerateFaces: nil, hasThinWalls: true,
                                             thinAreaRatio: 0.05, wallThicknessMM: 1.2, dimensionsMM: nil)
        let withMeshy = replicaPrintReviewContext(service: .meshy, size: size(.longest, 80), purpose: .display, meshyReport: report)
        XCTAssertEqual(withMeshy.origin, "Generated by Meshy from a photo")
        XCTAssertEqual(withMeshy.findings.count, 2)
        XCTAssertTrue(withMeshy.findings[1].contains("before Studio’s repair"))
        XCTAssertTrue(withMeshy.findings[1].contains("2 holes"))
        XCTAssertTrue(withMeshy.findings[1].contains("Thin walls thinner than 1.2 mm"))
    }

    func testRecordsHoldNoNamesOrPhotos() {
        XCTAssertEqual(replicaSavedActivityDetail(service: .meshy, triangles: 19_876, estimate: replicaCostEstimate(service: .meshy)),
                       "Meshy: saved, \(19_876.formatted()) triangles, about 20 credits")
        XCTAssertEqual(replicaSavedActivityDetail(service: .tripo, triangles: 10, estimate: nil), "Tripo: saved, 10 triangles")
        XCTAssertEqual(replicaSourceDetails(service: .meshy), ModelSourceDetails(source: "Generated by Meshy from a photo"))
        XCTAssertTrue(isPersonalisationTempFolderName("\(replicaTempFolderPrefix)\(UUID().uuidString)"), "removed at launch")
    }

    func testProgressLine() {
        XCTAssertEqual(replicaProgressLine(nil, service: .meshy, stopping: false), "Meshy: sending to the service…")
        let queued = ImageTo3DProgress(stage: .generating, taskID: "t1", state: .queued, percent: 0)
        XCTAssertEqual(replicaProgressLine(queued, service: .meshy, stopping: false), "Meshy: waiting in the queue (0%)…")
        let running = ImageTo3DProgress(stage: .generating, taskID: "t1", state: .running, percent: 40)
        XCTAssertEqual(replicaProgressLine(running, service: .tripo, stopping: true), "Tripo: generating the model (40%) — stopping…")
        XCTAssertEqual(replicaProgressLine(nil, service: .tripo, stopping: true), "Tripo: sending to the service — stopping once Tripo answers…")
    }
}
