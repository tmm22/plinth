import Foundation
import simd
import Euclid

enum ReinforcementKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case rib = "Internal rib"
    case gusset = "Triangular gusset"
    case mount = "Mounting collar"
    case fillet = "Junction fillet"
    case overhang = "Overhang support chamfer"
    case thicken = "Match wall to line width"
    case teardrop = "Teardrop hole roof"
    case bridge = "Counterbore bridging layers"
    case internalWalls = "Internal walls"
    case shell = "Internal shell gap · experimental"
    case holeRing = "Hole-wall ring gap · experimental"
    case cells = "Internal cells · experimental"
    case split = "Split with alignment pins"
    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .rib: return "Adds a web across unused space. Position it so it joins the surfaces you want to reinforce."
        case .gusset: return "Adds a triangular web between adjoining surfaces, with a sloping top."
        case .mount: return "Adds a collar around an existing clear bore. The bore is checked before applying; no hole is drilled."
        case .fillet: return "Adds a rounded transition along an inside junction. Place its two flat sides into the adjoining surfaces."
        case .overhang: return "Fills under a flat downward ledge with a 45° slope (up to Slant’s 50° when the region is a little shorter than it is deep) so it prints without supports. Put the region’s local −Y side into the wall and its top into the ledge; turn about Z to face another wall."
        case .thicken: return "Measures the wall through the region centre along local Y and thickens its +Y side to the next whole number of extrusion lines, avoiding weak gap fill. Slant publishes 1 mm walls, 25% infill and 0.2 mm layers, but not its line width, so the width here is an estimate."
        case .teardrop: return "Adds a 45° point to the top of an existing horizontal hole along local X so it prints without sagging or supports. This enlarges the hole at the top; use only where the top of the hole is not fit-critical."
        case .bridge: return "For a counterbore that opens downward, cuts two single-layer steps into its ceiling so each layer bridges between solid edges. Set position Z at the ceiling and the region footprint to the counterbore diameter. Slightly reduces the screw-head bearing area."
        case .internalWalls: return "Cuts thin \(String(format: "%.2f", internalWallsSlotWidthMM)) mm slots up from the bed face into thick, solid regions, at least \(Int(internalWallsClearanceMM)) mm from every other surface. Slant’s slicer prints its 1 mm walls round each slot, which adds internal walls where the part would otherwise be 25% infill. Every slot opens through the bed face, so the part stays one body. Applies to the whole part, which must stand on a flat face at its lowest point; keep-clear regions are left uncut. Uses more filament, so request a new Slant quote."
        case .shell, .cells: return reinforcementClosedVoidWithdrawal
        case .holeRing: return "Cuts a thin ring-shaped gap around an existing vertical bore, from the bed face up, so the slicer prints extra perimeters around the hole. The gap opens through the bed face, so the part stays one body: start the region at position Z 0. The bore itself is unchanged. Validate a Slant print before production."
        case .split: return "Cuts the part on the region’s local mid-height plane into two copies with matching blind holes for two alignment pins. Each half can then be prepared in its own best orientation. Assemble with dowels or printed pins and adhesive; the joint is weaker than solid material, so keep it away from peak loads."
        }
    }
    /// Features whose printability or perimeter behaviour depends on the layers running in local XY.
    var keepsZUp: Bool { [.cells, .shell, .holeRing, .teardrop, .bridge, .overhang, .thicken, .internalWalls].contains(self) }
    var isExperimental: Bool { [.cells, .shell, .holeRing].contains(self) }
    var removesMaterial: Bool { [.cells, .shell, .holeRing, .teardrop, .bridge, .internalWalls].contains(self) }
    /// Treatments that always leave a closed void inside the part. Slant bills each closed void as an extra body, so
    /// they are no longer offered or previewed; the cases stay so earlier copies' records still read.
    var isWithdrawn: Bool { [.shell, .cells].contains(self) }
    /// The treatments the picker offers.
    static var offered: [ReinforcementKind] { allCases.filter { !$0.isWithdrawn } }
    var thicknessLabel: String? {
        switch self {
        case .rib, .gusset, .fillet: return "Web thickness"
        case .mount: return "Minimum collar thickness"
        case .cells: return "Web / outer clearance"
        case .shell: return "Material cover around the gap"
        case .holeRing: return "Wall between hole and gap"
        case .teardrop: return "Material kept above the point"
        case .split: return "Wall around each pin hole"
        case .overhang, .thicken, .bridge, .internalWalls: return nil
        }
    }
    var boreLabel: String? {
        switch self {
        case .mount: return "Existing clear bore diameter"
        case .holeRing: return "Existing bore diameter"
        case .teardrop: return "Existing horizontal hole diameter"
        case .bridge: return "Through-hole diameter"
        case .split: return "Alignment pin hole diameter"
        default: return nil
        }
    }
    var fileSuffix: String {
        switch self {
        case .cells: return "experimental-cells"
        case .shell: return "experimental-shell"
        case .holeRing: return "experimental-hole-ring"
        case .teardrop: return "teardrop"
        case .bridge: return "bridging"
        case .overhang: return "overhang-chamfer"
        case .thicken: return "matched-wall"
        case .split: return "part"
        case .internalWalls: return "internal-walls"
        default: return "reinforced"
        }
    }
}

/// Why the closed gap and cell treatments are no longer offered.
let reinforcementClosedVoidWithdrawal = "No longer offered: this treatment leaves a closed gap inside the part, and Slant charges each closed gap or cavity as an extra body (about $0.39 each in a live Slant estimate, 25 Oct 2026). Use Internal walls, whose slots open through the bed face."

/// The shell check's refusal: a copy with more separate shells than its source has a closed void (or a new loose piece).
func reinforcementShellGrowthProblem(before: Int, after: Int) -> String? {
    guard after > before else { return nil }
    return "This change would leave \(after - before == 1 ? "a closed gap or a loose piece" : "closed gaps or loose pieces") inside the part (\(before) separate \(before == 1 ? "shell" : "shells") before, \(after) after). Slant charges each one as an extra body, so no copy can be saved."
}

struct ReinforcementBox: Codable, Equatable, Sendable, Identifiable {
    var id = UUID()
    /// Coordinates relative to the original model minimum, in mm.
    var offset: SIMD3<Float>
    var size: SIMD3<Float>
}

struct ReinforcementSettings: Codable, Equatable, Sendable {
    var kind: ReinforcementKind = .rib
    var offset = SIMD3<Float>(repeating: 0)
    /// Tool-local dimensions before the selected axis rotation.
    var size = SIMD3<Float>(8, 8, 8)
    var orientation: PrintOrientation = .zUp
    var thickness: Float = 1.6
    var boreDiameter: Float = 3
    var protectedRegions: [ReinforcementBox] = []
    /// Quarter turns about local Z, applied before `orientation`.
    var quarterTurns = 0
    var gapWidth: Float = 0.2
    var layerHeight: Float = 0.2
    var lineWidth: Float = 0.45

    static func initial(for mesh: STLMesh) -> Self {
        var value = Self()
        let extent = mesh.maximum - mesh.minimum
        value.size = simd_min(extent * 0.6, SIMD3<Float>(repeating: 12))
        value.offset = (extent - value.size) / 2
        return value
    }

    /// Tool-local to world rotation. Every case is an exact axis permutation with signs.
    func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
        var q = p
        for _ in 0..<((quarterTurns % 4 + 4) % 4) { q = SIMD3(-q.y, q.x, q.z) }
        return orientation.rotate(q)
    }
}

