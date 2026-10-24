import SwiftUI
import AppKit

struct StudioView: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var openQueue = ExternalModelOpenQueue.shared
    @Environment(\.openSettings) private var openSettings
    var body: some View {
        NavigationSplitView {
            StudioSidebar()
        } detail: {
            Group {
                if showsConnectAccountPrompt(destination: store.destination, hasKey: store.hasKey,
                                             hasLocalModels: !store.localModels.isEmpty) {
                    ConnectAccountPrompt()
                } else {
                    switch store.destination {
                    case .models: ModelsView()
                    case .orders: OrdersView()
                    // `.platforms` never stays selected (it opens Settings); Catalog shows its saved kind.
                    case .catalog, .materials, .components, .stationery, .platforms:
                        CatalogView(kind: store.catalogKind).id(store.catalogKind)
                    case .api: APIWorkbenchView()
                    case .activity: ActivityView()
                    }
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
                Button("Try Again") { Task { await store.retryLast() } }.keyboardShortcut(.defaultAction)
            }
            Button("OK", role: .cancel) { store.dismissError() }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: $store.showOrderComposer) { OrderComposerView().environmentObject(store) }
        .sheet(isPresented: $store.showPlatformComposer) { PlatformComposerView().environmentObject(store) }
        .sheet(isPresented: $store.showImportFromURL) { ImportFromURLSheet().environmentObject(store) }
        .sheet(isPresented: $store.showSavedProducts) { SavedProductsSheet().environmentObject(store) }
        .sheet(isPresented: $store.showOrderImport) { OrderImportSheet().environmentObject(store) }
        .sheet(isPresented: $store.showShopFollowUp) { ShopFollowUpSheet().environmentObject(store) }
        // Listing images and the spending report: local only, nothing is sent to Slant.
        .sheet(isPresented: Binding(get: { store.listingImagesModelID != nil }, set: { if !$0 { store.listingImagesModelID = nil } })) {
            if let id = store.listingImagesModelID { ListingImagesSheet(modelID: id).environmentObject(store) }
        }
        .sheet(isPresented: $store.showSpendingReport) { SpendingReportSheet().environmentObject(store) }
        .sheet(isPresented: Binding(get: { store.personalisationTemplate != nil },
                                    set: { if !$0 { store.personalisationTemplate = nil } })) {
            PersonalisationSheet().environmentObject(store)
        }
        .sheet(item: $store.meshFitRequest) { MeshFitSheet(request: $0).environmentObject(store) }
        .sheet(item: $store.printReviewRequest) { PrintReviewSheet(request: $0).environmentObject(store) }
        .task(id: store.hasKey) {
            if store.hasKey, !store.accountLoaded { await store.refresh() }
        }
        // Background order checks (OrderWatch.swift): read-only, never through `store.run`.
        .onAppear { OrderWatch.shared.attach(store) }
        // Restored at launch by `StudioStore.destination`'s initial value.
        .onChange(of: store.destination) { _, new in
            if sidebarDestinations(showDeveloperTools: true).contains(new) {
                UserDefaults.standard.set(new.rawValue, forKey: lastSidebarDestinationDefaultsKey)
            }
        }
        // Store-driven "open Settings" requests (Connect Account buttons, the platforms redirect). Opening Settings
        // only brings its window forward; nothing in this window changes.
        .onChange(of: store.settingsOpenRequest) { _, _ in openSettings() }
    }

    var detailTitle: String {
        store.destination == .catalog ? "Catalog" : store.destination.rawValue
    }
}

/// Shown instead of a screen that can't work without an API key, so first launch (or a Keychain read failure) always
/// leads to entering a key. Models still opens once the library has models, since the library works offline.
func showsConnectAccountPrompt(destination: Destination, hasKey: Bool, hasLocalModels: Bool) -> Bool {
    guard !hasKey else { return false }
    switch destination {
    case .models: return !hasLocalModels
    case .orders, .catalog, .materials, .components, .stationery, .platforms: return true
    case .api, .activity: return false
    }
}

