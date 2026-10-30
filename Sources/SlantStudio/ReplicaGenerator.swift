import Foundation
import simd

// MARK: - Generate a Replica from an Image
//
// One to four photos (a front view, and optionally the left side, back and right side) go to the seller's chosen 3D
// service (Meshy or Tripo3D, ImageTo3D.swift), which makes a mesh. Studio asks for more detail than it keeps, then
// works on this Mac only, in a fixed order: read the file (up to `replicaMaximumModelTriangles`, far above the
// library's limit), (optionally) stand it upright, scale it to the real size the seller typed (neither service knows
// it), repair, simplify when above the purpose's ceiling (Reinforce's 20,000-triangle limit for a functional part,
// 200,000 for a display piece), fit the size again if repair removed fragments, then check it. The seller sees the result, chooses which way is up, and only then is one library copy,
// "<name> (replica)", saved. The paid model stays in memory, so processing it again is free.
//
// Rules this file keeps:
//   - The generation is sent once and never retried. Stop never interrupts a request that may spend credits: it takes
//     effect while Studio waits between status reads, after a status read, or during the download
//     (`ReplicaRunControl`). An unknown create outcome sends the seller to the service's dashboard, with no resume.
//   - Generating again after anything that may have spent credits needs an explicit confirmation.
//   - Photos, names, sizes and the downloaded model stay in memory with the sheet; temporary files live in
//     `SlantStudio-Replica-…` folders (removed after the import, and at launch). Activity gets service, status,
//     counts (photos and triangles) and credits only.
//   - Higher detail costs more every time, so it is chosen per replica and never remembered, and only for a display
//     piece (a functional part is simplified to 20,000 triangles, which would throw the detail away).
//   - A model too large for Studio to download or read is a final stop: paid for, left on the service's dashboard.
//   - Everything geometric is deterministic: the wave-1 mesh tools walk index order, and so does this file.

/// Temporary folders for the replica on its way into the library; listed in `personalisationTempFolderPrefixes`.
let replicaTempFolderPrefix = "SlantStudio-Replica-"
/// The smallest real size accepted: smaller replicas lose almost all detail on an FDM printer.
let replicaMinimumSizeMM = 5.0
/// The triangles kept for a functional part after simplifying (Reinforce and Auto-improve's limit).
let replicaTriangleTarget = imageTo3DDefaultTriangleTarget
/// The triangle budget asked of Tripo (`face_limit`) for a functional part: five times what Studio keeps, so its own
/// simplification chooses which detail goes. Meshy isn't remeshed, so it sends what it generates.
let replicaFunctionalTriangleRequest = 100_000
/// The triangle budget asked of Tripo for a display piece: more than Studio keeps (a 25 MB STL), within its v3.1 range
/// (500–1,500,000; 2,000,000 with detailed geometry).
let replicaDisplayTriangleTarget = 500_000
/// A display piece is simplified only above this, well below the 500,000-triangle import limit.
let replicaDisplayTriangleCeiling = 200_000
/// The most triangles the replica pipeline reads from a downloaded model: what fits in the 128 MB download as binary
/// STL (50 bytes a triangle). Meshy doesn't document how many an unremeshed model has. Repair and simplify work on it in
/// memory and the saved copy is always within the library's 500,000-triangle limit. 3MF downloads keep the library's
/// limit (Studio asks both services for STL).
let replicaMaximumModelTriangles = Int(imageTo3DMaxDownloadBytes / 50)
/// "Checks found no problems" needs overhangs (faces down more steeply than 45° from vertical) on under this
/// share of the surface: more usually needs supports or another orientation.
let replicaOverhangShareLimit = printReviewOverhangLimit
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

    /// Triangles asked of Tripo: more than Studio keeps for either purpose, so Studio's simplification decides.
    var requestedTriangles: Int { self == .display ? replicaDisplayTriangleTarget : replicaFunctionalTriangleRequest }
    /// Studio simplifies only above this, down to it.
    var triangleCeiling: Int { self == .display ? replicaDisplayTriangleCeiling : replicaTriangleTarget }
}

