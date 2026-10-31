import SwiftUI
import AppKit

@main
struct PlinthApp: App {
    @NSApplicationDelegateAdaptor(PlinthAppDelegate.self) private var appDelegate
    @StateObject private var store = StudioStore()
    @StateObject private var modalPresentation = ModalPresentationMonitor()
    /// Slant 3D or 3DAPI (PrintService.swift): the File menu's order commands follow it. Read after `init()`'s migration.
    @StateObject private var printChoice = PrintServiceChoice.shared
    init() {
        // First, before the store or anything else reads preferences, the Keychain or the support folder: the one-time
        // move from Slant Studio (LegacyMigration.swift). It does nothing outside the packaged Plinth app.
        LegacyMigration.runAtLaunch()
    }
    var body: some Scene {
        WindowGroup(id: mainWindowID) {
            StudioView().environmentObject(store)
                .frame(minWidth: 1080, minHeight: 720)
                .tint(.studioAccent)
                .modifier(ExternalModelOpenAttachment(store: store))
        }
        .defaultSize(width: 1360, height: 900)
        .windowToolbarStyle(.unified)
        .commands {
            let modalUIShown = store.isPresentingSheet || modalPresentation.isPresenting
            let modelFileEnabled = modelFileCommandsEnabled(destination: store.destination, hasSelectedLocal: store.selectedLocal != nil,
                                                            sheetPresented: modalUIShown)
            // Every File and Go command acts in the main window. After the window was closed, `inMainWindow` opens it
            // again first and runs the command once it has appeared; each command keeps its own checks.
            let inMainWindow: (@escaping @MainActor () -> Void) -> Void = { ExternalModelOpenQueue.shared.performInMainWindow($0) }
            // Slant's order commands only while Slant is the print service; with 3DAPI, ⌘N opens 3DAPI's composer.
            let service = printChoice.service
            let slantOrderCommands = slantOrderMenuCommandsAvailable(service: service)
            let slantOnly: (@escaping @MainActor () -> Void) -> Void = { action in
                inMainWindow { if slantOrderMenuCommandsAvailable(service: PrintServiceChoice.shared.service) { action() } }
            }
            CommandGroup(replacing: .newItem) {
                // Like the Go menu, these do nothing over a sheet, alert or dialog: opening the composer or importing
                // (which shows Models) must never replace an open Pay or Cancel review. Either composer only opens for
                // review; nothing is sent from the menu.
                Button(newOrderMenuTitle(service: service)) { inMainWindow { store.openOrderComposerFromMenu() } }
                    .keyboardShortcut("n")
                    .disabled(service == .dapi ? modalUIShown
                                               : (store.orderDraftBlockedReason != nil || store.busy || modalUIShown))
                Divider()
                // Models. Library file actions only; nothing here uploads, places, pays for or cancels anything.
                Button("Import Model…") { inMainWindow { store.importModelFromMenu() } }
                    .keyboardShortcut("o")
                    .disabled(modalUIShown)
                Button("Upload from URL…") { slantOnly { store.importModelFromURLFromMenu() } }
                    .disabled(!slantOrderCommands || store.importFromURLBlockedReason != nil || modalUIShown)
                // Opens a .scad template to fill in; generating saves a new library model and never uploads.
                Button("Personalise from Template…") { inMainWindow { store.personaliseFromTemplateFromMenu() } }
                    .disabled(modalUIShown)
                // Opens the sheet only; nothing is sent to Claude until Start Design is pressed there.
                Button("Design an Accessory from a Photo…") { inMainWindow { store.openAccessoryDesignerFromMenu() } }
                    .disabled(modalUIShown)
                // Opens the replica sheet only; the photo is sent from there after an explicit Generate Replica.
                Button("Generate a Replica from an Image…") { inMainWindow { store.generateReplicaFromMenu() } }
                    .disabled(modalUIShown)
                Button("Rename Model…") { inMainWindow { store.beginRenamingSelectedModelFromMenu() } }
                    .disabled(!modelFileEnabled)
                Button("Export Model…") { inMainWindow { store.exportSelectedModelFromMenu() } }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(!modelFileEnabled)
                // Opens the listing images sheet; renders are saved to a folder the user picks. Nothing is sent.
                Button("Export Listing Images…") { inMainWindow { store.exportListingImagesFromMenu() } }
                    .disabled(!modelFileEnabled || store.selectedLocal?.supportsMeshPreview != true)
                Divider()
                // Orders. None of these sends a request.
                // Opens the Import Orders sheet only; drafts are created there after an explicit confirmation.
                Button("Import Orders…") { slantOnly { store.importOrdersFromMenu() } }
                    .disabled(!slantOrderCommands || store.orderImportBlockedReason != nil || modalUIShown)
                // Saves a CSV of the loaded orders shown in the list; no request is made.
                Button("Export Orders…") { slantOnly { store.exportOrdersFromMenu() } }
                    .disabled(!slantOrderCommands || !ordersExportMenuEnabled(destination: store.destination, ordersLoaded: !store.orders.isEmpty,
                                                       sheetPresented: modalUIShown))
                // Opens a local list of loaded orders' tracking only; nothing is sent.
                Button("Tracking for Your Shop…") { slantOnly { store.openShopFollowUpFromMenu() } }
                    .disabled(!slantOrderCommands || store.orders.isEmpty || modalUIShown)
                // Opens the spending report for the loaded orders; no request is made.
                Button("Spending Report…") { slantOnly { store.openSpendingReportFromMenu() } }
                    .disabled(!slantOrderCommands || !ordersExportMenuEnabled(destination: store.destination, ordersLoaded: !store.orders.isEmpty,
                                                       sheetPresented: modalUIShown))
                // Opens the Saved Products sheet only (a local list; nothing is sent).
                Button("Saved Products…") { inMainWindow { store.openSavedProductsFromMenu() } }
                    .disabled(modalUIShown)
                Divider()
                Button("Refresh") { inMainWindow { store.refreshFromMenu() } }
                    .keyboardShortcut("r")
                    .disabled(!store.connected || store.busy || modalUIShown
                              || !slantRefreshAvailable(service: service, destination: store.destination))
            }
            SidebarCommands()
            CommandMenu("Go") {
                // API Workbench and Activity are listed only when Settings › Advanced › Show developer tools is on.
                ForEach(goMenuDestinations(showDeveloperTools: store.showDeveloperTools)) { item in
                    if item == sidebarDeveloperDestinations.first { Divider() }
                    let button = Button(item.rawValue) { inMainWindow { store.goFromMenu(to: item) } }
                        .disabled(modalUIShown)
                    if let key = goMenuShortcut(for: item) {
                        button.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
                    } else {
                        button
                    }
                }
            }
            MainWindowAndHelpCommands(modalUIShown: modalUIShown, showDeveloperTools: store.showDeveloperTools)
        }
        // The single home for the account, default platform, platforms and developer options. Its sheets and dialogs
        // count as modal UI (AppModalState checks every window), so main-window menu commands stay inert under them.
        Settings {
            SettingsView()
                .environmentObject(store)
                .environmentObject(modalPresentation)
                .tint(.studioAccent)
        }
    }
}

