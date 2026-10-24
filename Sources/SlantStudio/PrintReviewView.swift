import SwiftUI
import AppKit

// Review for Printing with Claude: the sheet for `StudioStore.printReviewRequest` (PrintReview.swift has the pure
// parts). Studio measures and renders the model on this Mac when the sheet opens; nothing is sent until Ask Claude,
// and nothing is changed until Run Selected Steps. The pictures, measurements, Claude's reply and the plan live only in
// this sheet's memory; closing it stops any work. Activity gets counts, cost and status only.

extension StudioStore {
    /// Opens the review for a library STL, unless another sheet or modal UI is showing. Only opens the sheet.
    func beginPrintReview(model: LocalModel, context: PrintReviewContext = PrintReviewContext()) {
        guard !isPresentingSheet, !appIsPresentingModalUI(), model.supportsPreview else { return }
        printReviewRequest = PrintReviewRequest(modelID: model.id, context: context)
    }
}

/// Read from detached work, which does not inherit the UI task's cancellation.
private final class PrintReviewCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// The sheet's state, in memory only.
@MainActor final class PrintReviewSession: ObservableObject {
    enum Measuring: Equatable {
        case working(Double, String)
        case done
        case failed(String)
    }

    enum ClaudeState: Equatable {
        case idle
        case asking(String)
        case plan(PrintReviewPlan)
        case failed(String)
        case stopped
    }

    enum RunState: Equatable {
        case idle
        case running(Double, String)
        case saved(name: String, lines: [String], comparison: [String])
        case unchanged([String])
        case failed(String)
    }

    @Published var measuring = Measuring.working(0, "Reading the model…")
    @Published private(set) var before: PrintReviewMeasurements?
    @Published private(set) var renders: [PrintReviewRender] = []
    @Published private(set) var renderImages: [(title: String, image: NSImage)] = []
    @Published var claude = ClaudeState.idle
    @Published private(set) var cost: AnthropicCostEstimate?
    @Published var ticked: Set<Int> = []
    @Published var run = RunState.idle

    private var mesh: STLMesh?
    private var measureTask: Task<Void, Never>?
    private var measureFlag: PrintReviewCancelFlag?
    private var claudeTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var runFlag: PrintReviewCancelFlag?

    var isAsking: Bool { if case .asking = claude { return true }; return false }
    var isRunning: Bool { if case .running = run { return true }; return false }
    var plan: PrintReviewPlan? { if case .plan(let plan) = claude { return plan }; return nil }

    func cancelAll() {
        measureFlag?.set(); measureTask?.cancel()
        claudeTask?.cancel()
        runFlag?.set(); runTask?.cancel()
    }

    // MARK: Measuring (no request)

