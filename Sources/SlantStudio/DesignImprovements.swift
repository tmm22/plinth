import SwiftUI
import simd

enum EdgeImprovement: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottomChamfer = "Bottom chamfer", verticalFillet = "Round vertical corners"
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .bottomChamfer: return "A 45° bevel can provide bottom-edge clearance. It reduces bed-contact area, so use it only when that clearance is useful."
        case .verticalFillet: return "Rounded external corners can make a handled part more comfortable. This removes corner material; it is not a structural reinforcement."
        }
    }
}

struct DesignImprovementRecord: Codable, Equatable, Sendable {
    let sourceID: UUID
    let kind: EdgeImprovement
    let sizeMM: Float
    let created: Date
}

struct MeshEdge: Hashable {
    let a: SIMD3<Float>
    let b: SIMD3<Float>
    init(_ p: SIMD3<Float>, _ q: SIMD3<Float>) {
        let precedes = p.x != q.x ? p.x < q.x : (p.y != q.y ? p.y < q.y : p.z < q.z)
        a = precedes ? p : q; b = precedes ? q : p
    }
}

struct EdgeDesignCheck: Sendable {
    let plainBox: Bool
    let hasSharpJoins: Bool
    let hasTransitions: Bool
    let complete: Bool
}

extension STLMesh {
    func edgeDesignCheck() -> EdgeDesignCheck {
        guard triangleCount <= 100_000 else {
            return EdgeDesignCheck(plainBox: false, hasSharpJoins: false, hasTransitions: false, complete: false)
        }
        var edges: [MeshEdge: [SIMD3<Float>]] = [:]
        var edgeBalance: [MeshEdge: Int] = [:]
        var corners = Set<SIMD3<Float>>()
        var boxFaces = [Float](repeating: 0, count: 6)
        var onlyBoxFaces = true
        var signedVolume: Double = 0
        for i in stride(from: 0, to: vertices.count, by: 9) {
            let a = SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
            let b = SIMD3(vertices[i + 3], vertices[i + 4], vertices[i + 5])
            let c = SIMD3(vertices[i + 6], vertices[i + 7], vertices[i + 8])
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length.isFinite, length > 0 else {
                return EdgeDesignCheck(plainBox: false, hasSharpJoins: false, hasTransitions: false, complete: false)
            }
            let normal = cross / length
            for (p, q) in [(a, b), (b, c), (c, a)] {
                let edge = MeshEdge(p, q)
                edges[edge, default: []].append(normal)
                edgeBalance[edge, default: 0] += edge.a == p ? 1 : -1
            }
            for p in [a, b, c] { corners.insert(p) }
            let da = SIMD3<Double>(a - minimum), db = SIMD3<Double>(b - minimum), dc = SIMD3<Double>(c - minimum)
            signedVolume += simd_dot(da, simd_cross(db, dc)) / 6
            var face: Int?
            for axis in 0..<3 {
                for side in 0..<2 {
                    let boundary = side == 0 ? minimum[axis] : maximum[axis]
                    if a[axis] == boundary && b[axis] == boundary && c[axis] == boundary {
                        face = axis * 2 + side
                    }
                }
            }
            if let face { boxFaces[face] += length / 2 } else { onlyBoxFaces = false }
        }
        var sharp = false, transition = false
        for normals in edges.values where normals.count == 2 {
            let dot = simd_dot(normals[0], normals[1])
            if abs(dot) < 0.1 { sharp = true }
            if dot > 0.1 && dot < 0.9999 { transition = true }
        }
        let size = maximum - minimum
        let expected = [size.y * size.z, size.y * size.z, size.x * size.z, size.x * size.z, size.x * size.y, size.x * size.y]
        let areasMatch = zip(boxFaces, expected).allSatisfy { abs($0 - $1) <= max($1 * 0.00001, 0.000001) }
        let volume = Double(size.x) * Double(size.y) * Double(size.z)
        let volumeMatches = abs(signedVolume - volume) <= volume * 0.00001
        // Deliberately exact recognition: never replace a detailed or hollow model with its bounding box.
        let isBox = triangleCount == 12 && corners.count == 8 && onlyBoxFaces && areasMatch && volume > 0 && volumeMatches
            && edges.values.allSatisfy { $0.count == 2 } && edgeBalance.values.allSatisfy { $0 == 0 }
        return EdgeDesignCheck(plainBox: isBox, hasSharpJoins: sharp, hasTransitions: transition, complete: true)
    }