/// Window › Plinth (⌘0) brings the main window back after it was closed, and the Help menu opens Plinth's own
/// help window and, with developer tools on, Slant's API documentation. None of these sends anything; like every menu command they do nothing
/// while a sheet, alert or dialog is shown.
private struct MainWindowAndHelpCommands: Commands {
    let modalUIShown: Bool
    let showDeveloperTools: Bool
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        // The window's own content also sets this; the app-level action covers a launch that restored no window.
        let _ = ExternalModelOpenQueue.shared.provideOpenMainWindowIfMissing { openWindow(id: mainWindowID) }
        CommandGroup(before: .windowList) {
            Button("Plinth") {
                guard !appIsPresentingModalUI() else { return }
                ExternalModelOpenQueue.shared.revealMainWindow()
            }
            .keyboardShortcut("0")
            .disabled(modalUIShown)
            Divider()
        }
        CommandGroup(replacing: .help) {
            Button("Plinth Help") {
                guard !appIsPresentingModalUI() else { return }
                StudioHelpWindow.show()
            }
            // No ⌘? here: macOS keeps it for the Help menu's search field.
            .disabled(modalUIShown)
            // Developer material: shown only with Settings › Advanced › Show developer tools.
            if showDeveloperTools {
                Button("Slant API Documentation") {
                    guard !appIsPresentingModalUI() else { return }
                    NSWorkspace.shared.open(slantAPIDocumentationURL)
                }
                .disabled(modalUIShown)
            }
        }
    }
}

