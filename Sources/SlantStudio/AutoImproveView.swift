import SwiftUI

/// Read from the detached worker, which does not inherit the UI task's cancellation.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@MainActor final class AutoImproveRun: ObservableObject {
    @Published var working = false
    @Published var status = ""
    /// Shown when a run finished without anything to save.
    @Published var unchanged: AutoImprovementResult?
    private var task: Task<Void, Never>?
    private var flag: CancelFlag?

    func start(_ work: @escaping @Sendable (_ progress: @escaping @Sendable (String) -> Void, _ cancelled: @escaping @Sendable () -> Bool) async -> Void) {
        stop()
        let flag = CancelFlag()
        self.flag = flag
        working = true; status = "Starting…"; unchanged = nil
        task = Task {
            await work({ [weak self] text in Task { @MainActor in if !flag.isSet { self?.status = text } } }, { flag.isSet })
            if !flag.isSet { working = false }
        }
    }

    func stop() { flag?.set(); flag = nil; task?.cancel(); task = nil; working = false }
}

/// Auto-improve's caption, which stays visible while the card is collapsed. It needs the part's purpose to be complete
/// in Optimise for purpose first (a stress direction, and a description for a custom part), so it says so.
func autoImproveSummary(intent: PartIntent, hasRecipe: Bool, improved: Bool) -> String {
    if improved { return "Auto-improved copy · Original preserved" }
    if hasRecipe || intent.isReady { return "One click · Places the part and adds the treatments its shape needs" }
    let needsDirection = intent.purpose.needsDirection && intent.load == .unknown
    let needsDetails = intent.purpose == .custom && intent.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    if needsDirection && needsDetails { return "First describe the part and choose its main stress direction in Optimise for purpose." }
    if needsDetails { return "First describe the part in Optimise for purpose." }
    return "First choose the main stress direction in Optimise for purpose."
}

struct AutoImproveCard: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    @StateObject private var run = AutoImproveRun()
    @State private var expanded = false

    private var intent: PartIntent { designEditIntent(model) ?? PartIntent() }
    private var ready: Bool { intent.isReady || model.printRecipe != nil }

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if let record = model.autoImprovement {
                        summary(record)
                    } else if !model.supportsPreview {
                        // OBJ and 3MF get one notice in place of the tools instead.
                        if let note = stlOnlyToolNote(model) {
                            Text(note).font(.callout).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Places the part for its purpose, then adds what its shape needs: bridging for counterbores, chamfers under ledges, walls matched to the line width and fillets in inside corners. Each change is checked and skipped if it fails. Ribs, gussets, collars, teardrop holes and splits are never automatic; add them in Reinforce this part.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(purposeLine).font(.caption).foregroundStyle(.secondary)
                        if ready {
                            HStack {
                                Button(run.working ? "Improving…" : "Auto-Improve & Save Copy") { improve() }
                                    .buttonStyle(.borderedProminent)
                                    .disabled(run.working || store.busy)
                                if run.working {
                                    ProgressView().controlSize(.small)
                                    Text(run.status).font(.caption).foregroundStyle(.secondary)
                                    Button("Stop") { run.stop() }
                                }
                            }
                        } else {
                            Text(autoImproveSummary(intent: intent, hasRecipe: model.printRecipe != nil, improved: false))
                                .font(.callout)
                        }
                        if let result = run.unchanged {
                            Text("No automatic changes suit this part, so nothing was saved.").font(.callout)
                            notes(skipped: result.skipped, manual: result.manual)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            } label: {
                SectionHeading(title: "Auto-improve", caption: run.working
                               ? run.status
                               : autoImproveSummary(intent: intent, hasRecipe: model.printRecipe != nil, improved: model.autoImprovement != nil))
            }
        }
        .onDisappear { run.stop() }
    }

    private var purposeLine: String {
        var line = "Purpose: \(intent.purpose.rawValue)"
        if intent.effectiveLoad != .unknown { line += " · Main stress along \(intent.effectiveLoad.rawValue.lowercased())" }
        if model.printRecipe != nil || model.requiresZUp { line += " · Keeps its current placement" }
        return line + ". Change this in Optimise for purpose."
    }

    private func summary(_ record: AutoImprovementRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if record.applied.isEmpty {
                Text("Placed for printing; no treatments applied.").font(.callout)
            } else {
                ForEach(Array(record.applied.enumerated()), id: \.offset) { _, step in
                    Label(step.summary, systemImage: "checkmark.circle").font(.callout)
                }
                let added = record.applied.reduce(0) { $0 + $1.addedVolumeMM3 }, removed = record.applied.reduce(0) { $0 + $1.removedVolumeMM3 }
                Text(String(format: "Geometry: +%.1f mm³ added · %.1f mm³ removed · Overall envelope preserved. Request a new Slant quote for this copy.", added, removed))
                    .font(.caption).foregroundStyle(.secondary)
            }
            notes(skipped: record.skipped, manual: record.manual)
            Text("Review the copy before ordering. Fillets and matched walls take a little space from inside corners and cavities; check that mating parts still fit.")
                .font(.caption).foregroundStyle(.secondary)
            if let original = store.localModels.first(where: { $0.id == record.sourceID }) {
                Button("Return to Original") { store.select(original) }.disabled(store.busy)
            }
        }
    }

    @ViewBuilder private func notes(skipped: [String], manual: [String]) -> some View {
        if !manual.isEmpty {
            DisclosureGroup("For your review (\(manual.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(manual, id: \.self) { Text($0) }
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
        if !skipped.isEmpty {
            DisclosureGroup("Skipped after checks (\(skipped.count))") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(skipped.enumerated()), id: \.offset) { Text($0.element) }
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 6)
            }
        }
    }

    private func improve() {
        let model = model, intent = intent
        let materialID = store.filamentID.isEmpty ? nil : store.filamentID
        let locked = model.printRecipe != nil || model.requiresZUp
        run.start { progress, cancelled in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(AutoImprovementResult, URL?), Error> in
                Result {
                    let source = try STLMesh.read(from: model.url)
                    progress("Choosing the print placement…")
                    guard let orientation = AutoImprover.orientation(for: source, intent: intent, locked: locked) else {
                        throw StudioError("No flat-bed placement fits among the positions checked. Prepare a custom orientation in your CAD tool or slicer, then import it here.")
                    }
                    let result = try AutoImprover.improve(source, intent: intent, orientation: orientation, progress: progress, cancelled: cancelled)
                    guard result.changed else { return (result, nil) }
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("\(URL(fileURLWithPath: model.name).lastPathComponent)-auto-improved.stl")
                    do { try result.mesh.binarySTL().write(to: url, options: .atomic) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return (result, url)
                }
            }.value
            await MainActor.run {
                guard !cancelled() else { return }
                switch outcome {
                case .success((let result, let url)):
                    guard let url else { run.unchanged = result; return }
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    let record = AutoImprovementRecord(sourceID: model.id, orientation: result.orientation, applied: result.applied,
                                                       skipped: result.skipped, manual: result.manual, created: Date())
                    let recipe = model.printRecipe ?? PreparedPrintRecipe(sourceID: model.id, sourceName: model.name, intent: intent,
                                                                           orientation: result.orientation, materialID: materialID, created: Date())
                    store.importModel(url, recipe: recipe, improvement: model.designImprovement, intent: intent,
                                      reinforcement: model.reinforcement, autoImprovement: record)
                case .failure(let error):
                    store.showError(error.localizedDescription)
                }
            }
        }
    }
}
