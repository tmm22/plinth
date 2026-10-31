import SwiftUI

// MARK: - Settings › Account › 3DAPI

/// The seller's 3DAPI integrator key, for Get 3DAPI Quote… in Models and, with 3DAPI as the print service, ordering.
/// The key goes to its own Keychain item; only whether one is saved is a preference.
struct DapiSettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = DapiConnection.shared
    /// Observed so the key's blocked reason (which includes the order screens') stays current.
    @ObservedObject private var orderSession = DapiOrderSession.shared
    @ObservedObject private var printService = PrintServiceChoice.shared
    @State private var keyField = ""
    @State private var status: String?
    @State private var problem: String?
    @State private var testing = false
    /// The account check when the section appears (not the seller's own press).
    @State private var refreshing = false
    @State private var confirmRemove = false

    private var trimmedKey: String { keyField.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            if connection.isConfigured {
                LabeledContent("API key", value: "Saved in the Keychain")
                if let line = dapiAccountStatusLine(connection.account, onboarding: connection.onboarding) {
                    LabeledContent("Account", value: line)
                }
                // Whether this key can place orders (orders:write, approval, billing details); quotes work either way.
                if let ordering = dapiOrderingStatusLine(connection.account, onboarding: connection.onboarding) {
                    Label(ordering.text, systemImage: ordering.ready ? "checkmark.circle" : "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            // No onSubmit: Return never sends the key anywhere.
            SecureField(connection.isConfigured ? "Replace key" : "API key", text: $keyField, prompt: Text("sk_…"))
                .accessibilityLabel(connection.isConfigured ? "Replace 3DAPI key" : "3DAPI API key")
            HStack {
                Button("Save & Test") { saveAndTest() }
                    .disabled(trimmedKey.isEmpty || testing || connection.keyChangeBlockedReason != nil)
                    .help(connection.keyChangeBlockedReason ?? "Check the key with 3DAPI and save it if it can get quotes")
                if connection.isConfigured {
                    Button("Test Saved Key") { testSaved() }
                        .disabled(testing)
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .disabled(testing || connection.keyChangeBlockedReason != nil)
                        .help(connection.keyChangeBlockedReason ?? "Remove the 3DAPI key from this Mac")
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
            }
            if !testing, !refreshing, let reason = connection.keyChangeBlockedReason {
                Text(reason).font(.caption).foregroundStyle(.secondary)
            }
            if let status {
                Label(status, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(printService.service == .dapi ? "3DAPI" : "3DAPI (optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Compares 3DAPI’s price with Slant’s in Models (Get 3DAPI Quote…); quotes are free. With 3DAPI as the print service, you can also order from 3DAPI. Plinth places a 3DAPI order only when you press Place Order after reviewing it; 3DAPI charges your wallet (or saved card) at once.")
                Text("You need a 3DAPI integrator account, which must use a different email from any 3DAPI seller account. Create its key with quotes:read, quotes:write and orders:read, and orders:write to place orders.")
                Text("The key stays in this Mac’s Keychain and goes only to 3DAPI. 3DAPI keeps each quoted model file. 3DAPI is independent of Plinth and Slant 3D.")
                Link("3DAPI Integrator Sign-Up", destination: dapiIntegratorSignUpURL)
            }
            .settingsFooterLayout()
        }
        .task {
            // A read only; a failure just hides the account line.
            guard connection.isConfigured, !testing else { return }
            refreshing = true
            let reason = await connection.refreshStatus()
            refreshing = false
            if connection.account != nil, !testing { problem = reason }
        }
        .confirmationDialog("Remove the 3DAPI key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removeKey() }
            Button("Keep Key", role: .cancel) {}
        } message: {
            Text("This removes the 3DAPI API key from the Keychain on this Mac. Your 3DAPI account, its quotes and its orders are unchanged.")
        }
    }

    /// Checks the typed key with 3DAPI and saves it only when it can get quotes.
    private func saveAndTest() {
        status = nil
        problem = nil
        guard !testing else { return }
        let key = keyField
        testing = true
        Task { @MainActor in
            defer { testing = false }
            if let reason = await connection.saveAndTest(key: key) {
                problem = reason
                return
            }
            keyField = ""
            status = "Key saved and working."
            store.activities.insert(Activity(title: "Save 3DAPI Key", detail: "Saved and tested", success: true), at: 0)
        }
    }

    private func testSaved() {
        status = nil
        problem = nil
        guard !testing else { return }
        testing = true
        Task { @MainActor in
            defer { testing = false }
            if let reason = await connection.testSavedKey() {
                problem = reason
            } else {
                status = "Key working."
            }
        }
    }

    private func removeKey() {
        do {
            try connection.remove()
            keyField = ""
            status = nil
            problem = nil
            store.activities.insert(Activity(title: "Remove 3DAPI Key", detail: "Removed", success: true), at: 0)
        } catch {
            problem = "Couldn’t remove the 3DAPI key: \(dapiRedacted(error.localizedDescription))"
        }
    }
}
