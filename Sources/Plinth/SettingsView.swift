import SwiftUI
import AppKit

// MARK: - Settings window (⌘,)

/// The single home for the Slant account: the API key, the default platform and the platform list (Account), and
/// usage, identifiers, billing and the developer-tools switch (Advanced). Sheets and dialogs shown here are attached to
/// the Settings window, which `AppModalState` checks like any other window, so menu commands stay inert under them.
struct SettingsView: View {
    @EnvironmentObject var store: StudioStore

    var body: some View {
        TabView(selection: $store.settingsTab) {
            AccountSettingsTab()
                .tabItem { Label("Account", systemImage: "person.crop.circle") }
                .tag(SettingsTab.account)
            DesignToolsSettingsTab()
                .tabItem { Label("Design Tools", systemImage: "wand.and.stars") }
                .tag(SettingsTab.designTools)
            AdvancedSettingsTab()
                .tabItem { Label("Advanced", systemImage: "gearshape.2") }
                .tag(SettingsTab.advanced)
        }
        // A composer can't outlive its window; never leave the flag set (it would keep menu commands disabled).
        .onDisappear { store.showSettingsPlatformComposer = false }
    }
}

private struct ProminentWhen: ViewModifier {
    let isProminent: Bool
    init(_ isProminent: Bool) { self.isProminent = isProminent }
    @ViewBuilder
    func body(content: Content) -> some View {
        if isProminent {
            content.buttonStyle(.borderedProminent)
        } else {
            content.buttonStyle(.bordered)
        }
    }
}

extension View {
    /// Grouped-form footers that fit on one line otherwise sit at the trailing edge; keep every footer leading.
    func settingsFooterLayout() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
    }
}

/// Both tabs share one size so the window doesn't jump when switching tabs.
let settingsTabHeight: CGFloat = 620

enum ConnectionProminentAction: Equatable {
    case saveTest, createPlatform, none
}

/// The one button Settings › Account highlights: save a new or changed key first, then create a platform when the
/// account has none chosen. Once both are done nothing is highlighted.
func connectionProminentAction(connected: Bool, savedKey: String, keyField: String, platformID: String) -> ConnectionProminentAction {
    let trimmedField = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyDiffers = trimmedField != savedKey
    if !connected || keyDiffers { return .saveTest }
    if platformID.isEmpty { return .createPlatform }
    return .none
}

/// Why Show developer tools can't change right now, or nil. Hiding the Workbench while it runs a request or shows a
/// review would tear its view down part-way, so the switch waits for requests and modal UI (in any window) to finish.
func developerToolsToggleBlockedReason(busy: Bool, modalUIShown: Bool) -> String? {
    if busy { return "Wait for the current request to finish." }
    if modalUIShown { return "Close the open sheet, alert or dialog first." }
    return nil
}

/// Why Settings can't change or remove the API key right now, or nil. A new key may belong to another account and
/// Disconnect replaces Orders with the connect prompt, so neither may happen under an open review, draft or other sheet,
/// alert or dialog in any window, or while a request runs.
func accountKeyChangeBlockedReason(busy: Bool, modalUIShown: Bool) -> String? {
    if busy { return "Wait for the current request to finish." }
    if modalUIShown { return "Close the open sheet, alert or dialog first." }
    return nil
}

// MARK: - Account

struct AccountSettingsTab: View {
    @EnvironmentObject var store: StudioStore
    @EnvironmentObject var modalPresentation: ModalPresentationMonitor
    @State private var key = ""
    @State private var confirmDisconnect = false
    @State private var connectError: String?
    @State private var platforms = PlatformsSettingsState()
    /// AppKit makes the first text field first responder (with the key selected) when the window opens; a stray
    /// keystroke would then replace the key. Focus is released on appear so the field is focused only by the user.
    @FocusState private var keyFieldFocused: Bool
    /// Save & Test's test of a new key is running. The saved key stays connected meanwhile (`connect(key:)` changes
    /// nothing until the new key passes), so the status line says the new key is being tested.
    @State private var testingKey = false
    /// Whether this tab is on screen, read by Save & Test's task when the test ends (`slantKeyTestFailureShowsInSettings`).
    @State private var visibility = SettingsTabVisibility()