/// Shown under Purpose for a functional part.
let replicaFunctionalPartWarning = "A model made from photos isn’t dimensionally accurate: only the size you type is measured, and holes, slots and other sizes are the service’s guess. For a part that must fit something, use Design an Accessory from a Photo… (in the Import menu and the File menu) instead."

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

/// Why the name can't be used, or nil. Room is left for the suffix within the library's name limit.
func replicaNameProblem(_ name: String) -> String? {
    if let problem = modelNameProblem(name) { return problem }
    let limit = maximumModelNameLength - replicaNameSuffix.count
    if name.trimmingCharacters(in: .whitespacesAndNewlines).count > limit { return "Names can be at most \(limit) characters here." }
    if name.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "."))).isEmpty {
        return "Enter a name with letters or numbers."
    }
    return nil
}

/// "Dragon (replica)": trimmed, without leading full stops (which would hide the temporary file).
func replicaCopyName(_ name: String) -> String {
    var base = name.trimmingCharacters(in: .whitespacesAndNewlines)
    while base.hasPrefix(".") { base.removeFirst() }
    base = base.trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { base = "Model" }
    return base + replicaNameSuffix
}

/// What the service is asked for. Mesh only, STL, the purpose's triangle budget, and Higher detail only when ticked
/// for a display piece. The origin option is kept for Meshy (free) and left off for Tripo, where it makes the
/// conversion cost 10 credits instead of 5: Studio places the model itself.
func replicaGenerationOptions(for service: ImageTo3DService, purpose: ReplicaPurpose, higherDetail: Bool = false) -> ImageTo3DOptions {
    var options = ImageTo3DOptions()
    options.targetTriangles = purpose.requestedTriangles
    options.format = .stl
    options.originAtBottom = service == .meshy
    options.higherDetail = higherDetail && replicaHigherDetailAvailable(for: purpose)
    return options
}

/// Higher detail only pays for a display piece: a functional part is simplified to 20,000 triangles anyway.
func replicaHigherDetailAvailable(for purpose: ReplicaPurpose) -> Bool { purpose == .display }

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
func replicaCostEstimate(service: ImageTo3DService, purpose: ReplicaPurpose = .functional, photoCount: Int = 1,
                         higherDetail: Bool = false, tripoRegion: TripoRegion = .international) -> ImageTo3DCostEstimate {
    makeImageTo3DProvider(service, key: "", tripoRegion: tripoRegion, transport: ReplicaOfflineTransport())
        .estimatedCost(for: replicaGenerationOptions(for: service, purpose: purpose, higherDetail: higherDetail), photoCount: photoCount)
}

/// The cost line under the service: the estimate, then whether extra photos change it. Both services charge the same
/// for two to four photos as for one.
func replicaCostLine(_ estimate: ImageTo3DCostEstimate, photoCount: Int) -> String {
    photoCount > 1 ? "\(estimate.summary) Extra photos don’t change the price." : estimate.summary
}

/// What the seller chose that changes the request or its price, captured when Generate is pressed so a later change
/// (another photo, Higher detail, the service) can't slip past the cost that was shown.
struct ReplicaRequestPlan: Equatable, Sendable {
    let service: ImageTo3DService
    let views: [ImageTo3DPhotoView]
    /// As sent: only for a display piece.
    let higherDetail: Bool
    let credits: Int
}

/// The footer's cost label beside Generate, so the price is in view when the seller presses it.
func replicaFooterCostLabel(_ estimate: ImageTo3DCostEstimate) -> String {
    "About \(estimate.credits) \(estimate.service.title) credits"
}

/// The send button's title: Generate Replica the first time, Generate Again… after anything was sent.
func replicaGenerateButtonTitle(firstRequest: Bool) -> String {
    firstRequest ? "Generate Replica" : "Generate Again…"
}

/// Shown when the photos or options changed between pressing Generate and the send: nothing was sent.
func replicaPlanChangedMessage(buttonTitle: String) -> String {
    "The photos or options changed after the cost was shown, so nothing was sent. Check the cost, then choose \(buttonTitle) again."
}

