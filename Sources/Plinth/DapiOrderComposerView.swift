import SwiftUI

// New 3DAPI Order…: the composer sheet "New 3DAPI order". It gathers lines (library models with a ready 3DAPI quote, or
// a duplicated order's quotes), the recipient and an optional reference and notes, all in memory. Nothing here sends
// an order: Review Order… opens the review (DapiPlaceOrderSheet.swift), where only Place Order charges. Return never
// places anything, and the composer never uploads files or creates quotes.

struct DapiOrderComposerView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var session = DapiOrderSession.shared
    @ObservedObject private var connection = DapiConnection.shared
    @StateObject private var state = DapiComposerState(environment: .live())

    let seed: DapiComposerSeed
    let onPlaced: (DapiOrder) -> Void
    let onFound: (DapiOrder) -> Void

    @State private var address = DapiComposerAddress()
    @State private var initialAddress = DapiComposerAddress()
    @State private var initialLineSignature: [String] = []
    @State private var reference = ""
    @State private var notes = ""
    @State private var didSeed = false
    @State private var registered = false
    @State private var countryPicked = false
    @State private var confirmUseMyAddress = false
    @State private var confirmDiscard = false
    @State private var showAddressPaste = false
    @State private var addressPasteText = ""
    @State private var addressPasteSkippedClipboard = false
    @State private var sellerAddressMissing = false
    @State private var review: DapiReviewRequest?
    @State private var placed = false

    private var problems: [DapiComposerField: String] { dapiRecipientProblems(address, notes: notes) }
    private var linesProblem: String? { dapiComposerLinesProblem(state.lines) }
    private var draft: DapiOrderDraft? {
        dapiOrderDraft(lines: state.lines, address: address, reference: reference, notes: notes, catalogue: state.materials)
    }
    private var orderingProblem: String? {
        guard let account = connection.account else { return nil }
        return dapiOrderingProblem(account: account, onboardingOrderBlockers: connection.onboarding?.orderBlockers ?? [])
    }
    /// Why Review Order… is off: the first problem, lines first.
    private var reviewBlockedReason: String? {
        if !connection.isConfigured { return "Add a 3DAPI key in Settings first." }
        if let linesProblem { return linesProblem }
        let order: [DapiComposerField] = [.country, .name, .email, .line1, .city, .line2, .state, .postcode, .phone, .notes]
        for field in order { if let problem = problems[field] { return problem } }
        return nil
    }
    private var shippingKey: DapiOrderShippingKey? {
        let requests = state.lines.compactMap(dapiLineRequest)
        let country = orderCountryPickerValue(address.delivery)
        guard !requests.isEmpty, requests.count == state.lines.count, dapiIsDeliveryCountry(country) else { return nil }
        return DapiOrderShippingKey(lines: requests, countryCode: country.uppercased())
    }
    private var hasInput: Bool {
        dapiComposerHasInput(lineSignature: dapiComposerLineSignature(state.lines), initialLineSignature: initialLineSignature,
                             address: address, initialAddress: initialAddress, reference: reference, notes: notes)
    }
    private var availableModels: [LocalModel] {
        store.localModels
            .filter { FileManager.default.fileExists(atPath: $0.filePath) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("New 3DAPI order")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 16)
            form
        }
        .frame(minWidth: 720, idealWidth: 780, minHeight: 640)
        .safeAreaInset(edge: .bottom) { footer }
        .interactiveDismissDisabled(true)
        .onExitCommand {
            if showAddressPaste { showAddressPaste = false } else { requestClose() }
        }
        .confirmationDialog("Discard this order?", isPresented: $confirmDiscard) {
            Button("Discard Order", role: .destructive) { close() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Nothing was sent to 3DAPI. The lines and details you entered are discarded.")
        }
        .confirmationDialog("Replace the delivery details?", isPresented: $confirmUseMyAddress, titleVisibility: .visible) {
            Button("Use My Address") { applyMyAddress() }
            Button("Keep Current Details", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("The name, email and address in this order are replaced with your saved address.")
        }
        .sheet(item: $review, onDismiss: { if placed { close() } }) { request in
            DapiPlaceOrderSheet(draft: request.draft, onPlaced: { order in
                placed = true
                onPlaced(order)
            }, onFound: onFound)
            .environmentObject(store)
        }
        .onAppear {
            if !registered {
                registered = true
                session.sheetOpened()
            }
            seedIfNeeded()
        }
        .onDisappear {
            // A review shown over the composer isn't a close.
            guard review == nil else { return }
            state.close()
            if registered {
                registered = false
                session.sheetClosed()
            }
        }
        .onChange(of: shippingKey) { _, key in state.shippingInputsChanged(key) }
        .onChange(of: showAddressPaste) { _, shown in
            if !shown { addressPasteText = ""; addressPasteSkippedClipboard = false }
        }
        .onChange(of: state.lines.map(\.useSuggested)) { _, _ in
            if state.lines.contains(where: { !$0.useSuggested && $0.state == .ready }) { state.loadMaterialsIfNeeded() }
        }
        .onChange(of: state.lines.map(\.state)) { _, _ in
            if state.lines.contains(where: { !$0.useSuggested && $0.state == .ready }) { state.loadMaterialsIfNeeded() }
        }
    }

    // MARK: Seeding

    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        var start = DapiComposerAddress()
        if let prefill = seed.prefill {
            if let code = prefill.countryCode, dapiIsDeliveryCountry(code) {
                start.delivery = deliveryApplyingCountryPick(code, to: start.delivery)
            }
            if prefill.useSellerAddress {
                if let seller = store.sellerAddress {
                    start.delivery = deliveryDetails(fromSellerAddress: seller)
                } else {
                    sellerAddressMissing = true
                }
            }
            if let modelID = prefill.modelID, let model = store.localModels.first(where: { $0.id == modelID }),
               FileManager.default.fileExists(atPath: model.filePath) {
                state.addModel(model, quantity: prefill.quantity)
            }
        }
        if let order = seed.duplicateOf {
            state.addDuplicated(dapiComposerLines(duplicating: order), modelNames: DapiModelNameIndex.shared.names)
        }
        address = start
        initialAddress = start
        initialLineSignature = dapiComposerLineSignature(state.lines)
    }

    // MARK: Form

    private var form: some View {
        Form {
            if let orderingProblem {
                Section {
                    Label(orderingProblem, systemImage: "info.circle").font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if !session.unconfirmedOrders.isEmpty {
                Section {
                    DapiUnconfirmedOrdersNotice(onFound: onFound)
                }
            }
            if let order = seed.duplicateOf {
                Section("Copied from order \(order.number)") {
                    Text("The same models, quantities and materials were copied. 3DAPI doesn’t return the address in a form Plinth can copy, so enter it below.")
                        .font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if (order.items ?? []).count > dapiOrderMaxLines {
                        Text("Only the first 100 lines were copied.").font(.callout).foregroundStyle(.orange)
                    }
                }
            }
            linesSection
            deliverySection
            Section("Reference and notes") {
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Your order reference", text: $reference, prompt: Text("Optional, such as a marketplace order number"))
                    Text(referenceCaption).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Notes for 3DAPI", text: $notes, prompt: Text("Optional"), axis: .vertical)
                        .lineLimit(2...5)
                    if let problem = problems[.notes] { fieldProblem(problem) }
                }
            }
            shippingSection
        }
        .formStyle(.grouped)
    }

    private var referenceCaption: String {
        let sent = dapiOrderReference(sellerReference: reference, token: "xxxxxxxx")
        let shown = sent.replacingOccurrences(of: "xxxxxxxx", with: "…")
        return "Never a buyer’s name. 3DAPI receives “\(shown)”: Plinth adds a code for each attempt so it can find the order if 3DAPI doesn’t answer clearly."
    }

    // MARK: Lines

    private var linesSection: some View {
        Section {
            if state.lines.isEmpty {
                Text("Add a library model that has a 3DAPI quote (Models › Get 3DAPI Quote…).")
                    .font(.callout).foregroundStyle(.secondary)
            }
            ForEach($state.lines) { $line in
                lineEditor($line)
            }
            if let problem = state.materialsProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Menu {
                if availableModels.isEmpty {
                    Text("No library models")
                }
                ForEach(availableModels) { model in
                    Button(model.name) { state.addModel(model) }
                }
            } label: {
                Label("Add Model", systemImage: "plus")
            }
            .fixedSize()
            .disabled(state.lines.count >= dapiOrderMaxLines || !connection.isConfigured)
            .help(state.lines.count >= dapiOrderMaxLines ? "3DAPI takes at most 100 lines in one order."
                  : "Add a library model. Plinth finds the 3DAPI quote you got for it; it never uploads or makes quotes here.")
        } header: {
            Text("Items")
        }
    }

    @ViewBuilder
    private func lineEditor(_ line: Binding<DapiComposerLine>) -> some View {
        let value = line.wrappedValue
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(value.name.isEmpty ? "Unnamed quote" : value.name).font(.body.weight(.semibold)).lineLimit(1)
                Spacer()
                HStack(spacing: 4) {
                    TextField("Quantity", text: line.quantityText)
                        .labelsHidden()
                        .frame(width: 64)
                        .accessibilityLabel("Quantity for \(value.name)")
                    Stepper("Quantity", value: Binding(get: { value.quantity ?? 1 },
                                                       set: { line.wrappedValue.quantityText = String($0) }),
                            in: 1...dapiOrderMaxUnitsPerLine)
                        .labelsHidden()
                        .accessibilityLabel("Quantity for \(value.name)")
                }
                .fixedSize()
                Button(role: .destructive) { state.remove(lineID: value.id) } label: { Image(systemName: "minus.circle") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Remove \(value.name)")
                    .help("Remove this line")
            }
            if value.quantity == nil {
                fieldProblem("Enter a whole number from 1 to 10,000.")
            } else if let warning = largeQuantityNotice(value.quantity ?? 1) {
                Label(warning, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
            }
            switch value.state {
            case .resolving:
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking for this model’s 3DAPI quote…").font(.callout).foregroundStyle(.secondary)
                }
            case .problem(let reason):
                HStack(alignment: .firstTextBaseline) {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Check Again") { state.checkAgain(lineID: value.id) }.controlSize(.small)
                }
            case .ready:
                if let quote = value.quote, let price = quote.price {
                    let upTo = value.quantity.flatMap { dapiLineUpTo(unitPrice: price, quantity: $0) }
                    Text("\(dapiMoneyText(price)) per unit" + (upTo.map { " · up to \(dapiMoneyText($0)) for this line" } ?? ""))
                        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
                }
                materialsEditor(line)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func materialsEditor(_ line: Binding<DapiComposerLine>) -> some View {
        let value = line.wrappedValue
        let hasSuggestions = dapiQuoteHasSuggestions(value.quote)
        VStack(alignment: .leading, spacing: 6) {
            if hasSuggestions {
                Toggle("Use 3DAPI’s suggested materials", isOn: line.useSuggested)
                let suggestions = (value.quote?.suggestedMaterials ?? []).sorted { $0.slot < $1.slot }
                if value.useSuggested {
                    Text(suggestions.map { suggestion in
                        let name = suggestion.materialName ?? "—"
                        let match = suggestion.match.map { " (\($0) match)" } ?? ""
                        return suggestions.count > 1 ? "Slot \(suggestion.slot): \(name)\(match)" : name + match
                    }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("3DAPI suggested no materials for this model: choose them.").font(.caption).foregroundStyle(.secondary)
            }
            if !value.useSuggested || !hasSuggestions {
                if state.materialsLoading {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Reading 3DAPI’s materials…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if !state.materials.isEmpty {
                    let slots = dapiLineSlots(value.quote)
                    ForEach(slots, id: \.self) { slot in
                        Picker(slots.count > 1 ? "Slot \(slot)" : "Material", selection: Binding(
                            get: { line.wrappedValue.slotMaterials[slot] ?? "" },
                            set: { line.wrappedValue.slotMaterials[slot] = $0 }
                        )) {
                            Text("Choose a material").tag("")
                            ForEach(dapiMaterialGroups(state.materials), id: \.title) { group in
                                Section(group.title) {
                                    ForEach(group.materials) { material in Text(material.name).tag(material.id) }
                                }
                            }
                        }
                    }
                } else {
                    Button("Load Materials") { state.loadMaterialsIfNeeded() }.controlSize(.small)
                }
            }
        }
    }

    // MARK: Delivery

    private var deliverySection: some View {
        Section {
            if sellerAddressMissing {
                HStack(alignment: .firstTextBaseline) {
                    Label("Add your address in Settings › Account to send a sample to yourself.", systemImage: "info.circle")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button("Open Settings") { store.requestSettings(.account) }.controlSize(.small)
                }
            }
            countryPicker
            fieldWithProblem(.name) { TextField("Full name", text: $address.delivery.name, prompt: Text("Required")) }
            fieldWithProblem(.email) {
                TextField("Email", text: $address.delivery.email, prompt: Text("Required: 3DAPI needs it"))
            }
            fieldWithProblem(.phone) { TextField("Phone", text: $address.phone, prompt: Text("Optional")) }
            fieldWithProblem(.line1) { TextField("Street address", text: $address.delivery.line1, prompt: Text("Required")) }
            fieldWithProblem(.line2) { TextField("Apartment, suite, etc.", text: $address.delivery.line2, prompt: Text("Optional")) }
            fieldWithProblem(.city) { TextField("City", text: $address.delivery.city, prompt: Text("Required")) }
            fieldWithProblem(.state) { TextField("State / province", text: $address.delivery.state, prompt: Text("Optional")) }
            fieldWithProblem(.postcode) {
                TextField("Postal code", text: $address.delivery.zip, prompt: Text("Optional"))
            }
            if let warning = postcodeFormatWarning(address.delivery.zip, country: orderCountryPickerValue(address.delivery)) {
                Text(warning).font(.caption).foregroundStyle(.orange)
            }
            Text("These details are sent to 3DAPI with the order and kept only in this sheet until then.")
                .font(.caption).foregroundStyle(.secondary)
        } header: {
            HStack {
                Text("Deliver to")
                Spacer()
                if store.sellerAddress != nil {
                    Button {
                        if let seller = store.sellerAddress,
                           useMyAddressNeedsConfirmation(current: address.delivery, replacement: deliveryDetails(fromSellerAddress: seller),
                                                         countryPicked: countryPicked) {
                            confirmUseMyAddress = true
                        } else {
                            applyMyAddress()
                        }
                    } label: {
                        Label("Use My Address", systemImage: "house")
                    }
                    .controlSize(.small)
                    .help("Fill in your own address from Settings › Account, for a sample sent to you")
                }
                // The pasteboard is read only when this is pressed; nothing changes until Use These Details.
                Button {
                    let prefill = addressPastePasteboardText()
                    addressPasteText = prefill.text
                    addressPasteSkippedClipboard = prefill.skippedNonAddress
                    showAddressPaste = true
                } label: {
                    Label("Paste Address…", systemImage: "doc.on.clipboard")
                }
                .controlSize(.small)
                .help("Fill in an address copied from Etsy, Shopify or an email, after you check it")
                .popover(isPresented: $showAddressPaste, arrowEdge: .bottom) {
                    AddressPastePopover(initialText: addressPasteText, skippedClipboard: addressPasteSkippedClipboard,
                                        current: address.delivery, needsConfirmation: { pasted in
                        pastedAddressNeedsConfirmation(current: address.delivery,
                                                       replacement: deliveryDetails(applyingPasted: pasted, to: address.delivery),
                                                       countryPicked: countryPicked)
                    }, onUse: { pasted in
                        showAddressPaste = false
                        address.delivery = deliveryDetails(applyingPasted: pasted, to: address.delivery)
                    }, onCancel: {
                        showAddressPaste = false
                    })
                }
            }
        }
    }

    /// Country first: shortlist, then every other country; "Choose a country" when the Mac's region is unknown.
    private var countryPicker: some View {
        let picked = orderCountryPickerValue(address.delivery)
        let others = orderOtherCountryChoicesForCurrentLocale
        return VStack(alignment: .leading, spacing: 4) {
            Picker("Country", selection: Binding(
                get: { picked },
                set: {
                    address.delivery = deliveryApplyingCountryPick($0, to: address.delivery)
                    countryPicked = true
                }
            )) {
                Text("Choose a country").tag("")
                Divider()
                ForEach(orderCountryChoices, id: \.code) { Text($0.name).tag($0.code) }
                Divider()
                if !picked.isEmpty, !orderCountryChoices.contains(where: { $0.code == picked }),
                   !others.contains(where: { $0.code == picked }) {
                    Text("Country code \(picked)").tag(picked)
                }
                ForEach(others, id: \.code) { Text($0.name).tag($0.code) }
            }
            if let problem = problems[.country], !picked.isEmpty { fieldProblem(problem) }
        }
    }

    @ViewBuilder
    private func fieldWithProblem<Content: View>(_ field: DapiComposerField, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            content()
            // Required-field problems show once something was typed anywhere in the address; format problems at once.
            if let problem = problems[field], showsProblem(field) { fieldProblem(problem) }
        }
    }

    private func showsProblem(_ field: DapiComposerField) -> Bool {
        let d = address.delivery
        let value: String
        switch field {
        case .name: value = d.name
        case .email: value = d.email
        case .phone: value = address.phone
        case .line1: value = d.line1
        case .line2: value = d.line2
        case .city: value = d.city
        case .state: value = d.state
        case .postcode: value = d.zip
        case .country, .notes: return true
        }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func fieldProblem(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.orange)
    }

    private func applyMyAddress() {
        guard let seller = store.sellerAddress else { return }
        address.delivery = deliveryDetails(fromSellerAddress: seller)
        sellerAddressMissing = false
    }

    // MARK: Shipping

    @ViewBuilder
    private var shippingSection: some View {
        Section("Shipping estimate") {
            let key = shippingKey
            let stale = state.shippingFor != nil && state.shippingFor != key
            if state.shippingLoading {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Pricing shipping…").font(.callout).foregroundStyle(.secondary)
                }
            } else if let shipping = state.shipping, !stale {
                Text("\(dapiMoneyText(shipping.total)) before VAT · \(dapiShippingNote(shipping))")
                    .font(.callout).monospacedDigit()
                    .fixedSize(horizontal: false, vertical: true)
            } else if key == nil {
                Text("Choose the country and finish every line to price shipping.").font(.callout).foregroundStyle(.secondary)
            }
            if let problem = state.shippingProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !state.shippingLoading, let key, stale || state.shipping == nil {
                HStack {
                    if stale {
                        Label("Shipping needs updating for these lines and country.", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    Spacer(minLength: 0)
                    Button("Update Shipping") { state.requestShipping(key) }
                        .help("Ask 3DAPI for shipping to this country (nothing is ordered)")
                }
            }
            Text("The review prices everything again before anything is charged.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Cancel", role: .cancel) { requestClose() }
                // Escape belongs to an open Paste Address popover first.
                .keyboardShortcut(showAddressPaste ? nil : .cancelAction)
            Spacer()
            if let reason = reviewBlockedReason {
                Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // No default-action shortcut: Return in a field never opens the review, and the review's Place Order
            // takes its own click.
            Button("Review Order…") {
                guard let draft, review == nil else { return }
                review = DapiReviewRequest(draft: draft)
            }
            .buttonStyle(.borderedProminent)
            .disabled(reviewBlockedReason != nil || draft == nil || state.isResolving)
            .help(reviewBlockedReason ?? "Check prices, shipping and your account before placing the order")
        }
        .padding(16)
        .background(.bar)
    }

    private func requestClose() {
        if hasInput { confirmDiscard = true } else { close() }
    }

    private func close() {
        state.close()
        dismiss()
    }
}

/// The review sheet's input.
struct DapiReviewRequest: Identifiable {
    let id = UUID()
    let draft: DapiOrderDraft
}
