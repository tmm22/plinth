import SwiftUI
import UniformTypeIdentifiers

// The Generate a Replica from an Image sheet (ReplicaGenerator.swift holds the pure pipeline and rules). Opened from
// Models › Import and File; never from a shortcut. Everything typed or chosen here, the photo and the downloaded model
// live in this sheet's memory and go when it closes; closing cancels running work.

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

/// A finished model kept in memory so it can be processed again (another size, or upright) without a new request.
struct GeneratedReplicaFile {
    let data: Data
    let format: ImageTo3DOutputFormat
    let service: ImageTo3DService
    let sourceTaskID: String
    let sourceKind: ImageTo3DTaskKind
}

/// The sheet's run state. Lives and dies with the sheet.
@MainActor final class ReplicaGeneratorSession: ObservableObject {
    enum Phase: Equatable { case ready, generating, stopped, processing, processingFailed, saved }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var progress: ImageTo3DProgress?
    @Published private(set) var stopping = false
    @Published private(set) var lastStop: ImageTo3DStop?
    @Published private(set) var processingFraction = 0.0
    @Published private(set) var processingStage = ""
    @Published private(set) var processingProblem: String?
    @Published private(set) var processed: ReplicaProcessed?
    @Published private(set) var preview: NSImage?
    @Published private(set) var savedModelIDs: [UUID] = []
    @Published private(set) var meshyReport: MeshyPrintabilityReport?
    @Published private(set) var analyzing = false
    @Published private(set) var analysisProblem: String?
    private(set) var generated: GeneratedReplicaFile?
    private(set) var lastInputs: ReplicaInputs?
    private(set) var estimate: ImageTo3DCostEstimate?
    private var provider: ImageTo3DProvider?
    private var control: ReplicaRunControl?
    private var task: Task<Void, Never>?
    private var analysisTask: Task<Void, Never>?

    var isRunning: Bool { phase == .generating || phase == .processing }
    var service: ImageTo3DService? { generated?.service ?? provider?.service }
    /// A paid model that isn't in the library: closing discards it.
    var hasUnsavedModel: Bool { generated != nil && savedModelIDs.isEmpty }

    // MARK: Remote

    func start(provider: ImageTo3DProvider, image: ImageTo3DImage, inputs: ReplicaInputs, store: StudioStore) {
        guard !isRunning else { return }
        self.provider = provider
        let options = replicaGenerationOptions(for: provider.service)
        estimate = provider.estimatedCost(for: options)
        lastStop = nil
        runRemote(inputs: inputs, store: store) { sleep, report in
            await runImageTo3DGeneration(provider: provider, image: image, options: options, sleep: sleep, progress: report)
        }
    }

    /// Keep Waiting, Try Download Again or Try Conversion Again: carries on from the stop's resume point. Never
    /// sends the generation again.
    func resume(inputs: ReplicaInputs, store: StudioStore) {
        guard !isRunning, let stop = lastStop, let point = stop.resumePoint, replicaResumeAction(for: stop) != nil,
              let provider, provider.service == stop.service else { return }
        let options = replicaGenerationOptions(for: provider.service)
        runRemote(inputs: inputs, store: store) { sleep, report in
            await resumeImageTo3DGeneration(provider: provider, from: point, options: options, sleep: sleep, progress: report)
        }
    }

    private func runRemote(inputs: ReplicaInputs, store: StudioStore,
                           body: @escaping @Sendable (_ sleep: @escaping ImageTo3DSleep,
                                                      _ report: @escaping @Sendable (ImageTo3DProgress) -> Void) async -> Result<ImageTo3DGeneratedModel, ImageTo3DStop>) {
        let control = ReplicaRunControl()
        self.control = control
        phase = .generating
        progress = nil
        stopping = false
        processingProblem = nil
        let sleep = replicaInterruptibleSleep(control)
        let report: @Sendable (ImageTo3DProgress) -> Void = { [weak self] value in
            control.report(value)
            DispatchQueue.main.async {
                MainActor.assumeIsolated { if self?.control === control { self?.progress = value } }
            }
        }
        ImageTo3DConnection.shared.beginWork()
        let task = Task { @MainActor [weak self] in
            let result = await body(sleep, report)
            ImageTo3DConnection.shared.endWork()
            guard let self, self.control === control else {
                if case .success(let model) = result { try? FileManager.default.removeItem(at: model.folder) }
                return
            }
            self.finishRemote(result, inputs: inputs, store: store)
        }
        control.attach(task)
        self.task = task
    }