/// What still stops Generate Replica, in the order the sheet shows them. Empty when it can start.
func replicaGenerateBlockedReasons(photoReady: Bool, photoPreparing: Bool, nameText: String, sizeText: String,
                                   service: ImageTo3DService, hasKey: Bool, extraPhotosWithoutFront: Bool = false) -> [String] {
    var reasons: [String] = []
    if photoPreparing { reasons.append("Wait while Plinth prepares the photos.") }
    else if extraPhotosWithoutFront { reasons.append("Add a front photo: the other views go with it.") }
    else if !photoReady { reasons.append("Choose a photo of the object.") }
    if let problem = replicaNameProblem(nameText) { reasons.append(problem == "Enter a name." ? "Enter a name for the replica." : problem) }
    if let problem = replicaSizeProblem(sizeText) { reasons.append(problem) }
    if !hasKey { reasons.append("Add your \(service.title) API key in Settings › Design Tools › 3D generation.") }
    return reasons
}

let replicaPhotoAdvice = "A front photo is enough; more views help the service get the shape right. Use the same object, lighting and plain background in each."
/// Side views at a quarter turn line up with Tripo's left and right slots, and Meshy's multi-view guidance.
let replicaPhotoSideAdvice = "Take each side photo a quarter turn from the front, straight on, at the same distance."
/// Near-orthographic shots distort less (Meshy recommends a telephoto lens or a near-orthographic view).
let replicaPhotoDistanceAdvice = "Step back and zoom in so the object fills the frame: it looks less distorted."

/// The slot's label: which side, in the object's own terms.
func replicaPhotoSlotLabel(_ view: ImageTo3DPhotoView) -> String {
    switch view {
    case .front: return "Front (required)"
    case .left: return "Left side (its left)"
    case .back: return "Back"
    case .right: return "Right side (its right)"
    }
}

/// The convention behind the side labels, for the slot's help and the file picker. Nil for front and back.
func replicaPhotoSlotHelp(_ view: ImageTo3DPhotoView) -> String? {
    switch view {
    case .left: return "Its left is on your right when you face its front."
    case .right: return "Its right is on your left when you face its front."
    case .front, .back: return nil
    }
}

/// The file picker's message for a slot.
func replicaPhotoPickerMessage(_ view: ImageTo3DPhotoView) -> String {
    switch view {
    case .front: return "Choose a photo of the object’s front, on a plain background."
    case .back: return "Choose a photo of the object’s back, with the same lighting as the front photo."
    case .left, .right:
        return "Choose a photo of the object’s \(view.title.lowercased()), a quarter turn from the front. \(replicaPhotoSlotHelp(view) ?? "")"
    }
}

/// Shown under Higher detail for a display piece.
func replicaHigherDetailNote(service: ImageTo3DService) -> String {
    let what: String
    switch service {
    case .meshy: what = "Meshy generates the shape at Ultra 2K for finer surface detail, for \(meshyHigherDetailCredits) more credits each time."
    case .tripo: what = "Tripo generates detailed geometry for \(tripoHigherDetailCredits) more credits each time."
    }
    return "\(what) Plinth keeps up to \(replicaDisplayTriangleCeiling.formatted()) triangles of it. Fine detail can print differently, so check the result."
}

/// Shown under Higher detail, which is off and disabled, for a functional part.
let replicaHigherDetailFunctionalNote = "Functional parts are simplified to 20,000 triangles, so higher detail would be lost."
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

/// How the sheet may carry on after `stop`: nil when it can't (an unknown outcome, a refusal of the generation, a
/// task that ended, or a model too large to download or read), so the seller checks the dashboard instead. Never sends the generation again.
func replicaResumeAction(for stop: ImageTo3DStop) -> ReplicaResumeAction? {
    guard stop.resumePoint != nil else { return nil }
    switch stop.reason {
    case .conversionRefused: return .tryConversionAgain
    case .downloadFailed: return .tryDownloadAgain
    case .cancelled where stop.stage == .downloading: return .tryDownloadAgain
    case .timedOut, .statusUnreadable, .cancelled: return .keepWaiting
    case .notSent, .outcomeUnknown, .taskEnded, .modelTooLarge: return nil
    }
}