extension ReinforcementSettings {
    private enum CodingKeys: String, CodingKey {
        case kind, offset, size, orientation, thickness, boreDiameter, protectedRegions, quarterTurns, gapWidth, layerHeight, lineWidth
    }
    /// Records saved before the newer treatments omit their fields.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = Self()
        kind = try c.decode(ReinforcementKind.self, forKey: .kind)
        offset = try c.decode(SIMD3<Float>.self, forKey: .offset)
        size = try c.decode(SIMD3<Float>.self, forKey: .size)
        orientation = try c.decode(PrintOrientation.self, forKey: .orientation)
        thickness = try c.decode(Float.self, forKey: .thickness)
        boreDiameter = try c.decode(Float.self, forKey: .boreDiameter)
        protectedRegions = try c.decode([ReinforcementBox].self, forKey: .protectedRegions)
        quarterTurns = try c.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? defaults.quarterTurns
        gapWidth = try c.decodeIfPresent(Float.self, forKey: .gapWidth) ?? defaults.gapWidth
        layerHeight = try c.decodeIfPresent(Float.self, forKey: .layerHeight) ?? defaults.layerHeight
        lineWidth = try c.decodeIfPresent(Float.self, forKey: .lineWidth) ?? defaults.lineWidth
    }
}

struct ReinforcementRecord: Codable, Equatable, Sendable {
    let sourceID: UUID
    let settings: ReinforcementSettings
    let addedVolumeMM3: Double
    let removedVolumeMM3: Double
    let created: Date
    /// Testing is never inferred from successful mesh generation.
    var testPrintApproved = false
    /// Stored under its original name; set when any earlier copy had Z-up-dependent features.
    var inheritedCellRoofs: Bool? = nil
    var requiresZUp: Bool { settings.kind.keepsZUp || inheritedCellRoofs == true }
}

struct ReinforcementPreview: Sendable {
    let mesh: STLMesh
    let originalSection: STLMesh?
    let proposedSection: STLMesh?
    let addedVolume: Double
    let removedVolume: Double
    /// Separate shells (connected surfaces) in the source and in the copy; for a split, the larger part's count.
    /// A copy never has more than its source.
    var shellsBefore = 0
    var shellsAfter = 0
    /// Internal walls only: the engine's summary line.
    var detail: String? = nil
    /// Split only: the second saved part, and both parts separated for display.
    var secondPart: STLMesh? = nil
    var exploded: STLMesh? = nil
    /// The validated result before STL rounding, for chaining further changes without a Float round trip.
    var solid: Mesh? = nil
}

private func vector(_ p: SIMD3<Float>) -> Vector { Vector(Double(p.x), Double(p.y), Double(p.z)) }
private func point(_ p: Vector) -> SIMD3<Float> { SIMD3(Float(p.x), Float(p.y), Float(p.z)) }

extension STLMesh {
    func reinforcementSolid() throws -> Mesh {
        guard triangleCount > 0, triangleCount <= 20_000 else {
            throw StudioError("Reinforcement previews support STL meshes up to 20,000 triangles. Simplify a copy in CAD for this operation.")
        }
        var polygons: [Polygon] = []
        var edgeCounts: [MeshEdge: Int] = [:]
        var edgeDirections: [MeshEdge: Int] = [:]
        for i in stride(from: 0, to: vertices.count, by: 9) {
            let points = [0, 3, 6].map { j in Vector(Double(vertices[i+j]), Double(vertices[i+j+1]), Double(vertices[i+j+2])) }
            guard let polygon = Polygon(points) else { throw StudioError("Use a closed solid STL for reinforcement.") }
            polygons.append(polygon)
            for j in 0..<3 {
                let a = point(points[j]), b = point(points[(j+1)%3])
                let edge = MeshEdge(a,b)
                edgeCounts[edge, default: 0] += 1
                edgeDirections[edge, default: 0] += edge.a == a ? 1 : -1
            }
        }
        guard edgeCounts.values.allSatisfy({ $0 == 2 }), edgeDirections.values.allSatisfy({ $0 == 0 }) else {
            throw StudioError("Use a consistently oriented, closed manifold STL for reinforcement. Prepare this mesh in CAD first.")
        }
        let solid = Mesh(planarizedPolygons() ?? polygons)
        guard solid.isWatertight, solid.signedVolume > 0 else { throw StudioError("Use a closed, outward-facing solid STL for reinforcement.") }
        return solid
    }