    private func finishRemote(_ result: Result<ImageTo3DGeneratedModel, ImageTo3DStop>, inputs: ReplicaInputs, store: StudioStore) {
        stopping = false
        switch result {
        case .success(let model):
            defer { try? FileManager.default.removeItem(at: model.folder) }
            do {
                let data = try Data(contentsOf: model.fileURL)
                generated = GeneratedReplicaFile(data: data, format: model.format, service: model.service,
                                                 sourceTaskID: model.sourceTaskID, sourceKind: model.sourceKind)
            } catch {
                let stop = ImageTo3DStop(reason: .downloadFailed, stage: .downloading, service: model.service,
                                         taskID: model.conversionTaskID ?? model.sourceTaskID,
                                         detail: "Studio couldn’t read the downloaded file.",
                                         resumePoint: ImageTo3DResumePoint(sourceTaskID: model.sourceTaskID, sourceKind: model.sourceKind,
                                                                           conversionTaskID: model.conversionTaskID))
                stopped(stop, store: store)
                return
            }
            lastStop = nil
            process(inputs: inputs, upAxis: .z, store: store)
        case .failure(let stop):
            stopped(stop, store: store)
        }
    }

    private func stopped(_ stop: ImageTo3DStop, store: StudioStore) {
        lastStop = stop
        phase = .stopped
        store.activities.insert(Activity(title: "Generate Replica", detail: stop.activityDetail, success: false), at: 0)
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

    /// Processes the downloaded model on this Mac and saves one library copy. Free: nothing is sent.
    func process(inputs: ReplicaInputs, upAxis: ReplicaUpAxis, store: StudioStore) {
        guard let generated, phase != .processing, phase != .generating else { return }
        let control = ReplicaRunControl()
        self.control = control
        lastInputs = inputs
        phase = .processing
        stopping = false
        processingProblem = nil
        processingFraction = 0
        processingStage = "Reading the model…"
        let data = generated.data, format = generated.format, service = generated.service
        let copyName = replicaCopyName(inputs.name, upright: upAxis == .y)
        let report: @Sendable (Double, String) -> Void = { [weak self] fraction, stage in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.control === control, !control.isStopRequested else { return }
                    self.processingFraction = fraction
                    self.processingStage = stage
                }
            }
        }
        task = Task { @MainActor [weak self] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(ReplicaProcessed, URL, NSImage?), Error> in
                Result {
                    let processed = try processReplicaModel(data, format: format, size: inputs.size, upAxis: upAxis,
                                                            progress: { report($0, $1) }, isCancelled: { control.isStopRequested })
                    if control.isStopRequested { throw MeshToolError.cancelled }
                    let image = replicaPreviewImage(processed.mesh, isCancelled: { control.isStopRequested })
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(replicaTempFolderPrefix)\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
                    let url = folder.appendingPathComponent(exportFileName(modelName: copyName, fileExtension: "stl"))
                    do { try processed.stlData.write(to: url, options: .atomic) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return (processed, url, image)
                }
            }.value
            guard let self, self.control === control else {
                if case .success(let value) = outcome { try? FileManager.default.removeItem(at: value.1.deletingLastPathComponent()) }
                return
            }
            self.finishProcessing(outcome, inputs: inputs, service: service, store: store, stopped: control.isStopRequested)
        }
        control.attach(task!)
    }

    private func finishProcessing(_ outcome: Result<(ReplicaProcessed, URL, NSImage?), Error>, inputs: ReplicaInputs,
                                  service: ImageTo3DService, store: StudioStore, stopped: Bool) {
        stopping = false
        switch outcome {
        case .success(let (processed, url, image)):
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            guard !stopped else { return failProcessing(MeshToolError.cancelled.localizedDescription) }
            guard store.importModel(url, intent: inputs.purpose.partIntent, sourceDetails: replicaSourceDetails(service: service)),
                  let id = store.selectedLocalID else {
                return failProcessing("The replica couldn’t be added to your library.")
            }
            savedModelIDs.append(id)
            self.processed = processed
            preview = image
            phase = .saved
            store.activities.insert(Activity(title: "Generate Replica",
                                             detail: replicaSavedActivityDetail(service: service, triangles: processed.mesh.triangleCount,
                                                                                 estimate: savedModelIDs.count == 1 ? estimate : nil),
                                             success: true), at: 0)
        case .failure(let error):
            failProcessing(stopped || (error as? MeshToolError) == .cancelled
                           ? MeshToolError.cancelled.localizedDescription : error.localizedDescription)
        }
    }

    private func failProcessing(_ message: String) {
        processingProblem = message
        // After a saved copy (Save Upright Copy stopped or failed), the first copy's summary still stands.
        phase = savedModelIDs.isEmpty ? .processingFailed : .saved
    }

    // MARK: Meshy's free check

    /// Meshy's Analyze Printability (free) of its own model at `longestSideMM`. Read-only for credits; sent once.
    func analyzeWithMeshy(longestSideMM: Double, store: StudioStore) {
        guard !analyzing, let client = provider as? MeshyClient, let generated, generated.service == .meshy,
              generated.sourceKind == .generation else { return }
        analyzing = true
        analysisProblem = nil
        ImageTo3DConnection.shared.beginWork()
        analysisTask = Task { @MainActor [weak self] in
            defer { ImageTo3DConnection.shared.endWork() }
            do {
                let report = try await client.analyzePrintability(ofTask: generated.sourceTaskID, longestSideMM: longestSideMM)
                self?.meshyReport = report
                store.activities.insert(Activity(title: "Analyze Printability", detail: replicaAnalysisActivityDetail(report), success: true), at: 0)
            } catch is CancellationError {
                self?.analysisProblem = "Stopped."
            } catch {
                self?.analysisProblem = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription)
                store.activities.insert(Activity(title: "Analyze Printability",
                                                 detail: "Meshy: \((error as? ImageTo3DError)?.activityDetail ?? "failed")", success: false), at: 0)
            }
            self?.analyzing = false
        }
    }
}