/// What carrying on after `stop` with `action` sends. Keep Waiting never makes the model again, but a Tripo model
/// still needs its paid conversion to STL when that hasn't been sent yet.
func replicaResumeNote(_ stop: ImageTo3DStop, action: ReplicaResumeAction) -> String {
    if action == .tryConversionAgain {
        let credits = stop.service == .tripo ? tripoConvertBasicCredits : meshyConvertCredits
        return "\(action.title) sends the conversion once, which costs about \(credits) \(stop.service.title) \(credits == 1 ? "credit" : "credits"). The model itself isn’t made again."
    }
    let conversionPending = stop.service == .tripo && stop.resumePoint.map { $0.conversionTaskID == nil && $0.sourceKind != .conversion } == true
    if conversionPending {
        return "\(action.title) carries on with the same task, so the model isn’t made again. Once it’s finished, Plinth sends its conversion to STL once, which costs about \(tripoConvertBasicCredits) \(stop.service.title) credits."
    }
    return "\(action.title) carries on with the same task. Nothing new is made or charged."
}

/// One extra sentence for the stop message: whether credits may have gone. None for a model too large, whose message
/// already says the credits were spent.
func replicaCreditsNote(_ stop: ImageTo3DStop) -> String? {
    guard stop.creditsMayHaveBeenSpent else { return "No credits were spent." }
    switch stop.reason {
    case .modelTooLarge: return nil
    case .taskEnded(.failed): return "\(stop.service.title) usually refunds a task that failed; check your balance."
    default: return "\(stop.service.title) may have charged for this."
    }
}

/// Generating asks first after anything that may have spent credits: in this sheet (a stop, or a model already
/// made) or in any sheet this session (`ImageTo3DConnection.hasUnconfirmedRequests`).
func replicaGenerateNeedsConfirmation(lastStop: ImageTo3DStop?, modelAlreadyMade: Bool, earlierUnconfirmed: Bool) -> Bool {
    modelAlreadyMade || earlierUnconfirmed || (lastStop?.creditsMayHaveBeenSpent ?? false)
}