    /// Float STL rounding leaves the triangles of one flat face slightly non-coplanar, and folds
    /// near-degenerate triangles over their neighbours. Euclid's BSP (1e-8 tolerance) turns both
    /// into open slivers. Fits one plane per flat face, moves each vertex (by well under 0.1 µm)
    /// onto its incident face planes, and merges needle triangles into adjacent same-face polygons.
    /// Returns nil when this cannot be done safely; callers then use the raw triangles.
    private func planarizedPolygons() -> [Polygon]? {
        var index: [SIMD3<Float>: Int] = [:]
        var positions: [SIMD3<Double>] = []
        var triangles: [[Int]] = []
        for i in stride(from: 0, to: vertices.count, by: 9) {
            triangles.append((0..<3).map { j in
                let p = SIMD3(vertices[i+3*j], vertices[i+3*j+1], vertices[i+3*j+2])
                if let k = index[p] { return k }
                index[p] = positions.count
                positions.append(SIMD3<Double>(p))
                return positions.count - 1
            })
        }
        let normals = triangles.map { t in simd_cross(positions[t[1]]-positions[t[0]], positions[t[2]]-positions[t[0]]) }
        guard normals.allSatisfy({ simd_length($0) > 0 }) else { return nil }

        var neighbours = Array(repeating: [Int](), count: triangles.count)
        var edgeOwner: [SIMD2<Int>: Int] = [:]
        for (ti, t) in triangles.enumerated() {
            for j in 0..<3 {
                let key = SIMD2(min(t[j], t[(j+1)%3]), max(t[j], t[(j+1)%3]))
                if let other = edgeOwner.removeValue(forKey: key) { neighbours[ti].append(other); neighbours[other].append(ti) } else { edgeOwner[key] = ti }
            }
        }
        // Grow each flat face from its largest triangle: needle triangles have unreliable planes of their own.
        var face = Array(repeating: -1, count: triangles.count)
        var members: [Int: [Int]] = [:]
        for seed in triangles.indices.sorted(by: { simd_length(normals[$0]) > simd_length(normals[$1]) }) where face[seed] < 0 {
            let n = simd_normalize(normals[seed]), w = simd_dot(n, positions[triangles[seed][0]])
            var stack = [seed]
            face[seed] = seed
            while let ti = stack.popLast() {
                members[seed, default: []].append(ti)
                // Folded triangles face the opposite way but still lie on the same plane.
                for other in neighbours[ti] where face[other] < 0 && triangles[other].allSatisfy({ abs(simd_dot(n, positions[$0]) - w) < 1e-5 }) {
                    face[other] = seed
                    stack.append(other)
                }
            }
        }

        // Set and Dictionary iteration order changes with each process's hash seed. Everything below that
        // sums, solves or merges walks vertices, faces and triangles in index order, so a mesh always gives
        // the same snapped geometry.
        var planes: [Int: (normal: SIMD3<Double>, offset: Double)] = [:]
        for (id, list) in members {
            let normal = simd_normalize(list.reduce(SIMD3<Double>()) { $0 + normals[$1] })
            let points = Set(list.flatMap { triangles[$0] }).sorted()
            let offset = points.reduce(0) { $0 + simd_dot(normal, positions[$1]) } / Double(points.count)
            guard points.allSatisfy({ abs(simd_dot(normal, positions[$0]) - offset) < 1e-5 }) else { return nil }
            planes[id] = (normal, offset)
        }

        var incident = Array(repeating: Set<Int>(), count: positions.count)
        for (ti, t) in triangles.enumerated() { for v in t { incident[v].insert(face[ti]) } }
        // Closest point to the original vertex on all incident planes: x = x0 + Nᵀ(NNᵀ)⁻¹(w - N·x0).
        var snapped = positions
        for (v, faces) in incident.enumerated() {
            let constraints = faces.sorted().map { planes[$0]! }
            let x0 = positions[v]
            var x = x0
            switch constraints.count {
            case 1:
                x += constraints[0].normal * (constraints[0].offset - simd_dot(constraints[0].normal, x0))
            case 2:
                let (n1, w1) = constraints[0], (n2, w2) = constraints[1]
                let c = simd_dot(n1, n2), det = 1 - c * c
                guard det > 1e-12 else { return nil }
                let r1: Double = w1 - simd_dot(n1, x0), r2: Double = w2 - simd_dot(n2, x0)
                let y1: Double = (r1 - c * r2) / det, y2: Double = (r2 - c * r1) / det
                x += n1 * y1
                x += n2 * y2
            case 3:
                let n = simd_double3x3(rows: constraints.map(\.normal))
                guard abs(n.determinant) > 1e-9 else { return nil }
                x = n.inverse * SIMD3(constraints.map(\.offset))
            default:
                // Kaczmarz projections; only consistent planes converge, which the residual check enforces.
                for _ in 0..<200 { for (n, w) in constraints { x += n * (w - simd_dot(n, x)) } }
            }
            guard x.x.isFinite, x.y.isFinite, x.z.isFinite, simd_distance(x, positions[v]) < 1e-4 else { return nil }
            // Four or more inconsistent planes meeting at a vertex cannot be satisfied exactly.
            guard faces.allSatisfy({ abs(simd_dot(planes[$0]!.normal, x) - planes[$0]!.offset) < 1e-11 }) else { return nil }
            snapped[v] = x
        }

        // Merge each needle or folded triangle into a same-face neighbour across a shared edge.
        var loops = Dictionary(uniqueKeysWithValues: triangles.enumerated().map { ($0.offset, $0.element) })
        var owner: [SIMD2<Int>: Int] = [:]
        for (ti, t) in triangles.enumerated() { for j in 0..<3 { owner[SIMD2(t[j], t[(j+1)%3])] = ti } }
        func isNeedle(_ loop: [Int], _ n: SIMD3<Double>) -> Bool {
            var area = SIMD3<Double>(), longest = 0.0
            for j in loop.indices {
                let p = snapped[loop[j]], q = snapped[loop[(j+1)%loop.count]]
                area += simd_cross(p, q)
                longest = max(longest, simd_distance(p, q))
            }
            return simd_dot(area, n) / 2 <= 1e-4 * longest * longest
        }
        // Popped from the end, so needles merge in ascending triangle order.
        var pending = loops.keys.sorted(by: >).filter { isNeedle(loops[$0]!, planes[face[$0]]!.normal) }
        while let id = pending.popLast() {
            guard let loop = loops[id] else { continue }
            let n = planes[face[id]]!.normal
            guard isNeedle(loop, n) else { continue }
            var merged = false
            // Merging across the longest edge inserts the needle's apex into a neighbouring edge;
            // a short edge would leave the apex touching the merged outline.
            let edges = loop.indices.sorted { simd_distance(snapped[loop[$0]], snapped[loop[($0+1)%loop.count]]) > simd_distance(snapped[loop[$1]], snapped[loop[($1+1)%loop.count]]) }
            // Prefer a valid same-face merge, then a valid merge into the neighbouring face (a degenerate rim
            // triangle lies on both), then a same-face merge that a later merge may complete.
            let passes: [(sameFace: Bool, requireValid: Bool)] = [(true, true), (false, true), (true, false)]
            for (pass, j) in passes.flatMap({ pass in edges.map { (pass, $0) } }) where !merged {
                let requireValid = pass.requireValid
                let u = loop[j], v = loop[(j+1)%loop.count]
                guard let other = owner[SIMD2(v, u)], other != id, let target = loops[other] else { continue }
                let targetPlane = planes[face[other]]!
                guard pass.sameFace ? face[other] == face[id] : face[other] != face[id] && loop.allSatisfy({ abs(simd_dot(targetPlane.normal, snapped[$0]) - targetPlane.offset) < 1e-9 }) else { continue }
                // Insert this loop's remaining vertices between v and u of the neighbour.
                let rest = (2..<loop.count).map { loop[(j+$0)%loop.count] }
                guard rest.allSatisfy({ !target.contains($0) }), let at = target.indices.first(where: { target[$0] == v && target[($0+1)%target.count] == u }) else { continue }
                var combined = target
                combined.insert(contentsOf: rest, at: at + 1)
                guard !requireValid || Polygon(combined.map { Vector(snapped[$0].x, snapped[$0].y, snapped[$0].z) }) != nil else { continue }
                for k in loop.indices { owner[SIMD2(loop[k], loop[(k+1)%loop.count])] = nil }
                owner[SIMD2(v, u)] = nil
                for k in combined.indices { owner[SIMD2(combined[k], combined[(k+1)%combined.count])] = other }
                loops[id] = nil
                loops[other] = combined
                if isNeedle(combined, targetPlane.normal) { pending.append(other) }
                merged = true
            }
            guard merged else { return nil }
        }

        var result: [Polygon] = []
        result.reserveCapacity(loops.count)
        // Sorted for a deterministic BSP build order.
        for id in loops.keys.sorted() {
            let n = planes[face[id]]!.normal
            guard let polygon = Polygon(loops[id]!.map { Vector(snapped[$0].x, snapped[$0].y, snapped[$0].z) }),
                  polygon.plane.normal.dot(Vector(n.x, n.y, n.z)) > 1 - 1e-12 else { return nil }
            result.append(polygon)
        }
        return result
    }
}

/// All generated features are explicit solids, fused by CSG. No overlapping STL shells are exported.
enum ReinforcementEngine {
    static func stl(_ mesh: Mesh) throws -> STLMesh {
        let vertices = floatTriangles(mesh).flatMap { $0.flatMap { [$0.x, $0.y, $0.z] } }
        guard vertices.count <= 500_000 * 9 else { throw StudioError("The result is too detailed for this preview. Use a smaller reinforcement region.") }
        return try STLMesh.parse(STLMesh(vertices: vertices, minimum: .zero, maximum: .one).binarySTL())
    }

    /// Triangles at Float STL precision. Triangles whose corners coincide are dropped. A thin triangle at a
    /// T-junction can round to three collinear points; dropping it would open the seam, so the neighbour across
    /// its long edge is split at the middle point instead. Validation of the parsed STL still requires a closed result.
    private static func floatTriangles(_ mesh: Mesh) -> [[SIMD3<Float>]] {
        var triangles: [[SIMD3<Float>]?] = mesh.polygons.flatMap { $0.triangulate() }.map { $0.vertices.map { point($0.position) } }
        func isValid(_ t: [SIMD3<Float>]) -> Bool { Polygon(t.map(vector)) != nil }
        var owner: [[SIMD3<Float>]: Int] = [:]
        func register(_ i: Int) { if let t = triangles[i] { for j in 0..<3 { owner[[t[j], t[(j+1)%3]]] = i } } }
        func unregister(_ i: Int) { if let t = triangles[i] { for j in 0..<3 where owner[[t[j], t[(j+1)%3]]] == i { owner[[t[j], t[(j+1)%3]]] = nil } } }
        var collinear: [Int] = []
        for (i, t) in triangles.enumerated() {
            if Set(t!).count < 3 { triangles[i] = nil } else if !isValid(t!) { collinear.append(i) }
        }
        for i in triangles.indices { register(i) }
        var budget = 4 * triangles.count
        while let i = collinear.popLast(), budget > 0 {
            budget -= 1
            guard let t = triangles[i], !isValid(t) else { continue }
            let j = (0..<3).max { simd_distance(t[$0], t[($0+1)%3]) < simd_distance(t[$1], t[($1+1)%3]) }!
            let p = t[j], q = t[(j+1)%3], m = t[(j+2)%3]
            guard let n = owner[[q, p]], let neighbour = triangles[n], let k = neighbour.firstIndex(of: q) else { unregister(i); triangles[i] = nil; continue }
            let r = neighbour[(k+2)%3]
            unregister(i)
            triangles[i] = nil
            guard r != m else { continue }
            unregister(n)
            triangles[n] = [q, m, r]
            triangles.append([m, p, r])
            register(n)
            register(triangles.count - 1)
            for index in [n, triangles.count - 1] where !isValid(triangles[index]!) {
                if Set(triangles[index]!).count < 3 { unregister(index); triangles[index] = nil } else { collinear.append(index) }
            }
        }
        return triangles.compactMap { $0 }.filter(isValid)
    }

