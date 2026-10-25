import Foundation
import simd

// Fit tools for a mesh: scale to a size, flatten the bottom, add a plinth, and an advisory wall-thickness check.
// Everything here is pure and deterministic: triangles, vertices, cut points and loops are walked in index order, and
// dictionaries are used only for lookups, never iterated for output. Results are new meshes for separate library copies.

// MARK: - Errors

enum MeshFitError: LocalizedError, Equatable {
    case invalidTarget
    case flatAxis
    case exceedsBuildVolume(largestMM: Float)
    case notClosedSolid
    case invalidCutHeight
    case crossSectionTooDetailed
    case capFailed
    case invalidPlinth(String)
    case tooManyTriangles
    case resultNotClosed
    case addedZeroAreaTriangles
    /// More separate parts than the model had, such as slots sealed into closed cavities: Slant charges each as a body.
    case addedParts
    case stopped

    var errorDescription: String? {
        switch self {
        case .invalidTarget: return "Enter a size between 0.1 and 10,000 mm."
        case .flatAxis: return "The model has no size along that axis, so it can’t be scaled to it."
        case .exceedsBuildVolume(let largest):
            return "The result would be \(String(format: "%.1f", largest)) mm on its longest side, larger than Slant’s 220 mm build volume, so it wasn’t saved."
        case .notClosedSolid:
            return "This tool needs a closed, outward-facing mesh. The mesh check above lists what to repair first."
        case .invalidCutHeight: return "Choose a height above the model’s lowest point and below its top."
        case .crossSectionTooDetailed: return "The cut outline is too detailed to fill. Simplify the model first, or cut at a different height."
        case .capFailed:
            return "The cut outline crosses itself or touches another part, so it couldn’t be filled cleanly. Repair the mesh, or try a slightly different height."
        case .invalidPlinth(let reason): return reason
        case .tooManyTriangles: return "The result would have more than 500,000 triangles, so it wasn’t saved."
        case .resultNotClosed: return "The result didn’t come out as a closed solid, so it wasn’t saved. Try a slightly different height."
        case .addedZeroAreaTriangles:
            return "The result would have more zero-area triangles than the model, so it wasn’t saved. Try a slightly different height, or repair the model first."
        case .addedParts:
            return "The result would have more separate parts than the model, such as slots or gaps sealed into closed cavities, which Slant charges as extra bodies, so it wasn’t saved."
        case .stopped: return "Stopped. Nothing was saved."
        }
    }
}

// MARK: - Millimetre input

/// A positive millimetre value typed by the seller: digits with one optional decimal point or comma and an optional
/// trailing "mm". Nil for anything else, including zero, negatives, exponents and values over 10,000.
func meshFitMillimetres(_ text: String) -> Double? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if trimmed.hasSuffix("mm") { trimmed = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces) }
    trimmed = trimmed.replacingOccurrences(of: ",", with: ".")
    guard !trimmed.isEmpty, trimmed.filter({ $0 == "." }).count <= 1,
          trimmed.allSatisfy({ ($0.isASCII && $0.isNumber) || $0 == "." }),
          trimmed != ".", let value = Double(trimmed), value.isFinite, value > 0, value <= 10_000 else { return nil }
    return value
}

// MARK: - Scale to size

enum MeshFitAxis: String, CaseIterable, Identifiable, Codable, Sendable {
    case longest = "Longest side", x = "Width (X)", y = "Depth (Y)", z = "Height (Z)"
    var id: String { rawValue }
}

struct ScaleToSizePlan: Equatable, Sendable {
    let axis: MeshFitAxis
    let targetMM: Double
    /// Uniform factor applied to every coordinate.
    let factor: Double
    let resultSizeMM: SIMD3<Float>
    var fitsBuildVolume: Bool { resultSizeMM.max() <= slantBuildVolumeMM }
}

/// The uniform scale that makes `axis` (or the longest side) of a model `targetMM` long, and the size that results.
func scaleToSizePlan(extentMM: SIMD3<Float>, axis: MeshFitAxis, targetMM: Double) throws -> ScaleToSizePlan {
    guard targetMM.isFinite, targetMM >= 0.1, targetMM <= 10_000 else { throw MeshFitError.invalidTarget }
    let current: Float
    switch axis {
    case .longest: current = extentMM.max()
    case .x: current = extentMM.x
    case .y: current = extentMM.y
    case .z: current = extentMM.z
    }
    guard current.isFinite, current > 0 else { throw MeshFitError.flatAxis }
    let factor = targetMM / Double(current)
    let size = SIMD3<Float>(SIMD3<Double>(extentMM) * factor)
    return ScaleToSizePlan(axis: axis, targetMM: targetMM, factor: factor, resultSizeMM: size)
}

func scaledToSizeCopyName(_ name: String, plan: ScaleToSizePlan) -> String {
    let size = String(format: "%g", (plan.targetMM * 100).rounded() / 100)
    let axis: String
    switch plan.axis {
    case .longest: axis = ""
    case .x: axis = " wide"
    case .y: axis = " deep"
    case .z: axis = " tall"
    }
    return "\(meshFitCopyBaseName(name)) (scaled to \(size) mm\(axis))"
}

/// The library name without a model file extension, so suffixes don't follow ".stl".
func meshFitBaseName(_ name: String) -> String {
    var base = name
    if let dot = base.lastIndex(of: "."), dot > base.startIndex,
       modelNameFileExtensions.contains(base[base.index(after: dot)...].lowercased()) {
        base = String(base[..<dot])
    }
    return base
}

extension STLMesh {
    /// A binary STL scaled so the chosen axis matches `targetMM`, checked like any scaled copy. Refuses results that
    /// don't fit Slant's build volume.
    func scaledToSizeSTLData(axis: MeshFitAxis, targetMM: Double,
                             maximumTriangles: Int = STLMesh.maximumTriangles) throws -> (data: Data, plan: ScaleToSizePlan) {
        let plan = try scaleToSizePlan(extentMM: maximum - minimum, axis: axis, targetMM: targetMM)
        guard plan.fitsBuildVolume else { throw MeshFitError.exceedsBuildVolume(largestMM: plan.resultSizeMM.max()) }
        return (try scaledSTLData(by: plan.factor, maximumTriangles: maximumTriangles), plan)
    }
}

// MARK: - Flat base

/// Contact areas are measured on the model as it sits now, with Z up.
struct FlatBaseSuggestion: Equatable, Sendable {
    /// Flat, downward-facing area at the lowest point.
    let currentContactMM2: Double
    /// The XY bounding box's area.
    let footprintMM2: Double
    let targetContactMM2: Double
    /// The deepest cut considered, above the lowest point.
    let maximumCutMM: Float
    /// The smallest cut, above the lowest point, whose cross-section reaches the target. Nil when the model is already
    /// flat enough or no cut up to `maximumCutMM` reaches it (a plinth suits those models better).
    let cutHeightMM: Float?
    let contactAtCutMM2: Double?
    var alreadyFlat: Bool { currentContactMM2 >= targetContactMM2 }
}

let flatBaseDefaultMinimumContactMM2 = 100.0
let flatBaseDefaultContactFraction = 0.15
let flatBaseDefaultMaximumCutMM: Float = 5
/// Shown with the flat-base and plinth tools; Slant doesn't publish its first-layer settings.
let elephantFootNote = "The first layers of a print often spread slightly (“elephant’s foot”), so the bottom edge may come out a little wider than the model."
/// Shown with the plinth tool, whose bottom edge Studio chamfers.
let plinthChamferNote = "The plinth’s bottom edge gets a 0.5 mm chamfer, so the first layers’ slight spread (“elephant’s foot”) stays within its outline."

private func signedArea2D(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
    ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
}

extension STLMesh {
    fileprivate func corner(_ triangle: Int, _ j: Int) -> SIMD3<Float> {
        let i = triangle * 9 + j * 3
        return SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
    }

