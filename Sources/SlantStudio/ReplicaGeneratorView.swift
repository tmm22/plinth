import SwiftUI
import UniformTypeIdentifiers

// The Generate a Replica from an Image sheet (ReplicaGenerator.swift holds the pure pipeline and rules). Opened from
// Models › Import and File; never from a shortcut. Everything typed or chosen here, the photos (a front view and up to
// three more) and the downloaded model live in this sheet's memory and go when it closes; closing cancels running
// work. Nothing chosen here is remembered. Paid requests whose outcome is
// unconfirmed are remembered for the session in `ImageTo3DConnection` (service, task and time only).

extension StudioStore {
    /// File › Generate a Replica from an Image…: opens the sheet only (no request), and only when nothing modal is shown.
    func generateReplicaFromMenu() {
        guard !menuCommandsBlockedByModalUI else { return }
        showReplicaGenerator = true
    }

    /// Review for Printing with Claude… from the replica sheet: closes it, then opens the review once it has gone
    /// (`presentPendingPrintReview`, called from the sheet's `onDismiss`).
    func openPrintReviewAfterReplica(_ request: PrintReviewRequest) {
        pendingPrintReview = request
        showReplicaGenerator = false
    }

    func presentPendingPrintReview() {
        guard let request = pendingPrintReview else { return }
        pendingPrintReview = nil
        guard localModels.contains(where: { $0.id == request.modelID }), !isPresentingSheet else { return }
        printReviewRequest = request
    }
}

/// Where the replica session saves its copy and records Activity: the store in the app, a stand-in in tests.
@MainActor protocol ReplicaLibraryHost: AnyObject {
    func addReplicaActivity(_ activity: Activity)
    /// Imports the file as a new library model and returns its ID, or nil when it couldn't be added.
    func importReplica(_ url: URL, intent: PartIntent?, sourceDetails: ModelSourceDetails) -> UUID?
}

extension StudioStore: ReplicaLibraryHost {
    func addReplicaActivity(_ activity: Activity) {
        activities.insert(activity, at: 0)
    }

    func importReplica(_ url: URL, intent: PartIntent?, sourceDetails: ModelSourceDetails) -> UUID? {
        guard importModel(url, intent: intent, sourceDetails: sourceDetails, origin: .replica) else { return nil }
        return selectedLocalID
    }
}

/// A finished model, read once and kept in memory so it can be processed again (another size, or upright) without
/// a new request.
struct GeneratedReplicaFile {
    let mesh: STLMesh
    let service: ImageTo3DService
    let sourceTaskID: String
    let sourceKind: ImageTo3DTaskKind
    /// The views the photos showed, for the review hand-off. No photo is kept.
    let views: [ImageTo3DPhotoView]
}

/// The sheet's run state. Lives and dies with the sheet.
@MainActor final class ReplicaGeneratorSession: ObservableObject {
    enum Phase: Equatable { case ready, generating, stopped, processing, processingFailed, processed, saved }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var progress: ImageTo3DProgress?
    @Published private(set) var stopping = false
    @Published private(set) var lastStop: ImageTo3DStop?
    /// The session record (`ImageTo3DConnection.unconfirmedRequests`) of `lastStop`, which the sheet already explains.
    @Published private(set) var lastStopRecordID: UUID?
    @Published private(set) var processingFraction = 0.0
    @Published private(set) var processingStage = ""
    @Published private(set) var processingProblem: String?
    /// False when processing failed in a way Process Again can only repeat (a model too detailed to simplify enough).
    @Published private(set) var processAgainCanHelp = true
    @Published private(set) var processed: ReplicaProcessed?
    @Published private(set) var preview: NSImage?
    @Published private(set) var savedModelIDs: [UUID] = []
    @Published private(set) var meshyReport: MeshyPrintabilityReport?
    @Published private(set) var analyzing = false
    @Published private(set) var analysisProblem: String?
    private(set) var generated: GeneratedReplicaFile?
    private(set) var lastInputs: ReplicaInputs?
    private(set) var lastUpAxis: ReplicaUpAxis = .z
    private(set) var estimate: ImageTo3DCostEstimate?
    /// The views sent with the latest generation.
    private(set) var requestedViews: [ImageTo3DPhotoView] = []
    private var options: ImageTo3DOptions?
    private var provider: ImageTo3DProvider?
    private var control: ReplicaRunControl?
    private var task: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?
    let connection: ImageTo3DConnection
    private let wallThicknessSamples: Int

    /// `connection` is the app-wide one unless a test passes its own.
    init(connection: ImageTo3DConnection? = nil, wallThicknessSamples: Int = wallThicknessMaximumSamples) {
        self.connection = connection ?? .shared
        self.wallThicknessSamples = wallThicknessSamples
    }

    var isRunning: Bool { phase == .generating || phase == .processing }
    var service: ImageTo3DService? { generated?.service ?? provider?.service }
    /// A paid model that isn't in the library: closing discards it.
    var hasUnsavedModel: Bool { generated != nil && savedModelIDs.isEmpty }

    /// Save to Library is allowed only for the result on show, made from the details typed now.
    func canSave(_ inputs: ReplicaInputs?) -> Bool {
        phase == .processed && processed != nil && inputs != nil && inputs == lastInputs
    }

    // MARK: Remote

