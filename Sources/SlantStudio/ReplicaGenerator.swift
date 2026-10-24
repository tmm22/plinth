import Foundation
import simd

// MARK: - Generate a Replica from an Image
//
// One photo goes to the seller's chosen 3D service (Meshy or Tripo3D, ImageTo3D.swift), which makes a mesh. Studio
// then works on this Mac only, in a fixed order: read the file, (optionally) stand it upright, scale it to the real
// size the seller typed (neither service knows it), repair, simplify to Reinforce's 20,000-triangle limit when larger,
// fit the size again if repair removed fragments, then check it. One library copy, "<name> (replica)", is saved.
//
// Rules this file keeps:
//   - The generation is sent once and never retried. Stop never interrupts a request that may spend credits: it takes
//     effect while Studio waits between status reads, after a status read, or during the download
//     (`ReplicaRunControl`). An unknown create outcome sends the seller to the service's dashboard, with no resume.
//   - Generating again after anything that may have spent credits needs an explicit confirmation.
//   - Photos, names, sizes and the downloaded model stay in memory with the sheet; temporary files live in
//     `SlantStudio-Replica-…` folders (removed after the import, and at launch). Activity gets service, status,
//     counts and credits only.
//   - Everything geometric is deterministic: the wave-1 mesh tools walk index order, and so does this file.

/// Temporary folders for the replica on its way into the library; listed in `personalisationTempFolderPrefixes`.
let replicaTempFolderPrefix = "SlantStudio-Replica-"
/// The smallest real size accepted: smaller replicas lose almost all detail on an FDM printer.
let replicaMinimumSizeMM = 5.0
/// The triangle budget asked of the service and kept after simplifying (Reinforce and Auto-improve's limit).
let replicaTriangleTarget = imageTo3DDefaultTriangleTarget
/// Repair or simplify may remove loose fragments and change the size; beyond this share Studio fits the size again.
let replicaResizeTolerance = 0.001

// MARK: Inputs

enum ReplicaSizeAxis: String, CaseIterable, Identifiable, Sendable {
    case height = "Height", width = "Width", depth = "Depth", longest = "Longest side"

    var id: String { rawValue }

    var meshFitAxis: MeshFitAxis {
        switch self {
        case .height: return .z
        case .width: return .x
        case .depth: return .y
        case .longest: return .longest
        }
    }

    /// The axis's share of an extent, in millimetres.
    func length(of extent: SIMD3<Float>) -> Float {
        switch self {
        case .height: return extent.z
        case .width: return extent.x
        case .depth: return extent.y
        case .longest: return extent.max()
        }
    }
}

/// The real size the seller typed: one axis and its length in millimetres.
struct ReplicaSize: Equatable, Sendable {
    let axis: ReplicaSizeAxis
    let millimetres: Double

    var millimetreText: String { String(format: "%g", (millimetres * 100).rounded() / 100) }
    /// "Height 120 mm".
    var label: String { "\(axis.rawValue) \(millimetreText) mm" }
    /// For Review for Printing: "Height should be 120 mm (typed by the seller)".
    var reviewNote: String { "\(axis.rawValue) should be \(millimetreText) mm (typed by the seller)" }
}

/// Why the typed size can't be used, or nil.
func replicaSizeProblem(_ text: String) -> String? {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return "Enter the real size in millimetres." }
    guard let value = meshFitMillimetres(text) else { return "Enter the size as a number of millimetres, such as 120 or 85.5." }
    if value < replicaMinimumSizeMM { return "Enter at least \(String(format: "%g", replicaMinimumSizeMM)) mm: smaller replicas lose their detail." }
    if value > Double(slantBuildVolumeMM) {
        return "Enter at most \(Int(slantBuildVolumeMM)) mm: Slant’s build volume is \(Int(slantBuildVolumeMM)) mm on each side."
    }
    return nil
}

