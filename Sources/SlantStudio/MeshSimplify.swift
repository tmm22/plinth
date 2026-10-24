import Foundation
import simd

// Quadric error metric edge-collapse decimation (Garland & Heckbert). Deterministic: the queue is ordered by
// (error, lower vertex id, higher vertex id), vertices and faces are walked in index order, and no Set or Dictionary
// order reaches the output. Edges on an open or shared-by-three boundary keep their vertices fixed, each collapse must
// pass the link condition, and collapses that would flip or flatten a face are skipped.

struct MeshSimplifyOptions: Equatable, Sendable {
    /// Stop once the mesh has at most this many triangles. The default suits Reinforce and Auto-improve.
    var targetTriangles = meshToolsReinforceTriangleLimit
    /// Upper bound on queue entries examined, as a multiple of the starting edge count, so every run finishes.
    var maximumPopsPerEdge = 12
}

struct MeshSimplifyResult: Sendable {
    let mesh: STLMesh
    let originalTriangles: Int
    /// False when no further collapse passed the checks before reaching the target.
    let reachedTarget: Bool
    /// Square root of the largest accepted quadric error, in model units (mm for Slant): an estimate of how far the
    /// surface moved from the original faces' planes, not a measured distance.
    let estimatedMaximumDeviation: Double
    /// Vertices held in place because they lie on an open or non-manifold edge.
    let lockedVertices: Int
    let before: MeshHealthReport
    let after: MeshHealthReport
    var triangles: Int { mesh.triangleCount }
    var changed: Bool { triangles < originalTriangles }
}

/// Symmetric 4 × 4 plane quadric: E(x) = xᵀAx + 2bᵀx + c.
struct MeshQuadric: Equatable, Sendable {
    var a00 = 0.0, a01 = 0.0, a02 = 0.0, a11 = 0.0, a12 = 0.0, a22 = 0.0
    var b0 = 0.0, b1 = 0.0, b2 = 0.0, c = 0.0

    init() {}
    /// The squared distance to the plane n·x + d = 0, with n a unit normal.
    init(normal n: SIMD3<Double>, offset d: Double) {
        a00 = n.x * n.x; a01 = n.x * n.y; a02 = n.x * n.z
        a11 = n.y * n.y; a12 = n.y * n.z; a22 = n.z * n.z
        b0 = d * n.x; b1 = d * n.y; b2 = d * n.z; c = d * d
    }

    static func + (l: MeshQuadric, r: MeshQuadric) -> MeshQuadric {
        var q = MeshQuadric()
        q.a00 = l.a00 + r.a00; q.a01 = l.a01 + r.a01; q.a02 = l.a02 + r.a02
        q.a11 = l.a11 + r.a11; q.a12 = l.a12 + r.a12; q.a22 = l.a22 + r.a22
        q.b0 = l.b0 + r.b0; q.b1 = l.b1 + r.b1; q.b2 = l.b2 + r.b2; q.c = l.c + r.c
        return q
    }

    func error(_ p: SIMD3<Double>) -> Double {
        let ax = a00 * p.x + a01 * p.y + a02 * p.z
        let ay = a01 * p.x + a11 * p.y + a12 * p.z
        let az = a02 * p.x + a12 * p.y + a22 * p.z
        return max(0, p.x * ax + p.y * ay + p.z * az + 2 * (b0 * p.x + b1 * p.y + b2 * p.z) + c)
    }

    /// The point of least error, or nil when A is too close to singular (a flat or straight region).
    func minimiser() -> SIMD3<Double>? {
        let a = simd_double3x3(rows: [SIMD3(a00, a01, a02), SIMD3(a01, a11, a12), SIMD3(a02, a12, a22)])
        let trace = a00 + a11 + a22
        let det = a.determinant
        guard trace > 0, abs(det) > 1e-9 * trace * trace * trace else { return nil }
        let x = -(a.inverse * SIMD3(b0, b1, b2))
        return x.x.isFinite && x.y.isFinite && x.z.isFinite ? x : nil
    }
}

/// Binary min-heap of collapse candidates. Entries go stale when either vertex changes; `version` detects that.
private struct CollapseHeap {
    struct Entry {
        var cost: Double
        var u: Int32, v: Int32
        var uVersion: UInt32, vVersion: UInt32
        static func < (l: Entry, r: Entry) -> Bool {
            if l.cost != r.cost { return l.cost < r.cost }
            if l.u != r.u { return l.u < r.u }
            if l.v != r.v { return l.v < r.v }
            if l.uVersion != r.uVersion { return l.uVersion < r.uVersion }
            return l.vVersion < r.vVersion
        }
    }
    var items: [Entry] = []

