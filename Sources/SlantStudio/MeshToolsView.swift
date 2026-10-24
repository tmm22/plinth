import SwiftUI

// The Repair and simplify card in Improve for printing. Both tools run off the main actor, can be stopped, and save
// their result as a new library copy through `importModel`; the model itself is never changed.

/// Read from the detached worker, which does not inherit the UI task's cancellation.
private final class MeshToolsCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

enum MeshToolKind: Equatable, Sendable {
    case repair
    case simplify(target: Int)

    var copySuffix: String {
        switch self {
        case .repair: return "repaired"
        case .simplify: return "simplified"
        }
    }
    var isRepair: Bool { self == .repair }
}

struct MeshToolsNote: Equatable {
    /// "Repaired copy" or "Simplified copy".
    let title: String
    let lines: [String]
}

/// Temporary folders for results on their way into the library: `<prefix><UUID>`, removed after the import and, if
/// Studio stopped first, at the next launch (`personalisationTempFolderPrefixes`).
let meshToolsTempFolderPrefix = "SlantStudio-MeshTools-"

/// Session-only notes about copies these tools made, keyed by the new model's ID. Never saved.
@MainActor enum MeshToolsNotes {
    static var byModel: [UUID: MeshToolsNote] = [:]
}

/// "Name (repaired)": slashes and colons become hyphens, an empty name becomes "Model", and long names are shortened
/// so the file name stays within 255 bytes.
func meshToolCopyName(_ name: String, kind: MeshToolKind) -> String {
    var base = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty || base.hasPrefix(".") { base = "Model" + (base.isEmpty ? "" : " " + base) }
    while base.utf8.count > 200 { base.removeLast() }
    return "\(base) (\(kind.copySuffix))"
}

/// The smallest target the field accepts; fewer triangles would lose almost any real shape.
let meshSimplifyMinimumTarget = 100

/// Reads the target field: digits with optional grouping (spaces, commas, full stops, apostrophes).
func meshSimplifyTarget(_ text: String) -> Int? {
    let digits = text.filter { !" ,.'’\u{00A0}\u{202F}".contains($0) }
    guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy(\.isASCII), digits.allSatisfy(\.isNumber) else { return nil }
    return Int(digits)
}

/// Why Simplify can't run with this target, or nil when it can.
func meshSimplifyTargetProblem(_ text: String, currentTriangles: Int) -> String? {
    guard let target = meshSimplifyTarget(text) else { return "Enter a whole number of triangles." }
    if currentTriangles <= meshSimplifyMinimumTarget { return "This model is already very simple." }
    if target < meshSimplifyMinimumTarget { return "Enter at least \(meshSimplifyMinimumTarget) triangles." }
    if target >= currentTriangles { return "Enter fewer than this model’s \(currentTriangles.formatted()) triangles." }
    return nil
}

/// Triangle count and the mesh check in one line, for the card.
func meshToolsStatusLine(triangles: Int, report: MeshHealthReport) -> String {
    let check = meshHealthIsSound(report) ? "closed and consistent" : meshHealthSummary(report).title.lowercased()
    return "\(triangles.formatted()) \(triangles == 1 ? "triangle" : "triangles") · \(check)"
}

/// The card's one-line explanation of why simplifying matters.
let meshSimplifyExplanation = "Reinforce and Auto-improve accept up to \(meshToolsReinforceTriangleLimit.formatted()) triangles, so simplify a detailed copy first."

@MainActor final class MeshToolsRun: ObservableObject {
    @Published var working = false
    @Published var fraction = 0.0
    @Published var status = ""
    /// Shown when a run finished without anything to save.
    @Published var unchanged: [String]?
    private var task: Task<Void, Never>?
    private var flag: MeshToolsCancelFlag?

    func start(_ work: @escaping @Sendable (_ progress: @escaping MeshToolSendableProgress, _ cancelled: @escaping @Sendable () -> Bool) async -> Void) {
        stop()
        let flag = MeshToolsCancelFlag()
        self.flag = flag
        working = true; fraction = 0; status = "Starting…"; unchanged = nil
        task = Task { [weak self] in
            await work({ [weak self] value, text in
                Task { @MainActor in if !flag.isSet { self?.fraction = value; self?.status = text } }
            }, { flag.isSet })
            if !flag.isSet { self?.working = false }
        }
    }

    func stop() { flag?.set(); flag = nil; task?.cancel(); task = nil; working = false }
}

typealias MeshToolSendableProgress = @Sendable (_ fraction: Double, _ stage: String) -> Void

