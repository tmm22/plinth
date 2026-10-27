import Foundation
import simd

// Teardrop holes: horizontal round holes reshaped so their tops print without drooping.
//
// The shape is a truncated teardrop (as BOSL2's `teardrop` with `cap_h` at the radius): two 45° faces from vertical,
// tangent to the hole, up to a flat top on the hole's own top. The hole's lowest point and height stay exactly as they
// were; only its shoulders gain a little clearance. Holes are found, and changed, directly in the mesh rather than by
// Euclid: the change is confined to the hole's wall and its two end faces, so a direct construction keeps every other
// triangle (and the hole's bottom and top vertices) byte for byte, has no 20,000-triangle limit and no tangent or
// coplanar Boolean slivers, needs no time limit, and gives the same bytes on every run. The price is that only plain
// straight tubes are changed: holes that step, taper, cross another feature or end on a curved surface are reported and
// left alone. Iteration is in index order throughout; dictionaries are used for lookups only.

// MARK: - Limits

/// Round holes from this size up get a teardrop roof; smaller ones bridge their tops cleanly as they are.
let teardropMinimumDiameterMM: Float = 3
/// Beyond this a hole is closer to an arch, and the change to the part too large to make without the seller's CAD.
let teardropMaximumDiameterMM: Float = 30
/// Material that must be left above the new flat top and beside the new 45° shoulders.
let teardropMinimumWallMM: Float = 1
/// How far a hole's axis may tilt from horizontal.
let teardropMaximumTiltDegrees: Float = 5
/// Holes examined in one model; any more are reported as not checked.
let teardropMaximumHoles = 64
/// Material is measured this far past the new shape; thicker walls are reported as this much.
let teardropWallReachMM: Float = 10
/// The library's own limit: the direct construction has no Euclid limit of its own.
let teardropMaximumTriangles = STLMesh.maximumTriangles

// MARK: - Results

enum TeardropSkipReason: String, Codable, Sendable, CaseIterable {
    case tooSmall, tooLarge, notRound, tilted, notPlainTube, endNotFlat, thinRoof, thinWall, crowded, couldNotRebuild, notChecked
    var message: String {
        switch self {
        case .tooSmall: return "Under \(Int(teardropMinimumDiameterMM)) mm across: a hole this small prints its top cleanly as it is."
        case .tooLarge: return "Over \(Int(teardropMaximumDiameterMM)) mm across: a teardrop roof would change too much of the part. Reshape it in your CAD tool if its top sags."
        case .notRound: return "Not round: a slot, an oval or a hole that’s already shaped."
        case .tilted: return "Its axis runs more than \(Int(teardropMaximumTiltDegrees))° off horizontal."
        case .notPlainTube: return "Its wall isn’t a plain straight tube: it steps, tapers or meets another feature."
        case .endNotFlat: return "Its far end isn’t one flat face: it has a drill-point floor, or runs into another hole or pocket."
        case .thinRoof: return "Less than \(Int(teardropMinimumWallMM)) mm of material would be left above its new top."
        case .thinWall: return "Less than \(Int(teardropMinimumWallMM)) mm of material would be left beside its new 45° shoulders."
        case .crowded: return "Another feature meets the hole or sits too close to its top."
        case .couldNotRebuild: return "Studio couldn’t rebuild the faces round it cleanly."
        case .notChecked: return "Not checked: Studio checks up to \(teardropMaximumHoles) holes in one model."
        }
    }
}

/// Why no teardrop copy was made.
enum TeardropCopyProblem: String, Equatable, Sendable, CaseIterable {
    case notClosedSolid, tooManyTriangles, noHolesChosen, resultFailedChecks
    var message: String {
        switch self {
        case .notClosedSolid: return "Teardrop holes need a closed, consistently oriented mesh. Use Repair and simplify first."
        case .tooManyTriangles: return "This model has more than \(teardropMaximumTriangleText) triangles, the most Studio reshapes holes in."
        case .noHolesChosen: return "None of the chosen holes could take a teardrop roof."
        case .resultFailedChecks: return "The copy didn’t pass Studio’s mesh check, so no copy was made."
        }
    }
}

private let teardropMaximumTriangleText = STLMesh.maximumTriangles.formatted()

enum TeardropError: LocalizedError, Equatable {
    case stopped
    var errorDescription: String? { "Stopped. Nothing was saved." }
}

/// Identifies a hole across runs on the same placed mesh: its centre (0.01 mm), heading (0.1°) and size (0.01 mm).
struct TeardropHoleKey: Codable, Hashable, Sendable {
    let centre: SIMD3<Int32>
    let heading: Int32
    let diameter: Int32
}

/// A horizontal round hole Studio found. `skipped` says why it can't take a teardrop roof; nil when it can.
struct TeardropCandidate: Equatable, Sendable, Identifiable {
    var id: TeardropHoleKey { key }
    let key: TeardropHoleKey
    /// The hole's axis at mid-length, in the mesh's own coordinates (mm).
    let centre: SIMD3<Float>
    /// Unit axis, within 5° of horizontal, pointing towards +X or +Y.
    let axis: SIMD3<Float>
    let radiusMM: Float
    /// The ends' positions along `axis` (dot products), `startMM` < `endMM`.
    let startMM: Float
    let endMM: Float
    /// Open at both ends (including into a cavity), or blind with a flat floor.
    let through: Bool
    /// Material over the new flat top, at most `teardropWallReachMM`; nil when it wasn't measured.
    let wallAboveMM: Float?
    let skipped: TeardropSkipReason?
    /// The box round the material the change removes (eligible holes only; zero-size otherwise).
    let changeLow: SIMD3<Float>
    let changeHigh: SIMD3<Float>
    var eligible: Bool { skipped == nil }
    var diameterMM: Float { 2 * radiusMM }
    var lengthMM: Float { endMM - startMM }
}

/// One reshaped hole, as saved with the copy.
struct TeardropHoleRecord: Codable, Equatable, Sendable {
    var diameterMM: Double
    var lengthMM: Double
    var through: Bool
    /// "X", "Y", or the heading in degrees from X.
    var axis: String
    /// Mid-length centre in the copy's coordinates (mm).
    var centreMM: [Double]
    var wallAboveMM: Double?
}

struct TeardropSkipRecord: Codable, Equatable, Sendable {
    var reason: TeardropSkipReason
    var diameterMM: Double?
}

/// What Teardrop holes did to a copy. Decoding is lenient: a damaged or unknown entry is dropped, never the record.
struct TeardropHolesRecord: Codable, Equatable, Sendable {
    var holes: [TeardropHoleRecord]
    var skipped: [TeardropSkipRecord]
    var removedVolumeMM3: Double
    var count: Int { holes.count }
    var diametersMM: [Double] { holes.map(\.diameterMM) }

    init(holes: [TeardropHoleRecord], skipped: [TeardropSkipRecord], removedVolumeMM3: Double) {
        self.holes = holes; self.skipped = skipped; self.removedVolumeMM3 = removedVolumeMM3
    }
    private enum CodingKeys: String, CodingKey { case holes, skipped, removedVolumeMM3 }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        holes = (try? c?.decode([TeardropLenient<TeardropHoleRecord>].self, forKey: .holes))?.compactMap(\.value) ?? []
        skipped = (try? c?.decode([TeardropLenient<TeardropSkipRecord>].self, forKey: .skipped))?.compactMap(\.value) ?? []
        removedVolumeMM3 = (try? c?.decode(Double.self, forKey: .removedVolumeMM3)) ?? 0
    }
}

/// Decodes one array element, or nil (dropped) when it can't be read.
private struct TeardropLenient<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