    /// Sends the photos once. One photo goes to the single-image endpoint, two to four to the multi-view one.
    func start(provider: ImageTo3DProvider, views: [ImageTo3DViewImage], inputs: ReplicaInputs, higherDetail: Bool = false,
               host: ReplicaLibraryHost) {
        guard !isRunning, imageTo3DViewsProblem(views) == nil else { return }
        self.provider = provider
        let options = replicaGenerationOptions(for: provider.service, purpose: inputs.purpose, higherDetail: higherDetail)
        self.options = options
        estimate = provider.estimatedCost(for: options, photoCount: views.count)
        requestedViews = imageTo3DOrderedViews(views).map(\.view)
        lastStop = nil
        lastStopRecordID = nil
        runRemote(inputs: inputs, host: host) { sleep, proceed, report in
            await runImageTo3DGeneration(provider: provider, views: views, options: options, sleep: sleep, proceed: proceed,
                                         progress: report)
        }
    }

    /// One photo, as the front view.
    func start(provider: ImageTo3DProvider, image: ImageTo3DImage, inputs: ReplicaInputs, host: ReplicaLibraryHost) {
        start(provider: provider, views: [ImageTo3DViewImage(view: .front, image: image)], inputs: inputs, host: host)
    }

    /// Keep Waiting, Try Download Again or Try Conversion Again: carries on from the stop's resume point. Never
    /// sends the generation again.
    func resume(inputs: ReplicaInputs, host: ReplicaLibraryHost) {
        guard !isRunning, let stop = lastStop, let point = stop.resumePoint, replicaResumeAction(for: stop) != nil,
              let provider, provider.service == stop.service, let options else { return }
        runRemote(inputs: inputs, host: host) { sleep, _, report in
            await resumeImageTo3DGeneration(provider: provider, from: point, options: options, sleep: sleep, progress: report)
        }
    }

