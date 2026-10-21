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

/// The order lines for a saved product, plus what the user must know before using them.
struct SavedProductResolution {
    var lines: [OrderLine] = []
    /// Informational differences, e.g. the model was re-uploaded since the product was saved.
    var notes: [String] = []
    /// Problems that would make the draft wrong or fail; callers must not create a draft while any remain.
    var blockers: [String] = []
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
    guard units > 0 else {
        result.blockers.append("Choose a quantity of at least 1.")
        return result
    }
    guard !product.lines.isEmpty else {
        result.blockers.append("“\(product.name)” has no items.")
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
        let (quantity, overflow) = saved.perOrder ? (saved.quantity, false) : saved.quantity.multipliedReportingOverflow(by: units)
        guard !overflow, quantity > 0, quantity <= 10_000 else {
            result.blockers.append("“\(product.name)” would need more than 10,000 of one item.")
            return result
        }
        line.quantity = quantity
        var reference = saved.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = saved.name.isEmpty ? itemTypeLabel(saved.type) : saved.name
        switch saved.type {
        case "PRINT":
            if let modelID = saved.localModelID {
                if let model = localModels.first(where: { $0.id == modelID }) {
                    let current = model.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if current.isEmpty {
                        result.blockers.append("“\(model.name)” isn’t uploaded to Slant. Upload it, then try again.")
                    } else if current != reference {
                        if !reference.isEmpty { result.notes.append("Using the latest upload of “\(model.name)”.") }
                        reference = current
                    }
                } else if reference.isEmpty {
                    result.blockers.append("The model for “\(label)” is no longer in your library.")
                } else {
                    result.notes.append("The model for “\(label)” is no longer in your library; using its last uploaded file.")
                }
            }
            if reference.isEmpty { result.blockers.append("Choose a model for “\(label)”.") }
            if saved.filamentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.blockers.append("Choose a material for “\(label)”.")
            } else if !filaments.isEmpty {
                if let filament = filaments.first(where: { $0.id == saved.filamentID }) {
                    if filamentAvailability(filament) == false { result.blockers.append("\(filament.name) is out of stock.") }
                } else {
                    result.blockers.append("The material for “\(label)” is no longer offered.")
                }
            }
        case "COMPONENT":
            if reference.isEmpty { result.blockers.append("Choose a component for “\(label)”.") }
            else if !components.isEmpty, !components.contains(where: { $0.id == reference }) {
                result.blockers.append("The component “\(label)” is no longer offered.")
            }
        case "STATIONERY":
            if reference.isEmpty { result.blockers.append("Choose stationery for “\(label)”.") }
            else if !stationery.isEmpty, !stationery.contains(where: { $0.id == reference }) {
                result.blockers.append("The stationery “\(label)” is no longer offered.")
            }
        default:
            result.blockers.append("“\(label)” has an unknown item type.")
        }
        line.reference = reference
        result.lines.append(line)
    }
    return result
}

private func itemTypeLabel(_ type: String) -> String {
    switch type {
    case "COMPONENT": return "component"
    case "STATIONERY": return "stationery"
    default: return "3D print"
    }
}

let savedProductsFileName = "products.json"

/// Saved products from disk; an unreadable or missing file gives an empty list.
func loadSavedProducts(from url: URL) -> [SavedProduct] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([SavedProduct].self, from: data)) ?? []
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

    func removeSavedProduct(id: UUID) {
        savedProducts.removeAll { $0.id == id }
        saveSavedProducts()
    }
}
