import SwiftUI

// MARK: - Settings › Account › 3DAPI

/// Optional: the seller's 3DAPI integrator key, for Get 3DAPI Quote… in Models (price comparison only). The key goes
/// to its own Keychain item; only whether one is saved is a preference.
struct DapiSettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = DapiConnection.shared
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
            Text("3DAPI (optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Get 3DAPI Quote… in Models compares 3DAPI’s price for a model with Slant’s. Plinth never orders or pays on 3DAPI.")
                Text("It needs a key from a 3DAPI integrator account, which is separate from a 3DAPI seller account. Give the key only quotes:read, quotes:write and orders:read.")
                Text("The key is kept in the macOS Keychain on this Mac and sent only to public-api.dapi.digital. Getting a quote sends the model file to 3DAPI, which keeps it: its API can’t delete it. 3DAPI is an independent service, separate from Plinth and Slant 3D.")
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
            Text("This removes the 3DAPI API key from the Keychain on this Mac. Your 3DAPI account and its quotes are unchanged.")
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
