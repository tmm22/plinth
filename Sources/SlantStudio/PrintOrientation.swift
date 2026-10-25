import SwiftUI
import simd

/// Rigid, right-handed rotations: the source axis listed becomes the build Z axis.
enum PrintOrientation: Hashable, CaseIterable, Identifiable, Codable, Sendable {
    case zUp, zDown, xUp, xDown, yUp, yDown
    case face(SIMD3<Float>)
    static let allCases: [PrintOrientation] = [.zUp, .zDown, .xUp, .xDown, .yUp, .yDown]
    private static let names = ["zUp", "zDown", "xUp", "xDown", "yUp", "yDown"]
    var id: String {
        if case .face(let n) = self { return "face-\(n.x)-\(n.y)-\(n.z)" }
        return Self.names[Self.allCases.firstIndex(of: self)!]
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self), let index = Self.names.firstIndex(of: name) {
            self = Self.allCases[index]
        } else {
            let n = try container.decode(SIMD3<Float>.self)
            guard n.x.isFinite, n.y.isFinite, n.z.isFinite, abs(simd_length(n) - 1) < 0.0001 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid face normal")
            }
            self = .face(n)
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if case .face(let normal) = self { try container.encode(normal) }
        else { try container.encode(id) }
    }
    var label: String {
        switch self {
        case .face: return "Flat face on bed"
        case .zUp: return "Original · Z up"
        case .zDown: return "Flip · Z down"
        case .xUp: return "Side · X up"
        case .xDown: return "Side · X down"
        case .yUp: return "Side · Y up"
        case .yDown: return "Side · Y down"
        }
    }
    func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .face(let normal): return simd_quatf(from: normal, to: SIMD3<Float>(0, 0, -1)).act(p)
        case .zUp: return p
        case .zDown: return SIMD3(p.x, -p.y, -p.z)
        case .xUp: return SIMD3(-p.z, p.y, p.x)
        case .xDown: return SIMD3(p.z, p.y, -p.x)
        case .yUp: return SIMD3(p.x, -p.z, p.y)
        case .yDown: return SIMD3(p.x, p.z, -p.y)
        }
    }
}

enum PrintPriority: String, CaseIterable, Identifiable {
    case balanced = "Balanced", economy = "Lower support / cost", strength = "Strength"
    var id: String { rawValue }
}

enum PrintLoadAxis: String, CaseIterable, Identifiable, Codable, Sendable {
    case unknown = "Not specified", x = "Original X", y = "Original Y", z = "Original Z"
    var id: String { rawValue }
    var vector: SIMD3<Float>? {
        switch self {
        case .unknown: return nil
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }
}

struct OrientationAssessment: Identifiable, Sendable {
    let orientation: PrintOrientation
    let size: SIMD3<Float>
    let contactArea: Float
    let overhangArea: Float
    let surfaceArea: Float
    var contactWidth: Float? = nil
    var id: String { orientation.id }
    var fits: Bool { size.max() <= slantBuildVolumeMM }
    var contactRatio: Float { contactArea / max(size.x * size.y, 0.000001) }
    var hasFlatContact: Bool { contactArea.isFinite && contactArea > 0.000001 }
    var slendernessPenalty: Float {
        let width = min(contactWidth ?? sqrt(max(contactArea, 0)), sqrt(max(contactArea, 0)))
        let ratio = size.z / max(width, 0.000001)
        return ratio / (1 + ratio)
    }
    func score(priority: PrintPriority, load: PrintLoadAxis) -> Float {
        // Relative heuristics only: neither a slicer estimate nor a mechanical simulation.
        let support = overhangArea / max(surfaceArea, 0.000001)
        let height = size.z / max(size.max(), 0.000001)
        let contactPenalty = 1 - min(contactRatio, 1)
        let crossLayer = load.vector.map { abs(orientation.rotate($0).z) } ?? 0
        let strengthWeight: Float = priority == .strength ? 4 : (priority == .balanced ? 1 : 0.25)
        return support * (priority == .economy ? 5 : 3) + height * 0.25 + contactPenalty * 0.5
            + slendernessPenalty * 0.75 + crossLayer * strengthWeight + (fits ? 0 : 100) + (contactArea > 0 ? 0 : 10)
    }
}

extension STLMesh {
    func oriented(_ orientation: PrintOrientation) -> STLMesh {
        let rotation = simd_float3x3(columns: (orientation.rotate(SIMD3(1, 0, 0)),
                                                orientation.rotate(SIMD3(0, 1, 0)),
                                                orientation.rotate(SIMD3(0, 0, 1))))
        var points: [Float] = []
        points.reserveCapacity(vertices.count)
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in stride(from: 0, to: vertices.count, by: 3) {
            let p = rotation * SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
            low = simd_min(low, p); high = simd_max(high, p)
            points.append(contentsOf: [p.x, p.y, p.z])
        }
        for i in stride(from: 0, to: points.count, by: 3) {
            points[i] -= low.x; points[i + 1] -= low.y; points[i + 2] -= low.z
        }
        return STLMesh(vertices: points, minimum: .zero, maximum: high - low)
    }

