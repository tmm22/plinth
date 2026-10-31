import SwiftUI

// Catalog while 3DAPI is the print service: 3DAPI's materials (`GET /v2/materials`, read once per visit with the saved
// key's client; read-only, cancelled when the screen goes, failures shown in place). 3DAPI has no packaging catalogue,
// so Catalog shows Materials only (no Components or Stationery segments, whatever kind Slant's Catalog last showed;
// that choice is kept for Slant), with a footnote saying why. Nothing here sends anything but that read, and nothing
// reaches Slant.

/// The footnote under 3DAPI's materials: why there are no Components or Stationery.
let dapiNoPackagingCatalogText = "3DAPI has no catalogue of components or packaging: it ships each order in its own packaging. Choose Slant 3D as the print service in Settings › Account to see Slant’s."

/// One group of 3DAPI materials by filament type.
struct DapiMaterialGroup: Equatable {
    /// "PLA", "PETG", another type in capitals, or "Other" when 3DAPI gave none.
    let title: String
    let materials: [DapiMaterial]
}

/// Whether a material matches a typed search (name, colour or type; any case). An empty search matches everything.
func dapiMaterialMatches(_ material: DapiMaterial, search: String) -> Bool {
    let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else { return true }
    return [material.name, material.color ?? "", material.filamentType ?? ""]
        .contains { $0.localizedCaseInsensitiveContains(query) }
}

/// 3DAPI's materials grouped by filament type: PLA, then PETG, then other types alphabetically, then "Other"; each
/// group sorted by name (then ID, so the order never depends on 3DAPI's). Materials not matching `search` are left out,
/// and so are empty groups.
func dapiMaterialGroups(_ materials: [DapiMaterial], search: String = "") -> [DapiMaterialGroup] {
    var byType: [String: [DapiMaterial]] = [:]
    for material in materials where dapiMaterialMatches(material, search: search) {
        let type = material.filamentType?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        byType[type.isEmpty ? "" : type, default: []].append(material)
    }
    func rank(_ type: String) -> Int {
        switch type {
        case "PLA": 0
        case "PETG": 1
        case "": 3
        default: 2
        }
    }
    let types = byType.keys.sorted { (rank($0), $0) < (rank($1), $1) }
    return types.map { type in
        let sorted = (byType[type] ?? []).sorted {
            let a = $0.name.lowercased(), b = $1.name.lowercased()
            return a == b ? $0.id < $1.id : a < b
        }
        return DapiMaterialGroup(title: type.isEmpty ? "Other" : type, materials: sorted)
    }
}

/// The swatch colour for 3DAPI's `colorHex` ("#RRGGBB" or "RRGGBB", any case) as 0–1 components, or nil when it isn't
/// six hex digits.
func dapiColorComponents(_ hex: String?) -> (red: Double, green: Double, blue: Double)? {
    guard var text = hex?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
    if text.hasPrefix("#") { text.removeFirst() }
    guard text.count == 6, text.allSatisfy(\.isHexDigit), let value = UInt32(text, radix: 16) else { return nil }
    return (Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
}

struct DapiCatalogView: View {
    @EnvironmentObject var store: StudioStore
    @ObservedObject private var connection = DapiConnection.shared
    @State private var materials: [DapiMaterial]?
    @State private var loading = false
    @State private var failure: String?
    @State private var search = ""
    /// Bumped by Try Again: one more read, only on the seller's press.
    @State private var attempt = 0

    private struct LoadKey: Equatable {
        let configured: Bool
        let attempt: Int
    }

    var body: some View {
        materialsContent
            .searchable(text: $search, prompt: "Search materials")
            // Once per visit and after Try Again; cancelled when the screen goes.
            .task(id: LoadKey(configured: connection.isConfigured, attempt: attempt)) { await load() }
    }

    private var packagingFootnote: some View {
        Text(dapiNoPackagingCatalogText)
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var materialsContent: some View {
        if !connection.isConfigured {
            EmptyState(icon: "key", title: "Add your 3DAPI key",
                       detail: "Add your 3DAPI integrator key in Settings › Account to see 3DAPI’s materials.") {
                Button("Add 3DAPI Key…") { store.requestSettings(.account) }
                    .buttonStyle(.borderedProminent)
            }
        } else if let failure {
            EmptyState(icon: "exclamationmark.triangle", title: "3DAPI’s materials didn’t load", detail: failure) {
                Button("Try Again") { attempt += 1 }
                    .disabled(loading)
            }
        } else if let materials {
            let groups = dapiMaterialGroups(materials, search: search)
            if materials.isEmpty {
                EmptyState(icon: Destination.materials.icon, title: "No materials", detail: "3DAPI listed no materials.")
            } else if groups.isEmpty {
                ContentUnavailableView.search(text: search)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 24) {
                        Text("3DAPI suggests a material with each quote; you can choose another when you order. Plinth shows 3DAPI’s list as it is.")
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(groups, id: \.title) { group in
                            VStack(alignment: .leading, spacing: 12) {
                                SectionHeading(title: group.title)
                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 16)], spacing: 16) {
                                    ForEach(group.materials) { material in
                                        materialCard(material)
                                    }
                                }
                            }
                        }
                        packagingFootnote
                    }
                    .padding(StudioMetrics.pagePadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            ProgressView("Loading 3DAPI’s materials…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func materialCard(_ material: DapiMaterial) -> some View {
        HStack(spacing: 12) {
            Group {
                if let rgb = dapiColorComponents(material.colorHex) {
                    Circle().fill(Color(red: rgb.red, green: rgb.green, blue: rgb.blue))
                } else {
                    Circle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(width: 28, height: 28)
            .overlay(Circle().stroke(Color.studioHairline))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(material.name).font(.headline).lineLimit(2)
                let detail = [material.color, material.filamentType?.uppercased()].compactMap { $0 }.filter { !$0.isEmpty }
                if !detail.isEmpty {
                    Text(detail.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.studioCard, in: RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius).stroke(Color.studioHairline))
        .accessibilityElement(children: .combine)
    }

    /// One read of 3DAPI's materials with the saved key's client. A cancellation (the screen went) keeps nothing and
    /// reports nothing; the key can't change while it runs (`DapiConnection.beginRequest`).
    private func load() async {
        guard connection.isConfigured else { return }
        failure = nil
        materials = nil
        let client: any DapiOrdering
        do {
            client = try connection.currentOrderingClient()
        } catch {
            failure = dapiFailureMessage(error)
            return
        }
        loading = true
        connection.beginRequest()
        defer {
            connection.endRequest()
            loading = false
        }
        do {
            let result = try await client.materials()
            guard !Task.isCancelled else { return }
            materials = result
        } catch {
            guard !dapiIsCancellation(error), !Task.isCancelled else { return }
            failure = dapiFailureMessage(error)
        }
    }
}