    private func runRemote(inputs: ReplicaInputs, host: ReplicaLibraryHost,
                           body: @escaping @Sendable (_ sleep: @escaping ImageTo3DSleep,
                                                      _ proceed: @escaping @Sendable () -> Bool,
                                                      _ report: @escaping @Sendable (ImageTo3DProgress) -> Void) async -> Result<ImageTo3DGeneratedModel, ImageTo3DStop>) {
        let control = ReplicaRunControl()
        self.control = control
        phase = .generating
        progress = nil
        stopping = false
        processingProblem = nil
        let sleep = replicaInterruptibleSleep(control)
        // Asked before each Tripo upload and before the create: a Stop pressed by then sends nothing more.
        let proceed: @Sendable () -> Bool = { !control.isStopRequested }
        let report: @Sendable (ImageTo3DProgress) -> Void = { [weak self] value in
            control.report(value)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if self?.control === control { self?.progress = value } }
            }
        }
        let connection = connection
        connection.beginWork()
        let task = Task { @MainActor [weak self] in
            let result = await body(sleep, proceed, report)
            connection.endWork()
            guard let self, self.control === control else {
                // The sheet closed. A paid request whose outcome is unknown, or a model nobody will see, is
                // remembered for the session so the next Generate asks first.
                switch result {
                case .failure(let stop):
                    connection.rememberUnconfirmed(stop)
                case .success(let model):
                    try? FileManager.default.removeItem(at: model.folder)
                    connection.rememberUnconfirmed(replicaUndeliveredStop(model))
                }
                return
            }
            await self.finishRemote(result, control: control, inputs: inputs, host: host)
        }
        control.attach(task)
        self.task = task
    }

    /// Reads and checks the downloaded model off the main actor (it can be 128 MB), then processes it.
    private func finishRemote(_ result: Result<ImageTo3DGeneratedModel, ImageTo3DStop>, control: ReplicaRunControl,
                              inputs: ReplicaInputs, host: ReplicaLibraryHost) async {
        switch result {
        case .failure(let stop):
            stopping = false
            stopped(stop, host: host)
        case .success(let model):
            let fileURL = model.fileURL
            let read = await Task.detached(priority: .userInitiated) { () -> Result<STLMesh, Error> in
                Result { try replicaReadModel(Data(contentsOf: fileURL, options: .mappedIfSafe)) }
            }.value
            try? FileManager.default.removeItem(at: model.folder)
            guard self.control === control else {
                connection.rememberUnconfirmed(replicaUndeliveredStop(model))
                return
            }
            stopping = false
            switch read {
            case .failure(ReplicaProcessingError.modelTooLarge(let limit)):
                // Final: reading it again would fail the same way, so there's no resume point.
                var final = ImageTo3DStop(reason: .modelTooLarge, stage: .downloading, service: model.service,
                                          taskID: model.conversionTaskID ?? model.sourceTaskID, detail: limit,
                                          requestKind: model.sourceKind, sourceTaskID: model.sourceTaskID)
                final.higherDetailRequested = options?.higherDetail ?? false
                stopped(final, host: host)
            case .failure(let error):
                let detail = (error as? ReplicaProcessingError)?.errorDescription ?? "Studio couldn’t read the downloaded file."
                stopped(ImageTo3DStop(reason: .downloadFailed, stage: .downloading, service: model.service,
                                      taskID: model.conversionTaskID ?? model.sourceTaskID, detail: detail,
                                      resumePoint: ImageTo3DResumePoint(sourceTaskID: model.sourceTaskID, sourceKind: model.sourceKind,
                                                                        conversionTaskID: model.conversionTaskID)),
                        host: host)
            case .success(let mesh):
                connection.confirmDelivered(service: model.service, sourceTaskID: model.sourceTaskID)
                generated = GeneratedReplicaFile(mesh: mesh, service: model.service, sourceTaskID: model.sourceTaskID,
                                                 sourceKind: model.sourceKind, views: requestedViews)
                lastStop = nil
                lastStopRecordID = nil
                meshyReport = nil
                analysisProblem = nil
                lastUpAxis = .z
                if control.isStopRequested {
                    lastInputs = inputs
                    processingProblem = "Stopped. The model \(model.service.title) made is still here: Process Again uses it without sending anything."
                    phase = .processingFailed
                } else {
                    beginProcessing(inputs: inputs, upAxis: .z)
                }
            }
        }
    }

    private func stopped(_ stop: ImageTo3DStop, host: ReplicaLibraryHost) {
        lastStop = stop
        lastStopRecordID = connection.rememberUnconfirmed(stop)
        phase = .stopped
        host.addReplicaActivity(Activity(title: "Generate Replica", detail: stop.activityDetail, success: false))
    }

    /// Stop: at the next safe point (never while a credit-spending request is in flight).
    func stop() {
        guard isRunning, !stopping else { return }
        stopping = true
        control?.requestStop()
    }

    /// The sheet closed: stop everything now.
    func cancelAll() {
        control?.cancelImmediately()
        control = nil
        task?.cancel()
        task = nil
        analysisTask?.cancel()
        analysisTask = nil
    }

    // MARK: Local

    /// Processes the paid model again on this Mac (another size, or the other way up). Free: nothing is sent.
    func process(inputs: ReplicaInputs, upAxis: ReplicaUpAxis) {
        guard !isRunning, phase != .saved, generated != nil else { return }
        beginProcessing(inputs: inputs, upAxis: upAxis)
    }

    /// Runs the local pipeline off the main actor and shows the result for the seller to check. Nothing is saved
    /// until Save to Library.
    private func beginProcessing(inputs: ReplicaInputs, upAxis: ReplicaUpAxis) {
        guard let generated else { return }
        let control = ReplicaRunControl()
        self.control = control
        lastInputs = inputs
        lastUpAxis = upAxis
        phase = .processing
        stopping = false
        processingProblem = nil
        processingFraction = 0
        processingStage = "Reading the model…"
        processed = nil
        preview = nil
        processAgainCanHelp = true
        let mesh = generated.mesh, samples = wallThicknessSamples, ceiling = inputs.purpose.triangleCeiling
        let report: @Sendable (Double, String) -> Void = { [weak self] fraction, stage in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.control === control, !control.isStopRequested else { return }
                    self.processingFraction = fraction
                    self.processingStage = stage
                }
            }
        }
        let task = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(ReplicaProcessed, NSImage?), Error> in
                Result {
                    let processed = try processReplicaModel(mesh: mesh, size: inputs.size, upAxis: upAxis, triangleTarget: ceiling,
                                                            wallThicknessSamples: samples,
                                                            progress: { report($0, $1) }, isCancelled: { control.isStopRequested })
                    if control.isStopRequested { throw MeshToolError.cancelled }
                    return (processed, replicaPreviewImage(processed.mesh, isCancelled: { control.isStopRequested }))
                }
            }.value
            guard let self, self.control === control else { return }
            self.finishProcessing(outcome, stopped: control.isStopRequested)
        }
        control.attach(task)
        self.task = task
    }

    private func finishProcessing(_ outcome: Result<(ReplicaProcessed, NSImage?), Error>, stopped: Bool) {
        stopping = false
        switch outcome {
        case .success(let (processed, image)) where !stopped:
            self.processed = processed
            preview = image
            phase = .processed
        case .success:
            failProcessing(MeshToolError.cancelled.localizedDescription)
        case .failure(let error):
            let cancelled = stopped || (error as? MeshToolError) == .cancelled
            failProcessing(cancelled ? MeshToolError.cancelled.localizedDescription
                                     : replicaProcessingFailureMessage(error, higherDetail: options?.higherDetail ?? false),
                           processAgainCanHelp: cancelled || replicaProcessingFailureAllowsProcessAgain(error))
        }
    }

    private func failProcessing(_ message: String, processAgainCanHelp: Bool = true) {
        processingProblem = message
        self.processAgainCanHelp = processAgainCanHelp
        phase = .processingFailed
    }

    /// Saves the checked result as one library copy, "<name> (replica)". Nothing is sent.
    func save(inputs: ReplicaInputs?, host: ReplicaLibraryHost) {
        guard canSave(inputs), let inputs, let processed, let generated else { return }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(replicaTempFolderPrefix)\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent(exportFileName(modelName: replicaCopyName(inputs.name), fileExtension: "stl"))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try processed.stlData.write(to: url, options: .atomic)
        } catch {
            processingProblem = "Studio couldn’t write the replica to a temporary file, so it wasn’t saved."
            return
        }
        guard let id = host.importReplica(url, intent: inputs.purpose.partIntent,
                                          sourceDetails: replicaSourceDetails(service: generated.service)) else {
            processingProblem = "The replica couldn’t be added to your library."
            return
        }
        savedModelIDs.append(id)
        processingProblem = nil
        phase = .saved
        host.addReplicaActivity(Activity(title: "Generate Replica",
                                         detail: replicaSavedActivityDetail(service: generated.service, triangles: processed.mesh.triangleCount,
                                                                             estimate: estimate, photoCount: generated.views.count),
                                         success: true))
    }

    // MARK: Meshy's free check

    /// Meshy's Analyze Printability (free) of its own model at `longestSideMM`. Read-only for credits; sent once. Meshy
    /// documents it for Image to 3D and Multi-Image to 3D tasks alike.
    func analyzeWithMeshy(longestSideMM: Double, host: ReplicaLibraryHost) {
        guard !analyzing, let client = provider as? MeshyClient, let generated, generated.service == .meshy,
              generated.sourceKind.isGeneration else { return }
        analyzing = true
        analysisProblem = nil
        let connection = connection
        connection.beginWork()
        analysisTask = Task { @MainActor [weak self] in
            defer { connection.endWork() }
            do {
                let report = try await client.analyzePrintability(ofTask: generated.sourceTaskID, longestSideMM: longestSideMM)
                self?.meshyReport = report
                host.addReplicaActivity(Activity(title: "Check Printability", detail: replicaAnalysisActivityDetail(report), success: true))
            } catch is CancellationError {
                self?.analysisProblem = "Stopped."
            } catch {
                self?.analysisProblem = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription)
                host.addReplicaActivity(Activity(title: "Check Printability",
                                                 detail: "Meshy: \((error as? ImageTo3DError)?.activityDetail ?? "failed")", success: false))
            }
            self?.analyzing = false
        }
    }
}