/// A three-quarter render of the replica for the summary, or nil when it can't be drawn.
func replicaPreviewImage(_ mesh: STLMesh, size: Int = 220, isCancelled: () -> Bool = { false }) -> NSImage? {
    guard let rgba = renderMeshRGBA(mesh, size: size, camera: .thumbnail, style: .thumbnail, rasterBudget: thumbnailRasterBudget,
                                    isCancelled: isCancelled),
          let prepared = prepareRenderedImage(rgba: rgba, width: size, height: size) else { return nil }
    return NSImage(data: prepared.data)
}

// MARK: - Sheet

struct ReplicaGeneratorSheet: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = ImageTo3DConnection.shared
    @StateObject private var session = ReplicaGeneratorSession()

    @State private var photo: ImageTo3DImage?
    @State private var photoPreview: NSImage?
    @State private var photoName: String?
    @State private var photoProblem: String?
    @State private var preparingPhoto = false
    @State private var photoJob: Task<Void, Never>?
    @State private var name = ""
    @State private var axis: ReplicaSizeAxis = .height
    @State private var sizeText = ""
    @State private var purpose: ReplicaPurpose = .display
    @State private var balanceLine: String?
    @State private var checkingBalance = false
    @State private var startProblem: String?
    @State private var consentRequest: ImageSharingConsentRequest?
    @State private var confirmGenerateAgain = false
    @State private var confirmClose = false
    @State private var dropTargeted = false

    private var service: ImageTo3DService { connection.selectedService }
    private var estimate: ImageTo3DCostEstimate { replicaCostEstimate(service: service, tripoRegion: connection.tripoRegion) }
    private var inputs: ReplicaInputs? { replicaInputs(name: name, axis: axis, sizeText: sizeText, purpose: purpose) }
    private var blockedReasons: [String] {
        replicaGenerateBlockedReasons(photoReady: photo != nil, photoPreparing: preparingPhoto, nameText: name, sizeText: sizeText,
                                      service: service, hasKey: connection.hasKey(service))
    }
    private var inputsLocked: Bool { session.isRunning || session.phase == .saved }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Generate a replica from an image").font(.title2.weight(.bold))
                Text("\(service.title) makes a 3D model from one photo. Studio then scales it to the size you give, repairs and simplifies it on this Mac, and saves it as a new model in your library. Nothing is uploaded to Slant.")
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
        .interactiveDismissDisabled(session.isRunning || session.hasUnsavedModel)
        .imageSharingConsent($consentRequest)
        .onDisappear {
            photoJob?.cancel()
            session.cancelAll()
        }
    }

    // MARK: Sections

    private var photoSection: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(dropTargeted ? Color.accentColor : Color.secondary.opacity(0.4),
                                      style: StrokeStyle(lineWidth: 1, dash: photoPreview == nil ? [4] : []))
                    if let photoPreview {
                        Image(nsImage: photoPreview).resizable().scaledToFit().padding(4)
                            .accessibilityLabel("Chosen photo")
                    } else if preparingPhoto {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Drop a photo here").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 140, height: 140)
                .dropDestination(for: URL.self) { urls, _ in
                    guard !inputsLocked, let url = urls.first(where: \.isFileURL) else { return false }
                    choosePhoto(url)
                    return true
                } isTargeted: { dropTargeted = $0 }
                VStack(alignment: .leading, spacing: 8) {
                    if let photoName { Text(photoName).font(.callout).lineLimit(1).truncationMode(.middle) }
                    Button(photo == nil ? "Choose Photo…" : "Choose Another Photo…") { pickPhoto() }
                        .disabled(inputsLocked || preparingPhoto)
                    Text(replicaPhotoAdvice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let photoProblem {
                        Label(photoProblem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } header: {
            Text("Photo")
        } footer: {
            Text("Studio resizes the photo and removes its location, camera and other hidden details before sending it. It isn’t saved.")
                .settingsFooterLayout()
        }
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
                    TextField("Size in millimetres", text: $sizeText, prompt: Text("120"))
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
        } header: {
            Text("Replica")
        } footer: {
            Text("Neither service knows how big the object really is, so Studio scales the model to this measurement. The purpose is passed to Review for Printing with Claude.")
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
            Text(estimate.summary).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Change in Settings…") { store.requestSettings(.account) }
                    .help("Choose Meshy or Tripo3D and add its API key in Settings › Account › 3D generation.")
                Button("Check Balance") { checkBalance() }
                    .disabled(!connection.hasKey(service) || checkingBalance || session.isRunning)
                    .help("Reads your \(service.title) credits. Nothing is spent.")
                if checkingBalance { ProgressView().controlSize(.small) }
            }
            if let balanceLine {
                Text(balanceLine).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Label(session.processingProblem ?? "The replica wasn’t saved.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    Text("The model the service made is still here. Change the details above if needed, then Process Again. Nothing is sent or charged.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .saved:
                if let processed = session.processed { resultView(processed) }
            }
        } header: {
            Text(session.phase == .saved ? "Saved to your library" : "Progress")
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
                Text(action == .tryConversionAgain
                     ? "\(action.title) sends the conversion once, which costs credits. The model itself isn’t made again."
                     : "\(action.title) carries on with the same task. Nothing new is made or charged.")
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
                if let id = session.savedModelIDs.last, let model = store.localModels.first(where: { $0.id == id }) {
                    Text("“\(model.name)”").font(.callout.weight(.semibold))
                }
                ForEach(Array(replicaSummaryLines(processed).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if replicaChecksFoundNoProblems(processed) {
                    Text("Studio’s checks found no problems.").font(.callout).foregroundStyle(.secondary)
                }
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
        }
        if processed.upAxis == .z {
            HStack(alignment: .firstTextBaseline) {
                Text("Lying on its back in the picture? Some services treat a different direction as up.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Save Upright Copy") {
                    if let inputs = session.lastInputs { session.process(inputs: inputs, upAxis: .y, store: store) }
                }
                .help("Saves another copy turned upright and scaled again. Nothing is sent; remove the first copy if you don’t need it.")
            }
        }
        if session.generated?.service == .meshy, session.generated?.sourceKind == .generation {
            meshyAnalysis(processed)
        }
    }

    @ViewBuilder
    private func meshyAnalysis(_ processed: ReplicaProcessed) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button("Analyze Printability with Meshy") {
                    session.analyzeWithMeshy(longestSideMM: Double(processed.extentMM.max()), store: store)
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
            if session.phase == .ready || session.phase == .stopped || session.phase == .processingFailed {
                if let startProblem {
                    Label(startProblem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        .font(.callout).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                } else if let reason = blockedReasons.first {
                    Text(reason).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                if !connection.hasKey(service) {
                    Button("Open Settings") { store.requestSettings(.account) }
                }
            }
            Spacer()
            if session.isRunning {
                Button("Stop") { session.stop() }.disabled(session.stopping)
            }
            Button(session.phase == .saved ? "Done" : "Close") { close() }
                .keyboardShortcut(.cancelAction)
                .disabled(session.isRunning)
            switch session.phase {
            case .ready:
                generateButton
            case .stopped:
                if let stop = session.lastStop, let action = replicaResumeAction(for: stop) {
                    Button(action.title) { if let inputs { session.resume(inputs: inputs, store: store) } }
                        .disabled(inputs == nil)
                }
                generateButton
            case .processingFailed:
                Button("Process Again") { if let inputs { session.process(inputs: inputs, upAxis: .z, store: store) } }
                    .disabled(inputs == nil)
                generateButton
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
            Button("Generate Again") { DispatchQueue.main.async { startWithConsent() } }
            Button("Don’t Generate", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(replicaGenerateAgainMessage(lastStop: session.lastStop, estimate: estimate))
        }
        .confirmationDialog("Close without saving the replica?", isPresented: $confirmClose, titleVisibility: .visible) {
            Button("Close Without Saving", role: .destructive) { store.showReplicaGenerator = false }
            Button("Keep Open", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("The model \(session.service?.title ?? "the service") made isn’t in your library, and Studio doesn’t keep it. Getting it back means generating, and paying for, it again.")
        }
    }

    /// Never the default button and no shortcut: it spends the seller's credits.
    private var generateButton: some View {
        Button(session.phase == .ready ? "Generate Replica" : "Generate Again…") { requestGenerate() }
            .buttonStyle(.borderedProminent)
            .disabled(!blockedReasons.isEmpty || session.isRunning)
            .help("Sends the photo to \(service.title) once. \(estimate.summary)")
    }

    // MARK: Actions

    private func pickPhoto() {
        let panel = NSOpenPanel()
        panel.message = "Choose one photo of the object, on a plain background."
        panel.allowedContentTypes = [.jpeg, .png, .heic]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        choosePhoto(url)
    }

    private func choosePhoto(_ url: URL) {
        guard !inputsLocked else { return }
        photoJob?.cancel()
        preparingPhoto = true
        photoProblem = nil
        startProblem = nil
        let job = Task { @MainActor in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<PreparedImage, Error> in
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                return Result { try prepareImageForSharing(at: url, maxLongEdge: imagePreparationMaxLongEdge) }
            }.value
            guard !Task.isCancelled else { return }
            preparingPhoto = false
            switch result {
            case .success(let prepared):
                let image = ImageTo3DImage(data: prepared.data, mediaType: prepared.mediaType.rawValue)
                if let problem = imageTo3DImageProblem(image) {
                    photoProblem = problem
                    return
                }
                photo = image
                photoPreview = NSImage(data: prepared.data)
                photoName = url.lastPathComponent
            case .failure(let error):
                photoProblem = error.localizedDescription
            }
        }
        photoJob = job
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

    private func requestGenerate() {
        startProblem = nil
        guard blockedReasons.isEmpty, !session.isRunning else { return }
        if replicaGenerateNeedsConfirmation(lastStop: session.lastStop, modelAlreadyMade: session.generated != nil) {
            confirmGenerateAgain = true
        } else {
            startWithConsent()
        }
    }

    private func startWithConsent() {
        let chosen = service
        runWithImageSharingConsent(chosen.sharingService, request: $consentRequest) { start(chosen) }
    }

    private func start(_ chosen: ImageTo3DService) {
        guard connection.selectedService == chosen, blockedReasons.isEmpty, !session.isRunning,
              let photo, let inputs else { return }
        let provider: ImageTo3DProvider
        do { provider = try connection.provider(for: chosen) } catch {
            startProblem = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription)
            return
        }
        session.start(provider: provider, image: photo, inputs: inputs, store: store)
    }

    private func close() {
        guard !session.isRunning else { return }
        if session.hasUnsavedModel { confirmClose = true } else { store.showReplicaGenerator = false }
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
                                                meshyReport: session.meshyReport)
        store.openPrintReviewAfterReplica(PrintReviewRequest(modelID: id, context: context))
    }
}