struct TeardropHolesResult: Sendable {
    /// The copy, or nil when nothing was changed or a check stopped it.
    let mesh: STLMesh?
    let data: Data?
    let record: TeardropHolesRecord
    let shellsBefore: Int
    let shellsAfter: Int
    let problem: TeardropCopyProblem?
    var applied: Bool { mesh != nil }
}

// MARK: - Wording

/// "along X", "along Y" or "at 30° to X".
func teardropAxisLabel(_ axis: SIMD3<Float>) -> String {
    if abs(axis.y) < 1e-4, abs(axis.z) < 0.0873 { return "along X" }
    if abs(axis.x) < 1e-4, abs(axis.z) < 0.0873 { return "along Y" }
    return String(format: "at %.0f° to X", atan2(axis.y, axis.x) * 180 / .pi)
}

private func teardropAxisName(_ axis: SIMD3<Float>) -> String {
    switch teardropAxisLabel(axis) {
    case "along X": return "X"
    case "along Y": return "Y"
    default: return String(format: "%.0f°", atan2(axis.y, axis.x) * 180 / .pi)
    }
}

/// One line per hole for a list, such as "⌀5.0 mm through hole along X · centre Y 10.0, Z 8.0 · 20.0 mm long ·
/// 3.2 mm of material above". Positions are from `minimum`, as Reinforce measures them.
func teardropCandidateLabel(_ hole: TeardropCandidate, minimum: SIMD3<Float>) -> String {
    let p = hole.centre - minimum
    let centre: String
    switch teardropAxisLabel(hole.axis) {
    case "along X": centre = String(format: "centre Y %.1f, Z %.1f", p.y, p.z)
    case "along Y": centre = String(format: "centre X %.1f, Z %.1f", p.x, p.z)
    default: centre = String(format: "centre X %.1f, Y %.1f, Z %.1f", p.x, p.y, p.z)
    }
    var text = String(format: "⌀%.1f mm %@ hole %@ · %@ · %.1f mm long", hole.diameterMM, hole.through ? "through" : "blind",
                      teardropAxisLabel(hole.axis), centre, hole.lengthMM)
    if hole.eligible, let wall = hole.wallAboveMM {
        text += wall >= teardropWallReachMM ? String(format: " · %.0f mm or more of material above", teardropWallReachMM)
                                            : String(format: " · %.1f mm of material above", wall)
    }
    return text
}

/// The applied line, such as "Teardrop roofs on 2 holes (⌀5.0 and 6.0 mm): …".
func teardropHolesSummary(_ record: TeardropHolesRecord) -> String {
    guard record.count > 0 else { return "No holes were reshaped." }
    let sizes = record.diametersMM.map { String(format: "%.1f", $0) }
    let list = sizes.count == 1 ? sizes[0] : sizes.dropLast().joined(separator: ", ") + " and " + sizes.last!
    return "Teardrop roofs on \(record.count) \(record.count == 1 ? "hole" : "holes") (⌀\(list) mm): 45° shoulders up to a flat top at the hole’s own top, so \(record.count == 1 ? "its" : "each hole’s") bottom and height are unchanged and only the shoulders widen slightly."
}

/// A skipped hole's line, such as "⌀2.0 mm hole: Under 3 mm across: …".
func teardropSkipNote(_ skip: TeardropSkipRecord) -> String {
    if let d = skip.diameterMM { return String(format: "⌀%.1f mm hole: ", d) + skip.reason.message }
    return "A hole: " + skip.reason.message
}

/// Auto-improve's note for holes that could take a teardrop roof. Teardrops are never added automatically: they
/// change a hole's shoulders, which may be a fitting surface.
func teardropReviewNote(eligibleCount: Int) -> String? {
    guard eligibleCount > 0 else { return nil }
    let holes = "\(eligibleCount) horizontal round hole\(eligibleCount == 1 ? "" : "s")"
    return "\(holes) found that could take a teardrop roof, so \(eligibleCount == 1 ? "its top prints" : "their tops print") without drooping. Not added, because a teardrop widens a hole’s shoulders slightly. To add one, open Reinforce this part, choose Teardrop hole roof, then Find Horizontal Holes."
}

// MARK: - Detection

/// Horizontal round holes in `mesh` as placed (axis within 5° of horizontal, any heading), eligible or with the reason
/// they're left alone. Pure and deterministic; vertical holes, pins and non-round openings aren't listed.
func teardropCandidates(in mesh: STLMesh, isCancelled: () -> Bool = { false }) throws -> [TeardropCandidate] {
    guard mesh.triangleCount > 0, mesh.triangleCount <= teardropMaximumTriangles else { return [] }
    guard let topology = TeardropTopology(mesh) else { return [] }
    return try topology.detect(isCancelled: isCancelled).map(\.candidate)
}

/// A copy with teardrop roofs on the chosen holes (matched by key against a fresh detection on `mesh`, so stale
/// candidates are ignored) and only those. The copy must pass the mesh check, keep its shells and bounds, and remove
/// the volume the new shapes predict. Throws `TeardropError.stopped` when cancelled; nothing partial is returned.
func teardropHolesCopy(of mesh: STLMesh, candidates: [TeardropCandidate], isCancelled: () -> Bool = { false }) throws -> TeardropHolesResult {
    try teardropHolesCopy(of: mesh, keys: Set(candidates.filter(\.eligible).map(\.key)), isCancelled: isCancelled)
}

/// Closed, consistently oriented and outward-facing. Zero-area slivers (common in Euclid's and some CAD exports) are
/// allowed in the input, but a copy never has more than its source, and a sound source must give a sound copy.
func teardropInputUsable(_ report: MeshHealthReport) -> Bool {
    report.triangleCount > 0 && report.isClosed && report.isConsistentlyOriented && !report.isInsideOut
}