/// The stop recorded when a model arrived but nobody kept it (the sheet closed during the download or the read):
/// paid for, and only on the service's dashboard now.
func replicaUndeliveredStop(_ model: ImageTo3DGeneratedModel) -> ImageTo3DStop {
    ImageTo3DStop(reason: .cancelled, stage: .downloading, service: model.service,
                  taskID: model.conversionTaskID ?? model.sourceTaskID, detail: "",
                  resumePoint: ImageTo3DResumePoint(sourceTaskID: model.sourceTaskID, sourceKind: model.sourceKind,
                                                    conversionTaskID: model.conversionTaskID))
}

/// A three-quarter render of the replica for the summary, or nil when it can't be drawn.
func replicaPreviewImage(_ mesh: STLMesh, size: Int = 220, isCancelled: () -> Bool = { false }) -> NSImage? {
    guard let rgba = renderMeshRGBA(mesh, size: size, camera: .thumbnail, style: .thumbnail, rasterBudget: thumbnailRasterBudget,
                                    isCancelled: isCancelled),
          let prepared = prepareRenderedImage(rgba: rgba, width: size, height: size) else { return nil }
    return NSImage(data: prepared.data)
}

// MARK: - Sheet

/// One photo slot in the sheet: the prepared photo (memory only), its preview, the file's name and any problem.
struct ReplicaPhotoSlot {
    var image: ImageTo3DImage?
    var preview: NSImage?
    var name: String?
    var problem: String?
    var preparing = false

    /// A photo that couldn't be prepared: the slot shows why and holds no photo, so a failed Replace… never leaves the
    /// old photo to be sent.
    static func failed(_ problem: String) -> ReplicaPhotoSlot { ReplicaPhotoSlot(problem: problem) }
}