    /// Group triangle normals, then evaluate a bounded set of the largest surface directions.
    /// Full-mesh contact checks below reject internal faces and edge-only placements.
    func placementCandidates() -> [PrintOrientation] {
        var groups: [SIMD3<Int32>: (normal: SIMD3<Float>, area: Float)] = [:]
        for i in stride(from: 0, to: vertices.count, by: 9) {
            let a = SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
            let b = SIMD3(vertices[i + 3], vertices[i + 4], vertices[i + 5])
            let c = SIMD3(vertices[i + 6], vertices[i + 7], vertices[i + 8])
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length.isFinite, length > 0 else { continue }
            let normal = cross / length
            let key = SIMD3<Int32>(Int32((normal.x * 10000).rounded()), Int32((normal.y * 10000).rounded()), Int32((normal.z * 10000).rounded()))
            if var group = groups[key] { group.area += length / 2; groups[key] = group }
            else { groups[key] = (normal, length / 2) }
        }
        let sorted = groups.values.sorted {
            if $0.area != $1.area { return $0.area > $1.area }
            if $0.normal.x != $1.normal.x { return $0.normal.x < $1.normal.x }
            if $0.normal.y != $1.normal.y { return $0.normal.y < $1.normal.y }
            return $0.normal.z < $1.normal.z
        }
        var candidates = PrintOrientation.allCases
        for group in sorted {
            // Keep distinct directions; axis-aligned faces are already covered.
            if candidates.contains(where: { simd_distance($0.rotate(group.normal), SIMD3<Float>(0, 0, -1)) < 0.000001 }) { continue }
            candidates.append(.face(group.normal))
            if candidates.count == 30 { break }
        }
        return candidates
    }

    func orientationAssessments() -> [OrientationAssessment] {
        placementCandidates().map { orientation in
            let mesh = oriented(orientation)
            var surface: Float = 0, contact: Float = 0, overhang: Float = 0
            // Numerical coplanarity tolerance, not an adhesion or manufacturing tolerance.
            let tolerance: Float = 0.0001
            var contactLow = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
            var contactHigh = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
            for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
                func point(_ j: Int) -> SIMD3<Float> {
                    SIMD3(mesh.vertices[i + j], mesh.vertices[i + j + 1], mesh.vertices[i + j + 2])
                }
                let a = point(0), b = point(3), c = point(6)
                let cross = simd_cross(b - a, c - a)
                let length = simd_length(cross)
                guard length > 0 else { continue }
                let area = length / 2
                surface += area
                if max(a.z, max(b.z, c.z)) <= tolerance && abs(cross.z / length) >= 0.999999 {
                    contact += abs(cross.z) / 2
                    for p in [a, b, c] {
                        contactLow = simd_min(contactLow, SIMD2(p.x, p.y))
                        contactHigh = simd_max(contactHigh, SIMD2(p.x, p.y))
                    }
                } else if cross.z / length < -0.7071068 {
                    overhang += area
                }
            }
            return OrientationAssessment(orientation: orientation, size: mesh.maximum, contactArea: contact,
                                         overhangArea: overhang, surfaceArea: surface,
                                         contactWidth: contact > 0 ? (contactHigh - contactLow).min() : 0)
        }
    }