    private static func box(_ low: SIMD3<Float>, _ size: SIMD3<Float>) -> Mesh {
        .cube(center: vector(low + size / 2), size: vector(size))
    }

    /// Extrudes an anticlockwise YZ profile along local X.
    private static func prism(_ profile: [SIMD2<Float>], width: Float) -> Mesh {
        let lower = profile.map { Vector(0, Double($0.x), Double($0.y)) }
        let upper = profile.map { Vector(Double(width), Double($0.x), Double($0.y)) }
        var polygons = [Polygon(lower.reversed())!, Polygon(upper)!]
        for i in profile.indices {
            let j = (i + 1) % profile.count
            polygons.append(Polygon([lower[i], lower[j], upper[j], upper[i]])!)
        }
        let result = Mesh(polygons)
        return result.signedVolume < 0 ? result.inverted() : result
    }

    /// 48-sided cylinder along local Z from z = 0 to `height`.
    private static func cylinder(radius: Float, height: Float, center: SIMD2<Float>) -> Mesh {
        let points = (0..<48).map { i -> SIMD2<Float> in
            let angle = Float(i) * 2 * .pi / 48
            return SIMD2(radius * cos(angle), radius * sin(angle))
        }
        // Our prism extrudes along X; rotate (X,Y,Z) -> (Y,Z,X), preserving handedness.
        let mesh = prism(points, width: height)
        return Mesh(mesh.polygons.map { polygon in
            Polygon(polygon.vertices.map { v in Vector(v.position.y + Double(center.x), v.position.z + Double(center.y), v.position.x) })!
        })
    }

    /// 48-sided cylinder along local X from x = 0 to `length`, centred at (y, z).
    private static func cylinderX(radius: Float, length: Float, center: SIMD2<Float>) -> Mesh {
        Mesh(cylinder(radius: radius, height: length, center: center).polygons.map { polygon in
            Polygon(polygon.vertices.map { Vector($0.position.z, $0.position.x, $0.position.y) })!
        })
    }

    /// 48-sided tube along local Z between `z0` and `z1`.
    private static func annulus(inner: Float, outer: Float, z0: Float, z1: Float, center: SIMD2<Float>) -> Mesh {
        func ring(_ radius: Float, _ z: Float) -> [Vector] {
            (0..<48).map { i in
                let angle = Double(i) * 2 * Double.pi / 48
                return Vector(Double(center.x) + Double(radius)*cos(angle), Double(center.y) + Double(radius)*sin(angle), Double(z))
            }
        }
        let a = ring(outer,z0), b = ring(outer,z1), c = ring(inner,z0), d = ring(inner,z1)
        var polygons: [Polygon] = []
        for i in 0..<48 {
            let j = (i+1)%48
            for points in [[a[i],a[j],b[j],b[i]], [c[j],c[i],d[i],d[j]], [b[i],b[j],d[j],d[i]], [a[j],a[i],c[i],c[j]]] {
                polygons.append(Polygon(points)!)
            }
        }
        return Mesh(polygons)
    }

    /// Circumscribed radius whose 48-sided polygon still clears a circle of `diameter`.
    private static func clearanceRadius(_ diameter: Float) -> Float { diameter / 2 / cos(.pi / 48) }

    static func boreClearance(_ settings: ReinforcementSettings, inset: Float = 0) -> Mesh {
        cylinder(radius: clearanceRadius(settings.boreDiameter)-inset, height: settings.size.z, center: SIMD2(settings.size.x/2,settings.size.y/2))
    }

    private static func pinCentres(_ s: SIMD3<Float>) -> [SIMD2<Float>] { [SIMD2(s.x*0.25, s.y/2), SIMD2(s.x*0.75, s.y/2)] }

    /// The first-layer strip across the counterbore and the second-layer square around the through-hole, in local coordinates.
    private static func bridgeSteps(_ settings: ReinforcementSettings) throws -> [Mesh] {
        let s = settings.size, d = settings.boreDiameter, h = settings.layerHeight
        let center = SIMD2(s.x/2, s.y/2), outer = min(s.x, s.y)
        guard (0.05...0.6).contains(h), d / 2 >= 0.6, outer >= d + 1.2 else { throw StudioError("Use a layer height of 0.05–0.6 mm and a counterbore at least 1.2 mm wider than the through-hole.") }
        // Starts just below the ceiling, in the open counterbore, so no face is coplanar with the ceiling.
        let strip = box(SIMD3(center.x - outer/2, center.y - d/2, -0.05), SIMD3(outer, d, h + 0.05))
            .intersection(cylinder(radius: outer/2 - 0.05, height: h + 0.05, center: center).translated(by: Vector(0, 0, -0.05)))
        let square = box(SIMD3(center.x - d/2, center.y - d/2, h), SIMD3(d, d, h))
        return [strip.makeWatertight(), square]
    }