    func applyingEdgeImprovement(_ kind: EdgeImprovement, size radius: Float) throws -> STLMesh {
        let size = maximum - minimum
        guard edgeDesignCheck().plainBox, radius.isFinite, radius > 0, radius <= size.min() / 4 else {
            throw StudioError("This shape cannot be modified with the bounded box-edge operation. Use the original CAD model for this edit.")
        }
        func rectangle(_ inset: Float, _ z: Float) -> [SIMD3<Float>] {
            [SIMD3(inset, inset, z), SIMD3(size.x - inset, inset, z),
             SIMD3(size.x - inset, size.y - inset, z), SIMD3(inset, size.y - inset, z)]
        }
        let rings: [[SIMD3<Float>]]
        switch kind {
        case .bottomChamfer:
            rings = [rectangle(radius, 0), rectangle(0, radius), rectangle(0, size.z)]
        case .verticalFillet:
            var outline: [SIMD3<Float>] = []
            let centers = [SIMD2(size.x - radius, radius), SIMD2(size.x - radius, size.y - radius),
                           SIMD2(radius, size.y - radius), SIMD2(radius, radius)]
            // 16 segments per quarter; endpoints are snapped to exact tangencies.
            for corner in 0..<4 {
                for step in 0...16 {
                    let angle = Float(corner - 1) * .pi / 2 + Float(step) * .pi / 32
                    var x = centers[corner].x + radius * cos(angle)
                    var y = centers[corner].y + radius * sin(angle)
                    if abs(x) < 0.00001 { x = 0 }
                    if abs(y) < 0.00001 { y = 0 }
                    if abs(x - size.x) < 0.00001 { x = size.x }
                    if abs(y - size.y) < 0.00001 { y = size.y }
                    outline.append(SIMD3(x, y, 0))
                }
            }
            rings = [outline, outline.map { SIMD3($0.x, $0.y, size.z) }]
        }
        var output: [Float] = []
        func triangle(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
            for p in [a, b, c] {
                let v = p + minimum
                output.append(contentsOf: [v.x, v.y, v.z])
            }
        }
        let count = rings[0].count
        for ring in 0..<(rings.count - 1) {
            for i in 0..<count {
                let j = (i + 1) % count
                triangle(rings[ring][i], rings[ring][j], rings[ring + 1][j])
                triangle(rings[ring][i], rings[ring + 1][j], rings[ring + 1][i])
            }
        }
        let lowerCenter = SIMD3<Float>(size.x / 2, size.y / 2, 0)
        let upperCenter = SIMD3<Float>(size.x / 2, size.y / 2, size.z)
        for i in 0..<count {
            let j = (i + 1) % count
            triangle(lowerCenter, rings[0][j], rings[0][i])
            triangle(upperCenter, rings.last![i], rings.last![j])
        }
        // Validate the serialized artifact before it is ever offered for upload.
        let result = try STLMesh.parse(STLMesh(vertices: output, minimum: minimum, maximum: maximum).binarySTL())
        guard result.edgeDesignCheck().complete, result.minimum == minimum, result.maximum == maximum else {
            throw StudioError("The edge edit cannot preserve this model’s bounds at STL precision. Use the original CAD model for this edit.")
        }
        return result
    }
}

/// A prepared model has new axes; carry its purpose forward in those axes.
func designEditIntent(_ model: LocalModel) -> PartIntent? {
    guard let recipe = model.printRecipe else { return model.partIntent }
    var intent = recipe.intent
    if let load = intent.load.vector {
        let transformed = abs(recipe.orientation.rotate(load))
        // Do not silently round an oblique load to a different axis.
        intent.load = transformed.x > 0.999999 ? .x : (transformed.y > 0.999999 ? .y : (transformed.z > 0.999999 ? .z : .unknown))
    }
    return intent
}

/// Whether the automatic edge edit can act on a mesh: a plain closed rectangular box at least 0.4 mm on every side.
func edgeImprovementAvailable(_ check: EdgeDesignCheck, extent: SIMD3<Float>) -> Bool {
    check.plainBox && extent.min() >= 0.4
}

