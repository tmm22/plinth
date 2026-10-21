import SwiftUI
import AppKit

struct StudioView: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var openQueue = ExternalModelOpenQueue.shared
    var body: some View {
        NavigationSplitView {
            StudioSidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 216, max: 250)
        } detail: {
            Group {
                switch store.destination {
                case .models: ModelsView()
                case .orders: OrdersView()
                case .catalog, .materials, .components, .stationery, .platforms:
                    CatalogView(kind: store.catalogKind).id(store.catalogKind)
                case .api: APIWorkbenchView()
                case .activity: ActivityView()
                case .connection: ConnectionView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.studioCanvas)
            .navigationTitle(detailTitle)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if openQueue.isWaiting, let note = queuedImportNote(count: openQueue.pending.count) {
                        Label(note, systemImage: "tray.and.arrow.down")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help("Files opened from Finder import when the current sheet, alert or request finishes.")
                    }
                    if store.busy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small).accessibilityLabel("Working")
                            Text(store.progress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(maxWidth: 200, alignment: .trailing)
                                .help(store.progress)
                                .accessibilityLabel(store.progress)
                        }
                    }
                    Button { Task { await store.refreshCurrent() } } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help(store.connected ? "Refresh" : "Connect your account to refresh")
                    .disabled(store.busy || !store.connected)
                }
            }
        }
        .alert("Unable to complete request", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.dismissError() } })) {
            if store.canRetry {
                Button("Try again") { Task { await store.retryLast() } }.keyboardShortcut(.defaultAction)
            }
            Button("OK", role: .cancel) { store.dismissError() }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: $store.showOrderComposer) { OrderComposerView().environmentObject(store) }
        .sheet(isPresented: $store.showPlatformComposer) { PlatformComposerView().environmentObject(store) }
        .sheet(isPresented: $store.showImportFromURL) { ImportFromURLSheet().environmentObject(store) }
        .task(id: store.hasKey) {
            if store.hasKey, !store.accountLoaded { await store.refresh() }
        }
    }

    var detailTitle: String {
        store.destination == .catalog ? "Catalog" : store.destination.rawValue
    }
}

struct StudioSidebar: View {
    @EnvironmentObject var store: StudioStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 20)
            VStack(alignment: .leading, spacing: 2) {
                // ⌘-number shortcuts live in the Go menu so they are discoverable and defined once.
                ForEach(sidebarPrimaryDestinations) { navRow($0) }
            }
            .padding(.horizontal, 10)
            Spacer(minLength: 16)
            Text("DEVELOPER")
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 20)
                .padding(.bottom, 6)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(sidebarDeveloperDestinations) { navRow($0) }
            }
            .padding(.horizontal, 10)
            Divider().overlay(Color.white.opacity(0.08)).padding(.top, 12)
            connectionStatus
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.studioSidebar.ignoresSafeArea())
        .environment(\.colorScheme, .dark)
    }

    private var brand: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 7)
                .fill(Color.studioAccent)
                .frame(width: 28, height: 28)
                .overlay(Text("S").font(.system(size: 16, weight: .heavy, design: .rounded)).foregroundStyle(.black))
            VStack(alignment: .leading, spacing: 0) {
                Text("Slant 3D").font(.system(size: 14, weight: .bold))
                Text("Studio").font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func navRow(_ item: Destination) -> some View {
        let selected = store.destination == item
        return Button { store.destination = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? Color.studioAccent : .white.opacity(0.65))
                Text(item.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .white : .white.opacity(0.75))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? Color.white.opacity(0.09) : .clear)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(Color.studioAccent).frame(width: 3, height: 16).offset(x: -6)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(goMenuShortcut(for: item).map { "\(item.rawValue) (⌘\($0))" } ?? item.rawValue)
        .accessibilityLabel(item.rawValue)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var connectionStatus: some View {
        let status = connectionFooterStatus(
            hasKey: store.hasKey,
            connected: store.connected,
            accountLoaded: store.accountLoaded,
            busy: store.busy
        )
        Button { store.destination = .connection } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(store.connected ? Color.green : (store.hasKey ? Color.orange : Color.white.opacity(0.35)))
                    .frame(width: 7, height: 7)
                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open Connection")
        .accessibilityLabel("\(status). Open Connection")
    }
}

let sidebarPrimaryDestinations: [Destination] = [.models, .orders, .catalog, .connection]
let sidebarDeveloperDestinations: [Destination] = [.api, .activity]

