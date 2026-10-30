import SwiftUI
import AppKit
import UserNotifications

// MARK: - Opening models from Finder

/// Pending Finder opens, without duplicates and in the order received. Only STL, OBJ and 3MF file URLs are kept; a
/// model dragged from the library onto the Dock icon (its drag copy, ModelDragExport.swift) is already in the library.
func queuedModelOpens(_ pending: [URL], adding urls: [URL],
                      temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> [URL] {
    var result = pending
    var seen = Set(pending.map { $0.standardizedFileURL.path })
    for url in urls where url.isFileURL && ModelFileFormat(url: url) != nil
        && !ModelDragExport.isDragCopy(url, temporaryDirectory: temporaryDirectory) {
        if seen.insert(url.standardizedFileURL.path).inserted { result.append(url) }
    }
    return result
}

/// Files opened from Finder or the Dock wait while anything modal is up or a request is running, so an import never
/// switches screens behind a sheet (for example a Pay or Cancel review) or while a charge is in flight.
func externalOpenCanImport(storeSheetPresented: Bool, appModalUIPresented: Bool, errorShown: Bool, busy: Bool) -> Bool {
    !storeSheetPresented && !appModalUIPresented && !errorShown && !busy
}

/// Toolbar note while Finder opens wait for a sheet, alert or request to finish; nil when nothing is waiting.
func queuedImportNote(count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1 ? "1 file waiting to import" : "\(count) files waiting to import"
}

/// Holds files handed to the app by Launch Services until the store can import them. Opens can arrive before the
/// window (and so the store) exists, such as when a double-click launches the app.
@MainActor final class ExternalModelOpenQueue: ObservableObject {
    static let shared = ExternalModelOpenQueue()
    @Published private(set) var pending: [URL] = []
    /// True once an import has had to wait for a sheet, alert or request, so the toolbar note doesn't flash for the
    /// brief delay before every import.
    @Published private(set) var isWaiting = false
    private weak var store: StudioStore?
    private var drainScheduled = false

    /// Launch Services only delivers the declared STL, OBJ and 3MF types. Anything else is dropped quietly rather than
    /// raising an alert that could appear over a review sheet.
    func enqueue(_ urls: [URL]) {
        pending = queuedModelOpens(pending, adding: urls)
        guard !pending.isEmpty else { return }
        // Show the window first: an error alert or a review left open in a closed window would otherwise hold the
        // import back with nothing on screen. Raising it doesn't dismiss or act on anything presented in it.
        revealMainWindow()
        scheduleDrain()
    }

    /// Also used by order notification clicks (OrderWatch.swift), the Dock icon, Window › Slant Studio and the menu
    /// commands that act in the main window. Returns true when the window had been closed and a new one was asked for.
    @discardableResult
    func revealMainWindow() -> Bool {
        // A hidden app's windows report not visible, which would look like a closed window and open a second one.
        if NSApp.isHidden { NSApp.unhide(nil) }
        if let window = existingMainWindow() {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
            return false
        }
        // One main window only (the store is shared): a second request while the first window is still opening, such
        // as a double click on the Dock icon, waits for it instead of opening another.
        if let asked = mainWindowRequestedAt, Date().timeIntervalSince(asked) < 2 { return true }
        mainWindowRequestedAt = Date()
        openMainWindow?()
        return true
    }

    /// The main window while it is open (shown or minimised), or nil once it has been closed.
    func existingMainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            isMainStudioWindowCandidate(identifier: window.identifier?.rawValue, isPanel: window is NSPanel,
                                        canBecomeMain: window.canBecomeMain)
                && (window.isVisible || window.isMiniaturized)
        }
    }

    /// True while the main window is on screen and not minimised.
    var mainWindowIsShown: Bool {
        guard !NSApp.isHidden, let window = existingMainWindow() else { return false }
        return window.isVisible && !window.isMiniaturized
    }

    /// Runs a menu command that acts in the main window, raising the window first. When the window had been closed,
    /// the command waits for the new window's content, so a sheet it opens has a window to appear in. A command still
    /// waiting after a few seconds is dropped rather than run later by surprise. Each command keeps its own checks.
    func performInMainWindow(_ action: @escaping @MainActor () -> Void) {
        if NSApp.isHidden { NSApp.unhide(nil) }
        if existingMainWindow() != nil {
            _ = revealMainWindow()
            action()
        } else {
            // Queued before the window is asked for, so the new content's first appearance always finds it.
            actionsAwaitingMainWindow.append((Date(), action))
            _ = revealMainWindow()
        }
    }

    /// Called when the main window's content appears: runs the menu commands that were waiting for it.
    private func mainWindowContentAppeared() {
        mainWindowRequestedAt = nil
        let fresh = actionsAwaitingMainWindow.filter { Date().timeIntervalSince($0.date) < 5 }.map(\.action)
        actionsAwaitingMainWindow = []
        guard !fresh.isEmpty else { return }
        Task { @MainActor in
            // Let the new window finish its first layout, so its sheets are attached before a command shows one.
            try? await Task.sleep(nanoseconds: 250_000_000)
            for action in fresh { action() }
        }
    }

    private var mainWindowRequestedAt: Date?
    private var actionsAwaitingMainWindow: [(date: Date, action: @MainActor () -> Void)] = []

    /// Called when the main window's content appears (each time the window is opened).
    func attach(_ store: StudioStore) {
        self.store = store
        mainWindowContentAppeared()
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

    /// The app-level open action from the menu commands, used only until a window's content has set its own.
    func provideOpenMainWindowIfMissing(_ open: @escaping () -> Void) {
        if openMainWindow == nil { openMainWindow = open }
    }

    private func drainIfIdle() {
        guard let store, !pending.isEmpty else { return }
        guard externalOpenCanImport(storeSheetPresented: store.isPresentingSheet, appModalUIPresented: appIsPresentingModalUI(),
                                    errorShown: store.error != nil, busy: store.busy) else {
            // Keep checking while files are waiting; this stops as soon as the queue is empty.
            if !isWaiting { isWaiting = true }
            scheduleDrain()
            return
        }
        let urls = pending
        pending = []
        if isWaiting { isWaiting = false }
        for url in urls { store.importModel(url, origin: .imported) }
        if existingMainWindow() == nil { revealMainWindow() }
    }
}