    static func tool(_ settings: ReinforcementSettings) throws -> Mesh {
        let s = settings.size, t = settings.thickness, d = settings.boreDiameter
        guard [s.x, s.y, s.z, t, d, settings.offset.x, settings.offset.y, settings.offset.z, settings.gapWidth, settings.layerHeight, settings.lineWidth].allSatisfy({ $0.isFinite }),
              s.min() >= 1.2, s.max() <= slantBuildVolumeMM, t >= 1.2, settings.kind.thicknessLabel == nil || t <= s.min(), (0...3).contains(settings.quarterTurns),
              PrintOrientation.allCases.contains(settings.orientation) else {
            throw StudioError("Use finite dimensions of at least 1.2 mm, with thickness no larger than the region. The 1.2 mm limit is an app guideline, not a Slant qualification.")
        }
        if settings.kind.keepsZUp && settings.orientation != .zUp {
            throw StudioError("Keep this treatment facing Z up; it depends on the print layers. Use Turn about Z to change its direction, and prepare the part’s print orientation first.")
        }
        let center = SIMD2(s.x/2, s.y/2)
        switch settings.kind {
        case .rib:
            return box(SIMD3((s.x-t)/2, 0, 0), SIMD3(t, s.y, s.z))
        case .gusset:
            return prism([SIMD2(0,0), SIMD2(s.y,0), SIMD2(0,s.z)], width: t)
                .translated(by: Vector(Double((s.x-t)/2), 0, 0))
        case .fillet:
            let r = min(s.y, s.z)
            var profile: [SIMD2<Float>] = [.zero, SIMD2(r,0)]
            // About 0.25 mm per segment: denser arcs on small radii only add slivers to later Booleans.
            let segments = min(24, max(6, Int((r / 0.25).rounded(.up))))
            for i in 1...segments {
                let angle = -.pi / 2 - Float(i) * .pi / Float(2 * segments)
                profile.append(SIMD2(r + r * cos(angle), r + r * sin(angle)))
            }
            profile[profile.count-1] = SIMD2(0,r)
            return prism(profile, width: s.x)
        case .mount:
            let outer = min(s.x, s.y) / 2
            // Keep the new collar clear of the existing bore surface.
            let innerRadius = clearanceRadius(d) + 0.01
            guard d / 2 >= 0.6, outer - innerRadius >= t else { throw StudioError("Leave at least the chosen thickness around the existing bore.") }
            return annulus(inner: innerRadius, outer: outer, z0: 0, z1: s.z, center: center)
        case .overhang:
            // Wall on local −Y, ledge underside at the region top; the 45° face points down and outward. A region a
            // little shorter than it is deep, down to `overhangChamferMinimumRise` of its depth, gets one face across
            // its full depth instead, no steeper than Slant's 50°.
            if s.z < s.y, s.z >= s.y * overhangChamferMinimumRise {
                return prism([SIMD2(0, 0), SIMD2(s.y, s.z), SIMD2(0, s.z)], width: s.x)
            }
            let leg = min(s.y, s.z)
            return prism([SIMD2(0, s.z-leg), SIMD2(leg, s.z), SIMD2(0, s.z)], width: s.x)
        case .thicken:
            // Nominal slab for display; previews measure the wall and size the slab to it.
            guard (0.2...1.2).contains(settings.lineWidth) else { throw StudioError("Use an estimated line width between 0.2 and 1.2 mm.") }
            return box(SIMD3(0, s.y/2, 0), SIMD3(s.x, settings.lineWidth, s.z))
        case .teardrop:
            let r = d / 2, c = r * Float(2).squareRoot() / 2, apex = r * Float(2).squareRoot()
            guard r >= 0.6, s.y >= 2 * r, s.z / 2 + apex <= s.z else { throw StudioError("Make the region at least as wide as the hole and tall enough for its 45° point.") }
            return prism([SIMD2(center.y, s.z/2), SIMD2(center.y+c, s.z/2+c), SIMD2(center.y, s.z/2+apex), SIMD2(center.y-c, s.z/2+c)], width: s.x)
        case .bridge:
            let steps = try bridgeSteps(settings)
            return steps[0].union(steps[1]).makeWatertight()
        case .internalWalls:
            // Display only: one nominal slot. Previews run the internal walls engine over the whole part.
            let w = internalWallsSlotWidthMM
            return box(SIMD3((s.x - w) / 2, 0, 0), SIMD3(w, s.y, s.z))
        case .shell:
            let g = settings.gapWidth
            guard (0.05...1).contains(g), s.x > 2*g + 1.2, s.y > 2*g + 1.2 else { throw StudioError("Use a gap of 0.05–1 mm and a region that leaves at least 1.2 mm inside the gap.") }
            return box(.zero, s).subtracting(box(SIMD3(g, g, -1), SIMD3(s.x-2*g, s.y-2*g, s.z+2))).makeWatertight()
        case .holeRing:
            let g = settings.gapWidth, inner = clearanceRadius(d) + t
            guard (0.05...1).contains(g), d / 2 >= 0.6, inner + g <= min(s.x, s.y) / 2 else { throw StudioError("Use a gap of 0.05–1 mm and a region wide enough for the hole, its wall and the gap.") }
            return annulus(inner: inner, outer: inner + g, z0: 0, z1: s.z, center: center)
        case .cells:
            // Four vertical cavities with 45-degree gabled roofs; all remain inside the selected region.
            let w = (s.x-t)/2, depth = (s.y-t)/2
            let roof = depth/2
            guard w >= 1.2, depth >= 1.2, s.z > roof + 1.2 else { throw StudioError("Increase the cell region to leave printable cavities, a separating web and sloping roofs.") }
            let profile = [SIMD2<Float>(0,0), SIMD2(depth,0), SIMD2(depth,s.z-roof), SIMD2(depth/2,s.z), SIMD2(0,s.z-roof)]
            var cavities: [Mesh] = []
            for x in [Float(0), w+t] {
                for y in [Float(0), depth+t] {
                    cavities.append(prism(profile, width: w).translated(by: Vector(Double(x),Double(y),0)))
                }
            }
            return Mesh(submeshes: cavities)
        case .split:
            let r = d / 2
            guard r >= 0.6, s.x * 0.25 >= r + 0.3, s.x * 0.5 >= d + 0.6, s.y >= d else { throw StudioError("Make the region long enough for two separated pin holes.") }
            let pins = pinCentres(s).map { cylinder(radius: r, height: s.z, center: $0) }
            return pins[0].union(pins[1])
        }
    }