    func measure(url: URL) {
        guard measureTask == nil else { return }
        let flag = PrintReviewCancelFlag()
        measureFlag = flag
        let report: @Sendable (Double, String) -> Void = { [weak self] fraction, stage in
            Task { @MainActor in if !flag.isSet { self?.measuring = .working(fraction, stage) } }
        }
        measureTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) { () -> Result<(STLMesh, PrintReviewMeasurements, [PrintReviewRender])?, Error> in
                Result {
                    let mesh = try STLMesh.read(from: url)
                    guard let measured = measureForPrintReview(mesh, progress: { report($0 * 0.85, $1) }, isCancelled: { flag.isSet }) else {
                        return nil
                    }
                    report(0.9, "Drawing the views…")
                    guard let renders = renderPrintReviewViews(mesh, isCancelled: { flag.isSet }) else { return nil }
                    return (mesh, measured, renders)
                }
            }
            let result = await job.value
            guard let self, !flag.isSet else { return }
            switch result {
            case .success(let value?):
                self.mesh = value.0
                self.before = value.1
                self.renders = value.2
                self.renderImages = value.2.compactMap { render in NSImage(data: render.image.data).map { (render.title, $0) } }
                self.measuring = .done
            case .success(nil):
                self.measuring = .failed("Stopped.")
            case .failure(let error):
                self.measuring = .failed("Studio couldn’t read this model: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Asking Claude (one request, at most one follow-up)

    /// The request Ask Claude would send now, for its cost estimate.
    func pendingRequest(context: PrintReviewContext) -> AnthropicRequest? {
        guard let before else { return nil }
        return printReviewAnthropicRequest(views: renders, factLines: printReviewFactLines(before),
                                           contextLines: printReviewContextLines(context))
    }

    /// Ask Claude's estimated cost, worked out once: the request only changes when the measurements do.
    private var estimate: String?
    func estimatedCostText(context: PrintReviewContext) -> String? {
        if let estimate { return estimate }
        guard let pending = pendingRequest(context: context) else { return nil }
        let tokens = printReviewEstimatedInputTokens(pending, imageSizes: renders.map { ($0.image.pixelWidth, $0.image.pixelHeight) })
        estimate = printReviewCostRangeText(inputTokens: tokens)
        return estimate
    }

    func ask(context: PrintReviewContext, planContext: PrintReviewPlanContext, store: StudioStore) {
        guard !isAsking, !isRunning, let request = pendingRequest(context: context) else { return }
        claude = .asking("Sending the pictures and measurements to Claude…")
        cost = nil
        ticked = []
        run = .idle
        claudeTask = Task { [weak self] in
            var current = request
            var replies: [AnthropicMessage] = []
            var followedUp = false
            @MainActor func finish(_ state: ClaudeState, steps: Int?, status: String?, success: Bool) {
                store.activities.insert(Activity(title: "Review for printing with Claude",
                                                 detail: printReviewActivityDetail(steps: steps, cost: printReviewCostSoFar(replies), status: status),
                                                 success: success), at: 0)
                self?.claude = state
            }
            do {
                while true {
                    let reply = try await AnthropicConnection.shared.send(current) { [weak self] progress in
                        self?.note(progress)
                    }
                    replies.append(reply)
                    self?.cost = printReviewCostSoFar(replies)
                    try Task.checkCancellation()
                    switch printReviewReplyOutcome(reply, context: planContext) {
                    case .plan(let plan):
                        finish(.plan(plan), steps: plan.steps.count, status: nil, success: true)
                        return
                    case .refused(let message):
                        finish(.failed(message), steps: nil, status: "Claude declined", success: false)
                        return
                    case .failed(let message):
                        finish(.failed(message), steps: nil, status: "No plan", success: false)
                        return
                    case .needsFollowUp:
                        if !followedUp, let next = printReviewFollowUpRequest(current, reply: reply) {
                            followedUp = true
                            current = next
                            self?.claude = .asking("Claude didn’t give a plan, so Studio is asking once more…")
                            continue
                        }
                        finish(.failed("Claude didn’t answer with a plan, so Studio stopped. Nothing was changed."),
                               steps: nil, status: "No plan", success: false)
                        return
                    }
                }
            } catch is CancellationError {
                finish(.stopped, steps: nil, status: "Stopped", success: false)
            } catch {
                finish(.failed(error.localizedDescription), steps: nil, status: "Didn’t finish", success: false)
            }
        }
    }

    func stopAsking() { claudeTask?.cancel() }

    private func note(_ progress: AnthropicStreamProgress) {
        guard isAsking else { return }
        switch progress {
        case .started: claude = .asking("Claude is looking at the model…")
        case .toolInput: claude = .asking("Claude is writing the plan…")
        case .textDelta: claude = .asking("Claude is writing…")
        case .fallback: claude = .asking("Anthropic passed this request to another Claude model…")
        default: break
        }
    }

    // MARK: Running the ticked steps (on this Mac)

    func runTicked(model: LocalModel, store: StudioStore) {
        guard !isRunning, !isAsking, let mesh, let before, let plan else { return }
        let steps = plan.steps.filter { ticked.contains($0.id) && $0.isRunnable }
            .compactMap { step in step.action.map { PrintReviewRunStep(number: step.id, action: $0) } }
        guard !steps.isEmpty else { return }
        let flag = PrintReviewCancelFlag()
        runFlag = flag
        run = .running(0, "Starting…")
        let report: @Sendable (Double, String) -> Void = { [weak self] fraction, stage in
            Task { @MainActor in if !flag.isSet { self?.run = .running(fraction, stage) } }
        }
        runTask = Task { [weak self] in
            let job = Task.detached(priority: .userInitiated) { () -> Result<(PrintReviewRunResult, PrintReviewMeasurements?), Error> in
                Result {
                    let result = try runPrintReviewSteps(steps, on: mesh, progress: { report($0 * 0.8, $1) }, isCancelled: { flag.isSet })
                    guard result.changed else { return (result, nil) }
                    report(0.85, "Measuring the result…")
                    guard let after = measureForPrintReview(result.mesh, isCancelled: { flag.isSet }) else {
                        throw PrintReviewRunError.cancelled
                    }
                    return (result, after)
                }
            }
            let outcome = await job.value
            // Closing the sheet or Stop: nothing is saved.
            guard let self, !flag.isSet else { return }
            switch outcome {
            case .success(let value):
                guard value.0.changed, let after = value.1 else {
                    self.run = .unchanged(value.0.lines)
                    return
                }
                let name = printReadyCopyName(model.name)
                if Self.save(value.0.data, name: name, model: model, actions: steps.map(\.action), store: store) {
                    self.run = .saved(name: name, lines: value.0.lines,
                                      comparison: printReviewComparisonLines(before: before, after: after))
                    store.activities.insert(Activity(title: "Print-ready copy",
                                                     detail: steps.count == 1 ? "1 step run" : "\(steps.count) steps run",
                                                     success: true), at: 0)
                } else {
                    self.run = .failed("The copy wasn’t saved.")
                }
            case .failure(let error):
                self.run = .failed(error.localizedDescription)
            }
        }
    }

    func stopRun() {
        runFlag?.set()
        runTask?.cancel()
        run = .failed(PrintReviewRunError.cancelled.localizedDescription)
    }

    /// One library copy through `importModel`, from a temporary folder removed straight after.
    private static func save(_ data: Data, name: String, model: LocalModel, actions: [PrintReviewAction], store: StudioStore) -> Bool {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(meshToolsTempFolderPrefix)\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(exportFileName(modelName: name, fileExtension: "stl"))
            try data.write(to: url, options: .atomic)
            let details = sourceDetailsForCopy(of: model)
            if printReadyCopyKeepsRecords(actions) {
                return store.importModel(url, recipe: model.printRecipe, improvement: model.designImprovement, intent: model.partIntent,
                                         reinforcement: model.reinforcement, autoImprovement: model.autoImprovement, sourceDetails: details)
            }
            return store.importModel(url, intent: model.partIntent, sourceDetails: details)
        } catch {
            store.showError("The copy wasn’t saved: \(error.localizedDescription)")
            return false
        }
    }
}

// MARK: - Sheet

struct PrintReviewSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var claudeConnection = AnthropicConnection.shared
    @StateObject private var session = PrintReviewSession()
    @State private var consentRequest: ImageSharingConsentRequest?
    /// The model as it was when the sheet opened, so a rename or removal can't change what is reviewed.
    @State private var model: LocalModel?
    let request: PrintReviewRequest

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Review for Printing with Claude").font(.title2.weight(.bold))
                Text(model?.name ?? "This model is no longer in your library.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("Studio measures the model on this Mac first. Nothing is sent until you press Ask Claude, and nothing changes until you run the steps you tick.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if let model {
                        if model.supportsPreview {
                            measurementsSection
                            if case .done = session.measuring {
                                Divider()
                                askSection(model: model)
                                if let plan = session.plan, let before = session.before {
                                    Divider()
                                    planSection(plan, before: before, model: model)
                                }
                            }
                        } else {
                            Text("Review for Printing works on STL models. Use Save STL Copy in the inspector, then review the copy.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Text("Claude’s plan is advice. Studio’s own measurements are shown beside it.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Close") {
                    session.cancelAll()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 560, idealHeight: 760)
        .imageSharingConsent($consentRequest)
        .onAppear {
            guard model == nil, let found = store.localModels.first(where: { $0.id == request.modelID }) else { return }
            model = found
            if found.supportsPreview { session.measure(url: found.url) }
        }
        .onDisappear { session.cancelAll() }
    }

    // MARK: Measurements

    @ViewBuilder private var measurementsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Studio’s measurements").font(.headline)
            switch session.measuring {
            case .working(let fraction, let stage):
                HStack(spacing: 10) {
                    ProgressView(value: fraction).frame(maxWidth: 200)
                    Text(stage).font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .done:
                if let before = session.before {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(printReviewFactLines(before).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
                let contextLines = printReviewContextLines(request.context)
                if !contextLines.isEmpty {
                    Text("What Studio knows about it").font(.subheadline.weight(.semibold)).padding(.top, 4)
                    ForEach(Array(contextLines.enumerated()), id: \.offset) { _, line in
                        Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if session.renderImages.isEmpty {
                    Text("Studio couldn’t draw this model, so Claude would get the measurements only.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(session.renderImages.enumerated()), id: \.offset) { _, item in
                            VStack(spacing: 4) {
                                Image(nsImage: item.image).resizable().interpolation(.high).aspectRatio(1, contentMode: .fit)
                                    .frame(width: 130, height: 130)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                    .accessibilityLabel("\(item.title) view")
                                Text(item.title).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                Text("Advisory: measured on this Mac. Not a strength rating.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Ask Claude

    private func planContext(model: LocalModel) -> PrintReviewPlanContext {
        PrintReviewPlanContext(triangles: session.before?.triangles ?? 0, sizeMM: session.before?.sizeMM ?? .zero,
                               scaleBlockedReason: meshFitEditBlockedReason(model, tool: .scale),
                               baseBlockedReason: meshFitEditBlockedReason(model, tool: .flatBase))
    }

    @ViewBuilder private func askSection(model: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ask Claude").font(.headline)
            if !claudeConnection.isConfigured {
                Text("Add your Anthropic API key in Settings › Design Tools › Claude (Anthropic) to ask Claude.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                Button("Open Settings") { store.requestSettings(.designTools) }
            } else {
                Text(printReviewSendSummary(pictures: session.renders.count, hasContext: !printReviewContextLines(request.context).isEmpty))
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let estimate = session.estimatedCostText(context: request.context) {
                    Text("Estimated cost: \(estimate), billed to your Anthropic account. If Claude doesn’t answer with a plan, Studio asks once more.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Button(session.plan == nil ? "Ask Claude" : "Ask Claude Again") {
                        let context = request.context, planContext = planContext(model: model)
                        runWithImageSharingConsent(.anthropic, request: $consentRequest) {
                            session.ask(context: context, planContext: planContext, store: store)
                        }
                    }
                    .disabled(session.isAsking || session.isRunning || session.before == nil)
                    if session.isAsking {
                        ProgressView().controlSize(.small)
                        if case .asking(let status) = session.claude {
                            Text(status).font(.callout).foregroundStyle(.secondary)
                        }
                        Button("Stop") { session.stopAsking() }
                    }
                }
            }
            if let cost = session.cost {
                Text("Cost so far: \(anthropicCostText(cost)) (estimated from Anthropic’s token counts).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            switch session.claude {
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            case .stopped:
                Text("Stopped. Anthropic may still bill for what Claude had already written.")
                    .font(.callout).foregroundStyle(.secondary)
            default:
                EmptyView()
            }
        }
    }

    // MARK: Plan

    private func severityColour(_ severity: PrintReviewSeverity) -> Color {
        switch severity {
        case .high: return .red
        case .medium: return .orange
        case .low: return .secondary
        }
    }

    @ViewBuilder private func planSection(_ plan: PrintReviewPlan, before: PrintReviewMeasurements, model: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Claude’s review").font(.headline)
            Text("Advice from Claude, not a strength rating or an approval.")
                .font(.caption).foregroundStyle(.secondary)
            if !plan.assessment.isEmpty { Text(plan.assessment).fixedSize(horizontal: false, vertical: true) }
            if !plan.risks.isEmpty {
                Text("Likely weak points").font(.subheadline.weight(.semibold))
                ForEach(Array(plan.risks.enumerated()), id: \.offset) { _, risk in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(risk.severity.title).font(.caption.weight(.semibold)).foregroundStyle(severityColour(risk.severity))
                            .frame(width: 54, alignment: .leading)
                        Text(risk.part.isEmpty ? risk.issue : "\(risk.part): \(risk.issue)")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if !plan.orientation.isEmpty {
                Text("Orientation: \(plan.orientation)").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            if !plan.materialNote.isEmpty {
                Text("Material: \(plan.materialNote)").font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(plan.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Text("Steps").font(.subheadline.weight(.semibold)).padding(.top, 6)
            if plan.steps.isEmpty {
                Text("Claude didn’t suggest any steps.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text("Nothing is ticked. Tick the steps you want: Studio runs them in this order on a copy and keeps your original.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ForEach(plan.steps) { step in stepRow(step, before: before) }
                let selected = plan.steps.filter { session.ticked.contains($0.id) && $0.isRunnable }.compactMap(\.action)
                ForEach(Array(printReviewSelectionNotes(selected, measurements: before).enumerated()), id: \.offset) { _, note in
                    Label(note, systemImage: "info.circle").font(.callout).fixedSize(horizontal: false, vertical: true)
                }
                if plan.steps.contains(where: \.isRunnable) {
                    runControls(selectedCount: selected.count, model: model)
                }
            }
        }
    }

    private func tickBinding(_ id: Int) -> Binding<Bool> {
        Binding(get: { session.ticked.contains(id) },
                set: { on in if on { session.ticked.insert(id) } else { session.ticked.remove(id) } })
    }

    @ViewBuilder private func stepRow(_ step: PrintReviewStep, before: PrintReviewMeasurements) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if step.isRunnable {
                Toggle(isOn: tickBinding(step.id)) {
                    Text("\(step.id). \(step.title)").font(.callout.weight(.semibold))
                }
                .toggleStyle(.checkbox)
                .disabled(session.isRunning)
            } else {
                Label("\(step.id). \(step.title)", systemImage: step.isManual ? "hand.point.right" : "xmark.circle")
                    .font(.callout.weight(.semibold))
            }
            Group {
                if case .manual(let text)? = step.action { Text(text).foregroundStyle(.primary) }
                if !step.reason.isEmpty { Text("Claude: \(step.reason)").foregroundStyle(.secondary) }
                if let action = step.action {
                    Text(printReviewStudioNote(action, measurements: before, context: request.context)).foregroundStyle(.secondary)
                }
                if let problem = step.problem {
                    Label("Studio won’t run this: \(problem)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, 22)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder private func runControls(selectedCount: Int, model: LocalModel) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Button("Run Selected Steps") { session.runTicked(model: model, store: store) }
                    .disabled(selectedCount == 0 || session.isRunning || session.isAsking || store.busy)
                if case .running(let fraction, let stage) = session.run {
                    ProgressView(value: fraction).frame(maxWidth: 160)
                    Text(stage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button("Stop") { session.stopRun() }
                } else {
                    Text("Saves one copy, “\(printReadyCopyName(model.name))”.").font(.caption).foregroundStyle(.secondary)
                }
            }
            switch session.run {
            case .saved(let name, let lines, let comparison):
                Label("Saved “\(name)” to your library. Your original is unchanged.", systemImage: "checkmark.circle")
                    .font(.callout)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Text("Before → after").font(.subheadline.weight(.semibold)).padding(.top, 4)
                ForEach(Array(comparison.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            case .unchanged(let lines):
                Text("Nothing changed, so no copy was saved.").font(.callout)
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            default:
                EmptyView()
            }
        }
        .padding(.top, 4)
    }
}