    /// Flat, downward-facing area within 0.0001 mm of the lowest point (the same tolerance as the placement check).
    func bottomContactAreaMM2() -> Double {
        var area = 0.0
        let floor = minimum.z + 0.0001
        for t in 0..<triangleCount {
            let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
            guard max(a.z, b.z, c.z) <= floor else { continue }
            let cross = simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))
            let length = simd_length(cross)
            if length > 0, cross.z / length <= -0.999999 { area += length / 2 }
        }
        return area
    }

    /// Net cross-section area where the plane `height` mm above the lowest point cuts a closed, outward-facing mesh.
    /// Open or inconsistent meshes give an unreliable figure; callers check the mesh first.
    func crossSectionAreaMM2(atHeight height: Float) -> Double {
        crossSectionAreas(atHeights: [height])[0]
    }

    /// Net cross-section areas at several heights above the lowest point, from one pass over the triangles that
    /// reach below the highest of them.
    func crossSectionAreas(atHeights heights: [Float]) -> [Double] {
        guard let top = heights.max() else { return [] }
        let spanning = trianglesBelow(minimum.z + top)
        return heights.map { crossSectionArea(Double(minimum.z + $0), in: spanning) }
    }

    /// Corners (in Double) of each triangle whose lowest corner is at or below `ceiling`, in triangle order.
    fileprivate func trianglesBelow(_ ceiling: Float) -> [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] {
        var found: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)] = []
        for t in 0..<triangleCount {
            let base = t * 9
            guard min(vertices[base + 2], vertices[base + 5], vertices[base + 8]) <= ceiling else { continue }
            found.append((SIMD3<Double>(corner(t, 0)), SIMD3<Double>(corner(t, 1)), SIMD3<Double>(corner(t, 2))))
        }
        return found
    }

    fileprivate func crossSectionArea(_ h: Double, in triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]) -> Double {
        func cut(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> SIMD2<Double> {
            let s = (h - a.z) / (b.z - a.z)
            return SIMD2(a.x + (b.x - a.x) * s, a.y + (b.y - a.y) * s)
        }
        var area = 0.0
        for (p0, p1, p2) in triangles {
            let u0 = p0.z > h, u1 = p1.z > h, u2 = p2.z > h
            let count = (u0 ? 1 : 0) + (u1 ? 1 : 0) + (u2 ? 1 : 0)
            guard count == 1 || count == 2 else { continue }
            // Rotate so `a` is the odd corner out: the only one above (count 1) or the only one below (count 2).
            let (a, b, c): (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)
            if u0 == (count == 1) && u1 != u0 && u2 != u0 { (a, b, c) = (p0, p1, p2) }
            else if u1 == (count == 1) && u0 != u1 && u2 != u1 { (a, b, c) = (p1, p2, p0) }
            else { (a, b, c) = (p2, p0, p1) }
            // The kept (upper) part's open edge runs start → end; start × end sums to twice the loop area.
            // One above (a): from a–b's crossing to c–a's. Two above (a below): from c–a's crossing to a–b's.
            let start = count == 1 ? cut(a, b) : cut(c, a)
            let end = count == 1 ? cut(c, a) : cut(a, b)
            area += (start.x * end.y - end.x * start.y) / 2
        }
        return area
    }

    /// The smallest cut (in `stepMM` steps) that gives a flat contact of at least the smaller of `minimumContactMM2`
    /// and `minimumContactFraction` of the footprint. Cuts never go deeper than `maximumCutMM` or a quarter of the height.
    func flatBaseSuggestion(minimumContactMM2: Double = flatBaseDefaultMinimumContactMM2,
                            minimumContactFraction: Double = flatBaseDefaultContactFraction,
                            maximumCutMM: Float = flatBaseDefaultMaximumCutMM, stepMM: Float = 0.05) -> FlatBaseSuggestion {
        let extent = maximum - minimum
        let footprint = Double(extent.x) * Double(extent.y)
        let target = max(min(minimumContactMM2, footprint * minimumContactFraction), 0.000001)
        let deepest = min(maximumCutMM, extent.z / 4)
        let current = bottomContactAreaMM2()
        guard current < target, deepest >= stepMM, stepMM > 0 else {
            return FlatBaseSuggestion(currentContactMM2: current, footprintMM2: footprint, targetContactMM2: target,
                                      maximumCutMM: max(deepest, 0), cutHeightMM: nil, contactAtCutMM2: nil)
        }
        let steps = min(Int((deepest / stepMM).rounded(.down)), 1000)
        let spanning = trianglesBelow(minimum.z + Float(max(steps, 1)) * stepMM)
        for step in 1...max(steps, 1) {
            let height = Float(step) * stepMM
            let area = crossSectionArea(Double(minimum.z + height), in: spanning)
            if area >= target {
                return FlatBaseSuggestion(currentContactMM2: current, footprintMM2: footprint, targetContactMM2: target,
                                          maximumCutMM: deepest, cutHeightMM: height, contactAtCutMM2: area)
            }
        }
        return FlatBaseSuggestion(currentContactMM2: current, footprintMM2: footprint, targetContactMM2: target,
                                  maximumCutMM: deepest, cutHeightMM: nil, contactAtCutMM2: nil)
    }
}

/// A saved flat-base or plinth copy, already parsed back and checked as a closed, outward-facing solid.
struct MeshFitResult: Sendable {
    let mesh: STLMesh
    let data: Data
    /// The cut's height above the original lowest point (after the small nudge that keeps it off existing vertices).
    let cutHeightMM: Float
    /// The flat area on the bed: the filled cut for a flat base, the plinth's underside for a plinth.
    let contactAreaMM2: Double
    var sizeMM: SIMD3<Float> { mesh.maximum - mesh.minimum }
    var fitsBuildVolume: Bool { sizeMM.max() <= slantBuildVolumeMM }
}

/// The part of a mesh above a horizontal plane, with the cut outline as loops of points on the plane.
private struct PlaneCut {
    /// Kept triangles, three corners each, in source triangle order.
    var kept: [SIMD3<Float>] = []
    /// Points where edges cross the plane; their z is exactly `height`.
    var cutPoints: [SIMD3<Float>] = []
    /// Outline loops as indices into `cutPoints`, running the way the kept surface's open edges run.
    var loops: [[Int]] = []
    /// Absolute z of the plane.
    var height: Float = 0
}

/// Keeps the plane this far (in mm) from any vertex height, so no vertex lies on it: about ten Float steps at 200 mm.
private let cutVertexClearance: Float = 0.0002
/// The furthest the plane may move up to find that gap.
private let cutMaximumNudge: Float = 0.1

/// The model's mesh check, once it is known to be a closed, outward-facing solid.
@discardableResult
private func requireClosedSolid(_ mesh: STLMesh, isCancelled: () -> Bool) throws -> MeshHealthReport {
    guard let report = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw MeshFitError.stopped }
    guard report.isClosed, report.isConsistentlyOriented, report.signedVolume > 0 else { throw MeshFitError.notClosedSolid }
    return report
}