/// The typed size, or nil when `replicaSizeProblem` has something to say.
func replicaSize(axis: ReplicaSizeAxis, text: String) -> ReplicaSize? {
    guard replicaSizeProblem(text) == nil, let value = meshFitMillimetres(text) else { return nil }
    return ReplicaSize(axis: axis, millimetres: value)
}

enum ReplicaPurpose: String, CaseIterable, Identifiable, Sendable {
    case display = "Display piece", functional = "Functional part"
    var id: String { rawValue }

    /// A display piece starts the library's print intent as decorative; a functional part needs the seller's load
    /// direction, so it's left for them to set.
    var partIntent: PartIntent? { self == .display ? PartIntent(purpose: .decorative) : nil }
}

/// What the seller typed, checked: used for processing and the review hand-off. Memory only.
struct ReplicaInputs: Equatable, Sendable {
    let name: String
    let size: ReplicaSize
    let purpose: ReplicaPurpose
}

/// The inputs when all of them are valid, else nil.
func replicaInputs(name: String, axis: ReplicaSizeAxis, sizeText: String, purpose: ReplicaPurpose) -> ReplicaInputs? {
    guard replicaNameProblem(name) == nil, let size = replicaSize(axis: axis, text: sizeText) else { return nil }
    return ReplicaInputs(name: name.trimmingCharacters(in: .whitespacesAndNewlines), size: size, purpose: purpose)
}

/// The library name's suffix.
let replicaNameSuffix = " (replica)"
let replicaUprightNameSuffix = " (replica, upright)"

/// Why the name can't be used, or nil. Room is left for the suffix within the library's name limit.
func replicaNameProblem(_ name: String) -> String? {
    if let problem = modelNameProblem(name) { return problem }
    let limit = maximumModelNameLength - replicaUprightNameSuffix.count
    if name.trimmingCharacters(in: .whitespacesAndNewlines).count > limit { return "Names can be at most \(limit) characters here." }
    if name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))).isEmpty {
        return "Enter a name with letters or numbers."
    }
    return nil
}

/// "Dragon (replica)": trimmed, without leading full stops (which would hide the temporary file).
func replicaCopyName(_ name: String, upright: Bool = false) -> String {
    var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasPrefix(".") { base.removeFirst() }
    base = base.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { base = "Model" }
    return base + (upright ? replicaUprightNameSuffix : replicaNameSuffix)
}

/// What the service is asked for. Mesh only, STL, 20,000 triangles. The origin option is kept for Meshy (free) and
/// left off for Tripo, where it makes the conversion cost 10 credits instead of 5: Studio places the model itself.
func replicaGenerationOptions(for service: ImageTo3DService) -> ImageTo3DOptions {
    var options = ImageTo3DOptions()
    options.targetTriangles = replicaTriangleTarget
    options.format = .stl
    options.originAtBottom = service == .meshy
    return options
}

/// A transport that never sends: lets Studio ask a client for its published price without reading the Keychain.
private struct ReplicaOfflineTransport: ImageTo3DTransport {
    func send(_ request: URLRequest) async throws -> ImageTo3DHTTPReply {
        throw ImageTo3DError.invalidInput("Not sent.")
    }
    func download(_ url: URL, into folder: URL, fileName: String, maxBytes: Int64) async throws -> URL {
        throw ImageTo3DError.downloadRefused("Not sent.")
    }
}

/// The published price of a replica with `service`, before anything is sent. No key is read.
func replicaCostEstimate(service: ImageTo3DService, tripoRegion: TripoRegion = .international) -> ImageTo3DCostEstimate {
    makeImageTo3DProvider(service, key: "", tripoRegion: tripoRegion, transport: ReplicaOfflineTransport())
        .estimatedCost(for: replicaGenerationOptions(for: service))
}

