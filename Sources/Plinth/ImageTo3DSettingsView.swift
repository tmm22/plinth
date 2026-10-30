import SwiftUI

// MARK: - Settings › Design Tools › 3D generation

extension ImageTo3DService {
    /// Placeholder for the key field.
    var keyPrompt: String { self == .meshy ? "msy_…" : "tsk_…" }

    func pricingURL(tripoRegion: TripoRegion) -> URL {
        self == .meshy ? URL(string: "https://www.meshy.ai/pricing")! : tripoRegion.pricingURL
    }

    func apiDocsURL(tripoRegion: TripoRegion) -> URL {
        self == .meshy ? URL(string: "https://docs.meshy.ai/api/quick-start")! : tripoRegion.keysURL
    }

    func termsURL(tripoRegion: TripoRegion) -> URL {
        self == .meshy ? URL(string: "https://www.meshy.ai/terms-of-use")! : tripoRegion.termsURL
    }

    /// Plan, price and retention facts for the footer (from each service's docs, 25 Oct 2026).
    var settingsPlanNote: String {
        switch self {
        case .meshy:
            return "Meshy’s API needs a paid plan: free accounts can’t make API keys. A model costs about \(meshyImageTo3DMeshOnlyCredits) credits (mesh only) from one photo or up to four, plus \(meshyHigherDetailCredits) if you choose Higher detail, and Check Printability with Meshy is free. Meshy deletes models made through the API after 3 days."
        case .tripo:
            return "Tripo’s API is paid for with credits (1 credit = US$0.01); there’s no free API plan. A replica costs about \(tripoImageToModelCredits + tripoConvertBasicCredits) credits from one photo or up to four, including its conversion to STL, plus \(tripoHigherDetailCredits) if you choose Higher detail. Keys work only on the Tripo site they were made on."
        }
    }

    /// Who owns the output, per the service's terms (Meshy terms of use §3.2; Tripo terms §5.2).
    var settingsLicenceNote: String {
        switch self {
        case .meshy:
            return "Meshy’s terms: on a paid plan you own the models you make; free-plan models are licensed CC BY 4.0, and Meshy may use what you send and make to train its models."
        case .tripo:
            return "Tripo’s terms: paid users have the rights to their inputs and models, which Tripo doesn’t use for training; Tripo keeps rights to free users’ inputs and models."
        }
    }
}

let imageTo3DSettingsResponsibilityNote = "Generate only objects you have the right to copy. Trademarks, designs and other people’s work stay theirs, and checking a generated model’s licence and intellectual property is your responsibility. Keys are kept in the macOS Keychain on this Mac and sent only to the service’s own API."

/// The status line after a successful Save & Test or Test Saved Key.
func imageTo3DKeyTestStatus(_ balance: ImageTo3DBalance, saved: Bool) -> String {
    "\(saved ? "Key saved and working" : "Key working"). \(balance.summary)"
}