/// Cuts a closed, consistently oriented mesh with the plane z = minimum.z + `height` and keeps the part above.
private func planeCut(_ mesh: STLMesh, height: Float, isCancelled: () -> Bool) throws -> PlaneCut {
    let extent = mesh.maximum - mesh.minimum
    guard height.isFinite, height > 0, height < extent.z else { throw MeshFitError.invalidCutHeight }
    let count = mesh.triangleCount
    let v = mesh.vertices
    let check = 8192

    // Nudge the plane up, past vertex heights in ascending order, until it is at least 0.2 µm from every vertex.
    let requested = mesh.minimum.z + height
    var near: [Float] = []
    for i in stride(from: 2, to: v.count, by: 3)
    where v[i] >= requested - cutVertexClearance && v[i] <= requested + cutMaximumNudge + cutVertexClearance {
        near.append(v[i])
    }
    near.sort()
    var h = requested
    for z in near where abs(z - h) < cutVertexClearance {
        h = max(h, z + cutVertexClearance)
    }
    guard h <= requested + cutMaximumNudge else { throw MeshFitError.invalidCutHeight }
    guard h < mesh.maximum.z else { throw MeshFitError.invalidCutHeight }

    // Weld identical coordinates in first-seen order, as the mesh check does.
    var ids = [Int32](repeating: 0, count: count * 3)
    var lookup: [SIMD3<Float>: Int32] = [:]
    var points: [SIMD3<Float>] = []
    for corner in 0..<(count * 3) {
        if corner % check == 0, isCancelled() { throw MeshFitError.stopped }
        let p = SIMD3<Float>(v[corner * 3] + 0, v[corner * 3 + 1] + 0, v[corner * 3 + 2] + 0)
        if let id = lookup[p] { ids[corner] = id } else {
            let id = Int32(points.count)
            lookup[p] = id
            points.append(p)
            ids[corner] = id
        }
    }
    lookup = [:]

    var cut = PlaneCut()
    cut.height = h
    var edgePoint: [UInt64: Int32] = [:]
    func crossing(_ p: Int32, _ q: Int32) -> Int {
        let low = min(p, q), high = max(p, q)
        let key = UInt64(low) << 32 | UInt64(high)
        if let existing = edgePoint[key] { return Int(existing) }
        // Computed from the lower-numbered end, so both triangles sharing the edge get the same point.
        let a = SIMD3<Double>(points[Int(low)]), b = SIMD3<Double>(points[Int(high)])
        let s = (Double(h) - a.z) / (b.z - a.z)
        let point = SIMD3<Float>(Float(a.x + (b.x - a.x) * s), Float(a.y + (b.y - a.y) * s), h)
        edgePoint[key] = Int32(cut.cutPoints.count)
        cut.cutPoints.append(point)
        return cut.cutPoints.count - 1
    }
    var segments: [(Int, Int)] = []
    for t in 0..<count {
        if t % check == 0, isCancelled() { throw MeshFitError.stopped }
        let c = [ids[3 * t], ids[3 * t + 1], ids[3 * t + 2]]
        // A repeated corner has no surface and its edges pair with each other, so dropping it keeps the mesh closed.
        if c[0] == c[1] || c[1] == c[2] || c[0] == c[2] { continue }
        let p = c.map { points[Int($0)] }
        let above = p.map { $0.z > h }
        switch above.filter({ $0 }).count {
        case 3:
            cut.kept.append(contentsOf: p)
        case 1:
            let k = above.firstIndex(of: true)!
            let a = k, b = (k + 1) % 3, cc = (k + 2) % 3
            let ab = crossing(c[a], c[b]), ca = crossing(c[cc], c[a])
            cut.kept.append(contentsOf: [p[a], cut.cutPoints[ab], cut.cutPoints[ca]])
            segments.append((ab, ca))
        case 2:
            let k = above.firstIndex(of: false)!
            let cc = k, a = (k + 1) % 3, b = (k + 2) % 3
            let bc = crossing(c[b], c[cc]), ca = crossing(c[cc], c[a])
            cut.kept.append(contentsOf: [p[a], p[b], cut.cutPoints[bc], p[a], cut.cutPoints[bc], cut.cutPoints[ca]])
            segments.append((bc, ca))
        default:
            continue
        }
    }
    guard !segments.isEmpty, !cut.kept.isEmpty else { throw MeshFitError.invalidCutHeight }

    // Each crossing edge starts exactly one outline segment and ends one, so the segments chain into loops.
    var next = [Int](repeating: -1, count: cut.cutPoints.count)
    var incoming = [Int](repeating: 0, count: cut.cutPoints.count)
    for (start, end) in segments {
        guard next[start] < 0 else { throw MeshFitError.notClosedSolid }
        next[start] = end
        incoming[end] += 1
    }
    guard next.allSatisfy({ $0 >= 0 }), incoming.allSatisfy({ $0 == 1 }) else { throw MeshFitError.notClosedSolid }
    var visited = [Bool](repeating: false, count: cut.cutPoints.count)
    for start in 0..<cut.cutPoints.count where !visited[start] {
        var loop: [Int] = []
        var p = start
        while !visited[p] {
            visited[p] = true
            loop.append(p)
            p = next[p]
        }
        guard p == start, loop.count >= 3 else { throw MeshFitError.capFailed }
        cut.loops.append(loop)
    }
    return cut
}

// MARK: - Region triangulation

/// Work allowed for bridging holes and clipping ears in one region; bounds hostile or very detailed outlines.
let meshFitTriangulationWorkLimit = 400_000_000
/// Outline points allowed in one filled region.
let meshFitMaximumOutlinePoints = 200_000