let mainWindowID = "main"

/// Whether a window could be the main window: not a panel (open and save panels, the About panel), the Settings
/// window or the Help window, which can all become main too.
func isMainStudioWindowCandidate(identifier: String?, isPanel: Bool, canBecomeMain: Bool) -> Bool {
    guard canBecomeMain, !isPanel else { return false }
    guard let identifier else { return true }
    return !identifier.localizedCaseInsensitiveContains("settings") && identifier != helpWindowIdentifier
}

/// Receives Open With, double-click and Dock-icon drops. Imports copy the file into the library, as the Import panel does.
final class SlantStudioAppDelegate: NSObject, NSApplicationDelegate {
    /// The notification delegate must be set before launch finishes, so a click on an order notification that launched
    /// the app is delivered (OrderWatch.swift holds it until the window and store exist).
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Normally done already by the App's init(); this only guards a different start-up order.
        MainActor.assumeIsolated { LegacyMigration.runAtLaunch() }
        if orderWatchNotificationsAvailable() { UNUserNotificationCenter.current().delegate = OrderWatchNotificationDelegate.shared }
        // One main window only (the store is shared): no window tabs, whose + button would open a second one. Set
        // before the first window, so the tab menu items never appear.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { ExternalModelOpenQueue.shared.enqueue(urls) }
    }

    /// A click on the Dock icon (or `open` / an AppleScript reopen) brings the main window back after it was closed or
    /// minimised, even while only Settings is showing. Raising it doesn't dismiss or act on anything presented in it.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainActor.assumeIsolated {
            let queue = ExternalModelOpenQueue.shared
            if queue.mainWindowIsShown { return true }
            queue.revealMainWindow()
            return false
        }
    }
}

// MARK: - File menu commands

