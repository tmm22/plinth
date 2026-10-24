import SwiftUI

// MARK: - Settings › Design Tools › Claude (Anthropic)

/// One line after a successful key test.
func anthropicKeyTestStatusLine(_ message: AnthropicMessage) -> String {
    let cost = anthropicCostText(anthropicEstimatedCost(message.usage, model: message.model, requestedModel: message.requestedModel))
    if message.isRefusal { return "The key works, but Claude declined the test message. Test cost \(cost)." }
    return "The key works with Claude Opus 5.5. Test cost \(cost)."
}

let anthropicConsoleKeysURL = URL(string: "https://console.anthropic.com/settings/keys")!

/// Optional: the seller's own Anthropic API key, for the Claude design and review tools. The key goes to its own
/// Keychain item and is sent only to api.anthropic.com.
struct AnthropicSettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = AnthropicConnection.shared
    @State private var key = ""
    @State private var status: String?
    @State private var problem: String?
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var confirmRemove = false

    var body: some View {
        Section {
            if connection.isConfigured {
                LabeledContent("API key", value: "Saved in the Keychain")
            }
            SecureField(connection.isConfigured ? "Replace key" : "API key", text: $key, prompt: Text("sk-ant-…"))
                .onSubmit { saveAndTest() }
            HStack {
                Button("Save & Test") { saveAndTest() }
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || testing
                              || connection.keyChangeBlockedReason != nil)
                if connection.isConfigured {
                    Button("Test Saved Key") { testSaved() }
                        .disabled(testing || !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .disabled(testing || connection.keyChangeBlockedReason != nil)
                        .help(connection.keyChangeBlockedReason ?? "Remove the Anthropic key from this Mac")
                }
                Spacer()
                if testing {
                    ProgressView().controlSize(.small)
                    Button("Stop") { testTask?.cancel() }
                }
                Link("Anthropic Console", destination: anthropicConsoleKeysURL)
            }
            if let reason = connection.keyChangeBlockedReason {
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
            Text("Claude (Anthropic)")
        } footer: {
            Text("Claude designs accessories from your photos and reviews generated models. Anthropic bills your own account for each request (Claude Opus 5.5: $4 per million tokens sent, $20 per million written); Studio shows an estimate of each request’s cost. Testing a key costs well under a cent. The key is kept in the macOS Keychain on this Mac and sent only to Anthropic.")
                .settingsFooterLayout()
        }
        .confirmationDialog("Remove the Anthropic key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { remove() }
            Button("Keep Key", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("This removes the key from the Keychain on this Mac. Your Anthropic account and key are unchanged.")
        }
        .onDisappear { testTask?.cancel() }
    }

    /// Tests the typed key with one tiny request and saves it only when Anthropic accepts it.
    private func saveAndTest() {
        status = nil
        problem = nil
        guard !testing else { return }
        if let reason = connection.keyChangeBlockedReason { problem = reason; return }
        if let keyProblem = anthropicKeyProblem(key) { problem = keyProblem; return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        let client = AnthropicClient(apiKey: trimmed)
        run(client) { message in
            // Only the test itself may be running, and no Claude conversation may have opened meanwhile.
            if let reason = anthropicKeyChangeBlockedReason(activeRequests: connection.activeRequests - 1,
                                                            openSessions: connection.openSessions) {
                client.invalidate()
                problem = "The key worked but wasn’t saved. \(reason)"
                return
            }
            do {
                try connection.save(key: trimmed, client: client)
            } catch {
                client.invalidate()
                problem = "Couldn’t save the key: \(aiServiceRedacted(error.localizedDescription, secrets: [trimmed]))"
                return
            }
            key = ""
            status = anthropicKeyTestStatusLine(message)
            store.activities.insert(Activity(title: "Connect Claude", detail: "Key saved and tested", success: true), at: 0)
        } failure: {
            client.invalidate()
        }
    }

    private func testSaved() {
        status = nil
        problem = nil
        guard !testing else { return }
        do {
            let client = try connection.currentClient()
            run(client) { message in status = anthropicKeyTestStatusLine(message) } failure: {}
        } catch {
            problem = aiServiceRedacted(error.localizedDescription)
        }
    }

    /// The test request, counted as a running Claude request so the key can't change under it.
    private func run(_ client: AnthropicClient, success: @escaping (AnthropicMessage) -> Void, failure: @escaping () -> Void) {
        testing = true
        connection.beginRequest()
        testTask = Task { @MainActor in
            defer { testing = false; connection.endRequest(); testTask = nil }
            do {
                let message = try await client.send(AnthropicClient.keyTestRequest())
                success(message)
            } catch is CancellationError {
                problem = "Test stopped. Nothing was saved."
                failure()
            } catch {
                problem = aiServiceRedacted(error.localizedDescription)
                failure()
            }
        }
    }

    private func remove() {
        if let reason = connection.keyChangeBlockedReason { problem = reason; return }
        do {
            try connection.remove()
            status = nil
            problem = nil
            store.activities.insert(Activity(title: "Remove Claude Key", detail: "Removed", success: true), at: 0)
        } catch {
            problem = "Couldn’t remove the key: \(aiServiceRedacted(error.localizedDescription))"
        }
    }
}
