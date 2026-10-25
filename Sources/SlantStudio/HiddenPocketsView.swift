import SwiftUI

// Hidden pockets in the inspector (HiddenPockets.swift does the geometry): the per-model line in the model checks, the
// same line on a print-ready copy's panel, and Fill Hidden Pockets, the seller's own request for a separate copy with
// the pockets filled solid. Nothing is filled automatically, uploaded or sent, and no keyboard shortcut starts it.

/// Folders the filled copy is written through on its way into the library; listed in
/// `personalisationTempFolderPrefixes`, so the launch clean-up removes any a crash leaves behind.
let hiddenPocketsTempFolderPrefix = "SlantStudio-PocketsFilled-"

/// "Owl (pockets filled)".
func pocketsFilledCopyName(_ name: String) -> String {
    "\(meshFitCopyBaseName(name)) (pockets filled)"
}

/// Activity: title, counts and status only (no model name, no geometry).
let hiddenPocketsActivityTitle = "Fill hidden pockets"
func hiddenPocketsActivityDetail(filled: Int, removedInside: Int) -> String {
    let pockets = filled == 1 ? "1 pocket filled" : "\(filled.formatted()) pockets filled"
    guard removedInside > 0 else { return "Copy saved · \(pockets)" }
    return "Copy saved · \(pockets), \(removedInside.formatted()) loose \(removedInside == 1 ? "part" : "parts") inside removed"
}

let hiddenPocketsFillCaption = "Fill Hidden Pockets saves a separate copy with them filled solid. This model stays as it is."

// MARK: - Cache

/// In memory, per model and library file (library files are never changed in place). Cleared when the app quits.
@MainActor enum HiddenPocketsCache {
    static var reports: [String: HiddenPocketsReport] = [:]
}

func hiddenPocketsCacheKey(modelID: UUID, path: String) -> String {
    "\(modelID.uuidString)|\(path)"
}

/// Whether the inspector's model checks look for pockets: any STL, except a print-ready copy whose own record already
/// says (its panel shows the line instead).
func hiddenPocketsCheckApplies(_ model: LocalModel) -> Bool {
    model.supportsPreview && model.printPreparation?.hiddenPockets == nil
}

/// What Studio knows about a model's pockets: the print-ready record's count, else a cached check, else nil.
@MainActor func hiddenPocketsKnownCount(_ model: LocalModel) -> Int? {
    if let pockets = model.printPreparation?.hiddenPockets { return pockets.count }
    return HiddenPocketsCache.reports[hiddenPocketsCacheKey(modelID: model.id, path: model.filePath)]?.count
}

/// Fill Hidden Pockets is offered in the menus only when Studio knows the model has pockets.
@MainActor func hiddenPocketsFillOffered(_ model: LocalModel) -> Bool {
    model.supportsPreview && (hiddenPocketsKnownCount(model) ?? 0) > 0
}

/// True when every extra body is a hidden pocket or a part inside one, so the mesh check's body line can point to the
/// pocket line instead of repeating the cost.
func hiddenPocketsAccountForExtraBodies(_ health: MeshHealthReport, _ pockets: HiddenPocketsReport?) -> Bool {
    guard let pockets, pockets.complete, pockets.count > 0, health.shells > 1 else { return false }
    return pockets.separateParts == 1 && pockets.removableBodies == health.shells - 1
}

/// The record a fill of a print-ready copy carries: the same record, now with no pockets and how many were filled, so
/// the copy stays a print-ready copy (Make Print-Ready Copy isn't offered on it) and keeps its lock.
func printPreparationRecordAfterFill(_ record: PrintPreparationRecord, filled: Int) -> PrintPreparationRecord {
    var kept = record
    kept.hiddenPockets = PrintPreparationPockets(count: 0, shellsInside: 0, addedVolumeMM3: 0, filled: filled)
    return kept
}

/// What a fill that saved nothing says, inline under the pocket line (never in an alert).
struct HiddenPocketsFillOutcome: Equatable, Sendable {
    let modelID: UUID
    let message: String
}

// MARK: - Fill

/// One fill at a time, off the main actor. It only reads the library file; the copy goes through `importModel`.
@MainActor final class HiddenPocketsFillRun: ObservableObject {
    /// Set until the work itself ends, even after Stop, so a second fill can't start beside it.
    @Published private(set) var workingModelID: UUID?
    @Published private(set) var stopping = false
    @Published private(set) var outcome: HiddenPocketsFillOutcome?
    private var flag: PrintPreparationCancelFlag?

    /// Stops at the next safe point; the run clears its state when its work has ended.
    func stop() {
        flag?.set()
        stopping = workingModelID != nil
    }

    /// Marks a fill of `modelID` as running and returns its stop flag, or nil while another fill's work hasn't ended.
    func begin(_ modelID: UUID) -> PrintPreparationCancelFlag? {
        guard workingModelID == nil else { return nil }
        let flag = PrintPreparationCancelFlag()
        self.flag = flag
        workingModelID = modelID
        stopping = false
        outcome = nil
        return flag
    }

    /// The work has ended: only now may another fill start.
    func end() {
        workingModelID = nil
        stopping = false
        flag = nil
    }