    func binarySTL() -> Data {
        var data = Data(repeating: 0, count: 80)
        func word(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(UInt32(triangleCount))
        for i in stride(from: 0, to: vertices.count, by: 9) {
            let a = SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
            let b = SIMD3(vertices[i + 3], vertices[i + 4], vertices[i + 5])
            let c = SIMD3(vertices[i + 6], vertices[i + 7], vertices[i + 8])
            let cross = simd_cross(b - a, c - a)
            let normal = simd_length_squared(cross) > 0 ? simd_normalize(cross) : .zero
            for v in [normal.x, normal.y, normal.z] { word(v.bitPattern) }
            for j in 0..<9 { word(vertices[i + j].bitPattern) }
            data.append(contentsOf: [0, 0])
        }
        return data
    }
}

enum PartPurpose: String, CaseIterable, Identifiable, Codable, Sendable {
    case bracket = "Bracket", enclosure = "Enclosure", clip = "Clip", decorative = "Decorative", custom = "Custom"
    var id: String { rawValue }
    var priority: PrintPriority {
        switch self {
        case .bracket, .clip, .custom: return .strength
        case .enclosure: return .balanced
        case .decorative: return .economy
        }
    }
    var needsDirection: Bool { self == .bracket || self == .clip || self == .custom }
}

struct PartIntent: Codable, Equatable, Sendable {
    var purpose: PartPurpose = .enclosure
    var details = ""
    var load: PrintLoadAxis = .unknown
    var materialGoal: MaterialGoal? = nil
    var effectiveLoad: PrintLoadAxis { purpose == .decorative ? .unknown : load }
    var isReady: Bool {
        (!purpose.needsDirection || load != .unknown) &&
        (purpose != .custom || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var explanation: String {
        if effectiveLoad != .unknown {
            return "Balances layer alignment with your stress direction, bed contact, support needs and print height."
        }
        return purpose == .decorative
            ? "Favours reduced support needs, stable bed contact and a lower print height."
            : "Balances stable bed contact, support needs and print height for your enclosure."
    }
}

struct PreparedPrintRecipe: Codable, Equatable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let intent: PartIntent
    let orientation: PrintOrientation
    let materialID: String?
    let created: Date
}

func preferredOrientation(_ assessments: [OrientationAssessment], intent: PartIntent) -> OrientationAssessment? {
    guard intent.isReady else { return nil }
    // Reject unusable placements rather than allowing a penalty to be outweighed.
    return assessments.filter { $0.fits && $0.hasFlatContact && $0.surfaceArea.isFinite && $0.surfaceArea > 0 }.min {
        let lhs = $0.score(priority: intent.purpose.priority, load: intent.effectiveLoad)
        let rhs = $1.score(priority: intent.purpose.priority, load: intent.effectiveLoad)
        if lhs == rhs {
            return (PrintOrientation.allCases.firstIndex(of: $0.orientation) ?? 6) < (PrintOrientation.allCases.firstIndex(of: $1.orientation) ?? 6)
        }
        return lhs < rhs
    }
}

struct PrintOrientationCard: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    @State private var mesh: STLMesh?
    @State private var assessments: [OrientationAssessment] = []
    @State private var failure: String?
    @State private var intent = PartIntent()
    @State private var preparing = false
    @State private var loaded = false
    @State private var expanded = false

