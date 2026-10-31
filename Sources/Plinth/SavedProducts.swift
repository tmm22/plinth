import Foundation

/// One item of a saved product. Stores references only — never prices, addresses or customer details.
struct SavedProductLine: Codable, Equatable, Identifiable {
    var id = UUID()
    /// PRINT, COMPONENT or STATIONERY, as in `OrderLine.type`.
    var type = "PRINT"
    /// Slant file, component or stationery ID as last known. For PRINT lines this is a snapshot: the linked local
    /// model's current `remoteID` wins when it differs, and the difference is reported.
    var reference = ""
    /// PRINT only: the library model this line was saved from, so renames and re-uploads follow it.
    var localModelID: UUID?
    var filamentID = ""
    /// Per unit sold, unless `perOrder` is set.
    var quantity = 1
    /// Added once per order regardless of units sold (packing slips, inserts). Stationery defaults to this.
    var perOrder = false
    var imageURL = ""
    var name = ""
    var optionsJSON = "{}"
    /// PRINT only: made per buyer from an OpenSCAD template in Import Orders (BatchPersonalise.swift). References only.
    var template: SavedProductTemplateLink?
}

/// A product a seller sells repeatedly: its items, material and SKU, added to a draft in one step.
struct SavedProduct: Codable, Equatable, Identifiable {
    var id = UUID()
    var name = ""
    /// Marketplace SKU used to match imported orders. Optional, but unique (ignoring case) when present.
    var sku = ""
    var lines: [SavedProductLine] = []
    var created = Date()
}

// Decoding tolerates missing keys (older or hand-edited files) instead of dropping the whole list.
extension SavedProductLine {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try container.decodeIfPresent(String.self, forKey: .type) ?? "PRINT"
        reference = try container.decodeIfPresent(String.self, forKey: .reference) ?? ""
        localModelID = try container.decodeIfPresent(UUID.self, forKey: .localModelID)
        filamentID = try container.decodeIfPresent(String.self, forKey: .filamentID) ?? ""
        quantity = try container.decodeIfPresent(Int.self, forKey: .quantity) ?? 1
        perOrder = try container.decodeIfPresent(Bool.self, forKey: .perOrder) ?? false
        imageURL = try container.decodeIfPresent(String.self, forKey: .imageURL) ?? ""
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        optionsJSON = try container.decodeIfPresent(String.self, forKey: .optionsJSON) ?? "{}"
        // A damaged link drops only the link, never the item or the product.
        template = (try? container.decodeIfPresent(SavedProductTemplateLink.self, forKey: .template)) ?? nil
    }
}

extension SavedProduct {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        sku = try container.decodeIfPresent(String.self, forKey: .sku) ?? ""
        lines = try container.decodeIfPresent([SavedProductLine].self, forKey: .lines) ?? []
        created = try container.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}

/// The order lines for a saved product, plus what the user must know before using them.
struct SavedProductResolution {
    var lines: [OrderLine] = []
    /// Parallel to `lines`: whether each line is added once per order (packing slips, inserts) rather than per unit.
    var perOrder: [Bool] = []
    /// Informational differences, e.g. the model was re-uploaded since the product was saved.
    var notes: [String] = []
    /// Problems that would make the draft wrong or fail; callers must not create a draft while any remain.
    var blockers: [String] = []
    /// Parallel to `blockers`: the same reasons worded for the Saved Products list, whose row already names the
    /// product, so they leave out its name and instructions meant for the composer or Import Orders.
    var listBlockers: [String] = []
}

