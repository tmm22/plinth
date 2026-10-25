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

/// Fill Hidden Pockets is offered for STL models unless Studio already knows there are none.
@MainActor func hiddenPocketsFillOffered(_ model: LocalModel) -> Bool {
    model.supportsPreview && hiddenPocketsKnownCount(model) != 0
}

// MARK: - Fill

/// One fill at a time, off the main actor. It only reads the library file; the copy goes through `importModel`.
@MainActor final class HiddenPocketsFillRun: ObservableObject {
    @Published private(set) var workingModelID: UUID?
    private var flag: PrintPreparationCancelFlag?

    func stop() {
        flag?.set()
        flag = nil
        workingModelID = nil
    }

    fileprivate func start(model: LocalModel, store: StudioStore) {
        guard workingModelID == nil else { return }
        let flag = PrintPreparationCancelFlag()
        self.flag = flag
        workingModelID = model.id
        let url = model.url, name = model.name, modelID = model.id
        Task { [weak self, weak store] in
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<(HiddenPocketsResult, URL?), Error> in
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
            let folder: URL? = { if case .success((_, let file?)) = outcome { return file.deletingLastPathComponent() } else { return nil } }()
            defer { if let folder { try? FileManager.default.removeItem(at: folder) } }
            // Stopped: nothing is saved or shown.
            guard !flag.isSet, let self, let store else { return }
            self.workingModelID = nil
            self.flag = nil
            switch outcome {
            case .failure(HiddenPocketsError.stopped):
                return
            case .failure(let error):
                store.showError("Studio couldn’t fill the hidden pockets: \(error.localizedDescription)")
            case .success((let result, nil)):
                store.showError(result.skipped?.message ?? HiddenPocketsSkipReason.resultFailedChecks.message)
            case .success((let result, let file?)):
                // Removed while it was being filled: nothing to attach the copy to.
                guard let original = store.localModels.first(where: { $0.id == modelID }) else { return }
                // Like Repair and simplify: the copy keeps the original's records, its placement and its lock.
                guard store.importModelReturningID(file, recipe: original.printRecipe, improvement: original.designImprovement,
                                                   intent: original.partIntent, reinforcement: original.reinforcement,
                                                   autoImprovement: original.autoImprovement,
                                                   sourceDetails: sourceDetailsForCopy(of: original),
                                                   inheritsZUpLock: original.requiresZUp, origin: .studioToolCopy,
                                                   keepsPlacement: original.keepsPlacement == true, filledPockets: true) != nil else { return }
                store.activities.insert(Activity(title: hiddenPocketsActivityTitle,
                                                 detail: hiddenPocketsActivityDetail(filled: result.filledPockets, removedInside: result.removedInnerShells),
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

/// The pocket line with Fill Hidden Pockets (never the default button, no shortcut) and, while it runs, Stop.
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
                    Text("Filling…").font(.caption).foregroundStyle(.secondary)
                    Button("Stop") { run.stop() }
                }
            }
            Text(hiddenPocketsFillCaption).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The inspector's pocket check for a selected STL, under the mesh check: shown only when pockets are found. Runs in
/// the background, stops when the selection changes, and is cached per model and file.
struct HiddenPocketsCheck: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    let mesh: STLMesh
    @State private var report: HiddenPocketsReport?
    @State private var reportKey = ""

    var body: some View {
        let key = hiddenPocketsCacheKey(modelID: model.id, path: model.filePath)
        Group {
            if hiddenPocketsCheckApplies(model), let report, reportKey == key, let line = hiddenPocketsLine(report) {
                HiddenPocketsRow(run: store.hiddenPocketsFill, line: line, model: model)
                    .padding(.horizontal, 4)
            }
        }
        .task(id: "\(key)|\(mesh.triangleCount)") {
            guard hiddenPocketsCheckApplies(model), mesh.triangleCount <= hiddenPocketsMaximumTriangles else { return }
            if let cached = HiddenPocketsCache.reports[key] {
                report = cached
                reportKey = key
                return
            }
            let mesh = mesh
            let worker = Task.detached(priority: .utility) {
                try? hiddenPocketsReport(mesh, isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let result else { return }
            HiddenPocketsCache.reports[key] = result
            report = result
            reportKey = key
        }
    }
}
