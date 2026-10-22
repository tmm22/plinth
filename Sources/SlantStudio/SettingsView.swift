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

// MARK: - Account

struct AccountSettingsTab: View {
    @EnvironmentObject var store: StudioStore
    @State private var key = ""
    @State private var confirmDisconnect = false
    @State private var connectError: String?
    @State private var platforms = PlatformsSettingsState()

    private var prominent: ConnectionProminentAction {
        connectionProminentAction(
            connected: store.connected,
            savedKey: store.apiKey,
            keyField: key,
            platformID: store.platformID
        )
    }

    var body: some View {
        Form {
            Section {
                SecureField("API key", text: $key, prompt: Text("sl-…"))
                HStack {
                    Button("Save & Test") { saveAndTest() }
                        .modifier(ProminentWhen(prominent == .saveTest))
                        .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.busy)
                    if store.hasKey {
                        Button("Disconnect…", role: .destructive) { confirmDisconnect = true }
                            .disabled(store.busy)
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
                if let connectError {
                    Label(connectError, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } header: {
                Text("Slant account")
            } footer: {
                Text("The key is stored in the macOS Keychain on this Mac.")
            }

            PlatformsSettingsSections(state: $platforms, createProminent: prominent == .createPlatform)
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 640)
        .onAppear { key = store.apiKey }
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
        Task {
            await store.connect(key: key)
            // The main window also shows the error, but it may be behind this window.
            if !store.connected { connectError = store.error }
        }
    }
}

// MARK: - Advanced

struct AdvancedSettingsTab: View {
    @EnvironmentObject var store: StudioStore
    @EnvironmentObject var modalPresentation: ModalPresentationMonitor

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
                TextField("Owner ID", text: $store.ownerID, prompt: Text("Optional"))
                Text("Choose the default platform in Account. Customer accounts and checkout aren’t available in the Slant API yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Advanced identifiers")
            }

            Section {
                Text("Billing is managed on the Slant website.")
                    .foregroundStyle(.secondary)
                Link("Slant Documentation", destination: URL(string: "https://slant3dapi.com/documentation/introduction")!)
            } header: {
                Text("Billing")
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
            }
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 600)
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