struct ReplicaGeneratorSheet: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = ImageTo3DConnection.shared
    @StateObject private var session = ReplicaGeneratorSession()

    @State private var slots: [ImageTo3DPhotoView: ReplicaPhotoSlot] = [:]
    @State private var photoJobs: [ImageTo3DPhotoView: Task<Void, Never>] = [:]
    @State private var dropTarget: ImageTo3DPhotoView?
    /// Never remembered: it costs more every time.
    @State private var higherDetail = false
    /// What the cost shown covered when Generate was pressed; the send goes ahead only if nothing changed since.
    @State private var pendingPlan: ReplicaRequestPlan?
    @State private var name = ""
    @State private var axis: ReplicaSizeAxis = .height
    @State private var sizeText = ""
    @State private var purpose: ReplicaPurpose = .display
    @State private var balanceLine: String?
    @State private var checkingBalance = false
    @State private var startProblem: String?
    @State private var consentRequest: ImageSharingConsentRequest?
    @State private var confirmGenerateAgain = false
    @State private var closeWarning: ReplicaCloseWarning?

    private var service: ImageTo3DService { connection.selectedService }
    /// The chosen photos in slot order.
    private var views: [ImageTo3DViewImage] {
        ImageTo3DPhotoView.allCases.compactMap { view in slots[view]?.image.map { ImageTo3DViewImage(view: view, image: $0) } }
    }
    private var preparingPhotos: Bool { slots.values.contains { $0.preparing } }
    private var estimate: ImageTo3DCostEstimate {
        replicaCostEstimate(service: service, purpose: purpose, photoCount: max(1, views.count), higherDetail: higherDetail,
                            tripoRegion: connection.tripoRegion)
    }
    private var currentPlan: ReplicaRequestPlan {
        ReplicaRequestPlan(service: service, views: views.map(\.view),
                           higherDetail: higherDetail && replicaHigherDetailAvailable(for: purpose), credits: estimate.credits)
    }
    private var inputs: ReplicaInputs? { replicaInputs(name: name, axis: axis, sizeText: sizeText, purpose: purpose) }
    private var blockedReasons: [String] {
        let hasFront = slots[.front]?.image != nil
        return replicaGenerateBlockedReasons(photoReady: hasFront, photoPreparing: preparingPhotos, nameText: name, sizeText: sizeText,
                                             service: service, hasKey: connection.hasKey(service),
                                             extraPhotosWithoutFront: !hasFront && !views.isEmpty)
    }
    private var inputsLocked: Bool { session.isRunning || session.phase == .saved }
    private var currentCloseWarning: ReplicaCloseWarning? {
        replicaCloseWarning(hasUnsavedModel: session.hasUnsavedModel, lastStop: session.lastStop, service: session.service)
    }
    private var unconfirmedNotice: String? {
        replicaUnconfirmedNotice(connection.unconfirmedRequests, overflowed: connection.unconfirmedRequestsOverflowed,
                                 excluding: session.phase == .stopped ? session.lastStopRecordID : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Generate a replica from an image").font(.title2.weight(.bold))
                Text("\(service.title) makes a 3D model from a front photo, and up to three more views if you add them. Studio then scales it to the size you give, repairs it on this Mac and shows you the result before saving it as a new model in your library. Nothing is uploaded to Slant.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider()
            Form {
                photoSection
                detailsSection
                serviceSection
                if session.phase != .ready { runSection }
            }
            .formStyle(.grouped)
            Divider()
            footer
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 520, idealHeight: 720)
        .interactiveDismissDisabled(session.isRunning || currentCloseWarning != nil)
        .imageSharingConsent($consentRequest)
        .onChange(of: purpose) { _, newPurpose in
            // A functional part is simplified to 20,000 triangles: higher detail would be paid for and lost.
            if !replicaHigherDetailAvailable(for: newPurpose) { higherDetail = false }
        }
        .onDisappear {
            for job in photoJobs.values { job.cancel() }
            photoJobs = [:]
            slots = [:]
            session.cancelAll()
        }
    }

    // MARK: Sections

    private var photoSection: some View {
        Section {
            // A fixed 2 × 2 grid: two 230 pt cells and 12 pt between them is 472 pt, inside a grouped form's row
            // in the 560 pt minimum-width sheet (about 500 pt after the form's margins).
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) { photoSlot(.front); photoSlot(.left) }
                HStack(alignment: .top, spacing: 12) { photoSlot(.back); photoSlot(.right) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(ImageTo3DPhotoView.allCases.filter { slots[$0]?.problem != nil }) { view in
                Label("\(view.title): \(slots[view]?.problem ?? "")", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(replicaPhotoAdvice)
                Text(replicaPhotoSideAdvice)
                Text(replicaPhotoDistanceAdvice)
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Photos")
        } footer: {
            Text("Studio resizes each photo and removes its location, camera and other hidden details before sending it. Photos aren’t saved.")
                .settingsFooterLayout()
        }
    }

    /// One labelled slot, 230 pt wide: an 88 pt drop area beside its label and buttons. Choose… or drop a photo;
    /// Remove clears it.
    private func photoSlot(_ view: ImageTo3DPhotoView) -> some View {
        let slot = slots[view] ?? ReplicaPhotoSlot()
        return HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(dropTarget == view ? Color.accentColor : Color.secondary.opacity(0.4),
                                  style: StrokeStyle(lineWidth: 1, dash: slot.preview == nil ? [4] : []))
                if let preview = slot.preview {
                    Image(nsImage: preview).resizable().scaledToFit().padding(4)
                        .accessibilityLabel("\(view.title) photo")
                } else if slot.preparing {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Drop a photo here")
                        .font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(6)
                }
            }
            .frame(width: 88, height: 88)
            .dropDestination(for: URL.self) { urls, _ in
                guard !inputsLocked, let url = urls.first(where: \.isFileURL) else { return false }
                choosePhoto(url, for: view)
                return true
            } isTargeted: { targeted in
                if targeted { dropTarget = view } else if dropTarget == view { dropTarget = nil }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(replicaPhotoSlotLabel(view))
                    .font(.caption.weight(view == .front ? .semibold : .regular))
                    .help(replicaPhotoSlotHelp(view) ?? "")
                if let name = slot.name {
                    Text(name).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                HStack(spacing: 6) {
                    Button(slot.image == nil ? "Choose…" : "Replace…") { pickPhoto(for: view) }
                        .controlSize(.small)
                        .disabled(inputsLocked || slot.preparing)
                        .accessibilityLabel(slot.image == nil ? "Choose \(view.title.lowercased()) photo" : "Replace \(view.title.lowercased()) photo")
                    if slot.image != nil || slot.problem != nil {
                        Button("Remove") { removePhoto(view) }
                            .controlSize(.small)
                            .disabled(inputsLocked)
                            .accessibilityLabel("Remove \(view.title.lowercased()) photo")
                    }
                }
            }
            .frame(width: 132, alignment: .leading)
        }
        .frame(width: 230, alignment: .leading)
        .help(replicaPhotoSlotHelp(view) ?? "")
    }

    private var detailsSection: some View {
        Section {
            TextField("Name", text: $name, prompt: Text("Such as Dragon figure"))
                .accessibilityLabel("Name")
            LabeledContent("Real size") {
                HStack(spacing: 6) {
                    Picker("Measured along", selection: $axis) {
                        ForEach(ReplicaSizeAxis.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                    .accessibilityLabel("Measured along")
                    .fixedSize()
                    TextField("Size in millimetres", text: $sizeText, prompt: Text("Such as 120"))
                        .labelsHidden()
                        .accessibilityLabel("Size in millimetres")
                        .frame(width: 80)
                    Text("mm").foregroundStyle(.secondary)
                }
            }
            if !sizeText.isEmpty, let problem = replicaSizeProblem(sizeText) {
                Text(problem).font(.caption).foregroundStyle(.orange)
            }
            Picker("Purpose", selection: $purpose) {
                ForEach(ReplicaPurpose.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            if purpose == .functional {
                Label(replicaFunctionalPartWarning, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Replica")
        } footer: {
            Text("Neither service knows how big the object really is, so Studio scales the model to this measurement. Studio asks the service for more detail than it keeps, then simplifies on this Mac: a display piece keeps up to \(replicaDisplayTriangleCeiling.formatted()) triangles; a functional part \(replicaTriangleTarget.formatted()), so Reinforce and Auto-improve can work on it. The purpose is also passed to Review for Printing with Claude.")
                .settingsFooterLayout()
        }
        .disabled(inputsLocked)
    }

    private var serviceSection: some View {
        Section {
            LabeledContent("Service") {
                HStack {
                    Text(service.title)
                    Text(connection.hasKey(service) ? "Key saved" : "No key").foregroundStyle(.secondary)
                }
            }
            Toggle("Higher detail", isOn: $higherDetail)
                .disabled(inputsLocked || !replicaHigherDetailAvailable(for: purpose))
            Text(replicaHigherDetailAvailable(for: purpose) ? replicaHigherDetailNote(service: service) : replicaHigherDetailFunctionalNote)
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(replicaCostLine(estimate, photoCount: views.count)).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Change in Settings…") { store.requestSettings(.designTools) }
                    .help("Choose Meshy or Tripo and add its API key in Settings › Design Tools › 3D generation.")
                Button("Check Balance") { checkBalance() }
                    .disabled(!connection.hasKey(service) || checkingBalance || session.isRunning)
                    .help("Reads your \(service.title) credits. Nothing is spent.")
                if checkingBalance { ProgressView().controlSize(.small) }
            }
            if let balanceLine {
                Text(balanceLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let unconfirmedNotice {
                Label(unconfirmedNotice, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("3D service")
        } footer: {
            Text(replicaRightsNote).settingsFooterLayout()
        }
    }

    @ViewBuilder
    private var runSection: some View {
        Section {
            switch session.phase {
            case .ready:
                EmptyView()
            case .generating:
                VStack(alignment: .leading, spacing: 6) {
                    if let percent = session.progress?.percent {
                        ProgressView(value: Double(percent), total: 100)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                    Text(replicaProgressLine(session.progress, service: session.service ?? service, stopping: session.stopping))
                        .font(.callout).foregroundStyle(.secondary)
                    if let task = session.progress?.taskID {
                        Text("Task \(task)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("Studio checks every few seconds; a model usually takes a few minutes. Stop leaves the task running at the service, which may still charge for it.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .stopped:
                if let stop = session.lastStop { stopView(stop) }
            case .processing:
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: session.processingFraction)
                    Text(session.stopping ? "Stopping…" : session.processingStage).font(.callout).foregroundStyle(.secondary)
                }
            case .processingFailed:
                VStack(alignment: .leading, spacing: 6) {
                    Label(session.processingProblem ?? "The replica wasn’t processed.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    if session.processAgainCanHelp {
                        Text("The model the service made is still here. Change the details above if needed, then Process Again. Nothing is sent or charged.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            case .processed, .saved:
                if let processed = session.processed { resultView(processed) }
            }
        } header: {
            switch session.phase {
            case .processed: Text("Check before saving")
            case .saved: Text("Saved to your library")
            default: Text("Progress")
            }
        }
    }

    @ViewBuilder
    private func stopView(_ stop: ImageTo3DStop) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(stop.userMessage, systemImage: stop.reason == .notSent ? "info.circle" : "exclamationmark.triangle")
                .foregroundStyle(stop.reason == .notSent ? Color.secondary : Color.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if let note = replicaCreditsNote(stop) {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            if let action = replicaResumeAction(for: stop) {
                Text(replicaResumeNote(stop, action: action))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if session.generated != nil {
                Text("The model made earlier in this sheet is still here: Process Again uses it without sending anything.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func resultView(_ processed: ReplicaProcessed) -> some View {
        HStack(alignment: .top, spacing: 14) {
            if let preview = session.preview {
                Image(nsImage: preview).resizable().scaledToFit().frame(width: 140, height: 140)
                    .accessibilityLabel("Rendered view of the replica")
            }
            VStack(alignment: .leading, spacing: 4) {
                if session.phase == .saved, let id = session.savedModelIDs.last, let model = store.localModels.first(where: { $0.id == id }) {
                    Text("“\(model.name)”").font(.callout.weight(.semibold))
                }
                ForEach(Array(replicaSummaryLines(processed).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if replicaChecksFoundNoProblems(processed) {
                    Text(replicaNoProblemsLine).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        if session.phase == .processed {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Which way is up?", selection: upAxisBinding) {
                    Text("As Made").tag(ReplicaUpAxis.z)
                    Text("Turned Upright").tag(ReplicaUpAxis.y)
                }
                .pickerStyle(.segmented)
                Text("If the picture shows the model lying on its back, choose Turned Upright. Studio processes it again on this Mac; nothing is sent or charged.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        DisclosureGroup("What Studio changed") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(processed.changes.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        if let problem = session.processingProblem {
            Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
        if session.phase == .processed, inputs != session.lastInputs {
            Text("The details above changed since this result was made. Process Again to apply them before saving.")
                .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        }
        if session.generated?.service == .meshy, session.generated?.sourceKind.isGeneration == true {
            meshyAnalysis(processed)
        }
    }

    /// The up-direction choice: changing it processes the paid model again in memory.
    private var upAxisBinding: Binding<ReplicaUpAxis> {
        Binding(get: { session.processed?.upAxis ?? session.lastUpAxis },
                set: { axis in
                    guard let use = inputs ?? session.lastInputs else { return }
                    session.process(inputs: use, upAxis: axis)
                })
    }

    @ViewBuilder
    private func meshyAnalysis(_ processed: ReplicaProcessed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Check Printability with Meshy") {
                    session.analyzeWithMeshy(longestSideMM: Double(processed.extentMM.max()), host: store)
                }
                .disabled(session.analyzing || session.meshyReport != nil)
                .help("Free. Meshy checks its own model (before Studio’s repair) for holes and thin walls at this size.")
                if session.analyzing { ProgressView().controlSize(.small) }
            }
            if let report = session.meshyReport {
                Text("\(report.summary) This is Meshy’s view of its original model, before Studio’s repair.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if let problem = session.analysisProblem {
                Text(problem).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Free: Meshy checks its own model for holes and thin walls at this size.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(alignment: .center, spacing: 12) {
            if [.ready, .stopped, .processingFailed, .processed].contains(session.phase) {
                if let startProblem {
                    Label(startProblem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                } else if let reason = blockedReasons.first {
                    Text(reason).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                // Beside the reason, never squeezing the buttons: one line, truncated if it must be.
                Text(replicaFooterCostLabel(estimate)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !connection.hasKey(service) {
                    Button("Open Settings") { store.requestSettings(.designTools) }
                }
            }
            Spacer()
            if session.isRunning {
                Button("Stop") { session.stop() }.disabled(session.stopping)
            }
            Button("Close") { close() }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isRunning)
            switch session.phase {
            case .ready:
                generateButton
            case .stopped:
                if let stop = session.lastStop, let action = replicaResumeAction(for: stop) {
                    Button(action.title) { if let inputs { session.resume(inputs: inputs, host: store) } }
                        .disabled(inputs == nil)
                }
                if session.generated != nil { processAgainButton }
                generateButton
            case .processingFailed:
                if session.processAgainCanHelp { processAgainButton }
                generateButton
            case .processed:
                if inputs != session.lastInputs { processAgainButton }
                generateButton
                Button("Save to Library") { session.save(inputs: inputs, host: store) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!session.canSave(inputs))
                    .help("Adds this replica to your library as a new model. Nothing is sent.")
            case .saved:
                Button("Select in Library") { selectInLibrary() }
                Button("Review for Printing with Claude…") { reviewForPrinting() }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.savedModelIDs.isEmpty || session.processed == nil)
            case .generating, .processing:
                EmptyView()
            }
        }
        .padding(20)
        .confirmationDialog("Generate another model?", isPresented: $confirmGenerateAgain, titleVisibility: .visible) {
            Button("Generate Again") {
                let plan = pendingPlan
                DispatchQueue.main.async { if let plan { startWithConsent(plan) } }
            }
            Button("Don’t Generate", role: .cancel) { pendingPlan = nil }
                .keyboardShortcut(.defaultAction)
        } message: {
            // The message's first part covers this sheet's own stop, so the notice leaves it out.
            Text(replicaGenerateAgainMessage(lastStop: session.lastStop, modelAlreadyMade: session.generated != nil,
                                             earlierNotice: replicaUnconfirmedNotice(connection.unconfirmedRequests,
                                                                                     overflowed: connection.unconfirmedRequestsOverflowed,
                                                                                     excluding: session.lastStopRecordID),
                                             estimate: estimate))
        }
        .confirmationDialog(closeWarning?.title ?? "", isPresented: closeWarningShown, titleVisibility: .visible,
                            presenting: closeWarning) { warning in
            Button(warning.confirmTitle, role: .destructive) { store.showReplicaGenerator = false }
            Button("Keep Open", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: { warning in
            Text(warning.message)
        }
    }

    private var closeWarningShown: Binding<Bool> {
        Binding(get: { closeWarning != nil }, set: { if !$0 { closeWarning = nil } })
    }

    private var generateButtonTitle: String { replicaGenerateButtonTitle(firstRequest: session.phase == .ready) }

    private var processAgainButton: some View {
        Button("Process Again") { if let inputs { session.process(inputs: inputs, upAxis: session.lastUpAxis) } }
            .disabled(inputs == nil)
            .help("Processes the model you already have again on this Mac. Nothing is sent or charged.")
    }

    /// Never the default button and no shortcut: it spends the seller's credits.
    /// The estimated credits stay visible in the footer (`replicaFooterCostLabel`), not only in its help.
    @ViewBuilder
    private var generateButton: some View {
        let button = Button(generateButtonTitle) { requestGenerate() }
            .disabled(!blockedReasons.isEmpty || session.isRunning)
            .help("Sends the \(views.count > 1 ? "photos" : "photo") to \(service.title) once. \(estimate.summary)")
        if session.phase == .processed {
            button
        } else {
            button.buttonStyle(.borderedProminent)
        }
    }

    // MARK: Actions

    private func pickPhoto(for view: ImageTo3DPhotoView) {
        let panel = NSOpenPanel()
        panel.message = replicaPhotoPickerMessage(view)
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choosePhoto(url, for: view)
    }

    private func removePhoto(_ view: ImageTo3DPhotoView) {
        guard !inputsLocked else { return }
        photoJobs[view]?.cancel()
        photoJobs[view] = nil
        slots[view] = nil
        startProblem = nil
    }

    /// Prepares the photo for the 3D services (2048 px, no metadata, transparency kept) off the main actor.
    private func choosePhoto(_ url: URL, for view: ImageTo3DPhotoView) {
        guard !inputsLocked else { return }
        photoJobs[view]?.cancel()
        var slot = slots[view] ?? ReplicaPhotoSlot()
        slot.preparing = true
        slot.problem = nil
        slots[view] = slot
        startProblem = nil
        let job = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PreparedImage, Error> in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return Result { try prepareImageForSharing(at: url, profile: .imageTo3D) }
            }.value
            guard !Task.isCancelled else { return }
            photoJobs[view] = nil
            switch result {
            case .success(let prepared):
                let image = ImageTo3DImage(data: prepared.data, mediaType: prepared.mediaType.rawValue)
                if let problem = imageTo3DImageProblem(image) {
                    slots[view] = .failed(problem)
                } else {
                    slots[view] = ReplicaPhotoSlot(image: image, preview: NSImage(data: prepared.data), name: url.lastPathComponent)
                }
            case .failure(let error):
                slots[view] = .failed(error.localizedDescription)
            }
        }
        photoJobs[view] = job
    }

    private func checkBalance() {
        let chosen = service
        balanceLine = nil
        let provider: ImageTo3DProvider
        do { provider = try connection.provider(for: chosen) } catch {
            balanceLine = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription)
            return
        }
        checkingBalance = true
        connection.beginWork()
        Task { @MainActor in
            defer { checkingBalance = false; connection.endWork() }
            do {
                let balance = try await provider.readBalance()
                if connection.selectedService == chosen { balanceLine = balance.summary }
            } catch {
                if connection.selectedService == chosen {
                    balanceLine = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription)
                }
            }
        }
    }

    /// Captures what the cost shown covers, then asks first when anything may already have been charged.
    private func requestGenerate() {
        startProblem = nil
        guard blockedReasons.isEmpty, !session.isRunning, imageTo3DViewsProblem(views) == nil else { return }
        let plan = currentPlan
        if replicaGenerateNeedsConfirmation(lastStop: session.lastStop, modelAlreadyMade: session.generated != nil,
                                            earlierUnconfirmed: connection.hasUnconfirmedRequests) {
            pendingPlan = plan
            confirmGenerateAgain = true
        } else {
            startWithConsent(plan)
        }
    }

    /// One consent per service covers all its photos.
    private func startWithConsent(_ plan: ReplicaRequestPlan) {
        pendingPlan = nil
        runWithImageSharingConsent(plan.service.sharingService, request: $consentRequest) { start(plan) }
    }

    /// Sends only what the seller saw priced: the same service, photos, Higher detail and touch-up choice.
    private func start(_ plan: ReplicaRequestPlan) {
        guard blockedReasons.isEmpty, !session.isRunning, let inputs else { return }
        guard currentPlan == plan else {
            startProblem = replicaPlanChangedMessage(buttonTitle: generateButtonTitle)
            return
        }
        let provider: ImageTo3DProvider
        do { provider = try connection.provider(for: plan.service) } catch {
            startProblem = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription)
            return
        }
        session.start(provider: provider, views: views, inputs: inputs, higherDetail: plan.higherDetail, host: store)
    }

    private func close() {
        guard !session.isRunning else { return }
        if let warning = currentCloseWarning { closeWarning = warning } else { store.showReplicaGenerator = false }
    }

    private func selectInLibrary() {
        guard let id = session.savedModelIDs.last, let model = store.localModels.first(where: { $0.id == id }) else { return }
        store.destination = .models
        store.select(model)
        store.showReplicaGenerator = false
    }

    private func reviewForPrinting() {
        guard let id = session.savedModelIDs.last, store.localModels.contains(where: { $0.id == id }),
              let processed = session.processed, let inputs = session.lastInputs, let service = session.generated?.service else { return }
        let context = replicaPrintReviewContext(service: service, size: processed.size, purpose: inputs.purpose,
                                                meshyReport: session.meshyReport, views: session.generated?.views ?? [.front])
        store.openPrintReviewAfterReplica(PrintReviewRequest(modelID: id, context: context))
    }
}
