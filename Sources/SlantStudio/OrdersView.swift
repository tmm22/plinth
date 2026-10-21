import SwiftUI
import AppKit

struct OrderLine: Identifiable {
    let id = UUID()
    var type = "PRINT"
    var reference = ""
    var filamentID = ""
    var quantity = 1
    var imageURL = ""
    var name = ""
    var sku = ""
    var optionsJSON = "{}"
    func payload() throws -> [String: Any] {
        guard !reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, quantity > 0 else { throw StudioError("Choose an item and a quantity of at least 1 for every line.") }
        var value: [String: Any] = ["type": type, "quantity": quantity]
        value[type == "PRINT" ? "publicFileServiceId" : type == "COMPONENT" ? "componentId" : "stationeryId"] = reference
        if type == "PRINT" {
            guard !filamentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError("Choose a material for every 3D print item.") }
            value["filamentId"] = filamentID
        }
        if type == "STATIONERY" {
            let trimmedURL = imageURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedURL.isEmpty {
                guard isHTTPSImageURL(trimmedURL) else { throw StudioError("Enter an https image link with a website address.") }
                value["imageUrl"] = trimmedURL
            }
        }
        if !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value["name"] = name.trimmingCharacters(in: .whitespacesAndNewlines) }
        if !sku.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { value["SKU"] = sku.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let data = optionsJSON.data(using: .utf8), let options = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw StudioError("Item options must be a JSON object.") }
        if !options.isEmpty { value["options"] = options }
        return value
    }
}

struct OrderMetadataField: Identifiable, Equatable {
    let id = UUID()
    var key = ""
    var value = ""
}

func orderStateIsRequired(_ country: String) -> Bool {
    ["US", "CA", "AU"].contains(country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased())
}

func orderDraftPayload(
    platformID: String, ownerID: String, email: String, recipientName: String,
    line1: String, line2: String, city: String, state: String, zip: String, country: String,
    paymentID: String, metadata: [String: Any], options: [String: Any], lines: [OrderLine]
) throws -> [String: Any] {
    guard !platformID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StudioError("Choose a platform first.") }
    let countryCode = country.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    let trimmedState = state.trimmingCharacters(in: .whitespacesAndNewlines)
    guard [recipientName, line1, city, zip, countryCode].allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
          isEmailAddress(email) else { throw StudioError("Complete the delivery address and an email like name@example.com.") }
    if orderStateIsRequired(countryCode), trimmedState.isEmpty {
        throw StudioError("Complete the delivery address and an email like name@example.com.")
    }
    let items = try lines.map { try $0.payload() }
    guard !items.isEmpty else { throw StudioError("Add at least one order item.") }
    var address: [String: Any] = [
        "name": recipientName.trimmingCharacters(in: .whitespacesAndNewlines),
        "line1": line1.trimmingCharacters(in: .whitespacesAndNewlines),
        "line2": line2.trimmingCharacters(in: .whitespacesAndNewlines),
        "city": city.trimmingCharacters(in: .whitespacesAndNewlines),
        "zip": zip.trimmingCharacters(in: .whitespacesAndNewlines),
        "country": countryCode
    ]
    if !trimmedState.isEmpty { address["state"] = trimmedState }
    var customer: [String: Any] = ["details": [
        "email": email.trimmingCharacters(in: .whitespacesAndNewlines),
        "address": address
    ]]
    if !paymentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { customer["publicPaymentServiceId"] = paymentID.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: [String: Any] = ["platformId": platformID, "customer": customer, "items": items]
    if !ownerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["ownerId"] = ownerID.trimmingCharacters(in: .whitespacesAndNewlines) }
    if !metadata.isEmpty { body["metadata"] = metadata }
    if !options.isEmpty { body["options"] = options }
    return body
}

func orderObject(_ object: [String: Any]) -> [String: Any] {
    object["order"] as? [String: Any] ?? object
}

/// Merge draft envelope `items` / `totals` / `customer` into the order record (order fields win).
func mergeOrderDraftEnvelope(_ data: [String: Any]) -> [String: Any] {
    var order = orderObject(data)
    if order["items"] == nil, let items = data["items"] { order["items"] = items }
    if order["customer"] == nil, let customer = data["customer"] { order["customer"] = customer }
    if let totals = data["totals"] as? [String: Any] {
        if order["printingCost"] == nil, let value = totals["printingCost"] { order["printingCost"] = value }
        if order["deliveryCost"] == nil, let value = totals["deliveryCost"] { order["deliveryCost"] = value }
        if order["total"] == nil, order["totalCost"] == nil, let value = totals["totalCost"] { order["totalCost"] = value }
    }
    return order
}

func orderShippingOptions(provider: String) -> [String: Any] {
    let trimmed = provider.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !trimmed.isEmpty else { return [:] }
    return ["shippingProvider": trimmed]
}

func orderMetadataDictionary(_ fields: [OrderMetadataField]) throws -> [String: Any] {
    guard fields.count <= 10 else { throw StudioError("Metadata supports up to 10 fields.") }
    var result: [String: Any] = [:]
    var seen = Set<String>()
    for field in fields {
        let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw StudioError("Metadata keys can’t be empty.") }
        guard !seen.contains(key) else { throw StudioError("Metadata keys must be unique.") }
        seen.insert(key)
        result[key] = field.value
    }
    return result
}

func orderLinesUseUnavailableMaterial(_ lines: [OrderLine], filaments: [Record]) -> Bool {
    lines.contains { line in
        guard line.type == "PRINT", !line.filamentID.isEmpty else { return false }
        guard let filament = filaments.first(where: { $0.id == line.filamentID }) else { return false }
        return filamentAvailability(filament) == false
    }
}

let orderCountryOtherTag = "__OTHER__"
let orderCountryChoices: [(code: String, name: String)] = [
    ("US", "United States"), ("CA", "Canada"), ("GB", "United Kingdom"), ("AU", "Australia"),
    ("NZ", "New Zealand"), ("IE", "Ireland"), ("DE", "Germany"), ("FR", "France"),
    ("NL", "Netherlands"), ("JP", "Japan")
]
/// Region is a convenient editable default, not a claim about the user's physical location.
func defaultDeliveryCountry(regionCode: String? = Locale.current.region?.identifier) -> (selection: String, customCode: String) {
    let code = (regionCode ?? "").uppercased()
    guard isCountryCode(code), Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else {
        return ("", "")
    }
    if orderCountryChoices.contains(where: { $0.code == code }) { return (code, "") }
    return (orderCountryOtherTag, code)
}

let orderShippingProviderChoices: [(code: String, name: String)] = [
    ("", "Default"), ("SHIPPO", "Shippo"), ("SHIPSTATION", "ShipStation")
]

enum OrderConfirmLoadState: Equatable { case loading, loaded, failed }
enum OrderConfirmRecheckResult: Equatable {
    case proceed
    case statusBlocked(String)
    case priceChanged
}

struct PendingOrderConfirm: Identifiable {
    var id: String { "\(method):\(orderID)" }
    let method: String
    let orderID: String
}

// MARK: - Composer