/// Optional: the seller's Meshy or Tripo account, for Generate a Replica from an Image. Each key goes to its own
/// Keychain item; only the chosen service, the Tripo site, which keys are saved and the photo consent are preferences.
struct ImageTo3DSettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = ImageTo3DConnection.shared
    @State private var keyField = ""
    @State private var status: String?
    @State private var problem: String?
    @State private var testing = false
    @State private var confirmRemove = false

    private var service: ImageTo3DService { connection.selectedService }
    private var trimmedKey: String { keyField.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Section {
            Picker("Service", selection: $connection.selectedService) {
                ForEach(ImageTo3DService.allCases) { Text($0.title).tag($0) }
            }
            .disabled(testing)
            if service == .tripo {
                Picker("Tripo site", selection: $connection.tripoRegion) {
                    ForEach(TripoRegion.allCases) { Text($0.title).tag($0) }
                }
                .disabled(testing)
            }
            if connection.hasKey(service) {
                LabeledContent("API key", value: "Saved in the Keychain")
            }
            SecureField(connection.hasKey(service) ? "Replace key" : "API key", text: $keyField, prompt: Text(service.keyPrompt))
                .onSubmit { saveAndTest() }
            if let advice = imageTo3DKeyPrefixAdvice(keyField, service: service) {
                Text(advice).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Save & Test") { saveAndTest() }
                    .disabled(trimmedKey.isEmpty || testing || connection.keyChangeBlockedReason != nil)
                if connection.hasKey(service) {
                    Button("Test Saved Key") { testSaved() }
                        .disabled(testing)
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                        .disabled(testing || connection.keyChangeBlockedReason != nil)
                        .help(connection.keyChangeBlockedReason ?? "Remove the \(service.title) key from this Mac")
                }
                Spacer()
                if testing { ProgressView().controlSize(.small) }
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
            Text("3D generation (optional)")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Generate a Replica from an Image sends your photos (a front view and up to three more) to the service you choose here, after you agree to it once (Photo sharing, below).")
                Text(service.settingsPlanNote)
                Text(service.settingsLicenceNote)
                Text(imageTo3DSettingsResponsibilityNote)
                HStack(spacing: 12) {
                    Link("\(service.title) Pricing", destination: service.pricingURL(tripoRegion: connection.tripoRegion))
                    Link(service == .meshy ? "API Quick Start" : "API Keys", destination: service.apiDocsURL(tripoRegion: connection.tripoRegion))
                    Link("Terms of Use", destination: service.termsURL(tripoRegion: connection.tripoRegion))
                }
            }
            .settingsFooterLayout()
        }
        .onChange(of: connection.selectedService) { _, _ in clearForm() }
        .onChange(of: connection.tripoRegion) { _, _ in status = nil; problem = nil }
        .confirmationDialog("Remove the \(service.title) key?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove", role: .destructive) { removeKey() }
            Button("Keep Key", role: .cancel) {}
        } message: {
            Text("This removes the \(service.title) API key from the Keychain on this Mac. Your \(service.title) account and credits are unchanged.")
        }
    }

    private func clearForm() {
        keyField = ""
        status = nil
        problem = nil
    }

    /// Reads the balance with the typed key and saves the key only when the service accepts it.
    private func saveAndTest() {
        status = nil
        problem = nil
        guard !testing else { return }
        if let reason = connection.keyChangeBlockedReason { problem = reason; return }
        if let issue = imageTo3DKeyProblem(keyField, service: service) { problem = issue; return }
        let chosen = service
        let key = trimmedKey
        let provider = makeImageTo3DProvider(chosen, key: key, tripoRegion: connection.tripoRegion)
        testing = true
        Task { @MainActor in
            defer { testing = false }
            do {
                let balance = try await provider.readBalance()
                guard connection.selectedService == chosen else { return }
                if let reason = connection.keyChangeBlockedReason { problem = reason; return }
                do {
                    try connection.save(key: key, for: chosen)
                } catch {
                    problem = "Couldn’t save the \(chosen.title) key: \(imageTo3DRedacted(error.localizedDescription, secrets: [key]))"
                    return
                }
                keyField = ""
                status = imageTo3DKeyTestStatus(balance, saved: true)
                store.activities.insert(Activity(title: "Save \(chosen.title) Key", detail: "Saved and tested", success: true), at: 0)
            } catch {
                guard connection.selectedService == chosen else { return }
                problem = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription, secrets: [key])
            }
        }
    }

    private func testSaved() {
        status = nil
        problem = nil
        guard !testing else { return }
        let chosen = service
        let provider: ImageTo3DProvider
        do {
            provider = try connection.provider(for: chosen)
        } catch {
            problem = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription)
            return
        }
        testing = true
        Task { @MainActor in
            defer { testing = false }
            do {
                let balance = try await provider.readBalance()
                if connection.selectedService == chosen { status = imageTo3DKeyTestStatus(balance, saved: false) }
            } catch {
                if connection.selectedService == chosen {
                    problem = imageTo3DRedacted((error as? ImageTo3DError)?.userMessage ?? error.localizedDescription)
                }
            }
        }
    }

    private func removeKey() {
        do {
            try connection.removeKey(for: service)
            clearForm()
            store.activities.insert(Activity(title: "Remove \(service.title) Key", detail: "Removed", success: true), at: 0)
        } catch {
            problem = "Couldn’t remove the \(service.title) key: \(imageTo3DRedacted(error.localizedDescription))"
        }
    }
}