/// What still stops Generate Replica, in the order the sheet shows them. Empty when it can start.
func replicaGenerateBlockedReasons(photoReady: Bool, photoPreparing: Bool, nameText: String, sizeText: String,
                                   service: ImageTo3DService, hasKey: Bool) -> [String] {
    var reasons: [String] = []
    if photoPreparing { reasons.append("Wait while Studio prepares the photo.") }
    else if !photoReady { reasons.append("Choose a photo of the object.") }
    if let problem = replicaNameProblem(nameText) { reasons.append(problem == "Enter a name." ? "Enter a name for the replica." : problem) }
    if let problem = replicaSizeProblem(sizeText) { reasons.append(problem) }
    if !hasKey { reasons.append("Add your \(service.title) API key in Settings › Design Tools › 3D generation.") }
    return reasons
}

let replicaPhotoAdvice = "Use one clear photo of the object on its own: even light, a plain background, nothing in front of it, seen from slightly above. The service guesses the sides it can’t see."
let replicaRightsNote = "Make replicas only of objects you have the right to copy. Other people’s designs, characters and trademarks stay theirs."

// MARK: Stopping safely

/// Shared between the sheet (main actor) and the generation's progress reports (any thread). Stop is honoured only
/// where no credit-spending request can be in flight: while waiting between status reads (`sleep`), right after a
/// status read, or during the download. A create in flight is always allowed to answer, so its outcome is known.
final class ReplicaRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var stopRequested = false
    private var cancelled = false
    private var last: ImageTo3DProgress?
    private var task: Task<Void, Never>?

    var isStopRequested: Bool { lock.withLock { stopRequested } }
    var lastProgress: ImageTo3DProgress? { lock.withLock { last } }

    func attach(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    /// The progress callback: records the report and, when Stop was asked for, cancels at this safe point.
    func report(_ progress: ImageTo3DProgress) {
        let toCancel: Task<Void, Never>? = lock.withLock {
            last = progress
            guard stopRequested, replicaProgressAllowsStop(progress), !cancelled else { return nil }
            cancelled = true
            return task
        }
        toCancel?.cancel()
    }

    /// Asks the run to stop at the next safe point. During a download that's now.
    func requestStop() {
        let toCancel: Task<Void, Never>? = lock.withLock {
            stopRequested = true
            guard !cancelled, replicaStopCancelsAtOnce(last: last) else { return nil }
            cancelled = true
            return task
        }
        toCancel?.cancel()
    }

    /// Cancels everything at once (the sheet closed). A create in flight then has an unknown outcome.
    func cancelImmediately() {
        let toCancel: Task<Void, Never>? = lock.withLock {
            stopRequested = true
            cancelled = true
            return task
        }
        toCancel?.cancel()
    }
}

/// True for a report made after a status read (or right before the download), where the run's next step is a
/// cancellation check, a wait or the download: never a create. Reports with no task state announce a create.
func replicaProgressAllowsStop(_ progress: ImageTo3DProgress) -> Bool {
    progress.state != nil
}

/// True when a Stop pressed now can cancel at once: only during the download, which spends nothing.
func replicaStopCancelsAtOnce(last: ImageTo3DProgress?) -> Bool {
    last?.stage == .downloading
}

/// A sleep for the status reads that ends early, as a cancellation, once Stop is asked for. Waits in slices of
/// `slice` seconds so Stop takes effect within a quarter of a second.
func replicaInterruptibleSleep(_ control: ReplicaRunControl, slice: TimeInterval = 0.25,
                               base: @escaping ImageTo3DSleep = imageTo3DRealSleep) -> ImageTo3DSleep {
    { seconds in
        var remaining = max(0, seconds)
        repeat {
            if control.isStopRequested { throw CancellationError() }
            let step = min(max(slice, 0.01), remaining)
            if step > 0 { try await base(step) }
            remaining -= step
        } while remaining > 0
        if control.isStopRequested { throw CancellationError() }
    }
}