/// Connects Finder opens to the store once a window exists; files opened earlier wait in the queue.
private struct ExternalModelOpenAttachment: ViewModifier {
    let store: StudioStore
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let queue = ExternalModelOpenQueue.shared
            queue.openMainWindow = { openWindow(id: mainWindowID) }
            queue.attach(store)
        }
    }
}

// MARK: - Help

/// Slant's public API documentation (docs/API_REFERENCE.md).
let slantAPIDocumentationURL = URL(string: "https://slant3dapi.com/documentation/introduction")!

/// Identifies the Help window, so it is never mistaken for the main window.
let helpWindowIdentifier = "PlinthHelp"

struct StudioHelpSection: Identifiable, Equatable {
    var id: String { title }
    let title: String
    /// Markdown: bold for the names of commands and buttons.
    let body: String
}

/// Help › Plinth Help: a short guide to the app, shipped with it (no network).
let studioHelpSections: [StudioHelpSection] = [
    StudioHelpSection(title: "Getting started", body: """
        Open **Settings** (⌘,), paste your Slant 3D API key under **Account** and choose **Save & Test**. Then create or \
        choose a platform: a platform groups your uploads and orders. The key is kept in the macOS Keychain on this Mac.
        """),
    StudioHelpSection(title: "Models", body: """
        Import an STL, OBJ or 3MF model with **File › Import Model…** (⌘O) or by dropping it on the window. Select a \
        model to preview it and check its mesh; the action bar leads through **Upload Model**, **Get Estimate** and \
        **New Order Draft…**. The tools under **Improve for printing** work on STL models and always save a \
        separate copy: the original is never changed.
        """),
    StudioHelpSection(title: "Orders", body: """
        **New Order Draft…** (⌘N) creates a draft on Slant. A draft isn’t charged until you choose **Review & Place \
        Order…** and confirm **Pay & Send to Production**. Slant can’t delete drafts, so if Plinth can’t tell whether \
        a draft was created, it asks before you create another. **File › Import Orders…** creates drafts from an Etsy \
        or Shopify export after you confirm them. If Slant changes its API after this version of Plinth was made, a \
        notice at the top of Orders says so; Plinth keeps working as before and only tells you.
        """),
    StudioHelpSection(title: "Catalog", body: """
        Browse Slant’s materials, components and stationery.
        """),
    StudioHelpSection(title: "Design tools (optional)", body: """
        **Review for Printing with Claude…**, **Design an Accessory from a Photo…** and **Generate a Replica from an \
        Image…** use your own Claude (Anthropic), Meshy or Tripo account, set up in **Settings › Design Tools**. Each \
        request that costs money is a button you press, with an estimate shown first, and Plinth never resends one by \
        itself.
        """),
    StudioHelpSection(title: "Price comparison with 3DAPI (optional)", body: """
        **Get 3DAPI Quote…** in a model’s **Print configuration** shows what 3DAPI, a separate print service, would \
        charge to print it, beside Slant’s price. It needs a key from a 3DAPI integrator account, saved in \
        **Settings › Account**. Getting a quote sends the model file to 3DAPI, which keeps it. Plinth only compares \
        prices: it never orders or pays on 3DAPI.
        """),
    StudioHelpSection(title: "What Plinth never does by itself", body: """
        No menu item or keyboard shortcut uploads, pays, cancels or sends anything. When Plinth can’t tell whether a \
        payment or cancellation went through, it holds that order until a reload shows what happened.
        """),
    StudioHelpSection(title: "Privacy", body: """
        Customers’ names, addresses and personalisation stay in memory and are never saved on this Mac. Your own \
        address is saved only if you choose to save it.
        """),
    StudioHelpSection(title: "If the window is closed", body: """
        Click Plinth in the Dock, or choose **Window › Plinth** (⌘0).
        """),
    StudioHelpSection(title: "Keyboard shortcuts", body: """
        ⌘N New Order Draft… · ⌘O Import Model… · ⇧⌘E Export Model… · ⌘R Refresh · ⌘1 Models · ⌘2 Orders · \
        ⌘3 Catalog · ⌘0 Plinth window · ⌘, Settings
        """)
]