/// The notice for paid requests this session whose outcome is unconfirmed, newest first; nil when there are none.
/// `excluding` is the record of the stop this sheet is already explaining.
func replicaUnconfirmedNotice(_ requests: [ImageTo3DUnconfirmedRequest], overflowed: Bool, excluding: UUID? = nil,
                              timeText: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String? {
    let listed = requests.filter { $0.id != excluding }
    guard !listed.isEmpty || overflowed else { return nil }
    let labels = listed.reversed().map { imageTo3DUnconfirmedLabel($0, timeText: timeText) }
    let list = labels.isEmpty ? "earlier requests" : ListFormatter.localizedString(byJoining: labels)
    let more = overflowed && !labels.isEmpty ? " and older ones" : ""
    let services = Set(listed.map(\.service))
    let dashboard = services.count == 1 ? "\(services.first!.title)’s dashboard" : "each service’s dashboard"
    return "Plinth couldn’t confirm what happened to \(list)\(more) this session. They may have spent credits, and a finished model may be waiting there: check \(dashboard) before generating again."
}

func replicaGenerateAgainMessage(lastStop: ImageTo3DStop?, modelAlreadyMade: Bool, earlierNotice: String?,
                                 estimate: ImageTo3DCostEstimate) -> String {
    var parts: [String] = []
    // The earlier request may have gone to the other service if the seller switched in Settings since.
    if let lastStop, lastStop.creditsMayHaveBeenSpent {
        let service = lastStop.service.title
        if let task = lastStop.taskID {
            parts.append("\(service) may already be making or have made a model from the earlier request (task \(task)). Check \(service)’s dashboard first.")
        } else {
            parts.append("\(service) may already have charged for the earlier request. Check \(service)’s dashboard first.")
        }
    } else if modelAlreadyMade {
        parts.append("The model from your earlier request is still here: Process Again uses it without sending anything.")
    }
    if let earlierNotice { parts.append(earlierNotice) }
    parts.append("Generating again sends a new request: \(estimate.summary)")
    return parts.joined(separator: " ")
}

/// What Close asks before it closes, or nil when it can close at once: a paid model that isn't saved, or a stop that
/// may have spent credits (once closed, Studio can't carry on with that task).
struct ReplicaCloseWarning: Equatable {
    let title: String
    let message: String
    let confirmTitle: String
}

func replicaCloseWarning(hasUnsavedModel: Bool, lastStop: ImageTo3DStop?, service: ImageTo3DService?) -> ReplicaCloseWarning? {
    if hasUnsavedModel {
        let name = service?.title ?? "the service"
        return ReplicaCloseWarning(title: "Close without saving the replica?",
                                   message: "The model \(name) made isn’t in your library, and Plinth doesn’t keep it. Getting it back means generating, and paying for, it again.",
                                   confirmTitle: "Close Without Saving")
    }
    guard let lastStop, lastStop.creditsMayHaveBeenSpent else { return nil }
    let name = lastStop.service.title
    if lastStop.reason == .modelTooLarge {
        // Finished and paid for; nothing is running, and nothing more can be done with it here.
        let kept = lastStop.service == .meshy ? " (Meshy keeps it for 3 days)" : ""
        return ReplicaCloseWarning(title: "Close without the model \(name) made?",
                                   message: "\(name) made the model and charged for it, but it was too detailed for Plinth. It stays on \(name)’s dashboard\(kept).",
                                   confirmTitle: "Close")
    }
    let task = lastStop.taskID.map { " for task \($0)" } ?? ""
    let resume = replicaResumeAction(for: lastStop).map { " Once this closes, Plinth can’t \($0.title) for it." } ?? ""
    return ReplicaCloseWarning(title: "Close while \(name) may have charged?",
                               message: "\(name) may have charged for this request, and may still finish the model.\(resume) Check \(name)’s dashboard\(task). Plinth remembers this request until you quit, and asks before generating again.",
                               confirmTitle: "Close")
}

// MARK: Processing on this Mac

enum ReplicaProcessingStep: String, Equatable, Sendable {
    case read, turnUpright, scale, repair, simplify, resize, check
}

enum ReplicaProcessingError: LocalizedError, Equatable {
    case unreadable(String)
    case flat(ReplicaSizeAxis)
    case exceedsBuildVolume(size: ReplicaSize, longestMM: Float)
    /// More than `replicaMaximumModelTriangles`, or a 3MF above the library's limit: it can't be read at all.
    /// `limit` names the limit hit, as in "more than 2,684,354 triangles".
    case modelTooLarge(limit: String)
    case tooDetailed(triangles: Int)
    case invalidResult

    var errorDescription: String? {
        switch self {
        case .unreadable(let reason):
            return "Plinth couldn’t read the model the service made: \(reason)"
        case .flat(let axis):
            return "The model has no \(axis.rawValue.lowercased()) to scale to. Choose another measurement and Process Again."
        case .exceedsBuildVolume(let size, let longest):
            return "At \(size.label), the replica would be \(String(format: "%.0f", longest)) mm on its longest side, more than Slant’s \(Int(slantBuildVolumeMM)) mm build volume. Enter a smaller size, then Process Again: the model is still here, so nothing is sent or charged."
        case .modelTooLarge(let limit):
            return "The model is too detailed for Plinth to read (\(limit))."
        case .tooDetailed(let triangles):
            return "Plinth couldn’t simplify the model below \(STLMesh.maximumTriangles.formatted()) triangles (it still has \(triangles.formatted())), so it can’t be added to your library and nothing was saved. The service keeps this model on its dashboard."
        case .invalidResult:
            return "The processed model didn’t pass Plinth’s checks, so it wasn’t saved."
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
    /// Simplify's estimated largest surface change in millimetres, when Studio simplified.
    var simplifiedDeviationMM: Double? = nil
    let health: MeshHealthReport
    let wallThickness: WallThicknessReport?
    /// Downward faces steeper than 45° from vertical, as placed (`overhangShare`, PrintReview.swift).
    let overhang: OverhangShare
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
        data = try mesh.scaledToSizeSTLData(axis: size.axis.meshFitAxis, targetMM: size.millimetres,
                                            maximumTriangles: replicaMaximumModelTriangles).data
    } catch MeshFitError.exceedsBuildVolume(let longest) {
        throw ReplicaProcessingError.exceedsBuildVolume(size: size, longestMM: longest)
    } catch MeshFitError.flatAxis {
        throw ReplicaProcessingError.flat(size.axis)
    } catch {
        throw ReplicaProcessingError.unreadable(error.localizedDescription)
    }
    return try replicaPlacedOnBed(STLMesh.parse(data, maximumTriangles: replicaMaximumModelTriangles))
}

/// The downloaded file read as the format its content shows (`imageTo3DDetectedFormat`), whatever its link said. An
/// STL may have up to `replicaMaximumModelTriangles`; a 3MF keeps the library's limit.
func replicaReadModel(_ data: Data, maximumTriangles: Int = replicaMaximumModelTriangles) throws -> STLMesh {
    guard let format = imageTo3DDetectedFormat(data) else {
        throw ReplicaProcessingError.unreadable("the file isn’t an STL or 3MF model.")
    }
    if format == .stl {
        do { return try STLMesh.parse(data, maximumTriangles: maximumTriangles) } catch STLMesh.ParseError.oversized {
            throw ReplicaProcessingError.modelTooLarge(limit: "more than \(maximumTriangles.formatted()) triangles")
        } catch {
            throw ReplicaProcessingError.unreadable(error.localizedDescription)
        }
    }
    do {
        return try parsePreviewModel(data, format: .threeMF).mesh
    } catch STLMesh.ParseError.oversized {
        // A 3MF keeps the library's limit.
        throw ReplicaProcessingError.modelTooLarge(limit: "a 3MF with more than \(STLMesh.maximumTriangles.formatted()) triangles")
    } catch ZipArchive.ZipError.oversized {
        throw ReplicaProcessingError.modelTooLarge(limit: "a 3MF over 128 MB unpacked")
    } catch {
        throw ReplicaProcessingError.unreadable(error.localizedDescription)
    }
}

/// The whole local pipeline, in order: read → (turn upright) → scale → repair → simplify when above `triangleTarget`
/// → fit the size again if it drifted → check. Pure and deterministic; throws `MeshToolError.cancelled` when stopped.
/// Repair or simplify failing (other than cancellation) is noted and the run carries on with the mesh it had: the
/// final check reports honestly what's left. Reading and scaling failures stop the run.
func processReplicaModel(_ data: Data, size: ReplicaSize, upAxis: ReplicaUpAxis = .z,
                         triangleTarget: Int = replicaTriangleTarget, wallThicknessSamples: Int = wallThicknessMaximumSamples,
                         progress: MeshToolProgress = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> ReplicaProcessed {
    progress(0, "Reading the model…")
    let mesh = try replicaReadModel(data)
    return try processReplicaModel(mesh: mesh, size: size, upAxis: upAxis, triangleTarget: triangleTarget,
                                   wallThicknessSamples: wallThicknessSamples, progress: progress, isCancelled: isCancelled)
}

/// The same pipeline from a model already read (the sheet keeps the paid model read once, so Process Again is free).
/// `savedTriangleLimit` is the library's limit; tests pass a smaller one.
func processReplicaModel(mesh: STLMesh, size: ReplicaSize, upAxis: ReplicaUpAxis = .z,
                         triangleTarget: Int = replicaTriangleTarget, wallThicknessSamples: Int = wallThicknessMaximumSamples,
                         savedTriangleLimit: Int = STLMesh.maximumTriangles,
                         progress: MeshToolProgress = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> ReplicaProcessed {
    try withoutActuallyEscaping(progress) { progress in
        try replicaProcess(mesh, size: size, upAxis: upAxis, triangleTarget: triangleTarget,
                           wallThicknessSamples: wallThicknessSamples, savedTriangleLimit: savedTriangleLimit,
                           progress: progress, isCancelled: isCancelled)
    }
}

private func replicaProcess(_ input: STLMesh, size: ReplicaSize, upAxis: ReplicaUpAxis, triangleTarget: Int,
                            wallThicknessSamples: Int, savedTriangleLimit: Int, progress: @escaping MeshToolProgress,
                            isCancelled: () -> Bool) throws -> ReplicaProcessed {
    func checkCancelled() throws { if isCancelled() { throw MeshToolError.cancelled } }
    func within(_ low: Double, _ high: Double) -> MeshToolProgress {
        { fraction, stage in progress(low + (high - low) * min(max(fraction, 0), 1), stage) }
    }
    var steps: [ReplicaProcessingStep] = [.read]
    var changes: [String] = []
    var mesh = input
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
        var repairOptions = MeshRepairOptions()
        repairOptions.maximumTriangles = replicaMaximumModelTriangles
        let repaired = try repairMesh(mesh, options: repairOptions, progress: within(0.1, 0.45), isCancelled: isCancelled)
        steps.append(.repair)
        if repaired.summary.changed {
            mesh = repaired.mesh
            changes.append(contentsOf: meshRepairSummaryLines(repaired.summary).dropLast())
        }
    } catch MeshToolError.cancelled {
        throw MeshToolError.cancelled
    } catch {
        // Name the limit actually hit: the replica path's, not the library's.
        let reason = (error as? MeshToolError) == .tooLarge
            ? "the result would have more than \(replicaMaximumModelTriangles.formatted()) triangles."
            : error.localizedDescription
        changes.append("Repair couldn’t run: \(reason)")
    }
    try checkCancelled()

    var deviation: Double?
    if mesh.triangleCount > triangleTarget {
        var options = MeshSimplifyOptions()
        options.targetTriangles = triangleTarget
        do {
            let simplified = try simplifyMesh(mesh, options: options, progress: within(0.45, 0.75), isCancelled: isCancelled)
            steps.append(.simplify)
            if simplified.changed {
                mesh = simplified.mesh
                deviation = simplified.estimatedMaximumDeviation
                // The deviation estimate is a result fact (`replicaSimplifiedDeviationLine`), not repeated here.
                changes.append(contentsOf: meshSimplifySummaryLines(simplified).dropLast()
                    .filter { !$0.hasPrefix("Estimated largest surface change") })
            }
        } catch MeshToolError.cancelled {
            throw MeshToolError.cancelled
        } catch {
            changes.append("Couldn’t simplify below \(mesh.triangleCount.formatted()) triangles: \(error.localizedDescription)")
        }
        try checkCancelled()
    }

    // The library (and every tool after this) reads at most its preview limit.
    guard mesh.triangleCount <= min(savedTriangleLimit, STLMesh.maximumTriangles) else {
        throw ReplicaProcessingError.tooDetailed(triangles: mesh.triangleCount)
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
    let wall = analyzeWallThickness(mesh, maximumSamples: wallThicknessSamples,
                                    progress: { within(0.82, 0.98)($0, "Measuring wall thickness…") }, isCancelled: isCancelled)
    try checkCancelled()
    let overhang = overhangShare(mesh)
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
                            simplifiedDeviationMM: deviation, health: health, wallThickness: wall, overhang: overhang,
                            changes: changes, steps: steps)
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
    if let deviation = processed.simplifiedDeviationMM {
        lines.append(replicaSimplifiedDeviationLine(deviation))
    }
    if triangles > meshToolsReinforceTriangleLimit {
        lines.append("Reinforce and Auto-improve need \(meshToolsReinforceTriangleLimit.formatted()) triangles or fewer. To use them, make a lighter copy with Simplify & Save Copy in Improve for printing › Repair and simplify.")
    }
    lines.append(meshRepairOutcomeLine(processed.health))
    if let wall = processed.wallThickness {
        lines.append(wallThicknessSummary(wall).line + ".")
    }
    lines.append(printReviewOverhangLine(processed.overhang))
    return lines
}

/// Simplify's estimate as a result fact: an estimate of how far the surface moved, not a measurement.
func replicaSimplifiedDeviationLine(_ deviationMM: Double) -> String {
    let value = deviationMM < 0.01 ? "0.01 mm or less" : String(format: "%.2f mm", deviationMM)
    return "Simplifying moved the surface by an estimated \(value). Check fine details before ordering."
}

/// Whether Process Again could help after processing failed: never for a model too detailed to simplify enough, which
/// fails the same way every time.
func replicaProcessingFailureAllowsProcessAgain(_ error: Error) -> Bool {
    switch error as? ReplicaProcessingError {
    case .tooDetailed?, .modelTooLarge?: return false
    default: return true
    }
}

/// The message for a processing failure, with the Higher detail advice only when the request used it.
func replicaProcessingFailureMessage(_ error: Error, higherDetail: Bool) -> String {
    var message = error.localizedDescription
    if higherDetail, case .tooDetailed? = error as? ReplicaProcessingError {
        message += " Generating again without Higher detail may help."
    }
    return message
}

/// Whether Studio's own checks found nothing: a sound mesh, no thin walls or small features, and overhangs on under
/// `replicaOverhangShareLimit` of the surface. Only then may the sheet say `replicaNoProblemsLine`.
func replicaChecksFoundNoProblems(_ processed: ReplicaProcessed) -> Bool {
    meshHealthIsSound(processed.health)
        && (processed.wallThickness.map { wallThicknessSummary($0).isClear } ?? false)
        && processed.overhang.isMinor
}

/// What "no problems" covers, so it isn't read as more than was checked.
let replicaNoProblemsLine = "Plinth’s checks found no problems: the mesh is closed, no walls are thinner than 2 mm, no small features were found, and under \(Int(replicaOverhangShareLimit * 100))% of the surface overhangs more than 45°. Strength and fit aren’t checked."

/// Source details for the copy: where it came from, display-only. The date isn't recorded.
func replicaSourceDetails(service: ImageTo3DService) -> ModelSourceDetails {
    ModelSourceDetails(source: replicaOriginText(service: service))
}

/// "Generated by Meshy from a photo" / "Generated by Tripo from a photo".
func replicaOriginText(service: ImageTo3DService) -> String {
    "Generated by \(service.sharingService.displayName) from a photo"
}

// MARK: Review hand-off

/// What Review for Printing with Claude is told about the replica. No name, photo or seller text beyond the size.
func replicaPrintReviewContext(service: ImageTo3DService, size: ReplicaSize, purpose: ReplicaPurpose,
                               meshyReport: MeshyPrintabilityReport?, views: [ImageTo3DPhotoView] = [.front]) -> PrintReviewContext {
    var findings = [replicaPhotoCoverageFinding(views)]
    if let meshyReport {
        let list = meshyReport.findings
        let detail = list.isEmpty ? "" : ": " + list.joined(separator: "; ")
        findings.append("Meshy’s printability check of its original model (before Plinth’s repair), at this size: \(meshyReport.verdict.rawValue)\(detail).")
    }
    return PrintReviewContext(origin: replicaOriginText(service: service), intendedSizeNote: size.reviewNote,
                              purpose: purpose.rawValue, findings: findings)
}

/// What the photos covered, for the review: the sides no photo showed are the service's guess.
func replicaPhotoCoverageFinding(_ views: [ImageTo3DPhotoView]) -> String {
    let shown = ImageTo3DPhotoView.allCases.filter(views.contains)
    guard shown.count > 1 else {
        return "Made from one photo, so the sides the photo didn’t show (back, underside) are the service’s guess."
    }
    // Joined the British way, whatever the Mac's language: this goes to Claude in English.
    func joined(_ parts: [String]) -> String {
        parts.count <= 1 ? parts.joined() : parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
    }
    let names = joined(shown.map { $0.title.lowercased() })
    let missing = ImageTo3DPhotoView.allCases.filter { !shown.contains($0) }.map { $0.title.lowercased() } + ["underside"]
    return "Made from \(shown.count) photos (\(names)), so what they didn’t show (\(joined(missing))) is the service’s guess."
}

// MARK: Activity

/// Activity-safe detail for a saved replica: service, photo count, triangles and the estimated credits only.
func replicaSavedActivityDetail(service: ImageTo3DService, triangles: Int, estimate: ImageTo3DCostEstimate?, photoCount: Int = 1) -> String {
    let credits = estimate.map { ", about \($0.credits) credits" } ?? ""
    let photos = photoCount > 1 ? ", \(photoCount) photos" : ""
    return "\(service.title): saved\(photos), \(triangles.formatted()) triangles\(credits)"
}

/// Activity-safe detail for Meshy's analysis: verdict and counts only.
func replicaAnalysisActivityDetail(_ report: MeshyPrintabilityReport) -> String {
    "Meshy: \(report.verdict.rawValue), \(report.errorCount) errors, \(report.warningCount) warnings"
}