/// The line under the progress bar while the service works.
func replicaProgressLine(_ progress: ImageTo3DProgress?, service: ImageTo3DService, stopping: Bool) -> String {
    let stage: String
    if let progress {
        if let state = progress.state, progress.stage == .generating || progress.stage == .converting || progress.stage == .repairing,
           state == .queued {
            stage = "\(service.title): \(state.title.lowercased())"
        } else {
            stage = "\(service.title): \(progress.stage.title.lowercased())"
        }
    } else {
        stage = "\(service.title): \(ImageTo3DStage.sending.title.lowercased())"
    }
    let percent = progress?.percent.map { " (\($0)%)" } ?? ""
    let suffix = stopping ? (replicaProgressAllowsStop(progress ?? ImageTo3DProgress(stage: .sending, taskID: nil, state: nil, percent: nil))
                             ? " — stopping…" : " — stopping once \(service.title) answers…") : "…"
    return stage + percent + suffix
}

// MARK: After a stop

enum ReplicaResumeAction: Equatable, Sendable {
    /// Read the same task again (nothing is created).
    case keepWaiting
    /// Download the finished model again (nothing is created).
    case tryDownloadAgain
    /// The conversion was definitely refused (nothing created), so sending it now is a first send. Spends credits.
    case tryConversionAgain

    var title: String {
        switch self {
        case .keepWaiting: return "Keep Waiting"
        case .tryDownloadAgain: return "Try Download Again"
        case .tryConversionAgain: return "Try Conversion Again"
        }
    }
}

/// How the sheet may carry on after `stop`: nil when it can't (an unknown outcome, a refusal of the generation, or a
/// task that ended), so the seller checks the dashboard instead. Never sends the generation again.
func replicaResumeAction(for stop: ImageTo3DStop) -> ReplicaResumeAction? {
    guard stop.resumePoint != nil else { return nil }
    switch stop.reason {
    case .conversionRefused: return .tryConversionAgain
    case .downloadFailed: return .tryDownloadAgain
    case .cancelled where stop.stage == .downloading: return .tryDownloadAgain
    case .timedOut, .statusUnreadable, .cancelled: return .keepWaiting
    case .notSent, .outcomeUnknown, .taskEnded: return nil
    }
}

/// One extra sentence for the stop message: whether credits may have gone.
func replicaCreditsNote(_ stop: ImageTo3DStop) -> String? {
    guard stop.creditsMayHaveBeenSpent else { return "No credits were spent." }
    switch stop.reason {
    case .taskEnded(.failed): return "\(stop.service.title) usually refunds a task that failed; check your balance."
    default: return "\(stop.service.title) may have charged for this."
    }
}

/// Generating again after anything that may have spent credits (or after a model was already made in this sheet)
/// asks first.
func replicaGenerateNeedsConfirmation(lastStop: ImageTo3DStop?, modelAlreadyMade: Bool) -> Bool {
    modelAlreadyMade || (lastStop?.creditsMayHaveBeenSpent ?? false)
}

func replicaGenerateAgainMessage(lastStop: ImageTo3DStop?, estimate: ImageTo3DCostEstimate) -> String {
    // The earlier request may have gone to the other service if the seller switched in Settings since.
    let service = (lastStop?.service ?? estimate.service).title
    let earlier: String
    if lastStop == nil {
        earlier = "The model from your earlier request is still here: Process Again uses it without sending anything."
    } else if let task = lastStop?.taskID {
        earlier = "\(service) may already be making or have made a model from the earlier request (task \(task)). Check \(service)’s dashboard first."
    } else {
        earlier = "\(service) may already have charged for the earlier request. Check \(service)’s dashboard first."
    }
    return "\(earlier) Generating again sends a new request: \(estimate.summary)"
}

// MARK: Processing on this Mac

enum ReplicaProcessingStep: String, Equatable, Sendable {
    case read, turnUpright, scale, repair, simplify, resize, check
}