struct EmptyState<Actions: View>: View {
    let icon: String
    let title: String
    let detail: String
    @ViewBuilder let actions: () -> Actions

    init(icon: String, title: String, detail: String) where Actions == EmptyView {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.actions = { EmptyView() }
    }

    init(icon: String, title: String, detail: String, @ViewBuilder actions: @escaping () -> Actions) {
        self.icon = icon
        self.title = title
        self.detail = detail
        self.actions = actions
    }

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
        } description: {
            Text(detail)
        } actions: {
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(36)
    }
}

struct JSONView: View {
    let text: String
    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            Text(text)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
        }
        .background(.black.opacity(0.025), in: RoundedRectangle(cornerRadius: 8))
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
    case saveTest, createPlatform, continueModels, none
}

func connectionProminentAction(connected: Bool, savedKey: String, keyField: String, platformID: String) -> ConnectionProminentAction {
    let trimmedField = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
    let keyDiffers = trimmedField != savedKey
    if !connected || keyDiffers { return .saveTest }
    if platformID.isEmpty { return .createPlatform }
    return .continueModels
}

struct ConnectionView: View {
    @EnvironmentObject var store: StudioStore
    var presentsPlatformComposer = false
    @State private var key = ""
    @State private var confirmDisconnect = false
    @State private var showPlatformComposerLocal = false

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
                SecureField("sl-…", text: $key)
                Button("Save & Test") { Task { await store.connect(key: key) } }
                    .modifier(ProminentWhen(prominent == .saveTest))
                    .disabled(key.isEmpty || store.busy)
                Link("Get an API key", destination: URL(string: "https://slant3dapi.com")!)
                if store.hasKey {
                    Button("Disconnect", role: .destructive) { confirmDisconnect = true }
                        .disabled(store.busy)
                }
                if store.connected {
                    Label("Connection verified", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                } else if store.hasKey {
                    Label(connectionFooterStatus(hasKey: true, connected: false, accountLoaded: store.accountLoaded, busy: store.busy), systemImage: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected").foregroundStyle(.secondary)
                }
            } header: {
                Text("API key")
            } footer: {
                Text("Stored in the macOS Keychain on this Mac.")
            }

            Section {
                if !store.platforms.isEmpty || !store.platformID.isEmpty {
                    Picker("Platform", selection: $store.platformID) {
                        Text("Choose a platform").tag("")
                        if !store.platformID.isEmpty, !store.platforms.contains(where: { $0.id == store.platformID }) {
                            Text("Saved platform (not loaded)").tag(store.platformID)
                        }
                        ForEach(indexedRecords(store.platforms), id: \.id) { row in
                            Text(displayName(for: row.record, fallback: "Untitled platform")).tag(row.record.id)
                        }
                    }
                } else if store.connected {
                    Text("Choose or create a platform next. Uploads and orders need one.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(store.loadedCatalogs.contains(.platforms) ? "No platforms on this account yet." : "No platforms yet. Load them, or create one.")
                        .foregroundStyle(.secondary)
                }
                Button("Create Platform…") {
                    if presentsPlatformComposer { showPlatformComposerLocal = true }
                    else { store.showPlatformComposer = true }
                }
                .modifier(ProminentWhen(prominent == .createPlatform))
                .disabled(!store.hasKey || store.busy || store.platformLimitReached)
                if !store.loadedCatalogs.contains(.platforms) {
                    Button("Load Platforms…") { Task { await store.loadCatalog(.platforms) } }
                        .disabled(!store.hasKey || store.busy)
                }
                if store.platformLimitReached {
                    Text("This account already has \(maxPlatforms) enabled platforms. Disable one before creating another.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if store.connected, !store.platformID.isEmpty {
                    Button("Continue to Models") { store.destination = .models }
                        .modifier(ProminentWhen(prominent == .continueModels))
                }
            } header: {
                Text("Default platform")
            }

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
                    Text("Rate-limit headers appear after the next request.").foregroundStyle(.secondary)
                }
                if let usage = store.usage {
                    ForEach(usageSummaryRows(usage), id: \.0) { row in
                        LabeledContent(row.0) { Text(row.1) }
                    }
                }
                Button("Load Usage") { Task { await store.loadUsage() } }
                    .disabled(!store.hasKey || store.busy)
                if let health = store.healthStatus {
                    Text(healthOverallLabel(health)).font(.callout)
                    ForEach(healthServiceRows(health), id: \.name) { row in
                        LabeledContent(row.name) { Text(row.status) }
                    }
                }
                Button("Check Service Status") { Task { await store.loadHealth() } }
                    .disabled(store.busy)
            } header: {
                Text("Usage")
            }

            Section {
                TextField("Platform ID", text: $store.platformID)
                TextField("Owner ID (optional)", text: $store.ownerID)
                Text("Customer accounts and checkout aren’t available in the Slant API yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Advanced identifiers")
            }

            Section {
                Text("Billing is managed on the Slant website.")
                    .foregroundStyle(.secondary)
                Link("Slant documentation", destination: URL(string: "https://slant3dapi.com/documentation/introduction")!)
            }
        }
        .formStyle(.grouped)
        .onAppear { key = store.apiKey }
        .sheet(isPresented: $showPlatformComposerLocal) {
            PlatformComposerView().environmentObject(store)
        }
        .confirmationDialog("Disconnect this Mac?", isPresented: $confirmDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { store.disconnect(); key = "" }
                .disabled(store.busy)
            Button("Keep connected", role: .cancel) {}
        } message: {
            Text("This removes the saved API key from the Keychain on this Mac.")
        }
    }
}

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