    private static func regionLow(_ settings: ReinforcementSettings) -> SIMD3<Float> {
        Bounds(min: .zero, max: vector(settings.size)).corners.map { settings.rotate(point($0)) }
            .reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude), simd_min)
    }

    private static func world(_ local: SIMD3<Float>, settings: ReinforcementSettings, minimum: SIMD3<Float>) -> SIMD3<Float> {
        minimum + settings.offset - regionLow(settings) + settings.rotate(local)
    }

    private static func placed(_ local: Mesh, settings: ReinforcementSettings, minimum: SIMD3<Float>) -> Mesh {
        let translation = minimum + settings.offset - regionLow(settings)
        return Mesh(local.polygons.map { polygon in
            Polygon(polygon.vertices.map { vector(settings.rotate(point($0.position)) + translation) })!
        })
    }

    static func containsMaterial(_ point: SIMD3<Float>, in mesh: STLMesh) -> Bool {
        let p = SIMD3<Double>(point)
        var angle: Double = 0
        for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
            func v(_ j: Int) -> SIMD3<Double> { SIMD3(Double(mesh.vertices[i+j]), Double(mesh.vertices[i+j+1]), Double(mesh.vertices[i+j+2]))-p }
            let a=v(0), b=v(3), c=v(6)
            let la=simd_length(a), lb=simd_length(b), lc=simd_length(c)
            let numerator = simd_dot(a,simd_cross(b,c))
            let denominator = la*lb*lc + simd_dot(a,b)*lc + simd_dot(b,c)*la + simd_dot(c,a)*lb
            angle += 2*atan2(numerator,denominator)
        }
        return abs(angle) > 2 * .pi
    }

    /// Nearest surface hit along a ray (Möller–Trumbore), in mm.
    static func distanceToSurface(from origin: SIMD3<Float>, along direction: SIMD3<Float>, in mesh: STLMesh) -> Float? {
        let o = SIMD3<Double>(origin), dir = SIMD3<Double>(direction)
        var nearest: Double?
        for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
            func v(_ j: Int) -> SIMD3<Double> { SIMD3(Double(mesh.vertices[i+j]), Double(mesh.vertices[i+j+1]), Double(mesh.vertices[i+j+2])) }
            let a = v(0), e1 = v(3)-a, e2 = v(6)-a
            let pv = simd_cross(dir, e2), det = simd_dot(e1, pv)
            guard abs(det) > 1e-12 else { continue }
            let tv = o-a, u = simd_dot(tv, pv)/det
            guard u >= 0, u <= 1 else { continue }
            let qv = simd_cross(tv, e1), w = simd_dot(dir, qv)/det
            guard w >= 0, u + w <= 1 else { continue }
            let distance = simd_dot(e2, qv)/det
            if distance > 1e-6, distance < (nearest ?? .greatestFiniteMagnitude) { nearest = distance }
        }
        return nearest.map(Float.init)
    }

    /// Requires `mesh` to lie entirely inside existing material.
    private static func requireSolid(_ mesh: Mesh, in original: Mesh, _ message: String, _ stop: @escaping @Sendable () -> Bool) throws {
        let missing = mesh.subtracting(original, isCancelled: stop)
        guard abs(missing.signedVolume) < 0.0001 else { throw StudioError(message) }
    }

    /// Requires `mesh` to lie entirely in existing empty space.
    private static func requireClear(_ mesh: Mesh, in original: Mesh, _ message: String, _ stop: @escaping @Sendable () -> Bool) throws {
        let occupied = original.intersection(mesh, isCancelled: stop)
        guard abs(occupied.signedVolume) < 0.0001 else { throw StudioError(message) }
    }

    private static let manualOnly: Set<ReinforcementKind> = [.holeRing, .teardrop, .bridge, .thicken, .split]

    /// Bounded geometric starting-position search. Fit and intended load still require user review.
    static func suggestPosition(_ source: STLMesh, settings: ReinforcementSettings, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> ReinforcementSettings {
        guard !settings.kind.isWithdrawn else { throw StudioError(reinforcementClosedVoidWithdrawal) }
        guard settings.kind != .internalWalls else {
            throw StudioError("Internal walls cover the whole part, so they need no position. Choose Update Preview.")
        }
        guard !manualOnly.contains(settings.kind) else {
            throw StudioError("Suggest position is not available for this treatment. Position it on the existing hole, wall or cut location, then preview.")
        }
        let deadline = Date().addingTimeInterval(15)
        let stop: @Sendable () -> Bool = { cancelled() || Date() > deadline }
        let original = try source.reinforcementSolid()
        let local = try tool(settings)
        let corners = Bounds(min: .zero, max: vector(settings.size)).corners.map { settings.rotate(point($0)) }
        let low = corners.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude), simd_min)
        let high = corners.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude), simd_max)
        let available = source.maximum-source.minimum-(high-low)
        guard available.min() >= 0 else { throw StudioError("Reduce the feature dimensions to fit this model.") }
        var best: (ReinforcementSettings, Double)?
        // Centre first, then near each edge. A slight inset keeps exterior bounds unchanged.
        for x in [Float(0.5), 0.05, 0.95] {
            for y in [Float(0.5), 0.05, 0.95] {
                for z in [Float(0.5), 0.05, 0.95] {
                    if stop() { break }
                    var candidate = settings
                    candidate.offset = available * SIMD3(x,y,z)
                    let feature = placed(local, settings: candidate, minimum: source.minimum)
                    if settings.kind == .cells || settings.kind == .shell {
                        let t = candidate.thickness
                        let envelope = box(point(feature.bounds.min)-SIMD3(repeating:t), point(feature.bounds.size)+SIMD3(repeating:2*t))
                        if abs(envelope.subtracting(original, isCancelled: stop).signedVolume) < 0.0001, !stop() { return candidate }
                    } else {
                        let overlap = original.intersection(feature, isCancelled: stop).signedVolume
                        let fraction = overlap / feature.signedVolume
                        guard fraction > 0.01, fraction < 0.9, !stop() else { continue }
                        if settings.kind == .mount {
                            let bore = boreClearance(candidate, inset: 0.0001)
                            let boreWorld = placed(bore, settings: candidate, minimum: source.minimum)
                            if abs(original.intersection(boreWorld, isCancelled: stop).signedVolume) > 0.0001 { continue }
                        }
                        let score = abs(fraction-0.2)
                        if best == nil || score < best!.1 { best = (candidate, score) }
                    }
                }
            }
        }
        guard !cancelled(), let best else { throw StudioError("No starting position was found in the bounded search. Set the position manually and preview the change.") }
        return best.0
    }

    /// Measures the wall through the region centre and returns a slab that brings it to whole extrusion lines.
    private static func matchedWallSlab(_ source: STLMesh, settings: ReinforcementSettings) throws -> (slab: Mesh, expectedVolume: Double) {
        let s = settings.size, w = settings.lineWidth
        let centre = world(s / 2, settings: settings, minimum: source.minimum)
        let direction = settings.rotate(SIMD3(0, 1, 0))
        guard containsMaterial(centre, in: source),
              let ahead = distanceToSurface(from: centre, along: direction, in: source),
              let behind = distanceToSurface(from: centre, along: -direction, in: source) else {
            throw StudioError("Place the region centre inside the wall you want to match.")
        }
        let measured = ahead + behind
        guard measured <= 6 * w else { throw StudioError(String(format: "This wall measures %.2f mm, more than six line widths; infill already fills its centre.", measured)) }
        let target = (measured / w - 0.001).rounded(.up) * w
        let extra = target - measured
        guard extra >= 0.02 else { throw StudioError(String(format: "This wall already measures %.2f mm, a whole number of %.2f mm lines.", measured, w)) }
        let overlap: Float = 0.05
        let slab = box(SIMD3(0, s.y/2 + ahead - overlap, 0), SIMD3(s.x, extra + overlap, s.z))
        return (slab, Double(extra * s.x * s.z))
    }

    /// `solid`, when given, is the exact solid that `source` was exported from by an earlier preview.
    /// Seconds a single preview may take before it stops. Auto-improve treats a preview that ran this long as timed out.
    static let previewTimeLimit: TimeInterval = 20

    static func preview(_ source: STLMesh, solid: Mesh? = nil, settings: ReinforcementSettings, cancelled: @escaping @Sendable () -> Bool = { false }) throws -> ReinforcementPreview {
        let deadline = Date().addingTimeInterval(previewTimeLimit)
        let stop: @Sendable () -> Bool = { cancelled() || Date() > deadline }
        func check() throws { if stop() { throw StudioError("Preview stopped. Try a simpler mesh or a smaller region.") } }
        guard !settings.kind.isWithdrawn else { throw StudioError(reinforcementClosedVoidWithdrawal) }
        if settings.kind == .internalWalls { return try internalWallsPreview(source, settings: settings, cancelled: cancelled) }
        let original = try solid ?? source.reinforcementSolid()
        var local = try tool(settings)
        var expectedAddition: Double?
        if settings.kind == .thicken {
            let matched = try matchedWallSlab(source, settings: settings)
            local = matched.slab; expectedAddition = matched.expectedVolume
        }
        func inWorld(_ mesh: Mesh) -> Mesh { placed(mesh, settings: settings, minimum: source.minimum) }
        let feature = inWorld(local)
        let extent = source.maximum-source.minimum
        guard point(feature.bounds.min).x >= source.minimum.x, point(feature.bounds.min).y >= source.minimum.y,
              point(feature.bounds.min).z >= source.minimum.z, point(feature.bounds.max).x <= source.maximum.x,
              point(feature.bounds.max).y <= source.maximum.y, point(feature.bounds.max).z <= source.maximum.z else {
            throw StudioError("Move or resize the region to stay inside the model’s overall dimensions.")
        }
        try check()
        guard settings.protectedRegions.count <= 8 else { throw StudioError("Use up to eight keep-clear regions.") }
        let masks = try settings.protectedRegions.map { region -> Mesh in
            guard [region.offset.x,region.offset.y,region.offset.z,region.size.x,region.size.y,region.size.z].allSatisfy({ $0.isFinite }), region.size.min() > 0 else {
                throw StudioError("Keep-clear regions need finite positions and positive dimensions.")
            }
            return box(source.minimum+region.offset, region.size)
        }
        if settings.kind == .split {
            return try splitPreview(source, original: original, settings: settings, pins: feature, masks: masks, stop: stop)
        }
        let s = settings.size, t = settings.thickness
        var result: Mesh
        var conservedOverlap: Double?
        // What is cut away; the ring gap's cut runs on below the bed face so it opens through it.
        var cut = feature
        if settings.kind.removesMaterial {
            switch settings.kind {
            case .cells, .shell:
                // A fully solid envelope proves skin clearance from existing holes and cavities, not merely from the bounding box.
                let envelope = box(point(feature.bounds.min) - SIMD3(repeating: t), point(feature.bounds.size) + SIMD3(repeating: 2*t))
                try requireSolid(envelope, in: original, settings.kind == .cells
                    ? "Place the cell region inside solid material with the chosen thickness of material around it. Existing cavities and exterior surfaces stay clear."
                    : "Place the shell region inside solid material with the chosen cover around it, so the gap stays closed.", stop)
            case .holeRing:
                // A ring closed inside the part would be a separate body on Slant's bill, so it starts at the bed face.
                guard settings.offset.z == 0 else {
                    throw StudioError("Set position Z to 0, so the ring gap starts at the bed face and opens through it. A gap closed inside the part prints as a separate body, which Slant charges for.")
                }
                let radius = clearanceRadius(settings.boreDiameter)
                try requireClear(inWorld(boreClearance(settings, inset: 0.0001)), in: original, "Align the region with an existing clear vertical bore of this diameter.", stop)
                let outer = radius + t + settings.gapWidth + t
                try requireSolid(inWorld(annulus(inner: radius + 0.02, outer: outer, z0: 0.001, z1: s.z + t, center: SIMD2(s.x/2, s.y/2))), in: original,
                                 "Leave solid material around the bore from the bed face up, for the gap and the chosen thickness of cover above it. A larger existing bore than nominated, or a bore that doesn’t reach the bed face, also fails this check.", stop)
                let inner = radius + t
                cut = inWorld(annulus(inner: inner, outer: inner + settings.gapWidth, z0: -1, z1: s.z, center: SIMD2(s.x/2, s.y/2)))
            case .teardrop:
                let r = settings.boreDiameter / 2
                try requireClear(inWorld(cylinderX(radius: r * 0.95, length: s.x, center: SIMD2(s.y/2, s.z/2))), in: original,
                                 "Align the region with an existing horizontal hole of this diameter running along local X.", stop)
                let apex = s.z/2 + r * Float(2).squareRoot()
                try requireSolid(inWorld(box(SIMD3(0, s.y/2 - 0.5, apex), SIMD3(s.x, 1, t))), in: original,
                                 "Leave the chosen thickness of material above the teardrop point.", stop)
            case .bridge:
                let outer = min(s.x, s.y), d = settings.boreDiameter, h = settings.layerHeight
                let centre = SIMD2(s.x/2, s.y/2)
                try requireClear(inWorld(cylinder(radius: d/2 * 0.95, height: 2*h + 0.5, center: centre)), in: original,
                                 "Align the region centre with an existing through-hole of this diameter above the counterbore.", stop)
                try requireClear(inWorld(cylinder(radius: outer/2 * 0.95, height: 0.5, center: centre).translated(by: Vector(0, 0, -0.52))), in: original,
                                 "Set position Z at the counterbore ceiling, with the open counterbore directly below.", stop)
                // Sampled rather than Boolean-tested: a thin ring at the ceiling plane is near-coplanar with it.
                let inner = d/2 * Float(2).squareRoot() + 0.05, ring = outer/2 * 0.95
                for z in [h/2, 1.5*h] {
                    for radius in [inner, (inner+ring)/2, ring] {
                        for i in 0..<48 {
                            let angle = (Float(i)+0.5) * 2 * .pi / 48
                            let local = SIMD3(centre.x + radius*cos(angle), centre.y + radius*sin(angle), z)
                            guard containsMaterial(world(local, settings: settings, minimum: source.minimum), in: source) else {
                                throw StudioError("The counterbore ceiling must be solid around the through-hole for both bridging layers.")
                            }
                        }
                        try check()
                    }
                }
            default: break
            }
            try check()
            if settings.kind == .bridge {
                // One layer step at a time, re-read from STL between them: cutting both at once leaves
                // slivers along the through-hole wall that stitching cannot close without changing volume.
                var stage = original
                for step in try bridgeSteps(settings) {
                    stage = try exported(stage.subtracting(inWorld(step), isCancelled: stop), original: original, stop: stop).0
                }
                result = stage
            } else {
                conservedOverlap = original.intersection(cut, isCancelled: stop).signedVolume
                result = original.subtracting(cut, isCancelled: stop)
            }
        } else {
            if settings.kind == .mount {
                // Inscribed polygon expanded so the requested circular bore stays entirely clear.
                try requireClear(inWorld(boreClearance(settings, inset: 0.0001)), in: original, "Align the collar with an existing clear bore. This operation never cuts a new hole.", stop)
                try check()
                // Sample the annular seat with a winding-number test. This avoids fragile
                // near-coplanar Boolean slivers when reading a circular bore from Float STL.
                let inner = clearanceRadius(settings.boreDiameter) + 0.02
                let outer = min(s.x, s.y)/2*cos(.pi/48) - 0.01
                var seated = false
                for z in [Float(0.025), s.z - 0.025] {
                    var complete = true
                    for radius in [inner, (inner+outer)/2, outer] {
                        for i in 0..<48 {
                            let angle = (Float(i)+0.5)*2 * .pi/48
                            let localPoint = SIMD3(s.x/2+radius*cos(angle), s.y/2+radius*sin(angle), z)
                            if !containsMaterial(world(localPoint, settings: settings, minimum: source.minimum), in: source) { complete = false; break }
                        }
                        if !complete { break }
                        try check()
                    }
                    if complete { seated = true; break }
                }
                guard seated else { throw StudioError("Position a collar end in a mounting surface around the bore. The sampled seat must surround the nominated clearance; use keep-clear regions for other fastener clearances.") }
            }
            let overlap = original.intersection(feature, isCancelled: stop)
            try check()
            guard overlap.signedVolume > 0.01 else { throw StudioError("Move the reinforcement slightly into the surfaces it should join. It must overlap existing material, not float or merely touch.") }
            conservedOverlap = overlap.signedVolume
            result = original.union(feature, isCancelled: stop)
        }
        try check()
        var exportedResult: (Mesh, STLMesh)
        do {
            exportedResult = try exported(result, original: original, stop: stop)
        } catch {
            guard !settings.kind.removesMaterial, !stop() else { throw error }
            // Euclid's result depends on operand order; a union that fails to close often succeeds the other way round.
            result = feature.union(original, isCancelled: stop)
            exportedResult = try exported(result, original: original, stop: stop)
        }
        let (stitched, output) = exportedResult
        let added = max(0, result.signedVolume-original.signedVolume)
        let removed = max(0, original.signedVolume-result.signedVolume)
        guard max(added, removed) > 0.01 else { throw StudioError("This region already contains the proposed material. Choose unused space or a different treatment.") }
        if let expectedAddition, added < expectedAddition * 0.9 {
            throw StudioError("The space beside this wall is not clear for the added thickness. Turn the region to thicken the other side.")
        }
        // Protect the full keep-clear volumes, including existing surfaces within them.
        for mask in masks {
            let before = original.intersection(mask, isCancelled: stop)
            let after = result.intersection(mask, isCancelled: stop)
            let difference = after.subtracting(before, isCancelled: stop).signedVolume + before.subtracting(after, isCancelled: stop).signedVolume
            try check()
            guard abs(difference) < 0.0001 else { throw StudioError("The proposed change enters a keep-clear region. Move or resize the reinforcement.") }
        }
        // A failed Boolean can still produce a closed mesh. Check volume conservation against the overlap
        // (union: original + feature − overlap; cut: original − overlap) without near-coplanar comparisons.
        if let overlap = conservedOverlap {
            let expected = settings.kind.removesMaterial ? original.signedVolume - overlap : original.signedVolume + feature.signedVolume - overlap
            guard abs(stitched.signedVolume - expected) < max(0.01, expected * 0.00001) else {
                throw StudioError("This change did not combine cleanly with the existing geometry. Adjust its placement or prepare it in CAD.")
            }
        }
        guard simd_length(output.minimum-source.minimum) < 0.0001, simd_length(output.maximum-source.maximum) < 0.0001,
              try bodyCount(output) <= bodyCount(original) else {
            throw StudioError("The proposed copy cannot preserve the envelope and connected bodies. Adjust its placement.")
        }
        let shells = try shellCounts(source, [output], stop)
        // Section through the feature, along world X. Display only; never used for saving.
        let cutX = Float(feature.bounds.center.x)
        let sectionBox = box(source.minimum-SIMD3(repeating: 1), SIMD3(cutX-source.minimum.x+1,extent.y+2,extent.z+2))
        let beforeSection = original.intersection(sectionBox, isCancelled: stop)
        let afterSection = stitched.intersection(sectionBox, isCancelled: stop)
        try check()
        return ReinforcementPreview(mesh: output, originalSection: try? stl(beforeSection), proposedSection: try? stl(afterSection), addedVolume: added, removedVolume: removed,
                                    shellsBefore: shells.before, shellsAfter: shells.after, solid: stitched)
    }

    /// Separate shells in the source and the most in any output, by the mesh check's vertex connectivity. A closed void
    /// is its own shell, which the positive-volume body count above can't see; Slant bills it as an extra body.
    static func shellCounts(_ source: STLMesh, _ outputs: [STLMesh], _ stop: () -> Bool) throws -> (before: Int, after: Int) {
        func shells(_ mesh: STLMesh) throws -> Int {
            guard let report = analyzeMeshHealth(mesh, isCancelled: stop) else { throw StudioError("Preview stopped. Try a simpler mesh or a smaller region.") }
            return report.shells
        }
        let before = try shells(source)
        let after = try outputs.map(shells).max() ?? 0
        if let problem = reinforcementShellGrowthProblem(before: before, after: after) { throw StudioError(problem) }
        return (before, after)
    }

    /// Internal walls over the whole part, through `internalWallsCopy`. Keep-clear regions are left uncut.
    private static func internalWallsPreview(_ source: STLMesh, settings: ReinforcementSettings, cancelled: @escaping @Sendable () -> Bool) throws -> ReinforcementPreview {
        guard settings.protectedRegions.count <= 8 else { throw StudioError("Use up to eight keep-clear regions.") }
        var options = InternalWallsOptions()
        options.keepClear = settings.protectedRegions.map {
            InternalWallsKeepClearBox(low: source.minimum + $0.offset, high: source.minimum + $0.offset + $0.size)
        }
        let deadline = Date().addingTimeInterval(60)
        let result: InternalWallsResult
        do {
            result = try internalWallsCopy(of: source, options: options, isCancelled: { cancelled() || Date() > deadline })
        } catch InternalWallsError.stopped {
            throw StudioError("Preview stopped. Try a simpler mesh.")
        }
        guard let mesh = result.mesh else { throw StudioError(result.skipped?.message ?? InternalWallsSkipReason.resultFailedChecks.message) }
        if let problem = reinforcementShellGrowthProblem(before: result.shellsBefore, after: result.shellsAfter) { throw StudioError(problem) }
        // A cutaway across the slots at the middle of the part. Display only, and only where Euclid can read the mesh.
        var sections: (STLMesh, STLMesh)?
        if source.triangleCount <= 20_000, mesh.triangleCount <= 20_000, let original = try? source.reinforcementSolid(), let copy = try? mesh.reinforcementSolid() {
            var size = source.maximum - source.minimum + SIMD3(repeating: 2)
            let axis = result.axis == .y ? 1 : 0
            size[axis] = (source.maximum[axis] - source.minimum[axis]) / 2 + 1
            let keep = box(source.minimum - SIMD3(repeating: 1), size)
            let stop: @Sendable () -> Bool = { cancelled() || Date() > deadline }
            if let before = try? stl(original.intersection(keep, isCancelled: stop)), let after = try? stl(copy.intersection(keep, isCancelled: stop)), !stop() {
                sections = (before, after)
            }
        }
        return ReinforcementPreview(mesh: mesh, originalSection: sections?.0, proposedSection: sections?.1, addedVolume: 0,
                                    removedVolume: result.removedVolumeMM3, shellsBefore: result.shellsBefore, shellsAfter: result.shellsAfter,
                                    detail: internalWallsSummary(result))
    }

    private static func bodyCount(_ mesh: Mesh) -> Int { mesh.submeshes.filter { $0.signedVolume > 0.001 }.count }
    private static func bodyCount(_ mesh: STLMesh) throws -> Int { bodyCount(try mesh.reinforcementSolid()) }

    /// Stitches CSG edge subdivisions, then validates the exported STL rather than trusting the preview alone.
    private static func exported(_ result: Mesh, original: Mesh, stop: @escaping @Sendable () -> Bool) throws -> (Mesh, STLMesh) {
        let stitched = result.makeWatertight(isCancelled: stop)
        if stop() { throw StudioError("Preview stopped. Try a simpler mesh or a smaller region.") }
        guard stitched.isWatertight, abs(stitched.signedVolume-result.signedVolume) < max(0.001, abs(result.signedVolume)*0.000001) else {
            throw StudioError("This intersection needs a CAD edit to produce a closed solid.")
        }
        let output = try stl(stitched)
        let exported = try output.reinforcementSolid()
        let tolerance = max(0.001, abs(stitched.signedVolume)*0.00001)
        guard abs(exported.signedVolume-stitched.signedVolume) < tolerance else { throw StudioError("This geometry cannot be exported accurately at STL precision.") }
        return (stitched, output)
    }

    /// Cuts on the region's local mid-height plane and drills matching blind pin holes into both halves.
    private static func splitPreview(_ source: STLMesh, original: Mesh, settings: ReinforcementSettings, pins: Mesh, masks: [Mesh], stop: @escaping @Sendable () -> Bool) throws -> ReinforcementPreview {
        let s = settings.size, t = settings.thickness
        func inWorld(_ mesh: Mesh) -> Mesh { placed(mesh, settings: settings, minimum: source.minimum) }
        let walls = pinCentres(s).map { cylinder(radius: settings.boreDiameter/2 + t, height: s.z, center: $0) }
        try requireSolid(inWorld(walls[0].union(walls[1])), in: original,
                         "Place both pins inside solid material across the cut, with the chosen wall around each pin hole.", stop)
        for mask in masks {
            guard abs(mask.intersection(pins, isCancelled: stop).signedVolume) < 0.0001 else { throw StudioError("A pin hole enters a keep-clear region. Move or resize the region.") }
        }
        let reach = (source.maximum - source.minimum).max() * 2 + s.max() + 10
        let below = inWorld(box(SIMD3(-reach, -reach, -reach), SIMD3(2*reach, 2*reach, reach + s.z/2)))
        let lower = original.intersection(below, isCancelled: stop).subtracting(pins, isCancelled: stop)
        let upper = original.subtracting(below, isCancelled: stop).subtracting(pins, isCancelled: stop)
        if stop() { throw StudioError("Preview stopped. Try a simpler mesh or a smaller region.") }
        guard lower.signedVolume > 1, upper.signedVolume > 1 else { throw StudioError("Move the cut so it passes through the part, leaving material on both sides.") }
        let (_, first) = try exported(lower, original: original, stop: stop)
        let (_, second) = try exported(upper, original: original, stop: stop)
        guard try bodyCount(first) <= bodyCount(original), try bodyCount(second) <= bodyCount(original) else {
            throw StudioError("This cut separates the part into more than two pieces. Move the cut plane.")
        }
        let shells = try shellCounts(source, [first, second], stop)
        let removed = max(0, original.signedVolume - lower.signedVolume - upper.signedVolume)
        // Display only: separate the halves along the cut normal.
        let gap = settings.rotate(SIMD3(0, 0, 1)) * ((source.maximum - source.minimum).max() * 0.25 + 2)
        var shown = first.vertices
        for i in stride(from: 0, to: second.vertices.count, by: 3) {
            shown += [second.vertices[i] + gap.x, second.vertices[i+1] + gap.y, second.vertices[i+2] + gap.z]
        }
        let exploded = try STLMesh.parse(STLMesh(vertices: shown, minimum: .zero, maximum: .one).binarySTL())
        return ReinforcementPreview(mesh: first, originalSection: nil, proposedSection: nil, addedVolume: 0, removedVolume: removed,
                                    shellsBefore: shells.before, shellsAfter: shells.after, secondPart: second, exploded: exploded)
    }
}