    private var best: OrientationAssessment? { preferredOrientation(assessments, intent: intent) }

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 16) {
                    if let recipe = model.printRecipe {
                        preparedSummary(recipe)
                    } else if !model.supportsPreview {
                        Text(stlOnlyToolNote(model) ?? stlCopyToolNote)
                    } else if let failure {
                        Text(failure)
                    } else if let mesh {
                        purposeForm
                        if model.requiresZUp {
                            Text("Keeps Z up: this copy has features that depend on the print layers, such as cells, gaps, teardrop holes, bridging or matched walls. Prepare a different orientation from the source before adding them.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let best {
                            DisclosureGroup("Preview print placement") {
                                VStack(alignment: .leading, spacing: 8) {
                                    STLSceneView(mesh: mesh.oriented(best.orientation), showsPrintBed: true)
                                        .id(best.orientation).frame(height: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text("Flat face on bed · Base at Z = 0").font(.callout).foregroundStyle(.secondary)
                                }.padding(.top, 8)
                            }.studioDisclosureStyle()
                            Text(intent.explanation).font(.callout).foregroundStyle(.secondary)
                            Button(preparing ? "Preparing…" : "Optimise & Save Copy") { prepareCopy(mesh, orientation: best.orientation) }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.busy || preparing)
                        } else if intent.isReady {
                            Text("No flat-bed placement fits among the positions checked. Prepare a custom orientation in your CAD tool or slicer, then import it here.")
                        }
                        materialAdvice
                        DisclosureGroup("How optimisation works") {
                            Text("Compares standard placements and up to 24 additional face directions without changing shape, dimensions, holes or clearances. Uses your chosen material. Slant prints a part in the placement it is uploaded in, re-orienting only an obviously wrong upload, so this choice decides which way the layers run. Slant’s settings are fixed (0.2 mm layers, 1 mm walls, 25% infill, overhangs up to 50°); its tolerances aren’t published, and this is not a mechanical simulation.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                        }.studioDisclosureStyle()
                    } else {
                        ProgressView("Preparing placement options…")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            } label: {
                SectionHeading(title: "Optimise for purpose", caption: model.printRecipe.map { "Prepared for \($0.intent.purpose.rawValue.lowercased()) · View recipe" } ?? "Choose how this part sits on the print bed for its use")
            }.studioDisclosureStyle()
        }
        .task(id: model.id) {
            loaded = false
            intent = model.partIntent ?? PartIntent()
            mesh = nil; assessments = []; failure = nil
            guard model.supportsPreview, model.printRecipe == nil else { return }
            let url = model.url
            let keepCellRoofsUp = model.requiresZUp
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let mesh = try STLMesh.read(from: url)
                    let assessments = mesh.orientationAssessments().filter { !keepCellRoofsUp || $0.orientation == .zUp }
                    return (mesh, assessments)
                }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): mesh = value.0; assessments = value.1
            case .failure(let error): failure = error.localizedDescription
            }
            loaded = true
        }
        .onChange(of: intent) { _, value in
            guard loaded else { return }
            store.savePartIntent(value, modelID: model.id)
        }
    }

    private var purposeForm: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Part purpose", selection: $intent.purpose) {
                ForEach(PartPurpose.allCases) { Text($0.rawValue).tag($0) }
            }
            if intent.purpose == .custom {
                TextField("What will this part do?", text: $intent.details)
                    .textFieldStyle(.roundedBorder)
                Text("Your description is saved with the part. Choose the stress direction below to guide placement.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if intent.purpose != .decorative {
                Picker("Main stress direction", selection: $intent.load) {
                    ForEach(PrintLoadAxis.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(intent.purpose == .clip
                     ? "Choose the original STL axis along the flexing arm."
                     : "Choose the original STL axis of the main tensile stress. For bending, use the length of the loaded arm.")
                    .font(.callout).foregroundStyle(.secondary)
                if intent.purpose.needsDirection && intent.load == .unknown {
                    Text("Choose a direction to prepare this part for its purpose.").font(.caption)
                }
            }
        }
        .disabled(preparing)
    }

    /// Optional guidance under the placement. The material itself is chosen in Print configuration; a suggestion
    /// changes it only when picked here.
    private var materialAdvice: some View {
        DisclosureGroup("Material suggestions for this use") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Main requirement", selection: Binding(get: { intent.materialGoal ?? .keepCurrent }, set: { intent.materialGoal = $0 })) {
                    ForEach(MaterialGoal.allCases) { Text($0.rawValue).tag($0) }
                }
                .fixedSize()
                if let goal = intent.materialGoal, goal != .keepCurrent {
                    Text(goal.guidance).font(.callout).foregroundStyle(.secondary)
                    let options = recommendedMaterials(for: goal, in: store.filaments)
                    if options.isEmpty && goal.profile != nil {
                        Text("No matching material is currently listed as available. Keep the material chosen in Print configuration.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        let selected = options.first(where: { $0.id == store.filamentID })
                        let others = options.filter { $0.id != store.filamentID }
                        if let selected {
                            Label("Print configuration already uses \(selected.name).", systemImage: "checkmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        // Kept alongside the "already uses" line so another suggestion can still be chosen.
                        if !others.isEmpty {
                            Menu(selected == nil ? "Use a Suggested Material" : "Use Another Suggested Material") {
                                ForEach(others) { material in
                                    Button(material.name) { store.filamentID = material.id }
                                }
                            }
                            .fixedSize()
                            .disabled(store.busy || preparing)
                            .help("Sets the material in Print configuration")
                        }
                    }
                }
            }.padding(.top, 8)
        }.studioDisclosureStyle()
        .font(.callout)
    }

    private func preparedSummary(_ recipe: PreparedPrintRecipe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Prepared copy saved", systemImage: "checkmark.circle.fill").font(.headline)
            Text("Shape and dimensions preserved. Upload this copy and estimate it with your chosen material.")
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("Recipe details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recipe.intent.explanation)
                    if !recipe.intent.details.isEmpty { Text(recipe.intent.details) }
                    Text("Original: \(recipe.sourceName)")
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }.studioDisclosureStyle()
            if let material = recipe.materialID, material != store.filamentID {
                Text("The material selection has changed since preparation. Placement is preserved; strength depends on the material used.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let original = store.localModels.first(where: { $0.id == recipe.sourceID }) {
                Button("Prepare Another Version") { store.select(original) }
                    .disabled(store.busy)
            }
        }
    }

    private func prepareCopy(_ mesh: STLMesh, orientation: PrintOrientation) {
        preparing = true
        let name = model.name
        let recipe = PreparedPrintRecipe(sourceID: model.id, sourceName: name, intent: intent,
                                         orientation: orientation, materialID: store.filamentID.isEmpty ? nil : store.filamentID,
                                         created: Date())
        store.savePartIntent(intent, modelID: model.id)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> URL in
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let safeName = URL(fileURLWithPath: name).lastPathComponent
                    let url = folder.appendingPathComponent("\(safeName)-\(recipe.intent.purpose.rawValue.lowercased())-prepared.stl")
                    do { try mesh.oriented(orientation).binarySTL().write(to: url, options: .atomic) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return url
                }
            }.value
            switch result {
            case .success(let url):
                store.importModel(url, recipe: recipe, improvement: model.designImprovement, reinforcement: model.reinforcement,
                                  sourceDetails: model.sourceDetails)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            case .failure(let error): store.showError(error.localizedDescription)
            }
            preparing = false
        }
    }
}