/// Shown only when `edgeImprovementAvailable` (with that mesh passed in) or for a copy that already has an edge edit.
struct DesignImprovementsCard: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    /// The model's mesh when its edges can be edited; nil for a copy that already has an edge edit.
    let mesh: STLMesh?
    @State private var kind: EdgeImprovement = .bottomChamfer
    @State private var amount = 0.5
    @State private var review = false
    @State private var preview: STLMesh?
    @State private var edgesAreFree = false
    @State private var saving = false
    @State private var expanded = false

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 14) {
                    if let applied = model.designImprovement {
                        Text("\(applied.kind.rawValue) already applied to this copy.")
                        Text(String(format: "Size: %.2f mm · Original preserved", applied.sizeMM)).font(.caption)
                    } else if mesh != nil {
                        Text("This part is a plain box with square edges. A bottom chamfer adds clearance; rounded corners are easier to handle. Review the fit before applying.")
                        Button("Review Edge Improvement…") { review = true }
                            .disabled(store.busy)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            } label: {
                SectionHeading(title: "Design improvements", caption: model.designImprovement == nil ? "Square edges · Add a bottom chamfer or rounded corners" : "Edge improvement applied · View details")
            }.studioDisclosureStyle()
        }
        .onAppear {
            if let mesh { amount = Double(min(0.5, (mesh.maximum - mesh.minimum).min() / 4)) }
        }
        .sheet(isPresented: $review) { reviewSheet }
    }

    private var reviewSheet: some View {
        VStack(spacing: 0) {
            HStack {
                SectionHeading(title: "Review edge improvement", caption: "Compare the change before saving a new copy")
                Spacer()
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Treatment", selection: $kind) {
                        ForEach(EdgeImprovement.allCases) { Text($0.rawValue).tag($0) }
                    }
                    Text(kind.explanation).font(.callout).foregroundStyle(.secondary)
                    if let mesh {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(String(format: kind == .bottomChamfer ? "Chamfer width: %.2f mm" : "Corner radius: %.2f mm", amount))
                                .font(.callout.weight(.medium))
                            Slider(value: $amount, in: 0.1...Double(min(2, (mesh.maximum - mesh.minimum).min() / 4)))
                                .accessibilityLabel(kind == .bottomChamfer ? "Chamfer width" : "Corner radius")
                        }
                        HStack(spacing: 16) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Original").font(.callout.weight(.medium))
                                STLSceneView(mesh: mesh, showsPrintBed: true)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Proposed copy").font(.callout.weight(.medium))
                                if let preview {
                                    STLSceneView(mesh: preview, showsPrintBed: true).id("\(kind.rawValue)-\(amount)")
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                } else {
                                    Text("Preview unavailable for this size.").frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }.frame(height: 210)
                    }
                    Text("Overall dimensions stay the same. All four selected edges change shape; bed contact may change too. Your original is preserved.")
                        .font(.callout).foregroundStyle(.secondary)
                }.padding(24).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Toggle("These edges are not mating, locating or dimension-critical surfaces", isOn: $edgesAreFree)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { review = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(saving ? "Saving…" : "Apply to New Copy") { saveCopy() }
                        .buttonStyle(.borderedProminent)
                        .disabled(!edgesAreFree || preview == nil || store.busy || saving)
                }
            }.padding(24)
        }
        .frame(width: 680, height: 620)
        .disabled(saving)
        .onAppear { edgesAreFree = false; updatePreview() }
        .onChange(of: kind) { _, _ in edgesAreFree = false; updatePreview() }
        .onChange(of: amount) { _, _ in edgesAreFree = false; updatePreview() }
    }

    private func updatePreview() {
        preview = try? mesh?.applyingEdgeImprovement(kind, size: Float(amount))
    }

    private func saveCopy() {
        guard let preview, edgesAreFree else { return }
        saving = true
        let record = DesignImprovementRecord(sourceID: model.id, kind: kind, sizeMM: Float(amount), created: Date())
        do {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let name = URL(fileURLWithPath: model.name).lastPathComponent
            let url = folder.appendingPathComponent("\(name)-edge-improved.stl")
            try preview.binarySTL().write(to: url, options: .atomic)
            store.importModel(url, improvement: record, intent: designEditIntent(model), reinforcement: model.reinforcement,
                              sourceDetails: model.sourceDetails)
            review = false
        } catch { store.showError(error.localizedDescription) }
        saving = false
    }
}
