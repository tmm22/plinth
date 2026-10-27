import SwiftUI
import AppKit

// MARK: - Platforms in Settings › Account

/// Why Create Platform… is unavailable, or nil. Only one window shows the composer at a time, so the Settings button
/// waits while the main window's composer is open (and the main window's request defers to an open Settings one).
func createPlatformBlockedReason(hasKey: Bool, busy: Bool, limitReached: Bool, otherComposerOpen: Bool) -> String? {
    if !hasKey { return "Connect your account first." }
    if limitReached { return "This account already has \(maxPlatforms) enabled platforms. Disable one before creating another." }
    if otherComposerOpen { return "Finish creating the platform in the main window first." }
    if busy { return "Working…" }
    return nil
}

/// Takes the store's current error for showing inside Settings, and clears it so the main window's alert — usually
/// behind the Settings window — doesn't keep an unseen alert open (which would also block menus and settings).
@MainActor func takeStoreErrorForSettings(_ store: StudioStore) -> String? {
    guard let message = store.error else { return nil }
    store.dismissError()
    return message
}

/// Sheet state for the platform sections, owned by the Account tab so its sheets attach to the Form rather than to a
/// (lazily created) row.
struct PlatformsSettingsState {
    var selected: Record?
    var pendingEdit: Record?
    var editing: Record?
    var enableByID = ""
    var enableCandidate: Record?
    var confirmEnable = false
    /// The last failed platform action in the Account tab, shown inline.
    var error: String?
    var showEnableByID = false
}

/// The default-platform picker, the platform list (each row opens its details and management) and re-enabling.
struct PlatformsSettingsSections: View {
    @EnvironmentObject var store: StudioStore
    @Binding var state: PlatformsSettingsState
    var createProminent = false

    private var platformsLoaded: Bool { store.loadedCatalogs.contains(.platforms) }
    private var createBlocked: String? {
        createPlatformBlockedReason(hasKey: store.hasKey, busy: store.busy, limitReached: store.platformLimitReached,
                                    otherComposerOpen: store.showPlatformComposer)
    }