struct MeshToolsCard: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    @StateObject private var run = MeshToolsRun()
    @State private var expanded = false
    @State private var mesh: STLMesh?
    @State private var report: MeshHealthReport?
    @State private var failure: String?
    @State private var targetText = meshToolsReinforceTriangleLimit.formatted()
    /// Which tool the current run is, for the button titles.
    @State private var runningRepair = true

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 12) {
                    if !model.supportsPreview {
                        Text(stlOnlyToolNote(model) ?? stlCopyToolNote)
                    } else if let failure {
                        Text(failure).font(.callout).foregroundStyle(.secondary)
                    } else if let mesh, let report {
                        tools(mesh: mesh, report: report)
                    } else {
                        ProgressView("Checking mesh…")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            } label: {
                SectionHeading(title: "Repair and simplify", caption: caption)
            }.studioDisclosureStyle()
        }
        .task(id: expanded) {
            guard expanded, model.supportsPreview, mesh == nil, failure == nil else { return }
            let url = model.url
            let worker = Task.detached(priority: .userInitiated) { () -> Result<(STLMesh, MeshHealthReport)?, Error> in
                Result {
                    let value = try STLMesh.read(from: url)
                    guard let report = analyzeMeshHealth(value, isCancelled: { Task.isCancelled }) else { return nil }
                    return (value, report)
                }
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let loaded?): mesh = loaded.0; report = loaded.1
            case .success(nil): break
            case .failure(let error): failure = error.localizedDescription
            }
        }
        .onDisappear { run.stop() }
    }

    private var caption: String {
        if run.working { return run.status }
        if let note = MeshToolsNotes.byModel[model.id] { return "\(note.title) · Original preserved" }
        return "Close gaps, fix flipped faces or reduce detail"
    }

    @ViewBuilder private func tools(mesh: STLMesh, report: MeshHealthReport) -> some View {
        if let note = MeshToolsNotes.byModel[model.id] {
            VStack(alignment: .leading, spacing: 4) {
                Text(note.title).font(.callout.weight(.semibold))
                ForEach(Array(note.lines.enumerated()), id: \.offset) { Text($0.element) }
            }
            .font(.callout).foregroundStyle(.secondary)
        }
        Label(meshToolsStatusLine(triangles: mesh.triangleCount, report: report),
              systemImage: meshHealthIsSound(report) ? "checkmark.circle" : "info.circle")
            .font(.callout)

        Text("Repair joins nearby vertices, removes zero-area, repeated and loose triangles, turns faces the right way and closes small holes.")
            .font(.callout).foregroundStyle(.secondary)
        Button(run.working && runningRepair ? "Repairing…" : "Repair & Save Copy") { start(.repair, mesh: mesh) }
            .disabled(run.working || store.busy)

        Divider()
        Text(meshSimplifyExplanation).font(.callout).foregroundStyle(.secondary)
        if !meshHealthIsSound(report) {
            Text("Repair a copy first for the best result.").font(.caption).foregroundStyle(.secondary)
        }
        let problem = meshSimplifyTargetProblem(targetText, currentTriangles: mesh.triangleCount)
        HStack(spacing: 8) {
            TextField("Target triangles", text: $targetText)
                .labelsHidden()
                .accessibilityLabel("Target triangle count")
                .frame(width: 90)
                .multilineTextAlignment(.trailing)
            Text("triangles").foregroundStyle(.secondary)
            Button(run.working && !runningRepair ? "Simplifying…" : "Simplify & Save Copy") {
                if let target = meshSimplifyTarget(targetText) { start(.simplify(target: target), mesh: mesh) }
            }
            .disabled(run.working || store.busy || problem != nil)
        }
        if let problem { Text(problem).font(.caption).foregroundStyle(.secondary) }

        if run.working {
            HStack(spacing: 8) {
                ProgressView(value: run.fraction).frame(maxWidth: 160)
                Text(run.status).font(.caption).foregroundStyle(.secondary)
                Button("Stop") { run.stop() }
            }
        }
        if let lines = run.unchanged {
            VStack(alignment: .leading, spacing: 4) {
                Text("Nothing to change, so no copy was saved.").font(.callout)
                ForEach(Array(lines.enumerated()), id: \.offset) { Text($0.element).font(.callout).foregroundStyle(.secondary) }
            }
        }

        Divider()
        // Review for Printing with Claude (PrintReviewView.swift): only opens the sheet; nothing is sent from here.
        Text("Claude can look at pictures and Studio’s measurements of this model and suggest steps from these tools. Nothing is sent until you ask, and nothing runs until you tick it.")
            .font(.callout).foregroundStyle(.secondary)
        Button("Review for Printing with Claude…") { store.beginPrintReview(model: model) }
            .disabled(run.working)
    }

    private func start(_ kind: MeshToolKind, mesh: STLMesh) {
        let model = model, name = model.name
        runningRepair = kind.isRepair
        run.start { progress, cancelled in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(lines: [String], url: URL?), Error> in
                Result {
                    let lines: [String]
                    let output: STLMesh?
                    switch kind {
                    case .repair:
                        let result = try repairMesh(mesh, progress: progress, isCancelled: cancelled)
                        lines = meshRepairSummaryLines(result.summary)
                        output = result.summary.changed ? result.mesh : nil
                    case .simplify(let target):
                        var options = MeshSimplifyOptions()
                        options.targetTriangles = target
                        let result = try simplifyMesh(mesh, options: options, progress: progress, isCancelled: cancelled)
                        lines = meshSimplifySummaryLines(result)
                        output = result.changed ? result.mesh : nil
                    }
                    guard let output else { return (lines, nil) }
                    if cancelled() { throw MeshToolError.cancelled }
                    let folder = FileManager.default.temporaryDirectory
                        .appendingPathComponent("\(meshToolsTempFolderPrefix)\(UUID().uuidString)")
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let url = folder.appendingPathComponent("\(meshToolCopyName(name, kind: kind)).stl")
                    do { try output.binarySTL().write(to: url, options: .atomic) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return (lines, url)
                }
            }.value
            await MainActor.run {
                if case .success(let value) = outcome, let url = value.url {
                    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
                    guard !cancelled() else { return }
                    // The copy keeps the original's records: its placement and edits are unchanged.
                    if store.importModel(url, recipe: model.printRecipe, improvement: model.designImprovement,
                                         intent: model.partIntent, reinforcement: model.reinforcement,
                                         autoImprovement: model.autoImprovement, sourceDetails: model.sourceDetails),
                       let id = store.selectedLocalID {
                        MeshToolsNotes.byModel[id] = MeshToolsNote(title: kind.isRepair ? "Repaired copy" : "Simplified copy",
                                                                   lines: value.lines)
                    }
                    return
                }
                guard !cancelled() else { return }
                switch outcome {
                case .success(let value): run.unchanged = value.lines
                case .failure(let error): store.showError(error.localizedDescription)
                }
            }
        }
    }
}