    fileprivate func start(model: LocalModel, store: StudioStore) {
        guard let flag = begin(model.id) else { return }
        let url = model.url, name = model.name, modelID = model.id
        Task { [weak self, weak store] in
            let result = await Task.detached(priority: .userInitiated) { () -> Result<(HiddenPocketsResult, URL?), Error> in
                Result {
                    let mesh = try STLMesh.read(from: url)
                    let result = try fillHiddenPocketsCopy(of: mesh, isCancelled: { flag.isSet })
                    guard let data = result.data else { return (result, nil) }
                    if flag.isSet { throw HiddenPocketsError.stopped }
                    let folder = studioTempFolderURL(prefix: hiddenPocketsTempFolderPrefix)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let file = folder.appendingPathComponent(exportFileName(modelName: pocketsFilledCopyName(name), fileExtension: "stl"))
                    do { try data.write(to: file, options: .atomic) } catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return (result, file)
                }
            }.value
            let folder: URL? = { if case .success((_, let file?)) = result { return file.deletingLastPathComponent() } else { return nil } }()
            defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
            guard let self else { return }
            self.end()
            // Stopped: nothing is saved or shown.
            guard !flag.isSet, let store else { return }
            switch result {
            case .failure(HiddenPocketsError.stopped):
                return
            case .failure(let error):
                self.outcome = HiddenPocketsFillOutcome(modelID: modelID, message: "Studio couldn’t fill the hidden pockets: \(error.localizedDescription)")
                store.activities.insert(Activity(title: hiddenPocketsActivityTitle, detail: "No copy saved", success: false), at: 0)
            case .success((let fill, nil)):
                let reason = fill.skipped ?? .resultFailedChecks
                self.outcome = HiddenPocketsFillOutcome(modelID: modelID, message: reason.message)
                store.activities.insert(Activity(title: hiddenPocketsActivityTitle,
                                                 detail: reason == .noPockets ? "No hidden pockets found" : "No copy saved",
                                                 success: reason == .noPockets), at: 0)
            case .success((let fill, let file?)):
                // Removed while it was being filled: nothing to attach the copy to.
                guard let original = store.localModels.first(where: { $0.id == modelID }) else { return }
                // Like Repair and simplify: the copy keeps the original's records, its placement and its lock. A print-ready
                // copy's fill keeps its record, now with the pockets filled.
                let record = original.printPreparation.map { printPreparationRecordAfterFill($0, filled: fill.filledPockets) }
                guard store.importModelReturningID(file, recipe: original.printRecipe, improvement: original.designImprovement,
                                                   intent: original.partIntent, reinforcement: original.reinforcement,
                                                   autoImprovement: original.autoImprovement,
                                                   sourceDetails: sourceDetailsForCopy(of: original), printPreparation: record,
                                                   inheritsZUpLock: original.requiresZUp, origin: .studioToolCopy,
                                                   keepsPlacement: original.keepsPlacement == true, filledPockets: true,
                                                   fromPrintReadyCopy: original.derivesFromPrintReadyCopy) != nil else { return }
                store.activities.insert(Activity(title: hiddenPocketsActivityTitle,
                                                 detail: hiddenPocketsActivityDetail(filled: fill.filledPockets, removedInside: fill.removedInnerShells),
                                                 success: true), at: 0)
            }
        }
    }
}

extension StudioStore {
    /// Fill Hidden Pockets: the seller's own request for a separate "(pockets filled)" copy of an STL. Local only; it
    /// never uploads, and never runs while a sheet, alert or dialog is open or a request is running.
    func fillHiddenPockets(modelID: UUID) {
        guard !menuCommandsBlockedByModalUI, !busy else { return }
        guard let model = localModels.first(where: { $0.id == modelID }), model.supportsPreview else { return }
        hiddenPocketsFill.start(model: model, store: self)
    }
}

// MARK: - Views

/// The pocket line with Fill Hidden Pockets (never the default button, no shortcut), Stop while it runs, and what a
/// fill that saved nothing found.
struct HiddenPocketsRow: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject var run: HiddenPocketsFillRun
    let line: String
    let model: LocalModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(line, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Button("Fill Hidden Pockets") { store.fillHiddenPockets(modelID: model.id) }
                    .disabled(run.workingModelID != nil || store.busy)
                if run.workingModelID == model.id {
                    ProgressView().controlSize(.small)
                    Text(run.stopping ? "Stopping…" : "Filling…").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { run.stop() }.disabled(run.stopping)
                }
            }
            if let outcome = run.outcome, outcome.modelID == model.id {
                Text(outcome.message).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(hiddenPocketsFillCaption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The inspector's pocket check for a selected STL, under the mesh check: shown only when pockets are found, or when
/// there were too many separate parts to check. Runs in the background, stops when the selection changes, and is
/// cached per model and file.
struct HiddenPocketsCheck: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    let mesh: STLMesh
    @State private var report: HiddenPocketsReport?
    @State private var reportKey = ""

    var body: some View {
        let key = hiddenPocketsCacheKey(modelID: model.id, path: model.filePath)
        Group {
            if hiddenPocketsCheckApplies(model), let report, reportKey == key {
                if let line = hiddenPocketsLine(report) {
                    HiddenPocketsRow(run: store.hiddenPocketsFill, line: line, model: model)
                        .padding(.horizontal, 4)
                } else if !report.complete {
                    Label(hiddenPocketsIncompleteLine, systemImage: "info.circle")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
            }
        }
        .task(id: "\(key)|\(mesh.triangleCount)") {
            guard hiddenPocketsCheckApplies(model), mesh.triangleCount <= hiddenPocketsMaximumTriangles else { return }
            if let found = await hiddenPocketsCachedReport(key: key, mesh: mesh) {
                report = found
                reportKey = key
            }
        }
    }
}

/// The cached pocket report for a model's file, worked out in the background when it isn't cached yet. Nil when
/// cancelled.
@MainActor func hiddenPocketsCachedReport(key: String, mesh: STLMesh) async -> HiddenPocketsReport? {
    if let cached = HiddenPocketsCache.reports[key] { return cached }
    let worker = Task.detached(priority: .utility) {
        try? hiddenPocketsReport(mesh, isCancelled: { Task.isCancelled })
    }
    let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
    guard !Task.isCancelled, let result else { return nil }
    HiddenPocketsCache.reports[key] = result
    return result
}