enum ReplicaProcessingError: LocalizedError, Equatable {
    case unreadable(String)
    case flat(ReplicaSizeAxis)
    case exceedsBuildVolume(size: ReplicaSize, longestMM: Float)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "Studio couldn’t read the model the service made: \(reason)"
        case .flat(let axis):
            return "The model has no \(axis.rawValue.lowercased()) to scale to. Choose another measurement and Process Again."
        case .exceedsBuildVolume(let size, let longest):
            return "At \(size.label), the replica would be \(String(format: "%.0f", longest)) mm on its longest side, more than Slant’s \(Int(slantBuildVolumeMM)) mm build volume. Enter a smaller size, then Process Again: the model is still here, so nothing is sent or charged."
        case .invalidResult:
            return "The processed model didn’t pass Studio’s checks, so it wasn’t saved."
        }
    }
}

/// Which way the service's model points up. STL is Z-up; models that come out Y-up (as glTF is) lie on their back.
enum ReplicaUpAxis: String, Equatable, Sendable {
    case z, y
}

struct ReplicaProcessed: Sendable {
    let mesh: STLMesh
    /// The binary STL to save, already read back and checked.
    let stlData: Data
    let size: ReplicaSize
    let upAxis: ReplicaUpAxis
    let originalTriangles: Int
    let health: MeshHealthReport
    let wallThickness: WallThicknessReport?
    /// What Studio changed, one line each, in order.
    let changes: [String]
    let steps: [ReplicaProcessingStep]
    var extentMM: SIMD3<Float> { mesh.maximum - mesh.minimum }
}

/// The mesh turned from Y-up to Z-up: (x, y, z) → (x, −z, y), a rotation, so faces keep pointing outward.
func replicaTurnedUpright(_ mesh: STLMesh) throws -> STLMesh {
    var vertices = mesh.vertices
    for i in stride(from: 0, to: vertices.count - 2, by: 3) {
        let y = vertices[i + 1], z = vertices[i + 2]
        vertices[i + 1] = z == 0 ? 0 : -z
        vertices[i + 2] = y
    }
    return try STLMesh.validated(vertices)
}

/// The mesh moved so its base sits on Z = 0 and it is centred in X and Y.
func replicaPlacedOnBed(_ mesh: STLMesh) throws -> STLMesh {
    let centre = (SIMD3<Double>(mesh.minimum) + SIMD3<Double>(mesh.maximum)) / 2
    let offset = SIMD3<Float>(Float(centre.x), Float(centre.y), mesh.minimum.z)
    guard offset != .zero else { return mesh }
    var vertices = mesh.vertices
    for i in stride(from: 0, to: vertices.count - 2, by: 3) {
        vertices[i] -= offset.x
        vertices[i + 1] -= offset.y
        vertices[i + 2] -= offset.z
    }
    return try STLMesh.validated(vertices)
}

/// Scales uniformly so `size` holds, through the library's checked Scale to Size, then places it on the bed.
func replicaScaledToSize(_ mesh: STLMesh, size: ReplicaSize) throws -> STLMesh {
    let data: Data
    do {
        data = try mesh.scaledToSizeSTLData(axis: size.axis.meshFitAxis, targetMM: size.millimetres).data
    } catch MeshFitError.exceedsBuildVolume(let longest) {
        throw ReplicaProcessingError.exceedsBuildVolume(size: size, longestMM: longest)
    } catch MeshFitError.flatAxis {
        throw ReplicaProcessingError.flat(size.axis)
    } catch {
        throw ReplicaProcessingError.unreadable(error.localizedDescription)
    }
    return try replicaPlacedOnBed(STLMesh.parse(data))
}

