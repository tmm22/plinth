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
            Section {
                SecureField("API key", text: $key, prompt: Text("sl-…"))
                    .focused($keyFieldFocused)
                    .onSubmit { saveAndTest() }
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
                if store.connected {
                    Label("Connection verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if store.hasKey {
                    Label(connectionFooterStatus(hasKey: true, connected: false, accountLoaded: store.accountLoaded, busy: store.busy),
                          systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
                if store.hasKey || keyChanges, let keyChangeBlocked, !store.busy {
                    Text(keyChangeBlocked).font(.caption).foregroundStyle(.secondary)
                }
                if let connectError {
                    Label(connectError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Slant account")
            } footer: {
                Text("The key is stored in the macOS Keychain on this Mac. Billing is managed on the Slant website.")
                    .settingsFooterLayout()
            }

            PlatformsSettingsSections(state: $platforms, createProminent: prominent == .createPlatform)
        }
        .formStyle(.grouped)
        .frame(width: 620, height: settingsTabHeight)
        .onAppear { key = store.apiKey }
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
            Button("Keep Connected", role: .cancel) {}
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
        Task {
            await store.connect(key: key)
            // Show the failure here; the main window's alert would sit unseen behind this window.
            if !store.connected { connectError = takeStoreErrorForSettings(store) ?? connectError }
        }
    }
}

// MARK: - Advanced

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
                    ForEach(usageSummaryRows(usage), id: \.0) { row in
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
                        LabeledContent(row.name) { Text(row.status) }
                    }
                }
                Button("Check Service Status") { Task { await store.loadHealth() } }
                    .disabled(store.busy)
            } header: {
                Text("Service status")
            }

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
                Text("Advanced identifiers")
            } footer: {
                Text("Choose the default platform in Account. Owner ID is optional and is sent with uploads and order drafts.")
                    .settingsFooterLayout()
            }

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

func usageSummaryRows(_ usage: [String: Any]) -> [(String, String)] {
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

func healthOverallLabel(_ health: [String: Any]) -> String {
    let rows = healthServiceRows(health)
    guard !rows.isEmpty else { return "No service data" }
    let bad = rows.filter { $0.status != "Healthy" }.count
    if bad == 0 { return "All services healthy" }
    return "\(bad) service\(bad == 1 ? "" : "s") having problems"
}
