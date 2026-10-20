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
                Button("Cancel", role: .cancel) { dismiss() }
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
        .onAppear(perform: seedIfNeeded)
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
            orderStateIsRequired(delivery.countrySelection == orderCountryOtherTag ? delivery.customCountry : delivery.countrySelection)
                ? "State / province"
                : "State / province (optional)",
            text: $delivery.state
        )
        TextField("Postal code", text: $delivery.zip)
        Picker("Country", selection: $delivery.countrySelection) {
            Text("Choose a country").tag("")
            ForEach(orderCountryChoices, id: \.code) { Text($0.name).tag($0.code) }
            Text("Other…").tag(orderCountryOtherTag)
        }
        if delivery.countrySelection == orderCountryOtherTag {
            Text("Enter the two-letter country code used for shipping (for example US or AU).").font(.caption).foregroundStyle(.secondary)
            TextField("Country code", text: $delivery.customCountry)
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
            if item.wrappedValue.type == "PRINT" {
                catalogOrLoad(kind: .models, empty: store.files.isEmpty, hasSelection: !item.wrappedValue.reference.isEmpty) {
                    orderCatalogPicker("Model", selection: item.reference, records: store.files, placeholder: "Choose an uploaded model")
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

    func seedIfNeeded() {
        if draftPlatformID.isEmpty { draftPlatformID = store.platformID }
        if lines.isEmpty {
            var filament = store.filamentID
            if filament.isEmpty, let fallback = store.defaultFilamentID { filament = fallback }
            lines = [store.pendingOrderLine ?? OrderLine(reference: store.fileID, filamentID: filament, quantity: store.quantity)]
            store.pendingOrderLine = nil
        }
        if let saved = store.lastDelivery {
            delivery = saved
            seededDelivery = true
            editingDelivery = false
        }
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
            let country: String
            if delivery.countrySelection == orderCountryOtherTag {
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
                store.lastDelivery = delivery
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
    var finalActionEnabled: Bool {
        orderConfirmFinalActionEnabled(
            writeSucceeded: writeSucceeded,
            writeAttempted: writeAttempted,
            loaded: loadState == .loaded,
            status: status,
            isPay: isPay,
            order: fresh
        ) && !writing && !store.busy
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
                            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                                Text("\(item["quantity"].map { String(describing: $0) } ?? "1") × \(orderItemDisplayName(item))")
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
                } else if writeAttempted {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let reason = mutationLock.1 {
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
                fresh = mergeOrderDraftEnvelope(responseObject(response))
                succeeded = true
            }
            loadState = orderConfirmLoadStateAfterRun(succeeded: succeeded, skippedBusy: !ran)
            if !ran { awaitingBusy = true }
            if keepUnknownMessage, writeAttempted, !writeSucceeded {
                actionMessage = orderConfirmMutationSendAllowed(attempted: true, succeeded: false).1
            }
        }
    }
    func confirmAction() {
        guard let shown = fresh, !writeSucceeded, !writeAttempted, !writing else { return }
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
            let ran = await store.run(isPay ? "Process order" : "Cancel order") {
                let preview = try await store.client.request("GET", path: "/orders/\(encodedSegment(orderID))")
                let latest = mergeOrderDraftEnvelope(responseObject(preview))
                latestOrder = latest
                outcome = orderConfirmRecheck(method: method, shown: shown, latest: latest)
                if let abort = orderConfirmRecheckAbortError(outcome) { throw abort }
                attemptedWrite = true
                writeAttempted = true
                capturedRefundOnly = successRefundOnly
                let mutateResponse = try await store.client.request(method, path: "/orders/\(encodedSegment(orderID))")
                mutateOrder = mergeOrderDraftEnvelope(responseObject(mutateResponse))
                didWrite = true
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