/// The same, for every eligible hole when `keys` is nil. For the print-ready copy's Add Teardrop Holes: pass the placed
/// mesh, then save the returned mesh with its record.
func teardropHolesCopy(of mesh: STLMesh, keys: Set<TeardropHoleKey>? = nil, isCancelled: () -> Bool = { false }) throws -> TeardropHolesResult {
    func check() throws { if isCancelled() { throw TeardropError.stopped } }
    func none(_ problem: TeardropCopyProblem, skipped: [TeardropSkipRecord] = [], shells: Int = 0) -> TeardropHolesResult {
        TeardropHolesResult(mesh: nil, data: nil, record: TeardropHolesRecord(holes: [], skipped: skipped, removedVolumeMM3: 0),
                            shellsBefore: shells, shellsAfter: shells, problem: problem)
    }
    guard mesh.triangleCount <= teardropMaximumTriangles else { return none(.tooManyTriangles) }
    guard let before = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw TeardropError.stopped }
    guard teardropInputUsable(before), let topology = TeardropTopology(mesh) else { return none(.notClosedSolid, shells: before.shells) }
    let found = try topology.detect(isCancelled: isCancelled)
    try check()
    let chosen = found.filter { $0.plan != nil && (keys?.contains($0.candidate.key) ?? true) }
    var skipped = found.filter { $0.plan == nil && (keys?.contains($0.candidate.key) ?? true) }.map {
        TeardropSkipRecord(reason: $0.candidate.skipped ?? .couldNotRebuild, diameterMM: Double($0.candidate.diameterMM))
    }
    var plans = chosen
    // A face that can't be rebuilt drops the holes on it, and the rest are tried again: at most once per hole.
    while !plans.isEmpty {
        try check()
        switch topology.build(plans.map { $0.plan! }) {
        case .failed(let holes):
            let failed = Set(holes)
            for index in plans.indices where failed.contains(index) {
                skipped.append(TeardropSkipRecord(reason: .couldNotRebuild, diameterMM: Double(plans[index].candidate.diameterMM)))
            }
            plans = plans.indices.filter { !failed.contains($0) }.map { plans[$0] }
        case .built(let vertices):
            try check()
            guard let copy = try? STLMesh.parse(STLMesh(vertices: vertices, minimum: .zero, maximum: .one).binarySTL()) else {
                return none(.resultFailedChecks, skipped: skipped, shells: before.shells)
            }
            guard let after = analyzeMeshHealth(copy, isCancelled: isCancelled) else { throw TeardropError.stopped }
            let removed = before.signedVolume - after.signedVolume
            let expected = plans.reduce(0.0) { $0 + $1.plan!.expectedVolume }
            let source = meshCoordinateBounds(mesh.vertices), result = meshCoordinateBounds(copy.vertices)
            guard teardropInputUsable(after), after.degenerateTriangles <= before.degenerateTriangles, !meshToolMadeWorse(before: before, after: after), after.shells == before.shells,
                  source.low == result.low, source.high == result.high,
                  abs(removed - expected) <= max(0.01, expected * 0.01) else {
                return TeardropHolesResult(mesh: nil, data: nil, record: TeardropHolesRecord(holes: [], skipped: skipped, removedVolumeMM3: 0),
                                           shellsBefore: before.shells, shellsAfter: after.shells, problem: .resultFailedChecks)
            }
            let data = copy.binarySTL()
            guard let readBack = try? STLMesh.parse(data), readBack.triangleCount == copy.triangleCount else {
                return none(.resultFailedChecks, skipped: skipped, shells: before.shells)
            }
            let holes = plans.map { item -> TeardropHoleRecord in
                let c = item.candidate
                return TeardropHoleRecord(diameterMM: Double(c.diameterMM), lengthMM: Double(c.lengthMM), through: c.through,
                                          axis: teardropAxisName(c.axis), centreMM: [Double(c.centre.x), Double(c.centre.y), Double(c.centre.z)],
                                          wallAboveMM: c.wallAboveMM.map(Double.init))
            }
            return TeardropHolesResult(mesh: copy, data: data,
                                       record: TeardropHolesRecord(holes: holes, skipped: skipped, removedVolumeMM3: max(0, removed)),
                                       shellsBefore: before.shells, shellsAfter: after.shells, problem: nil)
        }
    }
    return none(.noHolesChosen, skipped: skipped, shells: before.shells)
}

// MARK: - Topology

/// How one hole is reshaped.
private struct TeardropPlan: Sendable {
    /// Face index and loop index (into that face's loops) at each end; the far end of a blind hole is its floor.
    let nearFace: Int, nearLoop: Int, farFace: Int, farLoop: Int
    /// Ring vertices to remove (welded ids), and the ring vertices either side of them at each end.
    let removed: [Int32]
    let rightNear: Int32, leftNear: Int32, rightFar: Int32, leftFar: Int32
    /// The rails either side of the removed ones, from the ring to the far end, with any vertices between.
    let rightRail: [Int32], leftRail: [Int32]
    /// New corners at the flat top's ends: right then left, near then far.
    let corners: [SIMD3<Float>]
    /// Wall triangles to drop (those touching a removed vertex).
    let droppedWall: [Int]
    /// A point on the axis, for orienting the new wall faces.
    let axisPoint: SIMD3<Double>
    let axis: SIMD3<Double>
    let expectedVolume: Double
}

private struct TeardropFound {
    let candidate: TeardropCandidate
    let plan: TeardropPlan?
}

private enum TeardropBuild {
    case built([Float])
    /// Indices (into the plans passed) of holes whose faces couldn't be rebuilt.
    case failed([Int])
}

private struct TeardropTopology {
    let points: [SIMD3<Float>]
    let triangles: [SIMD3<Int32>]
    /// Directed edge (a, b) → the triangle using it.
    let owner: [UInt64: Int32]
    let normals: [SIMD3<Double>]
    let faceOf: [Int32]
    let faces: [Face]
    /// Triangles round each vertex, as ranges into `incidentList`.
    let incidentStart: [Int32]
    let incidentList: [Int32]

    struct Face {
        let normal: SIMD3<Double>
        let triangles: [Int]
        /// Boundary loops following triangle winding, or nil when the boundary branches.
        let loops: [[Int32]]?
    }

    static func key(_ a: Int32, _ b: Int32) -> UInt64 { UInt64(UInt32(bitPattern: a)) << 32 | UInt64(UInt32(bitPattern: b)) }

    init?(_ mesh: STLMesh) {
        let v = mesh.vertices, count = mesh.triangleCount
        var index: [SIMD3<Float>: Int32] = [:]
        index.reserveCapacity(min(count * 3, 1 << 21))
        var points: [SIMD3<Float>] = []
        var triangles: [SIMD3<Int32>] = []
        triangles.reserveCapacity(count)
        for t in 0..<count {
            var ids = SIMD3<Int32>()
            for j in 0..<3 {
                // + 0 folds −0 into 0, so they weld.
                let p = SIMD3(v[t * 9 + j * 3] + 0, v[t * 9 + j * 3 + 1] + 0, v[t * 9 + j * 3 + 2] + 0)
                if let id = index[p] { ids[j] = id } else { ids[j] = Int32(points.count); index[p] = ids[j]; points.append(p) }
            }
            guard ids.x != ids.y, ids.y != ids.z, ids.z != ids.x else { return nil }
            triangles.append(ids)
        }
        var owner: [UInt64: Int32] = [:]
        owner.reserveCapacity(count * 3)
        for (t, ids) in triangles.enumerated() {
            for (a, b) in [(ids.x, ids.y), (ids.y, ids.z), (ids.z, ids.x)] {
                guard owner.updateValue(Int32(t), forKey: Self.key(a, b)) == nil else { return nil }
            }
        }
        for ids in triangles {
            for (a, b) in [(ids.x, ids.y), (ids.y, ids.z), (ids.z, ids.x)] where owner[Self.key(b, a)] == nil { return nil }
        }
        func p(_ i: Int32) -> SIMD3<Double> { SIMD3<Double>(points[Int(i)]) }
        let normals = triangles.map { t -> SIMD3<Double> in
            let c = simd_cross(p(t.y) - p(t.x), p(t.z) - p(t.x))
            let l = simd_length(c)
            return l > 0 ? c / l : .zero
        }
        let doubleAreas = triangles.map { t in simd_length(simd_cross(p(t.y) - p(t.x), p(t.z) - p(t.x))) }
        // Needle and zero-area triangles have no reliable normal of their own; they join a face by position alone.
        let needle = triangles.indices.map { t -> Bool in
            let ids = triangles[t]
            let longest = max(simd_distance_squared(p(ids.x), p(ids.y)), simd_distance_squared(p(ids.y), p(ids.z)), simd_distance_squared(p(ids.z), p(ids.x)))
            return doubleAreas[t] <= 1e-3 * longest
        }

        // Flat faces, grown from the largest triangles (ties by index) across edges onto triangles within 1e-4 mm of
        // the seed's plane.
        var faceOf = [Int32](repeating: -1, count: count)
        var faces: [Face] = []
        let order = (0..<count).sorted { doubleAreas[$0] != doubleAreas[$1] ? doubleAreas[$0] > doubleAreas[$1] : $0 < $1 }
        for seed in order where faceOf[seed] < 0 {
            let n = normals[seed]
            let w = simd_dot(n, p(triangles[seed].x))
            let id = Int32(faces.count)
            faceOf[seed] = id
            var members: [Int] = []
            var stack = [seed]
            while let t = stack.popLast() {
                members.append(t)
                let ids = triangles[t]
                for (a, b) in [(ids.x, ids.y), (ids.y, ids.z), (ids.z, ids.x)] {
                    guard let other = owner[Self.key(b, a)].map(Int.init), faceOf[other] < 0, needle[other] || simd_dot(normals[other], n) > 0.9 else { continue }
                    let o = triangles[other]
                    guard abs(simd_dot(n, p(o.x)) - w) <= 1e-4, abs(simd_dot(n, p(o.y)) - w) <= 1e-4, abs(simd_dot(n, p(o.z)) - w) <= 1e-4 else { continue }
                    faceOf[other] = id
                    stack.append(other)
                }
            }
            members.sort()
            faces.append(Face(normal: n, triangles: members, loops: nil))
        }
        // Boundary loops of each face.
        var next: [Int32: Int32] = [:]
        for f in faces.indices {
            next.removeAll(keepingCapacity: true)
            var starts: [Int32] = []
            var branches = false
            for t in faces[f].triangles {
                let ids = triangles[t]
                for (a, b) in [(ids.x, ids.y), (ids.y, ids.z), (ids.z, ids.x)] {
                    if let other = owner[Self.key(b, a)], faceOf[Int(other)] == Int32(f) { continue }
                    if next.updateValue(b, forKey: a) != nil { branches = true }
                    starts.append(a)
                }
            }
            var loops: [[Int32]]? = branches ? nil : []
            if !branches {
                var visited = Set<Int32>()
                for start in starts.sorted() where !visited.contains(start) {
                    var loop: [Int32] = []
                    var vertex = start
                    while !visited.contains(vertex) {
                        visited.insert(vertex)
                        loop.append(vertex)
                        guard let following = next[vertex] else { loops = nil; break }
                        vertex = following
                    }
                    guard loops != nil, vertex == start else { loops = nil; break }
                    loops!.append(loop)
                }
            }
            faces[f] = Face(normal: faces[f].normal, triangles: faces[f].triangles, loops: loops)
        }
        var incidentCount = [Int32](repeating: 0, count: points.count + 1)
        for ids in triangles { for i in [ids.x, ids.y, ids.z] { incidentCount[Int(i) + 1] += 1 } }
        for i in 0..<points.count { incidentCount[i + 1] += incidentCount[i] }
        var fill = incidentCount
        var list = [Int32](repeating: 0, count: count * 3)
        for (t, ids) in triangles.enumerated() {
            for i in [ids.x, ids.y, ids.z] { list[Int(fill[Int(i)])] = Int32(t); fill[Int(i)] += 1 }
        }
        self.points = points; self.triangles = triangles; self.owner = owner; self.normals = normals
        self.faceOf = faceOf; self.faces = faces; self.incidentStart = incidentCount; self.incidentList = list
    }