    private var prominent: ConnectionProminentAction {
        connectionProminentAction(
            connected: store.connected,
            savedKey: store.apiKey,
            keyField: key,
            platformID: store.platformID
        )
    }

    private var keyChanges: Bool {
        key.trimmingCharacters(in: .whitespacesAndNewlines) != store.apiKey
    }
    private var keyChangeBlocked: String? {
        accountKeyChangeBlockedReason(busy: store.busy, modalUIShown: store.isPresentingSheet || modalPresentation.isPresenting)
    }
    /// The action-time check is authoritative; the published modal state can lag behind AppKit.
    private var keyChangeBlockedNow: String? {
        accountKeyChangeBlockedReason(busy: store.busy, modalUIShown: store.isPresentingSheet || appIsPresentingModalUI())
    }

    var body: some View {
        Form {
            PrintServiceSettingsSection() // PrintService.swift

            Section {
                // No onSubmit: Return never sends the key anywhere.
                SecureField("API key", text: $key, prompt: Text("sl-…"))
                    .focused($keyFieldFocused)
                HStack {
                    Button("Save & Test") { saveAndTest() }
                        .modifier(ProminentWhen(prominent == .saveTest))
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy
                                  || (keyChanges && keyChangeBlocked != nil))
                    if store.hasKey {
                        Button("Disconnect…", role: .destructive) {
                            if let reason = keyChangeBlockedNow { connectError = reason } else { confirmDisconnect = true }
                        }
                        .disabled(keyChangeBlocked != nil)
                    }
                    Spacer()
                    Link("Get an API Key", destination: URL(string: "https://slant3dapi.com")!)
                }
                switch slantKeyStatusLine(keyField: key, savedKey: store.apiKey, testing: testingKey,
                                          errorShown: connectError != nil, connected: store.connected) {
                case .testing:
                    Label("Testing the key…", systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                case .notSavedYet:
                    Label(slantKeyNotSavedYetText, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                case .verified:
                    Label("Connection verified", systemImage: "checkmark.circle.fill").foregroundStyle(.studioSuccess)
                case .connectionStatus:
                    Label(connectionFooterStatus(hasKey: true, connected: false, accountLoaded: store.accountLoaded, busy: store.busy),
                          systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                case .notConnected:
                    Text("Not connected").foregroundStyle(.secondary)
                case .hidden:
                    EmptyView()
                }
                if store.hasKey || keyChanges, let keyChangeBlocked, !store.busy {
                    Text(keyChangeBlocked).font(.caption).foregroundStyle(.secondary)
                }
                if let connectError {
                    Label(connectError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.studioWarning)
                }
            } header: {
                Text("Slant account")
            } footer: {
                Text("The key is stored in the macOS Keychain on this Mac. Billing is managed on the Slant website.")
                    .settingsFooterLayout()
            }

            PlatformsSettingsSections(state: $platforms, createProminent: prominent == .createPlatform)

            SellerAddressSettingsSection() // SellerAddressView.swift

            ShopifySettingsSection() // ShopifySettingsView.swift
            DapiSettingsSection() // DapiSettingsView.swift
        }
        .formStyle(.grouped)
        .frame(width: 620, height: settingsTabHeight)
        .onAppear {
            visibility.shown = true
            key = store.apiKey
        }
        // Another tab chosen or the window closed: a Save & Test still running reports to the main window instead.
        .onDisappear { visibility.shown = false }
        .task {
            // The window assigns its initial first responder after this view appears, so release it on the next
            // turns of the run loop too. Only within the first moments after opening, so a deliberate click stays.
            for delay in [0, 50, 200] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
                guard !Task.isCancelled else { return }
                keyFieldFocused = false
            }
        }
        .onChange(of: store.apiKey) { _, new in key = new }
        .modifier(PlatformsSettingsSheets(state: $platforms))
        .confirmationDialog("Disconnect this Mac?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { store.disconnect(); key = ""; connectError = nil }
                .disabled(store.busy)
            // Never the destructive button: Return keeps the key.
            Button("Keep Connected", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This removes the saved API key from the Keychain on this Mac.")
        }
    }

    private func saveAndTest() {
        connectError = nil
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !store.busy else { return }
        if trimmed != store.apiKey, let reason = keyChangeBlockedNow {
            connectError = reason
            return
        }
        let savedKey = store.apiKey
        let visibility = self.visibility
        testingKey = true
        Task {
            let passed = await store.connect(key: key)
            testingKey = false
            // Judged by the test itself, not `connected`: a key that fails leaves the saved key connected as it was.
            guard !passed, let message = store.error else { return }
            let text = slantKeyTestFailureText(
                message, savedKeyKept: !savedKey.isEmpty && savedKey != trimmed && store.apiKey == savedKey)
            if slantKeyTestFailureShowsInSettings(tabShown: visibility.shown, selectedTab: store.settingsTab) {
                // Shown here; the main window's alert would sit unseen behind this window.
                _ = takeStoreErrorForSettings(store)
                connectError = text
            } else {
                // The tab has gone (another tab, or Settings closed) during the test: never lost, but in the main
                // window's alert, worded for the typed key, with no Try Again (`showError`), since the key is
                // changed only from here.
                store.showError(text)
            }
        }
    }
}

/// Whether this view is on screen. A class held in `@State`, so a task started by the view reads the live value even
/// after the view has gone (its last `onDisappear` left it false).
@MainActor final class SettingsTabVisibility {
    var shown = false
}

/// Where Save & Test's failure is shown when the test ends: under the key field while the Account tab is on screen,
/// otherwise in the main window's alert, so a failed test of a new key is never lost (the saved key stays in use).
func slantKeyTestFailureShowsInSettings(tabShown: Bool, selectedTab: SettingsTab) -> Bool {
    tabShown && selectedTab == .account
}

/// Save & Test's failure under the Slant key field. Slant's 401 copy speaks of the saved key and says to reconnect in
/// Settings, but here the key Slant refused is the one just typed. A key that fails its test changes nothing
/// (`StudioStore.connect(key:)`), so when another key is saved, the text says that key is still in use, after a full
/// stop when Slant's own text ends without one.
func slantKeyTestFailureText(_ message: String, savedKeyKept: Bool) -> String {
    let base = message == unauthorizedUserMessage(body: "") ? slantKeyTestRejectedText : message
    guard savedKeyKept else { return base }
    let lead = slantSentenceEndingWithStop(base)
    return lead.isEmpty ? slantKeyTestSavedKeyKeptText : "\(lead) \(slantKeyTestSavedKeyKeptText)"
}
let slantKeyTestRejectedText = "Slant didn’t accept this key. Check it, then press Save & Test again."
let slantKeyTestSavedKeyKeptText = "Your saved key is unchanged and still in use."

/// `text` trimmed, with a full stop added unless it already ends in `.`, `!`, `?` or `…`, before any closing quotes or
/// brackets (“Invalid key.” stays as it is; “Invalid key” becomes “Invalid key”.).
func slantSentenceEndingWithStop(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let closers: Set<Character> = ["”", "’", "\"", "'", "»", ")", "]"]
    guard let last = trimmed.reversed().first(where: { !closers.contains($0) }) else { return trimmed }
    return ".!?…".contains(last) ? trimmed : trimmed + "."
}

/// The line under the Slant key field in Settings › Account (`slantKeyStatusLine`).
enum SlantKeyStatusLine: Equatable {
    /// “Testing the key…”: Save & Test is testing a key other than the saved one.
    case testing
    /// `slantKeyNotSavedYetText`: the field holds a key other than the saved one, and no test is running.
    case notSavedYet
    /// “Connection verified”.
    case verified
    /// `connectionFooterStatus` for a saved key that isn't connected.
    case connectionStatus
    /// “Not connected”.
    case notConnected
    /// No line: a Save & Test error is shown under a connected key, so a green “Connection verified” would contradict
    /// it (the error says whether the saved key is still in use).
    case hidden
}
let slantKeyNotSavedYetText = "Not saved yet: press Save & Test."

/// Which line shows under the Slant key field. A typed key other than the saved one says it isn't saved yet (Return
/// doesn't save it), or that it is being tested; “Connection verified” shows only while no Save & Test error is shown.
func slantKeyStatusLine(keyField: String, savedKey: String, testing: Bool, errorShown: Bool, connected: Bool) -> SlantKeyStatusLine {
    let typed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
    let saved = savedKey.trimmingCharacters(in: .whitespacesAndNewlines)
    let changes = typed != saved
    if testing && changes { return .testing }
    if changes && !typed.isEmpty { return .notSavedYet }
    if connected { return errorShown ? .hidden : .verified }
    return saved.isEmpty ? .notConnected : .connectionStatus
}

// MARK: - Advanced

/// The optional services behind Design an Accessory, Generate a Replica and Review for Printing: the Claude key, the 3D
/// generation service and its keys, and the one-time photo-sharing answers.
struct DesignToolsSettingsTab: View {
    var body: some View {
        Form {
            PrintPreparationSettingsSection() // PrintPreparationView.swift: the automatic print-ready copy
            AnthropicSettingsSection() // AnthropicSettingsView.swift
            ImageTo3DSettingsSection() // ImageTo3DSettingsView.swift: Meshy / Tripo keys
            ImageSharingConsentSettingsSection() // ImageSharingConsent.swift
        }
        .formStyle(.grouped)
        .frame(width: 620, height: settingsTabHeight)
    }
}

struct AdvancedSettingsTab: View {
    @EnvironmentObject var store: StudioStore
    @EnvironmentObject var modalPresentation: ModalPresentationMonitor
    @State private var manualPlatformID = ""

    private var developerToolsBlocked: String? {
        developerToolsToggleBlockedReason(busy: store.busy,
                                          modalUIShown: store.isPresentingSheet || modalPresentation.isPresenting)
    }

    var body: some View {
        Form {
            Section {
                if let rate = store.rateLimit {
                    if let remaining = rate.remaining, let limit = rate.limit {
                        LabeledContent("Rate limit") { Text("\(remaining) of \(limit) remaining") }
                    } else if let remaining = rate.remaining {
                        LabeledContent("Remaining") { Text("\(remaining)") }
                    }
                    if let reset = rate.reset {
                        LabeledContent("Resets") { Text(reset, style: .time) }
                    }
                    if let role = rate.role, !role.isEmpty {
                        LabeledContent("Role") { Text(role) }
                    }
                } else {
                    Text("Rate-limit details appear after the next request.").foregroundStyle(.secondary)
                }
                if let usage = store.usage {
                    ForEach(usageSummaryRows(usage, hiding: (store.rateLimit?.role ?? "").isEmpty ? [] : ["Role"]), id: \.0) { row in
                        LabeledContent(row.0) { Text(row.1) }
                    }
                }
                Button("Load Usage") { Task { await store.loadUsage() } }
                    .disabled(!store.hasKey || store.busy)
            } header: {
                Text("Usage")
            }

            Section {
                if let health = store.healthStatus {
                    Text(healthOverallLabel(health)).font(.callout)
                    ForEach(healthServiceRows(health), id: \.name) { row in
                        LabeledContent(healthServiceDisplayName(row.name)) { Text(row.status) }
                    }
                }
                Button("Check Service Status") { Task { await store.loadHealth() } }
                    .disabled(store.busy)
            } header: {
                Text("Service status")
            }

            SlantAPISettingsSection() // SlantAPIChanges.swift: the daily API description check and unrecognised statuses

            Section {
                LabeledContent("Platform ID") {
                    HStack(spacing: 8) {
                        Text(store.platformID.isEmpty ? "None chosen" : store.platformID)
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(store.platformID.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(store.platformID, forType: .string)
                        }
                        .disabled(store.platformID.isEmpty)
                    }
                }
                HStack {
                    TextField("Use platform ID", text: $manualPlatformID, prompt: Text("Paste an ID if platforms can’t be listed"))
                    Button("Use") {
                        store.platformID = manualPlatformID.trimmingCharacters(in: .whitespacesAndNewlines)
                        manualPlatformID = ""
                    }
                    .disabled(manualPlatformID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
                }
                TextField("Owner ID", text: $store.ownerID, prompt: Text("Optional"))
            } header: {
                Text("Identifiers")
            } footer: {
                Text("Choose the default platform in Account. Owner ID is optional and is sent with uploads and order drafts.")
                    .settingsFooterLayout()
            }

            OrderWatchSettingsSection() // OrderWatch.swift: order checks, notifications, Forget Saved Statuses

            Section {
                Toggle("Show developer tools", isOn: Binding(
                    get: { store.showDeveloperTools },
                    set: { new in
                        // The action-time check is authoritative; the disabled state can lag behind AppKit.
                        guard developerToolsToggleBlockedReason(busy: store.busy,
                                                                modalUIShown: store.isPresentingSheet || appIsPresentingModalUI()) == nil
                        else { return }
                        store.showDeveloperTools = new
                    }
                ))
                .disabled(developerToolsBlocked != nil)
                if let developerToolsBlocked {
                    Text(developerToolsBlocked).font(.caption).foregroundStyle(.secondary)
                }
            } header: {
                Text("Developer")
            } footer: {
                Text("Adds the API Workbench and Activity to the sidebar and Go menu. Activity is recorded either way, and every Workbench request goes to Slant’s production API.")
                    .settingsFooterLayout()
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: settingsTabHeight)
    }
}

// MARK: - Usage and service status

/// Usage rows for Settings › Advanced. `hiding` drops labels already shown above from the rate-limit headers
/// (such as Role), so nothing appears twice.
func usageSummaryRows(_ usage: [String: Any], hiding: Set<String> = []) -> [(String, String)] {
    let hidden = Set(hiding.map { $0.lowercased() })
    return usageSummaryAllRows(usage).filter { !hidden.contains($0.0.lowercased()) }
}
private func usageSummaryAllRows(_ usage: [String: Any]) -> [(String, String)] {
    var rows: [(String, String)] = []
    if let user = usage["user"] as? [String: Any] {
        rows.append(contentsOf: usageScalarRows(from: user))
    }
    if let summary = usage["summary"] as? [String: Any] {
        rows.append(contentsOf: usageScalarRows(from: summary))
    }
    if let keys = usage["apiKeys"] as? [Any] {
        rows.append(("API keys", "\(keys.count)"))
    }
    if rows.isEmpty {
        rows.append(contentsOf: usageScalarRows(from: usage))
    }
    return rows
}

func healthServiceRows(_ health: [String: Any]) -> [(name: String, status: String)] {
    var rows: [(name: String, status: String)] = []
    for (key, value) in health.sorted(by: { $0.key < $1.key }) {
        guard let service = value as? [String: Any] else { continue }
        let healthy: Bool
        if let flag = service["healthy"] as? Bool { healthy = flag }
        else if let number = service["healthy"] as? NSNumber { healthy = number.boolValue }
        else { continue }
        rows.append((key, healthy ? "Healthy" : "Unavailable"))
    }
    return rows
}

/// Slant's service keys ("ORDER-SERVICE") in sentence case for display ("Order service"); short capitalised words
/// such as API stay as they are. Slant's internal names say what the service does, from Slant's docs: KRAKEN is
/// "Print farm operations - job assignment, filament data, and fulfillment", TELEPORT the "Order intake portal used
/// alongside the API".
func healthServiceDisplayName(_ key: String) -> String {
    switch key.uppercased() {
    case "KRAKEN": return "Print farm (Kraken)"
    case "TELEPORT": return "Order intake (Teleport)"
    default: break
    }
    let words = key.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        .split(separator: " ").map { word -> String in
            word.count <= 3 && word == word.uppercased() && word.contains(where: \.isLetter) ? String(word) : word.lowercased()
        }
    guard let first = words.first else { return key }
    return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
}
func healthOverallLabel(_ health: [String: Any]) -> String {
    let rows = healthServiceRows(health)
    guard !rows.isEmpty else { return "No service data" }
    let bad = rows.filter { $0.status != "Healthy" }.count
    if bad == 0 { return "All services healthy" }
    return "\(bad) service\(bad == 1 ? "" : "s") having problems"
}