/// Triangulates the planar region bounded by `loops` (indices into `points`). Loops wound anticlockwise are outer
/// boundaries; clockwise loops are holes, each assigned to the smallest outer boundary that contains it. Every loop
/// point is used, so the triangles meet the loops' edges exactly. Returns anticlockwise triangles.
func triangulatePlanarRegion(points: [SIMD2<Double>], loops: [[Int]], workLimit: Int = meshFitTriangulationWorkLimit,
                             isCancelled: () -> Bool = { false }) throws -> [SIMD3<Int32>] {
    guard loops.reduce(0, { $0 + $1.count }) <= meshFitMaximumOutlinePoints else { throw MeshFitError.crossSectionTooDetailed }
    func loopArea(_ loop: [Int]) -> Double {
        var sum = 0.0
        for i in loop.indices {
            let p = points[loop[i]], q = points[loop[(i + 1) % loop.count]]
            sum += p.x * q.y - q.x * p.y
        }
        return sum / 2
    }
    func contains(_ loop: [Int], _ point: SIMD2<Double>) -> Bool {
        var inside = false
        var j = loop.count - 1
        for i in loop.indices {
            let a = points[loop[i]], b = points[loop[j]]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
    let areas = loops.map(loopArea)
    guard areas.allSatisfy({ $0 != 0 && $0.isFinite }) else { throw MeshFitError.capFailed }
    let outers = loops.indices.filter { areas[$0] > 0 }
    var holesOf = [[Int]](repeating: [], count: loops.count)
    for hole in loops.indices where areas[hole] < 0 {
        let probe = points[loops[hole][0]]
        guard let owner = outers.filter({ contains(loops[$0], probe) }).min(by: { (areas[$0], $0) < (areas[$1], $1) }) else {
            throw MeshFitError.capFailed
        }
        holesOf[owner].append(hole)
    }

    var work = 0
    func spend(_ n: Int) throws {
        work += n
        if work > workLimit { throw MeshFitError.crossSectionTooDetailed }
    }
    var triangles: [SIMD3<Int32>] = []
    for outer in outers {
        if isCancelled() { throw MeshFitError.stopped }
        var polygon = loops[outer]
        // Rightmost holes first, as in Eberly's bridging, so each bridge reaches an already-merged boundary.
        let holes = holesOf[outer].sorted {
            let a = loops[$0].map { points[$0].x }.max()!, b = loops[$1].map { points[$0].x }.max()!
            return a != b ? a > b : $0 < $1
        }
        for (position, hole) in holes.enumerated() {
            polygon = try bridge(hole: loops[hole], into: polygon, pending: holes[(position + 1)...].map { loops[$0] },
                                 points: points, spend: spend)
        }
        try triangles.append(contentsOf: clipEars(polygon, points: points, spend: spend, isCancelled: isCancelled))
    }
    flipPlanarSlivers(&triangles, points: points)

    // Every triangle must be anticlockwise, and together they must cover exactly the region's area.
    var covered = 0.0
    for t in triangles {
        let area = signedArea2D(points[Int(t.x)], points[Int(t.y)], points[Int(t.z)])
        guard area > 0 else { throw MeshFitError.capFailed }
        covered += area
    }
    let expected = areas.reduce(0, +)
    let scale = areas.map(abs).reduce(0, +)
    guard abs(covered - expected) <= max(1e-9, 1e-7 * scale) else { throw MeshFitError.capFailed }
    return triangles
}

/// Zero-area by the mesh check's rule, with a margin for the rounding to Float when the triangle is written.
private func planarSliver(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
    let longest = max(simd_distance_squared(a, b), simd_distance_squared(b, c), simd_distance_squared(c, a))
    return abs(2 * signedArea2D(a, b, c)) <= 10 * meshHealthDegenerateRatio * longest
}

/// Removes slivers ear clipping was left with (its last triangle has no choice) by flipping the sliver's longest edge
/// with the triangle across it, when both new triangles are anticlockwise and not slivers themselves. Triangles are
/// visited in index order and edges found through lookups only, so the result is deterministic.
private func flipPlanarSlivers(_ triangles: inout [SIMD3<Int32>], points: [SIMD2<Double>]) {
    func key(_ p: Int32, _ q: Int32) -> UInt64 { UInt64(UInt32(p)) << 32 | UInt64(UInt32(q)) }
    func p(_ i: Int32) -> SIMD2<Double> { points[Int(i)] }
    var owner: [UInt64: Int] = [:]
    var shared = Set<UInt64>()
    func register(_ t: Int) {
        let v = triangles[t]
        for (a, b) in [(v.x, v.y), (v.y, v.z), (v.z, v.x)] {
            if owner[key(a, b)] != nil { shared.insert(key(a, b)) } else { owner[key(a, b)] = t }
        }
    }
    for t in triangles.indices { register(t) }
    for _ in 0..<3 {
        var flipped = false
        for t in triangles.indices {
            let v = triangles[t]
            guard planarSliver(p(v.x), p(v.y), p(v.z)) else { continue }
            let corners = [v.x, v.y, v.z]
            var j = 0, longest = -1.0
            for k in 0..<3 {
                let length = simd_distance_squared(p(corners[k]), p(corners[(k + 1) % 3]))
                if length > longest { longest = length; j = k }
            }
            let u = corners[j], w = corners[(j + 1) % 3], m = corners[(j + 2) % 3]
            // A repeated directed edge (only possible at a bridge's ends) is left alone.
            guard !shared.contains(key(w, u)), let n = owner[key(w, u)], n != t else { continue }
            let other = [triangles[n].x, triangles[n].y, triangles[n].z]
            guard let r = other.first(where: { $0 != u && $0 != w }), r != m else { continue }
            let first = SIMD3(u, r, m), second = SIMD3(r, w, m)
            guard signedArea2D(p(u), p(r), p(m)) > 0, signedArea2D(p(r), p(w), p(m)) > 0,
                  !planarSliver(p(u), p(r), p(m)), !planarSliver(p(r), p(w), p(m)) else { continue }
            for old in [t, n] {
                let o = triangles[old]
                for (a, b) in [(o.x, o.y), (o.y, o.z), (o.z, o.x)] where owner[key(a, b)] == old { owner[key(a, b)] = nil }
            }
            triangles[t] = first
            triangles[n] = second
            register(t)
            register(n)
            flipped = true
        }
        if !flipped { break }
    }
}

private func segmentsTouch(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
    func orient(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    func onSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        min(a.x, b.x) <= c.x && c.x <= max(a.x, b.x) && min(a.y, b.y) <= c.y && c.y <= max(a.y, b.y)
    }
    let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2), d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
    if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
    if d1 == 0, onSegment(q1, q2, p1) { return true }
    if d2 == 0, onSegment(q1, q2, p2) { return true }
    if d3 == 0, onSegment(p1, p2, q1) { return true }
    if d4 == 0, onSegment(p1, p2, q2) { return true }
    return false
}

/// Joins a hole to the polygon with a two-way cut from the hole's rightmost point to the nearest polygon point it can
/// see without touching any edge of the polygon, this hole or the holes still to be joined.
private func bridge(hole: [Int], into polygon: [Int], pending: [[Int]], points: [SIMD2<Double>],
                    spend: (Int) throws -> Void) throws -> [Int] {
    var start = 0
    for i in hole.indices {
        let p = points[hole[i]], best = points[hole[start]]
        if p.x > best.x || (p.x == best.x && p.y < best.y) { start = i }
    }
    let m = points[hole[start]]
    var edges: [(SIMD2<Double>, SIMD2<Double>)] = []
    for loop in [polygon, hole] + pending {
        for i in loop.indices { edges.append((points[loop[i]], points[loop[(i + 1) % loop.count]])) }
    }
    let candidates = polygon.indices.sorted {
        let a = simd_distance_squared(points[polygon[$0]], m), b = simd_distance_squared(points[polygon[$1]], m)
        return a != b ? a < b : $0 < $1
    }
    for candidate in candidates {
        let target = points[polygon[candidate]]
        guard target != m else { continue }
        try spend(edges.count)
        let blocked = edges.contains { edge in
            // Edges ending at either end of the bridge can only meet it there.
            if edge.0 == m || edge.1 == m || edge.0 == target || edge.1 == target { return false }
            return segmentsTouch(m, target, edge.0, edge.1)
        }
        guard !blocked else { continue }
        let rotated = Array(hole[start...] + hole[..<start])
        var merged = Array(polygon[...candidate])
        merged.append(contentsOf: rotated)
        merged.append(hole[start])
        merged.append(polygon[candidate])
        merged.append(contentsOf: polygon[(candidate + 1)...])
        return merged
    }
    throw MeshFitError.capFailed
}

/// Ear clipping for an anticlockwise, weakly simple polygon (bridged holes repeat points). Only corners that aren't
/// strictly convex can lie inside an ear; they're found through a uniform grid so large outlines stay fast.
private func clipEars(_ polygon: [Int], points: [SIMD2<Double>], spend: (Int) throws -> Void,
                      isCancelled: () -> Bool) throws -> [SIMD3<Int32>] {
    let n = polygon.count
    guard n >= 3 else { throw MeshFitError.capFailed }
    var prev = (0..<n).map { ($0 + n - 1) % n }
    var next = (0..<n).map { ($0 + 1) % n }
    var removed = [Bool](repeating: false, count: n)
    func position(_ i: Int) -> SIMD2<Double> { points[polygon[i]] }
    func isConvex(_ i: Int) -> Bool { signedArea2D(position(prev[i]), position(i), position(next[i])) > 0 }

    var low = SIMD2<Double>(repeating: .greatestFiniteMagnitude), high = -low
    for i in 0..<n { low = simd_min(low, position(i)); high = simd_max(high, position(i)) }
    let side = max(1, Int(Double(n).squareRoot() / 2))
    let span = simd_max(high - low, SIMD2(repeating: 1e-12))
    func cell(_ p: SIMD2<Double>) -> SIMD2<Int> {
        let c = (p - low) / span * Double(side)
        return SIMD2(min(max(Int(c.x), 0), side - 1), min(max(Int(c.y), 0), side - 1))
    }
    var grid = [[Int]](repeating: [], count: side * side)
    for i in 0..<n where !isConvex(i) {
        let c = cell(position(i))
        grid[c.y * side + c.x].append(i)
    }

    /// While true, ears that would be zero-area by the mesh check's rule (with a margin, since coordinates are rounded
    /// to Float when written) are passed over, so the triangulation doesn't add slivers the model didn't have. Only a
    /// full lap without any other ear allows one.
    var avoidSlivers = true

    func isEar(_ i: Int) throws -> Bool {
        guard isConvex(i) else { return false }
        let a = position(prev[i]), b = position(i), c = position(next[i])
        if avoidSlivers, planarSliver(a, b, c) { return false }
        let lo = cell(simd_min(a, simd_min(b, c))), hi = cell(simd_max(a, simd_max(b, c)))
        for y in lo.y...hi.y {
            for x in lo.x...hi.x {
                let bucket = grid[y * side + x]
                try spend(bucket.count + 1)
                for j in bucket where !removed[j] && j != prev[i] && j != i && j != next[i] {
                    let p = position(j)
                    // Repeated bridge points sit on the corners; they can't make the ear overlap anything.
                    if p == a || p == b || p == c { continue }
                    if signedArea2D(a, b, p) >= 0 && signedArea2D(b, c, p) >= 0 && signedArea2D(c, a, p) >= 0 { return false }
                }
            }
        }
        return true
    }

    var triangles: [SIMD3<Int32>] = []
    triangles.reserveCapacity(n - 2)
    var remaining = n
    var i = 0
    var failures = 0
    while remaining > 3 {
        if triangles.count % 4096 == 0, isCancelled() { throw MeshFitError.stopped }
        if try isEar(i) {
            triangles.append(SIMD3(Int32(polygon[prev[i]]), Int32(polygon[i]), Int32(polygon[next[i]])))
            removed[i] = true
            let before = prev[i], after = next[i]
            next[before] = after
            prev[after] = before
            remaining -= 1
            failures = 0
            avoidSlivers = true
            i = before
        } else {
            failures += 1
            if failures > remaining, avoidSlivers {
                // Only slivers are left to clip: allow one, then go back to avoiding them.
                avoidSlivers = false
                failures = 0
            }
            // A full lap without an ear: the outline crosses itself.
            guard failures <= remaining else { throw MeshFitError.capFailed }
            i = next[i]
        }
    }
    triangles.append(SIMD3(Int32(polygon[prev[i]]), Int32(polygon[i]), Int32(polygon[next[i]])))
    return triangles
}

// MARK: - Assembling results

private func flattened(_ corners: [SIMD3<Float>]) -> [Float] {
    var floats: [Float] = []
    floats.reserveCapacity(corners.count * 3)
    for p in corners { floats.append(p.x); floats.append(p.y); floats.append(p.z) }
    return floats
}

/// Writes the binary STL, parses it back and requires a closed, consistently oriented, outward-facing solid with no
/// more zero-area triangles than the model had (`inputZeroArea`) and no more separate parts (`inputShells`).
private func checkedResult(_ corners: [SIMD3<Float>], cutHeight: Float, contact: Double, inputZeroArea: Int, inputShells: Int,
                           isCancelled: () -> Bool) throws -> MeshFitResult {
    guard corners.count / 3 <= STLMesh.maximumTriangles else { throw MeshFitError.tooManyTriangles }
    let assembled = try STLMesh.validated(flattened(corners))
    let data = assembled.binarySTL()
    let parsed = try STLMesh.parse(data)
    guard parsed.triangleCount == corners.count / 3 else { throw MeshFitError.resultNotClosed }
    guard let report = analyzeMeshHealth(parsed, isCancelled: isCancelled) else { throw MeshFitError.stopped }
    if let problem = meshFitResultProblem(report, inputZeroArea: inputZeroArea, inputShells: inputShells) { throw problem }
    return MeshFitResult(mesh: parsed, data: data, cutHeightMM: cutHeight, contactAreaMM2: contact)
}

/// Why a fit tool's result can't be saved: not a closed, consistently oriented, outward-facing solid, or more zero-area
/// triangles than the model had, or more separate parts (a base sealing slots that opened through the bed face into
/// closed cavities, which Slant bills as bodies). Nil when it can.
func meshFitResultProblem(_ report: MeshHealthReport, inputZeroArea: Int, inputShells: Int = .max) -> MeshFitError? {
    guard report.isClosed, report.isConsistentlyOriented, report.signedVolume > 0 else { return .resultNotClosed }
    guard report.degenerateTriangles <= inputZeroArea else { return .addedZeroAreaTriangles }
    guard report.shells <= inputShells else { return .addedParts }
    return nil
}

/// Cap triangles for a cut, facing down. The outline loops run the way the kept surface's open edges do; the cap
/// runs them backwards so every edge pairs up, and is triangulated mirrored so its triangles face −Z.
private func capTriangles(_ cut: PlaneCut, isCancelled: () -> Bool) throws -> (corners: [SIMD3<Float>], area: Double) {
    let mirrored = cut.cutPoints.map { SIMD2<Double>(-Double($0.x), Double($0.y)) }
    let loops = cut.loops.map { Array($0.reversed()) }
    let triangles = try triangulatePlanarRegion(points: mirrored, loops: loops, isCancelled: isCancelled)
    var corners: [SIMD3<Float>] = []
    corners.reserveCapacity(triangles.count * 3)
    var area = 0.0
    for t in triangles {
        corners.append(cut.cutPoints[Int(t.x)]); corners.append(cut.cutPoints[Int(t.y)]); corners.append(cut.cutPoints[Int(t.z)])
        area += signedArea2D(mirrored[Int(t.x)], mirrored[Int(t.y)], mirrored[Int(t.z)])
    }
    return (corners, area)
}

extension STLMesh {
    /// Cuts the model `cutHeightMM` above its lowest point and fills the cut, so it sits on a flat face. Needs a closed,
    /// outward-facing mesh. Coordinates are kept: the new base is at the cut's height, not moved to zero.
    func flatBaseCopy(cutHeightMM: Float, isCancelled: () -> Bool = { false }) throws -> MeshFitResult {
        let input = try requireClosedSolid(self, isCancelled: isCancelled)
        let cut = try planeCut(self, height: cutHeightMM, isCancelled: isCancelled)
        let cap = try capTriangles(cut, isCancelled: isCancelled)
        return try checkedResult(cut.kept + cap.corners, cutHeight: cut.height - minimum.z, contact: cap.area,
                                 inputZeroArea: input.degenerateTriangles, inputShells: input.shells, isCancelled: isCancelled)
    }
}

// MARK: - Plinth

enum PlinthShape: String, CaseIterable, Identifiable, Codable, Sendable {
    case round = "Round", rectangular = "Rectangular"
    var id: String { rawValue }
}

struct PlinthSettings: Equatable, Codable, Sendable {
    var shape: PlinthShape = .round
    /// Extra width around the model's whole footprint, on every side.
    var marginMM: Float = 3
    var thicknessMM: Float = 3
    /// How far the model sinks into the plinth: the cut height above its lowest point.
    var joinDepthMM: Float = 0.5
    /// Sides of a round plinth.
    static let segments = 64
    /// The 45° chamfer round the plinth's bottom edge, against the first layers' spread.
    static let bottomChamferMM: Float = 0.5
}

/// The plinth's outline moved in by `inset` on every side: the rectangle's corners move diagonally, and the round
/// plinth's corners move towards its centre so each flat side moves in by `inset`.
func plinthChamferOutline(_ outline: [SIMD2<Double>], shape: PlinthShape, inset: Double) -> [SIMD2<Double>] {
    switch shape {
    case .rectangular:
        guard outline.count == 4 else { return outline }
        return [outline[0] + SIMD2(inset, inset), outline[1] + SIMD2(-inset, inset),
                outline[2] + SIMD2(-inset, -inset), outline[3] + SIMD2(inset, -inset)]
    case .round:
        guard !outline.isEmpty else { return outline }
        let centre = outline.reduce(SIMD2<Double>(), +) / Double(outline.count)
        let step = inset / cos(Double.pi / Double(outline.count))
        return outline.map { centre + simd_normalize($0 - centre) * (simd_length($0 - centre) - step) }
    }
}

func plinthSettingsProblem(_ settings: PlinthSettings) -> String? {
    if !(settings.marginMM >= 1 && settings.marginMM <= 30) { return "Choose a margin from 1 to 30 mm." }
    if !(settings.thicknessMM >= 1 && settings.thicknessMM <= 20) { return "Choose a plinth thickness from 1 to 20 mm." }
    if !(settings.joinDepthMM >= 0.1 && settings.joinDepthMM <= 10) { return "Choose a join depth from 0.1 to 10 mm." }
    return nil
}

extension STLMesh {
    /// Sinks the model `joinDepthMM` into a slab or disc that covers its whole footprint plus the margin, joined into one
    /// closed solid: the plinth's top is the cut outline's surroundings, so no overlapping shells are written.
    func plinthCopy(_ settings: PlinthSettings, isCancelled: () -> Bool = { false }) throws -> MeshFitResult {
        if let problem = plinthSettingsProblem(settings) { throw MeshFitError.invalidPlinth(problem) }
        guard settings.joinDepthMM < (maximum.z - minimum.z) / 2 else {
            throw MeshFitError.invalidPlinth("Choose a join depth less than half the model’s height.")
        }
        let input = try requireClosedSolid(self, isCancelled: isCancelled)
        let cut = try planeCut(self, height: settings.joinDepthMM, isCancelled: isCancelled)
        let top = cut.height, bottom = cut.height - settings.thicknessMM

        var low = SIMD2<Double>(repeating: .greatestFiniteMagnitude), high = -low
        for p in cut.kept { low = simd_min(low, SIMD2(Double(p.x), Double(p.y))); high = simd_max(high, SIMD2(Double(p.x), Double(p.y))) }
        let margin = Double(settings.marginMM)
        var outline: [SIMD2<Double>] = []
        switch settings.shape {
        case .rectangular:
            outline = [SIMD2(low.x - margin, low.y - margin), SIMD2(high.x + margin, low.y - margin),
                       SIMD2(high.x + margin, high.y + margin), SIMD2(low.x - margin, high.y + margin)]
        case .round:
            let centre = (low + high) / 2
            var reach = 0.0
            for p in cut.kept { reach = max(reach, simd_distance(SIMD2(Double(p.x), Double(p.y)), centre)) }
            // Circumscribed, so the flat sides still clear the model by the margin.
            let n = PlinthSettings.segments
            let radius = (reach + margin) / cos(Double.pi / Double(n))
            outline = (0..<n).map { i in
                let angle = 2 * Double.pi * Double(i) / Double(n)
                return centre + SIMD2(cos(angle), sin(angle)) * radius
            }
        }
        // Round to the Float coordinates that are written, so the triangulation sees the same points.
        let rim = outline.map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        let n = rim.count

        // Top: the outline with the model's outline loops (run backwards) as holes and islands, facing +Z.
        var planar = rim.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        planar.append(contentsOf: cut.cutPoints.map { SIMD2<Double>(Double($0.x), Double($0.y)) })
        let loops = [Array(0..<n)] + cut.loops.map { $0.reversed().map { $0 + n } }
        let topTriangles = try triangulatePlanarRegion(points: planar, loops: loops, isCancelled: isCancelled)
        func topPoint(_ index: Int32) -> SIMD3<Float> {
            let i = Int(index)
            return i < n ? SIMD3(rim[i].x, rim[i].y, top) : cut.cutPoints[i - n]
        }
        var corners = cut.kept
        for t in topTriangles { corners.append(topPoint(t.x)); corners.append(topPoint(t.y)); corners.append(topPoint(t.z)) }
        // Sides: each outline edge a → b as two outward-facing triangles, down to where the bottom chamfer starts.
        let chamfer = PlinthSettings.bottomChamferMM
        let ledge = bottom + chamfer
        for i in 0..<n {
            let a = rim[i], b = rim[(i + 1) % n]
            let aTop = SIMD3(a.x, a.y, top), bTop = SIMD3(b.x, b.y, top)
            let aLow = SIMD3(a.x, a.y, ledge), bLow = SIMD3(b.x, b.y, ledge)
            corners.append(contentsOf: [aLow, bLow, bTop, aLow, bTop, aTop])
        }
        // The 45° chamfer: the outline moved in by `chamfer` on every side at the very bottom, so the first layers'
        // spread ("elephant's foot") stays inside the plinth's outline.
        let foot = plinthChamferOutline(outline, shape: settings.shape, inset: Double(chamfer))
            .map { SIMD2<Float>(Float($0.x), Float($0.y)) }
        for i in 0..<n {
            let a = rim[i], b = rim[(i + 1) % n], c = foot[i], d = foot[(i + 1) % n]
            let aLow = SIMD3(a.x, a.y, ledge), bLow = SIMD3(b.x, b.y, ledge)
            let cBottom = SIMD3(c.x, c.y, bottom), dBottom = SIMD3(d.x, d.y, bottom)
            corners.append(contentsOf: [cBottom, dBottom, bLow, cBottom, bLow, aLow])
        }
        // Underside: a fan over the convex chamfered outline, facing −Z.
        for i in 1..<(n - 1) {
            corners.append(contentsOf: [SIMD3(foot[0].x, foot[0].y, bottom), SIMD3(foot[i + 1].x, foot[i + 1].y, bottom),
                                        SIMD3(foot[i].x, foot[i].y, bottom)])
        }
        let footPlanar = foot.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        var underside = 0.0
        for i in 1..<(n - 1) { underside += signedArea2D(footPlanar[0], footPlanar[i], footPlanar[i + 1]) }
        let result = try checkedResult(corners, cutHeight: cut.height - minimum.z, contact: underside,
                                       inputZeroArea: input.degenerateTriangles, inputShells: input.shells, isCancelled: isCancelled)
        guard result.fitsBuildVolume else { throw MeshFitError.exceedsBuildVolume(largestMM: result.sizeMM.max()) }
        return result
    }
}

/// "Owl (flat base)", in the style of the other round 6 copies ("(repaired)", "(reviewed)").
func flatBaseCopyName(_ name: String) -> String { "\(meshFitCopyBaseName(name)) (flat base)" }
func plinthCopyName(_ name: String) -> String { "\(meshFitCopyBaseName(name)) (plinth)" }

/// The library name without a model file extension or surrounding spaces; "Model" when nothing is left.
func meshFitCopyBaseName(_ name: String) -> String {
    let base = meshFitBaseName(name).trimmingCharacters(in: .whitespacesAndNewlines)
    return base.isEmpty ? "Model" : base
}

// MARK: - Ray index

/// A bounding-volume hierarchy over a mesh's triangles for nearest-hit ray queries. Triangles are ordered by the
/// Morton code of their centroid (ties by index) and split at the middle of each range, so the tree depends only on
/// the mesh.
struct TriangleRayIndex: Sendable {
    private let a: [SIMD3<Float>], b: [SIMD3<Float>], c: [SIMD3<Float>]
    private let order: [Int32]
    private var low: [SIMD3<Float>] = [], high: [SIMD3<Float>] = []
    /// Leaves: start into `order` (≥ 0) and count; internal nodes: −1 and the right child (the left child follows).
    private var start: [Int32] = [], extra: [Int32] = []
    static let leafSize = 4

    init?(_ mesh: STLMesh, isCancelled: () -> Bool = { false }) {
        let count = mesh.triangleCount
        guard count > 0 else { return nil }
        var a = [SIMD3<Float>](), b = [SIMD3<Float>](), c = [SIMD3<Float>]()
        a.reserveCapacity(count); b.reserveCapacity(count); c.reserveCapacity(count)
        for t in 0..<count {
            a.append(mesh.corner(t, 0)); b.append(mesh.corner(t, 1)); c.append(mesh.corner(t, 2))
        }
        if isCancelled() { return nil }
        let span = simd_max(mesh.maximum - mesh.minimum, SIMD3(repeating: 1e-12))
        func spread(_ value: UInt32) -> UInt64 {
            var x = UInt64(value) & 0x1fffff
            x = (x | x << 32) & 0x1f00000000ffff
            x = (x | x << 16) & 0x1f0000ff0000ff
            x = (x | x << 8) & 0x100f00f00f00f00f
            x = (x | x << 4) & 0x10c30c30c30c30c3
            x = (x | x << 2) & 0x1249249249249249
            return x
        }
        var keys = [UInt64](repeating: 0, count: count)
        for t in 0..<count {
            let centroid = ((a[t] + b[t] + c[t]) / 3 - mesh.minimum) / span
            let q = simd_clamp(centroid, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 1_048_575
            keys[t] = spread(UInt32(q.x)) | spread(UInt32(q.y)) << 1 | spread(UInt32(q.z)) << 2
        }
        let order = (0..<Int32(count)).sorted { keys[Int($0)] != keys[Int($1)] ? keys[Int($0)] < keys[Int($1)] : $0 < $1 }
        if isCancelled() { return nil }
        self.a = a; self.b = b; self.c = c; self.order = order
        build(0, count)
    }

    @discardableResult
    private mutating func build(_ from: Int, _ to: Int) -> Int {
        let node = low.count
        low.append(.zero); high.append(.zero); start.append(-1); extra.append(0)
        if to - from <= Self.leafSize {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for k in from..<to {
                let t = Int(order[k])
                lo = simd_min(lo, simd_min(a[t], simd_min(b[t], c[t])))
                hi = simd_max(hi, simd_max(a[t], simd_max(b[t], c[t])))
            }
            low[node] = lo; high[node] = hi
            start[node] = Int32(from); extra[node] = Int32(to - from)
        } else {
            let middle = (from + to) / 2
            let left = build(from, middle)
            let right = build(middle, to)
            low[node] = simd_min(low[left], low[right]); high[node] = simd_max(high[left], high[right])
            extra[node] = Int32(right)
        }
        return node
    }

    struct Hit: Equatable, Sendable {
        let distance: Float
        let triangle: Int
        /// The hit triangle's unit normal (zero for a degenerate triangle).
        let normal: SIMD3<Float>
    }

    /// The nearest triangle the ray meets beyond `minimumDistance`, ignoring `skipping`; equal distances go to the
    /// lower triangle index.
    func firstHit(from origin: SIMD3<Float>, along direction: SIMD3<Float>, minimumDistance: Float = 0,
                  skipping: Int = -1) -> Hit? {
        let inverse = SIMD3<Float>(1 / direction.x, 1 / direction.y, 1 / direction.z)
        // Axes the ray doesn't move along. Their slab is all or nothing: the ray is inside it for its whole length
        // when the origin lies within the box on that axis, edges included, and never otherwise. Computing it as
        // (bound − origin) × ∞ gives NaN (0 × ∞) for an origin exactly in a box face's plane, which `simd_min` and
        // `simd_max` replace with the other bound's ±∞, so that box used to be dropped.
        let stillX = direction.x == 0, stillY = direction.y == 0, stillZ = direction.z == 0
        let ox = origin.x, oy = origin.y, oz = origin.z, ix = inverse.x, iy = inverse.y, iz = inverse.z
        // fmin and fmax, as `simd_min` and `simd_max` work lane by lane: a NaN gives way to the other value. Written out
        // with the slab test because the generic SIMD operators are slow in unoptimised builds.
        func smaller(_ a: Float, _ b: Float) -> Float { a.isNaN ? b : (b.isNaN ? a : (b < a ? b : a)) }
        func larger(_ a: Float, _ b: Float) -> Float { a.isNaN ? b : (b.isNaN ? a : (b > a ? b : a)) }
        var best = Float.infinity, bestTriangle = -1
        // A stack on the stack, not the heap: this runs for every query.
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 64) { stack in
            var depth = 1
            stack[0] = 0
            while depth > 0 {
                depth -= 1
                let node = stack[depth]
                // Slab test, inclusive at the box faces.
                let lo = low[node], hi = high[node]
                var near = -Float.infinity, far = Float.infinity
                if stillX {
                    guard ox >= lo.x, ox <= hi.x else { continue }
                } else {
                    let t0 = (lo.x - ox) * ix, t1 = (hi.x - ox) * ix
                    near = larger(near, smaller(t0, t1)); far = smaller(far, larger(t0, t1))
                }
                if stillY {
                    guard oy >= lo.y, oy <= hi.y else { continue }
                } else {
                    let t0 = (lo.y - oy) * iy, t1 = (hi.y - oy) * iy
                    near = larger(near, smaller(t0, t1)); far = smaller(far, larger(t0, t1))
                }
                if stillZ {
                    guard oz >= lo.z, oz <= hi.z else { continue }
                } else {
                    let t0 = (lo.z - oz) * iz, t1 = (hi.z - oz) * iz
                    near = larger(near, smaller(t0, t1)); far = smaller(far, larger(t0, t1))
                }
                guard !(near > far), !(far < minimumDistance), !(near > best) else { continue }
                if start[node] >= 0 {
                    for k in Int(start[node])..<Int(start[node] + extra[node]) {
                        let t = Int(order[k])
                        guard t != skipping, let distance = intersect(t, origin, direction),
                              distance > minimumDistance, distance < best || (distance == best && t < bestTriangle) else { continue }
                        best = distance
                        bestTriangle = t
                    }
                } else if depth + 2 <= stack.count {
                    stack[depth] = Int(extra[node]); stack[depth + 1] = node + 1
                    depth += 2
                }
            }
        }
        guard bestTriangle >= 0 else { return nil }
        let cross = simd_cross(b[bestTriangle] - a[bestTriangle], c[bestTriangle] - a[bestTriangle])
        let length = simd_length(cross)
        return Hit(distance: best, triangle: bestTriangle, normal: length > 0 ? cross / length : .zero)
    }

    /// Möller–Trumbore, both sides, with a hair of tolerance so rays through shared edges aren't lost.
    private func intersect(_ t: Int, _ origin: SIMD3<Float>, _ direction: SIMD3<Float>) -> Float? {
        let e1 = b[t] - a[t], e2 = c[t] - a[t]
        let p = simd_cross(direction, e2)
        let det = simd_dot(e1, p)
        guard abs(det) > 1e-20 else { return nil }
        let inv = 1 / det
        let s = origin - a[t]
        let u = simd_dot(s, p) * inv
        guard u >= -1e-6, u <= 1 + 1e-6 else { return nil }
        let q = simd_cross(s, e1)
        let v = simd_dot(direction, q) * inv
        guard v >= -1e-6, u + v <= 1 + 1e-6 else { return nil }
        let distance = simd_dot(e2, q) * inv
        return distance.isFinite ? distance : nil
    }
}

// MARK: - Wall thickness

struct ThinSpot: Equatable, Sendable {
    let point: SIMD3<Float>
    let thicknessMM: Float
}

/// A cluster of thin readings that are also narrow across, such as a pin, spike or small tab.
struct SmallFeature: Equatable, Sendable {
    let centre: SIMD3<Float>
    let thinnestMM: Float
    /// The narrowest extent measured across the feature, through the middle of the wall.
    let widthMM: Float
    let samples: Int
}

struct ThicknessBand: Equatable, Sendable {
    let lowerMM: Float
    /// Nil for the open-ended top band.
    let upperMM: Float?
    /// Share of the measured surface.
    let fraction: Double
}

struct WallThicknessReport: Equatable, Sendable {
    let sampleCount: Int
    let measuredCount: Int
    let surfaceAreaMM2: Double
    let thinnestMM: Float?
    let percentile5MM: Float?
    let medianMM: Float?
    /// Shares of the measured surface.
    let fractionUnder1MM: Double
    let fractionUnder2MM: Double
    let bands: [ThicknessBand]
    /// Readings under 2 mm, in sample order, for highlighting.
    let thinSpots: [ThinSpot]
    let smallFeatures: [SmallFeature]
    var measuredFraction: Double { sampleCount == 0 ? 0 : Double(measuredCount) / Double(sampleCount) }
}

let wallThicknessMaximumSamples = 20_000
let wallThicknessBandEdgesMM: [Float] = [0.5, 1, 1.5, 2, 3]
/// Readings thinner than this are checked for being narrow across as well (pins are best at 3–5 mm or more).
let smallFeatureThresholdMM: Float = 3
let smallFeatureClusterRadiusMM: Float = 5
let smallFeatureMaximumClusters = 100
let smallFeatureMaximumReported = 10

/// The surface's local thickness, measured by casting a ray inward along the face normal from evenly spread sample
/// points to the far side of the wall. Samples are placed by cumulative area in triangle order and a fixed
/// low-discrepancy sequence, so a mesh always gives the same report. Readings are skipped where the ray escapes or
/// meets a face pointing the wrong way (open or overlapping meshes). Returns nil when `isCancelled` reports true.
/// Advisory only; units are read as millimetres.
func analyzeWallThickness(_ mesh: STLMesh, maximumSamples: Int = wallThicknessMaximumSamples,
                          progress: (Double) -> Void = { _ in }, isCancelled: () -> Bool = { false }) -> WallThicknessReport? {
    let count = mesh.triangleCount
    var areas = [Double](repeating: 0, count: count)
    var total = 0.0
    for t in 0..<count {
        let a = SIMD3<Double>(mesh.corner(t, 0)), b = SIMD3<Double>(mesh.corner(t, 1)), c = SIMD3<Double>(mesh.corner(t, 2))
        let area = simd_length(simd_cross(b - a, c - a)) / 2
        areas[t] = area.isFinite ? area : 0
        total += areas[t]
    }
    let sampleCount = total > 0 ? max(1, min(maximumSamples, 1_000_000)) : 0
    guard sampleCount > 0 else {
        return WallThicknessReport(sampleCount: 0, measuredCount: 0, surfaceAreaMM2: 0, thinnestMM: nil, percentile5MM: nil,
                                   medianMM: nil, fractionUnder1MM: 0, fractionUnder2MM: 0, bands: [], thinSpots: [], smallFeatures: [])
    }
    progress(0)
    guard let index = TriangleRayIndex(mesh, isCancelled: isCancelled), !isCancelled() else { return nil }
    let tolerance = max(Float(1e-5), 1e-6 * (mesh.maximum - mesh.minimum).max())

    var readings: [Float] = []
    readings.reserveCapacity(sampleCount)
    var thinSpots: [ThinSpot] = []
    struct Cluster { var sum: SIMD3<Double>; var count: Int; var thinnest: Float; var width: Float; var first: Int }
    var clusters: [Cluster] = []
    var triangle = 0
    var cumulative = 0.0
    for k in 0..<sampleCount {
        if k % 256 == 0 {
            if isCancelled() { return nil }
            progress(Double(k) / Double(sampleCount))
        }
        let position = (Double(k) + 0.5) * total / Double(sampleCount)
        while triangle < count - 1, cumulative + areas[triangle] < position {
            cumulative += areas[triangle]
            triangle += 1
        }
        while triangle < count - 1, areas[triangle] == 0 { triangle += 1 }
        let a = mesh.corner(triangle, 0), b = mesh.corner(triangle, 1), c = mesh.corner(triangle, 2)
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        guard length > 0, length.isFinite else { continue }
        let normal = cross / length
        // R2 sequence (Roberts), reflected into the triangle.
        var u = Float((0.5 + Double(k) * 0.7548776662466927).truncatingRemainder(dividingBy: 1))
        var v = Float((0.5 + Double(k) * 0.5698402909980532).truncatingRemainder(dividingBy: 1))
        if u + v > 1 { u = 1 - u; v = 1 - v }
        let point = a + (b - a) * u + (c - a) * v
        guard let hit = index.firstHit(from: point, along: -normal, minimumDistance: tolerance, skipping: triangle),
              simd_dot(hit.normal, -normal) > 0 else { continue }
        let thickness = hit.distance
        readings.append(thickness)
        if thickness < 2 { thinSpots.append(ThinSpot(point: point, thicknessMM: thickness)) }
        guard thickness < smallFeatureThresholdMM else { continue }

        // Narrow across as well? Measure through the middle of the wall in four directions along the surface. Only
        // chords between roughly opposite faces count, so a line cutting off the corner of a wide, thin plate isn't
        // mistaken for a pin.
        let middle = point - normal * (thickness / 2)
        let helper: SIMD3<Float> = abs(normal.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
        let tangent = simd_normalize(simd_cross(normal, helper)), bitangent = simd_cross(normal, tangent)
        var width = Float.infinity
        for angle in [Float(0), .pi / 4, .pi / 2, 3 * .pi / 4] {
            let direction = tangent * cos(angle) + bitangent * sin(angle)
            guard let forward = index.firstHit(from: middle, along: direction),
                  let backward = index.firstHit(from: middle, along: -direction),
                  simd_dot(forward.normal, backward.normal) < -0.5 else { continue }
            width = min(width, forward.distance + backward.distance)
        }
        guard width < smallFeatureThresholdMM else { continue }
        let location = SIMD3<Double>(point)
        if let match = clusters.indices.first(where: {
            simd_distance(clusters[$0].sum / Double(clusters[$0].count), location) <= Double(smallFeatureClusterRadiusMM)
        }) {
            clusters[match].sum += location
            clusters[match].count += 1
            clusters[match].thinnest = min(clusters[match].thinnest, thickness)
            clusters[match].width = min(clusters[match].width, width)
        } else if clusters.count < smallFeatureMaximumClusters {
            clusters.append(Cluster(sum: location, count: 1, thinnest: thickness, width: width, first: k))
        }
    }
    if isCancelled() { return nil }
    progress(1)

    let measured = readings.count
    let sorted = readings.sorted()
    func share(_ test: (Float) -> Bool) -> Double { measured == 0 ? 0 : Double(readings.filter(test).count) / Double(measured) }
    var bands: [ThicknessBand] = []
    var lower: Float = 0
    for edge in wallThicknessBandEdgesMM + [Float.infinity] {
        let low = lower
        bands.append(ThicknessBand(lowerMM: low, upperMM: edge.isFinite ? edge : nil,
                                   fraction: share { $0 >= low && $0 < edge }))
        lower = edge
    }
    func percentile(_ p: Double) -> Float? {
        sorted.isEmpty ? nil : sorted[min(sorted.count - 1, Int((Double(sorted.count - 1) * p).rounded()))]
    }
    let features = clusters
        .sorted { ($0.thinnest, $0.first) < ($1.thinnest, $1.first) }
        .prefix(smallFeatureMaximumReported)
        .map { SmallFeature(centre: SIMD3<Float>($0.sum / Double($0.count)), thinnestMM: $0.thinnest, widthMM: $0.width, samples: $0.count) }
    return WallThicknessReport(sampleCount: sampleCount, measuredCount: measured, surfaceAreaMM2: total,
                               thinnestMM: sorted.first, percentile5MM: percentile(0.05), medianMM: percentile(0.5),
                               fractionUnder1MM: share { $0 < 1 }, fractionUnder2MM: share { $0 < 2 },
                               bands: bands, thinSpots: thinSpots, smallFeatures: Array(features))
}

// MARK: - Thickness summary copy

struct WallThicknessSummary: Equatable {
    /// The one line shown after a check.
    let line: String
    let details: [String]
    /// True when the measured surface has no readings under 2 mm and most of it could be measured.
    let isClear: Bool
}

func percentLabel(_ fraction: Double) -> String {
    if fraction <= 0 { return "0%" }
    if fraction < 0.01 { return "under 1%" }
    return "\(Int((fraction * 100).rounded()))%"
}

private func millimetres(_ value: Float) -> String { String(format: "%.1f mm", value) }

func wallThicknessSummary(_ report: WallThicknessReport, origin: SIMD3<Float> = .zero) -> WallThicknessSummary {
    guard report.sampleCount > 0 else {
        return WallThicknessSummary(line: "Wall thickness: nothing to measure", details: [], isClear: false)
    }
    guard report.measuredFraction >= 0.5 else {
        return WallThicknessSummary(
            line: "Wall thickness: couldn’t measure most of the surface",
            details: ["\(percentLabel(1 - report.measuredFraction)) of the sample points had no far wall to measure to. The mesh is probably open, inside out or made of overlapping parts; the mesh check above lists what to repair."],
            isClear: false)
    }
    let line: String
    if report.fractionUnder2MM == 0 {
        line = "Wall thickness: no walls under 2 mm found"
    } else if report.fractionUnder1MM == 0 {
        line = "Wall thickness: \(percentLabel(report.fractionUnder2MM)) of the surface under 2 mm"
    } else {
        line = "Wall thickness: \(percentLabel(report.fractionUnder1MM)) under 1 mm, \(percentLabel(report.fractionUnder2MM)) under 2 mm"
    }
    var details: [String] = []
    if let thinnest = report.thinnestMM, let median = report.medianMM {
        details.append("Thinnest reading \(String(format: "%.2f mm", thinnest)); typical (median) \(millimetres(median)).")
    }
    if report.fractionUnder1MM > 0 {
        details.append("Walls under 1 mm may not print, or may break. Thicken them in your CAD tool.")
    }
    if report.fractionUnder2MM > 0 {
        details.append("Where the part carries load, aim for walls of 2 mm or more.")
    }
    for feature in report.smallFeatures.prefix(3) {
        let at = feature.centre - origin
        details.append("Small feature (such as a pin or spike) about \(millimetres(feature.widthMM)) across near X \(String(format: "%.0f", at.x)), Y \(String(format: "%.0f", at.y)), Z \(String(format: "%.0f", at.z)); thinnest \(millimetres(feature.thinnestMM)). Pins and posts print best at 3–5 mm or more.")
    }
    if report.smallFeatures.count > 3 {
        details.append("\(report.smallFeatures.count - 3) more small features found.")
    }
    if report.measuredFraction < 0.98 {
        details.append("\(percentLabel(1 - report.measuredFraction)) of the sample points couldn’t be measured, usually where the mesh is open or parts overlap.")
    }
    return WallThicknessSummary(line: line, details: details,
                                isClear: report.fractionUnder2MM == 0 && report.smallFeatures.isEmpty && report.measuredFraction >= 0.98)
}

/// Band rows for the breakdown, such as "1.0–1.5 mm · 3%".
func wallThicknessBandLabel(_ band: ThicknessBand) -> String {
    let range = band.upperMM.map { "\(String(format: "%.1f", band.lowerMM))–\(String(format: "%.1f", $0)) mm" }
        ?? "\(String(format: "%.1f", band.lowerMM)) mm or more"
    return "\(range) · \(percentLabel(band.fraction))"
}