struct PlatformComposerView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    private let editing: Record?
    @State private var draft: PlatformDraft
    @State private var validation: String?

    /// Create mode when `editing` is nil; update mode when a platform record is supplied.
    init(editing: Record? = nil) {
        self.editing = editing
        _draft = State(initialValue: editing.map { PlatformDraft(platform: $0) } ?? PlatformDraft())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(editing == nil ? "Create a platform" : "Edit platform").font(.title2.weight(.bold))
                Text("A platform groups your uploads and orders.").foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("My print shop"))
                    TextField("Application address", text: $draft.url, prompt: Text("https://yourstore.com"))
                    TextField("Description", text: $draft.description, prompt: Text("Optional"))
                }
                Section {
                    DisclosureGroup("Advanced") {
                        VStack(alignment: .leading, spacing: 10) {
                            TextField("Webhook URL", text: $draft.webhookURL, prompt: Text("Optional · https://example.com/webhooks/slant"))
                            if editing != nil {
                                Text("Leave the webhook URL blank to remove it from this platform.")
                                    .font(.caption).foregroundStyle(.secondary)
                                SecureField("Webhook secret (optional)", text: $draft.webhookSecret)
                                Text("32–256 printable ASCII characters. Leave blank to keep the current secret.")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("Slant sends order status updates to this address. Leave it blank if you don’t run your own server. A signing secret is generated when the platform is created.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.top, 6)
                    }
                }
                if let validation {
                    Label(validation, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }.formStyle(.grouped)
            Divider()
            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                    .help(store.busy ? "Working…" : "Cancel")
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button(editing == nil ? "Create platform" : "Save changes") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.busy || !store.hasKey)
            }.padding(20)
        }.frame(width: 560, height: 520)
    }

    func submit() {
        do { _ = try draft.payload(); validation = nil } catch { validation = error.localizedDescription; return }
        Task {
            if let editing {
                if await store.updatePlatform(id: editing.id, draft: draft) { dismiss() }
            } else {
                if await store.createPlatform(draft) { dismiss() }
            }
        }
    }
}

struct ActivityView: View {
    @EnvironmentObject var store: StudioStore
    @State private var search = ""
    var filtered: [Activity] {
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return store.activities }
        return store.activities.filter {
            $0.title.localizedCaseInsensitiveContains(trimmed) || $0.detail.localizedCaseInsensitiveContains(trimmed)
        }
    }
    var body: some View {
        Group {
            if store.activities.isEmpty {
                EmptyState(icon: "waveform.path", title: "A fresh session", detail: "Your requests will appear here. Credentials and request bodies are never written to the activity history.")
            } else if filtered.isEmpty {
                EmptyState(icon: "magnifyingglass", title: "No matches", detail: "Nothing in Activity matches “\(search)”.")
            } else {
                List(filtered) { event in
                    HStack(alignment: .top, spacing: 14) {
                        Image(systemName: event.success ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                            .foregroundStyle(event.success ? .green : .orange)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(event.title).font(.headline)
                            Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                        }
                        Spacer()
                        Text(event.date, style: .time).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 8)
                }
            }
        }
        .searchable(text: $search, prompt: "Search activity")
    }
}