func ordersExportMenuEnabled(destination: Destination, ordersLoaded: Bool, sheetPresented: Bool) -> Bool {
    destination == .orders && ordersLoaded && !sheetPresented
}

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

    /// File › Export Orders…: only on Orders with orders loaded and nothing modal shown. Writes a local file only.
    func exportOrdersFromMenu() {
        guard !menuCommandsBlockedByModalUI, ordersExportMenuEnabled(destination: destination, ordersLoaded: !orders.isEmpty,
                                                                     sheetPresented: false) else { return }
        ordersExportRequest += 1
    }

    /// File › Saved Products…: opens the local product list only (no request), and only when nothing modal is shown.
    func openSavedProductsFromMenu() {
        guard !menuCommandsBlockedByModalUI else { return }
        openSavedProducts()
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

/// Why no STL copy (or scaled STL copy) can be saved from this preview, or nil when one can. A face that couldn't be
/// split into triangles exactly is only approximated in the preview, so a copy wouldn't match the original file.
func stlCopyBlockedReason(format: ModelFileFormat, inexactFaces: Int) -> String? {
    guard inexactFaces > 0 else { return nil }
    let faces = inexactFaces == 1 ? "a face" : "\(inexactFaces.formatted()) faces"
    return "This \(format.displayName) has \(faces) that can’t be split into triangles exactly (for example, one that crosses itself), so an STL copy wouldn’t match it. Fix the faces in your modelling tool and import the file again."
}

/// What an STL-only tool card says for other models. OBJ and 3MF models get one shared notice with **Save STL copy**
/// above the tool cards, so their cards return nil here; anything else simply isn't supported.
func stlOnlyToolNote(_ model: LocalModel) -> String? {
    guard !model.supportsPreview else { return nil }
    return model.supportsMeshPreview ? nil : "Available for STL files."
}

/// Inside a collapsed tool card for an OBJ or 3MF model, pointing back to the shared notice.
let stlCopyToolNote = "Works on an STL copy. Use Save STL Copy above."

/// Scale card wording; OBJ and 3MF sources are saved as STL.
func scaledCopyExplanation(format: ModelFileFormat) -> String {
    let kind = format == .stl ? "" : " The copy is an STL file."
    return "If it was, save a scaled copy.\(kind) This model is kept as it is; the copy needs its own upload and estimate."
}

extension STLMesh {
    /// The same geometry as a binary STL, parsed back and checked like a scaled copy (×1): every triangle kept, no new
    /// degenerate triangles, and the same size.
    func stlCopyData() throws -> Data { try scaledSTLData(by: 1) }
}

extension StudioStore {
    /// Adds a separate binary STL of an OBJ or 3MF model's previewed geometry, so the STL-only tools can use it.
    /// The original stays in the library unchanged and is still what an upload of that model sends.
    /// `sourceDetails` are the previewed file's own (a 3MF's designer and licence); the copy keeps them.
    func saveSTLCopy(of modelID: UUID, mesh: STLMesh, inexactFaces: Int, sourceDetails: ModelSourceDetails = ModelSourceDetails()) async {
        guard let model = localModels.first(where: { $0.id == modelID }), !model.supportsPreview, model.supportsMeshPreview,
              let format = ModelFileFormat(url: model.url) else { return }
        if let reason = stlCopyBlockedReason(format: format, inexactFaces: inexactFaces) {
            showError("The STL copy wasn’t saved. \(reason)")
            return
        }
        let fileName = exportFileName(modelName: stlCopyName(model.name), fileExtension: "stl")
        let result = await Task.detached(priority: .userInitiated) {
            Result { () -> URL in
                let data = try mesh.stlCopyData()
                let folder = studioTempFolderURL(prefix: stlCopyTempFolderPrefix)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let url = folder.appendingPathComponent(fileName)
                do { try data.write(to: url, options: .atomic) }
                catch { try? FileManager.default.removeItem(at: folder); throw error }
                return url
            }
        }.value
        switch result {
        case .success(let url):
            if importModel(url, intent: model.partIntent, sourceDetails: sourceDetailsForCopy(of: model, fromFile: sourceDetails),
                           origin: .stlCopyOfOtherFormat) {
                activities.insert(Activity(title: "Save STL copy", detail: model.name, success: true), at: 0)
            }
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        case .failure(let error):
            showError("The STL copy wasn’t saved: \(error.localizedDescription)")
        }
    }
}
