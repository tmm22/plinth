import SwiftUI
import AppKit

// MARK: - Opening models from Finder

/// Pending Finder opens, without duplicates and in the order received. Only STL, OBJ and 3MF file URLs are kept.
func queuedModelOpens(_ pending: [URL], adding urls: [URL]) -> [URL] {
    var result = pending
    var seen = Set(pending.map { $0.standardizedFileURL.path })
    for url in urls where url.isFileURL && ModelFileFormat(url: url) != nil {
        if seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
    }
    return result
}

/// Files opened from Finder or the Dock wait while anything modal is up or a request is running, so an import never
/// switches screens behind a sheet (for example a Pay or Cancel review) or while a charge is in flight.
func externalOpenCanImport(storeSheetPresented: Bool, appModalUIPresented: Bool, errorShown: Bool, busy: Bool) -> Bool {
    !storeSheetPresented && !appModalUIPresented && !errorShown && !busy
}

/// Holds files handed to the app by Launch Services until the store can import them. Opens can arrive before the
/// window (and so the store) exists, such as when a double-click launches the app.
@MainActor final class ExternalModelOpenQueue: ObservableObject {
    static let shared = ExternalModelOpenQueue()
    @Published private(set) var pending: [URL] = []
    private weak var store: StudioStore?
    private var drainScheduled = false

    /// Launch Services only delivers the declared STL, OBJ and 3MF types. Anything else is dropped quietly rather than
    /// raising an alert that could appear over a review sheet.
    func enqueue(_ urls: [URL]) {
        pending = queuedModelOpens(pending, adding: urls)
        scheduleDrain()
    }

    func attach(_ store: StudioStore) {
        self.store = store
        scheduleDrain()
    }

    /// Waits briefly so a sheet that is closing while another opens (for example a review followed by an alert) is not
    /// mistaken for an idle window, then re-checks AppKit's modal state at the moment of import.
    func scheduleDrain() {
        guard !pending.isEmpty, !drainScheduled else { return }
        drainScheduled = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            drainScheduled = false
            drainIfIdle()
        }
    }

    /// Opens the main window when files arrive after every window was closed. Set by the window's content.
    var openMainWindow: (() -> Void)?

    private func drainIfIdle() {
        guard let store, !pending.isEmpty else { return }
        guard externalOpenCanImport(storeSheetPresented: store.isPresentingSheet, appModalUIPresented: appIsPresentingModalUI(),
                                    errorShown: store.error != nil, busy: store.busy) else {
            // Keep checking while files are waiting; this stops as soon as the queue is empty.
            scheduleDrain()
            return
        }
        let urls = pending
        pending = []
        for url in urls { store.importModel(url) }
        if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) { openMainWindow?() }
    }
}

let mainWindowID = "main"

/// Receives Open With, double-click and Dock-icon drops. Imports copy the file into the library, as the Import panel does.
final class SlantStudioAppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ExternalModelOpenQueue.shared.enqueue(urls) }
    }
}

// MARK: - File menu commands

extension StudioStore {
    /// File menu commands act only when no sheet, alert or dialog is up; their disabled state can lag behind AppKit.
    var menuCommandsBlockedByModalUI: Bool { isPresentingSheet || appIsPresentingModalUI() }

    func importModelFromMenu() {
        guard !menuCommandsBlockedByModalUI else { return }
        importModel()
    }

    func importModelFromURLFromMenu() {
        guard !menuCommandsBlockedByModalUI, importFromURLBlockedReason == nil else { return }
        showImportFromURL = true
    }

    func openOrderComposerFromMenu() {
        guard !menuCommandsBlockedByModalUI, orderDraftBlockedReason == nil, !busy else { return }
        openOrderComposer()
    }

    func refreshFromMenu() {
        guard !menuCommandsBlockedByModalUI, connected, !busy else { return }
        Task { await refreshCurrent() }
    }
}

// MARK: - STL copies of OBJ and 3MF models

/// Library name for an STL copy, without the original's file extension.
func stlCopyName(_ name: String) -> String {
    var base = name
    if let dot = base.lastIndex(of: "."), dot > base.startIndex,
       modelNameFileExtensions.contains(base[base.index(after: dot)...].lowercased()) {
        base = String(base[..<dot])
    }
    return "\(base) (STL copy)"
}

extension STLMesh {
    /// The same geometry as a binary STL, parsed back and checked like a scaled copy (×1): every triangle kept, no new
    /// degenerate triangles, and the same size.
    func stlCopyData() throws -> Data { try scaledSTLData(by: 1) }
}

extension StudioStore {
    /// Adds a separate binary STL of an OBJ or 3MF model's previewed geometry, so the STL-only tools can use it.
    /// The original stays in the library unchanged and is still what an upload of that model sends.
    func saveSTLCopy(of modelID: UUID, mesh: STLMesh) async {
        guard let model = localModels.first(where: { $0.id == modelID }), !model.supportsPreview, model.supportsMeshPreview else { return }
        let fileName = exportFileName(modelName: stlCopyName(model.name), fileExtension: "stl")
        let result = await Task.detached(priority: .userInitiated) {
            Result { () -> URL in
                let data = try mesh.stlCopyData()
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(fileName)
                do { try data.write(to: url, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: folder); throw error }
                return url
            }
        }.value
        switch result {
        case .success(let url):
            if importModel(url, intent: model.partIntent) {
                activities.insert(Activity(title: "Save STL copy", detail: model.name, success: true), at: 0)
            }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        case .failure(let error):
            showError("The STL copy wasn’t saved: \(error.localizedDescription)")
        }
    }
}