/// The whole local pipeline, in order: read → (turn upright) → scale → repair → simplify when above `triangleTarget`
/// → fit the size again if it drifted → check. Pure and deterministic; throws `MeshToolError.cancelled` when stopped.
/// Repair or simplify failing (other than cancellation) is noted and the run carries on with the mesh it had: the
/// final check reports honestly what's left. Reading and scaling failures stop the run.
func processReplicaModel(_ data: Data, format: ImageTo3DOutputFormat, size: ReplicaSize, upAxis: ReplicaUpAxis = .z,
                         triangleTarget: Int = replicaTriangleTarget,
                         progress: MeshToolProgress = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> ReplicaProcessed {
    try withoutActuallyEscaping(progress) { progress in
        try replicaProcess(data, format: format, size: size, upAxis: upAxis, triangleTarget: triangleTarget,
                           progress: progress, isCancelled: isCancelled)
    }
}

private func replicaProcess(_ data: Data, format: ImageTo3DOutputFormat, size: ReplicaSize, upAxis: ReplicaUpAxis,
                            triangleTarget: Int, progress: @escaping MeshToolProgress, isCancelled: () -> Bool) throws -> ReplicaProcessed {
    func checkCancelled() throws { if isCancelled() { throw MeshToolError.cancelled } }
    func within(_ low: Double, _ high: Double) -> MeshToolProgress {
        { fraction, stage in progress(low + (high - low) * min(max(fraction, 0), 1), stage) }
    }
    var steps: [ReplicaProcessingStep] = []
    var changes: [String] = []

    progress(0, "Reading the model…")
    var mesh: STLMesh
    do {
        mesh = try parsePreviewModel(data, format: format == .stl ? .stl : .threeMF).mesh
    } catch {
        throw ReplicaProcessingError.unreadable(error.localizedDescription)
    }
    steps.append(.read)
    let originalTriangles = mesh.triangleCount
    try checkCancelled()

    if upAxis == .y {
        mesh = try replicaTurnedUpright(mesh)
        steps.append(.turnUpright)
        changes.append("Turned it upright.")
    }

    progress(0.05, "Scaling to \(size.label)…")
    mesh = try replicaScaledToSize(mesh, size: size)
    steps.append(.scale)
    changes.append("Scaled to \(size.label) and placed its base on the bed.")
    try checkCancelled()

    do {
        let repaired = try repairMesh(mesh, progress: within(0.1, 0.45), isCancelled: isCancelled)
        steps.append(.repair)
        if repaired.summary.changed {
            mesh = repaired.mesh
            changes.append(contentsOf: meshRepairSummaryLines(repaired.summary).dropLast())
        }
    } catch MeshToolError.cancelled {
        throw MeshToolError.cancelled
    } catch {
        changes.append("Repair couldn’t run: \(error.localizedDescription)")
    }
    try checkCancelled()

    if mesh.triangleCount > triangleTarget {
        var options = MeshSimplifyOptions()
        options.targetTriangles = triangleTarget
        do {
            let simplified = try simplifyMesh(mesh, options: options, progress: within(0.45, 0.75), isCancelled: isCancelled)
            steps.append(.simplify)
            if simplified.changed {
                mesh = simplified.mesh
                changes.append(contentsOf: meshSimplifySummaryLines(simplified).dropLast())
            }
        } catch MeshToolError.cancelled {
            throw MeshToolError.cancelled
        } catch {
            changes.append("Couldn’t simplify below \(mesh.triangleCount.formatted()) triangles: \(error.localizedDescription)")
        }
        try checkCancelled()
    }

    // Removing loose fragments can shrink the bounding box or lift the base: fit and place again.
    let measured = Double(size.axis.length(of: mesh.maximum - mesh.minimum))
    if !measured.isFinite || abs(measured - size.millimetres) > size.millimetres * replicaResizeTolerance {
        mesh = try replicaScaledToSize(mesh, size: size)
        steps.append(.resize)
        changes.append("Scaled again to \(size.label) after loose fragments were removed.")
    } else if mesh.minimum.z != 0 {
        mesh = try replicaPlacedOnBed(mesh)
    }
    try checkCancelled()

    progress(0.8, "Checking the replica…")
    guard let health = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw MeshToolError.cancelled }
    let wall = analyzeWallThickness(mesh, progress: { within(0.82, 0.98)($0, "Measuring wall thickness…") }, isCancelled: isCancelled)
    try checkCancelled()
    steps.append(.check)

    let stl = mesh.binarySTL()
    guard let readBack = try? STLMesh.parse(stl), readBack.triangleCount == mesh.triangleCount else {
        throw ReplicaProcessingError.invalidResult
    }
    guard (readBack.maximum - readBack.minimum).max() <= slantBuildVolumeMM + 0.01 else {
        throw ReplicaProcessingError.exceedsBuildVolume(size: size, longestMM: (readBack.maximum - readBack.minimum).max())
    }
    progress(1, "Done")
    return ReplicaProcessed(mesh: readBack, stlData: stl, size: size, upAxis: upAxis, originalTriangles: originalTriangles,
                            health: health, wallThickness: wall, changes: changes, steps: steps)
}

