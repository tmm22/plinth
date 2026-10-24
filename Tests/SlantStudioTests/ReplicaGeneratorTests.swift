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
    /// Wall-thickness samples for the pipeline tests: enough to find the walls of these simple shapes, far fewer than
    /// the app's 20,000, so the suite stays quick.
    private let samples = 300

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
        let longest = String(repeating: "x", count: maximumModelNameLength - replicaNameSuffix.count)
        XCTAssertNil(replicaNameProblem(longest))
        XCTAssertNotNil(replicaNameProblem(longest + "x"))
        XCTAssertNil(modelNameProblem(replicaCopyName(longest)), "the saved name stays within the library's limit")
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
        let meshy = replicaGenerationOptions(for: .meshy, purpose: .functional)
        XCTAssertEqual(meshy.targetTriangles, 100_000)
        XCTAssertEqual(meshy.format, .stl)
        XCTAssertTrue(meshy.originAtBottom)
        XCTAssertFalse(replicaGenerationOptions(for: .tripo, purpose: .functional).originAtBottom,
                       "Studio places the model itself; the option costs Tripo credits")
        XCTAssertEqual(replicaCostEstimate(service: .meshy).credits, meshyImageTo3DMeshOnlyCredits)
        XCTAssertEqual(replicaCostEstimate(service: .tripo).credits, tripoImageToModelCredits + tripoConvertBasicCredits)
        XCTAssertEqual(replicaCostEstimate(service: .tripo, purpose: .display), replicaCostEstimate(service: .tripo, purpose: .functional),
                       "the triangle budget doesn't change the published price")
    }

    func testDisplayPiecesKeepTheirDetail() {
        // A display piece asks for far more triangles, within both services' documented maximums.
        let meshy = replicaGenerationOptions(for: .meshy, purpose: .display)
        let tripo = replicaGenerationOptions(for: .tripo, purpose: .display)
        XCTAssertEqual(meshy.targetTriangles, 500_000)
        // Meshy isn't remeshed, so it gets no triangle budget at all.
        XCTAssertNil(meshyImageTo3DBody(imageDataURI: "data:", options: meshy)["target_polycount"])
        XCTAssertEqual(meshyImageTo3DBody(imageDataURI: "data:", options: meshy)["should_remesh"] as? Bool, false)
        XCTAssertEqual(tripoImageToModelBody(fileToken: "f", options: tripo)["face_limit"] as? Int, 500_000)
        XCTAssertLessThanOrEqual(replicaDisplayTriangleTarget, tripoFaceLimitRange.upperBound)
        XCTAssertEqual(tripoImageToModelBody(fileToken: "f", options: replicaGenerationOptions(for: .tripo, purpose: .functional))["face_limit"] as? Int,
                       100_000, "a functional part asks for five times what Studio keeps")
        // Studio simplifies a display piece only above its ceiling, well under the import limit; a functional part
        // still goes down to Reinforce's limit.
        XCTAssertEqual(ReplicaPurpose.display.triangleCeiling, 200_000)
        XCTAssertLessThan(ReplicaPurpose.display.triangleCeiling, STLMesh.maximumTriangles)
        XCTAssertEqual(ReplicaPurpose.functional.requestedTriangles, replicaFunctionalTriangleRequest)
        XCTAssertEqual(ReplicaPurpose.functional.triangleCeiling, meshToolsReinforceTriangleLimit)
        XCTAssertTrue(replicaFunctionalPartWarning.contains("isn’t dimensionally accurate"))
        XCTAssertTrue(replicaFunctionalPartWarning.contains("Design an Accessory from a Photo"))
    }

    func testDetailedReplicaPointsToSimplify() throws {
        let small = try processReplicaModel(MeshRepairTests.cube(size: 1).binarySTL(), size: size(.height, 20), wallThicknessSamples: 50)
        // 20,004 triangles: the cube's twelve, many times over (only the count matters for the summary).
        let many = try STLMesh.validated(Array(repeating: small.mesh.vertices, count: 1_667).flatMap { $0 })
        let detailed = ReplicaProcessed(mesh: many, stlData: Data(), size: small.size, upAxis: .z, originalTriangles: many.triangleCount,
                                        health: small.health, wallThickness: small.wallThickness, overhang: small.overhang,
                                        changes: [], steps: [])
        let lines = replicaSummaryLines(detailed)
        XCTAssertTrue(lines.contains { $0.contains("Reinforce and Auto-improve need 20,000 triangles or fewer") && $0.contains("Simplify & Save Copy") },
                      "\(lines)")
        XCTAssertFalse(replicaSummaryLines(small).contains { $0.contains("Simplify") })
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
                       ["Wait while Studio prepares the photos."])
        XCTAssertTrue(replicaGenerateBlockedReasons(photoReady: true, photoPreparing: false, nameText: "A", sizeText: "50",
                                                    service: .tripo, hasKey: true).isEmpty)
    }

    // MARK: Pipeline

    func testPipelineScalesPlacesAndChecksInOrder() throws {
        // Services send metres (probably): a 2 cm cube far from the origin.
        let mesh = try MeshRepairTests.cube(size: 0.02, offset: SIMD3(3, -4, 1))
        let result = try processReplicaModel(mesh.binarySTL(), size: size(.height, 40), wallThicknessSamples: samples)
        XCTAssertEqual(result.steps, [.read, .scale, .repair, .check])
        XCTAssertEqual(result.extentMM.z, 40, accuracy: 0.001)
        XCTAssertEqual(result.mesh.minimum.z, 0, accuracy: 0.0001, "base on the bed")
        XCTAssertEqual(result.mesh.minimum.x, -result.mesh.maximum.x, accuracy: 0.001, "centred")
        XCTAssertTrue(meshHealthIsSound(result.health))
        XCTAssertEqual(result.originalTriangles, 12)
        XCTAssertEqual(try STLMesh.parse(result.stlData).triangleCount, 12)
        XCTAssertTrue(result.changes.first?.hasPrefix("Scaled to Height 40 mm") == true)
        XCTAssertTrue(replicaChecksFoundNoProblems(result), "a 40 mm solid cube has no thin walls and no overhangs")
        XCTAssertEqual(result.overhang.overhangAreaMM2, 0, "its base lies on the bed")
        let lines = replicaSummaryLines(result)
        XCTAssertEqual(lines.first, "Size: 40.0 × 40.0 × 40.0 mm (width × depth × height).")
        XCTAssertEqual(lines[1], "12 triangles.")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Mesh check: closed and consistent") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Overhangs: no downward faces") })
    }

    func testOverhangsStopTheNoProblemsLine() throws {
        // A solid ball has no thin walls and a closed mesh, but its underside overhangs well past 45°.
        let ball = try processReplicaModel(MeshRepairTests.sphere(levels: 2, radius: 1).binarySTL(), size: size(.longest, 40),
                                           wallThicknessSamples: samples)
        XCTAssertTrue(meshHealthIsSound(ball.health))
        XCTAssertGreaterThan(ball.overhang.fraction, replicaOverhangShareLimit)
        XCTAssertFalse(replicaChecksFoundNoProblems(ball), "overhangs count as a problem")
        XCTAssertTrue(replicaSummaryLines(ball).contains { $0.hasPrefix("Overhangs:") && $0.contains("supports") })
        XCTAssertTrue(replicaNoProblemsLine.contains("overhangs"), "the line says what was checked")
        XCTAssertTrue(replicaNoProblemsLine.contains("Strength and fit aren’t checked"))
    }

    func testPipelineRunsTwiceToTheSameBytes() throws {
        let sphere = try MeshRepairTests.sphere(levels: 2, radius: 0.05)
        let data = sphere.binarySTL()
        let first = try processReplicaModel(data, size: size(.longest, 60), triangleTarget: 150, wallThicknessSamples: samples)
        let second = try processReplicaModel(data, size: size(.longest, 60), triangleTarget: 150, wallThicknessSamples: samples)
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
        let result = try processReplicaModel(sphere.binarySTL(), size: size(.width, 30), triangleTarget: sphere.triangleCount,
                                             wallThicknessSamples: samples)
        XCTAssertFalse(result.steps.contains(.simplify))
    }

    func testUprightTurnsYUpToZUpKeepingFacesOutward() throws {
        // Y-up: 1 wide, 3 tall (Y), 2 deep (Z).
        let mesh = try box(SIMD3(1, 3, 2))
        let result = try processReplicaModel(mesh.binarySTL(), size: size(.height, 30), upAxis: .y, wallThicknessSamples: samples)
        XCTAssertEqual(result.steps, [.read, .turnUpright, .scale, .repair, .check])
        XCTAssertEqual(result.extentMM.x, 10, accuracy: 0.001)
        XCTAssertEqual(result.extentMM.y, 20, accuracy: 0.001)
        XCTAssertEqual(result.extentMM.z, 30, accuracy: 0.001)
        XCTAssertTrue(meshHealthIsSound(result.health), "a rotation keeps the faces pointing outward")
        XCTAssertEqual(result.upAxis, .y)
        let again = try processReplicaModel(mesh.binarySTL(), size: size(.height, 30), upAxis: .y, wallThicknessSamples: samples)
        XCTAssertEqual(result.stlData, again.stlData)
    }

    func testTooLargeForTheBuildVolumeSaysProcessAgain() throws {
        let tall = try box(SIMD3(1, 1, 4))
        XCTAssertThrowsError(try processReplicaModel(tall.binarySTL(), size: size(.width, 100))) { error in
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
        let result = try processReplicaModel(combined.binarySTL(), size: size(.width, 30), wallThicknessSamples: samples)
        XCTAssertTrue(result.steps.contains(.resize), "\(result.steps)")
        XCTAssertEqual(result.extentMM.x, 30, accuracy: 0.01)
        XCTAssertEqual(result.mesh.triangleCount, 12)
        XCTAssertEqual(result.mesh.minimum.z, 0, accuracy: 0.0001)
        XCTAssertTrue(result.changes.contains { $0.contains("loose fragment") })
    }

    func testUnreadableAndCancelledRunsSaveNothing() throws {
        XCTAssertThrowsError(try processReplicaModel(Data("not a model".utf8), size: size(.height, 40))) { error in
            guard case ReplicaProcessingError.unreadable? = error as? ReplicaProcessingError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try replicaReadModel(Data("glTF\u{2}\0\0\0".utf8))) { error in
            XCTAssertTrue(error.localizedDescription.contains("isn’t an STL or 3MF"), error.localizedDescription)
        }
        let cube = try MeshRepairTests.cube(size: 1)
        XCTAssertThrowsError(try processReplicaModel(cube.binarySTL(), size: size(.height, 40), isCancelled: { true })) { error in
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
        XCTAssertFalse(replicaGenerateNeedsConfirmation(lastStop: nil, modelAlreadyMade: false, earlierUnconfirmed: false))
        XCTAssertFalse(replicaGenerateNeedsConfirmation(lastStop: stop(.notSent, taskID: nil, resume: false), modelAlreadyMade: false,
                                                        earlierUnconfirmed: false))
        XCTAssertFalse(replicaGenerateNeedsConfirmation(lastStop: stop(.cancelled, taskID: nil, resume: false), modelAlreadyMade: false,
                                                        earlierUnconfirmed: false),
                       "stopped before anything was sent")
        XCTAssertTrue(replicaGenerateNeedsConfirmation(lastStop: stop(.outcomeUnknown, resume: false), modelAlreadyMade: false, earlierUnconfirmed: false))
        XCTAssertTrue(replicaGenerateNeedsConfirmation(lastStop: stop(.timedOut), modelAlreadyMade: false, earlierUnconfirmed: false))
        XCTAssertTrue(replicaGenerateNeedsConfirmation(lastStop: nil, modelAlreadyMade: true, earlierUnconfirmed: false))
        XCTAssertTrue(replicaGenerateNeedsConfirmation(lastStop: nil, modelAlreadyMade: false, earlierUnconfirmed: true),
                      "an unconfirmed request from an earlier sheet asks too")
        let message = replicaGenerateAgainMessage(lastStop: stop(.outcomeUnknown, resume: false), modelAlreadyMade: false, earlierNotice: nil,
                                                  estimate: replicaCostEstimate(service: .meshy))
        XCTAssertTrue(message.contains("task t1"))
        XCTAssertTrue(message.contains("About 20 Meshy credits"))
        XCTAssertTrue(replicaGenerateAgainMessage(lastStop: nil, modelAlreadyMade: true, earlierNotice: nil,
                                                  estimate: replicaCostEstimate(service: .tripo)).contains("Process Again"))
        XCTAssertTrue(replicaGenerateAgainMessage(lastStop: nil, modelAlreadyMade: false, earlierNotice: "Earlier notice.",
                                                  estimate: replicaCostEstimate(service: .tripo)).hasPrefix("Earlier notice. Generating again"))
        let switched = replicaGenerateAgainMessage(lastStop: stop(.timedOut), modelAlreadyMade: false, earlierNotice: nil,
                                                   estimate: replicaCostEstimate(service: .tripo))
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
            let result = await runImageTo3DGeneration(provider: client, image: self.jpeg, options: replicaGenerationOptions(for: .meshy, purpose: .functional),
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
            box.set(await runImageTo3DGeneration(provider: client, image: self.jpeg, options: replicaGenerationOptions(for: .meshy, purpose: .functional),
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
                                                  options: replicaGenerationOptions(for: .meshy, purpose: .functional), sleep: { _ in },
                                                  makeFolder: { try self.makeFolder() })
        guard case .success(let model) = result else { return XCTFail("\(result)") }
        let processed = try processReplicaModel(Data(contentsOf: model.fileURL), size: size(.height, 25), wallThicknessSamples: samples)
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

    // MARK: Resume, close and session records

    func testResumeNotesSayWhatIsCharged() {
        let tripoWaiting = ImageTo3DStop(reason: .timedOut, stage: .generating, service: .tripo, taskID: "g1", detail: "",
                                         resumePoint: ImageTo3DResumePoint(sourceTaskID: "g1", sourceKind: .generation, conversionTaskID: nil))
        let note = replicaResumeNote(tripoWaiting, action: .keepWaiting)
        XCTAssertFalse(note.contains("Nothing new is made or charged"), "Tripo's conversion is still to be sent")
        XCTAssertTrue(note.contains("about \(tripoConvertBasicCredits) Tripo credits"), note)
        let converting = ImageTo3DStop(reason: .timedOut, stage: .converting, service: .tripo, taskID: "c1", detail: "",
                                       resumePoint: ImageTo3DResumePoint(sourceTaskID: "g1", sourceKind: .generation, conversionTaskID: "c1"))
        XCTAssertTrue(replicaResumeNote(converting, action: .keepWaiting).contains("Nothing new is made or charged"))
        XCTAssertTrue(replicaResumeNote(stop(.timedOut), action: .keepWaiting).contains("Nothing new is made or charged"), "Meshy makes STL itself")
        XCTAssertTrue(replicaResumeNote(stop(.conversionRefused, stage: .converting), action: .tryConversionAgain).contains("costs about"))
    }

    func testCloseAsksAfterAPossibleSpend() {
        XCTAssertNil(replicaCloseWarning(hasUnsavedModel: false, lastStop: nil, service: .meshy))
        XCTAssertNil(replicaCloseWarning(hasUnsavedModel: false, lastStop: stop(.notSent, taskID: nil, resume: false), service: .meshy))
        XCTAssertEqual(replicaCloseWarning(hasUnsavedModel: true, lastStop: nil, service: .meshy)?.confirmTitle, "Close Without Saving")
        let unknown = replicaCloseWarning(hasUnsavedModel: false, lastStop: stop(.outcomeUnknown, resume: false), service: .meshy)
        XCTAssertNotNil(unknown, "an unknown create may have spent credits")
        XCTAssertTrue(unknown?.message.contains("task t1") == true)
        let waiting = replicaCloseWarning(hasUnsavedModel: false, lastStop: stop(.timedOut), service: .meshy)
        XCTAssertTrue(waiting?.message.contains("can’t Keep Waiting") == true, waiting?.message ?? "")
    }

    @MainActor func testUnconfirmedRequestsLastTheSessionAndAreConfirmedByDelivery() {
        let connection = makeTestConnection()
        XCTAssertNil(connection.rememberUnconfirmed(stop(.notSent, taskID: nil, resume: false)), "nothing was spent")
        XCTAssertNil(connection.rememberUnconfirmed(stop(.cancelled, taskID: nil, resume: false)), "stopped before sending")
        XCTAssertNil(connection.rememberUnconfirmed(stop(.taskEnded(.failed), resume: false)), "nothing to duplicate")
        let time = Date(timeIntervalSince1970: 0)
        let unknown = ImageTo3DStop(reason: .outcomeUnknown, stage: .sending, service: .tripo, taskID: nil, detail: "")
        let first = connection.rememberUnconfirmed(unknown, at: time)
        XCTAssertNotNil(first)
        XCTAssertTrue(connection.hasUnconfirmedRequests)
        connection.rememberUnconfirmed(stop(.timedOut), at: time)
        connection.rememberUnconfirmed(stop(.statusUnreadable), at: time)
        XCTAssertEqual(connection.unconfirmedRequests.count, 2, "a later stop of the same task replaces its record")
        let notice = replicaUnconfirmedNotice(connection.unconfirmedRequests, overflowed: false, timeText: { _ in "09:00" })
        XCTAssertEqual(notice, "Studio couldn’t confirm what happened to Meshy at 09:00 (task t1) and Tripo at 09:00 this session. They may have spent credits, and a finished model may be waiting there: check each service’s dashboard before generating again.")
        XCTAssertTrue(replicaUnconfirmedNotice(connection.unconfirmedRequests, overflowed: false, excluding: first,
                                               timeText: { _ in "09:00" })?.contains("check Meshy’s dashboard") == true)
        connection.confirmDelivered(service: .meshy, sourceTaskID: "t1")
        XCTAssertEqual(connection.unconfirmedRequests.map(\.service), [.tripo], "an unknown create is never confirmed by another task")
        for index in 0..<imageTo3DUnconfirmedRequestLimit {
            connection.rememberUnconfirmed(ImageTo3DStop(reason: .timedOut, stage: .generating, service: .meshy, taskID: "x\(index)", detail: ""))
        }
        XCTAssertEqual(connection.unconfirmedRequests.count, imageTo3DUnconfirmedRequestLimit)
        XCTAssertTrue(connection.unconfirmedRequestsOverflowed)
        for index in 0..<imageTo3DUnconfirmedRequestLimit { connection.confirmDelivered(service: .meshy, sourceTaskID: "x\(index)") }
        XCTAssertTrue(connection.unconfirmedRequests.isEmpty)
        XCTAssertTrue(connection.hasUnconfirmedRequests, "a record that dropped off keeps the guard")
        XCTAssertTrue(replicaUnconfirmedNotice([], overflowed: true)?.contains("earlier requests") == true)
    }

    // MARK: The sheet's session

    @MainActor private func waitFor(_ session: ReplicaGeneratorSession, _ phases: [ReplicaGeneratorSession.Phase],
                                    file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = Date().addingTimeInterval(20)
        while !phases.contains(session.phase) {
            guard Date() < deadline else { return XCTFail("still \(session.phase)", file: file, line: line) }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    @MainActor private func makeTestConnection() -> ImageTo3DConnection {
        ImageTo3DConnection(defaults: UserDefaults(suiteName: "replica-tests-\(UUID().uuidString)")!)
    }

    private var cat: ReplicaInputs { ReplicaInputs(name: "Cat", size: size(.height, 25), purpose: .functional) }
    private let meshyFinished = #"{"id":"t1","status":"SUCCEEDED","progress":100,"model_urls":{"stl":"https://assets.meshy.ai/t1/model.stl"}}"#

    // MARK: Round 8: accuracy

    func testHigherParseLimitOnlyOnTheReplicaPath() throws {
        XCTAssertEqual(STLMesh.maximumTriangles, 500_000, "the library's limit is unchanged")
        XCTAssertGreaterThanOrEqual(replicaMaximumModelTriangles, 2_600_000, "everything a 128 MB download can hold as binary STL")
        XCTAssertLessThanOrEqual(Int64(replicaMaximumModelTriangles) * 50, imageTo3DMaxDownloadBytes)
        let cube = try MeshRepairTests.cube(size: 1)
        XCTAssertThrowsError(try STLMesh.parse(cube.binarySTL(), maximumTriangles: 11))
        XCTAssertEqual(try STLMesh.parse(cube.binarySTL(), maximumTriangles: 12).triangleCount, 12)
        XCTAssertThrowsError(try cube.scaledSTLData(by: 2, maximumTriangles: 11))
        XCTAssertEqual(MeshRepairOptions().maximumTriangles, STLMesh.maximumTriangles)
        var tight = MeshRepairOptions()
        tight.maximumTriangles = 11
        XCTAssertThrowsError(try repairMesh(cube, options: tight)) { XCTAssertEqual($0 as? MeshToolError, .tooLarge) }

        // 500,001 copies of one triangle: the library refuses the file, the replica pipeline reads it.
        var data = Data(count: 80)
        var count = UInt32(500_001).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        var record = Data(count: 12)
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { record.append(contentsOf: $0) }
        }
        record.append(contentsOf: [0, 0])
        data.append(Data(repeating: 0, count: 0))
        data.reserveCapacity(84 + 500_001 * 50)
        for _ in 0..<500_001 { data.append(record) }
        XCTAssertThrowsError(try parsePreviewModel(data, format: .stl)) {
            guard case STLMesh.ParseError.oversized = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try replicaReadModel(data).triangleCount, 500_001)
    }

    func testTriangleCornerKeysDontCollideAboveTwoToTheTwentyOne() {
        // The old packing, (a << 42) | (b << 21) | c, gave these two the same key.
        let big = Int32(1 << 21) + 5
        let first = meshTriangleCornerKey(SIMD3(0, 1, big)), second = meshTriangleCornerKey(SIMD3(0, 2, 5))
        XCTAssertNotEqual(first.key, second.key)
        XCTAssertLessThan(first.key, second.key, "ordered as (a, b, c)")
        // Rotations match; the opposite winding has the same key, the other direction.
        let t = SIMD3<Int32>(3_000_000, 2_500_001, 2_900_000)
        XCTAssertEqual(meshTriangleCornerKey(t).key, meshTriangleCornerKey(SIMD3(t.y, t.z, t.x)).key)
        XCTAssertEqual(meshTriangleCornerKey(t).key, meshTriangleCornerKey(SIMD3(t.x, t.z, t.y)).key)
        XCTAssertNotEqual(meshTriangleCornerKey(t).forward, meshTriangleCornerKey(SIMD3(t.x, t.z, t.y)).forward)
        XCTAssertNotEqual(meshTriangleCornerKey(SIMD3(0, 1, Int32.max)).key, meshTriangleCornerKey(SIMD3(0, 1, Int32.max - 1)).key)
    }

    func testEdgeKeysDontOverflowAboveTwoToTheTwentyTwo() {
        // MeshHealth packs edges as `meshDirectedEdgeKey`: 32 bits a vertex.
        let low = Int32(1 << 22) + 7, high = Int32(1 << 23) + 1
        XCTAssertNotEqual(meshDirectedEdgeKey(low, high) >> 1, meshDirectedEdgeKey(low, high + 1) >> 1)
        XCTAssertNotEqual(meshDirectedEdgeKey(low, high) >> 1, meshDirectedEdgeKey(low + 1, high) >> 1)
        XCTAssertEqual(meshDirectedEdgeKey(low, high) >> 1, meshDirectedEdgeKey(high, low) >> 1, "one edge, either way")
        XCTAssertNotEqual(meshDirectedEdgeKey(low, high) & 1, meshDirectedEdgeKey(high, low) & 1)
        XCTAssertLessThan(meshDirectedEdgeKey(5, Int32.max), meshDirectedEdgeKey(6, 7), "ordered by the lower vertex first")
    }

    func testAModelTooLargeToReadIsFinalAndSaysWhatToDo() throws {
        let cube = try MeshRepairTests.cube(size: 1).binarySTL()
        XCTAssertThrowsError(try replicaReadModel(cube, maximumTriangles: 11)) {
            XCTAssertEqual($0 as? ReplicaProcessingError, .modelTooLarge)
        }
        let stop = ImageTo3DStop(reason: .modelTooLarge, stage: .downloading, service: .tripo, taskID: "conv", detail: "")
        XCTAssertNil(replicaResumeAction(for: stop))
        XCTAssertTrue(stop.userMessage.contains("Tripo’s dashboard"))
        XCTAssertFalse(stop.userMessage.contains("3 days"), "Meshy's retention only")
        XCTAssertFalse(replicaProcessingFailureAllowsProcessAgain(ReplicaProcessingError.tooDetailed(triangles: 600_000)))
        XCTAssertFalse(replicaProcessingFailureAllowsProcessAgain(ReplicaProcessingError.modelTooLarge))
        XCTAssertTrue(replicaProcessingFailureAllowsProcessAgain(ReplicaProcessingError.flat(.height)))
        XCTAssertTrue(replicaProcessingFailureAllowsProcessAgain(MeshToolError.cancelled))
        let message = ReplicaProcessingError.tooDetailed(triangles: 600_000).localizedDescription
        XCTAssertTrue(message.contains("without Higher detail"))
        XCTAssertTrue(message.contains("dashboard"))
        XCTAssertFalse(message.contains("Process Again"))
    }

    func testFooterCostAndButtonTitles() {
        XCTAssertEqual(replicaFooterCostLabel(replicaCostEstimate(service: .meshy, purpose: .display, higherDetail: true)), "About 25 Meshy credits")
        XCTAssertEqual(replicaFooterCostLabel(replicaCostEstimate(service: .tripo)), "About 25 Tripo credits")
        XCTAssertEqual(replicaGenerateButtonTitle(firstRequest: true), "Generate Replica")
        XCTAssertEqual(replicaGenerateButtonTitle(firstRequest: false), "Generate Again…")
        XCTAssertTrue(replicaPlanChangedMessage(buttonTitle: "Generate Again…").hasSuffix("choose Generate Again… again."))
    }

    func testAFailedReplacementLeavesNoPhotoToSend() {
        let failed = ReplicaPhotoSlot.failed("That photo couldn’t be read.")
        XCTAssertNil(failed.image)
        XCTAssertNil(failed.preview)
        XCTAssertNil(failed.name)
        XCTAssertEqual(failed.problem, "That photo couldn’t be read.")
        XCTAssertFalse(failed.preparing)
    }

    func testAResultTooDetailedForTheLibraryIsRefused() throws {
        let cube = try MeshRepairTests.cube(size: 0.02)
        XCTAssertThrowsError(try processReplicaModel(mesh: cube, size: size(.height, 40), wallThicknessSamples: samples,
                                                     savedTriangleLimit: 10)) {
            XCTAssertEqual($0 as? ReplicaProcessingError, .tooDetailed(triangles: 12))
        }
        XCTAssertTrue(ReplicaProcessingError.tooDetailed(triangles: 600_000).localizedDescription.contains("nothing was saved"))
    }

    func testDetailedMeshSimplifiesToTheLimitToTheSameBytes() throws {
        let sphere = try MeshRepairTests.sphere(levels: 4, radius: 0.04)
        let data = sphere.binarySTL()
        let first = try processReplicaModel(data, size: size(.longest, 50), triangleTarget: 1_000, wallThicknessSamples: samples)
        let second = try processReplicaModel(data, size: size(.longest, 50), triangleTarget: 1_000, wallThicknessSamples: samples)
        XCTAssertEqual(first.stlData, second.stlData)
        XCTAssertLessThanOrEqual(first.mesh.triangleCount, 1_000)
        XCTAssertTrue(meshHealthIsSound(first.health))
        let deviation = try XCTUnwrap(first.simplifiedDeviationMM)
        XCTAssertGreaterThan(deviation, 0)
        XCTAssertTrue(replicaSummaryLines(first).contains(replicaSimplifiedDeviationLine(deviation)),
                      "the estimate is a result fact, not only in the collapsed list")
        let unsimplified = try processReplicaModel(MeshRepairTests.cube(size: 0.02).binarySTL(), size: size(.height, 40),
                                                   wallThicknessSamples: samples)
        XCTAssertNil(unsimplified.simplifiedDeviationMM)
        XCTAssertFalse(replicaSummaryLines(unsimplified).contains { $0.hasPrefix("Simplifying moved") })
        XCTAssertEqual(replicaSimplifiedDeviationLine(0.004), "Simplifying moved the surface by an estimated 0.01 mm or less. Check fine details before ordering.")
        XCTAssertTrue(replicaSimplifiedDeviationLine(0.123).contains("by an estimated 0.12 mm."))
        XCTAssertFalse(first.changes.contains { $0.contains("Estimated largest surface change") }, "not repeated in What Studio changed")
        XCTAssertTrue(first.changes.contains { $0.hasPrefix("Reduced ") })
    }

    func testPhotoGuidanceAndCoverage() {
        XCTAssertTrue(replicaPhotoAdvice.contains("same object, lighting and plain background"))
        XCTAssertTrue(replicaPhotoAdvice.contains("plain background"))
        XCTAssertTrue(replicaPhotoDistanceAdvice.contains("Step back and zoom in"))
        XCTAssertEqual(replicaPhotoSideAdvice, "Take each side photo a quarter turn from the front, straight on, at the same distance.")
        XCTAssertEqual(ImageTo3DPhotoView.allCases.map(replicaPhotoSlotLabel),
                       ["Front (required)", "Left side (its left)", "Back", "Right side (its right)"])
        XCTAssertEqual(replicaPhotoSlotHelp(.left), "Its left is on your right when you face its front.")
        XCTAssertNil(replicaPhotoSlotHelp(.front))
        XCTAssertTrue(replicaPhotoPickerMessage(.left).contains("Its left is on your right when you face its front."))
        XCTAssertTrue(replicaPhotoPickerMessage(.right).contains("a quarter turn from the front"))
        XCTAssertEqual(replicaPhotoCoverageFinding([.front]),
                       "Made from one photo, so the sides the photo didn’t show (back, underside) are the service’s guess.")
        XCTAssertEqual(replicaPhotoCoverageFinding([.back, .front]),
                       "Made from 2 photos (front and back), so what they didn’t show (left side, right side and underside) is the service’s guess.")
        let context = replicaPrintReviewContext(service: .meshy, size: size(.height, 40), purpose: .display, meshyReport: nil,
                                                views: [.front, .left, .back, .right])
        XCTAssertTrue(context.findings[0].hasPrefix("Made from 4 photos"))
        XCTAssertEqual(replicaSavedActivityDetail(service: .tripo, triangles: 1_000, estimate: nil, photoCount: 3),
                       "Tripo: saved, 3 photos, 1,000 triangles")
        XCTAssertEqual(replicaGenerateBlockedReasons(photoReady: false, photoPreparing: false, nameText: "A", sizeText: "50",
                                                     service: .meshy, hasKey: true, extraPhotosWithoutFront: true),
                       ["Add a front photo: the other views go with it."])
    }

    func testRequestPlanNoticesAChange() {
        let plan = ReplicaRequestPlan(service: .meshy, views: [.front, .back], higherDetail: false,
                                      credits: replicaCostEstimate(service: .meshy, purpose: .display, photoCount: 2).credits)
        let ticked = ReplicaRequestPlan(service: .meshy, views: [.front, .back], higherDetail: true,
                                        credits: replicaCostEstimate(service: .meshy, purpose: .display, photoCount: 2, higherDetail: true).credits)
        XCTAssertNotEqual(plan, ticked, "Higher detail ticked after the cost was shown")
        XCTAssertEqual(ticked.credits, plan.credits + meshyHigherDetailCredits)
        XCTAssertNotEqual(plan, ReplicaRequestPlan(service: .tripo, views: [.front, .back], higherDetail: false,
                                                   credits: plan.credits), "another service")
        XCTAssertNotEqual(plan, ReplicaRequestPlan(service: .meshy, views: [.front], higherDetail: false,
                                                   credits: plan.credits), "a photo removed")
    }

    @MainActor func testSessionSendsSeveralPhotosOnceAndKeepsTheirViews() async throws {
        let transport = ReplicaScriptedTransport([(202, #"{"result":"t1"}"#),
                                                  (200, meshyFinished)],
                                                 modelData: try MeshRepairTests.cube(size: 0.05).binarySTL())
        let connection = makeTestConnection()
        let host = ReplicaTestHost()
        let session = ReplicaGeneratorSession(connection: connection, wallThicknessSamples: samples)
        let views = [ImageTo3DViewImage(view: .back, image: jpeg), ImageTo3DViewImage(view: .front, image: jpeg)]
        let figure = ReplicaInputs(name: "Cat", size: size(.height, 25), purpose: .display)
        session.start(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), views: views, inputs: figure,
                      higherDetail: true, host: host)
        try await waitFor(session, [.processed, .stopped, .processingFailed])
        XCTAssertEqual(session.phase, .processed, "\(String(describing: session.lastStop))")
        XCTAssertEqual(transport.posts, 1)
        XCTAssertEqual(transport.requests.first?.url?.path, "/openapi/v1/multi-image-to-3d")
        XCTAssertEqual(transport.requests.dropFirst().first?.url?.path, "/openapi/v1/multi-image-to-3d/t1")
        XCTAssertEqual(session.generated?.views, [.front, .back])
        XCTAssertEqual(session.generated?.sourceKind, .multiImageGeneration)
        XCTAssertEqual(session.estimate?.credits, 25)
        let sent = (transport.requests.first?.httpBody).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        XCTAssertEqual(sent?["geometry_resolution"] as? String, "2k")
        XCTAssertEqual(sent?["image_enhancement"] as? Bool, false)
        session.save(inputs: figure, host: host)
        XCTAssertEqual(host.activities.last?.detail.contains("2 photos"), true)
    }

    @MainActor func testSessionGeneratesDownloadsProcessesThenSavesOnce() async throws {
        // Regression: the session used to stay in "generating" for ever after a successful download.
        let transport = ReplicaScriptedTransport([(202, #"{"result":"t1"}"#), (200, meshyFinished)],
                                                 modelData: try MeshRepairTests.cube(size: 0.05).binarySTL())
        let connection = makeTestConnection()
        let host = ReplicaTestHost()
        let session = ReplicaGeneratorSession(connection: connection, wallThicknessSamples: samples)
        session.start(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), image: jpeg, inputs: cat, host: host)
        XCTAssertEqual(session.phase, .generating)
        try await waitFor(session, [.processed, .stopped, .processingFailed])
        XCTAssertEqual(session.phase, .processed, "\(String(describing: session.lastStop)) \(session.processingProblem ?? "")")
        XCTAssertEqual(Double(session.processed?.extentMM.z ?? 0), 25, accuracy: 0.001)
        XCTAssertTrue(host.imported.isEmpty, "nothing is saved before the seller has seen it")
        XCTAssertTrue(session.hasUnsavedModel)
        XCTAssertEqual(connection.activeWork, 0)

        // Which way is up: processed again from memory, free.
        session.process(inputs: cat, upAxis: .y)
        XCTAssertEqual(session.phase, .processing)
        try await waitFor(session, [.processed, .processingFailed])
        XCTAssertEqual(session.processed?.upAxis, .y)
        XCTAssertEqual(transport.posts, 1, "processing again sends nothing")
        XCTAssertEqual(transport.downloads.count, 1)

        let changed = ReplicaInputs(name: "Cat", size: size(.height, 30), purpose: .functional)
        XCTAssertFalse(session.canSave(changed), "a result made from other details isn't saved")
        session.save(inputs: changed, host: host)
        XCTAssertTrue(host.imported.isEmpty)

        session.save(inputs: cat, host: host)
        XCTAssertEqual(session.phase, .saved)
        XCTAssertEqual(host.imported, ["Cat (replica).stl"])
        XCTAssertEqual(session.savedModelIDs.count, 1)
        XCTAssertFalse(session.hasUnsavedModel)
        XCTAssertEqual(host.activities.last?.success, true)
        session.save(inputs: cat, host: host)
        session.process(inputs: cat, upAxis: .z)
        XCTAssertEqual(host.imported.count, 1, "one copy only")
        XCTAssertEqual(session.phase, .saved)
        XCTAssertTrue(connection.unconfirmedRequests.isEmpty)
    }

    @MainActor func testSessionRemembersAnUnknownCreateForTheNextSheet() async throws {
        let transport = ReplicaScriptedTransport([(503, #"{"message":"busy"}"#)])
        let connection = makeTestConnection()
        let host = ReplicaTestHost()
        let session = ReplicaGeneratorSession(connection: connection, wallThicknessSamples: samples)
        session.start(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), image: jpeg, inputs: cat, host: host)
        try await waitFor(session, [.stopped])
        XCTAssertEqual(session.lastStop?.reason, .outcomeUnknown)
        XCTAssertNil(session.lastStop.flatMap(replicaResumeAction(for:)))
        XCTAssertEqual(connection.unconfirmedRequests.count, 1)
        XCTAssertEqual(session.lastStopRecordID, connection.unconfirmedRequests.first?.id)
        XCTAssertNil(replicaUnconfirmedNotice(connection.unconfirmedRequests, overflowed: false, excluding: session.lastStopRecordID),
                     "the stop view already explains it")
        XCTAssertNotNil(replicaCloseWarning(hasUnsavedModel: session.hasUnsavedModel, lastStop: session.lastStop, service: session.service))
        session.cancelAll()

        // A newly opened sheet: nothing of its own, but Generate still asks, and the notice names the request.
        let next = ReplicaGeneratorSession(connection: connection)
        XCTAssertTrue(replicaGenerateNeedsConfirmation(lastStop: next.lastStop, modelAlreadyMade: next.generated != nil,
                                                       earlierUnconfirmed: connection.hasUnconfirmedRequests))
        XCTAssertTrue(replicaUnconfirmedNotice(connection.unconfirmedRequests, overflowed: false)?.contains("Meshy at") == true)
        XCTAssertEqual(transport.posts, 1)
    }

    @MainActor func testClosingMidCreateIsRemembered() async throws {
        let transport = ReplicaHangingTransport()
        let connection = makeTestConnection()
        let session = ReplicaGeneratorSession(connection: connection, wallThicknessSamples: samples)
        session.start(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), image: jpeg, inputs: cat, host: ReplicaTestHost())
        let deadline = Date().addingTimeInterval(10)
        while !transport.started, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertTrue(transport.started)
        session.cancelAll()  // the sheet closed while the create was on its way
        while connection.unconfirmedRequests.isEmpty, Date() < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
        XCTAssertEqual(connection.unconfirmedRequests.count, 1, "the create may have gone through")
        XCTAssertEqual(connection.unconfirmedRequests.first?.service, .meshy)
        XCTAssertNil(connection.unconfirmedRequests.first?.taskID)
        XCTAssertEqual(connection.activeWork, 0)
    }

    @MainActor func testDownloadedFileIsCheckedByItsContent() async throws {
        let transport = ReplicaScriptedTransport([(202, #"{"result":"t1"}"#), (200, meshyFinished)], modelData: Data("glTF\u{2}\0\0\0rest".utf8))
        let connection = makeTestConnection()
        let host = ReplicaTestHost()
        let session = ReplicaGeneratorSession(connection: connection, wallThicknessSamples: samples)
        session.start(provider: MeshyClient(apiKey: "msy_secretkey1", transport: transport), image: jpeg, inputs: cat, host: host)
        try await waitFor(session, [.stopped, .processed, .processingFailed])
        XCTAssertEqual(session.phase, .stopped)
        XCTAssertEqual(session.lastStop?.reason, .downloadFailed)
        XCTAssertEqual(session.lastStop.flatMap(replicaResumeAction(for:)), .tryDownloadAgain, "paid for, so it can be fetched again")
        XCTAssertEqual(connection.unconfirmedRequests.count, 1)
        XCTAssertNil(session.generated)
        XCTAssertEqual(host.activities.last?.success, false)
        session.cancelAll()
    }

    func testTripoLinkWithoutAnExtensionIsAccepted() {
        let client = TripoClient(apiKey: "tsk_secretkey1", transport: ReplicaScriptedTransport([]))
        let status = ImageTo3DTaskStatus(taskID: "c1", state: .succeeded, modelURLs: ["bin": URL(string: "https://cdn.tripo3d.ai/o/abc.bin")!])
        XCTAssertEqual(client.modelLink(in: status, kind: .conversion, preferred: .stl)?.format, .stl)
        XCTAssertNil(client.modelLink(in: status, kind: .generation, preferred: .stl), "a generation is GLB only")
        XCTAssertEqual(imageTo3DDetectedFormat(Data([0x50, 0x4B, 0x03, 0x04, 0])), .threeMF)
        XCTAssertNil(imageTo3DDetectedFormat(Data("glTF".utf8)))
        XCTAssertNil(imageTo3DDetectedFormat(Data()))
        XCTAssertEqual(imageTo3DDetectedFormat(Data("solid x\n".utf8)), .stl)
    }
}

/// Stands in for the store: records imports by file name (the file must be a readable STL when imported) and Activity.
@MainActor private final class ReplicaTestHost: ReplicaLibraryHost {
    private(set) var imported: [String] = []
    private(set) var activities: [Activity] = []

    func addReplicaActivity(_ activity: Activity) { activities.append(activity) }

    func importReplica(_ url: URL, intent: PartIntent?, sourceDetails: ModelSourceDetails) -> UUID? {
        guard (try? STLMesh.parse(Data(contentsOf: url))) != nil else { return nil }
        imported.append(url.lastPathComponent)
        return UUID()
    }
}

/// A create that never answers until it is cancelled.
private final class ReplicaHangingTransport: ImageTo3DTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var didStart = false
    var started: Bool { lock.withLock { didStart } }

    func send(_ request: URLRequest) async throws -> ImageTo3DHTTPReply {
        lock.withLock { didStart = true }
        try await Task.sleep(nanoseconds: 30_000_000_000)
        throw ImageTo3DError.transport("No reply")
    }

    func download(_ url: URL, into folder: URL, fileName: String, maxBytes: Int64) async throws -> URL {
        throw ImageTo3DError.downloadRefused("Not used")
    }
}
