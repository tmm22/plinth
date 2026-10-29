import SwiftUI
import AppKit

struct OrderLine: Identifiable, Equatable {
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

/// Merge draft envelope `items` / `totals` / `customer` into the order record (order fields win). The `totals` object
/// itself is kept too, so the pay review can see any cost in it that Studio doesn't add (`orderUnlistedCosts`).
func mergeOrderDraftEnvelope(_ data: [String: Any]) -> [String: Any] {
    var order = orderObject(data)
    if order["items"] == nil, let items = data["items"] { order["items"] = items }
    if order["customer"] == nil, let customer = data["customer"] { order["customer"] = customer }
    if order["totals"] == nil, let totals = data["totals"] { order["totals"] = totals }
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
    guard fields.count <= 10 else { throw StudioError("Add up to 10 reference fields (metadata).") }
    var result: [String: Any] = [:]
    var seen = Set<String>()
    for field in fields {
        let key = field.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw StudioError("Give every reference field (metadata) a key.") }
        guard !seen.contains(key) else { throw StudioError("Each reference field (metadata) needs a different key.") }
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
/// Shortlisted countries, in this order, above the full list.
let orderCountryShortlistCodes = ["US", "CA", "GB", "AU", "NZ", "IE", "DE", "FR", "NL", "JP"]
/// The shortlist with names localized like the full list.
func orderCountryShortlist(locale: Locale = .current) -> [(code: String, name: String)] {
    orderCountryShortlistCodes.map { (code: $0, name: locale.localizedString(forRegionCode: $0) ?? $0) }
}
let orderCountryChoices = orderCountryShortlist()
/// Region is a convenient editable default, not a claim about the user's physical location.
func defaultDeliveryCountry(regionCode: String? = Locale.current.region?.identifier) -> (selection: String, customCode: String) {
    let code = (regionCode ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    // Codes such as "EU" or "UN" are ISO regions but not delivery countries; leave the country unselected.
    guard isCountryCode(code), !orderNonCountryRegionCodes.contains(code),
          Locale.Region.isoRegions.contains(where: { $0.identifier == code }) else {
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
    @FocusState private var postcodeFocused: Bool
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
    @State private var platformNotCopied = false
    @State private var initialShippingProvider = ""
    @State private var initialDraftPlatformID = ""
    @State private var confirmDiscard = false
    @State private var showAddSavedProduct = false
    @State private var confirmCreateAnyway = false
    @State private var advancedExpanded = false
    /// Use My Address asks before replacing details already in the form (SellerAddress.swift).
    @State private var confirmUseMyAddress = false
    /// The country was chosen in the picker (not the Mac-region default), so replacing it needs confirmation too.
    @State private var countryPicked = false
    // Paste Address… (AddressPaste.swift): the popover and its starting text, in memory only and cleared once
    // the popover closes.
    @State private var showAddressPaste = false
    @State private var addressPasteText = ""
    /// The clipboard held text that doesn't look like an address, so the box started empty (AddressPaste.swift).
    @State private var addressPasteSkippedClipboard = false
    /// When a popover last closed: an Escape that closed it must not also reach the composer's Cancel.
    @State private var popoverClosedAt: Date?
    /// Catalog loads started here that failed: shown in the form, since the window's alert waits behind the sheet.
    @State private var catalogLoadError: String?
    /// Check Slant's last result for unconfirmed drafts (DraftConfirmation.swift).
    @State private var draftCheckOutcome: DraftCreateCheckOutcome?

    var composerPopoverShown: Bool { showAddressPaste || showAddSavedProduct }
    var hasUnsavedInput: Bool {
        orderComposerHasUnsavedInput(
            lines: lines, initialLines: initialLines, delivery: delivery, initialDelivery: initialDelivery,
            metadataFields: metadataFields, paymentID: paymentID,
            shippingProvider: shippingProvider, initialShippingProvider: initialShippingProvider,
            platformID: draftPlatformID, initialPlatformID: initialDraftPlatformID
        )
    }
    var emailFieldError: String? {
        let trimmed = delivery.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return showEmailError ? "Enter an email like name@example.com." : nil }
        return isEmailAddress(delivery.email) ? nil : "Enter an email like name@example.com."
    }
    /// Advisory only: never blocks Create Draft.
    /// Waits while the field is being typed in, until the postcode is long enough to judge.
    var postcodeWarning: String? {
        postcodeFormatWarning(delivery.zip, country: orderCountryPickerValue(delivery), whileEditing: postcodeFocused)
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
        VStack(spacing: 0) {
            // A sheet shows no window title, so the form carries its own heading.
            Text(orderComposerHeading(sourceOrderNumber: sourceOrderNumber))
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 16)
            composerForm
        }
        .navigationTitle(orderComposerHeading(sourceOrderNumber: sourceOrderNumber))
        .frame(minWidth: 720, minHeight: 640)
        // A Create Draft problem note goes once the items or address change; the next Create checks again.
        .onChange(of: lines) { validation = nil }
        .onChange(of: delivery) { validation = nil }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Cancel", role: .cancel) { requestClose(fromCancelButton: true) }
                    // Escape belongs to an open popover (Paste Address…, Add Saved Product…) first: it must close only
                    // that popover, never the whole composer as well.
                    .keyboardShortcut(composerPopoverShown ? nil : .cancelAction)
                    .disabled(store.busy)
                    .help(store.busy ? "Working…" : "Cancel")
                Spacer()
                if let validation {
                    Text(validation).font(.caption).foregroundStyle(.orange).lineLimit(4).help(validation)
                        .fixedSize(horizontal: false, vertical: true)
                }
                else if let createBlockedReason { Text(createBlockedReason).font(.caption).foregroundStyle(.secondary) }
                if store.busy { ProgressView().controlSize(.small) }
                // No default-action shortcut: creating a draft always takes a click (Return in a field must never
                // send `POST /orders`, which Slant can't undo), as in Import Orders.
                Button("Create Draft") { createDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.busy || createBlockedReason != nil)
                    .help(createBlockedReason ?? "Create an order draft")
            }
            .padding(16)
            .background(.bar)
        }
        // Also while a popover is open, so an Escape meant for Paste Address or Add Saved Product never closes the sheet.
        .interactiveDismissDisabled(hasUnsavedInput || composerPopoverShown)
        // An Escape that reaches the sheet some other way (no text field focused, as in a duplicate's address
        // summary) takes the same path as Cancel: the popover guard and the discard check.
        // Like Cancel, it does nothing while a request runs.
        .onExitCommand {
            // An Escape that reaches the sheet while a popover is open closes only the popover.
            if composerPopoverShown { showAddressPaste = false; showAddSavedProduct = false }
            else if !store.busy { requestClose(fromCancelButton: true) }
        }
        .confirmationDialog("Discard this order draft?", isPresented: $confirmDiscard) {
            Button("Discard Draft", role: .destructive) { dismiss() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text(orderComposerDiscardMessage(outcomeUnknown: store.draftCreateOutcomeUnknown))
        }
        .confirmationDialog("Replace the delivery details?", isPresented: $confirmUseMyAddress, titleVisibility: .visible) {
            Button("Use My Address") { applyMyAddress() }
            // Return keeps what's in the form.
            Button("Keep Current Details", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text("The name, email and address in this draft are replaced with your saved address.")
        }
        .confirmationDialog("Create another draft?", isPresented: $confirmCreateAnyway, titleVisibility: .visible) {
            Button("Create Anyway") { createDraft(confirmedDespiteUnknownOutcome: true) }
            Button("Don’t Create", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(draftCreateAnywayMessage(store.unconfirmedDraftCreates, earlierUnlisted: store.unconfirmedDraftCreatesOverflowed))
        }
        .onAppear(perform: seedIfNeeded)
        // Pasted text goes as soon as the popover closes, however it closed.
        .onChange(of: showAddressPaste) { _, shown in
            if !shown { addressPasteText = ""; addressPasteSkippedClipboard = false; popoverClosedAt = Date() }
        }
        .onChange(of: showAddSavedProduct) { _, shown in if !shown { popoverClosedAt = Date() } }
        // Pending location work stops whenever the form actually closes (create, cancel or discard).
        .onDisappear { locationLookup.cancel() }
        .task(id: catalogTaskID) { await loadNeededCatalogs() }
        .task { await store.refreshFilamentsIfStale() }
    }

    var composerForm: some View {
        Form {
            if store.draftCreateOutcomeUnknown || draftCheckOutcome != nil {
                Section {
                    UnconfirmedDraftNotice(outcome: $draftCheckOutcome) { record in showFoundDraft(record) }
                }
            }
            if sourceOrderNumber != nil {
                Section("Copied from the original order") {
                    Text("Items and delivery details were copied for you to check. Slant calculates new prices when you create the draft, and you review the total before anything is charged.")
                        .font(.callout).foregroundStyle(.secondary)
                    if lines.allSatisfy({ $0.reference.isEmpty }) {
                        Text("No items could be copied. Choose them below.").font(.callout).foregroundStyle(.orange)
                    }
                    if lines.contains(where: { !orderLineOptionsSummary($0.optionsJSON).isEmpty }) {
                        Text("Some items include options copied from the original order. Check them under each item.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    if !deliveryCopied {
                        Text("This order had no delivery details to copy. Enter them below.").font(.callout).foregroundStyle(.orange)
                    }
                    if platformNotCopied {
                        Text(initialDraftPlatformID.isEmpty
                             ? "This order’s platform isn’t in your platform list. Choose a platform under More options."
                             : "This order’s platform isn’t in your platform list, so the draft uses your current platform. Check it under More options.")
                            .font(.callout).foregroundStyle(.orange)
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
                if let catalogLoadError {
                    Label(catalogLoadError, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach($lines) { $item in
                    orderItemEditor($item)
                }
                Button { lines.append(OrderLine()) } label: { Label("Add Another Item", systemImage: "plus") }
                Button { showAddSavedProduct = true } label: { Label("Add Saved Product…", systemImage: "shippingbox") }
                    .help("Add the items of a product you’ve saved, for a number of units sold")
                    .popover(isPresented: $showAddSavedProduct, arrowEdge: .bottom) {
                        AddSavedProductPopover { added in
                            lines = orderLinesAddingSavedProduct(lines, adding: added)
                            popoverClosedAt = Date()
                            showAddSavedProduct = false
                        }
                        .environmentObject(store)
                    }
            }
            Section {
                locationStatus
                if seededDelivery, !editingDelivery {
                    // Copied from the order being duplicated, or reused from this session's last draft (memory only).
                    Text(sourceOrderNumber == nil
                         ? orderComposerReusedAddressLine(delivery)
                         : "Copied address: \(deliverySummary.isEmpty ? delivery.email : deliverySummary)")
                    if let postcodeWarning { Text(postcodeWarning).font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("Edit") { editingDelivery = true }
                        if sourceOrderNumber == nil {
                            Button("Clear") { clearReusedDelivery() }
                                .help("Start with an empty address for this draft")
                        }
                    }
                } else {
                    deliveryFields
                }
            } header: {
                HStack {
                    Text("Deliver to")
                    Spacer()
                    // Shown only once the seller has saved their own address in Settings › Account.
                    if store.sellerAddress != nil {
                        Button {
                            if let address = store.sellerAddress,
                               useMyAddressNeedsConfirmation(current: delivery, replacement: deliveryDetails(fromSellerAddress: address),
                                                             countryPicked: countryPicked) {
                                confirmUseMyAddress = true
                            } else {
                                applyMyAddress()
                            }
                        } label: {
                            Label("Use My Address", systemImage: "house")
                        }
                        .controlSize(.small)
                        .disabled(store.busy)
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
                    .disabled(store.busy)
                    .help("Fill in an address copied from Etsy, Shopify or an email, after you check it")
                    .popover(isPresented: $showAddressPaste, arrowEdge: .bottom) {
                        // The popover asks before replacing details already in the form.
                        AddressPastePopover(initialText: addressPasteText, skippedClipboard: addressPasteSkippedClipboard,
                                            current: delivery, needsConfirmation: { pasted in
                            pastedAddressNeedsConfirmation(current: delivery, replacement: deliveryDetails(applyingPasted: pasted, to: delivery),
                                                           countryPicked: countryPicked)
                        }, onUse: { pasted in
                            popoverClosedAt = Date()
                            showAddressPaste = false
                            applyPastedAddress(pasted)
                        }, onCancel: {
                            popoverClosedAt = Date()
                            showAddressPaste = false
                        })
                    }
                    // Location is only requested when this is pressed; manual entry stays available.
                    Button {
                        if seededDelivery { editingDelivery = true }
                        locationAddressApplied = false
                        locationLookup.start()
                    } label: {
                        Label("Use Current Location", systemImage: "location")
                    }
                    .controlSize(.small)
                    .disabled(locationLookup.isBusy || store.busy)
                    .help("Suggest an address from your Mac’s location, for you to check before using it")
                }
            }
            Section("More options") {
                if store.platforms.isEmpty {
                    Text("Load platforms to choose one by name.").foregroundStyle(.secondary)
                    Button("Load Platforms") { Task { catalogLoadError = nil; await loadCatalogShowingFailure(.platforms) } }
                        .disabled(!store.hasKey || store.busy)
                } else {
                    orderCatalogPicker("Platform", selection: $draftPlatformID, records: store.platforms, placeholder: "Choose a platform")
                }
                DisclosureGroup("Advanced", isExpanded: $advancedExpanded) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Shipping provider", selection: $shippingProvider) {
                            ForEach(orderShippingProviderChoices, id: \.code) { Text($0.name).tag($0.code) }
                        }
                        TextField("Payment service ID", text: $paymentID, prompt: Text("Optional"))
                        let ownerID = store.ownerID.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !ownerID.isEmpty {
                            // Sent with every draft; edited in Settings › Advanced, where uploads use it too.
                            Text("Owner ID \(ownerID) is sent with this draft. Change it in Settings › Advanced.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text("Reference fields (metadata)").padding(.top, 4)
                        Text("Optional notes saved with the order, such as your shop’s order number. Up to 10.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach($metadataFields) { $field in
                            HStack {
                                TextField("Key", text: $field.key)
                                TextField("Value", text: $field.value)
                                Button(role: .destructive) { metadataFields.removeAll { $0.id == field.id } } label: { Image(systemName: "minus.circle") }
                                    .accessibilityLabel("Remove reference field").help("Remove reference field")
                            }
                        }
                        if metadataFields.count < 10 {
                            Button("Add Reference Field") { metadataFields.append(OrderMetadataField()) }
                        }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// Location lookup progress, its explanation and the suggestion to review. Shown only after Use Current Location.
    @ViewBuilder
    var locationStatus: some View {
        if locationLookup.isBusy || locationLookup.message != nil || locationLookup.suggestion != nil || locationAddressApplied {
            VStack(alignment: .leading, spacing: 8) {
                if locationLookup.isBusy || locationLookup.suggestion != nil {
                    Text("With your permission, Apple uses your location to suggest an address. Check the building and add any apartment or unit number.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if locationLookup.isBusy {
                    HStack {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("Finding your address")
                        Text("Finding your address…").font(.callout).foregroundStyle(.secondary)
                        Button("Stop Lookup") { locationLookup.cancel() }
                    }
                }
                if let message = locationLookup.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                if let suggestion = locationLookup.suggestion {
                    Text("Suggested address").font(.headline)
                    Text(suggestion.summary).textSelection(.enabled)
                    Text("Confirm this is your delivery address. Using it replaces the address fields below; your name and email are kept.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Use This Address") {
                            delivery = suggestion.applying(to: delivery)
                            locationLookup.clearSuggestion()
                            locationAddressApplied = true
                            editingDelivery = true
                        }
                        .disabled(store.busy)
                        Button("Dismiss Suggestion") { locationLookup.clearSuggestion() }
                    }
                }
                if locationAddressApplied {
                    Label("Address filled in. Check it below and add any apartment or unit number before creating your draft.", systemImage: "checkmark.circle")
                        .font(.callout)
                }
            }
        }
    }

    @ViewBuilder
    var deliveryFields: some View {
        // Prompts make an empty field visible in the grouped form, as in System Settings.
        TextField("Full name", text: $delivery.name, prompt: Text("Required"))
        VStack(alignment: .leading, spacing: 4) {
            TextField("Email", text: $delivery.email, prompt: Text("name@example.com"))
            if let emailFieldError { Text(emailFieldError).font(.caption).foregroundStyle(.orange) }
        }
        // Country first: it decides whether State is required and how the postcode is checked.
        countryPicker
        TextField("Street address", text: $delivery.line1, prompt: Text("Required"))
        TextField("Apartment, suite, etc.", text: $delivery.line2, prompt: Text("Optional"))
        TextField("City", text: $delivery.city, prompt: Text("Required"))
        TextField("State / province", text: $delivery.state,
                  prompt: Text(orderStateIsRequired(orderCountryPickerValue(delivery)) ? "Required" : "Optional"))
        VStack(alignment: .leading, spacing: 4) {
            TextField("Postal code", text: $delivery.zip, prompt: Text("Required"))
                .focused($postcodeFocused)
            if let postcodeWarning { Text(postcodeWarning).font(.caption).foregroundStyle(.orange) }
        }
    }

    /// Shortlist first, then every other country by name. Stays on "Choose a country" when nothing is known.
    @ViewBuilder
    var countryPicker: some View {
        let picked = orderCountryPickerValue(delivery)
        let others = orderOtherCountryChoicesForCurrentLocale
        Picker("Country", selection: Binding(
            get: { picked },
            set: {
                delivery = deliveryApplyingCountryPick($0, to: delivery)
                countryPicked = true // Use My Address then asks before replacing it (SellerAddress.swift)
            }
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
                // Text plus a label-less stepper: in a grouped Form a labelled Stepper is drawn as a form row, which put
                // the arrows at the far edge away from the number.
                HStack(spacing: 4) {
                    Text("Quantity: \(item.wrappedValue.quantity)").monospacedDigit()
                    Stepper("Quantity", value: item.quantity, in: 1...10000)
                        .labelsHidden()
                        .accessibilityValue("\(item.wrappedValue.quantity)")
                }
                .fixedSize()
                Spacer(minLength: 0)
                Button(role: .destructive) { lines.removeAll { $0.id == item.wrappedValue.id } } label: { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove item")
                    .help(lines.count < 2 ? "An order needs at least one item." : "Remove item")
                    .disabled(lines.count < 2)
            }
            if let warning = largeQuantityNotice(item.wrappedValue.quantity) {
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
                TextField("Custom image link", text: item.imageURL, prompt: Text("Optional, https://…"))
            }
            let copiedOptions = orderLineOptionsSummary(item.wrappedValue.optionsJSON)
            if !copiedOptions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Copied options — sent with this item", systemImage: "slider.horizontal.3")
                        .font(.callout)
                    ForEach(Array(copiedOptions.enumerated()), id: \.offset) { _, option in
                        Text("\(option.key): \(option.value)")
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .lineLimit(4)
                    }
                    Button("Remove Options") { item.wrappedValue = orderLineRemovingOptions(item.wrappedValue) }
                        .controlSize(.small)
                        .help("Send this item without the copied options")
                }
            }
            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Item name", text: item.name, prompt: Text("Optional"))
                    TextField("SKU", text: item.sku, prompt: Text("Optional"))
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
        case .models: return "Load Your Models"
        case .materials: return "Load Materials"
        case .components: return "Load Components"
        case .stationery: return "Load Stationery"
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
                        let title = materialDisplayName(displayName(for: row.record, fallback: "Untitled"))
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
            // Same-named entries (such as several uploads of one model) get a type/date detail (LibraryNameDetails.swift).
            let details = recordDuplicateNameDetailsByID(records)
            ForEach(indexedRecords(records), id: \.id) { row in
                Text(nameWithDetail(displayName(for: row.record, fallback: "Untitled"), details[row.record.id])).tag(row.record.id)
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
            // Keep the source order's platform only when the loaded platform list has it; say so if it isn't used.
            if let platform = prefill.platformID {
                let seed = orderComposerPlatformSeed(copied: platform, current: draftPlatformID,
                                                     loadedPlatformIDs: store.platforms.map(\.id))
                draftPlatformID = seed.platformID
                platformNotCopied = seed.notCopied
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
        initialShippingProvider = shippingProvider
        initialDraftPlatformID = draftPlatformID
        advancedExpanded = orderComposerAdvancedStartsExpanded(shippingProvider: shippingProvider, metadataFields: metadataFields)
        // A sample to the seller's own address shows the fields so they can be checked before Create Draft.
        if prefill?.usesSellerAddress == true { editingDelivery = true }
    }

    /// Fills every delivery field with the seller's saved address and shows the fields to check.
    func applyMyAddress() {
        guard let address = store.sellerAddress else { return }
        delivery = deliveryDetails(fromSellerAddress: address)
        countryPicked = false
        editingDelivery = true
    }

    /// Fills the delivery fields from a reviewed (and, if it replaces anything, confirmed) paste and shows them.
    func applyPastedAddress(_ pasted: PastedAddress) {
        delivery = deliveryDetails(applyingPasted: pasted, to: delivery)
        // A paste without a country keeps the form's, and whether the seller picked it.
        if !pastedAddressNamesNoCountry(pasted) { countryPicked = false }
        locationAddressApplied = false
        editingDelivery = true
    }

    /// Check Slant found an unconfirmed draft: select it in Orders, then close the form (asking first if it has
    /// unsaved input, as Cancel does).
    func showFoundDraft(_ record: Record) {
        if !store.orders.contains(where: { $0.id == record.id }) { store.orders.insert(record, at: 0) }
        store.draft = ["order": record.values]
        store.destination = .orders
        requestClose()
    }

    /// Starts this draft's address from empty instead of the last draft's. Nothing typed is lost, so the empty form
    /// becomes the discard check's starting point; the remembered address stays for the next draft.
    func clearReusedDelivery() {
        locationAddressApplied = false
        delivery = DeliveryDetails()
        countryPicked = false
        initialDelivery = delivery
        seededDelivery = false
        editingDelivery = true
    }

    /// `fromCancelButton`: the footer's Cancel (or Escape). A press right after a popover closed is ignored, so the
    /// Escape that closed Paste Address… or Add Saved Product… never closes the composer too.
    func requestClose(fromCancelButton: Bool = false) {
        if fromCancelButton, composerCancelFollowsPopoverClose(closedAt: popoverClosedAt, now: Date()) { return }
        if hasUnsavedInput { confirmDiscard = true } else { dismiss() }
    }

    func loadNeededCatalogs(force: Bool = false) async {
        guard store.hasKey else { return }
        catalogsLoading = true
        defer { catalogsLoading = false }
        let types = Set(lines.map(\.type))
        if force { catalogLoadError = nil }
        if types.contains("PRINT") {
            if store.filaments.isEmpty || force { await loadCatalogShowingFailure(.materials) }
            if store.files.isEmpty || force { await store.refresh() }
        }
        if types.contains("COMPONENT"), store.components.isEmpty || force { await loadCatalogShowingFailure(.components) }
        if types.contains("STATIONERY"), store.stationery.isEmpty || force { await loadCatalogShowingFailure(.stationery) }
        if store.platforms.isEmpty || force { await loadCatalogShowingFailure(.platforms) }
    }

    /// A read-only catalog load whose failure is shown in the form instead of the window's alert behind this sheet.
    func loadCatalogShowingFailure(_ kind: Destination) async {
        guard !store.busy else { return }
        await store.loadCatalog(kind)
        if !store.loadedCatalogs.contains(kind), let message = store.error {
            catalogLoadError = message
            store.dismissError()
        }
    }

    /// After an unconfirmed create, the next press asks for "Create Anyway" first. Never retried automatically.
    func createDraft(confirmedDespiteUnknownOutcome: Bool = false) {
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
            let metadata: [String: Any]
            do { metadata = try orderMetadataDictionary(metadataFields) } catch {
                // The reference fields live under Advanced; show them so the problem can be fixed.
                advancedExpanded = true
                throw error
            }
            let options = orderShippingOptions(provider: shippingProvider)
            // A fresh marker per press, so Check Slant can later tell whether this draft was created
            // (DraftConfirmation.swift). Left out when the reference fields already use all 10 metadata fields.
            let generatedMarker = newStudioDraftMarker()
            let markedMetadata = orderMetadataAddingDraftMarker(metadata, marker: generatedMarker)
            let body = try orderDraftPayload(
                platformID: draftPlatformID, ownerID: store.ownerID, email: delivery.email, recipientName: delivery.name,
                line1: delivery.line1, line2: delivery.line2, city: delivery.city, state: delivery.state, zip: delivery.zip, country: country,
                paymentID: paymentID, metadata: markedMetadata, options: options, lines: lines
            )
            let marker = orderDraftMarkerSent(body, generated: generatedMarker)
            let sentPlatformID = draftPlatformID
            validation = nil
            // Create Anyway only when this draft could be one of the unconfirmed attempts: judged by the name the body
            // sends (`draftCreateNeedsCreateAnyway`). The notice above shows whatever the name.
            let needsCreateAnyway = draftCreateNeedsCreateAnyway(
                attempts: store.unconfirmedDraftCreates, overflowed: store.unconfirmedDraftCreatesOverflowed,
                recipient: orderDraftBodyRecipient(body))
            if draftCreateNeedsConfirmation(outcomeUnknown: needsCreateAnyway, confirmed: confirmedDespiteUnknownOutcome) {
                confirmCreateAnyway = true
                return
            }
            // Shown in the notice if this attempt's outcome isn't confirmed (kept in memory only); a confirmed creation
            // clears only this recipient's earlier unconfirmed attempts. The same name the draft body sends.
            let recipient = delivery.name
            let attemptDate = Date()
            Task {
                var attempt = DraftCreateAttempt.notSent
                var failure: String?
                // Any failure is explained here in the form (a window alert would wait behind this sheet). An unknown
                // outcome also gets the unconfirmed-draft notice below, as before.
                let ran = await store.run("Create order draft", handlesError: { error in
                    attempt = .failed(error)
                    failure = orderComposerCreateFailureMessage(error)
                    return true
                }) {
                    // Quit asks first until this create has its answer (SlantStudioApp.swift).
                    let write = SlantWritesInFlight.shared.begin(.draft)
                    defer { SlantWritesInFlight.shared.end(write) }
                    let response = try await store.client.request("POST", path: "/orders", body: body)
                    let data = responseObject(response)
                    let order = mergeOrderDraftEnvelope(data)
                    // The POST went through, so a draft may exist: a reply without the order's `publicId` or `id` (a
                    // name alone isn't one) leaves the outcome unknown.
                    guard orderCreatedID(order) != nil else { throw StudioError("Slant didn’t return an order number.") }
                    attempt = .succeeded
                    store.draft = ["order": order]
                    // A duplicated order's address belongs to that order's customer; don't make it the next draft's default.
                    if sourceOrderNumber == nil { store.lastDelivery = delivery }
                    let record = Record(values: order)
                    store.orders.removeAll { $0.id == record.id }; store.orders.insert(record, at: 0)
                    store.destination = .orders; dismiss()
                }
                if ran {
                    store.noteDraftCreateAttempt(attempt, recipient: recipient, date: attemptDate,
                                                 marker: marker, platformID: sentPlatformID)
                    // An earlier Check Slant result no longer describes the notice.
                    draftCheckOutcome = nil
                    if let failure { validation = failure }
                }
            }
        } catch { validation = error.localizedDescription }
    }
}

// MARK: - Orders

struct OrderTableRow: Identifiable {
    let record: Record
    let recipient: String
    /// The status shown (`orderDisplayStatusTitle`): Shipped when Slant's order status lags its shipping record. The
    /// Status column sorts by it too, since sorting is local and display-only.
    let status: String
    /// Why `status` differs from Slant's order status (`orderStatusLagNote`), for the cell's hover hint.
    let statusNote: String?
    let created: String
    let total: String
    let number: String
    /// "Etsy order 3141592653" when the order's metadata has a marketplace reference (if Slant returns metadata).
    let marketplaceReference: String?
    /// Typed sort keys: display strings ("Oct 3", "$100.00") don't sort chronologically or numerically.
    let createdSortKey: Date
    let totalSortKey: Decimal
    // Order follow-up (OrderFollowUp.swift): arrive-by date, its sort key, and the Needs Attention reason.
    let arriveBy: String
    let arriveBySortKey: Date
    let attention: OrderAttention?
    var id: String { record.id }

    init(record: Record, now: Date = Date()) {
        self.record = record
        let order = orderObject(record.values)
        recipient = orderListTitle(order)
        status = orderDisplayStatusTitle(order)
        statusNote = orderStatusLagNote(order)
        created = orderCreatedDisplay(order) ?? ""
        total = orderTotalMoney(order)
        number = orderNumber(order)
        marketplaceReference = orderMarketplaceReferenceLine(order)
        createdSortKey = orderCreatedDate(order) ?? orderMissingDateSortKey
        totalSortKey = orderTotalAmount(order) ?? orderMissingTotalSortKey
        let arriveByDate = orderArriveByDate(order)
        arriveBy = arriveByDate.map(orderArriveByLabel) ?? ""
        arriveBySortKey = arriveByDate ?? orderMissingArriveBySortKey
        attention = orderAttention(order, now: now)
    }
}

struct OrdersView: View {
    @EnvironmentObject var store: StudioStore
    @State private var selection: String?
    @State private var search = ""
    @State private var detail: [String: Any]?
    @State private var pendingConfirm: PendingOrderConfirm?
    @State private var pendingLoadID: String?
    @State private var filtersPresented = false
    @State private var draftSortOrder = "desc"
    @State private var useFromDate = false
    @State private var useToDate = false
    @State private var draftFromDate = Date()
    @State private var draftToDate = Date()
    /// Starts on (and resets to) the server's createdAt sort from Dates & Sort; column clicks re-sort the loaded rows.
    @State private var sortOrder = orderTableDefaultSort(serverSortOrder: "desc")
    @State private var tableSortSynced = false
    /// Orders the "Since you last looked" banner's Show focused the list on (OrderWatch.swift); nil shows every order.
    @State private var watchFocus: Set<String>?
    // Order detail extras (OrderDetailExtras.swift): Report a Problem…, and the next sheet to open once the current
    // one has closed (Reprint as New Draft…, Review Next Draft).
    @State private var problemReport: OrderProblemReportRequest?
    @State private var reprintAfterDismiss: String?
    @State private var nextReviewAfterDismiss: String?
    /// Needs Attention (OrderFollowUp.swift): a local filter over loaded orders; never a request.
    @State private var needsAttentionOnly = false
    /// The list's order IDs when the first of a run of charge reviews opened, so Review Next Draft keeps its place
    /// however the list changes meanwhile (OrderDetailExtras.swift).
    @State private var reviewListSnapshot: [String] = []
    /// The drafts in that snapshot when it was taken, for "Draft 2 of 5" (`orderReviewRunPositionText`).
    @State private var reviewRunDraftIDs: [String] = []
    /// A run of reviews is going (Review Drafts One by One…, or Review Next Draft after a payment), and the order
    /// whose review is open or was last closed. Choosing another order ends the run; nothing here ever pays.
    @State private var reviewRunActive = false
    @State private var reviewRunCurrentID: String?
    /// Only the Arrive by column has a customization ID, so this controls its visibility alone.
    @State private var columnCustomization = TableColumnCustomization<OrderTableRow>()

    // From all loaded orders, not just the visible list: a new draft or a just-paid order stays shown even when the
    // typed search no longer matches it.
    var selected: Record? { store.orders.first { $0.id == selection } }
    var displayedOrder: [String: Any]? {
        guard let selected else { return nil }
        if let detail, orderBelongs(detail, to: selected.id) { return detail }
        return orderObject(selected.values)
    }
    var canCancelSelected: Bool {
        displayedOrder.map { orderCanRequestCancellation(($0["status"] as? String) ?? "") } ?? false
    }
    /// Show's focus on changed orders and Needs Attention never apply together: Show turns Needs Attention off, and
    /// turning it on or off ends the focus, so the focus bar's count and the empty states always match the list.
    var needsAttentionBinding: Binding<Bool> {
        Binding(get: { needsAttentionOnly }, set: { needsAttentionOnly = $0; watchFocus = nil })
    }
    /// The list's rows: the default platform's loaded orders (`store.ordersOnDefaultPlatform`; Slant's list may
    /// hold other platforms'), then Show's focus, the typed search and Needs Attention. Display only: `selected` and every
    /// duplicate, lock and charge check read the raw `store.orders`.
    var listRecords: [Record] { listRecords(from: store.ordersOnDefaultPlatform) }
    func listRecords(from orders: [Record]) -> [Record] {
        if let focused = orderWatchFocusedRecords(orders, focus: watchFocus) { return focused }
        if store.orderSearchActive { return orderAttentionFiltered(orders, enabled: needsAttentionOnly, now: Date()) }
        let modelNames = orderItemModelNames(localModels: store.localModels, files: store.files)
        return orderAttentionFiltered(orders.filter { orderMatchesSearch($0, query: search, modelNames: modelNames) },
                                      enabled: needsAttentionOnly, now: Date())
    }
    /// Loaded orders left out of the list because they name another platform.
    var otherPlatformsHiddenCount: Int { store.orders.count - store.ordersOnDefaultPlatform.count }
    /// The list is empty only because of the platform: the same filters over every loaded order would show some.
    var listEmptyOnlyForPlatform: Bool {
        otherPlatformsHiddenCount > 0 && listRecords.isEmpty && !listRecords(from: store.orders).isEmpty
    }
    var tableRows: [OrderTableRow] {
        orderTableRowsSorted(listRecords.map { OrderTableRow(record: $0) }, using: sortOrder)
    }
    var draftFilterPreview: OrderFilter {
        var filter = OrderFilter()
        // Status comes from the toolbar's Status menu, which applies on its own.
        filter.status = store.orderFilter.status
        filter.sortOrder = draftSortOrder
        filter.startDate = useFromDate ? draftFromDate : nil
        filter.endDate = useToDate ? draftToDate : nil
        return filter
    }
    var draftFilterValidation: String? { orderFilterValidationError(draftFilterPreview) }
    var showsArriveByColumn: Bool { store.ordersOnDefaultPlatform.contains { orderArriveByDate(orderObject($0.values)) != nil } }
    func syncArriveByColumn() {
        columnCustomization[visibility: orderArriveByColumnID] = showsArriveByColumn ? .visible : .hidden
    }

    var body: some View {
        Group {
            if store.ordersLoaded && tableRows.isEmpty && displayedOrder == nil {
                tableEmptyOverlay.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
        HSplitView {
            VStack(spacing: 0) {
                OrderWatchBanner { ids in showWatchedChanges(ids) }
                if let focused = orderWatchFocusedRecords(store.ordersOnDefaultPlatform, focus: watchFocus) {
                    OrderWatchFocusBar(count: focused.count) { watchFocus = nil }
                }
                Table(tableRows, selection: $selection, sortOrder: $sortOrder, columnCustomization: $columnCustomization) {
                    TableColumn("Recipient", value: \.recipient) { (row: OrderTableRow) in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.recipient).lineLimit(1).help(row.recipient)
                            // Lets sellers match a draft to its marketplace order without opening it.
                            if let reference = row.marketplaceReference {
                                Text(reference).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    // Flexible widths whose minimums add up to about the pane's 360 pt minimum, so the table scrolls
                    // sideways only at the narrowest window; the recipient gets the most room, the order number
                    // (also in the detail) the least, and Created always fits a full "23 Oct 2026".
                    .width(min: 96, ideal: 160)
                    TableColumn("Status", value: \.status) { (row: OrderTableRow) in
                        // With the Needs Attention marker when the order is late or stuck (OrderFollowUp.swift), and
                        // a hover hint when the status shown comes from Slant's shipping record.
                        OrderStatusCell(status: row.status, attention: row.attention, note: row.statusNote)
                    }
                    .width(min: 64, ideal: 112, max: 160)
                    TableColumn("Created", value: \.createdSortKey) { (row: OrderTableRow) in
                        Text(row.created.isEmpty ? "—" : row.created).lineLimit(1)
                    }
                    .width(min: 84, ideal: 96, max: 130)
                    // Shown only while a loaded order has an arrive-by date (`syncArriveByColumn`), so a column Slant
                    // leaves blank doesn't take room from the others. Ascending puts the soonest due first, blanks last.
                    // While shown, the minimums pass the 360 pt pane, so the narrowest window scrolls sideways.
                    TableColumn("Arrive by", value: \.arriveBySortKey) { (row: OrderTableRow) in
                        Text(row.arriveBy.isEmpty ? "—" : row.arriveBy).lineLimit(1).help(row.arriveBy)
                    }
                    .width(min: 60, ideal: 96, max: 130)
                    .customizationID(orderArriveByColumnID)
                    .defaultVisibility(.hidden)
                    TableColumn("Total", value: \.totalSortKey) { (row: OrderTableRow) in
                        Text(row.total).monospacedDigit().lineLimit(1)
                    }
                    .width(min: 52, ideal: 68, max: 110)
                    TableColumn("Order number", value: \.number) { (row: OrderTableRow) in
                        Text(row.number).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).help(row.number)
                    }
                    .width(min: 60, ideal: 100)
                }
                .contextMenu(forSelectionType: String.self) { ids in
                    if ids.count == 1, let id = ids.first, let record = store.orders.first(where: { $0.id == id }) {
                        Button("Duplicate as New Draft…") { Task { await store.duplicateOrderAsDraft(orderID: id) } }
                            .disabled(store.duplicateOrderBlockedReason(orderID: id) != nil)
                        Button("Copy Order Number") { copyToPasteboard(orderNumber(orderObject(record.values))) }
                    }
                }
                .overlay {
                    if store.ordersLoaded, tableRows.isEmpty {
                        tableEmptyOverlay
                    }
                }
                if needsAttentionOnly {
                    Text(orderAttentionFilterHint(moreOnServer: store.ordersHasMore && !store.orderSearchActive))
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                // Slant's Status filter uses its order status, which can lag its shipping record (OrderFollowUp.swift).
                if !store.orderSearchActive, !store.ordersOnDefaultPlatform.isEmpty,
                   let hint = orderStatusFilterLagHintText(status: store.orderFilter.status, loaded: store.ordersOnDefaultPlatform) {
                    Text(hint)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                // Slant's list may hold other platforms' orders; those naming another platform aren't listed.
                if !tableRows.isEmpty, let hidden = orderOtherPlatformsHiddenLine(otherPlatformsHiddenCount) {
                    Text(hidden)
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 6)
                }
                if let hint = orderSearchHint(typed: search, searchActive: store.orderSearchActive) {
                    Text(hint)
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                }
                if !store.orderSearchActive, store.ordersChangedWhileLoading {
                    // A later page's count differed from page 1's: some orders may have shifted past the pages read.
                    HStack(spacing: 8) {
                        Label(orderListChangedWhileLoadingNote, systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Button("Reload") { Task { await store.applyOrderFilter(store.orderFilter) } }
                            .controlSize(.small)
                            .disabled(!store.hasKey || store.busy)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                }
                if !store.orderSearchActive, store.ordersHasMore {
                    HStack {
                        Spacer()
                        Button("Load More") { Task { await store.loadMoreOrders() } }
                            .disabled(!store.hasKey || store.busy)
                        Spacer()
                    }.padding(8)
                }
            }
            .frame(minWidth: 360, idealWidth: 540, maxWidth: .infinity, maxHeight: .infinity)
            detailPane
                // Wide enough for Cancel, Duplicate and Review & Place Order side by side (they never truncate).
                .frame(minWidth: 500, idealWidth: 600, maxWidth: .infinity, maxHeight: .infinity)
        }
        // Fills the window even with no order selected; otherwise the split shrinks to its content and centres.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Slant changed its API, or sent a status Studio doesn't recognise (SlantAPIChanges.swift); also over the empty state.
        .safeAreaInset(edge: .top, spacing: 0) { SlantAPIChangeNotice() }
        .searchable(text: $search, prompt: "Search orders")
        .onSubmit(of: .search) { Task { await store.searchOrders(search) } }
        .onChange(of: search) { _, new in
            if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, store.orderSearchActive {
                Task { await store.searchOrders("") }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let reason = store.orderDraftBlockedReason {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                    if store.hasKey, store.platformID.isEmpty {
                        platformSetupButton
                    }
                }
                Button("New Order Draft…") { store.openOrderComposer() }
                    .disabled(store.orderDraftBlockedReason != nil || store.busy)
                    .help(store.orderDraftBlockedReason ?? "Create an order draft")
            }
            ToolbarItem(placement: .automatic) {
                // Opens the import sheet only; drafts are created there after an explicit confirmation.
                Button {
                    store.showOrderImport = true
                } label: {
                    Label("Import Orders…", systemImage: "square.and.arrow.down")
                }
                .disabled(store.orderImportBlockedReason != nil)
                .help(store.orderImportBlockedReason ?? "Create order drafts from an Etsy, Shopify or template CSV file")
            }
            ToolbarItem(placement: .automatic) {
                // Status applies at once: reloads the list from Slant with this status, keeping the dates and sort from
                // Dates & Sort. Needs attention, in its own section, filters the loaded orders here and never asks Slant
                // for anything; it shares this menu so the toolbar fits the narrowest window. The icon fills while
                // either narrows the list.
                Menu {
                    Picker("Status", selection: Binding(
                        get: { store.orderFilter.status ?? "" },
                        set: { applyStatusFilter($0) }
                    )) {
                        Text("All Statuses").tag("")
                        Divider()
                        ForEach(orderStatusFilterOptions, id: \.self) { Text(orderStatusTitle($0)).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                    .disabled(!store.hasKey || store.busy)
                    Section {
                        Toggle("Needs Attention (Loaded Orders)", isOn: needsAttentionBinding)
                            .disabled(!store.ordersLoaded)
                    }
                } label: {
                    Label("Status", systemImage: store.orderFilter.status != nil || needsAttentionOnly
                          ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
                }
                .help(needsAttentionOnly
                      ? "Showing loaded orders that need attention. Choose a status, or turn off Needs Attention."
                      : "Show orders with this status, or only loaded orders that are late, stuck or not yet placed")
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    syncFilterDraftFromStore()
                    filtersPresented = true
                } label: {
                    Label("Dates & Sort", systemImage: "calendar.badge.clock")
                }
                .help("Date range and Newest/Oldest order")
                .popover(isPresented: $filtersPresented, arrowEdge: .bottom) {
                    filtersPopover
                }
            }
            ToolbarItem(placement: .automatic) {
                // Less frequent tools. None sends anything to Slant: Review Drafts One by One… only opens the existing
                // charge review (each still needs its own Pay), Pay Several Drafts… only opens its sheet (BatchPay.swift),
                // the others open local sheets or save a CSV through the same guarded paths as the File menu.
                Menu {
                    Button("Review Drafts One by One…") { reviewDraftsInOrder() }
                        .disabled(store.busy || nextDraftForReview(after: nil, in: tableRows.map(\.id)) == nil)
                        .help("Review each draft in the list in turn, starting at the top. Each is paid only if you press Pay & Send to Production in its own review.")
                    Button("Pay Several Drafts…") {
                        guard pendingConfirm == nil else { return }
                        store.openBatchPay(listIDs: tableRows.map(\.id))
                    }
                    .disabled(store.busy || batchPayDraftRecords(listIDs: tableRows.map(\.id), orders: store.orders).isEmpty)
                    .help("Choose drafts in the list, review them together and pay them one at a time. Nothing is paid until you confirm the total.")
                    Divider()
                    // Lists loaded orders' tracking to copy into Etsy or Shopify; sends nothing.
                    Button("Tracking for Your Shop…") { store.openShopFollowUpFromMenu() }
                        .disabled(store.orders.isEmpty)
                        .help("Tracking for loaded orders, to copy into Etsy or Shopify")
                    Button("Export Orders…") { store.exportOrdersFromMenu() }
                        .disabled(store.orders.isEmpty)
                        .help("Save the orders in the list as a CSV file")
                    Divider()
                    // Spending report (SpendReport.swift): from the loaded orders only; nothing is sent or saved.
                    Button("Spending Report…") { store.openSpendingReportFromMenu() }
                        .disabled(store.orders.isEmpty)
                        .help("Slant spend per month and top items, from the loaded orders")
                    Divider()
                    Button("Saved Products…") { store.openSavedProducts() }
                        .help("Products you sell often, to add to order drafts in one step")
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
                .help("More order tools")
            }
        }
        // A new search or filter replaces the banner's focus on changed orders.
        .onChange(of: search) { _, new in
            if !new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { watchFocus = nil }
        }
        .onChange(of: store.orderFilter) { _, _ in watchFocus = nil }
        .onChange(of: store.orderSearchActive) { _, active in if active { watchFocus = nil } }
        // A clicked order notification (OrderWatch.swift). Taken after the publisher's change has landed.
        .onReceive(OrderWatch.shared.$selectionRequest) { request in
            guard let request else { return }
            Task { @MainActor in
                if OrderWatch.shared.consumeSelection(request) { selectOrderFromNotification(request.orderID) }
            }
        }
        .onChange(of: store.ordersExportRequest) { _, _ in
            // File › Export Orders…, which the store only forwards when nothing modal is shown.
            // Search can hide every loaded order; say so rather than doing nothing silently.
            guard !tableRows.isEmpty else { NSSound.beep(); return }
            store.exportOrdersCSV(tableRows.map(\.record), moreOnServer: store.ordersHasMore && !store.orderSearchActive)
        }
        .onChange(of: selection) { _, new in
            // Choosing another order ends a run of reviews (its next review sets the selection first, so it stays).
            if reviewRunActive, new != reviewRunCurrentID { endReviewRun() }
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
            if !tableSortSynced {
                tableSortSynced = true
                sortOrder = orderTableDefaultSort(serverSortOrder: store.orderFilter.sortOrder)
            }
            syncArriveByColumn()
        }
        .onChange(of: showsArriveByColumn) { _, _ in syncArriveByColumn() }
        .sheet(item: $pendingConfirm, onDismiss: openNextReviewIfRequested) { request in
            OrderActionConfirmSheet(method: request.method, orderID: request.orderID, onCompleted: { orderID, order in
                applyCompletedOrder(orderID, order)
            }, nextDraft: { nextDraftForReview(after: $0) },
               runPosition: request.method == "POST" && reviewRunActive
                   ? orderReviewRunPositionText(draftIDs: reviewRunDraftIDs, current: request.orderID) : nil,
               inReviewRun: request.method == "POST" && reviewRunActive,
               onReviewNext: { id in
                // Opens only after this review has closed; that review then needs its own Pay press.
                nextReviewAfterDismiss = id
                pendingConfirm = nil
            })
            .environmentObject(store)
        }
        // Pay Several Drafts (BatchPay.swift): each placed order is merged as the single review's are.
        .sheet(item: $store.batchPayRequest) { request in
            BatchPaySheet(request: request, onCompleted: { orderID, order in applyCompletedOrder(orderID, order) })
                .environmentObject(store)
        }
        .sheet(item: $problemReport, onDismiss: reprintIfRequested) { request in
            OrderProblemReportSheet(order: request.order) {
                reprintAfterDismiss = request.id
                problemReport = nil
            }
            .environmentObject(store)
        }
    }

    /// The banner's Show: reloads the newest orders, clearing any search or filter (Needs Attention too) like Show All
    /// Orders, reads changed orders that aren't on that page by ID (`reloadOrdersIncludingWatched`), then lists the
    /// changed orders. Only those listed count as seen, and only once the reload actually ran and succeeded: a refused,
    /// failed or skipped reload (another request running) leaves the banner as it was.
    func showWatchedChanges(_ ids: Set<String>) {
        guard !store.busy else { return }
        Task {
            // Newest change first, so the orders read by ID (older than the reloaded page) are the latest changes.
            let ordered = OrderWatch.shared.unseenChanges.map(\.id).filter(ids.contains)
            guard await store.reloadOrdersIncludingWatched(ordered) else { return }
            needsAttentionOnly = false
            search = ""
            sortOrder = orderTableDefaultSort(serverSortOrder: store.orderFilter.sortOrder)
            let shown = store.ordersOnDefaultPlatform
            let present = Set(ids.filter { id in shown.contains { $0.id == id } })
            // Only the changes now listed count as seen; one that couldn't be read stays in the banner.
            OrderWatch.shared.acknowledge(ids: present)
            watchFocus = present.isEmpty ? nil : present
            if present.count == 1, let id = present.first, selection != id {
                selection = id
            } else if let current = selection, present.contains(current) {
                load(current) // its detail was read before the change
            }
        }
    }

    /// After a review placed or cancelled an order (or a batch payment placed one): the list and the detail show
    /// the order as Slant returned it.
    func applyCompletedOrder(_ orderID: String, _ order: [String: Any]) {
        let record = Record(values: order)
        if !record.id.isEmpty, let index = store.orders.firstIndex(where: { $0.id == orderID }) {
            store.orders[index] = record
        }
        if selection == orderID { detail = order }
    }

    /// A clicked order notification: selects the order (OrderWatch has made sure it is loaded), ending a local search,
    /// Needs Attention or Show focus that hides it. A lookup's results are left alone: clearing it would reload.
    func selectOrderFromNotification(_ id: String) {
        guard store.orders.contains(where: { $0.id == id }) else { return }
        if !listRecords.contains(where: { $0.id == id }) {
            watchFocus = nil
            needsAttentionOnly = false
            if !store.orderSearchActive { search = "" }
        }
        if selection == id { load(id) } else { selection = id }
    }

    // MARK: Order detail extras hooks (OrderDetailExtras.swift)

    /// The next draft for Review Next Draft, with a caption naming it: from the list as it was when this run of reviews
    /// began (`ids`, by default the snapshot), skipping orders that are no longer drafts or are locked now.
    func nextDraftForReview(after currentID: String?, in ids: [String]? = nil) -> (id: String, caption: String)? {
        let rows = orderDraftReviewRows(snapshotIDs: ids ?? reviewListSnapshot, orders: store.orders)
        guard let id = orderNextDraftToReview(rows: rows, after: currentID, isLocked: { store.isOutcomeUnknown(orderID: $0) }),
              let record = store.orders.first(where: { $0.id == id }) else { return nil }
        let row = OrderTableRow(record: record)
        return (id, orderNextDraftCaption(recipient: row.recipient, number: row.number))
    }
    /// Opens the charge review. A review opened from the list or the detail starts a new run (its snapshot of the list);
    /// Review Next Draft continues the current run's.
    /// `startsRun`: Review Drafts One by One…, whose reviews show "Draft 2 of 5" and can skip to the next draft.
    func presentChargeReview(orderID: String, continuingRun: Bool = false, startsRun: Bool = false) {
        if !continuingRun {
            reviewListSnapshot = tableRows.map(\.id)
            reviewRunDraftIDs = orderReviewRunDraftIDs(rows: orderDraftReviewRows(snapshotIDs: reviewListSnapshot, orders: store.orders),
                                                       isLocked: { store.isOutcomeUnknown(orderID: $0) })
            reviewRunActive = startsRun
        } else {
            reviewRunActive = true
        }
        reviewRunCurrentID = reviewRunActive ? orderID : nil
        pendingConfirm = PendingOrderConfirm(method: "POST", orderID: orderID)
    }
    /// Review Drafts One by One…: opens the existing charge review for the first draft in the list. It never pays.
    func reviewDraftsInOrder() {
        guard !store.menuCommandsBlockedByModalUI, !store.busy, pendingConfirm == nil,
              let next = nextDraftForReview(after: nil, in: tableRows.map(\.id)) else { return }
        selection = next.id
        presentChargeReview(orderID: next.id, startsRun: true)
    }
    /// The detail's way on after Go Back during a run: the position, and the next draft (nil when there is none, the
    /// run has ended, or a review is open).
    func reviewRunContinuation(for id: String) -> (position: String, nextID: String, nextCaption: String)? {
        guard reviewRunActive, reviewRunCurrentID == id, pendingConfirm == nil,
              let next = nextDraftForReview(after: id) else { return nil }
        let position = orderReviewRunPositionText(draftIDs: reviewRunDraftIDs, current: id).map { "Reviewing drafts one by one: \($0)." }
        return (position ?? "Reviewing drafts one by one.", next.id, next.caption)
    }
    /// Opens the next draft's review; that review loads the order fresh and needs its own Pay press.
    func continueReviewRun(to id: String) {
        guard pendingConfirm == nil, !store.busy, store.orders.contains(where: { $0.id == id }) else { return }
        selection = id
        presentChargeReview(orderID: id, continuingRun: true)
    }
    func endReviewRun() {
        reviewRunActive = false
        reviewRunCurrentID = nil
    }
    func openNextReviewIfRequested() {
        guard let id = nextReviewAfterDismiss else { return }
        nextReviewAfterDismiss = nil
        guard store.orders.contains(where: { $0.id == id }) else { return }
        selection = id
        presentChargeReview(orderID: id, continuingRun: true)
    }
    func reprintIfRequested() {
        guard let id = reprintAfterDismiss else { return }
        reprintAfterDismiss = nil
        Task { await store.duplicateOrderAsDraft(orderID: id) }
    }

    func applyStatusFilter(_ status: String) {
        var filter = store.orderFilter
        filter.status = status.isEmpty ? nil : status
        guard filter != store.orderFilter else { return }
        Task { await store.applyOrderFilter(filter) }
    }

    /// The route out of "Choose a default platform…", as on Models: Create Platform… when the account has none
    /// (opens the sheet only; nothing is sent until it is submitted), otherwise Settings › Account.
    @ViewBuilder
    var platformSetupButton: some View {
        switch platformSetupAction(platformsLoaded: store.loadedCatalogs.contains(.platforms), platformCount: store.platforms.count) {
        case .createPlatform:
            Button("Create Platform…") { store.showPlatformComposer = true }
                .disabled(store.busy)
        case .chooseInSettings:
            Button("Choose Platform…") { store.requestSettings(.account) }
        }
    }

    var filtersPopover: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Dates & Sort").font(.headline)
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
                // Resets the dates and sort shown here; the toolbar's Status menu keeps its choice.
                Button("Reset") {
                    draftSortOrder = "desc"
                    useFromDate = false
                    useToDate = false
                    filtersPresented = false
                    var filter = OrderFilter()
                    filter.status = store.orderFilter.status
                    Task {
                        await store.applyOrderFilter(filter)
                        sortOrder = orderTableDefaultSort(serverSortOrder: store.orderFilter.sortOrder)
                    }
                }
                .help("Clear the dates and sort newest first")
                Spacer()
                Button("Apply") {
                    filtersPresented = false
                    let filter = draftFilterPreview
                    Task {
                        await store.applyOrderFilter(filter)
                        // Newest/Oldest from Dates & Sort wins over an earlier column sort.
                        sortOrder = orderTableDefaultSort(serverSortOrder: store.orderFilter.sortOrder)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draftFilterValidation != nil)
            }
        }
        .padding(16)
        .frame(width: 280)
    }

    func syncFilterDraftFromStore() {
        draftSortOrder = store.orderFilter.sortOrder
        useFromDate = store.orderFilter.startDate != nil
        useToDate = store.orderFilter.endDate != nil
        draftFromDate = store.orderFilter.startDate ?? Date()
        draftToDate = store.orderFilter.endDate ?? Date()
    }

    /// Nothing matches: a typed search gets the system's search wording; a status or date filter says which
    /// filter left the list empty and offers a way back to every order.
    @ViewBuilder
    var filteredEmptyView: some View {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if listEmptyOnlyForPlatform {
            // Never blames the search or the dates: these orders match, but are on another platform.
            otherPlatformsEmptyView
        } else if needsAttentionOnly {
            ContentUnavailableView {
                Label("Nothing needs attention", systemImage: "checkmark.circle")
            } description: {
                Text(orderAttentionEmptyDetail(filterActive: store.orderFilter.isActive, search: query))
            } actions: {
                Button("Show All Orders") {
                    needsAttentionOnly = false
                    if store.orderFilter.isActive {
                        Task { await store.applyOrderFilter(OrderFilter(sortOrder: store.orderFilter.sortOrder)) }
                    }
                }
                .disabled(store.busy && store.orderFilter.isActive)
            }
        } else if !query.isEmpty, !store.orderFilter.isActive {
            ContentUnavailableView.search(text: query)
        } else {
            // Load More (under the list) stays available when Slant has more pages: the date filter's margin can trim
            // a whole page away, so "none" is only about the pages read so far.
            let moreOnServer = store.ordersHasMore && !store.orderSearchActive
            ContentUnavailableView {
                Label(moreOnServer ? "None on the pages loaded so far" : "No matching orders",
                      systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text([orderFilterEmptyDetail(store.orderFilter, search: query, moreOnServer: moreOnServer),
                      orderOtherPlatformsHiddenLine(otherPlatformsHiddenCount)].compactMap { $0 }.joined(separator: " "))
            } actions: {
                if store.orderFilter.isActive {
                    Button("Show All Orders") {
                        Task { await store.applyOrderFilter(OrderFilter(sortOrder: store.orderFilter.sortOrder)) }
                    }
                    .disabled(store.busy)
                }
            }
        }
    }

    /// Every loaded order that would be listed names another platform.
    var otherPlatformsEmptyView: some View {
        ContentUnavailableView {
            Label("No orders on your default platform", systemImage: "storefront")
        } description: {
            Text(orderOtherPlatformsHiddenLine(otherPlatformsHiddenCount) ?? "")
        } actions: {
            Button("Choose Platform…") { store.requestSettings(.account) }
        }
    }

    @ViewBuilder
    var tableEmptyOverlay: some View {
        if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.orderSearchActive || store.orderFilter.isActive
            || needsAttentionOnly {
            filteredEmptyView
        } else if store.orders.isEmpty {
            ContentUnavailableView {
                Label("No orders yet", systemImage: "shippingbox")
            } description: {
                Text("Create a draft to calculate printing and shipping.")
            } actions: {
                Button("New Order Draft…") { store.openOrderComposer() }
                    .disabled(store.orderDraftBlockedReason != nil || store.busy)
            }
        } else if listRecords.isEmpty, otherPlatformsHiddenCount > 0 {
            otherPlatformsEmptyView
        }
    }

    @ViewBuilder
    var detailPane: some View {
        if let selected, let displayed = displayedOrder {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack {
                        let detailStatus = (displayed["status"] as? String) ?? selected.string("status")
                        // The shipping record's word when Slant's order status lags it (`orderDisplayStatus`); display
                        // only: Cancel and every check use Slant's own status.
                        let lagNote = orderStatusLagNote(displayed)
                        SectionHeading(title: orderDetailCaption(displayed),
                                       caption: displayed["status"] is String ? orderDisplayStatusTitle(displayed) : orderStatusTitle(detailStatus))
                            .help(lagNote ?? orderStatusHelp(detailStatus) ?? "")
                        Spacer()
                        Button { load(selected.id) } label: { Image(systemName: "arrow.clockwise") }
                            .accessibilityLabel("Reload order").help("Reload order").disabled(store.busy)
                    }
                    if let lagNote = orderStatusLagNote(displayed) {
                        Text(lagNote).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Why this order needs attention (OrderFollowUp.swift), which the list shows only as a marker.
                    if let attention = orderAttention(displayed, now: Date()) {
                        Label("Needs attention: \(attention.detail)", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    // Actions sit under the header so placing a draft never needs scrolling; both open a review first.
                    // The destructive Cancel & Refund… comes last.
                    HStack {
                        Spacer()
                        let duplicateBlocked = store.duplicateOrderBlockedReason(orderID: selected.id)
                        Button("Duplicate as New Draft…") { Task { await store.duplicateOrderAsDraft(orderID: selected.id) } }
                            .disabled(duplicateBlocked != nil)
                            .fixedSize()
                            .help(duplicateBlocked ?? "Open a new draft with this order’s items and delivery details for review")
                        if ((displayed["status"] as? String) ?? "").uppercased() == "DRAFT" {
                            Button("Review & Place Order…") { presentChargeReview(orderID: selected.id) }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.busy)
                                .fixedSize()
                                .help("Review and pay")
                        }
                        // Takes the slot Review & Place Order uses on drafts, so the row never gets wider.
                        if orderOffersProblemReport(status: (displayed["status"] as? String) ?? selected.string("status")) {
                            Button("Report a Problem…") { problemReport = OrderProblemReportRequest(id: selected.id, order: displayed) }
                                .fixedSize()
                                .help("Put together a message about this order for Slant support, to copy")
                        }
                        if canCancelSelected {
                            // Offered by Slant's own status (`canCancelSelected`); only the wording follows the
                            // shipping record ("Request Refund…" once it says the order shipped).
                            Button(orderCancelActionTitle(orderDisplayStatus(displayed)), role: .destructive) {
                                pendingConfirm = PendingOrderConfirm(method: "DELETE", orderID: selected.id)
                            }
                            .disabled(store.busy)
                            .fixedSize()
                            .help("Review cancellation")
                        }
                    }
                    if ((displayed["status"] as? String) ?? "").uppercased() == "DRAFT" {
                        Text(orderDetailDraftCaption).font(.caption).foregroundStyle(.secondary)
                    } else if !canCancelSelected, let reason = orderDetailCancelBlockedNote((displayed["status"] as? String) ?? "") {
                        // Under the row with its own width, rather than squeezed beside the buttons.
                        Text(reason).font(.caption).foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    // Review Drafts One by One…: after Go Back the run can still move on (never pays by itself).
                    if let run = reviewRunContinuation(for: selected.id) {
                        HStack {
                            Text(run.position).font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            Button("Stop Reviewing") { endReviewRun() }
                                .help("End this run of reviews. Nothing is paid.")
                            Button("Review Next Draft…") { continueReviewRun(to: run.nextID) }
                                .disabled(store.busy || pendingConfirm != nil)
                                .help("Open the review for the next draft in the list (\(run.nextCaption)). Nothing is paid until you press Pay in that review.")
                        }
                    }
                    Divider()
                    OrderSummary(order: displayed)
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
        } else if !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.orderSearchActive || store.orderFilter.isActive
                    || needsAttentionOnly {
            if listRecords.isEmpty {
                filteredEmptyView
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
                guard orderBelongs(order, to: id) else { throw StudioError(orderReviewDifferentOrderMessage) }
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
    /// Review Next Draft… (OrderDetailExtras.swift): offered after this order was placed, and as Skip to Next Draft…
    /// before paying during Review Drafts One by One…. It closes this review and opens a new one for the next draft,
    /// which loads fresh and needs its own Pay press; it never pays.
    var nextDraft: ((_ after: String) -> (id: String, caption: String)?)? = nil
    /// "Draft 2 of 5" during a run of reviews.
    var runPosition: String? = nil
    var inReviewRun = false
    var onReviewNext: ((_ orderID: String) -> Void)? = nil
    @State private var fresh: [String: Any]?
    @State private var loadState: OrderConfirmLoadState = .loading
    @State private var awaitingBusy = false
    @State private var actionMessage: String?
    @State private var writing = false
    @State private var writeSucceeded = false
    @State private var writeAttempted = false
    @State private var successMessage: String?
    @State private var capturedRefundOnly = false
    /// Slant accepted the Pay but the order it then showed wasn't placed (cancelled, a payment problem, or a status
    /// Studio doesn't recognise): no Review Next Draft… then.
    @State private var payNotPlaced = false
    /// Why the review couldn't load, shown in this sheet (a window alert would wait behind it).
    @State private var loadFailure: String?
    var isPay: Bool { method == "POST" }
    /// For wording only (`orderDisplayStatus`): Shipped when Slant's order status lags its shipping record, so a
    /// cancel review of an order the record says shipped reads as a refund request. Never a gate input: the gate
    /// (`orderConfirmReviewGate`) takes the order and reads Slant's own status itself.
    var copyStatus: String { fresh.map(orderDisplayStatus) ?? "" }
    var mutationLock: (Bool, String?) { orderConfirmMutationSendAllowed(attempted: writeAttempted, succeeded: writeSucceeded) }
    /// Set by an earlier Orders or Workbench attempt whose result is unknown; survives closing and reopening this sheet.
    var sharedOutcomeLock: Bool { store.isOutcomeUnknown(orderID: orderID) }
    /// Whether Pay or Cancel may be pressed for the loaded order, and why not.
    var reviewGate: OrderConfirmReviewGate {
        orderConfirmReviewGate(order: fresh, loaded: loadState == .loaded, isPay: isPay,
                               writeSucceeded: writeSucceeded, writeAttempted: writeAttempted)
    }
    var finalActionEnabled: Bool {
        reviewGate.enabled && !writing && !store.busy && !sharedOutcomeLock
    }
    var sheetTitle: String {
        if isPay { return "Place this order?" }
        return orderCancelSheetTitle(copyStatus)
    }
    var sheetBodyCopy: String {
        if isPay {
            return "This charges the payment method associated with your Slant account and starts fulfilment. Costs below are loaded fresh from Slant."
        }
        return orderCancelSheetBody(order: fresh)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text(sheetTitle).font(.title2.weight(.bold))
                Spacer()
                if let runPosition { Text(runPosition).foregroundStyle(.secondary) }
            }
            Text(sheetBodyCopy).foregroundStyle(.secondary)
            switch loadState {
            case .loading:
                ProgressView("Loading order…").controlSize(.small)
            case .failed:
                VStack(alignment: .leading, spacing: 10) {
                    Text(isPay ? "Couldn’t load this order’s costs." : "Couldn’t load this order.").font(.callout).foregroundStyle(.orange)
                    if let loadFailure {
                        Text(loadFailure).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Button("Try Again") { loadFresh() }.disabled(store.busy || writing)
                }
            case .loaded:
                if let order = fresh {
                    let reference = orderMarketplaceReferenceLine(order)
                    let estimate = reviewProfitEstimate(order)
                    // A cost field Studio doesn't add (a tax or fee Slant might add one day), or a Slant total that
                    // disagrees with the sum. Advisory: Pay stays enabled or disabled exactly as without it.
                    let costNotice = isPay ? orderUnlistedCostNotice(orderUnlistedCosts(order)) : nil
                    VStack(alignment: .leading, spacing: 8) {
                        if let items = order["items"] as? [[String: Any]], !items.isEmpty {
                            // A long list scrolls in a fixed-height box so the totals and buttons below always stay
                            // visible. Chosen by item count, never by measuring (ViewThatFits looped forever when
                            // VoiceOver or automation hit-tested this sheet); a short list hugs its content. Extra
                            // receipt lines (marketplace, estimated profit, the cost notice) shorten it to keep the
                            // buttons in view.
                            let noticeLines = costNotice == nil ? 0 : orderReviewCostNoticeLines
                            let itemLayout = orderReviewItemListLayout(
                                itemCount: items.count,
                                extraReceiptLines: (reference == nil ? 0 : 1) + (estimate == nil ? 0 : 1) + noticeLines,
                                maximumExtraLines: 2 + noticeLines)
                            if itemLayout.scrolls {
                                ScrollView { reviewItemList(items).padding(.trailing, 12) }
                                    .scrollIndicators(.visible)
                                    .frame(height: itemLayout.height)
                            } else {
                                reviewItemList(items)
                            }
                            if isPay, let notice = orderReviewLargeQuantityNotice(items) {
                                Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            }
                            Divider()
                        }
                        // A receipt: labels on the left, values in a right-aligned column.
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent("Status") {
                                Text(orderStatusTitle(copyStatus)).help(orderStatusLagNote(order) ?? "")
                            }
                            // "Print cost", as in the order detail: "Printing" is also a status, shown just above.
                            LabeledContent("Print cost") { Text("\(money(order["printingCost"])) USD").monospacedDigit() }
                            LabeledContent("Delivery cost") { Text("\(money(order["deliveryCost"])) USD").monospacedDigit() }
                            LabeledContent("Total") { Text("\(orderTotalMoney(order)) USD").monospacedDigit().fontWeight(.semibold) }
                            if let costNotice {
                                Label(costNotice, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            LabeledContent("Recipient") { Text(orderRecipientDisplay(order)).lineLimit(2) }
                            // A likely duplicate (another loaded order for the same marketplace order) replaces the
                            // Marketplace row with a warning naming it, so the list's height is unchanged. Advisory
                            // only: Pay and the defaults are the same either way.
                            if let duplicate = marketplaceDuplicateNotice(order) {
                                Label(duplicate, systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                                    .lineLimit(1).truncationMode(.tail)
                                    .help(duplicate)
                                    .accessibilityLabel(duplicate)
                            } else if let reference {
                                LabeledContent("Marketplace") { Text(reference).lineLimit(1).truncationMode(.middle) }
                            }
                            // From Import Orders' amounts (memory only): one line, informational, never affects Pay.
                            if let estimate { importedSaleEstimateLine(estimate) }
                        }
                        .labeledContentStyle(.receipt)
                    }.font(.callout).textSelection(.enabled)
                }
            }
            if let successMessage {
                Text(successMessage).font(.callout).foregroundStyle(.secondary)
            } else if let actionMessage {
                Text(actionMessage).font(.callout).foregroundStyle(.orange)
            }
            if writing {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            HStack {
                // Close after a Pay Slant accepted but didn't place (nothing more to do here), Done after a placed
                // order or a requested cancellation, Go Back before anything was done.
                Button(orderReviewDismissTitle(writeSucceeded: writeSucceeded, payNotPlaced: payNotPlaced), role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(writing)
                // Review Next Draft… (after paying) or Skip to Next Draft… (before paying, during Review Drafts One by
                // One…): never the default button, and kept away from the trailing Pay position so a repeated click
                // can't land on the next review's Pay. Not offered once a Pay was sent without a confirmed result.
                if isPay, let onReviewNext, let next = nextDraft?(orderID),
                   orderReviewOffersNextDraft(inRun: inReviewRun, writeSucceeded: writeSucceeded && !payNotPlaced,
                                              writeAttempted: writeAttempted, writing: writing) {
                    VStack(alignment: .leading, spacing: 2) {
                        Button(writeSucceeded ? "Review Next Draft…" : "Skip to Next Draft…") { onReviewNext(next.id) }
                            .disabled(store.busy || writing)
                            .help(writeSucceeded
                                  ? "Close this and review the next draft in the list. Nothing is paid until you press Pay in that review."
                                  : "Leave this draft unpaid and review the next one in the list. Nothing is paid until you press Pay in that review.")
                        Text(next.caption).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    .layoutPriority(-1)
                }
                Spacer()
                if writeSucceeded {
                    EmptyView()
                } else if writeAttempted || sharedOutcomeLock {
                    VStack(alignment: .trailing, spacing: 6) {
                        if let reason = writeAttempted ? mutationLock.1 : unknownOutcomeBlockMessage {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Reload Order") { loadFresh(keepUnknownMessage: true) }
                            .disabled(store.busy || writing)
                    }
                } else if isPay {
                    VStack(alignment: .trailing, spacing: 6) {
                        if loadState == .loaded, !finalActionEnabled, let reason = reviewGate.reason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Button("Pay & Send to Production") { confirmAction() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!finalActionEnabled)
                            .fixedSize()
                    }
                } else {
                    VStack(alignment: .trailing, spacing: 6) {
                        if loadState == .loaded, !finalActionEnabled, let reason = reviewGate.reason {
                            Text(reason).font(.caption).foregroundStyle(.secondary)
                        }
                        Button(orderCancelSheetButtonTitle(copyStatus), role: .destructive) { confirmAction() }
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
    /// Before paying: a warning when a loaded order for the same marketplace order was already placed, or another loaded
    /// draft is for it (`orderReviewMarketplaceDuplicateNotice`). Never affects whether Pay is enabled.
    func marketplaceDuplicateNotice(_ order: [String: Any]) -> String? {
        guard isPay, !writeAttempted, !writeSucceeded else { return nil }
        return orderReviewMarketplaceDuplicateNotice(order, orderID: orderID, loaded: store.orders)
    }
    /// Estimated profit before paying, only from this session's imported amounts and only until Pay is pressed.
    func reviewProfitEstimate(_ order: [String: Any]) -> ImportedSaleReviewEstimate? {
        guard isPay, !writeAttempted,
              let amounts = importedSaleAmountsLookup(store.importedSaleAmounts, order: order) else { return nil }
        let preset = ProfitFeeSettings.loadPreset()
        return importedSaleReviewEstimate(amounts, order: order, preset: preset, rates: ProfitFeeSettings.loadRates(preset))
    }
    /// The pay review's estimated profit from imported amounts: one line, orange with a warning sign for a loss.
    func importedSaleEstimateLine(_ estimate: ImportedSaleReviewEstimate) -> some View {
        Group {
            if estimate.isLoss {
                Label(estimate.text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            } else {
                Label(estimate.text, systemImage: "chart.line.uptrend.xyaxis").foregroundStyle(.secondary)
            }
        }
        .lineLimit(1).truncationMode(.tail)
        .help(estimate.text + ". From the imported order’s amounts and the order’s Slant total; see Profit check for details.")
    }
    /// The reviewed items. Large quantities are highlighted as a visual fat-finger check only; the explicit Pay
    /// confirmation is unchanged.
    func reviewItemList(_ items: [[String: Any]]) -> some View {
        let modelNames = orderItemModelNames(localModels: store.localModels, files: store.files)
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let text = orderItemLineText(item, modelNames: modelNames)
                // One line each, material as a caption (as in the order detail), so the list's height is predictable.
                VStack(alignment: .leading, spacing: 1) {
                    if isPay, orderItemHasLargeQuantity(item) {
                        Label(text, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).fontWeight(.semibold)
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityLabel("Large quantity: \(text)")
                    } else {
                        Text(text).lineLimit(1).truncationMode(.middle)
                    }
                    if let material = orderItemMaterialName(item, filaments: store.filaments) {
                        Text("Material: \(materialDisplayName(material))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .help(text)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        loadFailure = nil
        fresh = nil
        Task {
            var succeeded = false
            var failure: String?
            // A failure is explained in this sheet (`loadFailure`), not in a window alert behind it.
            let ran = await store.run("Load order for review", handlesError: { error in
                failure = friendlyAPIMessage(error)
                return true
            }) {
                let response = try await store.client.request("GET", path: "/orders/\(encodedSegment(orderID))")
                let loaded = mergeOrderDraftEnvelope(responseObject(response))
                // Only this order may be reviewed, paid or used to lift its lock.
                guard orderBelongs(loaded, to: orderID) else { throw StudioError(orderReviewDifferentOrderMessage) }
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
            loadFailure = failure
            if !ran { awaitingBusy = true }
            if keepUnknownMessage, writeAttempted, !writeSucceeded {
                // Keeps the specific note (such as the cause of an unknown outcome) from before the reload.
                actionMessage = actionMessage ?? orderConfirmMutationSendAllowed(attempted: true, succeeded: false).1
            }
        }
    }
    func confirmAction() {
        guard let shown = fresh, !writeSucceeded, !writeAttempted, !writing, !sharedOutcomeLock else { return }
        actionMessage = nil
        writing = true
        // Wording only: "Refund requested." also when only the shipping record says the order shipped.
        let successRefundOnly = orderCancellationIsRefundOnly(orderDisplayStatus(shown))
        Task {
            var outcome: OrderConfirmRecheckResult = .proceed
            var latestOrder: [String: Any]?
            var mutateOrder: [String: Any]?
            var completedOrder: [String: Any]?
            var didWrite = false
            var attemptedWrite = false
            var payAcceptedUnconfirmed = false
            var payOutcome: BatchPayOutcome?
            var rejected = false
            var refusal: String?
            var failure: String?
            // The write's own error when its outcome is unknown, for the cause shown in the sheet.
            var unknownWriteError: Error?
            // Every failure is explained here in the review: a window alert would wait behind this sheet, and after a
            // write was sent its "try again" advice would be wrong.
            let ran = await store.run(isPay ? "Process order" : "Cancel order", handlesError: { error in
                failure = friendlyAPIMessage(error)
                return true
            }) {
                let preview = try await store.client.request("GET", path: "/orders/\(encodedSegment(orderID))")
                let latest = mergeOrderDraftEnvelope(responseObject(preview))
                // Only this order may be paid or cancelled (as Pay Several Drafts checks).
                guard orderBelongs(latest, to: orderID) else { throw StudioError(orderReviewDifferentOrderMessage) }
                latestOrder = latest
                outcome = orderConfirmRecheck(method: method, shown: shown, latest: latest)
                if let abort = orderConfirmRecheckAbortError(outcome) { throw abort }
                if store.isOutcomeUnknown(orderID: orderID) { throw StudioError(unknownOutcomeBlockMessage) }
                // Shared lock before the write: a timeout or 5xx leaves the charge/cancel outcome unknown.
                store.markOutcomeUnknown(orderID: orderID, action: isPay ? .pay : .cancel, reviewedStatus: latest["status"] as? String)
                attemptedWrite = true
                writeAttempted = true
                capturedRefundOnly = successRefundOnly
                // Quit asks first until this write has its answer (SlantStudioApp.swift).
                let write = SlantWritesInFlight.shared.begin(isPay ? .payment : .cancellation)
                defer { SlantWritesInFlight.shared.end(write) }
                let mutateResponse: APIResponse
                do {
                    mutateResponse = try await store.client.request(method, path: "/orders/\(encodedSegment(orderID))")
                } catch {
                    if orderMutationErrorProvesNoEffect(error, method: method) {
                        // Slant refused it (or it was never sent), so nothing is pending: lift the lock and return to
                        // the review.
                        store.clearOutcomeUnknown(orderID: orderID)
                        attemptedWrite = false
                        writeAttempted = false
                        rejected = true
                        refusal = orderConfirmRefusalMessage(isPay: isPay, error: error)
                    } else {
                        unknownWriteError = error
                    }
                    throw error
                }
                mutateOrder = mergeOrderDraftEnvelope(responseObject(mutateResponse))
                var refreshedOrder: [String: Any]?
                if let refreshed = try? await store.client.request("GET", path: "/orders/\(encodedSegment(orderID))") {
                    refreshedOrder = mergeOrderDraftEnvelope(responseObject(refreshed))
                }
                // Only an order that is this one counts: the refresh, else the reply.
                completedOrder = orderPayAcceptedOrder(replied: mutateOrder, refreshed: refreshedOrder, orderID: orderID)
                if isPay {
                    // A 2xx to a pay whose order still shows DRAFT, or no readable status, isn't a confirmed charge:
                    // the lock stays until a reload shows the outcome (as Pay Several Drafts does). Any other status
                    // is past DRAFT, a definite outcome, so the lock lifts, but only a placed one is reported as placed.
                    let result = batchPayOutcomeAfterSuccess(completedOrder)
                    payOutcome = result
                    if batchPayAcceptedOutcomeStaysLocked(completedOrder) {
                        payAcceptedUnconfirmed = true
                    } else {
                        didWrite = true
                        store.clearOutcomeUnknown(orderID: orderID)
                    }
                    // Activity records "Completed" only for a placed order.
                    if result != .placed { throw StudioError(orderPayActivityDetail(result)) }
                } else {
                    didWrite = true
                    store.clearOutcomeUnknown(orderID: orderID)
                }
            }
            writing = false
            if attemptedWrite { writeAttempted = true; capturedRefundOnly = successRefundOnly }
            if !ran { awaitingBusy = true; return }
            if let latest = latestOrder { fresh = latest; loadState = .loaded }
            if didWrite {
                let best = completedOrder ?? latestOrder ?? shown
                fresh = best
                loadState = .loaded
                writeSucceeded = true
                if isPay, let payOutcome, payOutcome != .placed {
                    // Accepted, but not placed: say why, and offer no next draft.
                    payNotPlaced = true
                    successMessage = nil
                    actionMessage = orderPayAcceptedMessage(payOutcome)
                } else {
                    successMessage = isPay ? "Order placed." : (capturedRefundOnly ? "Refund requested." : "Cancellation requested.")
                    actionMessage = nil
                }
                onCompleted(orderID, best)
            } else if payAcceptedUnconfirmed {
                if let shownOrder = completedOrder { fresh = shownOrder; loadState = .loaded }
                actionMessage = "Slant accepted the payment request but doesn’t show the order as placed yet, so it may still be charged. Reload the order before doing anything else."
            } else if attemptedWrite {
                actionMessage = unknownWriteError.map { orderConfirmUnknownOutcomeMessage(isPay: isPay, error: $0) }
                    ?? orderConfirmMutationSendAllowed(attempted: true, succeeded: false).1
            } else if rejected {
                actionMessage = refusal ?? (isPay ? "Slant didn’t accept the payment request. Review the order before trying again." : "Slant didn’t accept the cancel request. Review the order before trying again.")
            } else {
                switch outcome {
                case .priceChanged: actionMessage = "The price changed. Review the new total."
                case .statusBlocked(let reason): actionMessage = reason
                case .proceed: actionMessage = failure
                }
            }
        }
    }
}

// MARK: - Pure helpers

/// Why a filtered orders list is empty, naming the status and/or dates that left nothing.
/// `moreOnServer`: Slant has further pages (Load More is shown), so the emptiness is only about the pages read so far.
func orderFilterEmptyDetail(_ filter: OrderFilter, search: String = "", moreOnServer: Bool = false) -> String {
    let dated = filter.startDate != nil || filter.endDate != nil
    let base: String
    switch (filter.status, dated) {
    case (let status?, true): base = "No orders with the status “\(orderStatusTitle(status))” in the chosen dates"
    case (let status?, false): base = "No orders with the status “\(orderStatusTitle(status))”"
    case (nil, true): base = "No orders in the chosen dates"
    case (nil, false): base = "No orders"
    }
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    // An order Studio shows as Shipped may be listed under Printing or Submitted (`orderStatusFilterLagHint`).
    let lagHint = (filter.status ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "SHIPPED"
        ? " " + orderStatusFilterLagHint : ""
    if moreOnServer {
        let matching = query.isEmpty ? base : base + " match “\(query)”"
        return matching + " on the pages loaded so far. Load More reads the next page from Slant." + lagHint
    }
    return (query.isEmpty ? base + (filter.isActive ? "." : " match.") : base + " match “\(query)”.") + lagHint
}
/// Under a draft's actions: what placing does, and why there's no Cancel.
let orderDetailDraftCaption = "Placing charges your saved payment method. Slant doesn’t cancel drafts; a draft costs nothing unless you place it."
/// The review sheet's note after Slant definitely refused the pay or cancel request (nothing was charged or
/// cancelled): Slant's own words for a rejected request (400/422), otherwise the usual message, which already says
/// what went wrong and keeps advice such as reconnecting after a 401.
func orderConfirmRefusalMessage(isPay: Bool, error: Error) -> String {
    let lead = isPay ? "Slant didn’t accept the payment request." : "Slant didn’t accept the cancel request."
    if case .http(let status, let body, _, _)? = error as? APIError, status == 400 || status == 422,
       let message = shortAPIMessage(from: body)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
        let sentence = message.last.map { ".!?".contains($0) } == true ? message : message + "."
        return lead + " Slant said: “" + sentence + "”"
    }
    let detail = friendlyAPIMessage(error).trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty ? lead + " Review the order before trying again." : detail
}
/// The composer's note after Create Draft failed: for a definite refusal (400/422) Slant's own words, otherwise the
/// usual message. When the outcome is unknown (a timeout, transport error, 5xx, 408/409 or a reply without an order
/// number) the draft may exist, so the note says so and never suggests trying again; the unconfirmed-draft notice and
/// Look for Draft on Slant are the way forward.
func orderComposerCreateFailureMessage(_ error: Error) -> String {
    if case .http(let status, let body, _, _)? = error as? APIError, status == 400 || status == 422,
       let message = shortAPIMessage(from: body)?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
        let sentence = message.last.map { ".!?".contains($0) } == true ? message : message + "."
        return "Slant didn’t create the draft. Slant said: “" + sentence + "”"
    }
    if !orderMutationErrorProvesNoEffect(error) {
        return "\(orderCreateUnknownReason(error)), so this draft may have been created. "
            + "Check the notice at the top of this form before creating it again."
    }
    let detail = friendlyAPIMessage(error).trimmingCharacters(in: .whitespacesAndNewlines)
    return detail.isEmpty ? "The draft wasn’t created." : detail
}
/// Why a draft create's outcome is unknown, as the start of a sentence.
func orderCreateUnknownReason(_ error: Error) -> String {
    if case .http(let status, _, _, _)? = error as? APIError { return "Slant replied with an error (HTTP \(status))" }
    if let urlError = error as? URLError, urlError.code == .timedOut { return "Slant didn’t reply in time" }
    if error is URLError || error is CancellationError { return "The connection to Slant was interrupted" }
    return "Slant’s reply didn’t confirm the draft"
}
/// What happened to a pay or cancel request whose outcome is unknown, as the start of a sentence: never says it failed.
func slantUnclearReplyCause(_ error: Error) -> String {
    if case .http(let status, _, _, _)? = error as? APIError { return "Slant replied with HTTP \(status)" }
    if let urlError = error as? URLError, urlError.code == .timedOut { return "Slant didn’t reply in time" }
    if error is URLError || error is CancellationError { return "The connection to Slant was interrupted" }
    return "Slant’s reply didn’t confirm it"
}
/// The single pay/cancel review's note after a request whose outcome is unknown: the cause, and that the outcome may
/// already have happened. It never suggests sending again; a reload shows what Slant did.
func orderConfirmUnknownOutcomeMessage(isPay: Bool, error: Error) -> String {
    let outcome = isPay ? "the order may have been placed and charged" : "the cancellation may have gone through"
    return "\(slantUnclearReplyCause(error)), so the result is unknown: \(outcome). Reload the order to see what Slant shows."
}
/// The pay/cancel review's dismiss button.
func orderReviewDismissTitle(writeSucceeded: Bool, payNotPlaced: Bool) -> String {
    guard writeSucceeded else { return "Go Back" }
    return payNotPlaced ? "Close" : "Done"
}
/// The single review and the Workbench refuse to act on a reply for another order.
let orderReviewDifferentOrderMessage = "Slant returned a different order. Reload Orders and review this order again."
/// Activity's detail for a 2xx Pay that didn't place the order (never "Completed"): counts and statuses only.
func orderPayActivityDetail(_ outcome: BatchPayOutcome) -> String {
    switch outcome {
    case .placed: return "Completed"
    case .notPlaced(let reason): return "Accepted, but not placed. " + reason
    case .unrecognised(let status): return "Accepted; Slant now shows the status \(status), which Studio doesn’t recognise"
    case .unclear: return "Accepted, but Slant’s reply didn’t show the order’s status, so it may still be charged"
    case .changed, .refused, .unknown, .notSent: return "Not confirmed"
    }
}
/// The pay review's warning when this draft's marketplace order (`batchPayMarketplaceKey`) already has a placed order
/// among the loaded orders, or another loaded draft is for it. Advisory only: it never changes whether Pay is enabled
/// or which button is the default. Nil when the draft has no marketplace reference or nothing matches.
func orderReviewMarketplaceDuplicateNotice(_ order: [String: Any], orderID: String, loaded: [Record]) -> String? {
    guard let key = batchPayMarketplaceKey(order), let line = orderMarketplaceReferenceLine(order) else { return nil }
    let others = loaded.filter { record in
        !record.id.isEmpty && record.id != orderID && !orderBelongs(orderObject(record.values), to: orderID)
    }
    if batchPayPlacedMarketplaceKeys(others).contains(key) {
        return "Possible duplicate: \(line) already has a placed order."
    }
    let otherDraft = others.contains { record in
        let other = orderObject(record.values)
        return batchPayIsDraft(other) && batchPayMarketplaceKey(other) == key
    }
    return otherDraft ? "Possible duplicate: another draft is also for \(line)." : nil
}
/// True for a Cancel press (or Escape) that follows a popover closing so closely that it is the same keystroke.
func composerCancelFollowsPopoverClose(closedAt: Date?, now: Date) -> Bool {
    guard let closedAt else { return false }
    let elapsed = now.timeIntervalSince(closedAt)
    return elapsed >= 0 && elapsed < 0.4
}
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
/// The Orders review sheet's Pay / Cancel gate: whether the button may be pressed (before the sheet's own busy,
/// writing and shared-lock checks) and, when the order's status rules it out, why.
struct OrderConfirmReviewGate: Equatable {
    var enabled: Bool
    var reason: String?
}
/// The review sheet's gate for the order it loaded. It takes the order, not a status, and reads Slant's own `status`
/// itself, so the status shown (`orderDisplayStatus`, which can say Shipped while Slant says Printing) can never be
/// passed in its place.
func orderConfirmReviewGate(order: [String: Any]?, loaded: Bool, isPay: Bool,
                            writeSucceeded: Bool, writeAttempted: Bool) -> OrderConfirmReviewGate {
    let status = order.flatMap { $0["status"] as? String }
    let check = isPay ? workbenchChargeAllowed(status: status, loaded: loaded, order: order)
        : orderCancelConfirmAllowed(status: status, loaded: loaded)
    let enabled = orderConfirmFinalActionEnabled(writeSucceeded: writeSucceeded, writeAttempted: writeAttempted,
                                                 loaded: loaded, status: status, isPay: isPay, order: order)
    return OrderConfirmReviewGate(enabled: enabled, reason: check.1)
}
func orderConfirmRecheck(method: String, shown: [String: Any], latest: [String: Any]) -> OrderConfirmRecheckResult {
    let status = (latest["status"] as? String) ?? ""
    let shownStatus = (shown["status"] as? String) ?? ""
    if method == "POST" {
        if status.uppercased() != "DRAFT" { return .statusBlocked("Only drafts can be placed.") }
        if !workbenchOrderHasNumericTotal(shown) || !workbenchOrderHasNumericTotal(latest) {
            return .statusBlocked("Couldn’t confirm a total for this order.")
        }
        // A tax or fee field that appeared or changed since the review could change the charge without changing the
        // total Studio adds up, so it stops the payment like a changed price (the review then shows it).
        if orderUnlistedCostSignature(shown) != orderUnlistedCostSignature(latest) { return .priceChanged }
    } else {
        if shownStatus.uppercased() != status.uppercased() {
            return .statusBlocked("This order’s status changed. Review it again.")
        }
        // Slant's order status can lag its shipping record, so a record or tracking that changed since the review
        // (the parcel may have shipped) stops the cancel too, before the lock is recorded or anything is sent. It can
        // only stop: eligibility below is still decided by Slant's own status alone.
        if orderShippingDetails(shown) != orderShippingDetails(latest) {
            return .statusBlocked(orderShippingDetailsChangedMessage)
        }
        if !orderCanRequestCancellation(status) {
            return .statusBlocked(orderCancellationBlockedReason(status) ?? "This order can’t be cancelled.")
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
    orderCreatedRaw(order).map(orderDateLabel)
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
func orderMatchesSearch(_ order: Record, query: String, modelNames: [String: String] = [:]) -> Bool {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    let values = orderObject(order.values)
    var fields = [
        order.string("publicId", "id"),
        orderStatusTitle(order.string("status")),
        // Slant's own status word too, so "canceled" still finds orders shown as "Cancelled".
        order.string("status").replacingOccurrences(of: "_", with: " "),
        // And the status shown when the shipping record says it shipped (`orderDisplayStatus`), so "shipped" and
        // "printing" both find such an order.
        orderDisplayStatusTitle(values),
        orderRecipientName(values),
        orderCity(values)
    ]
    if let items = values["items"] as? [[String: Any]] {
        fields.append(contentsOf: items.map { orderItemDisplayName($0, modelNames: modelNames) })
    }
    if let reference = orderMarketplaceReference(values) { fields.append(reference.id) }
    return fields.contains { $0.localizedCaseInsensitiveContains(trimmed) }
}

func orderCanRequestCancellation(_ status: String) -> Bool {
    let normalized = status.uppercased()
    guard orderKnownStatuses.contains(normalized) else { return false }
    // Slant refuses DELETE on drafts ("Can not cancel a draft order", seen 23 Oct 2026), so drafts offer no cancel.
    return !orderStatusIsCancelled(normalized) && normalized != "DRAFT"
}
func orderCancellationIsRefundOnly(_ status: String) -> Bool {
    ["SHIPPED", "DELIVERED"].contains(status.uppercased())
}
func orderCancellationBlockedReason(_ status: String) -> String? {
    if orderCanRequestCancellation(status) { return nil }
    if orderStatusIsCancelled(status) { return "This order was already cancelled." }
    let shown = status.trimmingCharacters(in: .whitespacesAndNewlines)
    if shown.uppercased() == "DRAFT" { return "Slant doesn’t cancel drafts. A draft costs nothing unless you place it." }
    // Every other known status can be cancelled, so what's left is a status Studio doesn't know (Slant changed its
    // statuses without notice on 26 Oct 2026): say so rather than claim Slant can't cancel it.
    if shown.isEmpty {
        return "Slant didn’t return this order’s status, so Studio doesn’t offer Cancel. Check the order on Slant."
    }
    return "Studio doesn’t recognise this order’s status (“\(orderStatusQuoted(shown))”), so it doesn’t offer Cancel. Check the order on Slant."
}
/// A status from Slant as quoted in copy: at most 40 characters, control characters dropped.
func orderStatusQuoted(_ status: String) -> String {
    let cleaned = String(String.UnicodeScalarView(status.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return cleaned.count > 40 ? String(cleaned.prefix(40)) + "…" : cleaned
}
/// The note shown in an order's details instead of Cancel…, or nil. Omitted for finished orders (cancelled, shipped,
/// delivered, complete), whose status heading already says why; kept where it tells the user something, such as a
/// status Studio doesn't recognise.
func orderDetailCancelBlockedNote(_ status: String) -> String? {
    // Drafts say why they have no Cancel in their caption under the buttons (`orderDetailDraftCaption`).
    if orderStatusIsCancelled(status) { return nil }
    let finished: Set<String> = ["SHIPPED", "DELIVERED", "DRAFT"]
    if finished.contains(status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()) { return nil }
    return orderCancellationBlockedReason(status)
}
func orderCancelConfirmAllowed(status: String?, loaded: Bool) -> (Bool, String?) {
    guard loaded else { return (false, "Couldn’t load this order.") }
    guard let status, orderCanRequestCancellation(status) else {
        return (false, orderCancellationBlockedReason(status ?? "") ?? "This order can’t be cancelled.")
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
    case "QUEUED", "PRINTING", "AWAITING_SHIPMENT", "PROCESSING", "PAID", "SUBMITTED", "IN_REVIEW",
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
        return "This order already shipped, so Slant refunds it but can’t stop delivery."
    case "PAYMENT_ERROR":
        return "Cancellation may be possible. A refund isn’t promised for payment-problem orders."
    case "QUEUED", "PRINTING", "AWAITING_SHIPMENT", "PROCESSING", "PAID", "SUBMITTED", "IN_REVIEW",
         "POST_PROCESSING", "ITEMS_ON_SHELF", "COMPLETED":
        return "Slant will cancel when eligible and refund according to their rules."
    default:
        return "Cancellation may be possible. A refund isn’t promised for this status."
    }
}
/// The cancel review's explanation for the order shown. When Slant's shipping record says the order shipped while its
/// status still says it's being made (`orderStatusLagsShippingRecord`), Slant probably can't stop the delivery and
/// decides what happens; otherwise the status's own wording. Wording only: whether Cancel is offered is still decided
/// by Slant's own status.
func orderCancelSheetBody(order: [String: Any]?) -> String {
    guard let order else { return orderCancelSheetBody("") }
    if orderStatusLagsShippingRecord(order) {
        return "Slant’s shipping record says this order has shipped, so Slant probably can’t stop the delivery. Slant decides whether to cancel it and what to refund."
    }
    return orderCancelSheetBody((order["status"] as? String) ?? "")
}
/// A hover hint for live statuses whose title alone is vague, in Slant's own words (docs, read 28 Oct 2026), or nil.
func orderStatusHelp(_ status: String) -> String? {
    switch status.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
    case "SUBMITTED": "Paid, waiting to print"
    case "PRINTING": "In production: printing, finishing and packing"
    default: nil
    }
}
func orderStatusTitle(_ status: String) -> String {
    switch status.uppercased() {
    case "DRAFT": "Draft"
    case "PAID": "Paid"
    case "SUBMITTED": "Submitted"
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
    case "CANCELED", "CANCELLED": "Cancelled"
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
/// An order item's name. Items Studio drafts carry `name: null`, so a print item's uploaded model is looked up in
/// `modelNames` (see `orderItemModelNames`) before falling back to the item type. Display only: never sent to Slant.
func orderItemDisplayName(_ item: [String: Any], modelNames: [String: String] = [:]) -> String {
    if let name = item["name"] as? String, !name.isEmpty { return name }
    if let printItem = item["printItem"] as? [String: Any], let name = printItem["name"] as? String, !name.isEmpty { return name }
    if let component = item["componentItem"] as? [String: Any], let name = component["componentName"] as? String, !name.isEmpty { return name }
    if let name = item["componentName"] as? String, !name.isEmpty { return name }
    if let stationery = item["stationeryItem"] as? [String: Any], let name = stationery["stationeryName"] as? String, !name.isEmpty { return name }
    if let name = item["stationeryName"] as? String, !name.isEmpty { return name }
    if let fileID = orderItemFileID(item), let name = modelNames[fileID] { return name }
    if let type = item["type"] as? String, !type.isEmpty {
        if type.uppercased() == "PRINT" { return "3D print" }
        return type.replacingOccurrences(of: "_", with: " ").capitalized
    }
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
    // Same date as the orders table's Arrive by column (a date-only value isn't shifted a day by the time zone).
    if let arrive = order["arriveByDate"] as? String, !arrive.isEmpty { return orderTimestamp(arrive).map(orderArriveByLabel) ?? orderDateLabel(arrive) }
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
    /// `delivery` is the seller's own saved address (Order a Sample to Me…), shown as fields to check.
    var usesSellerAddress = false
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
        if let quantity = orderItemQuantity(item), quantity > 0 {
            line.quantity = quantity
        } else {
            skipped.append("\(title): quantity not copied, set to 1. Check it before creating the draft.")
        }
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
    for region in Locale.Region.isoRegions where isCountryCode(region.identifier) && !orderNonCountryRegionCodes.contains(region.identifier) {
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
    // Slant names an order's platform in `customer.platformId` (every order seen, 29 Oct 2026); a top-level
    // `platformId` is read too, for other replies.
    let platform = orderNamedPlatformID(values) ?? ""
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

/// Duplicate as New Draft's platform: the source order's when the loaded platform list (Slant lists only enabled
/// platforms) has it; otherwise the composer keeps `current`, and `notCopied` says so when they differ.
func orderComposerPlatformSeed(copied: String, current: String, loadedPlatformIDs: [String]) -> (platformID: String, notCopied: Bool) {
    if loadedPlatformIDs.contains(copied) { return (copied, false) }
    return (current, copied != current)
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

/// True when closing the composer would lose something the user entered: lines, delivery, shipping provider or
/// platform changed from what the form opened with, or metadata / payment ID typed.
func orderComposerHasUnsavedInput(
    lines: [OrderLine], initialLines: [OrderLine],
    delivery: DeliveryDetails, initialDelivery: DeliveryDetails,
    metadataFields: [OrderMetadataField], paymentID: String,
    shippingProvider: String = "", initialShippingProvider: String = "",
    platformID: String = "", initialPlatformID: String = ""
) -> Bool {
    if !orderLinesHaveSameContent(lines, initialLines) { return true }
    if delivery != initialDelivery { return true }
    if shippingProvider != initialShippingProvider { return true }
    if platformID.trimmingCharacters(in: .whitespacesAndNewlines) != initialPlatformID.trimmingCharacters(in: .whitespacesAndNewlines) { return true }
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

/// Neutral notice shown under a quantity at or above the threshold (order composer and Models print configuration).
func largeQuantityNotice(_ quantity: Int, threshold: Int = orderLargeQuantityThreshold) -> String? {
    guard isLargeOrderQuantity(quantity, threshold: threshold) else { return nil }
    return "Large quantity (\(quantity)) — check for an extra zero."
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
                let showsItemStatus = orderItemStatusesDiffer(items)
                let modelNames = orderItemModelNames(localModels: store.localModels, files: store.files)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(orderItemLineText(item, modelNames: modelNames))
                            Spacer()
                            if item["price"] != nil { Text(money(item["price"])).monospacedDigit() }
                        }
                        if let material = orderItemMaterialName(item, filaments: store.filaments) {
                            Text("Material: \(materialDisplayName(material))").font(.caption).foregroundStyle(.secondary)
                        }
                        if showsItemStatus, let itemStatus = orderItemStatusTitle(item) {
                            Text("Item status: \(itemStatus)").font(.caption).foregroundStyle(.secondary)
                        }
                        // Slant's per-item production progress (OrderDetailExtras.swift); never shown for drafts, nor
                        // once the shipping record says the order shipped (`orderDisplayStatus`).
                        if let progress = orderItemProgressLine(item, orderStatus: orderDisplayStatus(order)) {
                            Text("Production: \(progress)").font(.caption).foregroundStyle(.secondary)
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
            // Advisory only: the address Slant's label was made for, when it differs (OrderDetailExtras.swift).
            if let advisory = orderLabelAddressAdvisory(order) {
                Label(advisory.line, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .help("Differs from the order’s address in: \(advisory.differences.joined(separator: ", ")).")
            }
            // Orders being made or shipped show tracking above the costs; drafts and cancelled orders skip it.
            if orderDetailShowsTracking(status: status, hasTrackingDetails: !tracking.isEmpty || fulfillmentArriveBy(order) != nil) {
                trackingSection
                Divider()
            }
            // A receipt: labels on the left, values in a right-aligned column.
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Print cost") { Text(money(order["printingCost"])).monospacedDigit() }
                LabeledContent("Delivery cost") { Text(money(order["deliveryCost"])).monospacedDigit() }
                LabeledContent("Total") { Text(orderTotalMoney(order)).monospacedDigit().fontWeight(.semibold) }
                ForEach(Array(orderDetailFacts(order).enumerated()), id: \.offset) { _, fact in
                    LabeledContent(fact.0) { Text(fact.1).textSelection(.enabled) }
                }
            }
            .labeledContentStyle(.receipt)
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
            if let reference = orderMarketplaceReference(order) {
                let label = orderMarketplaceReferenceLabel(source: reference.source)
                HStack {
                    Text("\(label): \(reference.id)").textSelection(.enabled).lineLimit(2)
                    Button { copyToPasteboard(reference.id) } label: { Image(systemName: "doc.on.doc") }
                        .accessibilityLabel("Copy \(label.lowercased()) number").help("Copy \(label.lowercased()) number")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            // Keyed by order so amounts typed for one order never carry over to another.
            ProfitCheckPanel(order: order, imported: importedSaleAmountsLookup(store.importedSaleAmounts, order: order))
                .id(Record(values: order).id)
            DisclosureGroup("Technical details") { JSONView(text: prettyJSON(hidingSecrets(order))).frame(height: 220) }.studioDisclosureStyle()
        }
    }

    @ViewBuilder
    var trackingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
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
                        } else if ["Carrier", "Service", "Shipment status"].contains(row.0) {
                            // Readable words for Slant's constants (SHIPPO, INTERNATIONAL); display only.
                            Text(orderAPIValueTitle(row.1)).textSelection(.enabled).help(row.1)
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
        }
    }
}

/// Receipt rows for totals: the label on the left and the value in a right-aligned column, so amounts line up
/// down the right edge. A plain HStack, with no measuring or preferences.
struct ReceiptLabeledContentStyle: LabeledContentStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // No layout priority: a fixed-width field (Profit check) keeps its width and a long label wraps instead.
            configuration.label
            Spacer(minLength: 12)
            configuration.content
                .multilineTextAlignment(.trailing)
        }
    }
}

extension LabeledContentStyle where Self == ReceiptLabeledContentStyle {
    static var receipt: ReceiptLabeledContentStyle { ReceiptLabeledContentStyle() }
}