struct OrderComposerView: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    @State private var lines: [OrderLine] = []
    @State private var delivery = DeliveryDetails()
    @State private var editingDelivery = false
    @State private var seededDelivery = false
    @State private var paymentID = ""
    @State private var shippingProvider = ""
    @State private var metadataFields: [OrderMetadataField] = []
    @State private var validation: String?
    @State private var showEmailError = false
    @State private var catalogsLoading = false
    @State private var draftPlatformID = ""
    @StateObject private var locationLookup = DeliveryLocationLookup()
    @State private var locationAddressApplied = false
    @State private var didSeed = false
    @State private var initialLines: [OrderLine] = []
    @State private var initialDelivery = DeliveryDetails()
    @State private var sourceOrderNumber: String?
    @State private var skippedItems: [String] = []
    @State private var deliveryCopied = true
    @State private var confirmDiscard = false

    var hasUnsavedInput: Bool {
        orderComposerHasUnsavedInput(
            lines: lines, initialLines: initialLines, delivery: delivery, initialDelivery: initialDelivery,
            metadataFields: metadataFields, paymentID: paymentID
        )
    }
    var emailFieldError: String? {
        let trimmed = delivery.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return showEmailError ? "Enter an email like name@example.com." : nil }
        return isEmailAddress(delivery.email) ? nil : "Enter an email like name@example.com."
    }
    var createBlockedReason: String? {
        if !store.hasKey { return "Connect your account first." }
        if draftPlatformID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return store.platforms.isEmpty ? "Load platforms to choose one by name." : "Choose a platform first."
        }
        if orderLinesUseUnavailableMaterial(lines, filaments: store.filaments) {
            return "Choose an in-stock material for every 3D print item."
        }
        return nil
    }
    var deliverySummary: String {
        [delivery.name, delivery.line1, delivery.city, delivery.countrySelection == orderCountryOtherTag ? delivery.customCountry : delivery.countrySelection]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }
    var catalogTaskID: String {
        lines.map(\.type).sorted().joined(separator: ",") + "|\(draftPlatformID)"
    }

    var body: some View {
        Form {
            if let sourceOrderNumber {
                Section("Duplicated from order \(sourceOrderNumber)") {
                    Text("Items and delivery details were copied for you to check. Slant calculates new prices when you create the draft, and you review the total before anything is charged.")
                        .font(.callout).foregroundStyle(.secondary)
                    if lines.allSatisfy({ $0.reference.isEmpty }) {
                        Text("No items could be copied. Choose them below.").font(.callout).foregroundStyle(.orange)
                    }
                    if !deliveryCopied {
                        Text("This order had no delivery details to copy. Enter them below.").font(.callout).foregroundStyle(.orange)
                    }
                    if !skippedItems.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Label("Not copied", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            ForEach(Array(skippedItems.enumerated()), id: \.offset) { _, reason in
                                Text(reason).font(.callout)
                            }
                        }
                    }
                }
            }
            Section("Items") {
                ForEach($lines) { $item in
                    orderItemEditor($item)
                }
                Button { lines.append(OrderLine()) } label: { Label("Add another item", systemImage: "plus") }
            }
            Section("Deliver to") {
                if seededDelivery, !editingDelivery {
                    Text(deliverySummary.isEmpty ? delivery.email : deliverySummary)
                        .foregroundStyle(.secondary)
                    Button("Edit") { editingDelivery = true }
                } else {
                    deliveryFields
                }
            }
            Section("More options") {
                if store.platforms.isEmpty {
                    Text("Load platforms to choose one by name.").foregroundStyle(.secondary)
                    Button("Load platforms") { Task { await store.loadCatalog(.platforms) } }.disabled(!store.hasKey || store.busy)
                } else {
                    orderCatalogPicker("Platform", selection: $draftPlatformID, records: store.platforms, placeholder: "Choose a platform")
                }
                DisclosureGroup("Advanced") {
                    TextField("Owner ID (optional)", text: $store.ownerID)
                    TextField("Payment service ID (optional)", text: $paymentID)
                }
                Picker("Shipping provider", selection: $shippingProvider) {
                    ForEach(orderShippingProviderChoices, id: \.code) { Text($0.name).tag($0.code) }
                }
                ForEach($metadataFields) { $field in
                    HStack {
                        TextField("Key", text: $field.key)
                        TextField("Value", text: $field.value)
                        Button(role: .destructive) { metadataFields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }
                            .accessibilityLabel("Remove metadata field").help("Remove metadata field")
                    }
                }
                if metadataFields.count < 10 {
                    Button("Add metadata field") { metadataFields.append(OrderMetadataField()) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("New Order Draft")
        .frame(minWidth: 720, minHeight: 640)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel", role: .cancel) { requestClose() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(store.busy)
                    .help(store.busy ? "Working…" : "Cancel")
                Spacer()
                if let validation { Text(validation).font(.caption).foregroundStyle(.orange).lineLimit(3) }
                else if let createBlockedReason { Text(createBlockedReason).font(.caption).foregroundStyle(.secondary) }
                if store.busy { ProgressView().controlSize(.small) }
                Button("Create Draft") { createDraft() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.busy || createBlockedReason != nil)
                    .help(createBlockedReason ?? "Create an order draft")
            }
            .padding(16)
            .background(.bar)
        }
        .interactiveDismissDisabled(hasUnsavedInput)
        .confirmationDialog("Discard this order draft?", isPresented: $confirmDiscard) {
            Button("Discard Draft", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your items and delivery details haven’t been saved. Nothing has been sent to Slant.")
        }
        .onAppear(perform: seedIfNeeded)
        // Pending location work stops whenever the form actually closes (create, cancel or discard).
        .onDisappear { locationLookup.cancel() }
        .task(id: catalogTaskID) { await loadNeededCatalogs() }
        .task { await store.refreshFilamentsIfStale() }
    }

    @ViewBuilder
    var deliveryFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    locationAddressApplied = false
                    locationLookup.start()
                } label: {
                    Label("Use current location", systemImage: "location")
                }
                .disabled(locationLookup.isBusy || store.busy)
                if locationLookup.isBusy {
                    ProgressView().controlSize(.small)
                        .accessibilityLabel("Finding your address")
                    Button("Stop lookup") { locationLookup.cancel() }
                }
            }
            Text("With your permission, Apple uses your location to suggest an address. Check the building and add any apartment or unit number.")
                .font(.caption).foregroundStyle(.secondary)
            if let message = locationLookup.message {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            if let suggestion = locationLookup.suggestion {
                Text("Suggested address").font(.headline)
                Text(suggestion.summary).textSelection(.enabled)
                Text("Confirm this is your delivery address. Using it replaces the address fields below; your name and email are kept.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Use this address") {
                        delivery = suggestion.applying(to: delivery)
                        locationLookup.clearSuggestion()
                        locationAddressApplied = true
                    }
                    .disabled(store.busy)
                    Button("Dismiss suggestion") { locationLookup.clearSuggestion() }
                }
            }
            if locationAddressApplied {
                Label("Address filled in. Check it below and add any apartment or unit number before creating your draft.", systemImage: "checkmark.circle")
                    .font(.callout)
            }
        }
        TextField("Full name", text: $delivery.name)
        VStack(alignment: .leading, spacing: 4) {
            TextField("Email", text: $delivery.email)
            if let emailFieldError { Text(emailFieldError).font(.caption).foregroundStyle(.orange) }
        }
        TextField("Street address", text: $delivery.line1)
        TextField("Apartment, suite, etc. (optional)", text: $delivery.line2)
        TextField("City", text: $delivery.city)
        TextField(
            orderStateIsRequired(orderCountryPickerValue(delivery))
                ? "State / province"
                : "State / province (optional)",
            text: $delivery.state
        )
        TextField("Postal code", text: $delivery.zip)
        countryPicker
    }

    /// Shortlist first, then every other country by name. Stays on "Choose a country" when nothing is known.
    @ViewBuilder
    var countryPicker: some View {
        let picked = orderCountryPickerValue(delivery)
        let others = orderOtherCountryChoicesForCurrentLocale
        Picker("Country", selection: Binding(
            get: { picked },
            set: { delivery = deliveryApplyingCountryPick($0, to: delivery) }
        )) {
            Text("Choose a country").tag("")
            Divider()
            ForEach(orderCountryChoices, id: \.code) { Text($0.name).tag($0.code) }
            Divider()
            if !picked.isEmpty, !orderCountryChoices.contains(where: { $0.code == picked }), !others.contains(where: { $0.code == picked }) {
                Text("Country code \(picked)").tag(picked)
            }
            ForEach(others, id: \.code) { Text($0.name).tag($0.code) }
        }
    }

    @ViewBuilder
    func orderItemEditor(_ item: Binding<OrderLine>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Type", selection: Binding(
                    get: { item.wrappedValue.type },
                    set: { newType in
                        if item.wrappedValue.type != newType {
                            item.wrappedValue.reference = ""
                            item.wrappedValue.filamentID = ""
                            item.wrappedValue.imageURL = ""
                        }
                        item.wrappedValue.type = newType
                    }
                )) {
                    Text("3D print").tag("PRINT"); Text("Component").tag("COMPONENT"); Text("Stationery").tag("STATIONERY")
                }.frame(width: 210)
                Stepper("Quantity: \(item.wrappedValue.quantity)", value: item.quantity, in: 1...10000)
                Button(role: .destructive) { lines.removeAll { $0.id == item.wrappedValue.id } } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove item")
                    .help(lines.count < 2 ? "An order needs at least one item." : "Remove item")
                    .disabled(lines.count < 2)
            }
            if let warning = largeQuantityComposerWarning(item.wrappedValue.quantity) {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
            if item.wrappedValue.type == "PRINT" {
                catalogOrLoad(kind: .models, empty: store.files.isEmpty, hasSelection: !item.wrappedValue.reference.isEmpty) {
                    orderCatalogPicker("Model", selection: item.reference, records: store.files, placeholder: "Choose an uploaded model")
                }
                if orderLineModelLooksMissing(item.wrappedValue, files: store.files,
                                              filesFullyLoaded: store.filesLoaded && !store.filesHasMore && !store.fileSearchActive) {
                    Label("This model isn’t in your uploaded models. It may have been deleted; choose another.", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                }
                catalogOrLoad(kind: .materials, empty: store.filaments.isEmpty, hasSelection: !item.wrappedValue.filamentID.isEmpty) {
                    materialPicker(selection: item.filamentID)
                }
            }
            if item.wrappedValue.type == "COMPONENT" {
                catalogOrLoad(kind: .components, empty: store.components.isEmpty, hasSelection: !item.wrappedValue.reference.isEmpty) {
                    orderCatalogPicker("Component", selection: item.reference, records: store.components, placeholder: "Choose a component")
                }
            }
            if item.wrappedValue.type == "STATIONERY" {
                catalogOrLoad(kind: .stationery, empty: store.stationery.isEmpty, hasSelection: !item.wrappedValue.reference.isEmpty) {
                    orderCatalogPicker("Stationery", selection: item.reference, records: store.stationery, placeholder: "Choose stationery")
                }
                TextField("Custom image link (optional, starts with https://)", text: item.imageURL)
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Item name (optional)", text: item.name)
                    TextField("SKU (optional)", text: item.sku)
                    if item.wrappedValue.type == "PRINT", store.files.isEmpty { TextField("Model reference", text: item.reference) }
                    if item.wrappedValue.type == "PRINT", store.filaments.isEmpty { TextField("Material reference", text: item.filamentID) }
                    if item.wrappedValue.type == "COMPONENT", store.components.isEmpty { TextField("Component reference", text: item.reference) }
                    if item.wrappedValue.type == "STATIONERY", store.stationery.isEmpty { TextField("Stationery reference", text: item.reference) }
                }
            }
        }
    }

    @ViewBuilder
    func catalogOrLoad<Content: View>(kind: Destination, empty: Bool, hasSelection: Bool, @ViewBuilder content: () -> Content) -> some View {
        let loaded = catalogIsLoaded(kind)
        if empty, !hasSelection {
            Text(catalogEmptyTitle(kind, loaded: loaded, loading: catalogsLoading)).font(.callout).foregroundStyle(.secondary)
            if !catalogsLoading, !loaded {
                Button(loadButtonTitle(kind)) { Task { await loadNeededCatalogs(force: true) } }
                    .disabled(!store.hasKey || store.busy)
            }
        } else {
            content()
        }
    }

    func catalogIsLoaded(_ kind: Destination) -> Bool {
        switch kind {
        case .models: return store.filesLoaded
        default: return store.loadedCatalogs.contains(kind)
        }
    }

    func catalogEmptyTitle(_ kind: Destination, loaded: Bool, loading: Bool) -> String {
        if loading, !loaded { return "Loading…" }
        if !loaded { return "Nothing loaded yet." }
        switch kind {
        case .models: return "No uploaded models yet. Upload one from Models."
        case .materials: return "No materials on this account."
        case .components: return "No components on this account."
        case .stationery: return "No stationery on this account."
        default: return "Nothing to choose yet."
        }
    }

    func loadButtonTitle(_ kind: Destination) -> String {
        switch kind {
        case .models: return "Load your models"
        case .materials: return "Load materials"
        case .components: return "Load components"
        case .stationery: return "Load stationery"
        default: return "Load"
        }
    }

    @ViewBuilder
    func materialPicker(selection: Binding<String>) -> some View {
        Picker("Material", selection: selection) {
            Text("Choose a material").tag("")
            if !selection.wrappedValue.isEmpty, !store.filaments.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Previously chosen material").tag(selection.wrappedValue)
            }
            ForEach(filamentTypes(in: store.filaments), id: \.self) { type in
                Section(type) {
                    ForEach(indexedRecords(filamentsMatching(store.filaments, type: type)), id: \.id) { row in
                        let title = displayName(for: row.record, fallback: "Untitled")
                        if let stock = filamentAvailabilityLabel(row.record) {
                            Text("\(title) (\(stock))").tag(row.record.id)
                        } else {
                            Text(title).tag(row.record.id)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    func orderCatalogPicker(_ title: String, selection: Binding<String>, records: [Record], placeholder: String) -> some View {
        Picker(title, selection: selection) {
            Text(placeholder).tag("")
            if !selection.wrappedValue.isEmpty, !records.contains(where: { $0.id == selection.wrappedValue }) {
                let savedName = store.localModels.first { $0.remoteID == selection.wrappedValue }?.name
                Text(savedName ?? "Previously chosen item").tag(selection.wrappedValue)
            }
            ForEach(indexedRecords(records), id: \.id) { row in
                Text(displayName(for: row.record, fallback: "Untitled")).tag(row.record.id)
            }
        }
    }

    /// One-shot: a second onAppear must not overwrite what the user has typed.
    func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        if draftPlatformID.isEmpty { draftPlatformID = store.platformID }
        let prefill = store.pendingOrderPrefill
        store.pendingOrderPrefill = nil
        if let prefill {
            // Keep the source order's platform unless the loaded list shows it is no longer available.
            if let platform = prefill.platformID, store.platforms.isEmpty || store.platforms.contains(where: { $0.id == platform }) {
                draftPlatformID = platform
            }
            sourceOrderNumber = prefill.sourceOrderNumber
            skippedItems = prefill.skippedItems
            shippingProvider = prefill.shippingProvider
        }
        let seededLines = orderComposerInitialLines(prefill: prefill) {
            var filament = store.filamentID
            if filament.isEmpty, let fallback = store.defaultFilamentID { filament = fallback }
            return OrderLine(reference: store.fileID, filamentID: filament, quantity: store.quantity)
        }
        var seededDeliveryDetails = delivery
        switch orderComposerDeliverySeed(prefill: prefill, lastDelivery: store.lastDelivery) {
        case .copiedFromOrder(let copied):
            seededDeliveryDetails = copied
            seededDelivery = true
            // An unknown country must be chosen explicitly, so show the fields instead of the summary.
            editingDelivery = orderCountryPickerValue(copied).isEmpty
        case .lastUsed(let saved):
            seededDeliveryDetails = saved
            seededDelivery = true
            editingDelivery = false
        case .blank(let missingFromSourceOrder):
            deliveryCopied = !missingFromSourceOrder
        }
        lines = seededLines
        initialLines = seededLines
        delivery = seededDeliveryDetails
        initialDelivery = seededDeliveryDetails
    }

    func requestClose() {
        if hasUnsavedInput { confirmDiscard = true } else { dismiss() }
    }

    func loadNeededCatalogs(force: Bool = false) async {
        guard store.hasKey else { return }
        catalogsLoading = true
        defer { catalogsLoading = false }
        let types = Set(lines.map(\.type))
        if types.contains("PRINT") {
            if store.filaments.isEmpty || force { await store.loadCatalog(.materials) }
            if store.files.isEmpty || force { await store.refresh() }
        }
        if types.contains("COMPONENT"), store.components.isEmpty || force { await store.loadCatalog(.components) }
        if types.contains("STATIONERY"), store.stationery.isEmpty || force { await store.loadCatalog(.stationery) }
        if store.platforms.isEmpty || force { await store.loadCatalog(.platforms) }
    }

    func createDraft() {
        showEmailError = true
        do {
            if let createBlockedReason { validation = createBlockedReason; return }
            let pickedCountry = orderCountryPickerValue(delivery)
            let restOfAddressComplete = [delivery.name, delivery.line1, delivery.city, delivery.zip]
                .allSatisfy { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } && isEmailAddress(delivery.email)
            if pickedCountry.isEmpty, restOfAddressComplete { throw StudioError("Choose a delivery country.") }
            let country: String
            if pickedCountry.isEmpty {
                country = ""
            } else if delivery.countrySelection == orderCountryOtherTag {
                country = try normalizedCountryCode(delivery.customCountry)
            } else {
                country = delivery.countrySelection
            }
            let metadata = try orderMetadataDictionary(metadataFields)
            let options = orderShippingOptions(provider: shippingProvider)
            let body = try orderDraftPayload(
                platformID: draftPlatformID, ownerID: store.ownerID, email: delivery.email, recipientName: delivery.name,
                line1: delivery.line1, line2: delivery.line2, city: delivery.city, state: delivery.state, zip: delivery.zip, country: country,
                paymentID: paymentID, metadata: metadata, options: options, lines: lines
            )
            validation = nil
            Task { await store.run("Create order draft") {
                let response = try await store.client.request("POST", path: "/orders", body: body)
                let data = responseObject(response)
                let order = mergeOrderDraftEnvelope(data)
                guard !Record(values: order).id.isEmpty else { throw StudioError("Slant didn’t return an order number. Check Orders before creating another draft.") }
                store.draft = ["order": order]
                // A duplicated order's address belongs to that order's customer; don't make it the next draft's default.
                if sourceOrderNumber == nil { store.lastDelivery = delivery }
                let record = Record(values: order)
                store.orders.removeAll { $0.id == record.id }; store.orders.insert(record, at: 0)
                store.destination = .orders; dismiss()
            } }
        } catch { validation = error.localizedDescription }
    }
}

// MARK: - Orders

struct OrderTableRow: Identifiable {
    let record: Record
    var id: String { record.id }
    var recipient: String { orderListTitle(orderObject(record.values)) }
    var status: String { orderStatusTitle((orderObject(record.values)["status"] as? String) ?? "") }
    var created: String { orderCreatedDisplay(orderObject(record.values)) ?? "" }
    var total: String { orderTotalMoney(orderObject(record.values)) }
    var number: String { orderNumber(orderObject(record.values)) }
}

struct OrdersView: View {
    @EnvironmentObject var store: StudioStore
    @State private var selection: String?
    @State private var search = ""
    @State private var detail: [String: Any]?
    @State private var pendingConfirm: PendingOrderConfirm?
    @State private var pendingLoadID: String?
    @State private var filtersPresented = false
    @State private var draftFilterStatus = ""
    @State private var draftSortOrder = "desc"
    @State private var useFromDate = false
    @State private var useToDate = false
    @State private var draftFromDate = Date()
    @State private var draftToDate = Date()
    @State private var sortOrder = [KeyPathComparator(\OrderTableRow.created, order: .reverse)]

    var selected: Record? { store.orders.first { $0.id == selection } }
    var displayedOrder: [String: Any]? {
        guard let selected else { return nil }
        if let detail, orderBelongs(detail, to: selected.id) { return detail }
        return orderObject(selected.values)
    }
    var canCancelSelected: Bool {
        displayedOrder.map { orderCanRequestCancellation(($0["status"] as? String) ?? "") } ?? false
    }
    var listRecords: [Record] {
        if store.orderSearchActive { return store.orders }
        return store.orders.filter { orderMatchesSearch($0, query: search) }
    }
    var tableRows: [OrderTableRow] {
        listRecords.map(OrderTableRow.init).sorted(using: sortOrder)
    }
    var draftFilterPreview: OrderFilter {
        var filter = OrderFilter()
        filter.status = draftFilterStatus.isEmpty ? nil : draftFilterStatus
        filter.sortOrder = draftSortOrder
        filter.startDate = useFromDate ? draftFromDate : nil
        filter.endDate = useToDate ? draftToDate : nil
        return filter
    }
    var draftFilterValidation: String? { orderFilterValidationError(draftFilterPreview) }

    var body: some View {
        Group {
            if store.ordersLoaded && tableRows.isEmpty && displayedOrder == nil {
                tableEmptyOverlay.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
        HSplitView {
            VStack(spacing: 0) {
                Table(tableRows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Recipient", value: \.recipient) { (row: OrderTableRow) in
                        Text(row.recipient).lineLimit(1)
                    }
                    TableColumn("Status", value: \.status) { (row: OrderTableRow) in
                        Text(row.status)
                    }
                    .width(110)
                    TableColumn("Created", value: \.created) { (row: OrderTableRow) in
                        Text(row.created.isEmpty ? "—" : row.created)
                    }
                    .width(110)
                    TableColumn("Total", value: \.total) { (row: OrderTableRow) in
                        Text(row.total)
                    }
                    .width(80)
                    TableColumn("Order number", value: \.number) { (row: OrderTableRow) in
                        Text(row.number).foregroundStyle(.secondary)
                    }
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first, let record = store.orders.first(where: { $0.id == id }) {
                        Button("Duplicate as New Draft…") { Task { await store.duplicateOrderAsDraft(orderID: id) } }
                            .disabled(store.duplicateOrderBlockedReason(orderID: id) != nil)
                        Button("Copy Order ID") { copyToPasteboard(orderNumber(orderObject(record.values))) }
                    }
                }
                .overlay {
                    if store.ordersLoaded, tableRows.isEmpty {
                        tableEmptyOverlay
                    }
                }
                if store.orderSearchActive {
                    Text("Press Return to search all orders. Clear the search to load more orders.")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                } else if store.ordersHasMore {
                    HStack {
                        Spacer()
                        Button("Load More") { Task { await store.loadMoreOrders() } }
                            .disabled(!store.hasKey || store.busy)
                        Spacer()
                    }.padding(8)
                }
            }
            .frame(minWidth: 420)
            detailPane
                .frame(minWidth: 360)
        }
            }
        }
        .searchable(text: $search, prompt: "Search orders")
        .onSubmit(of: .search) { Task { await store.searchOrders(search) } }
        .onChange(of: search) { _, new in
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.orderSearchActive {
                Task { await store.searchOrders("") }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if let reason = store.orderDraftBlockedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                }
                Button("New Order Draft…") { store.openOrderComposer() }
                    .disabled(store.orderDraftBlockedReason != nil || store.busy)
                    .help(store.orderDraftBlockedReason ?? "Create an order draft")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    syncFilterDraftFromStore()
                    filtersPresented = true
                } label: {
                    Label("Filters", systemImage: "line.3.horizontal.decrease.circle")
                }
                .popover(isPresented: $filtersPresented, arrowEdge: .bottom) {
                    filtersPopover
                }
            }
        }
        .onChange(of: selection) { _, new in
            pendingLoadID = nil
            detail = nil
            if let new { load(new) }
        }
        .onChange(of: store.busy) { _, busy in
            if !busy, let id = pendingLoadID, selection == id {
                pendingLoadID = nil
                load(id)
            }
        }
        .onChange(of: store.draft == nil) { _, draftIsNil in
            guard !draftIsNil else { return }
            applyIncomingDraft()
        }
        .onAppear {
            applyIncomingDraft()
            syncFilterDraftFromStore()
        }
        .sheet(item: $pendingConfirm) { request in
            OrderActionConfirmSheet(method: request.method, orderID: request.orderID) { orderID, order in
                let record = Record(values: order)
                if !record.id.isEmpty, let index = store.orders.firstIndex(where: { $0.id == orderID }) {
                    store.orders[index] = record
                }
                if selection == orderID { detail = order }
            }
            .environmentObject(store)
        }
    }

    var filtersPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Filters").font(.headline)
            Picker("Status", selection: $draftFilterStatus) {
                Text("All").tag("")
                ForEach(orderStatusFilterOptions, id: \.self) { Text(orderStatusTitle($0)).tag($0) }
            }
            Picker("Sort", selection: $draftSortOrder) {
                Text("Newest").tag("desc")
                Text("Oldest").tag("asc")
            }
            Toggle("From date", isOn: $useFromDate)
            if useFromDate {
                DatePicker("From", selection: $draftFromDate, displayedComponents: .date)
            }
            Toggle("To date", isOn: $useToDate)
            if useToDate {
                DatePicker("To", selection: $draftToDate, displayedComponents: .date)
            }
            if let draftFilterValidation {
                Text(draftFilterValidation).font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Clear filters") {
                    draftFilterStatus = ""
                    draftSortOrder = "desc"
                    useFromDate = false
                    useToDate = false
                    filtersPresented = false
                    Task { await store.applyOrderFilter(OrderFilter()) }
                }
                Spacer()
                Button("Apply") {
                    filtersPresented = false
                    Task { await store.applyOrderFilter(draftFilterPreview) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftFilterValidation != nil)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    func syncFilterDraftFromStore() {
        draftFilterStatus = store.orderFilter.status ?? ""
        draftSortOrder = store.orderFilter.sortOrder
        useFromDate = store.orderFilter.startDate != nil
        useToDate = store.orderFilter.endDate != nil
        draftFromDate = store.orderFilter.startDate ?? Date()
        draftToDate = store.orderFilter.endDate ?? Date()
    }

    @ViewBuilder
    var tableEmptyOverlay: some View {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.orderSearchActive || store.orderFilter.isActive {
            ContentUnavailableView.search(text: search.isEmpty ? "filters" : search)
        } else if store.orders.isEmpty {
            ContentUnavailableView {
                Label("No orders yet", systemImage: "shippingbox")
            } description: {
                Text("Create a draft to calculate printing and shipping.")
            } actions: {
                Button("New Order Draft…") { store.openOrderComposer() }
                    .disabled(store.orderDraftBlockedReason != nil || store.busy)
            }
        }
    }

    @ViewBuilder
    var detailPane: some View {
        if let selected, let displayed = displayedOrder {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        SectionHeading(title: orderDetailCaption(displayed), caption: orderStatusTitle((displayed["status"] as? String) ?? selected.string("status")))
                        Spacer()
                        Button { load(selected.id) } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Reload order").help("Reload order").disabled(store.busy)
                    }
                    OrderSummary(order: displayed)
                    HStack {
                        if canCancelSelected {
                            let status = (displayed["status"] as? String) ?? ""
                            Button(orderCancelActionTitle(status), role: .destructive) {
                                pendingConfirm = PendingOrderConfirm(method: "DELETE", orderID: selected.id)
                            }
                            .disabled(store.busy)
                            .help("Review cancellation")
                        } else if let reason = orderCancellationBlockedReason((displayed["status"] as? String) ?? "") {
                            Button("Cancel…", role: .destructive) {}
                                .disabled(true)
                                .help(reason)
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let duplicateBlocked = store.duplicateOrderBlockedReason(orderID: selected.id)
                        Button("Duplicate as New Draft…") { Task { await store.duplicateOrderAsDraft(orderID: selected.id) } }
                            .disabled(duplicateBlocked != nil)
                            .help(duplicateBlocked ?? "Open a new draft with this order’s items and delivery details for review")
                        if ((displayed["status"] as? String) ?? "").uppercased() == "DRAFT" {
                            Button("Review & Place Order…") { pendingConfirm = PendingOrderConfirm(method: "POST", orderID: selected.id) }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.busy)
                                .help("Review and pay")
                        }
                    }
                    if ((displayed["status"] as? String) ?? "").uppercased() == "DRAFT" {
                        Text("Placing charges your saved payment method.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(24)
            }
        } else {
            detailEmptyState
        }
    }

    @ViewBuilder
    var detailEmptyState: some View {
        if !store.ordersLoaded {
            EmptyState(icon: "shippingbox", title: "Your orders, in one place", detail: "Load recent orders, or create a draft to calculate printing and shipping.") {
                Button("Load Orders") { Task { await store.refresh() } }.disabled(!store.hasKey || store.busy)
            }
        } else if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.orderSearchActive || store.orderFilter.isActive {
            if listRecords.isEmpty {
                ContentUnavailableView.search(text: search.isEmpty ? "filters" : search)
            } else {
                ContentUnavailableView("Select an order", systemImage: "shippingbox", description: Text("Choose an order from the list to review it."))
            }
        } else if store.orders.isEmpty {
            EmptyState(icon: "shippingbox", title: "No orders yet", detail: "Create a draft to calculate printing and shipping.") {
                Button("New Order Draft…") { store.openOrderComposer() }
                    .disabled(store.orderDraftBlockedReason != nil || store.busy)
            }
        } else {
            ContentUnavailableView("Select an order", systemImage: "shippingbox", description: Text("Choose an order from the list to review it."))
        }
    }

    func applyIncomingDraft() {
        guard let draft = store.draft else { return }
        let order = mergeOrderDraftEnvelope(draft)
        selection = Record(values: order).id
        detail = order
        store.draft = nil
    }
    func load(_ id: String) {
        Task {
            let ran = await store.run("Get order") {
                let response = try await store.client.request("GET", path: "/orders/\(encodedSegment(id))")
                let order = mergeOrderDraftEnvelope(responseObject(response))
                if selection == id { detail = order }
                let record = Record(values: order)
                if !record.id.isEmpty, let index = store.orders.firstIndex(where: { $0.id == id }) { store.orders[index] = record }
            }
            if !ran, selection == id {
                pendingLoadID = id
            } else if pendingLoadID == id {
                pendingLoadID = nil
            }
        }
    }
}

// MARK: - Confirm sheet

struct OrderActionConfirmSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) var dismiss
    let method: String
    let orderID: String
    let onCompleted: (_ orderID: String, _ order: [String: Any]) -> Void
    @State private var fresh: [String: Any]?
    @State private var loadState: OrderConfirmLoadState = .loading
    @State private var awaitingBusy = false
    @State private var actionMessage: String?
    @State private var writing = false
    @State private var writeSucceeded = false
    @State private var writeAttempted = false
    @State private var successMessage: String?
    @State private var capturedRefundOnly = false
    var isPay: Bool { method == "POST" }
    var status: String? { fresh.flatMap { $0["status"] as? String } }
    var refundOnly: Bool { orderCancellationIsRefundOnly(status ?? "") }
    var mutationLock: (Bool, String?) { orderConfirmMutationSendAllowed(attempted: writeAttempted, succeeded: writeSucceeded) }
    /// Set by an earlier Orders or Workbench attempt whose result is unknown; survives closing and reopening this sheet.
    var sharedOutcomeLock: Bool { store.isOutcomeUnknown(orderID: orderID) }
    var finalActionEnabled: Bool {
        orderConfirmFinalActionEnabled(
            writeSucceeded: writeSucceeded,
            writeAttempted: writeAttempted,
            loaded: loadState == .loaded,
            status: status,
            isPay: isPay,
            order: fresh
        ) && !writing && !store.busy && !sharedOutcomeLock
    }
    var sheetTitle: String {
        if isPay { return "Place this order?" }
        return orderCancelSheetTitle(status ?? "")
    }
    var sheetBodyCopy: String {
        if isPay {
            return "This charges the payment method associated with your Slant account and starts fulfillment. Costs below are loaded fresh from Slant."
        }
        return orderCancelSheetBody(status ?? "")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(sheetTitle).font(.title2.weight(.bold))
            Text(sheetBodyCopy).foregroundStyle(.secondary)
            switch loadState {
            case .loading:
                ProgressView("Loading order…").controlSize(.small)
            case .failed:
                VStack(alignment: .leading, spacing: 10) {
                    Text(isPay ? "Couldn’t load this order’s costs." : "Couldn’t load this order.").font(.callout).foregroundStyle(.orange)
                    Button("Try again") { loadFresh() }.disabled(store.busy || writing)
                }
            case .loaded:
                if let order = fresh {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status: \(orderStatusTitle(status ?? ""))")
                        if let items = order["items"] as? [[String: Any]], !items.isEmpty {
                            // Visual fat-finger check only; the explicit Pay confirmation below is unchanged.
                            if isPay, let warning = largeQuantityReviewWarning(items) {
                                Label(warning, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).fontWeight(.semibold)
                            }
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                let text = "\(item["quantity"].map { String(describing: $0) } ?? "1") × \(orderItemDisplayName(item))"
                                if isPay, orderItemHasLargeQuantity(item) {
                                    Label(text, systemImage: "exclamationmark.triangle.fill")
                                        .foregroundStyle(.orange).fontWeight(.semibold)
                                        .accessibilityLabel("Large quantity: \(text)")
                                } else {
                                    Text(text)
                                }
                            }
                        }
                        LabeledContent("Printing") { Text("\(money(order["printingCost"])) USD") }
                        LabeledContent("Delivery") { Text("\(money(order["deliveryCost"])) USD") }
                        LabeledContent("Total") { Text("\(orderTotalMoney(order)) USD").fontWeight(.semibold) }
                        LabeledContent("Recipient") { Text(orderRecipientDisplay(order)) }
                    }.font(.callout).textSelection(.enabled)
                }
            }
            if let successMessage {
                Text(successMessage).font(.callout).foregroundStyle(.secondary)
            } else if let actionMessage {
                Text(actionMessage).font(.callout).foregroundStyle(.orange)
            }
            if writing { Label("Working…", systemImage: "ellipsis").font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
            HStack {
                Button(writeSucceeded ? "Done" : "Go back", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(writing)
                Spacer()
                if writeSucceeded {
                    EmptyView()
                } else if writeAttempted || sharedOutcomeLock {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let reason = writeAttempted ? mutationLock.1 : unknownOutcomeBlockMessage {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Reload order") { loadFresh(keepUnknownMessage: true) }
                            .disabled(store.busy || writing)
                    }
                } else if isPay {
                    VStack(alignment: .trailing, spacing: 6) {
                        if loadState == .loaded, !finalActionEnabled, let reason = workbenchChargeAllowed(status: status, loaded: true, order: fresh).1 {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Pay & send to production") { confirmAction() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!finalActionEnabled)
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        if loadState == .loaded, !finalActionEnabled, let reason = orderCancelConfirmAllowed(status: status, loaded: true).1 {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Button(orderCancelSheetButtonTitle(status ?? ""), role: .destructive) { confirmAction() }
                            .disabled(!finalActionEnabled)
                    }
                }
            }
        }
        .padding(26)
        .frame(width: 560, height: 520)
        .onAppear { loadFresh() }
        .onChange(of: store.busy) { _, busy in
            if !busy, awaitingBusy, !writing, !writeSucceeded {
                awaitingBusy = false
                loadFresh(keepUnknownMessage: writeAttempted)
            }
        }
    }
    func loadFresh(keepUnknownMessage: Bool = false) {
        guard !writeSucceeded else { return }
        if !keepUnknownMessage { actionMessage = nil }
        if store.busy {
            loadState = .loading
            awaitingBusy = true
            return
        }
        awaitingBusy = false
        loadState = .loading
        fresh = nil
        Task {
            var succeeded = false
            let ran = await store.run("Load order for review") {
                let response = try await store.client.request("GET", path: "/orders/\(encodedSegment(orderID))")
                let loaded = mergeOrderDraftEnvelope(responseObject(response))
                fresh = loaded
                succeeded = true
                if store.isOutcomeUnknown(orderID: orderID),
                   unknownOutcomeResolvedByReload(
                       context: store.unknownOutcomeContext(orderID: orderID),
                       reloadedStatus: (loaded["status"] as? String) ?? ""
                   ) {
                    store.clearOutcomeUnknown(orderID: orderID)
                }
            }
            loadState = orderConfirmLoadStateAfterRun(succeeded: succeeded, skippedBusy: !ran)
            if !ran { awaitingBusy = true }
            if keepUnknownMessage, writeAttempted, !writeSucceeded {
                actionMessage = orderConfirmMutationSendAllowed(attempted: true, succeeded: false).1
            }
        }
    }
    func confirmAction() {
        guard let shown = fresh, !writeSucceeded, !writeAttempted, !writing, !sharedOutcomeLock else { return }
        actionMessage = nil
        writing = true
        let successRefundOnly = orderCancellationIsRefundOnly((shown["status"] as? String) ?? "")
        Task {
            var outcome: OrderConfirmRecheckResult = .proceed
            var latestOrder: [String: Any]?
            var mutateOrder: [String: Any]?
            var completedOrder: [String: Any]?
            var didWrite = false
            var attemptedWrite = false
            var rejected = false
            let ran = await store.run(isPay ? "Process order" : "Cancel order") {
                let preview = try await store.client.request("GET", path: "/orders/\(encodedSegment(orderID))")
                let latest = mergeOrderDraftEnvelope(responseObject(preview))
                latestOrder = latest
                outcome = orderConfirmRecheck(method: method, shown: shown, latest: latest)
                if let abort = orderConfirmRecheckAbortError(outcome) { throw abort }
                if store.isOutcomeUnknown(orderID: orderID) { throw StudioError(unknownOutcomeBlockMessage) }
                // Shared lock before the write: a timeout or 5xx leaves the charge/cancel outcome unknown.
                store.markOutcomeUnknown(orderID: orderID, action: isPay ? .pay : .cancel, reviewedStatus: latest["status"] as? String)
                attemptedWrite = true
                writeAttempted = true
                capturedRefundOnly = successRefundOnly
                let mutateResponse: APIResponse
                do {
                    mutateResponse = try await store.client.request(method, path: "/orders/\(encodedSegment(orderID))")
                } catch {
                    if orderMutationErrorProvesNoEffect(error) {
                        // Slant refused it, so nothing is pending: lift the lock and return to the review.
                        store.clearOutcomeUnknown(orderID: orderID)
                        attemptedWrite = false
                        writeAttempted = false
                        rejected = true
                    }
                    throw error
                }
                mutateOrder = mergeOrderDraftEnvelope(responseObject(mutateResponse))
                didWrite = true
                store.clearOutcomeUnknown(orderID: orderID)
                do {
                    let refreshed = try await store.client.request("GET", path: "/orders/\(encodedSegment(orderID))")
                    completedOrder = mergeOrderDraftEnvelope(responseObject(refreshed))
                } catch {
                    completedOrder = mutateOrder
                }
            }
            writing = false
            if attemptedWrite { writeAttempted = true; capturedRefundOnly = successRefundOnly }
            if !ran { awaitingBusy = true; return }
            if let latest = latestOrder { fresh = latest; loadState = .loaded }
            if didWrite {
                let best = completedOrder ?? mutateOrder ?? latestOrder ?? shown
                fresh = best
                loadState = .loaded
                writeSucceeded = true
                successMessage = isPay ? "Order placed." : (capturedRefundOnly ? "Refund requested." : "Cancellation requested.")
                actionMessage = nil
                onCompleted(orderID, best)
            } else if attemptedWrite {
                actionMessage = orderConfirmMutationSendAllowed(attempted: true, succeeded: false).1
            } else if rejected {
                actionMessage = isPay ? "Slant didn’t accept the payment request. Review the order before trying again." : "Slant didn’t accept the cancel request. Review the order before trying again."
            } else {
                switch outcome {
                case .priceChanged: actionMessage = "The price changed. Review the new total."
                case .statusBlocked(let reason): actionMessage = reason
                case .proceed: break
                }
            }
        }
    }
}

// MARK: - Pure helpers

func orderConfirmLoadStateAfterRun(succeeded: Bool, skippedBusy: Bool) -> OrderConfirmLoadState {
    if succeeded { return .loaded }
    if skippedBusy { return .loading }
    return .failed
}
func orderConfirmMutationSendAllowed(attempted: Bool, succeeded: Bool) -> (Bool, String?) {
    if succeeded { return (false, nil) }
    if attempted {
        return (false, "The result is unknown. Reload the order before trying again.")
    }
    return (true, nil)
}
func orderConfirmFinalActionEnabled(
    writeSucceeded: Bool,
    writeAttempted: Bool = false,
    loaded: Bool,
    status: String?,
    isPay: Bool,
    order: [String: Any]? = nil
) -> Bool {
    guard !writeSucceeded, !writeAttempted else { return false }
    if isPay { return workbenchChargeAllowed(status: status, loaded: loaded, order: order).0 }
    return orderCancelConfirmAllowed(status: status, loaded: loaded).0
}
func orderConfirmRecheck(method: String, shown: [String: Any], latest: [String: Any]) -> OrderConfirmRecheckResult {
    let status = (latest["status"] as? String) ?? ""
    let shownStatus = (shown["status"] as? String) ?? ""
    if method == "POST" {
        if status.uppercased() != "DRAFT" { return .statusBlocked("Only drafts can be placed.") }
        if !workbenchOrderHasNumericTotal(shown) || !workbenchOrderHasNumericTotal(latest) {
            return .statusBlocked("Couldn’t confirm a total for this order.")
        }
    } else {
        if shownStatus.uppercased() != status.uppercased() {
            return .statusBlocked("This order’s status changed. Review it again.")
        }
        if !orderCanRequestCancellation(status) {
            return .statusBlocked(orderCancellationBlockedReason(status) ?? "This order can’t be canceled.")
        }
    }
    if orderCostsChanged(shown: shown, latest: latest) { return .priceChanged }
    return .proceed
}
func orderConfirmRecheckAbortError(_ outcome: OrderConfirmRecheckResult) -> StudioError? {
    switch outcome {
    case .proceed: return nil
    case .priceChanged: return StudioError("The price changed. Review the new total.")
    case .statusBlocked(let reason): return StudioError(reason)
    }
}
func orderCostsChanged(shown: [String: Any], latest: [String: Any]) -> Bool {
    money(shown["printingCost"]) != money(latest["printingCost"])
        || money(shown["deliveryCost"]) != money(latest["deliveryCost"])
        || orderTotalMoney(shown) != orderTotalMoney(latest)
}
func orderBelongs(_ order: [String: Any], to id: String) -> Bool {
    let record = Record(values: order)
    return !id.isEmpty && (record.id == id || (order["publicId"] as? String) == id || (order["id"] as? String) == id)
}
func orderRecipientName(_ order: [String: Any]) -> String {
    if let address = ((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any],
       let name = address["name"] as? String, !name.isEmpty { return name }
    if let name = ((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["name"] as? String, !name.isEmpty { return name }
    return ""
}
func orderRecipientDisplay(_ order: [String: Any]) -> String {
    if let address = ((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any] {
        let parts = [address["name"], address["line1"], address["line2"], address["city"], address["state"], address["zip"], address["country"]].compactMap { $0 as? String }.filter { !$0.isEmpty }
        if !parts.isEmpty { return parts.joined(separator: ", ") }
    }
    return "—"
}
func orderCity(_ order: [String: Any]) -> String {
    (((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any])?["city"] as? String ?? ""
}
func orderCreatedDisplay(_ order: [String: Any]) -> String? {
    for key in ["createdAt", "created_at", "created", "dateCreated"] {
        if let value = order[key] as? String, !value.isEmpty { return orderDateLabel(value) }
    }
    return nil
}
func orderDateLabel(_ raw: String) -> String {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let fallback = ISO8601DateFormatter()
    if let date = iso.date(from: raw) ?? fallback.date(from: raw) {
        return date.formatted(date: .abbreviated, time: .omitted)
    }
    return raw
}
func orderListTitle(_ order: [String: Any]) -> String {
    let name = orderRecipientName(order)
    return name.isEmpty ? "Order" : name
}
func orderDetailCaption(_ order: [String: Any]) -> String {
    let name = orderRecipientName(order)
    let date = orderCreatedDisplay(order) ?? ""
    if !name.isEmpty, !date.isEmpty { return "Order for \(name) · \(date)" }
    if !name.isEmpty { return "Order for \(name)" }
    if !date.isEmpty { return date }
    return "Order details"
}
func orderMatchesSearch(_ order: Record, query: String) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    let values = orderObject(order.values)
    var fields = [
        order.string("publicId", "id"),
        orderStatusTitle(order.string("status")),
        orderRecipientName(values),
        orderCity(values)
    ]
    if let items = values["items"] as? [[String: Any]] {
        fields.append(contentsOf: items.map(orderItemDisplayName))
    }
    return fields.contains { $0.localizedCaseInsensitiveContains(trimmed) }
}

let orderKnownStatuses: Set<String> = [
    "DRAFT", "PAID", "QUEUED", "PROCESSING", "PRINTING", "ITEMS_ON_SHELF", "POST_PROCESSING",
    "COMPLETED", "IN_REVIEW", "AWAITING_SHIPMENT", "SHIPPED", "DELIVERED", "CANCELED", "PAYMENT_ERROR"
]

func orderCanRequestCancellation(_ status: String) -> Bool {
    let normalized = status.uppercased()
    guard orderKnownStatuses.contains(normalized) else { return false }
    return normalized != "CANCELED"
}
func orderCancellationIsRefundOnly(_ status: String) -> Bool {
    ["SHIPPED", "DELIVERED"].contains(status.uppercased())
}
func orderCancellationBlockedReason(_ status: String) -> String? {
    if orderCanRequestCancellation(status) { return nil }
    switch status.uppercased() {
    case "CANCELED": return "This order was already canceled."
    case "": return "This order can’t be canceled."
    default: return "This order can’t be canceled."
    }
}
func orderCancelConfirmAllowed(status: String?, loaded: Bool) -> (Bool, String?) {
    guard loaded else { return (false, "Couldn’t load this order.") }
    guard let status, orderCanRequestCancellation(status) else {
        return (false, orderCancellationBlockedReason(status ?? "") ?? "This order can’t be canceled.")
    }
    return (true, nil)
}
/// Toolbar / detail button title (includes ellipsis).
func orderCancelActionTitle(_ status: String) -> String {
    orderCancelButtonBaseTitle(status) + "…"
}
/// In-sheet confirm button title (no ellipsis).
func orderCancelSheetButtonTitle(_ status: String) -> String {
    orderCancelButtonBaseTitle(status)
}
func orderCancelButtonBaseTitle(_ status: String) -> String {
    switch status.uppercased() {
    case "DRAFT": return "Cancel Draft"
    case "SHIPPED", "DELIVERED": return "Request Refund"
    case "QUEUED", "PRINTING", "AWAITING_SHIPMENT", "PROCESSING", "PAID", "IN_REVIEW",
         "POST_PROCESSING", "ITEMS_ON_SHELF", "COMPLETED":
        return "Cancel & Refund"
    case "PAYMENT_ERROR": return "Cancel Order"
    default: return "Cancel Order"
    }
}
func orderCancelSheetTitle(_ status: String) -> String {
    switch status.uppercased() {
    case "DRAFT": return "Cancel this draft?"
    case "SHIPPED", "DELIVERED": return "Request a refund?"
    default: return "Cancel this order?"
    }
}
func orderCancelSheetBody(_ status: String) -> String {
    switch status.uppercased() {
    case "DRAFT": return "Nothing has been charged."
    case "SHIPPED", "DELIVERED":
        return "This order already shipped, so Slant refunds it but can't stop delivery."
    case "PAYMENT_ERROR":
        return "Cancellation may be possible. A refund isn’t promised for payment-problem orders."
    case "QUEUED", "PRINTING", "AWAITING_SHIPMENT", "PROCESSING", "PAID", "IN_REVIEW",
         "POST_PROCESSING", "ITEMS_ON_SHELF", "COMPLETED":
        return "Slant will cancel when eligible and refund according to their rules."
    default:
        return "Cancellation may be possible. A refund isn’t promised for this status."
    }
}
func orderStatusTitle(_ status: String) -> String {
    switch status.uppercased() {
    case "DRAFT": "Draft"
    case "PAID": "Paid"
    case "QUEUED": "In queue"
    case "PROCESSING": "Processing"
    case "PRINTING": "Printing"
    case "ITEMS_ON_SHELF": "On the shelf"
    case "POST_PROCESSING": "Finishing"
    case "COMPLETED": "Printed"
    case "IN_REVIEW": "In review"
    case "AWAITING_SHIPMENT": "Awaiting shipment"
    case "SHIPPED": "Shipped"
    case "DELIVERED": "Delivered"
    case "CANCELED": "Canceled"
    case "PAYMENT_ERROR": "Payment problem"
    case "": "Order"
    default: status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
func isEmailAddress(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return false }
    return trimmed.range(of: #"^[A-Z0-9a-z._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}$"#, options: .regularExpression) != nil
}
func isCountryCode(_ value: String) -> Bool {
    value.trimmingCharacters(in: .whitespacesAndNewlines).range(of: #"^[A-Za-z]{2}$"#, options: .regularExpression) != nil
}
func normalizedCountryCode(_ value: String) throws -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard isCountryCode(trimmed) else { throw StudioError("Enter a two-letter country code like US or AU.") }
    return trimmed
}
func isHTTPSImageURL(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    guard let components = URLComponents(string: trimmed), components.scheme?.lowercased() == "https",
          let host = components.host, !host.isEmpty else { return false }
    return true
}
func orderItemDisplayName(_ item: [String: Any]) -> String {
    if let name = item["name"] as? String, !name.isEmpty { return name }
    if let printItem = item["printItem"] as? [String: Any], let name = printItem["name"] as? String, !name.isEmpty { return name }
    if let component = item["componentItem"] as? [String: Any], let name = component["componentName"] as? String, !name.isEmpty { return name }
    if let name = item["componentName"] as? String, !name.isEmpty { return name }
    if let stationery = item["stationeryItem"] as? [String: Any], let name = stationery["stationeryName"] as? String, !name.isEmpty { return name }
    if let name = item["stationeryName"] as? String, !name.isEmpty { return name }
    if let type = item["type"] as? String, !type.isEmpty { return type.replacingOccurrences(of: "_", with: " ").capitalized }
    return "Item"
}
func orderItemMaterialName(_ item: [String: Any], filaments: [Record] = []) -> String? {
    if let name = item["filamentName"] as? String, !name.isEmpty { return name }
    if let material = item["material"] as? String, !material.isEmpty { return material }
    if let filament = item["filament"] as? [String: Any], let name = filament["name"] as? String, !name.isEmpty { return name }
    if let printItem = item["printItem"] as? [String: Any] {
        if let name = printItem["filamentName"] as? String, !name.isEmpty { return name }
        if let id = printItem["filamentId"] as? String, !id.isEmpty,
           let match = filaments.first(where: { $0.id == id }) {
            return displayName(for: match, fallback: match.name)
        }
    }
    if let id = item["filamentId"] as? String, !id.isEmpty, let match = filaments.first(where: { $0.id == id }) {
        return displayName(for: match, fallback: match.name)
    }
    return nil
}
func orderTotalMoney(_ order: [String: Any]) -> String {
    if order["total"] != nil { return money(order["total"]) }
    if order["totalCost"] != nil { return money(order["totalCost"]) }
    let print = decimalAmount(order["printingCost"])
    let delivery = decimalAmount(order["deliveryCost"])
    if let print, let delivery { return money(NSDecimalNumber(decimal: print + delivery).stringValue) }
    if let print { return money(NSDecimalNumber(decimal: print).stringValue) }
    if let delivery { return money(NSDecimalNumber(decimal: delivery).stringValue) }
    return "—"
}
func decimalAmount(_ value: Any?) -> Decimal? {
    guard let value, !(value is NSNull) else { return nil }
    if let number = value as? NSNumber { return number.decimalValue }
    return Decimal(string: String(describing: value), locale: Locale(identifier: "en_US_POSIX"))
}
func trackingFacts(_ fulfillment: Any?) -> [(String, String)] {
    guard let object = fulfillment as? [String: Any] else { return [] }
    var rows: [(String, String)] = []
    if let provider = stringValue(object["provider"]) ?? stringValue(object["carrier"]), !provider.isEmpty {
        rows.append(("Carrier", provider))
    }
    if let method = stringValue(object["deliveryMethod"]) ?? stringValue(object["service"]), !method.isEmpty {
        rows.append(("Service", method))
    }
    if let shipmentStatus = stringValue(object["status"]) ?? stringValue(object["providerStatus"]), !shipmentStatus.isEmpty {
        rows.append(("Shipment status", shipmentStatus))
    }
    if let numbers = object["trackingNumbers"] as? [String] {
        for number in numbers where !number.isEmpty { rows.append(("Tracking number", number)) }
    } else if let numbers = object["trackingNumbers"] as? [Any] {
        for value in numbers {
            if let number = stringValue(value), !number.isEmpty { rows.append(("Tracking number", number)) }
        }
    }
    if !rows.contains(where: { $0.0 == "Tracking number" }) {
        for key in ["trackingNumber", "tracking_number"] {
            if let number = stringValue(object[key]), !number.isEmpty {
                rows.append(("Tracking number", number))
                break
            }
        }
    }
    for key in ["trackingUrl", "trackingURL", "url"] {
        if let url = stringValue(object[key]), !url.isEmpty {
            rows.append(("Tracking link", url))
            break
        }
    }
    return rows
}
func stringValue(_ value: Any?) -> String? {
    guard let value, !(value is NSNull) else { return nil }
    if let text = value as? String { return text }
    return String(describing: value)
}
func fulfillmentArriveBy(_ order: [String: Any]) -> String? {
    if let arrive = order["arriveByDate"] as? String, !arrive.isEmpty { return orderDateLabel(arrive) }
    if let fulfillment = order["fulfillment"] as? [String: Any] {
        for key in ["arriveByDate", "arrive_by", "estimatedDelivery", "estimated_delivery"] {
            if let value = fulfillment[key] as? String, !value.isEmpty { return orderDateLabel(value) }
        }
    }
    return nil
}
func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}
func orderNumber(_ order: [String: Any]) -> String {
    if let publicId = order["publicId"] as? String, !publicId.isEmpty { return publicId }
    if let id = order["id"] as? String, !id.isEmpty { return id }
    return Record(values: order).id
}

// MARK: - Reorder, unsaved input and quantity review

/// What the composer opens with. Old prices are never carried over: Slant prices the new draft when it is created,
/// and placing it still goes through the explicit charge review.
struct OrderComposerPrefill {
    var lines: [OrderLine]
    var delivery: DeliveryDetails? = nil
    /// Human-readable descriptions of source items that could not be copied.
    var skippedItems: [String] = []
    var sourceOrderNumber: String? = nil
    var shippingProvider = ""
    var platformID: String? = nil
}

private func reorderText(_ value: Any?) -> String {
    (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// First non-empty string for `key` on the item, then on its nested `printItem` / `componentItem` / `stationeryItem`.
private func reorderField(_ item: [String: Any], _ keys: [String], nested: String?) -> String {
    for key in keys {
        let flat = reorderText(item[key])
        if !flat.isEmpty { return flat }
    }
    if let nested, let inner = item[nested] as? [String: Any] {
        for key in keys {
            let value = reorderText(inner[key])
            if !value.isEmpty { return value }
        }
    }
    return ""
}

/// Whole-number quantity from an order item, or nil if missing, fractional, boolean or not a number.
func orderItemQuantity(_ item: [String: Any]) -> Int? {
    switch item["quantity"] {
    case let number as NSNumber:
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.rounded() == value, abs(value) < Double(Int.max) else { return nil }
        return number.intValue
    case let text as String:
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
    default:
        return nil
    }
}

/// The item type to reorder as: the declared type, otherwise inferred from which reference is present.
func orderItemReorderType(_ item: [String: Any]) -> String? {
    let declared = reorderText(item["type"]).uppercased()
    if ["PRINT", "COMPONENT", "STATIONERY"].contains(declared) { return declared }
    guard declared.isEmpty else { return nil }
    if item["printItem"] is [String: Any] || !reorderText(item["publicFileServiceId"]).isEmpty { return "PRINT" }
    if item["componentItem"] is [String: Any] || !reorderText(item["componentId"]).isEmpty { return "COMPONENT" }
    if item["stationeryItem"] is [String: Any] || !reorderText(item["stationeryId"]).isEmpty { return "STATIONERY" }
    return nil
}

/// Maps a past order's items to new, editable composer lines. Prices are ignored.
/// Items without a usable reference are returned in `skipped` so the composer can say what wasn't copied.
func orderLinesForReorder(_ order: Record) -> (lines: [OrderLine], skipped: [String]) {
    let values = orderObject(order.values)
    let items = values["items"] as? [[String: Any]] ?? []
    var lines: [OrderLine] = []
    var skipped: [String] = []
    for item in items {
        let title = "“\(orderItemDisplayName(item))”"
        guard let type = orderItemReorderType(item) else {
            skipped.append("\(title): this item type can’t be reordered here.")
            continue
        }
        let nested: String
        let referenceKey: String
        let missing: String
        switch type {
        case "PRINT": (nested, referenceKey, missing) = ("printItem", "publicFileServiceId", "uploaded model")
        case "COMPONENT": (nested, referenceKey, missing) = ("componentItem", "componentId", "component")
        default: (nested, referenceKey, missing) = ("stationeryItem", "stationeryId", "stationery")
        }
        let reference = reorderField(item, [referenceKey], nested: nested)
        guard !reference.isEmpty else {
            skipped.append("\(title): the order doesn’t include its \(missing) ID.")
            continue
        }
        var line = OrderLine()
        line.type = type
        line.reference = reference
        if let quantity = orderItemQuantity(item), quantity > 0 { line.quantity = quantity }
        line.name = reorderField(item, ["name"], nested: nested)
        line.sku = reorderField(item, ["SKU", "sku"], nested: nested)
        if type == "PRINT" { line.filamentID = reorderField(item, ["filamentId"], nested: nested) }
        if type == "STATIONERY" {
            let image = reorderField(item, ["imageUrl"], nested: nested)
            if isHTTPSImageURL(image) { line.imageURL = image }
        }
        if let options = item["options"] as? [String: Any], !options.isEmpty,
           JSONSerialization.isValidJSONObject(options),
           let data = try? JSONSerialization.data(withJSONObject: options, options: [.sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            line.optionsJSON = text
        }
        lines.append(line)
    }
    return (lines, skipped)
}

/// Country picker state for an address country from Slant. Accepts an ISO code or an exact English/local country name;
/// anything else leaves the country unselected so the user chooses it. Never falls back to US or the Mac region.
func orderCountrySelection(fromAddressCountry value: Any?, locale: Locale = .current) -> (selection: String, customCode: String) {
    let trimmed = reorderText(value)
    guard !trimmed.isEmpty else { return ("", "") }
    if isCountryCode(trimmed) { return defaultDeliveryCountry(regionCode: trimmed) }
    let english = Locale(identifier: "en_US")
    for region in Locale.Region.isoRegions where isCountryCode(region.identifier) {
        let code = region.identifier
        for candidate in [english, locale] {
            if let name = candidate.localizedString(forRegionCode: code),
               name.compare(trimmed, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
                return defaultDeliveryCountry(regionCode: code)
            }
        }
    }
    return ("", "")
}

/// Delivery details copied from a past order's shipping address, or nil if it has none.
func deliveryDetails(fromOrder order: [String: Any]) -> DeliveryDetails? {
    let values = orderObject(order)
    let details = (values["customer"] as? [String: Any])?["details"] as? [String: Any] ?? [:]
    let address = details["address"] as? [String: Any] ?? [:]
    var delivery = DeliveryDetails()
    delivery.email = reorderText(details["email"])
    delivery.name = reorderText(address["name"])
    if delivery.name.isEmpty { delivery.name = reorderText(details["name"]) }
    delivery.line1 = reorderText(address["line1"])
    delivery.line2 = reorderText(address["line2"])
    delivery.city = reorderText(address["city"])
    delivery.state = reorderText(address["state"])
    delivery.zip = reorderText(address["zip"])
    let country = orderCountrySelection(fromAddressCountry: address["country"])
    delivery.countrySelection = country.selection
    delivery.customCountry = country.customCode
    let copied = [delivery.email, delivery.name, delivery.line1, delivery.city, delivery.zip]
    return copied.allSatisfy(\.isEmpty) ? nil : delivery
}

/// Composer prefill for "Duplicate as New Draft". Metadata is not copied because it often holds per-order references.
func orderComposerPrefill(reordering order: Record) -> OrderComposerPrefill {
    let values = orderObject(order.values)
    let mapped = orderLinesForReorder(order)
    let provider = reorderText((values["options"] as? [String: Any])?["shippingProvider"]).uppercased()
    let platform = reorderText(values["platformId"])
    let number = orderNumber(values)
    return OrderComposerPrefill(
        lines: mapped.lines,
        delivery: deliveryDetails(fromOrder: values),
        skippedItems: mapped.skipped,
        sourceOrderNumber: number.isEmpty ? nil : number,
        shippingProvider: orderShippingProviderChoices.contains { !$0.code.isEmpty && $0.code == provider } ? provider : "",
        platformID: platform.isEmpty ? nil : platform
    )
}

/// Lines the composer opens with: prefilled lines, a blank line for a duplicate with nothing copyable (never an
/// unrelated selected model), otherwise the caller's default line.
func orderComposerInitialLines(prefill: OrderComposerPrefill?, defaultLine: () -> OrderLine) -> [OrderLine] {
    if let lines = prefill?.lines, !lines.isEmpty { return lines }
    if prefill?.sourceOrderNumber != nil { return [OrderLine()] }
    return [defaultLine()]
}

enum OrderComposerDeliverySeed: Equatable {
    case copiedFromOrder(DeliveryDetails)
    case lastUsed(DeliveryDetails)
    /// `missingFromSourceOrder` is true for a duplicate whose order had no address to copy.
    case blank(missingFromSourceOrder: Bool)
}

/// A duplicate uses only its source order's address; it never falls back to another order's address from this session.
func orderComposerDeliverySeed(prefill: OrderComposerPrefill?, lastDelivery: DeliveryDetails?) -> OrderComposerDeliverySeed {
    if let copied = prefill?.delivery { return .copiedFromOrder(copied) }
    if prefill?.sourceOrderNumber != nil { return .blank(missingFromSourceOrder: true) }
    if let lastDelivery { return .lastUsed(lastDelivery) }
    return .blank(missingFromSourceOrder: false)
}

/// Why "Duplicate as New Draft" is unavailable, or nil when it can open the composer.
func orderDuplicateBlockedReason(draftBlockedReason: String?, composerOpen: Bool, outcomeUnknown: Bool, busy: Bool) -> String? {
    if let draftBlockedReason { return draftBlockedReason }
    if outcomeUnknown { return unknownOutcomeBlockMessage }
    if composerOpen { return "Finish or close the open order draft first." }
    if busy { return "Working…" }
    return nil
}

/// A print line whose model isn't among the account's uploaded models (for example, deleted since the source order).
/// Only judged when the complete file list is loaded, so a partial page never produces a false warning.
func orderLineModelLooksMissing(_ line: OrderLine, files: [Record], filesFullyLoaded: Bool) -> Bool {
    guard filesFullyLoaded, line.type == "PRINT" else { return false }
    let reference = line.reference.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !reference.isEmpty else { return false }
    return !files.contains { $0.id == reference }
}

func orderLinesHaveSameContent(_ lhs: [OrderLine], _ rhs: [OrderLine]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    return zip(lhs, rhs).allSatisfy { a, b in
        a.type == b.type && a.reference == b.reference && a.filamentID == b.filamentID && a.quantity == b.quantity
            && a.imageURL == b.imageURL && a.name == b.name && a.sku == b.sku && a.optionsJSON == b.optionsJSON
    }
}

/// True when closing the composer would lose something the user entered: lines or delivery changed from what the
/// form opened with, or metadata / payment ID typed.
func orderComposerHasUnsavedInput(
    lines: [OrderLine], initialLines: [OrderLine],
    delivery: DeliveryDetails, initialDelivery: DeliveryDetails,
    metadataFields: [OrderMetadataField], paymentID: String
) -> Bool {
    if !orderLinesHaveSameContent(lines, initialLines) { return true }
    if delivery != initialDelivery { return true }
    if metadataFields.contains(where: { !$0.key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) { return true }
    return !paymentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// Quantities at or above this are highlighted. Most print-on-demand lines are single or low double digits, so 25
/// catches an extra zero on 3–10 (30–100) and similar slips while leaving dozen-scale batches unflagged.
/// It is a visual check only; legitimate bulk orders still proceed through the normal review.
let orderLargeQuantityThreshold = 25

func isLargeOrderQuantity(_ quantity: Int, threshold: Int = orderLargeQuantityThreshold) -> Bool {
    threshold > 0 && quantity >= threshold
}

func largeQuantityLines(_ lines: [OrderLine], threshold: Int = orderLargeQuantityThreshold) -> [OrderLine] {
    lines.filter { isLargeOrderQuantity($0.quantity, threshold: threshold) }
}

func orderItemHasLargeQuantity(_ item: [String: Any], threshold: Int = orderLargeQuantityThreshold) -> Bool {
    orderItemQuantity(item).map { isLargeOrderQuantity($0, threshold: threshold) } ?? false
}

/// Review-sheet banner text when any item quantity is unusually high.
func largeQuantityReviewWarning(_ items: [[String: Any]], threshold: Int = orderLargeQuantityThreshold) -> String? {
    let count = items.filter { orderItemHasLargeQuantity($0, threshold: threshold) }.count
    guard count > 0 else { return nil }
    let subject = count == 1 ? "1 item has" : "\(count) items have"
    return "Check quantities: \(subject) a quantity of \(threshold) or more."
}

func largeQuantityComposerWarning(_ quantity: Int, threshold: Int = orderLargeQuantityThreshold) -> String? {
    guard isLargeOrderQuantity(quantity, threshold: threshold) else { return nil }
    return "Quantity \(quantity) is unusually high. Check it before creating the draft."
}

// MARK: - Complete country list

/// Codes in `Locale.Region.isoRegions` that are not ISO 3166-1 countries or territories a parcel ships to.
let orderNonCountryRegionCodes: Set<String> = ["AC", "CP", "CQ", "DG", "EA", "EU", "EZ", "IC", "QO", "TA", "UN"]

/// Every other country, sorted by localized name, for the picker below the shortlist.
func orderOtherCountryChoices(locale: Locale = .current) -> [(code: String, name: String)] {
    let shortlist = Set(orderCountryChoices.map(\.code))
    return Locale.Region.isoRegions.map(\.identifier)
        .filter { isCountryCode($0) && !orderNonCountryRegionCodes.contains($0) && !shortlist.contains($0) }
        .map { (code: $0, name: locale.localizedString(forRegionCode: $0) ?? $0) }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
}
let orderOtherCountryChoicesForCurrentLocale = orderOtherCountryChoices()

/// The single country picker shows one code; the stored model keeps shortlist codes in `countrySelection` and other
/// codes under the "Other" tag in `customCountry`.
func orderCountryPickerValue(_ delivery: DeliveryDetails) -> String {
    delivery.countrySelection == orderCountryOtherTag
        ? delivery.customCountry.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        : delivery.countrySelection
}

func deliveryApplyingCountryPick(_ code: String, to delivery: DeliveryDetails) -> DeliveryDetails {
    var result = delivery
    let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    if trimmed.isEmpty {
        result.countrySelection = ""
        result.customCountry = ""
    } else if orderCountryChoices.contains(where: { $0.code == trimmed }) {
        result.countrySelection = trimmed
        result.customCountry = ""
    } else {
        result.countrySelection = orderCountryOtherTag
        result.customCountry = trimmed
    }
    return result
}

struct OrderSummary: View {
    @EnvironmentObject var store: StudioStore
    let order: [String: Any]
    var status: String { order["status"] as? String ?? "" }
    var tracking: [(String, String)] { trackingFacts(order["fulfillment"]) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let items = order["items"] as? [[String: Any]], !items.isEmpty {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("\(item["quantity"].map { String(describing: $0) } ?? "1") × \(orderItemDisplayName(item))")
                            Spacer()
                            if item["price"] != nil { Text(money(item["price"])) }
                        }
                        if let material = orderItemMaterialName(item, filaments: store.filaments) {
                            Text("Material: \(material)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else {
                Text("Item details appear after the draft is calculated.").foregroundStyle(.secondary)
            }
            if let address = ((order["customer"] as? [String: Any])?["details"] as? [String: Any])?["address"] as? [String: Any] {
                Text([address["name"], address["line1"], address["line2"], address["city"], address["state"], address["zip"], address["country"]].compactMap { $0 as? String }.filter { !$0.isEmpty }.joined(separator: ", "))
                    .font(.callout).foregroundStyle(.secondary)
            }
            LabeledContent("Print cost") { Text(money(order["printingCost"])) }
            LabeledContent("Delivery cost") { Text(money(order["deliveryCost"])) }
            LabeledContent("Total") { Text(orderTotalMoney(order)).fontWeight(.semibold) }
            let number = orderNumber(order)
            if !number.isEmpty {
                HStack {
                    Text("Order number \(number)")
                    Button { copyToPasteboard(number) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy order number").help("Copy order number")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Divider()
            Text("Tracking").font(.headline)
            if tracking.isEmpty {
                Text("No tracking yet.").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(tracking.enumerated()), id: \.offset) { _, row in
                    HStack {
                        Text(row.0).foregroundStyle(.secondary)
                        Spacer()
                        if row.0 == "Tracking link", let url = URL(string: row.1) {
                            Link(row.1, destination: url)
                        } else {
                            Text(row.1).textSelection(.enabled)
                        }
                        if row.0 == "Tracking number" {
                            Button { copyToPasteboard(row.1) } label: { Image(systemName: "doc.on.doc") }
                                .accessibilityLabel("Copy tracking number").help("Copy tracking number")
                        }
                    }
                }
            }
            if let arrive = fulfillmentArriveBy(order) {
                LabeledContent("Arrive by") { Text(arrive) }
            }
            DisclosureGroup("Technical details") { JSONView(text: prettyJSON(hidingSecrets(order))).frame(height: 220) }
        }
    }
}