func normalizedSKU(_ sku: String) -> String {
    sku.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// The saved product with this SKU, matched ignoring case and surrounding spaces. Nil for an empty SKU.
func savedProduct(forSKU sku: String, in products: [SavedProduct]) -> SavedProduct? {
    let key = normalizedSKU(sku)
    guard !key.isEmpty else { return nil }
    return products.first { normalizedSKU($0.sku) == key }
}

/// Why this SKU can't be used for `product`, or nil. Empty SKUs are always allowed.
func savedProductSKUConflict(_ sku: String, for productID: UUID, in products: [SavedProduct]) -> String? {
    let key = normalizedSKU(sku)
    guard !key.isEmpty else { return nil }
    guard let other = products.first(where: { $0.id != productID && normalizedSKU($0.sku) == key }) else { return nil }
    return "“\(other.name)” already uses SKU \(other.sku.trimmingCharacters(in: .whitespacesAndNewlines))."
}

/// Expands a saved product into order lines for `units` sold. Per-unit quantities are multiplied by `units`;
/// per-order lines are added once. Catalog checks only run against non-empty lists, so an unloaded catalog never
/// produces a false blocker.
func savedProductOrderLines(
    _ product: SavedProduct, units: Int, localModels: [LocalModel],
    filaments: [Record], components: [Record], stationery: [Record]
) -> SavedProductResolution {
    var result = SavedProductResolution()
    func block(_ text: String, list: String? = nil) {
        result.blockers.append(text)
        result.listBlockers.append(list ?? text)
    }
    guard units > 0 else {
        block("Choose a quantity of at least 1.")
        return result
    }
    guard !product.lines.isEmpty else {
        block("“\(product.name)” has no items.", list: "No items.")
        return result
    }
    for saved in product.lines {
        var line = OrderLine()
        line.type = saved.type
        line.filamentID = saved.filamentID
        line.imageURL = saved.imageURL
        line.name = saved.name
        line.sku = product.sku.trimmingCharacters(in: .whitespacesAndNewlines)
        line.optionsJSON = saved.optionsJSON
        let trimmedName = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmedName.isEmpty ? itemTypeLabel(saved.type) : trimmedName
        guard saved.quantity > 0 else {
            block("An item of “\(product.name)” has no quantity. Edit the product to set one.", list: "An item has no quantity.")
            return result
        }
        let (quantity, overflow) = saved.perOrder ? (saved.quantity, false) : saved.quantity.multipliedReportingOverflow(by: units)
        guard !overflow, quantity > 0, quantity <= 10_000 else {
            block("“\(product.name)” would need more than 10,000 of one item.", list: "Would need more than 10,000 of one item.")
            return result
        }
        line.quantity = quantity
        var reference = saved.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        switch saved.type {
        case "PRINT":
            var modelBlocked = false
            if let modelID = saved.localModelID {
                if let model = localModels.first(where: { $0.id == modelID }) {
                    let current = model.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if current.isEmpty {
                        block("“\(model.name)” isn’t uploaded to Slant. Upload it from Models, then try again.",
                              list: "“\(model.name)” isn’t uploaded to Slant.")
                        modelBlocked = true
                    } else if current != reference {
                        if !reference.isEmpty { result.notes.append("Using the latest upload of “\(model.name)”.") }
                        reference = current
                    }
                } else if reference.isEmpty {
                    block("The model for “\(label)” is no longer in your library.")
                    modelBlocked = true
                } else {
                    result.notes.append("The model for “\(label)” is no longer in your library; using its last uploaded file.")
                }
            }
            if reference.isEmpty, !modelBlocked { block("Choose a model for “\(label)”.") }
            let filamentID = saved.filamentID.trimmingCharacters(in: .whitespacesAndNewlines)
            line.filamentID = filamentID
            if filamentID.isEmpty {
                block("Choose a material for “\(label)”.")
            } else if !filaments.isEmpty {
                if let filament = filaments.first(where: { $0.id == filamentID }) {
                    if filamentAvailability(filament) == false { block("\(filament.name) is out of stock.") }
                } else {
                    block("The material for “\(label)” is no longer offered.")
                }
            }
        case "COMPONENT":
            if reference.isEmpty { block("Choose a component for “\(label)”.") }
            else if !components.isEmpty, !components.contains(where: { $0.id == reference }) {
                block("The component “\(label)” is no longer offered.")
            }
        case "STATIONERY":
            if reference.isEmpty { block("Choose stationery for “\(label)”.") }
            else if !stationery.isEmpty, !stationery.contains(where: { $0.id == reference }) {
                block("The stationery “\(label)” is no longer offered.")
            }
            if !isHTTPSImageURL(saved.imageURL) {
                block("The image link for “\(label)” must be an https:// address.")
            }
        default:
            block("“\(label)” has an unknown item type.")
        }
        line.reference = reference
        result.lines.append(line)
        result.perOrder.append(saved.perOrder)
    }
    return result
}

/// Whether a saved product could be added to a draft now, from what Plinth has loaded. Read-only: it uses the same
/// resolver as the composer and Import Orders, for one unit, so it blocks exactly when they would; its reasons are the
/// resolver's list wording (`listBlockers`).
struct SavedProductOrderability: Equatable {
    /// The resolver's blockers for one unit sold, in its order, worded for the Saved Products list.
    var blockers: [String] = []
    /// Catalogs this product's items need that Plinth holds no entries for, in a fixed order (materials, components,
    /// stationery). The resolver never blocks on an empty catalog, so their stock and availability weren't checked.
    var uncheckedCatalogs: [Destination] = []
    var canOrder: Bool { blockers.isEmpty }
}

func savedProductOrderability(
    _ product: SavedProduct, localModels: [LocalModel], filaments: [Record], components: [Record], stationery: [Record]
) -> SavedProductOrderability {
    let resolution = savedProductOrderLines(product, units: 1, localModels: localModels, filaments: filaments,
                                            components: components, stationery: stationery)
    func needs(_ type: String, _ value: (SavedProductLine) -> String) -> Bool {
        product.lines.contains { $0.type == type && !value($0).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
    var unchecked: [Destination] = []
    if filaments.isEmpty, needs("PRINT", \.filamentID) { unchecked.append(.materials) }
    if components.isEmpty, needs("COMPONENT", \.reference) { unchecked.append(.components) }
    if stationery.isEmpty, needs("STATIONERY", \.reference) { unchecked.append(.stationery) }
    return SavedProductOrderability(blockers: resolution.listBlockers, uncheckedCatalogs: unchecked)
}

/// The row's reason, e.g. "Can’t be ordered: PLA Black is out of stock." with "(+1 more)" when there are others.
func savedProductCantOrderText(_ orderability: SavedProductOrderability) -> String? {
    guard let first = orderability.blockers.first else { return nil }
    let more = orderability.blockers.count - 1
    return "Can’t be ordered: \(first)" + (more > 0 ? " (+\(more) more)" : "")
}

/// "2 products can’t be ordered right now.", or nil when every product can.
func savedProductsCantOrderCountText(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1 ? "1 product can’t be ordered right now." : "\(count) products can’t be ordered right now."
}

/// Says which catalogs weren't checked and why, so an unloaded catalog never reads as "all is well". Nil when every
/// catalog the products need was checked.
func savedProductsUncheckedCatalogsText(_ kinds: [Destination], loaded: Set<Destination>) -> String? {
    func noun(_ kind: Destination) -> String {
        switch kind {
        case .materials: return "materials"
        case .components: return "components"
        default: return "stationery"
        }
    }
    func list(_ kinds: [Destination]) -> String {
        let names = kinds.map(noun)
        guard names.count > 1 else { return names.first ?? "" }
        return names.dropLast().joined(separator: ", ") + " and " + names.last!
    }
    let ordered = Destination.catalogKinds.filter { kinds.contains($0) }
    let notLoaded = ordered.filter { !loaded.contains($0) }
    let empty = ordered.filter { loaded.contains($0) }
    var sentences: [String] = []
    if !notLoaded.isEmpty {
        let reason = notLoaded.count == 1 ? "that catalog isn’t loaded" : "those catalogs aren’t loaded"
        sentences.append("Stock and availability weren’t checked for \(list(notLoaded)), because \(reason).")
    }
    if !empty.isEmpty {
        sentences.append("Stock and availability weren’t checked for \(list(empty)), because Slant listed none.")
    }
    return sentences.isEmpty ? nil : sentences.joined(separator: " ")
}

/// A product's name in a picker: "Name (SKU)", marked when it can't be ordered right now.
func savedProductPickerTitle(_ product: SavedProduct, canOrder: Bool) -> String {
    let sku = product.sku.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = sku.isEmpty ? savedProductDisplayName(product) : "\(savedProductDisplayName(product)) (\(sku))"
    return canOrder ? name : "\(name) — can’t be ordered"
}

private func itemTypeLabel(_ type: String) -> String {
    switch type {
    case "COMPONENT": return "component"
    case "STATIONERY": return "stationery"
    default: return "3D print"
    }
}

let savedProductsFileName = "products.json"

/// Decodes one product, or nil, so a single damaged entry doesn't discard the rest.
private struct LossySavedProduct: Decodable {
    let value: SavedProduct?
    init(from decoder: Decoder) throws { value = try? SavedProduct(from: decoder) }
}

/// Where an unreadable products file is copied before the next save can replace it.
func savedProductsBackupURL(for url: URL) -> URL {
    url.deletingPathExtension().appendingPathExtension("unreadable.json")
}

/// Saved products from disk; a missing file gives an empty list. Entries that can't be read are skipped, and a file
/// that can't be fully read is first copied beside it (`products.unreadable.json`), so the next save can't lose it.
func loadSavedProducts(from url: URL) -> [SavedProduct] {
    guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
    let rows = try? JSONDecoder().decode([LossySavedProduct].self, from: data)
    if rows == nil || rows?.contains(where: { $0.value == nil }) == true {
        try? data.write(to: savedProductsBackupURL(for: url), options: .atomic)
    }
    return rows?.compactMap(\.value) ?? []
}

extension StudioStore {
    func saveSavedProducts() {
        do {
            try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
            try JSONEncoder().encode(savedProducts).write(to: Self.supportDirectory.appendingPathComponent(savedProductsFileName), options: .atomic)
        } catch { showError("Could not save products: \(error.localizedDescription)") }
    }

    /// Adds or replaces a saved product. Refuses a SKU another product already uses.
    func upsertSavedProduct(_ product: SavedProduct) throws {
        if let conflict = savedProductSKUConflict(product.sku, for: product.id, in: savedProducts) { throw StudioError(conflict) }
        if let index = savedProducts.firstIndex(where: { $0.id == product.id }) { savedProducts[index] = product }
        else { savedProducts.append(product) }
        saveSavedProducts()
    }

    /// Opens the Saved Products sheet, optionally straight into a new product prefilled from a model. Never opens
    /// over another sheet the store drives.
    func openSavedProducts(prefill: SavedProduct? = nil) {
        guard !isPresentingSheet else { return }
        pendingSavedProductDraft = prefill
        showSavedProducts = true
    }

    func removeSavedProduct(id: UUID) {
        savedProducts.removeAll { $0.id == id }
        saveSavedProducts()
    }
}