/// The finished summary: size, triangles, Studio's checks. What changed is listed separately (`changes`).
func replicaSummaryLines(_ processed: ReplicaProcessed) -> [String] {
    let extent = processed.extentMM
    var lines = ["Size: \(footprintLabel((extent.x, extent.y, extent.z))) (width × depth × height)."]
    let triangles = processed.mesh.triangleCount
    if triangles == processed.originalTriangles {
        lines.append("\(triangles.formatted()) triangles.")
    } else {
        lines.append("\(triangles.formatted()) triangles (the service sent \(processed.originalTriangles.formatted())).")
    }
    if triangles > meshToolsReinforceTriangleLimit {
        lines.append("Above \(meshToolsReinforceTriangleLimit.formatted()) triangles, so Reinforce and Auto-improve won’t take it until it’s simplified.")
    }
    lines.append(meshRepairOutcomeLine(processed.health))
    if let wall = processed.wallThickness {
        lines.append(wallThicknessSummary(wall).line + ".")
    }
    return lines
}

/// Whether Studio's own checks found nothing: a sound mesh and no thin walls or small features. Only then may the
/// sheet say "checks found no problems".
func replicaChecksFoundNoProblems(_ processed: ReplicaProcessed) -> Bool {
    meshHealthIsSound(processed.health) && (processed.wallThickness.map { wallThicknessSummary($0).isClear } ?? false)
}

/// Source details for the copy: where it came from, display-only. The date isn't recorded.
func replicaSourceDetails(service: ImageTo3DService) -> ModelSourceDetails {
    ModelSourceDetails(source: replicaOriginText(service: service))
}

/// "Generated by Meshy from a photo" / "Generated by Tripo3D from a photo".
func replicaOriginText(service: ImageTo3DService) -> String {
    "Generated by \(service.sharingService.displayName) from a photo"
}

// MARK: Review hand-off

/// What Review for Printing with Claude is told about the replica. No name, photo or seller text beyond the size.
func replicaPrintReviewContext(service: ImageTo3DService, size: ReplicaSize, purpose: ReplicaPurpose,
                               meshyReport: MeshyPrintabilityReport?) -> PrintReviewContext {
    var findings = ["Made from one photo, so the sides the photo didn’t show (back, underside) are the service’s guess."]
    if let meshyReport {
        let list = meshyReport.findings
        let detail = list.isEmpty ? "" : ": " + list.joined(separator: "; ")
        findings.append("Meshy’s printability check of its original model (before Studio’s repair), at this size: \(meshyReport.verdict.rawValue)\(detail).")
    }
    return PrintReviewContext(origin: replicaOriginText(service: service), intendedSizeNote: size.reviewNote,
                              purpose: purpose.rawValue, findings: findings)
}

// MARK: Activity

/// Activity-safe detail for a saved replica: service, triangles and the estimated credits only.
func replicaSavedActivityDetail(service: ImageTo3DService, triangles: Int, estimate: ImageTo3DCostEstimate?) -> String {
    let credits = estimate.map { ", about \($0.credits) credits" } ?? ""
    return "\(service.title): saved, \(triangles.formatted()) triangles\(credits)"
}

/// Activity-safe detail for Meshy's analysis: verdict and counts only.
func replicaAnalysisActivityDetail(_ report: MeshyPrintabilityReport) -> String {
    "Meshy: \(report.verdict.rawValue), \(report.errorCount) errors, \(report.warningCount) warnings"
}