    var body: some View {
        Section {
            if !store.platforms.isEmpty || !store.platformID.isEmpty {
                Picker("Default platform", selection: $store.platformID) {
                    Text("Choose a platform").tag("")
                    if !store.platformID.isEmpty, !store.platforms.contains(where: { $0.id == store.platformID }) {
                        Text("Saved platform (not loaded)").tag(store.platformID)
                    }
                    ForEach(indexedRecords(store.platforms), id: \.id) { row in
                        Text(displayName(for: row.record, fallback: "Untitled platform")).tag(row.record.id)
                    }
                }
            } else if store.connected {
                Text("Create a platform next. Uploads and orders need one.")
                    .foregroundStyle(.secondary)
            } else {
                Text(platformsLoaded ? "No platforms on this account yet." : "Connect your account, then load or create a platform.")
                    .foregroundStyle(.secondary)
            }

            ForEach(indexedRecords(store.platforms), id: \.id) { row in
                platformRow(row.record)
            }

            HStack {
                Button("Create Platform…") { store.showSettingsPlatformComposer = true }
                    .modifier(ProminentCreate(isProminent: createProminent))
                    .disabled(createBlocked != nil)
                    .help(createBlocked ?? "Create a platform")
                Button(platformsLoaded ? "Reload Platforms" : "Load Platforms") {
                    Task {
                        state.error = nil
                        await store.loadCatalog(.platforms)
                        state.error = takeStoreErrorForSettings(store)
                    }
                }
                .disabled(!store.hasKey || store.busy)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if store.platformLimitReached {
                Text("This account already has \(maxPlatforms) enabled platforms. Disable one before creating another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Platforms")
        } footer: {
            Text("A platform groups your uploads and orders. New uploads and order drafts use the default platform.")
                .settingsFooterLayout()
        }

        if store.hasKey {
            Section {
                ForEach(indexedRecords(store.disabledPlatformsThisSession), id: \.id) { row in
                    HStack {
                        Text(displayName(for: row.record, fallback: "Untitled platform"))
                        Spacer()
                        Button("Enable") {
                            Task {
                                state.error = nil
                                if !(await store.setPlatformEnabled(id: row.record.id, enabled: true)) {
                                    state.error = takeStoreErrorForSettings(store)
                                }
                            }
                        }
                        .disabled(store.busy)
                    }
                }
                DisclosureGroup("Enable a platform by ID", isExpanded: $state.showEnableByID) {
                    HStack {
                        TextField("Platform ID", text: $state.enableByID, prompt: Text("ID of a disabled platform"))
                        Button("Look Up…") {
                            Task {
                                state.error = nil
                                state.enableCandidate = await store.loadPlatform(id: state.enableByID)
                                if state.enableCandidate != nil { state.confirmEnable = true }
                                else { state.error = takeStoreErrorForSettings(store) ?? "No platform found with that ID." }
                            }
                        }
                        .disabled(store.busy || state.enableByID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            } header: {
                Text("Disabled platforms")
            } footer: {
                Text(store.disabledPlatformsThisSession.isEmpty
                     ? "Disabled platforms don’t appear above. To enable one, look it up by its ID."
                     : "Platforms you disable this session are listed here. To enable another, look it up by its ID.")
                    .settingsFooterLayout()
            }
        }
    }

    private func platformRow(_ record: Record) -> some View {
        HStack(spacing: 10) {
            Image(systemName: Destination.platforms.icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName(for: record, fallback: "Untitled platform"))
                let subtitle = record.string("url", "description")
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
            if record.id == store.platformID {
                StudioBadge(text: "Default", tone: .accent)
            }
            Button("Details…") { state.selected = record }
                .accessibilityLabel("Details for \(displayName(for: record, fallback: "Untitled platform"))")
        }
    }
}

private struct ProminentCreate: ViewModifier {
    let isProminent: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if isProminent { content.buttonStyle(.borderedProminent) } else { content }
    }
}

/// The platform sheets of Settings › Account: details and management, edit, create and enable-by-ID.
struct PlatformsSettingsSheets: ViewModifier {
    @EnvironmentObject var store: StudioStore
    @Binding var state: PlatformsSettingsState

    func body(content: Content) -> some View {
        content
            .sheet(item: $state.selected, onDismiss: presentPendingEdit) { record in
                PlatformDetailSheet(record: record) { platform in state.pendingEdit = platform }
                    .environmentObject(store)
            }
            .sheet(item: $state.editing) { platform in
                PlatformComposerView(editing: platform).environmentObject(store)
            }
            .sheet(isPresented: $store.showSettingsPlatformComposer) {
                PlatformComposerView().environmentObject(store)
            }
            .sheet(isPresented: $state.confirmEnable) {
                enableCandidateSheet
            }
    }

    private func presentPendingEdit() {
        guard let platform = state.pendingEdit else { return }
        state.pendingEdit = nil
        state.editing = platform
    }

    private var enableCandidateSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Enable platform").font(.title3.weight(.semibold))
            if let candidate = state.enableCandidate {
                Text(displayName(for: candidate, fallback: "Untitled platform")).font(.headline)
                Text(candidate.id).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Cancel") { state.confirmEnable = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                Button("Enable") {
                    Task {
                        state.error = nil
                        if let id = state.enableCandidate?.id, !(await store.setPlatformEnabled(id: id, enabled: true)) {
                            state.error = takeStoreErrorForSettings(store)
                        }
                        state.confirmEnable = false
                        state.enableByID = ""
                        state.enableCandidate = nil
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy || state.enableCandidate == nil)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

// MARK: - Platform details and management

/// The details sheet offers Use as Default only for a platform that isn't already the default.
func platformDetailOffersUseAsDefault(platformID: String, defaultPlatformID: String) -> Bool {
    platformID != defaultPlatformID
}

struct PlatformDetailSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    let record: Record
    /// Called before dismissing for Edit…; the parent presents the editor once this sheet has closed.
    var onEdit: (Record) -> Void

    @State private var confirmDisable = false
    @State private var confirmResendAll = false
    @State private var showSecret = false
    @State private var rotatePrompt = false
    @State private var rotateTyped = ""
    @State private var rotatedSecret: String?
    @State private var deadLoaded = false
    @State private var testWebhookResult: WebhookTestResult?
    @State private var resendResult: WebhookResendResult?
    /// The last failed action in this sheet or its confirmations, shown inline (the main window's alert is hidden).
    @State private var actionError: String?

    private var livePlatform: Record {
        store.platforms.first { $0.id == record.id } ?? record
    }
    private var currentSecret: String {
        livePlatform.string("webhookSecret", "secret")
    }
    private var displayedSecret: String {
        displayedWebhookSecret(rotatedSecret: rotatedSecret, currentSecret: currentSecret)
    }
    private var platformDeadWebhooks: [Record] {
        store.deadWebhooks[record.id] ?? []
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView { details }
            Divider()
            footer
        }
        .frame(width: 600, height: 620)
        .sheet(isPresented: $confirmDisable) { disableConfirmSheet }
        .sheet(isPresented: $confirmResendAll) { resendAllConfirmSheet }
        .sheet(isPresented: $rotatePrompt) { rotateSecretSheet }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text(displayName(for: livePlatform, fallback: "Untitled platform")).font(.title2.weight(.bold))
                if record.id == store.platformID {
                    StudioBadge(text: "Default", tone: .accent)
                }
                Spacer()
            }
            platformReadableFields(livePlatform)
            actionErrorLabel
            platformManagement
            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 12) {
                    Button("Copy ID") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(record.id, forType: .string)
                    }
                    .accessibilityLabel("Copy ID")
                    JSONView(text: prettyJSON(hidingSecrets(livePlatform.values))).frame(height: 220)
                }
            }.studioDisclosureStyle()
        }
        .padding(28)
    }

    /// The management actions act (after their own confirmations) as they are pressed, so closing abandons nothing.
    private var footer: some View {
        HStack {
            Spacer()
            Button("Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            // Already the default: the header's Default badge says so. A local preference; nothing is sent.
            if platformDetailOffersUseAsDefault(platformID: record.id, defaultPlatformID: store.platformID) {
                Button("Use as Default") {
                    store.platformID = record.id
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(store.busy)
            }
        }
        .padding(20)
    }

    @ViewBuilder
    private var actionErrorLabel: some View {
        if let actionError {
            Label(actionError, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
        }
    }

    /// Runs a platform request from this sheet, keeping any failure visible here.
    private func perform<T>(_ operation: () async -> T?) async -> T? {
        actionError = nil
        let result = await operation()
        if result == nil { actionError = takeStoreErrorForSettings(store) }
        return result
    }

    @ViewBuilder
    private var platformManagement: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Edit…") {
                    onEdit(livePlatform)
                    dismiss()
                }
                .disabled(store.busy)
                Button("Disable…") { confirmDisable = true }
                    .tint(.red)
                    .disabled(store.busy)
                if !livePlatform.string("webhookURL", "webhookUrl").isEmpty {
                    Button("Send Test Webhook") {
                        Task {
                            testWebhookResult = await perform { await store.sendTestWebhook(platformID: record.id) }
                        }
                    }
                    .disabled(store.busy)
                }
            }
            if let testWebhookResult {
                Text(webhookTestResultMessage(testWebhookResult))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            webhookSecretSection
            DisclosureGroup("How to verify webhooks") {
                Text(webhookVerificationRecipe)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.studioDisclosureStyle()
            deadWebhooksSection
        }
    }

    private var webhookSecretSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Webhook secret").font(.headline)
            if displayedSecret.isEmpty {
                Text("Hidden · rotate to mint a new secret.").font(.caption).foregroundStyle(.secondary)
            } else if showSecret {
                Text(displayedSecret).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else {
                Text("••••••••••••").foregroundStyle(.secondary)
            }
            HStack {
                if !displayedSecret.isEmpty {
                    Button(showSecret ? "Hide" : "Show") { showSecret.toggle() }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(displayedSecret, forType: .string)
                    }
                }
                Button("Rotate…") {
                    rotateTyped = ""
                    rotatePrompt = true
                }
                .disabled(store.busy)
            }
            if rotatedSecret != nil {
                Text("Update your webhook receiver with the new secret now. The old one stops working.")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var deadWebhooksSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Failed deliveries").font(.headline)
                Spacer()
                Button(deadLoaded || store.deadWebhooks[record.id] != nil ? "Reload" : "Load") {
                    Task {
                        if await perform({ await store.loadDeadWebhooks(platformID: record.id) }) != nil { deadLoaded = true }
                    }
                }
                .disabled(store.busy)
                if deadLoaded || store.deadWebhooks[record.id] != nil, !platformDeadWebhooks.isEmpty {
                    Button("Resend All…") { confirmResendAll = true }
                        .disabled(store.busy)
                }
            }
            if let resendResult {
                Text(webhookResendResultMessage(resendResult))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if resendResult.remaining > 0 {
                    Button("Resend Remaining (\(resendResult.remaining))") {
                        Task {
                            if let result = await perform({ await store.resendDeadWebhooks(platformID: record.id) }) {
                                self.resendResult = result
                                _ = await store.loadDeadWebhooks(platformID: record.id)
                                deadLoaded = true
                            }
                        }
                    }
                    .disabled(store.busy)
                }
            }
            if deadLoaded || store.deadWebhooks[record.id] != nil {
                if platformDeadWebhooks.isEmpty {
                    Text("No failed deliveries.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(indexedRecords(platformDeadWebhooks), id: \.id) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(displayName(for: row.record, fallback: row.record.id)).font(.callout)
                                Text(row.record.string("status", "error", "reason")).font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Try Again") {
                                Task {
                                    if await perform({ await store.resendDeadWebhook(platformID: record.id, webhookID: row.record.id) }) != nil {
                                        _ = await perform { await store.loadDeadWebhooks(platformID: record.id) }
                                        deadLoaded = true
                                    }
                                }
                            }
                            .disabled(store.busy || row.record.id.isEmpty)
                        }
                    }
                }
            }
        }
    }

    private var disableConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Disable this platform?").font(.title3.weight(.semibold))
            Text("Disabled platforms disappear from this list. You can re-enable it here or by its ID.")
                .foregroundStyle(.secondary)
            actionErrorLabel
            HStack {
                Spacer()
                Button("Cancel") { confirmDisable = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                Button("Disable Platform", role: .destructive) {
                    Task {
                        actionError = nil
                        let disabled = await store.setPlatformEnabled(id: record.id, enabled: false)
                        if !disabled { actionError = takeStoreErrorForSettings(store) }
                        confirmDisable = false
                        // Only close the details once Slant confirms; a failure stays visible in the details.
                        if disabled { dismiss() }
                    }
                }
                .disabled(store.busy)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var resendAllConfirmSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Resend all failed deliveries?").font(.title3.weight(.semibold))
            Text("Slant will attempt delivery for every failed webhook on this platform.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { confirmResendAll = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                Button("Resend All") {
                    Task {
                        if let result = await perform({ await store.resendDeadWebhooks(platformID: record.id) }) {
                            resendResult = result
                            _ = await perform { await store.loadDeadWebhooks(platformID: record.id) }
                            deadLoaded = true
                        }
                        confirmResendAll = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(store.busy)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private var rotateSecretSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rotate webhook secret").font(.title3.weight(.semibold))
            Text("Type rotate to confirm secret rotation. The previous secret stops working immediately.")
                .foregroundStyle(.secondary)
            TextField("rotate", text: $rotateTyped)
                .textFieldStyle(.roundedBorder)
                .disabled(store.busy)
            actionErrorLabel
            HStack {
                Spacer()
                Button("Cancel") { rotatePrompt = false }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                Button("Rotate Secret") {
                    Task {
                        if let secret = await perform({ await store.rotateWebhookSecret(platformID: record.id) }) {
                            rotatedSecret = secret
                            showSecret = true
                            rotatePrompt = false
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!webhookRotateTypedConfirmAllowed(rotateTyped) || store.busy)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}

@ViewBuilder
func platformReadableFields(_ record: Record) -> some View {
    let description = record.string("description")
    if !description.isEmpty { Text(description).foregroundStyle(.secondary) }
    let url = record.string("url")
    // The same names as the platform composer's fields (Slant's `url` is the application URL: where the seller sells).
    if !url.isEmpty { LabeledContent("Shop address", value: url) }
    let webhook = record.string("webhookURL", "webhookUrl")
    if !webhook.isEmpty { LabeledContent("Webhook URL", value: webhook) }
}

func webhookRotateTypedConfirmAllowed(_ typed: String) -> Bool {
    typed.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("rotate") == .orderedSame
}

func displayedWebhookSecret(rotatedSecret: String?, currentSecret: String) -> String {
    rotatedSecret ?? currentSecret
}

let webhookVerificationRecipe = #"""
X-Webhook-Signature-256 = "sha256=" + hex(HMAC-SHA256(secret, `${timestamp}.${rawBody}`))
Reject timestamps older than 5 minutes.
"""#

// MARK: - Create / edit platform

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
                Text(editing == nil ? "Create platform" : "Edit platform").font(.title2.weight(.bold))
                Text("A platform groups your uploads and orders.").foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            Form {
                Section {
                    TextField("Name", text: $draft.name, prompt: Text("My print shop"))
                    // Slant calls this the platform's application URL; for most sellers it is where they sell.
                    TextField("Shop address", text: $draft.url, prompt: Text("https://www.etsy.com/shop/YourShopName"))
                    TextField("Description", text: $draft.description, prompt: Text("Optional"))
                } footer: {
                    Text("Where you sell, starting with https://: your Etsy shop page, your Shopify store or your own website.")
                        .settingsFooterLayout()
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
                Spacer()
                if store.busy { ProgressView().controlSize(.small) }
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                    .help(store.busy ? "Working…" : "Cancel")
                // Never the default button and no shortcut: both write to Slant's production API (POST or PATCH
                // /platforms), and a platform can only be disabled afterwards, never deleted. Return in a field must
                // not send it.
                Button(editing == nil ? "Create Platform" : "Save Changes") { submit() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy || !store.hasKey)
            }.padding(20)
        }.frame(width: 560, height: 520)
    }

    func submit() {
        do { _ = try draft.payload(); validation = nil } catch { validation = error.localizedDescription; return }
        Task {
            let saved: Bool
            if let editing {
                saved = await store.updatePlatform(id: editing.id, draft: draft)
            } else {
                saved = await store.createPlatform(draft)
            }
            // Never retried. In Settings the app's error alert can sit behind this window, so repeat it here.
            if saved { dismiss() } else if let error = store.error { validation = error }
        }
    }
}