struct ConnectAccountPrompt: View {
    @EnvironmentObject var store: StudioStore
    @State private var dropTargeted = false

    var body: some View {
        if store.destination == .models {
            // Imports work without an account, so model files dropped here import exactly as they do on Models.
            prompt
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .overlay {
                    if dropTargeted {
                        RoundedRectangle(cornerRadius: 12).stroke(Color.studioAccent, lineWidth: 3).padding(8)
                    }
                }
                .dropDestination(for: URL.self) { urls, _ in
                    urls.forEach { store.importModel($0) }
                    return !urls.isEmpty
                } isTargeted: { dropTargeted = $0 }
        } else {
            prompt
        }
    }

    private var prompt: some View {
        EmptyState(
            icon: "person.crop.circle.badge.plus",
            title: "Connect your Slant account",
            detail: "Add your Slant 3D API key in Settings to upload models, get estimates and create orders. The key is stored in the macOS Keychain on this Mac."
        ) {
            VStack(spacing: 10) {
                Button("Connect Slant Account…") { store.requestSettings(.account) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                if store.destination == .models {
                    Button("Import Model…") { store.importModel() }
                        .help("Models you import stay on this Mac until you upload them.")
                }
            }
        }
    }
}

let sidebarPrimaryDestinations: [Destination] = [.models, .orders, .catalog]
let sidebarDeveloperDestinations: [Destination] = [.api, .activity]

/// Every destination the sidebar lists, in order. Developer destinations only when developer tools are on.
func sidebarDestinations(showDeveloperTools: Bool) -> [Destination] {
    sidebarPrimaryDestinations + (showDeveloperTools ? sidebarDeveloperDestinations : [])
}

/// The sidebar section the main window last showed, restored at launch.
let lastSidebarDestinationDefaultsKey = "lastSidebarDestination"

/// Where the main window opens: the last sidebar section if the sidebar still lists it (a developer section only while
/// developer tools are on), otherwise Models.
func restoredSidebarDestination(saved: String?, showDeveloperTools: Bool) -> Destination {
    guard let saved, let destination = Destination(rawValue: saved),
          sidebarDestinations(showDeveloperTools: showDeveloperTools).contains(destination) else { return .models }
    return destination
}

/// A standard source-list sidebar: system selection, arrow-key navigation, translucency and sizing. The brand shows
/// through the app accent colour and the row icons.
struct StudioSidebar: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var orderWatch = OrderWatch.shared

    private var selection: Binding<Destination?> {
        Binding(
            get: { store.destination },
            set: { if let new = $0 { store.destination = new } }
        )
    }

    var body: some View {
        List(selection: selection) {
            // ⌘-number shortcuts live in the Go menu so they are discoverable and defined once.
            Section {
                ForEach(sidebarPrimaryDestinations) { row($0) }
            }
            if store.showDeveloperTools {
                Section("Developer") {
                    ForEach(sidebarDeveloperDestinations) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            ConnectionStatusFooter()
        }
    }

    private func row(_ item: Destination) -> some View {
        Label(item.rawValue, systemImage: item.icon)
            // Unseen order changes that need attention or reached the customer (OrderWatch.swift); 0 shows nothing.
            .badge(item == .orders ? orderWatch.badgeCount : 0)
            .tag(item)
            .help(goMenuShortcut(for: item).map { "\(item.rawValue) (⌘\($0))" } ?? item.rawValue)
    }
}

/// Compact account status under the sidebar. It opens Settings › Account; first-run connection is also offered in the
/// main window, so this is never the only way in.
struct ConnectionStatusFooter: View {
    @EnvironmentObject var store: StudioStore

    var body: some View {
        let status = connectionFooterStatus(
            hasKey: store.hasKey,
            connected: store.connected,
            accountLoaded: store.accountLoaded,
            busy: store.busy
        )
        Button { store.requestSettings(.account) } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(store.connected ? Color.green : (store.hasKey ? Color.orange : Color.secondary.opacity(0.6)))
                    .frame(width: 7, height: 7)
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .help("Open Settings to manage your Slant account")
        .accessibilityLabel("\(status). Open Settings")
    }
}

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