struct StudioHelpView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Plinth Help").font(.title2.weight(.bold))
                ForEach(studioHelpSections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
                        Text(LocalizedStringKey(section.body))
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 420, idealWidth: 520, minHeight: 360, idealHeight: 620)
    }
}

/// One Help window, reused: choosing Help again brings it forward.
@MainActor enum StudioHelpWindow {
    private static var window: NSWindow?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: StudioHelpView()))
        window.title = "Plinth Help"
        window.identifier = NSUserInterfaceItemIdentifier(helpWindowIdentifier)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 520, height: 620))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Quitting while a Slant write is in flight

/// What kind of Slant write is waiting for its reply; named in the quit question.
enum SlantWriteKind: String, CaseIterable {
    case payment = "a payment"
    case cancellation = "a cancellation"
    case draft = "a new draft"
    case upload = "an upload"
    case importOrders = "an Import Orders draft"
    case payDrafts = "a Pay Several Drafts payment"
    case dapiOrder = "a 3DAPI order"
    case dapiCancellation = "a 3DAPI cancellation"

    /// The service that will answer it.
    var service: PrintService {
        switch self {
        case .dapiOrder, .dapiCancellation: .dapi
        default: .slant
        }
    }
}

/// Slant writes still waiting for a reply: a pay or cancel (Orders or the API Workbench), a draft create (the composer
/// or the Workbench), a model upload (Slant may keep a file whose confirm went unanswered), or an Import Orders or Pay Several Drafts batch from start to finish. The unknown-outcome lock
/// and the unconfirmed-draft guard last only for the session, so quitting mid-request would lose the record of a write
/// that may have reached Slant: Quit asks first (`slantWritesQuitQuestion`). Memory only; nothing else reads it.
@MainActor final class SlantWritesInFlight {
    static let shared = SlantWritesInFlight()
    private var active: [UUID: SlantWriteKind] = [:]

    func begin(_ kind: SlantWriteKind) -> UUID {
        let token = UUID()
        active[token] = kind
        return token
    }

    func end(_ token: UUID) { active[token] = nil }

    var kinds: [SlantWriteKind] { Array(active.values) }
}

/// The quit question's title and message while writes are in flight, or nil (quit at once) when none are.
func slantWritesQuitQuestion(_ kinds: [SlantWriteKind]) -> (title: String, message: String)? {
    let named = SlantWriteKind.allCases.filter { kinds.contains($0) }.map(\.rawValue)
    guard let last = named.last else { return nil }
    let list = named.count == 1 ? last : named.dropLast().joined(separator: ", ") + " and " + last
    let services = Set(kinds.map(\.service))
    let who = services == [.dapi] ? "3DAPI" : (services == [.slant] ? "Slant" : "Slant and 3DAPI")
    return ("Quit while \(who) \(services.count > 1 ? "are" : "is") still answering?",
            "Plinth is still waiting for \(who) to answer \(list). If you quit now, Plinth can’t record whether it "
            + "went through, so it can’t warn you before you send it again. Wait for it to finish, then quit.")
}

extension PlinthAppDelegate {
    /// Asks before quitting while a Slant write is in flight, with Don't Quit as the default; quits at once otherwise.
    @objc func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let question = slantWritesQuitQuestion(SlantWritesInFlight.shared.kinds) else { return .terminateNow }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = question.title
            alert.informativeText = question.message
            alert.addButton(withTitle: "Don’t Quit")
            alert.addButton(withTitle: "Quit Anyway")
            return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
        }
    }
}
