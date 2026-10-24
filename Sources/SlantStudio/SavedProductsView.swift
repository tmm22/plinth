import SwiftUI

// MARK: - Saved product UI logic (pure; tested in SavedProductsTests)

let savedProductItemTypes: [(type: String, title: String)] = [("PRINT", "3D print"), ("COMPONENT", "Component"), ("STATIONERY", "Stationery")]

func savedProductsSorted(_ products: [SavedProduct]) -> [SavedProduct] {
    products.sorted {
        let order = savedProductDisplayName($0).localizedStandardCompare(savedProductDisplayName($1))
        return order == .orderedSame ? $0.created < $1.created : order == .orderedAscending
    }
}

func savedProductDisplayName(_ product: SavedProduct) -> String {
    let name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
    return name.isEmpty ? "Untitled product" : name
}

/// A library model counts as uploaded once it has a Slant file ID.
func localModelIsUploaded(_ model: LocalModel) -> Bool {
    !(model.remoteID ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
}

/// What a line is called in summaries: its own item name, else the model or catalog entry, else its type.
func savedProductLineTitle(_ line: SavedProductLine, localModels: [LocalModel], components: [Record], stationery: [Record]) -> String {
    let named = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !named.isEmpty { return named }
    let reference = line.reference.trimmingCharacters(in: .whitespacesAndNewlines)
    switch line.type {
    case "PRINT":
        if let id = line.localModelID, let model = localModels.first(where: { $0.id == id }) { return model.name }
        if !reference.isEmpty, let model = localModels.first(where: { $0.remoteID == reference }) { return model.name }
        return "3D print"
    case "COMPONENT":
        if !reference.isEmpty, let record = components.first(where: { $0.id == reference }) { return displayName(for: record, fallback: "Component") }
        return "Component"
    case "STATIONERY":
        if !reference.isEmpty, let record = stationery.first(where: { $0.id == reference }) { return displayName(for: record, fallback: "Stationery") }
        return "Stationery"
    default:
        return "Item"
    }
}

/// What a resolved draft line is called: its item name, else the model or catalog entry its reference names, else its type.
func savedProductOrderLineTitle(_ line: OrderLine, localModels: [LocalModel], components: [Record], stationery: [Record]) -> String {
    var saved = SavedProductLine()
    saved.type = line.type
    saved.reference = line.reference
    saved.name = line.name
    return savedProductLineTitle(saved, localModels: localModels, components: components, stationery: stationery)
}

/// The draft lines a product resolved to, e.g. "6 × Bracket, 1 × Packing slip".
func savedProductResolvedLinesSummary(_ lines: [OrderLine], localModels: [LocalModel], components: [Record], stationery: [Record]) -> String {
    lines.map { "\($0.quantity) × \(savedProductOrderLineTitle($0, localModels: localModels, components: components, stationery: stationery))" }
        .joined(separator: ", ")
}

/// Units sold as typed in the Add Saved Product popover: a whole number from 1 to 10,000, otherwise nil.
func savedProductUnitsSold(_ text: String) -> Int? {
    orderImportQuantity(text)
}

/// One line per product in the list, e.g. "1 × Bracket in PLA Black · Packing slip per order".
func savedProductItemsSummary(
    _ product: SavedProduct, localModels: [LocalModel], filaments: [Record], components: [Record], stationery: [Record]
) -> String {
    guard !product.lines.isEmpty else { return "No items" }
    return product.lines.map { line in
        let title = savedProductLineTitle(line, localModels: localModels, components: components, stationery: stationery)
        var text = line.perOrder && line.quantity == 1 ? title : "\(line.quantity) × \(title)"
        if line.type == "PRINT", !line.filamentID.isEmpty, let filament = filaments.first(where: { $0.id == line.filamentID }) {
            text += " in \(displayName(for: filament, fallback: "Untitled material"))"
        }
        if line.perOrder { text += " per order" }
        if line.type == "PRINT", line.template != nil { text += ", personalised" }
        return text
    }.joined(separator: " · ")
}

/// Why the editor can't save yet, or nil. Missing uploads and out-of-stock materials don't block saving: they are
/// reported when the product is added to a draft, so a product can be set up before its model is uploaded.
func savedProductSaveBlockedReason(_ product: SavedProduct, in products: [SavedProduct], localModels: [LocalModel]) -> String? {
    if product.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Enter a product name." }
    if let conflict = savedProductSKUConflict(product.sku, for: product.id, in: products) { return conflict }
    if product.lines.isEmpty { return "Add at least one item." }
    for (index, line) in product.lines.enumerated() {
        let item = product.lines.count == 1 ? "the item" : "item \(index + 1)"
        guard (1...10_000).contains(line.quantity) else { return "Set a quantity from 1 to 10,000 for \(item)." }
        let reference = line.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        switch line.type {
        case "PRINT":
            if let id = line.localModelID {
                if !localModels.contains(where: { $0.id == id }), reference.isEmpty {
                    return "The model for \(item) is no longer in your library. Choose another."
                }
            } else if reference.isEmpty {
                return "Choose a model for \(item)."
            }
            if line.filamentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Choose a material for \(item)." }
        case "COMPONENT":
            if reference.isEmpty { return "Choose a component for \(item)." }
        case "STATIONERY":
            if reference.isEmpty { return "Choose stationery for \(item)." }
            if !isHTTPSImageURL(line.imageURL) { return "Enter an https image link for \(item), or leave it blank." }
        default:
            return "Choose a type for \(item)."
        }
    }
    return savedProductTemplateLinkProblem(product)
}

/// Trims what was typed, drops fields that don't apply to a line's type and refreshes each print line's file
/// snapshot from its library model. Only item references, names and quantities are kept.
func savedProductForSaving(_ product: SavedProduct, localModels: [LocalModel]) -> SavedProduct {
    var result = product
    result.name = product.name.trimmingCharacters(in: .whitespacesAndNewlines)
    result.sku = product.sku.trimmingCharacters(in: .whitespacesAndNewlines)
    result.lines = product.lines.map { saved in
        var line = saved
        line.name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        line.reference = saved.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        line.filamentID = saved.type == "PRINT" ? saved.filamentID.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        line.imageURL = saved.type == "STATIONERY" ? saved.imageURL.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        line.template = saved.type == "PRINT" ? saved.template.map(savedProductTemplateLinkTrimmed) : nil
        if saved.type == "PRINT" {
            if let id = saved.localModelID, let model = localModels.first(where: { $0.id == id }), localModelIsUploaded(model) {
                line.reference = (model.remoteID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            line.localModelID = nil
        }
        return line
    }
    return result
}

/// Changing an item's type clears its choices; stationery (packing slips, inserts) defaults to once per order.
func savedProductLine(_ line: SavedProductLine, changingTypeTo type: String) -> SavedProductLine {
    guard line.type != type else { return line }
    var result = line
    result.type = type
    result.reference = ""
    result.localModelID = nil
    result.filamentID = ""
    result.imageURL = ""
    result.optionsJSON = "{}"
    result.template = nil
    result.perOrder = type == "STATIONERY"
    return result
}

/// Links a print line to a library model, taking its current upload (if any) as the file snapshot.
func savedProductLine(_ line: SavedProductLine, selectingModel model: LocalModel?) -> SavedProductLine {
    var result = line
    result.localModelID = model?.id
    result.reference = model.flatMap { localModelIsUploaded($0) ? $0.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines) : nil } ?? ""
    return result
}

func newSavedProductLine() -> SavedProductLine {
    SavedProductLine()
}

/// Models › Save as Product…: one print of the model, in its prepared material when it has one, otherwise the
/// material selected in Print configuration.
func savedProductPrefill(for model: LocalModel, selectedFilamentID: String) -> SavedProduct {
    var line = savedProductLine(newSavedProductLine(), selectingModel: model)
    let prepared = (model.printRecipe?.materialID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    line.filamentID = prepared.isEmpty ? selectedFilamentID.trimmingCharacters(in: .whitespacesAndNewlines) : prepared
    return SavedProduct(name: model.name, lines: [line])
}

/// A copy to edit before saving: new IDs, a distinct name and no SKU (SKUs are unique).
func savedProductDuplicate(_ product: SavedProduct, in products: [SavedProduct], now: Date = Date()) -> SavedProduct {
    var copy = product
    copy.id = UUID()
    copy.sku = ""
    copy.created = now
    copy.lines = product.lines.map { line in
        var line = line
        line.id = UUID()
        return line
    }
    let base = "\(savedProductDisplayName(product)) copy"
    let taken = Set(products.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
    var name = base
    var number = 2
    while taken.contains(name.lowercased()) {
        name = "\(base) \(number)"
        number += 1
    }
    copy.name = name
    return copy
}

/// Read-only catalogs the editor needs for these item types and hasn't loaded yet, in a fixed order.
func savedProductCatalogsToLoad(lineTypes: Set<String>, loaded: Set<Destination>) -> [Destination] {
    var kinds: [Destination] = []
    if lineTypes.contains("PRINT"), !loaded.contains(.materials) { kinds.append(.materials) }
    if lineTypes.contains("COMPONENT"), !loaded.contains(.components) { kinds.append(.components) }
    if lineTypes.contains("STATIONERY"), !loaded.contains(.stationery) { kinds.append(.stationery) }
    return kinds
}

/// A composer line nothing has been chosen for yet (material and quantity may hold defaults).
func orderLineIsBlankStarter(_ line: OrderLine) -> Bool {
    [line.reference, line.name, line.sku, line.imageURL].allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        && orderLineOptionsSummary(line.optionsJSON).isEmpty
}

/// Adds a saved product's lines after the draft's existing lines. A single untouched starter line is replaced
/// rather than left behind as an empty item.
func orderLinesAddingSavedProduct(_ lines: [OrderLine], adding added: [OrderLine]) -> [OrderLine] {
    guard !added.isEmpty else { return lines }
    if lines.count == 1, let only = lines.first, orderLineIsBlankStarter(only) { return added }
    return lines + added
}

// MARK: - Saved Products sheet

struct SavedProductsSheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var editing: SavedProduct?
    @State private var editingBaseline: SavedProduct?
    @State private var editorIsNew = false
    @State private var openedForPrefill = false
    @State private var didSeed = false
    @State private var pendingDelete: SavedProduct?
    @State private var confirmDiscardEdit = false
    @State private var saveError: String?
    @State private var catalogsLoading = false
    /// Check Cost… (ProductCostCheck.swift) shows in place of the list; its results go when it closes.
    @State private var costCheckProduct: SavedProduct?

    var sortedProducts: [SavedProduct] { savedProductsSorted(store.savedProducts) }
    var selectedProduct: SavedProduct? { store.savedProducts.first { $0.id == selection } }
    var editorHasChanges: Bool { editing != nil && editing != editingBaseline }
    var neededLineTypes: Set<String> {
        if let editing { return Set(editing.lines.map(\.type)) }
        return Set(store.savedProducts.flatMap { $0.lines.map(\.type) })
    }

    var body: some View {
        Group {
            if editing != nil {
                // A field that commits as the editor closes must not reopen it, so writes only land while editing.
                editor(Binding(get: { editing ?? editingBaseline ?? SavedProduct() }, set: { if editing != nil { editing = $0 } }))
            } else if let costCheckProduct {
                ProductCostCheckView(product: costCheckProduct) { self.costCheckProduct = nil }
            } else {
                productList
            }
        }
        // An ideal width keeps long footnotes from widening the sheet, which left the grouped form centred in it.
        .frame(minWidth: 680, idealWidth: 720, minHeight: 540)
        .interactiveDismissDisabled(editorHasChanges)
        .onAppear(perform: seedIfNeeded)
        .onDisappear { store.pendingSavedProductDraft = nil }
        .task(id: neededLineTypes.sorted().joined(separator: ",")) { startCatalogLoads() }
        .confirmationDialog(
            "Delete “\(pendingDelete.map(savedProductDisplayName) ?? "")”?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: pendingDelete
        ) { product in
            Button("Delete Product", role: .destructive) {
                store.removeSavedProduct(id: product.id)
                if selection == product.id { selection = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("The product is removed from Slant Studio. Models, drafts and orders aren’t changed, and nothing is sent to Slant.")
        }
        .confirmationDialog("Discard changes to this product?", isPresented: $confirmDiscardEdit) {
            Button("Discard Changes", role: .destructive) { finishEditing() }
            Button("Keep Editing", role: .cancel) {}
        } message: {
            Text("Your changes haven’t been saved.")
        }
    }

    // MARK: List

    private var productList: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Saved Products").font(.title2.weight(.semibold))
                Text("Products you sell often, ready to add to an order draft in one step. A product keeps its items, materials and SKU on this Mac — never prices or customer details.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            if store.savedProducts.isEmpty {
                ContentUnavailableView {
                    Label("No Saved Products", systemImage: "shippingbox")
                } description: {
                    Text("Add a product here, or choose Save as Product… from a model’s More actions menu in Models.")
                } actions: {
                    Button("Add Product") { beginEditing(SavedProduct(lines: [newSavedProductLine()]), isNew: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    ForEach(sortedProducts) { product in
                        productRow(product).tag(product.id)
                    }
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if ids.count == 1, let id = ids.first, let product = store.savedProducts.first(where: { $0.id == id }) {
                        Button("Edit…") { beginEditing(product, isNew: false) }
                        Button("Duplicate") { beginEditing(savedProductDuplicate(product, in: store.savedProducts), isNew: true) }
                        Button("Check Cost…") { costCheckProduct = product }
                        Divider()
                        Button("Delete…", role: .destructive) { pendingDelete = product }
                    }
                } primaryAction: { ids in
                    if ids.count == 1, let id = ids.first, let product = store.savedProducts.first(where: { $0.id == id }) {
                        beginEditing(product, isNew: false)
                    }
                }
            }
            HStack {
                Button { beginEditing(SavedProduct(lines: [newSavedProductLine()]), isNew: true) } label: {
                    Label("Add Product", systemImage: "plus")
                }
                Button("Edit…") { if let selectedProduct { beginEditing(selectedProduct, isNew: false) } }
                    .disabled(selectedProduct == nil)
                Button("Duplicate") {
                    if let selectedProduct { beginEditing(savedProductDuplicate(selectedProduct, in: store.savedProducts), isNew: true) }
                }
                .disabled(selectedProduct == nil)
                .help("Copy the selected product to edit, for example in another colour")
                Button("Check Cost…") { costCheckProduct = selectedProduct }
                    .disabled(selectedProduct == nil)
                    .help("Price the selected product with fresh Slant estimates")
                Button("Delete…", role: .destructive) { pendingDelete = selectedProduct }
                    .disabled(selectedProduct == nil)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(16)
            .background(.bar)
        }
    }

    private func productRow(_ product: SavedProduct) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(savedProductDisplayName(product)).fontWeight(.medium).lineLimit(1)
                let sku = product.sku.trimmingCharacters(in: .whitespacesAndNewlines)
                if !sku.isEmpty {
                    Text(sku).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Text(savedProductItemsSummary(product, localModels: store.localModels, filaments: store.filaments,
                                          components: store.components, stationery: store.stationery))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 3)
    }

    // MARK: Editor

    private func editor(_ product: Binding<SavedProduct>) -> some View {
        let blockedReason = savedProductSaveBlockedReason(product.wrappedValue, in: store.savedProducts, localModels: store.localModels)
        let skuConflict = savedProductSKUConflict(product.wrappedValue.sku, for: product.wrappedValue.id, in: store.savedProducts)
        return VStack(spacing: 0) {
            Text(editorIsNew ? "New Product" : "Edit Product")
                .font(.title2.weight(.semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 16)
            Form {
                Section("Product") {
                    TextField("Name", text: product.name)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("SKU (optional)", text: product.sku)
                        if let skuConflict {
                            Label("\(skuConflict) Each SKU can belong to one product.", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        } else {
                            Text("Your shop’s SKU for this product. It’s sent with each item of a draft made from it. Needed to match imported orders.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    ForEach(product.lines) { $line in
                        lineEditor($line, canRemove: product.wrappedValue.lines.count > 1) {
                            product.wrappedValue.lines.removeAll { $0.id == line.id }
                        }
                    }
                    Button { product.wrappedValue.lines.append(newSavedProductLine()) } label: {
                        Label("Add another item", systemImage: "plus")
                    }
                } header: {
                    Text("Items")
                } footer: {
                    Text("Quantities are per unit sold: 2 units of a product with 3 prints adds 6 prints. Items set to once per order, such as a packing slip, are added once however many units are sold.")
                        .font(.caption).foregroundStyle(.secondary)
                        .settingsFooterLayout()
                }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel", role: .cancel) { requestCancelEdit() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                if let saveError {
                    Text(saveError).font(.caption).foregroundStyle(.orange).lineLimit(2)
                } else if let blockedReason {
                    Text(blockedReason).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Button("Save Product") { save() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(blockedReason != nil)
                    .help(blockedReason ?? "Save this product")
            }
            .padding(16)
            .background(.bar)
        }
        .onChange(of: product.wrappedValue) { _, _ in saveError = nil }
    }

    @ViewBuilder
    private func lineEditor(_ line: Binding<SavedProductLine>, canRemove: Bool, remove: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("Type", selection: Binding(
                    get: { line.wrappedValue.type },
                    set: { line.wrappedValue = savedProductLine(line.wrappedValue, changingTypeTo: $0) }
                )) {
                    ForEach(savedProductItemTypes, id: \.type) { Text($0.title).tag($0.type) }
                    if !savedProductItemTypes.contains(where: { $0.type == line.wrappedValue.type }) {
                        Text("Unknown type").tag(line.wrappedValue.type)
                    }
                }
                .frame(width: 210)
                // Text plus a label-less stepper: in a grouped Form a labelled Stepper is drawn as a form row, which put
                // the arrows at the far edge away from the number.
                HStack(spacing: 4) {
                    Text("Quantity: \(line.wrappedValue.quantity)").monospacedDigit()
                    Stepper("Quantity", value: line.quantity, in: 1...10000)
                        .labelsHidden()
                        .accessibilityValue("\(line.wrappedValue.quantity)")
                }
                .fixedSize()
                Spacer(minLength: 0)
                Button(role: .destructive, action: remove) { Image(systemName: "minus.circle") }
                    .accessibilityLabel("Remove item")
                    .help(canRemove ? "Remove item" : "A product needs at least one item.")
                    .disabled(!canRemove)
            }
            // Explained once, in the Items footer.
            Toggle("Once per order", isOn: line.perOrder)
                .help("Added once to each order, however many units are sold")
            switch line.wrappedValue.type {
            case "PRINT":
                modelPicker(line)
                materialField(line)
                // Personalised imports (BatchPersonaliseView.swift).
                SavedProductTemplateLinkEditor(link: line.template)
            case "COMPONENT":
                catalogField(.components, title: "Component", placeholder: "Choose a component", records: store.components, selection: line.reference)
            case "STATIONERY":
                catalogField(.stationery, title: "Stationery", placeholder: "Choose stationery", records: store.stationery, selection: line.reference)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Custom image link (optional, starts with https://)", text: line.imageURL)
                    if !isHTTPSImageURL(line.wrappedValue.imageURL) {
                        Text("Enter an https image link with a website address, or leave it blank.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            default:
                Text("Choose a type for this item.").font(.callout).foregroundStyle(.orange)
            }
            TextField("Item name (optional)", text: line.name)
        }
    }

    @ViewBuilder
    private func modelPicker(_ line: Binding<SavedProductLine>) -> some View {
        let models = store.localModels.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if store.localModels.isEmpty, line.wrappedValue.localModelID == nil {
            Text("Your model library is empty. Import a model in Models first.").font(.callout).foregroundStyle(.secondary)
        } else {
            Picker("Model", selection: Binding<UUID?>(
                get: { line.wrappedValue.localModelID },
                set: { id in line.wrappedValue = savedProductLine(line.wrappedValue, selectingModel: store.localModels.first { $0.id == id }) }
            )) {
                Text("Choose a library model").tag(UUID?.none)
                if let id = line.wrappedValue.localModelID, !store.localModels.contains(where: { $0.id == id }) {
                    Text("Removed from library").tag(UUID?.some(id))
                }
                ForEach(models) { model in
                    Text(localModelIsUploaded(model) ? model.name : "\(model.name) — not uploaded").tag(UUID?.some(model.id))
                }
            }
        }
        if let id = line.wrappedValue.localModelID {
            if let model = store.localModels.first(where: { $0.id == id }) {
                if !localModelIsUploaded(model) {
                    Label("Not uploaded yet. You can save the product now; upload the model before adding it to a draft.", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Label(line.wrappedValue.reference.isEmpty
                      ? "This model was removed from your library. Choose another."
                      : "This model was removed from your library. Drafts use its last uploaded file until you choose another.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        } else if !line.wrappedValue.reference.isEmpty {
            Text("Uses Slant file \(line.wrappedValue.reference). Choose a library model to replace it.")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func materialField(_ line: Binding<SavedProductLine>) -> some View {
        if store.filaments.isEmpty {
            catalogNotLoaded(.materials)
            TextField("Material reference", text: line.filamentID)
        } else {
            let selected = line.wrappedValue.filamentID
            Picker("Material", selection: line.filamentID) {
                Text("Choose a material").tag("")
                if !selected.isEmpty, !store.filaments.contains(where: { $0.id == selected }) {
                    Text("No longer offered").tag(selected)
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
            if let filament = store.filaments.first(where: { $0.id == selected }), filamentAvailability(filament) == false {
                Label("Out of stock. Drafts can’t use this product until it’s back in stock or you choose another material.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder
    private func catalogField(_ kind: Destination, title: String, placeholder: String, records: [Record], selection: Binding<String>) -> some View {
        if records.isEmpty {
            catalogNotLoaded(kind)
            TextField("\(title) reference", text: selection)
        } else {
            Picker(title, selection: selection) {
                Text(placeholder).tag("")
                if !selection.wrappedValue.isEmpty, !records.contains(where: { $0.id == selection.wrappedValue }) {
                    Text("No longer offered").tag(selection.wrappedValue)
                }
                ForEach(indexedRecords(records), id: \.id) { row in
                    Text(displayName(for: row.record, fallback: "Untitled")).tag(row.record.id)
                }
            }
        }
    }

    @ViewBuilder
    private func catalogNotLoaded(_ kind: Destination) -> some View {
        let loaded = store.loadedCatalogs.contains(kind)
        HStack {
            Text(loaded ? catalogEmptyMessage(kind) : (catalogsLoading ? "Loading…" : "Not loaded yet."))
                .font(.callout).foregroundStyle(.secondary)
            if !loaded, !catalogsLoading {
                Button("Load \(kind.rawValue)") { loadCatalogs([kind]) }
                    .disabled(!store.hasKey || store.busy)
            }
        }
    }

    private func catalogEmptyMessage(_ kind: Destination) -> String {
        switch kind {
        case .materials: return "No materials on this account."
        case .components: return "No components on this account."
        case .stationery: return "No stationery on this account."
        default: return "Nothing to choose yet."
        }
    }

    // MARK: Actions

    private func seedIfNeeded() {
        guard !didSeed else { return }
        didSeed = true
        if let prefill = store.pendingSavedProductDraft {
            store.pendingSavedProductDraft = nil
            openedForPrefill = true
            beginEditing(prefill, isNew: true)
        }
    }

    private func beginEditing(_ product: SavedProduct, isNew: Bool) {
        saveError = nil
        editorIsNew = isNew
        editingBaseline = product
        editing = product
    }

    private func requestCancelEdit() {
        if editorHasChanges { confirmDiscardEdit = true } else { finishEditing() }
    }

    private func finishEditing() {
        editing = nil
        editingBaseline = nil
        if openedForPrefill { dismiss() }
    }

    private func save() {
        guard let editing else { return }
        let product = savedProductForSaving(editing, localModels: store.localModels)
        guard savedProductSaveBlockedReason(product, in: store.savedProducts, localModels: store.localModels) == nil else { return }
        do {
            try store.upsertSavedProduct(product)
            selection = product.id
            finishEditing()
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func startCatalogLoads() {
        loadCatalogs(savedProductCatalogsToLoad(lineTypes: neededLineTypes, loaded: store.loadedCatalogs))
    }

    /// Read-only GETs. They run outside the view's task so closing the sheet mid-load lets them finish into the store
    /// rather than cancelling into an error alert.
    private func loadCatalogs(_ kinds: [Destination]) {
        guard store.hasKey, !kinds.isEmpty, !catalogsLoading else { return }
        catalogsLoading = true
        Task {
            for kind in kinds { await store.loadCatalog(kind) }
            catalogsLoading = false
        }
    }
}

// MARK: - Adding a saved product to the order composer

/// Popover in the order composer's Items section. Adds the resolved lines; refuses while the resolver reports blockers.
struct AddSavedProductPopover: View {
    @EnvironmentObject var store: StudioStore
    let onAdd: ([OrderLine]) -> Void
    @State private var productID: UUID?
    /// Typed text, parsed on every change, so Add never uses a value the field hasn't committed yet.
    @State private var unitsText = "1"

    var products: [SavedProduct] { savedProductsSorted(store.savedProducts) }
    var product: SavedProduct? { store.savedProducts.first { $0.id == productID } }
    var units: Int? { savedProductUnitsSold(unitsText) }
    var resolution: SavedProductResolution? {
        guard let product, let units else { return nil }
        return savedProductOrderLines(product, units: units, localModels: store.localModels, filaments: store.filaments,
                                      components: store.components, stationery: store.stationery)
    }
    var canAdd: Bool { resolution.map { $0.blockers.isEmpty && !$0.lines.isEmpty } ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Add Saved Product").font(.headline)
            if products.isEmpty {
                Text("You have no saved products yet. Create them with Saved Products… in the Orders toolbar, or Save as Product… in a model’s More actions menu.")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Picker("Product", selection: $productID) {
                    ForEach(products) { product in
                        let sku = product.sku.trimmingCharacters(in: .whitespacesAndNewlines)
                        Text(sku.isEmpty ? savedProductDisplayName(product) : "\(savedProductDisplayName(product)) (\(sku))")
                            .tag(UUID?.some(product.id))
                    }
                }
                HStack(spacing: 8) {
                    Text("Units sold")
                    TextField("Units sold", text: $unitsText)
                        .labelsHidden()
                        // Hidden labels aren't read by VoiceOver on macOS, so name the field explicitly.
                        .accessibilityLabel("Units sold")
                        .frame(width: 64)
                    Stepper("Units sold", value: Binding(
                        get: { units ?? 1 },
                        set: { unitsText = String(min(max($0, 1), 10_000)) }
                    ), in: 1...10000).labelsHidden()
                }
                if units == nil {
                    Text("Enter a whole number of units from 1 to 10,000.").font(.caption).foregroundStyle(.orange)
                }
                if let resolution {
                    if resolution.blockers.isEmpty, !resolution.lines.isEmpty {
                        Text("Adds " + savedProductResolvedLinesSummary(resolution.lines, localModels: store.localModels,
                                                                        components: store.components, stationery: store.stationery))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(resolution.notes.enumerated()), id: \.offset) { _, note in
                        Label(note, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(Array(resolution.blockers.enumerated()), id: \.offset) { _, blocker in
                        Label(blocker, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                HStack {
                    Spacer()
                    Button("Add to Draft") {
                        guard let resolution, resolution.blockers.isEmpty, !resolution.lines.isEmpty else { return }
                        onAdd(resolution.lines)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
                    .help("Adds this product’s items to the draft. You review prices before anything is charged.")
                }
            }
        }
        .padding(16)
        .frame(width: 400)
        .onAppear { if product == nil { productID = products.first?.id } }
    }
}