    mutating func push(_ e: Entry) {
        items.append(e)
        var i = items.count - 1
        while i > 0 {
            let parent = (i - 1) / 2
            guard items[i] < items[parent] else { break }
            items.swapAt(i, parent)
            i = parent
        }
    }

    mutating func pop() -> Entry? {
        guard let first = items.first else { return nil }
        let last = items.removeLast()
        if !items.isEmpty {
            items[0] = last
            siftDown(0)
        }
        return first
    }

    mutating func heapify() {
        guard items.count > 1 else { return }
        for i in stride(from: items.count / 2 - 1, through: 0, by: -1) { siftDown(i) }
    }

    private mutating func siftDown(_ start: Int) {
        var i = start
        while true {
            let l = 2 * i + 1, r = l + 1
            var smallest = i
            if l < items.count, items[l] < items[smallest] { smallest = l }
            if r < items.count, items[r] < items[smallest] { smallest = r }
            guard smallest != i else { return }
            items.swapAt(i, smallest)
            i = smallest
        }
    }
}

/// Simplifies a copy of `mesh` to at most `options.targetTriangles` triangles where the checks allow. Vertices are
/// welded by exact position first (run `repairMesh` before this for a mesh with gaps). Throws
/// `MeshToolError.cancelled`, `.empty`, or `.openedSurface` when a closed or consistent input would come out
/// otherwise. A mesh already at or under the target comes back unchanged (`changed` false).
func simplifyMesh(_ mesh: STLMesh, options: MeshSimplifyOptions = MeshSimplifyOptions(),
                  progress: MeshToolProgress = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> MeshSimplifyResult {
    guard mesh.triangleCount > 0 else { throw MeshToolError.empty }
    progress(0, "Checking the mesh…")
    guard let before = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw MeshToolError.cancelled }
    let target = max(4, options.targetTriangles)
    guard mesh.triangleCount > target else {
        return MeshSimplifyResult(mesh: mesh, originalTriangles: mesh.triangleCount, reachedTarget: true,
                                  estimatedMaximumDeviation: 0, lockedVertices: 0, before: before, after: before)
    }
    let weld = try weldMeshCorners(mesh, tolerance: 0, isCancelled: isCancelled)
    let bounds = meshCoordinateBounds(mesh.vertices)
    // Centred in Double, so quadric sums don't lose precision far from the origin.
    let centre = (SIMD3<Double>(bounds.low) + SIMD3<Double>(bounds.high)) / 2
    var pos = weld.points.map { SIMD3<Double>($0) - centre }
    var tris = weld.triangles
    var faceAlive = tris.map { $0.x != $0.y && $0.y != $0.z && $0.x != $0.z }
    var live = faceAlive.filter { $0 }.count
    let startCount = live
    let vertexCount = pos.count

    progress(0.05, "Measuring the surface…")
    var quadric = [MeshQuadric](repeating: MeshQuadric(), count: vertexCount)
    var incident = [[Int32]](repeating: [], count: vertexCount)
    var keys: [UInt64] = []
    keys.reserveCapacity(tris.count * 3)
    func edgeKey(_ p: Int32, _ q: Int32) -> UInt64 { UInt64(UInt32(min(p, q))) << 32 | UInt64(UInt32(max(p, q))) }
    for f in tris.indices where faceAlive[f] {
        if f % 8192 == 0, isCancelled() { throw MeshToolError.cancelled }
        let t = tris[f]
        let a = pos[Int(t.x)], b = pos[Int(t.y)], c = pos[Int(t.z)]
        let n = simd_cross(b - a, c - a), length = simd_length(n)
        if length > 0 {
            let unit = n / length
            let q = MeshQuadric(normal: unit, offset: -simd_dot(unit, a))
            quadric[Int(t.x)] = quadric[Int(t.x)] + q
            quadric[Int(t.y)] = quadric[Int(t.y)] + q
            quadric[Int(t.z)] = quadric[Int(t.z)] + q
        }
        for id in [t.x, t.y, t.z] { incident[Int(id)].append(Int32(f)) }
        keys.append(edgeKey(t.x, t.y)); keys.append(edgeKey(t.y, t.z)); keys.append(edgeKey(t.z, t.x))
    }
    keys.sort()
    var locked = [Bool](repeating: false, count: vertexCount)
    var edges: [UInt64] = []
    edges.reserveCapacity(keys.count / 2)
    var i = 0
    while i < keys.count {
        var j = i
        while j < keys.count, keys[j] == keys[i] { j += 1 }
        if j - i != 2 {
            locked[Int(keys[i] >> 32)] = true
            locked[Int(keys[i] & 0xFFFF_FFFF)] = true
        }
        edges.append(keys[i])
        i = j
    }
    keys = []

    var vertexAlive = [Bool](repeating: true, count: vertexCount)
    var version = [UInt32](repeating: 0, count: vertexCount)

    /// Where a collapse of (u, v) would put the kept vertex, and its error. A locked end stays where it is.
    func plan(_ u: Int32, _ v: Int32) -> (cost: Double, target: SIMD3<Double>) {
        let q = quadric[Int(u)] + quadric[Int(v)]
        let pu = pos[Int(u)], pv = pos[Int(v)]
        if locked[Int(u)] { return (q.error(pu), pu) }
        if locked[Int(v)] { return (q.error(pv), pv) }
        let mid = (pu + pv) / 2
        var candidates: [SIMD3<Double>] = []
        // Far-off optima come from nearly flat regions; the ends and midpoint are safer there.
        if let x = q.minimiser(), simd_distance(x, mid) <= 2 * simd_distance(pu, pv) { candidates.append(x) }
        candidates += [pu, pv, mid]
        var best = candidates[0], bestCost = q.error(best)
        for p in candidates.dropFirst() {
            let cost = q.error(p)
            if cost < bestCost { best = p; bestCost = cost }
        }
        return (bestCost, best)
    }

    func entry(_ a: Int32, _ b: Int32) -> CollapseHeap.Entry {
        let u = min(a, b), v = max(a, b)
        return CollapseHeap.Entry(cost: plan(u, v).cost, u: u, v: v, uVersion: version[Int(u)], vVersion: version[Int(v)])
    }

    progress(0.1, "Ranking edges…")
    var heap = CollapseHeap()
    // Room for the edges plus the pushes after collapses, so the heap doesn't reallocate at its largest.
    heap.items.reserveCapacity(edges.count * 3)
    for (n, key) in edges.enumerated() {
        if n % 8192 == 0, isCancelled() { throw MeshToolError.cancelled }
        let u = Int32(key >> 32), v = Int32(key & 0xFFFF_FFFF)
        guard !(locked[Int(u)] && locked[Int(v)]) else { continue }
        heap.items.append(entry(u, v))
    }
    heap.heapify()

    func contains(_ t: SIMD3<Int32>, _ id: Int32) -> Bool { t.x == id || t.y == id || t.z == id }
    func sortedKey(_ t: SIMD3<Int32>) -> SIMD3<Int32> {
        let a = min(t.x, t.y, t.z), c = max(t.x, t.y, t.z)
        return SIMD3(a, t.x + t.y + t.z - a - c, c)
    }
    /// Vertices around `id` other than `except`, sorted and unique.
    func ring(_ id: Int32, except: Int32) -> [Int32] {
        var list: [Int32] = []
        for f in incident[Int(id)] {
            let t = tris[Int(f)]
            for w in [t.x, t.y, t.z] where w != id && w != except { list.append(w) }
        }
        list.sort()
        var unique: [Int32] = []
        for w in list where unique.last != w { unique.append(w) }
        return unique
    }

    let budget = max(1, options.maximumPopsPerEdge) * max(edges.count, 1)
    var pops = 0
    var maxCost = 0.0
    let span = Double(max(1, startCount - target))
    progress(0.15, "Simplifying…")
    while live > target, let e = heap.pop() {
        pops += 1
        if pops > budget { break }
        if pops % 1024 == 0 {
            if isCancelled() { throw MeshToolError.cancelled }
            if pops % 16384 == 0 { progress(0.15 + 0.75 * Double(startCount - live) / span, "Simplifying…") }
        }
        let u = e.u, v = e.v
        guard vertexAlive[Int(u)], vertexAlive[Int(v)], version[Int(u)] == e.uVersion, version[Int(v)] == e.vVersion,
              !(locked[Int(u)] && locked[Int(v)]) else { continue }
        let (cost, target3) = plan(u, v)
        let keep = locked[Int(v)] ? v : u, gone = keep == u ? v : u
        incident[Int(keep)].removeAll { !faceAlive[Int($0)] }
        incident[Int(gone)].removeAll { !faceAlive[Int($0)] }
        let shared = incident[Int(gone)].filter { contains(tris[Int($0)], keep) }
        guard shared.count == 2 else { continue }
        // Link condition: the only vertices next to both ends are the two faces' opposite corners.
        let opposite = shared.map { f -> Int32 in
            let t = tris[Int(f)]
            return [t.x, t.y, t.z].first { $0 != keep && $0 != gone }!
        }.sorted()
        guard opposite[0] != opposite[1] else { continue }
        let keepRing = ring(keep, except: gone), goneRing = ring(gone, except: keep)
        var common: [Int32] = []
        var a = 0, b = 0
        while a < keepRing.count, b < goneRing.count {
            if keepRing[a] == goneRing[b] { common.append(keepRing[a]); a += 1; b += 1 } else if keepRing[a] < goneRing[b] { a += 1 } else { b += 1 }
        }
        guard common == opposite else { continue }

        // Every face that survives must keep its facing, stay well shaped and not duplicate another.
        var acceptable = true
        var keepKeys: [SIMD3<Int32>] = []
        for (owner, list) in [(keep, incident[Int(keep)]), (gone, incident[Int(gone)])] where acceptable {
            for f in list where !shared.contains(f) {
                let t = tris[Int(f)]
                let corners = [t.x, t.y, t.z]
                let old = corners.map { pos[Int($0)] }
                let moved = corners.map { $0 == owner ? target3 : pos[Int($0)] }
                let oldNormal = simd_cross(old[1] - old[0], old[2] - old[0])
                let newNormal = simd_cross(moved[1] - moved[0], moved[2] - moved[0])
                let longest = max(simd_length_squared(moved[1] - moved[0]), simd_length_squared(moved[2] - moved[1]),
                                  simd_length_squared(moved[0] - moved[2]))
                let newLength = simd_length(newNormal), oldLength = simd_length(oldNormal)
                if longest <= 0 || newLength < 1e-4 * longest { acceptable = false; break }
                if oldLength > 0, simd_dot(oldNormal, newNormal) < 0.2 * oldLength * newLength { acceptable = false; break }
                let remapped = SIMD3(t.x == gone ? keep : t.x, t.y == gone ? keep : t.y, t.z == gone ? keep : t.z)
                let key = sortedKey(remapped)
                if owner == keep { keepKeys.append(key) } else if keepKeys.contains(key) { acceptable = false; break }
            }
        }
        guard acceptable else { continue }

        for f in shared { faceAlive[Int(f)] = false; live -= 1 }
        for f in incident[Int(gone)] where faceAlive[Int(f)] {
            var t = tris[Int(f)]
            if t.x == gone { t.x = keep } else if t.y == gone { t.y = keep } else if t.z == gone { t.z = keep }
            tris[Int(f)] = t
            incident[Int(keep)].append(f)
        }
        incident[Int(gone)] = []
        incident[Int(keep)].removeAll { !faceAlive[Int($0)] }
        vertexAlive[Int(gone)] = false
        pos[Int(keep)] = target3
        quadric[Int(keep)] = quadric[Int(keep)] + quadric[Int(gone)]
        version[Int(keep)] &+= 1
        maxCost = max(maxCost, cost)
        for w in ring(keep, except: keep) where !(locked[Int(keep)] && locked[Int(w)]) { heap.push(entry(keep, w)) }
    }
    if isCancelled() { throw MeshToolError.cancelled }

    progress(0.92, "Checking the simplified mesh…")
    var vertices: [Float] = []
    vertices.reserveCapacity(live * 9)
    for f in tris.indices where faceAlive[f] {
        for id in [tris[f].x, tris[f].y, tris[f].z] {
            let p = SIMD3<Float>(pos[Int(id)] + centre)
            vertices.append(p.x); vertices.append(p.y); vertices.append(p.z)
        }
    }
    guard !vertices.isEmpty else { throw MeshToolError.empty }
    let simplified: STLMesh
    do { simplified = try STLMesh.validated(vertices) } catch { throw MeshToolError.empty }
    guard let after = analyzeMeshHealth(simplified, isCancelled: isCancelled) else { throw MeshToolError.cancelled }
    if (before.isClosed && !after.isClosed) || (before.isConsistentlyOriented && !after.isConsistentlyOriented) {
        throw MeshToolError.openedSurface
    }
    progress(1, "Done")
    return MeshSimplifyResult(mesh: simplified, originalTriangles: mesh.triangleCount, reachedTarget: live <= target,
                              estimatedMaximumDeviation: maxCost.squareRoot(),
                              lockedVertices: locked.filter { $0 }.count, before: before, after: after)
}

// MARK: - Summary copy

/// One line on what simplifying did and how far the surface may have moved, then the final check.
func meshSimplifySummaryLines(_ result: MeshSimplifyResult) -> [String] {
    var lines: [String] = []
    if result.changed {
        lines.append("Reduced \(result.originalTriangles.formatted()) triangles to \(result.triangles.formatted()).")
        lines.append(String(format: "Estimated largest surface change: %.2f mm. Check fine details and fit before ordering.",
                            result.estimatedMaximumDeviation))
    } else {
        lines.append("Already at \(result.triangles.formatted()) triangles, so nothing was simplified.")
    }
    if !result.reachedTarget {
        lines.append("Stopped above the target: the remaining edges couldn’t be collapsed without spoiling the shape"
                     + (result.lockedVertices > 0 ? " or moving open edges." : "."))
    }
    lines.append(meshRepairOutcomeLine(result.after))
    return lines
}