    func p(_ i: Int32) -> SIMD3<Double> { SIMD3<Double>(points[Int(i)]) }

    /// A 2D basis (e1, e2) of the plane with normal `n`, with e1 × e2 = n.
    static func basis(_ n: SIMD3<Double>) -> (SIMD3<Double>, SIMD3<Double>) {
        let helper: SIMD3<Double> = abs(n.x) <= abs(n.y) && abs(n.x) <= abs(n.z) ? SIMD3(1, 0, 0) : (abs(n.y) <= abs(n.z) ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
        let e1 = simd_normalize(simd_cross(helper, n))
        return (e1, simd_cross(n, e1))
    }

    static func area(_ q: [SIMD2<Double>]) -> Double {
        var sum = 0.0
        for i in q.indices { let a = q[i], b = q[(i + 1) % q.count]; sum += a.x * b.y - b.x * a.y }
        return sum / 2
    }

    // MARK: Finding holes

    func detect(isCancelled: () -> Bool) throws -> [TeardropFound] {
        var found: [TeardropFound] = []
        var consumed = Set<Int32>()
        var examined = 0
        for f in faces.indices {
            if f % 256 == 0, isCancelled() { throw TeardropError.stopped }
            guard let loops = faces[f].loops, loops.count > 1 else { continue }
            let n = faces[f].normal
            let (e1, e2) = Self.basis(n)
            for (l, loop) in loops.enumerated() where loop.count >= 12 && !consumed.contains(loop[0]) {
                // Holes are inner loops: clockwise about the face's outward normal.
                guard Self.area(loop.map { SIMD2(simd_dot(p($0), e1), simd_dot(p($0), e2)) }) < 0 else { continue }
                guard let result = examine(face: f, loopIndex: l, ring: loop) else { continue }
                if result.farRing.isEmpty == false, result.candidate.through { for v in result.farRing { consumed.insert(v) } }
                for v in loop { consumed.insert(v) }
                examined += 1
                if examined > teardropMaximumHoles {
                    found.append(TeardropFound(candidate: result.candidate.skipping(.notChecked), plan: nil))
                    continue
                }
                if isCancelled() { throw TeardropError.stopped }
                found.append(TeardropFound(candidate: result.candidate, plan: result.plan))
            }
        }
        // A stable order: along the axis heading, then by centre.
        return found.sorted {
            let a = $0.candidate, b = $1.candidate
            return (a.centre.x, a.centre.y, a.centre.z, a.radiusMM) < (b.centre.x, b.centre.y, b.centre.z, b.radiusMM)
        }
    }

    private struct Examined {
        let candidate: TeardropCandidate
        let plan: TeardropPlan?
        let farRing: [Int32]
    }

    /// Follows a face's inner loop into the part as a straight tube, and decides whether it is a horizontal round hole
    /// that can take a teardrop roof. Nil when the loop isn't a horizontal hole at all (pins, vertical holes, pockets
    /// that aren't tubes, shapes with fewer than 12 corners).
    private func examine(face f: Int, loopIndex: Int, ring: [Int32]) -> Examined? {
        let m = ring.count
        // The hole's axis, from the wall triangle across each ring edge: its third corner lies on the line along the axis
        // through one end of that edge (a rail). The end whose direction is nearer the face's inward normal is taken, then
        // again against the mean; all must agree, as in a straight tube.
        var firstWall: [Int] = []
        for k in 0..<m {
            guard let t = owner[Self.key(ring[(k + 1) % m], ring[k])].map(Int.init), faceOf[t] != Int32(f) else { return nil }
            firstWall.append(t)
        }
        guard Set(firstWall).count == m else { return nil }
        func third(_ t: Int, _ a: Int32, _ b: Int32) -> Int32 {
            let i = triangles[t]
            return i.x != a && i.x != b ? i.x : (i.y != a && i.y != b ? i.y : i.z)
        }
        var into = -faces[f].normal
        var directions: [SIMD3<Double>] = []
        for _ in 0..<2 {
            directions = (0..<m).map { k in
                let x = p(third(firstWall[k], ring[k], ring[(k + 1) % m]))
                let d1 = simd_normalize(x - p(ring[k])), d2 = simd_normalize(x - p(ring[(k + 1) % m]))
                return simd_dot(d1, into) >= simd_dot(d2, into) ? d1 : d2
            }
            into = simd_normalize(directions.reduce(SIMD3<Double>(), +))
        }
        guard into.x.isFinite, directions.allSatisfy({ simd_length($0 - into) < 2e-3 }) else { return nil }
        // Into the material (a pin runs out of it), and not at a glancing angle to the face.
        guard simd_dot(into, faces[f].normal) < -0.5 else { return nil }
        // Snapped to an exact axis when it is one, so axis-aligned holes keep exact coordinates.
        let unsnapped = into
        for k in 0..<3 where abs(abs(unsnapped[k]) - 1) < 1e-9 { into = .zero; into[k] = unsnapped[k] > 0 ? 1 : -1 }
        let tilt = asin(min(1, abs(into.z))) * 180 / .pi
        guard tilt <= 45 else { return nil }

        // The cross-section frame: `up` is Z made perpendicular to the axis.
        let up = simd_normalize(SIMD3<Double>(0, 0, 1) - into.z * into)
        let side = simd_normalize(simd_cross(up, into))
        let origin = p(ring[0])
        func flat(_ q: SIMD3<Double>) -> SIMD2<Double> { SIMD2(simd_dot(q - origin, side), simd_dot(q - origin, up)) }
        let section = ring.map { flat(p($0)) }
        let ringAlong = ring.map { simd_dot(p($0) - origin, into) }

        // The wall: triangles reached from the ring whose corners all lie on the tube beyond the ring, either on a rail (the
        // line along the axis through a ring vertex) or inside a strip between two neighbouring rails. Euclid's exports
        // split a wall's faces along and across its length, so rails and strips may carry vertices between the ends.
        func distance(_ q: SIMD2<Double>, toStrip k: Int) -> Double {
            let a = section[k], e = section[(k + 1) % m] - a
            let t = simd_clamp(simd_dot(q - a, e) / max(simd_length_squared(e), 1e-18), 0, 1)
            return simd_distance(q, a + e * t)
        }
        let ringSet = Set(ring)
        var placeOf: [Int32: (k: Int, onRail: Bool)] = [:]
        for (k, v) in ring.enumerated() { placeOf[v] = (k, true) }
        func place(_ v: Int32) -> (k: Int, onRail: Bool)? {
            if let known = placeOf[v] { return known }
            let q = flat(p(v)), along = simd_dot(p(v) - origin, into)
            var found: (k: Int, onRail: Bool)?
            var best = 1e-3
            for k in 0..<m { let d = simd_distance(q, section[k]); if d < best { best = d; found = (k, true) } }
            if found == nil { for k in 0..<m { let d = distance(q, toStrip: k); if d < best { best = d; found = (k, false) } } }
            guard let found else { return nil }
            let start = found.onRail ? ringAlong[found.k] : min(ringAlong[found.k], ringAlong[(found.k + 1) % m])
            guard along > start + 1e-4 else { return nil }
            placeOf[v] = found
            return found
        }
        /// The strips a placed vertex may belong to: both beside a rail, or its own.
        func strips(_ place: (k: Int, onRail: Bool)) -> [Int] { place.onRail ? [(place.k + m - 1) % m, place.k] : [place.k] }
        /// A wall triangle's strip, or -1 - k for a needle lying along rail k; nil when the triangle isn't on the wall.
        func strip(of t: Int) -> Int? {
            guard faceOf[t] != Int32(f) else { return nil }
            let ids = triangles[t]
            guard let a = place(ids.x), let b = place(ids.y), let c = place(ids.z) else { return nil }
            let sb = strips(b), sc = strips(c)
            let common = strips(a).filter { sb.contains($0) && sc.contains($0) }
            let along = [ids.x, ids.y, ids.z].map { simd_dot(p($0) - origin, into) }
            guard !common.isEmpty, along.max()! - along.min()! > 1e-4 else { return nil }
            return common.count == 1 ? common[0] : -1 - a.k
        }
        var wall: [Int] = []
        var stripOf: [Int] = []
        var inWall = Set<Int>()
        for t in firstWall {
            guard let s = strip(of: t) else { return nil }
            inWall.insert(t)
            wall.append(t)
            stripOf.append(s)
        }
        var head = 0
        while head < wall.count {
            let ids = triangles[wall[head]]
            head += 1
            guard wall.count <= 40 * m else { return nil }
            for (a, b) in [(ids.x, ids.y), (ids.y, ids.z), (ids.z, ids.x)] {
                guard let other = owner[Self.key(b, a)].map(Int.init), !inWall.contains(other), let s = strip(of: other) else { continue }
                inWall.insert(other)
                wall.append(other)
                stripOf.append(s)
            }
        }
        // Each rail's vertices from the ring to the far end, and the vertices inside each strip.
        var railVertices = [[Int32]](repeating: [], count: m)
        var stripVertices = [[Int32]](repeating: [], count: m)
        var seen = Set<Int32>()
        for t in wall {
            let ids = triangles[t]
            for v in [ids.x, ids.y, ids.z] where seen.insert(v).inserted {
                let at = placeOf[v]!
                if at.onRail { railVertices[at.k].append(v) } else { stripVertices[at.k].append(v) }
            }
        }
        var tubeProblem: TeardropSkipReason?
        for k in 0..<m {
            railVertices[k].sort { (simd_dot(p($0) - origin, into), $0) < (simd_dot(p($1) - origin, into), $1) }
            if railVertices[k].count < 2 || railVertices[k][0] != ring[k] { tubeProblem = .notPlainTube }
        }
        let rail = railVertices.indices.map { railVertices[$0].last ?? ring[$0] }
        if Set(rail).count != m || !ringSet.isDisjoint(with: rail) { tubeProblem = .notPlainTube }
        // The far end: wall edges that open onto neither another wall triangle nor the face round the ring. They must all
        // border one flat face, along one of its loops: an inner loop facing on (a through hole, or one into a cavity) or
        // the whole outline of a floor facing back (a blind hole).
        var farFaceID: Int32 = -1
        var farEnd = Set<Int32>()
        for t in wall {
            let ids = triangles[t]
            for (a, b) in [(ids.x, ids.y), (ids.y, ids.z), (ids.z, ids.x)] {
                guard let other = owner[Self.key(b, a)].map(Int.init), !inWall.contains(other) else { continue }
                if faceOf[other] == Int32(f) {
                    if !(ringSet.contains(a) && ringSet.contains(b)) { tubeProblem = tubeProblem ?? .notPlainTube }
                    continue
                }
                farEnd.insert(a); farEnd.insert(b)
                if farFaceID < 0 { farFaceID = faceOf[other] } else if farFaceID != faceOf[other] { tubeProblem = tubeProblem ?? .endNotFlat }
            }
        }
        if !rail.allSatisfy(farEnd.contains) || farEnd.contains(where: { placeOf[$0]!.onRail && !rail.contains($0) }) { tubeProblem = tubeProblem ?? .notPlainTube }
        var farEndInfo: (face: Int, loop: Int, through: Bool)?
        if tubeProblem == nil, farFaceID >= 0, let loops = faces[Int(farFaceID)].loops,
           let l = loops.firstIndex(where: { $0.contains(rail[0]) }), Set(loops[l]) == farEnd, loops[l].count == farEnd.count {
            let through = loops.count > 1, facing = simd_dot(faces[Int(farFaceID)].normal, into)
            if through ? facing > 0.5 : facing < -0.5 { farEndInfo = (Int(farFaceID), l, through) }
        }
        if tubeProblem == nil, farEndInfo == nil { tubeProblem = .endNotFlat }
        // Fewer than 12 real corners isn't a round shape (a square or hex hole, say): not listed.
        var corners = 0
        for k in 0..<m {
            let a = section[(k + m - 1) % m], b = section[k], c = section[(k + 1) % m]
            let turn = (b - a).x * (c - b).y - (b - a).y * (c - b).x
            if abs(turn) > 1e-9 * max(simd_length_squared(b - a), simd_length_squared(c - b)) { corners += 1 }
        }
        guard corners >= 12 else { return nil }

        let signed = Self.area(section)
        var centre = SIMD2<Double>()
        for k in 0..<m {
            let a = section[k], b = section[(k + 1) % m], cross = a.x * b.y - b.x * a.y
            centre += (a + b) * cross
        }
        centre /= 6 * signed
        let radii = section.map { simd_distance($0, centre) }
        let mean = radii.reduce(0, +) / Double(m), rMax = radii.max()!
        // Ends along the axis, at the centre.
        let nearPlane = plane(of: ring)
        func along(_ q: SIMD2<Double>, plane: (SIMD3<Double>, Double)) -> Double {
            let base = origin + q.x * side + q.y * up
            return (plane.1 - simd_dot(plane.0, base)) / simd_dot(plane.0, into)
        }
        let farPlane = plane(of: rail)
        let nearAlong = along(centre, plane: nearPlane), farAlong = along(centre, plane: farPlane)
        // The axis points towards +X or +Y; the start is the smaller position along it.
        var axis = into
        if abs(axis.x) >= abs(axis.y) ? axis.x < 0 : axis.y < 0 { axis = -axis }
        let mid = origin + centre.x * side + centre.y * up + (nearAlong + farAlong) / 2 * into
        let a0 = simd_dot(origin + centre.x * side + centre.y * up + nearAlong * into, axis)
        let a1 = simd_dot(origin + centre.x * side + centre.y * up + farAlong * into, axis)
        let heading = atan2(axis.y, axis.x) * 180 / .pi
        let key = TeardropHoleKey(centre: SIMD3<Int32>(Int32((mid.x * 100).rounded()), Int32((mid.y * 100).rounded()), Int32((mid.z * 100).rounded())),
                                  heading: Int32((heading * 10).rounded()), diameter: Int32((2 * mean * 100).rounded()))
        var through = farEndInfo?.through ?? true
        func candidate(_ skip: TeardropSkipReason?, wallAbove: Float? = nil, low: SIMD3<Float> = .zero, high: SIMD3<Float> = .zero) -> TeardropCandidate {
            TeardropCandidate(key: key, centre: SIMD3<Float>(mid), axis: SIMD3<Float>(axis), radiusMM: Float(mean),
                              startMM: Float(min(a0, a1)), endMM: Float(max(a0, a1)), through: through, wallAboveMM: wallAbove,
                              skipped: skip, changeLow: low, changeHigh: high)
        }
        func skip(_ reason: TeardropSkipReason) -> Examined { Examined(candidate: candidate(reason), plan: nil, farRing: rail) }

        // Round and convex.
        var convex = true
        for k in 0..<m {
            let a = section[(k + m - 1) % m], b = section[k], c = section[(k + 1) % m]
            let turn = ((b - a).x * (c - b).y - (b - a).y * (c - b).x) * (signed > 0 ? 1 : -1)
            if turn < -1e-9 * max(simd_length_squared(b - a), simd_length_squared(c - b)) { convex = false }
        }
        guard convex, radii.allSatisfy({ abs($0 - mean) <= 0.03 * mean + 0.01 }) else { return skip(.notRound) }
        if tilt > Double(teardropMaximumTiltDegrees) { return skip(.tilted) }
        if 2 * mean < Double(teardropMinimumDiameterMM) { return skip(.tooSmall) }
        if 2 * mean > Double(teardropMaximumDiameterMM) { return skip(.tooLarge) }
        if let tubeProblem { return skip(tubeProblem) }
        guard let end = farEndInfo else { return skip(.endNotFlat) }
        through = end.through

        // The new outline: the hull of the ring and the flat top's two corners, which sit on the 45° tangents to the
        // circle through the farthest ring point, at the ring's own top. Every ring point is inside that circle, so the
        // new faces are no steeper than 45° from vertical.
        let top = section.map(\.y).max()!
        let reach = 2.squareRoot() * rMax - (top - centre.y)
        let right = SIMD2(centre.x + reach, top), left = SIMD2(centre.x - reach, top)
        let hull = Self.hull(section + [right, left])
        guard let at = hull.firstIndex(of: m), hull[(at + 1) % hull.count] == m + 1 else { return skip(.couldNotRebuild) }
        let vR = hull[(at + hull.count - 1) % hull.count], vL = hull[(at + 2) % hull.count]
        guard vR < m, vL < m, vR != vL else { return skip(.couldNotRebuild) }
        // Ring positions strictly between vR and vL over the top.
        var removedK: [Int] = []
        if signed > 0 { var k = (vR + 1) % m; while k != vL { removedK.append(k); k = (k + 1) % m } }
        else { var k = (vL + 1) % m; while k != vR { removedK.append(k); k = (k + 1) % m } }
        guard !removedK.isEmpty, removedK.count < m - 2 else { return skip(.couldNotRebuild) }
        let removedSet = Set(removedK)
        // Strips beside a removed rail go; so do the vertices on those rails and inside those strips.
        let removedStrips = Set((0..<m).filter { removedSet.contains($0) || removedSet.contains(($0 + 1) % m) })
        let removedVertices = removedK.flatMap { railVertices[$0] } + removedStrips.sorted().flatMap { stripVertices[$0] }
        var outline: [SIMD2<Double>] = []
        if signed > 0 {
            var k = vL; while true { outline.append(section[k]); if k == vR { break }; k = (k + 1) % m }
            outline += [right, left]
        } else {
            var k = vR; while true { outline.append(section[k]); if k == vL { break }; k = (k + 1) % m }
            outline += [left, right]
        }
        let extraArea = abs(Self.area(outline)) - abs(signed)
        guard extraArea > 0 else { return skip(.couldNotRebuild) }

        // Every removed ring vertex is used only by the wall and the two end faces.
        let endFaces: Set<Int32> = [Int32(f), Int32(end.face)]
        for v in removedVertices {
            for i in Int(incidentStart[Int(v)])..<Int(incidentStart[Int(v) + 1]) {
                let t = Int(incidentList[i])
                guard inWall.contains(t) || endFaces.contains(faceOf[t]) else { return skip(.crowded) }
            }
        }
        // Material round the new shape, measured by rays from the axis at five places along the hole. Rays are turned
        // 0.43° off the obvious directions so they don't run exactly through the ring's vertices.
        let turn = 0.43 * Double.pi / 180
        func rotate(_ d: SIMD2<Double>) -> SIMD2<Double> { SIMD2(d.x * cos(turn) - d.y * sin(turn), d.x * sin(turn) + d.y * cos(turn)) }
        let rays: [(SIMD2<Double>, roof: Bool)] = [
            (rotate(SIMD2(0, 1)), true),
            (rotate(simd_normalize(right - centre)), true), (rotate(simd_normalize(left - centre)), true),
            (rotate(SIMD2(0.5.squareRoot(), 0.5.squareRoot())), false), (rotate(SIMD2(-(0.5.squareRoot()), 0.5.squareRoot())), false),
        ]
        let nearLow = ring.map { simd_dot(p($0) - origin, into) }.max()!, farHigh = rail.map { simd_dot(p($0) - origin, into) }.min()!
        guard farHigh > nearLow else { return skip(.notPlainTube) }
        let span = farHigh - nearLow, inset = min(0.05, span / 10)
        let wallReach = Double(teardropWallReachMM)
        let nearby = trianglesNear(low: (ring + rail).map { p($0) }.reduce(SIMD3(repeating: .greatestFiniteMagnitude), simd_min),
                                   high: (ring + rail).map { p($0) }.reduce(SIMD3(repeating: -.greatestFiniteMagnitude), simd_max),
                                   margin: 0.2 * rMax + wallReach + 1)
        var wallAbove = wallReach, wallBeside = wallReach
        for fraction in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let at = nearLow + inset + (span - 2 * inset) * fraction
            let start = origin + centre.x * side + centre.y * up + at * into
            for (d, roof) in rays {
                let ray = simd_normalize(d.x * side + d.y * up)
                guard let wallHit = Self.rayExit(centre, d, section), let newHit = Self.rayExit(centre, d, outline) else { return skip(.couldNotRebuild) }
                let hits = rayHits(start, ray, nearby, limit: newHit + wallReach + 0.5)
                guard let first = hits.first, abs(first - wallHit) < 0.01 else { return skip(.crowded) }
                let beyond = min(wallReach, (hits.count > 1 ? hits[1] : .greatestFiniteMagnitude) - newHit)
                if roof { wallAbove = min(wallAbove, beyond) } else { wallBeside = min(wallBeside, beyond) }
            }
        }
        if wallAbove < Double(teardropMinimumWallMM) { return skip(.thinRoof) }
        if wallBeside < Double(teardropMinimumWallMM) { return skip(.thinWall) }

        // The new corners at each end, on that end's face plane. Coordinates every ring vertex at an end shares exactly
        // (x at a face x = c, z of the top for a level axis) are copied, so the new vertices sit exactly on the face.
        func corner(_ q: SIMD2<Double>, plane: (SIMD3<Double>, Double), ring: [Int32], topVertex: Int32) -> SIMD3<Float> {
            var x = SIMD3<Float>(origin + q.x * side + q.y * up + along(q, plane: plane) * into)
            for k in 0..<3 {
                let value = points[Int(ring[0])][k]
                if ring.allSatisfy({ points[Int($0)][k] == value }) { x[k] = value }
            }
            if into.z == 0 { x.z = points[Int(topVertex)].z }
            return x
        }
        let topK = (0..<m).max { section[$0].y != section[$1].y ? section[$0].y < section[$1].y : $0 > $1 }!
        let newCorners = [corner(right, plane: nearPlane, ring: ring, topVertex: ring[topK]), corner(left, plane: nearPlane, ring: ring, topVertex: ring[topK]),
                       corner(right, plane: farPlane, ring: rail, topVertex: rail[topK]), corner(left, plane: farPlane, ring: rail, topVertex: rail[topK])]
        // Wall triangles in a removed strip, or needles along a removed rail. A needle along a kept rail beside the change
        // would need splitting, so such a hole is left alone.
        var dropped: [Int] = []
        for (i, t) in wall.enumerated() {
            let s = stripOf[i]
            if s >= 0 {
                if removedStrips.contains(s) { dropped.append(t) }
            } else if removedSet.contains(-1 - s) {
                dropped.append(t)
            } else if -1 - s == vR || -1 - s == vL {
                return skip(.couldNotRebuild)
            }
        }
        dropped.sort()
        // The volume removed: the extra area times the hole's length at the extra area's centroid.
        var extraCentre = SIMD2<Double>()
        do {
            let a = Self.area(outline)
            var c = SIMD2<Double>()
            for k in outline.indices { let u = outline[k], w = outline[(k + 1) % outline.count]; c += (u + w) * (u.x * w.y - w.x * u.y) }
            c /= 6 * a
            extraCentre = (c * abs(a) - centre * abs(signed)) / extraArea
        }
        let expectedVolume = extraArea * abs(along(extraCentre, plane: farPlane) - along(extraCentre, plane: nearPlane))
        // The change's box: the new corners and the removed ring vertices.
        var low = newCorners.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude), simd_min), high = newCorners.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude), simd_max)
        for k in removedK { for v in [ring[k], rail[k], ring[vR], ring[vL], rail[vR], rail[vL]] { low = simd_min(low, points[Int(v)]); high = simd_max(high, points[Int(v)]) } }
        let plan = TeardropPlan(nearFace: f, nearLoop: loopIndex, farFace: end.face, farLoop: end.loop,
                                removed: removedVertices,
                                rightNear: ring[vR], leftNear: ring[vL], rightFar: rail[vR], leftFar: rail[vL],
                                rightRail: railVertices[vR], leftRail: railVertices[vL],
                                corners: newCorners, droppedWall: dropped, axisPoint: origin + centre.x * side + centre.y * up, axis: into,
                                expectedVolume: expectedVolume)
        return Examined(candidate: candidate(nil, wallAbove: Float(wallAbove), low: low, high: high), plan: plan, farRing: rail)
    }

    /// The plane through a ring's vertices (normal and offset), fitted as the ring's own: Newell's normal.
    private func plane(of ring: [Int32]) -> (SIMD3<Double>, Double) {
        var n = SIMD3<Double>(), c = SIMD3<Double>()
        for k in ring.indices {
            let a = p(ring[k]), b = p(ring[(k + 1) % ring.count])
            n += SIMD3(a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x)
            c += a
        }
        n = simd_normalize(n)
        c /= Double(ring.count)
        return (n, simd_dot(n, c))
    }

    /// Andrew's monotone chain, anticlockwise, without collinear points. Returns indices into `points`.
    static func hull(_ points: [SIMD2<Double>]) -> [Int] {
        let order = points.indices.sorted { points[$0].x != points[$1].x ? points[$0].x < points[$1].x : (points[$0].y != points[$1].y ? points[$0].y < points[$1].y : $0 < $1) }
        func cross(_ o: Int, _ a: Int, _ b: Int) -> Double {
            (points[a].x - points[o].x) * (points[b].y - points[o].y) - (points[a].y - points[o].y) * (points[b].x - points[o].x)
        }
        var lower: [Int] = [], upper: [Int] = []
        for i in order {
            while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], i) <= 0 { lower.removeLast() }
            lower.append(i)
        }
        for i in order.reversed() {
            while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], i) <= 0 { upper.removeLast() }
            upper.append(i)
        }
        return Array(lower.dropLast() + upper.dropLast())
    }

    /// Where a ray from `origin` (inside the convex outline) leaves it.
    static func rayExit(_ origin: SIMD2<Double>, _ d: SIMD2<Double>, _ outline: [SIMD2<Double>]) -> Double? {
        var best: Double?
        for k in outline.indices {
            let a = outline[k], b = outline[(k + 1) % outline.count], e = b - a
            let denominator = d.x * e.y - d.y * e.x
            guard abs(denominator) > 1e-15 else { continue }
            let w = a - origin
            let t = (w.x * e.y - w.y * e.x) / denominator, s = (w.x * d.y - w.y * d.x) / denominator
            if t > 0, s >= -1e-12, s <= 1 + 1e-12 { best = min(best ?? t, t) }
        }
        return best
    }

    private func trianglesNear(low: SIMD3<Double>, high: SIMD3<Double>, margin: Double) -> [Int] {
        let lo = low - margin, hi = high + margin
        return triangles.indices.filter { t in
            let ids = triangles[t]
            let a = p(ids.x), b = p(ids.y), c = p(ids.z)
            let tl = simd_min(a, simd_min(b, c)), th = simd_max(a, simd_max(b, c))
            return th.x >= lo.x && tl.x <= hi.x && th.y >= lo.y && tl.y <= hi.y && th.z >= lo.z && tl.z <= hi.z
        }
    }

    /// Distances to every surface the ray crosses within `limit`, sorted, with hits on shared edges counted once.
    private func rayHits(_ origin: SIMD3<Double>, _ direction: SIMD3<Double>, _ list: [Int], limit: Double) -> [Double] {
        var hits: [Double] = []
        for t in list {
            let ids = triangles[t]
            let a = p(ids.x), e1 = p(ids.y) - a, e2 = p(ids.z) - a
            let pv = simd_cross(direction, e2), det = simd_dot(e1, pv)
            guard abs(det) > 1e-12 else { continue }
            let tv = origin - a, u = simd_dot(tv, pv) / det
            guard u >= -1e-9, u <= 1 + 1e-9 else { continue }
            let qv = simd_cross(tv, e1), w = simd_dot(direction, qv) / det
            guard w >= -1e-9, u + w <= 1 + 1e-9 else { continue }
            let distance = simd_dot(e2, qv) / det
            if distance > 1e-6, distance <= limit { hits.append(distance) }
        }
        hits.sort()
        var merged: [Double] = []
        for h in hits where merged.last.map({ h - $0 > 1e-5 }) ?? true { merged.append(h) }
        return merged
    }

    // MARK: Building the copy

    func build(_ plans: [TeardropPlan]) -> TeardropBuild {
        var points = self.points
        var dropped = Set<Int>()
        var added: [SIMD3<Int32>] = []
        // New corner ids, and each changed face's loop replacements: (loop index, removed ring vertices, the ring vertex
        // either side mapped to its corner).
        var replacements: [Int: [(loop: Int, removed: Set<Int32>, corner: [Int32: Int32], hole: Int)]] = [:]
        var changedFaces: [Int] = []
        for (h, plan) in plans.enumerated() {
            let base = Int32(points.count)
            points += plan.corners
            let rN = base, lN = base + 1, rF = base + 2, lF = base + 3
            let removed = Set(plan.removed)
            for (face, loop, map) in [(plan.nearFace, plan.nearLoop, [plan.rightNear: rN, plan.leftNear: lN]),
                                      (plan.farFace, plan.farLoop, [plan.rightFar: rF, plan.leftFar: lF])] {
                if replacements[face] == nil { changedFaces.append(face) }
                replacements[face, default: []].append((loop, removed, map, h))
            }
            for t in plan.droppedWall { dropped.insert(t) }
            // The three new wall strips from the near end to the far end, facing the axis: the shoulders fanned from their
            // near corner to every vertex along the kept rail beside them, and the flat top as one quad.
            var strips: [SIMD3<Int32>] = []
            for (rail, near, far) in [(plan.rightRail, rN, rF), (plan.leftRail, lN, lF)] {
                for i in 0..<(rail.count - 1) { strips.append(SIMD3(near, rail[i], rail[i + 1])) }
                strips.append(SIMD3(near, rail[rail.count - 1], far))
            }
            strips += [SIMD3(rN, lN, lF), SIMD3(rN, lF, rF)]
            for tri in strips {
                let x = SIMD3<Double>(points[Int(tri.x)]), y = SIMD3<Double>(points[Int(tri.y)]), z = SIMD3<Double>(points[Int(tri.z)])
                let normal = simd_cross(y - x, z - x)
                guard simd_length(normal) > 1e-9 else { return .failed([h]) }
                let centroid = (x + y + z) / 3
                let towardAxis = plan.axisPoint + simd_dot(centroid - plan.axisPoint, plan.axis) * plan.axis - centroid
                added.append(simd_dot(normal, towardAxis) > 0 ? tri : SIMD3(tri.x, tri.z, tri.y))
            }
        }
        for face in changedFaces.sorted() {
            let info = faces[face]
            guard var loops = info.loops else { return .failed(replacements[face]!.map(\.hole)) }
            let holes = replacements[face]!.map(\.hole)
            for change in replacements[face]! {
                guard let replaced = Self.replacing(loops[change.loop], removed: change.removed, corner: change.corner) else { return .failed(holes) }
                loops[change.loop] = replaced
            }
            // Triangulated in the face's plane, from every loop point, so the new triangles meet the old edges exactly.
            let (e1, e2) = Self.basis(info.normal)
            var local: [Int32] = []
            var localIndex: [Int32: Int] = [:]
            var flat: [SIMD2<Double>] = []
            let indexed = loops.map { loop in loop.map { v -> Int in
                if let i = localIndex[v] { return i }
                localIndex[v] = local.count
                local.append(v)
                let q = SIMD3<Double>(points[Int(v)])
                flat.append(SIMD2(simd_dot(q, e1), simd_dot(q, e2)))
                return local.count - 1
            } }
            let firstNew = Int32(self.points.count)
            let changedLoops = Set(replacements[face]!.map(\.loop))
            guard Self.loopsAreSeparate(indexed, flat, changed: changedLoops, isNew: { local[$0] >= firstNew }), let filled = try? triangulatePlanarRegion(points: flat, loops: indexed) else { return .failed(holes) }
            for t in info.triangles { dropped.insert(t) }
            added += filled.map { SIMD3(local[Int($0.x)], local[Int($0.y)], local[Int($0.z)]) }
        }
        var vertices: [Float] = []
        vertices.reserveCapacity((triangles.count - dropped.count + added.count) * 9)
        for (t, ids) in triangles.enumerated() where !dropped.contains(t) {
            for i in [ids.x, ids.y, ids.z] { let q = points[Int(i)]; vertices += [q.x, q.y, q.z] }
        }
        for ids in added {
            for i in [ids.x, ids.y, ids.z] { let q = points[Int(i)]; vertices += [q.x, q.y, q.z] }
        }
        return .built(vertices)
    }

    /// `loop` with its contiguous run of `removed` vertices replaced by the corners of the vertices either side.
    static func replacing(_ loop: [Int32], removed: Set<Int32>, corner: [Int32: Int32]) -> [Int32]? {
        let n = loop.count
        guard let first = (0..<n).first(where: { removed.contains(loop[$0]) && !removed.contains(loop[($0 + n - 1) % n]) }) else { return nil }
        var end = first
        while removed.contains(loop[(end + 1) % n]) { end = (end + 1) % n }
        let before = loop[(first + n - 1) % n], after = loop[(end + 1) % n]
        guard let a = corner[before], let b = corner[after] else { return nil }
        var result: [Int32] = []
        var k = (end + 1) % n
        while k != first { result.append(loop[k]); k = (k + 1) % n }
        // `result` runs from `after` round to `before`; the corners close the loop.
        guard result.count + removed.filter({ loop.contains($0) }).count == n else { return nil }
        return result + [a, b]
    }

    /// The changed loops' new edges (those at a point from `firstNew` on) cross or touch no other loop's edges, apart
    /// from shared points, and no other loop lies inside a changed one: a reshaped hole stays clear of the face's other
    /// outlines. The unchanged loops were already valid.
    static func loopsAreSeparate(_ loops: [[Int]], _ q: [SIMD2<Double>], changed: Set<Int>, isNew: (Int) -> Bool) -> Bool {
        func orient(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
        func inside(_ point: SIMD2<Double>, _ loop: [Int]) -> Bool {
            var result = false
            var j = loop.count - 1
            for i in loop.indices {
                let a = q[loop[i]], b = q[loop[j]]
                if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
                j = i
            }
            return result
        }
        for l in changed.sorted() {
            let loop = loops[l]
            for k in loop.indices where isNew(loop[k]) || isNew(loop[(k + 1) % loop.count]) {
                let a = loop[k], b = loop[(k + 1) % loop.count]
                let lowA = simd_min(q[a], q[b]), highA = simd_max(q[a], q[b])
                for (o, other) in loops.enumerated() where o != l {
                    for i in other.indices {
                        let c = other[i], d = other[(i + 1) % other.count]
                        if a == c || a == d || b == c || b == d { continue }
                        let lowB = simd_min(q[c], q[d]), highB = simd_max(q[c], q[d])
                        guard highA.x >= lowB.x, highB.x >= lowA.x, highA.y >= lowB.y, highB.y >= lowA.y else { continue }
                        let d1 = orient(q[c], q[d], q[a]), d2 = orient(q[c], q[d], q[b]), d3 = orient(q[a], q[b], q[c]), d4 = orient(q[a], q[b], q[d])
                        if (d1 > 0) != (d2 > 0) || d1 == 0 || d2 == 0, (d3 > 0) != (d4 > 0) || d3 == 0 || d4 == 0 { return false }
                    }
                }
            }
            for (o, other) in loops.enumerated() where o != l && inside(q[other[0]], loop) && !inside(q[loop[0]], other) { return false }
        }
        return true
    }
}

private extension TeardropCandidate {
    func skipping(_ reason: TeardropSkipReason) -> TeardropCandidate {
        TeardropCandidate(key: key, centre: centre, axis: axis, radiusMM: radiusMM, startMM: startMM, endMM: endMM, through: through,
                          wallAboveMM: nil, skipped: reason, changeLow: .zero, changeHigh: .zero)
    }
}
