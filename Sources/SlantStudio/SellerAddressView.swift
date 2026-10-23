import SwiftUI

// MARK: - Settings › Account › Your address (for samples)

/// The form a Settings visit starts from: the saved address, or an empty one with the Mac's region as the initial
/// country (never assumed when the region isn't a country).
func sellerAddressInitialDraft(saved: SellerAddress?, regionDefault: (selection: String, customCode: String) = defaultDeliveryCountry()) -> SellerAddress {
    if let saved { return saved }
    let country = regionDefault.selection == orderCountryOtherTag ? regionDefault.customCode : regionDefault.selection
    return SellerAddress(country: country)
}

/// True when Save would change what is stored: a complete form that differs from the saved address.
func sellerAddressCanSave(_ draft: SellerAddress, saved: SellerAddress?) -> Bool {
    sellerAddressSaveBlockedReason(draft) == nil && sellerAddressTrimmed(draft) != saved
}

/// The seller's own address, opt-in and removable. Saved to Application Support only when Save is pressed; never
/// recorded in Activity or logs. Customer addresses are not saved here or anywhere else.
struct SellerAddressSettingsSection: View {
    @EnvironmentObject var store: StudioStore
    @State private var draft = SellerAddress()
    @State private var didLoad = false
    @State private var problem: String?
    @State private var confirmRemove = false
    @State private var justSaved = false
    @FocusState private var postcodeFocused: Bool

    private var differsFromSaved: Bool {
        store.sellerAddress.map { sellerAddressTrimmed(draft) != $0 } ?? !sellerAddressIsBlank(draft)
    }
    private var blockedReason: String? { sellerAddressSaveBlockedReason(draft) }

    var body: some View {
        Section {
            TextField("Name", text: $draft.name)
            TextField("Email", text: $draft.email)
            // Country first: it decides whether State is required and how the postcode is checked.
            countryPicker
            TextField("Street address", text: $draft.line1)
            TextField("Apartment, suite, etc. (optional)", text: $draft.line2)
            TextField("City", text: $draft.city)
            TextField(orderStateIsRequired(draft.country) ? "State / province" : "State / province (optional)", text: $draft.state)
            VStack(alignment: .leading, spacing: 4) {
                TextField("Postal code", text: $draft.zip)
                    .focused($postcodeFocused)
                if let warning = postcodeFormatWarning(draft.zip, country: draft.country, whileEditing: postcodeFocused) {
                    Text(warning).font(.caption).foregroundStyle(.orange)
                }
            }
            HStack {
                Button("Save Address") { save() }
                    .disabled(!sellerAddressCanSave(draft, saved: store.sellerAddress))
                if store.sellerAddress != nil {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
                Spacer()
                if differsFromSaved, let blockedReason {
                    Text(blockedReason).font(.caption).foregroundStyle(.secondary)
                } else if justSaved, !differsFromSaved {
                    Label("Saved", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                }
            }
            if let problem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Your address (for samples)")
        } footer: {
            Text("Your own address, saved on this Mac until you remove it. It is used only when you choose Use My Address or Order a Sample to Me…; customer addresses are still never saved.")
                .settingsFooterLayout()
        }
        .onAppear {
            guard !didLoad else { return }
            didLoad = true
            draft = sellerAddressInitialDraft(saved: store.sellerAddress)
        }
        // Saving replaces the form with the trimmed address, which must not hide the Saved note it just earned.
        .onChange(of: draft) {
            problem = nil
            if differsFromSaved { justSaved = false }
        }
        .confirmationDialog("Remove your saved address?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Remove Address", role: .destructive) { remove() }
            Button("Keep Address", role: .cancel) {}
        } message: {
            Text("It is deleted from this Mac. Drafts you already created keep the address they were sent with.")
        }
    }

    /// The composer's country list: shortlist first, then every other country by name.
    @ViewBuilder
    private var countryPicker: some View {
        let others = orderOtherCountryChoicesForCurrentLocale
        Picker("Country", selection: Binding(
            get: { draft.country },
            set: { draft.country = $0.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }
        )) {
            Text("Choose a country").tag("")
            Divider()
            ForEach(orderCountryChoices, id: \.code) { Text($0.name).tag($0.code) }
            Divider()
            if !draft.country.isEmpty, !orderCountryChoices.contains(where: { $0.code == draft.country }),
               !others.contains(where: { $0.code == draft.country }) {
                Text("Country code \(draft.country)").tag(draft.country)
            }
            ForEach(others, id: \.code) { Text($0.name).tag($0.code) }
        }
    }

    private func save() {
        do {
            try store.saveSellerAddress(draft)
            draft = store.sellerAddress ?? draft
            problem = nil
            justSaved = true
        } catch {
            problem = "Couldn’t save your address: \(error.localizedDescription)"
        }
    }

    private func remove() {
        do {
            try store.removeSellerAddress()
            draft = sellerAddressInitialDraft(saved: nil)
            problem = nil
            justSaved = false
        } catch {
            problem = "Couldn’t remove your address: \(error.localizedDescription)"
        }
    }
}

// MARK: - Order a Sample to Me… without a saved address

/// Explains why Order a Sample to Me… needs the seller's address and offers to open Settings.
struct SellerAddressNeededAlert: ViewModifier {
    @EnvironmentObject var store: StudioStore

    func body(content: Content) -> some View {
        content.alert("Add your address first", isPresented: $store.showSellerAddressNeeded) {
            Button("Open Settings") { store.requestSettings(.account) }
                .keyboardShortcut(.defaultAction)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Order a Sample to Me… sends a model to your own address. Save it in Settings › Account under “Your address (for samples)”, then try again.")
        }
    }
}
