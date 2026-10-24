import Foundation
import simd

// Deterministic mesh repair for imported and AI-generated meshes. Everything walks vertices, triangles and sorted
// edge keys in index order; dictionaries are only looked up, never iterated, so a mesh always gives the same bytes
// whatever the process's hash seed. Results are new triangle soups; callers save them as separate library copies.

// MARK: - Shared pieces

/// Reinforce and Auto-improve read meshes up to this many triangles (`reinforcementSolid()` in Reinforcement.swift).
let meshToolsReinforceTriangleLimit = 20_000

enum MeshToolError: LocalizedError, Equatable {
    case cancelled
    case empty
    case tooLarge
    case openedSurface

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Stopped. Nothing was saved."
        case .empty: return "Nothing would be left of this mesh, so no copy was made."
        case .tooLarge: return "The result would be larger than the 500,000-triangle preview limit, so no copy was made."
        case .openedSurface: return "Simplifying would leave gaps in this closed mesh, so no copy was made. Try a higher triangle count."
        }
    }
}

/// Reported to the caller's progress closure: a fraction from 0 to 1 and a short stage description.
typealias MeshToolProgress = (_ fraction: Double, _ stage: String) -> Void

/// The mesh tools' bar for a sound, printable surface. Separate parts are allowed; zero-area triangles are not, because
/// the tools remove them.
func meshHealthIsSound(_ report: MeshHealthReport) -> Bool {
    report.triangleCount > 0 && report.isClosed && report.isConsistentlyOriented && !report.isInsideOut
        && report.degenerateTriangles == 0
}

/// Bounds read from the coordinates themselves, since a hand-built `STLMesh` may carry placeholder bounds.
func meshCoordinateBounds(_ vertices: [Float]) -> (low: SIMD3<Float>, high: SIMD3<Float>) {
    guard vertices.count >= 3 else { return (.zero, .zero) }
    var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    for i in stride(from: 0, to: vertices.count - 2, by: 3) {
        let p = SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
        low = simd_min(low, p)
        high = simd_max(high, p)
    }
    return (low, high)
}

/// The weld distance used when none is given: 1/100,000 of the bounding-box diagonal (1 µm on a 100 mm part).
func defaultMeshWeldTolerance(_ mesh: STLMesh) -> Float {
    let bounds = meshCoordinateBounds(mesh.vertices)
    return simd_length(bounds.high - bounds.low) * 1e-5
}

struct MeshWeld: Sendable {
    /// One position per welded vertex, in first-seen order.
    var points: [SIMD3<Float>]
    /// Three vertex ids per input triangle, in input order.
    var triangles: [SIMD3<Int32>]
    /// Distinct input positions that moved onto an earlier vertex within the tolerance.
    var mergedPositions: Int
}

/// Welds identical coordinates, then (when `tolerance` > 0) any corner within `tolerance` of an earlier vertex, onto that
/// vertex's position. Candidates come from a spatial hash of `tolerance`-sized cells; the lowest-numbered vertex in reach
/// wins, so the result depends only on input order. -0 and +0 weld together.
func weldMeshCorners(_ mesh: STLMesh, tolerance: Float, isCancelled: () -> Bool = { false }) throws -> MeshWeld {
    let v = mesh.vertices
    let cornerCount = v.count / 3
    let bounds = meshCoordinateBounds(v)
    let diagonal = simd_length(bounds.high - bounds.low)
    let tol = tolerance.isFinite ? max(0, tolerance) : 0
    let toleranceSquared = tol * tol
    // Never smaller than a billionth of the diagonal, so cell indices fit in Int32.
    let cell = max(tol, diagonal * 1e-9, .leastNormalMagnitude)
    var exact: [SIMD3<Float>: Int32] = [:]
    exact.reserveCapacity(min(cornerCount, 1 << 21))
    var buckets: [SIMD3<Int32>: [Int32]] = [:]
    var points: [SIMD3<Float>] = []
    points.reserveCapacity(min(cornerCount, 1 << 21))
    var ids = [Int32](repeating: 0, count: cornerCount)
    var merged = 0
    func cellOf(_ p: SIMD3<Float>) -> SIMD3<Int32> {
        let q = (p - bounds.low) / cell
        return SIMD3<Int32>(Int32(q.x.rounded(.down)), Int32(q.y.rounded(.down)), Int32(q.z.rounded(.down)))
    }
    for corner in 0..<cornerCount {
        if corner % 8192 == 0, isCancelled() { throw MeshToolError.cancelled }
        let p = SIMD3<Float>(v[3 * corner] + 0, v[3 * corner + 1] + 0, v[3 * corner + 2] + 0)
        if let id = exact[p] { ids[corner] = id; continue }
        var best: Int32 = -1
        var home = SIMD3<Int32>.zero
        if tol > 0 {
            home = cellOf(p)
            for dz: Int32 in -1...1 { for dy: Int32 in -1...1 { for dx: Int32 in -1...1 {
                guard let list = buckets[home &+ SIMD3(dx, dy, dz)] else { continue }
                for id in list where (best < 0 || id < best) && simd_distance_squared(points[Int(id)], p) <= toleranceSquared {
                    best = id
                }
            } } }
        }
        if best >= 0 {
            merged += 1
        } else {
            best = Int32(points.count)
            points.append(p)
            if tol > 0 { buckets[home, default: []].append(best) }
        }
        exact[p] = best
        ids[corner] = best
    }
    var triangles: [SIMD3<Int32>] = []
    triangles.reserveCapacity(cornerCount / 3)
    for t in 0..<(cornerCount / 3) { triangles.append(SIMD3(ids[3 * t], ids[3 * t + 1], ids[3 * t + 2])) }
    return MeshWeld(points: points, triangles: triangles, mergedPositions: merged)
}

/// The zero-area rule `analyzeMeshHealth` uses: height below `meshHealthDegenerateRatio` of the longest edge.
func meshTriangleIsZeroArea(_ a: SIMD3<Double>, _ b: SIMD3<Double>, _ c: SIMD3<Double>) -> Bool {
    let cross = simd_cross(b - a, c - a)
    let longest = max(simd_length_squared(b - a), simd_length_squared(c - b), simd_length_squared(a - c))
    return simd_length(cross) <= meshHealthDegenerateRatio * longest
}

/// Undirected edge key with the direction in the lowest bit: 0 when the edge runs from the lower id to the higher.
@inline(__always) func meshDirectedEdgeKey(_ p: Int32, _ q: Int32) -> UInt64 {
    let low = UInt64(UInt32(min(p, q))), high = UInt64(UInt32(max(p, q)))
    return (low << 33) | (high << 1) | (p < q ? 0 : 1)
}

/// Triangle soup from indexed triangles, in triangle order.
func meshSoup(points: [SIMD3<Float>], triangles: [SIMD3<Int32>]) -> [Float] {
    var vertices: [Float] = []
    vertices.reserveCapacity(triangles.count * 9)
    for t in triangles {
        for corner in 0..<3 {
            let p = points[Int(t[corner])]
            vertices.append(p.x); vertices.append(p.y); vertices.append(p.z)
        }
    }
    return vertices
}

// MARK: - Repair

struct MeshRepairOptions: Equatable, Sendable {
    /// Corners closer than this weld into one vertex. Nil uses `defaultMeshWeldTolerance`; 0 welds exact matches only.
    var weldTolerance: Float? = nil
    /// Holes whose boundary has at most this many edges are capped; larger openings are left and reported.
    var maximumHoleEdges = 128
    var removeSmallShells = true
    /// A separate part with fewer triangles than this can't enclose any volume and is removed.
    var minimumShellTriangles = 4
    /// A separate part enclosing less than this fraction of the largest part's volume is removed as a fragment.
    var minimumShellVolumeFraction = 0.001
}

struct RemovedMeshShell: Equatable, Sendable {
    let triangles: Int
    /// Absolute enclosed volume in cubic model units (approximate for an open part).
    let volume: Double
}

struct MeshRepairSummary: Equatable, Sendable {
    var before: MeshHealthReport
    var after: MeshHealthReport
    var weldTolerance: Float = 0
    /// Distinct positions moved onto a nearby vertex.
    var weldedVertices = 0
    /// Triangles with a repeated corner or zero area, removed.
    var removedDegenerate = 0
    /// Neighbours split at a removed sliver's middle corner so the seam stays closed.
    var splitTriangles = 0
    /// Repeated triangles, and pairs of the same triangle facing opposite ways (an internal double wall), removed.
    var removedDuplicates = 0
    /// Loose flaps: triangles with an edge shared by three or more faces and an open edge, removed.
    var removedFlaps = 0
    /// Triangles turned round to match their neighbours or to face outward.
    var flippedTriangles = 0
    /// Closed parts that faced inward and were turned outward.
    var invertedShells = 0
    var filledHoles = 0
    var addedTriangles = 0
    /// Openings left: larger than `maximumHoleEdges`, or not a simple loop that could be capped cleanly.
    var unfilledHoles = 0
    var largestUnfilledHole = 0
    var removedShells: [RemovedMeshShell] = []

    var changed: Bool {
        weldedVertices > 0 || removedDegenerate > 0 || splitTriangles > 0 || removedDuplicates > 0 || removedFlaps > 0
            || flippedTriangles > 0 || filledHoles > 0 || !removedShells.isEmpty
    }
    /// True only when the final mesh check finds nothing to fix.
    var isSound: Bool { meshHealthIsSound(after) }
}

struct MeshRepairResult: Sendable {
    let mesh: STLMesh
    let summary: MeshRepairSummary
}

/// Repairs a copy of `mesh`: tolerance weld, zero-area and duplicate triangle removal, loose-flap removal, consistent
/// winding, hole capping, small-fragment removal and outward orientation, then a final `analyzeMeshHealth`. The summary
/// reports what changed and the final check; `summary.isSound` is the only success signal. Throws
/// `MeshToolError.cancelled` when `isCancelled` reports true, `.empty` when nothing is left and `.tooLarge` above the
/// preview limit.
func repairMesh(_ mesh: STLMesh, options: MeshRepairOptions = MeshRepairOptions(),
                progress: MeshToolProgress = { _, _ in }, isCancelled: () -> Bool = { false }) throws -> MeshRepairResult {
    guard mesh.triangleCount > 0 else { throw MeshToolError.empty }
    progress(0, "Checking the mesh…")
    guard let before = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw MeshToolError.cancelled }
    var summary = MeshRepairSummary(before: before, after: before)
    let tolerance = options.weldTolerance ?? defaultMeshWeldTolerance(mesh)
    summary.weldTolerance = tolerance

    progress(0.1, "Joining nearby vertices…")
    let weld = try weldMeshCorners(mesh, tolerance: tolerance, isCancelled: isCancelled)
    summary.weldedVertices = weld.mergedPositions
    return try withoutActuallyEscaping(isCancelled) { isCancelled in
    var work = RepairWork(points: weld.points, triangles: weld.triangles, isCancelled: isCancelled)

    progress(0.2, "Removing zero-area triangles…")
    try work.removeDegenerate(&summary)
    progress(0.3, "Removing repeated triangles…")
    try work.removeDuplicates(&summary)
    try work.removeFlaps(&summary)
    progress(0.4, "Making the faces consistent…")
    try work.orientConsistently(&summary)
    progress(0.55, "Closing small holes…")
    try work.fillHoles(maximumEdges: max(3, options.maximumHoleEdges), &summary)
    if options.removeSmallShells {
        progress(0.7, "Removing loose fragments…")
        try work.removeSmallShells(minimumTriangles: options.minimumShellTriangles,
                                   volumeFraction: options.minimumShellVolumeFraction, &summary)
    }
    progress(0.8, "Turning faces outward…")
    try work.orientOutward(&summary)

    let triangles = work.liveTriangles()
    guard !triangles.isEmpty else { throw MeshToolError.empty }
    guard triangles.count <= STLMesh.maximumTriangles else { throw MeshToolError.tooLarge }
    let repaired: STLMesh
    do { repaired = try STLMesh.validated(meshSoup(points: work.points, triangles: triangles)) } catch { throw MeshToolError.empty }
    progress(0.9, "Checking the repaired mesh…")
    guard let after = analyzeMeshHealth(repaired, isCancelled: isCancelled) else { throw MeshToolError.cancelled }
    summary.after = after
    progress(1, "Done")
    return MeshRepairResult(mesh: repaired, summary: summary)
    }
}

/// Indexed working state for `repairMesh`. Removed triangles stay in place, marked dead, so indices stay stable.
private struct RepairWork {
    var points: [SIMD3<Float>]
    var triangles: [SIMD3<Int32>]
    var alive: [Bool]
    let isCancelled: () -> Bool
    /// Positions are measured from here in Double, as `analyzeMeshHealth` does, so both apply the same zero-area test.
    let origin: SIMD3<Double>

    init(points: [SIMD3<Float>], triangles: [SIMD3<Int32>], isCancelled: @escaping () -> Bool) {
        self.points = points
        self.triangles = triangles
        self.alive = [Bool](repeating: true, count: triangles.count)
        self.isCancelled = isCancelled
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        for p in points { low = simd_min(low, p) }
        self.origin = points.isEmpty ? .zero : SIMD3<Double>(low)
    }

    func check(_ step: Int) throws { if step % 8192 == 0, isCancelled() { throw MeshToolError.cancelled } }
    func position(_ id: Int32) -> SIMD3<Double> { SIMD3<Double>(points[Int(id)]) - origin }
    func liveTriangles() -> [SIMD3<Int32>] { triangles.indices.filter { alive[$0] }.map { triangles[$0] } }

    /// (directed edge key, triangle) for every live triangle, sorted, so the uses of one edge are adjacent.
    func sortedEdges() throws -> [(key: UInt64, face: Int32)] {
        var edges: [(key: UInt64, face: Int32)] = []
        edges.reserveCapacity(triangles.count * 3)
        for f in triangles.indices where alive[f] {
            try check(f)
            let t = triangles[f]
            edges.append((meshDirectedEdgeKey(t.x, t.y), Int32(f)))
            edges.append((meshDirectedEdgeKey(t.y, t.z), Int32(f)))
            edges.append((meshDirectedEdgeKey(t.z, t.x), Int32(f)))
        }
        edges.sort { $0.key != $1.key ? $0.key < $1.key : $0.face < $1.face }
        return edges
    }

    // MARK: Degenerate triangles

    /// Drops triangles with a repeated corner. A zero-area sliver whose middle corner sits on its long edge would open
    /// a crack if simply dropped, so the neighbour across that edge is split at the middle corner instead (as
    /// `ReinforcementEngine` does for STL rounding).
    mutating func removeDegenerate(_ summary: inout MeshRepairSummary) throws {
        for f in triangles.indices {
            let t = triangles[f]
            if t.x == t.y || t.y == t.z || t.x == t.z { alive[f] = false; summary.removedDegenerate += 1 }
        }
        func zeroArea(_ t: SIMD3<Int32>) -> Bool { meshTriangleIsZeroArea(position(t.x), position(t.y), position(t.z)) }
        var slivers = triangles.indices.filter { alive[$0] && zeroArea(triangles[$0]) }
        guard !slivers.isEmpty else { return }
        // First live owner of each directed edge; looked up only.
        var owner: [UInt64: Int32] = [:]
        func pack(_ p: Int32, _ q: Int32) -> UInt64 { UInt64(UInt32(p)) << 32 | UInt64(UInt32(q)) }
        func register(_ f: Int) {
            let t = triangles[f]
            for (p, q) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] where owner[pack(p, q)] == nil { owner[pack(p, q)] = Int32(f) }
        }
        func unregister(_ f: Int) {
            let t = triangles[f]
            for (p, q) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] where owner[pack(p, q)] == Int32(f) { owner[pack(p, q)] = nil }
        }
        for f in triangles.indices where alive[f] { try check(f); register(f) }
        // Popped from the end, so slivers are handled in ascending triangle order.
        slivers.reverse()
        var budget = 4 * triangles.count + 16
        while let f = slivers.popLast(), budget > 0 {
            budget -= 1
            try check(budget)
            guard alive[f], zeroArea(triangles[f]) else { continue }
            let t = triangles[f]
            let corners = [t.x, t.y, t.z]
            // The longest edge (p, q); the third corner m lies on it.
            var j = 0, longest = -1.0
            for k in 0..<3 {
                let length = simd_distance_squared(position(corners[k]), position(corners[(k + 1) % 3]))
                if length > longest { longest = length; j = k }
            }
            let p = corners[j], q = corners[(j + 1) % 3], m = corners[(j + 2) % 3]
            unregister(f)
            alive[f] = false
            summary.removedDegenerate += 1
            guard let n32 = owner[pack(q, p)], alive[Int(n32)] else { continue }
            let n = Int(n32)
            let other = triangles[n]
            let r = [other.x, other.y, other.z].first { $0 != p && $0 != q } ?? p
            if r == m {
                // The neighbour is the same sliver facing the other way: a zero-volume fold. Remove both.
                unregister(n)
                alive[n] = false
                summary.removedDegenerate += 1
                continue
            }
            guard triangles.count < STLMesh.maximumTriangles * 2 else { continue }
            unregister(n)
            triangles[n] = SIMD3(q, m, r)
            triangles.append(SIMD3(m, p, r))
            alive.append(true)
            summary.splitTriangles += 1
            register(n)
            register(triangles.count - 1)
            for g in [triangles.count - 1, n] where zeroArea(triangles[g]) { slivers.append(g) }
        }
    }

    // MARK: Duplicates

    /// Triangles over the same three vertices: same-way repeats keep the first; a pair facing opposite ways is an
    /// internal double wall (two solids touching face to face), so both go.
    mutating func removeDuplicates(_ summary: inout MeshRepairSummary) throws {
        var keyed: [(key: UInt64, forward: Bool, face: Int32)] = []
        keyed.reserveCapacity(triangles.count)
        for f in triangles.indices where alive[f] {
            try check(f)
            let t = triangles[f]
            // Rotate so the smallest id comes first; the order of the other two gives the winding.
            let s: SIMD3<Int32> = t.x <= t.y && t.x <= t.z ? t : (t.y <= t.z ? SIMD3(t.y, t.z, t.x) : SIMD3(t.z, t.x, t.y))
            let a = UInt64(UInt32(s.x)), b = UInt64(UInt32(min(s.y, s.z))), c = UInt64(UInt32(max(s.y, s.z)))
            keyed.append(((a << 42) | (b << 21) | c, s.y < s.z, Int32(f)))
        }
        keyed.sort { $0.key != $1.key ? $0.key < $1.key : $0.face < $1.face }
        var i = 0
        while i < keyed.count {
            var j = i
            while j < keyed.count, keyed[j].key == keyed[i].key { j += 1 }
            if j - i > 1 {
                var forward = keyed[i..<j].filter { $0.forward }.map(\.face)
                var backward = keyed[i..<j].filter { !$0.forward }.map(\.face)
                // Cancel opposite pairs, then keep one of whatever is left.
                let pairs = min(forward.count, backward.count)
                for k in 0..<pairs { alive[Int(forward[k])] = false; alive[Int(backward[k])] = false }
                forward.removeFirst(pairs)
                backward.removeFirst(pairs)
                for face in (forward + backward).dropFirst() { alive[Int(face)] = false }
                summary.removedDuplicates += (j - i) - (forward.isEmpty && backward.isEmpty ? 0 : 1)
            }
            i = j
        }
    }

    // MARK: Loose flaps

    /// Removes triangles that hang off an edge shared by three or more faces and also have an open edge: the fins and
    /// stray flaps AI meshes leave on a surface. A few passes peel a flap back to its attachment.
    mutating func removeFlaps(_ summary: inout MeshRepairSummary) throws {
        for _ in 0..<3 {
            let edges = try sortedEdges()
            var open = [Bool](repeating: false, count: triangles.count)
            var crowded = [Bool](repeating: false, count: triangles.count)
            var i = 0
            while i < edges.count {
                var j = i
                while j < edges.count, edges[j].key >> 1 == edges[i].key >> 1 { j += 1 }
                if j - i == 1 { open[Int(edges[i].face)] = true }
                if j - i > 2 { for k in i..<j { crowded[Int(edges[k].face)] = true } }
                i = j
            }
            var removed = 0
            for f in triangles.indices where alive[f] && open[f] && crowded[f] { alive[f] = false; removed += 1 }
            summary.removedFlaps += removed
            if removed == 0 { return }
        }
    }

    // MARK: Winding

    /// Faces joined across edges used by exactly two triangles, with whether the pair runs the same way (so one is flipped).
    func manifoldAdjacency() throws -> (start: [Int32], neighbours: [(face: Int32, same: Bool)], closed: [Bool]) {
        let edges = try sortedEdges()
        var pairs: [(a: Int32, b: Int32, same: Bool)] = []
        var closed = [Bool](repeating: true, count: triangles.count)
        var i = 0
        while i < edges.count {
            var j = i
            while j < edges.count, edges[j].key >> 1 == edges[i].key >> 1 { j += 1 }
            if j - i == 2, edges[i].face != edges[i + 1].face {
                pairs.append((edges[i].face, edges[i + 1].face, edges[i].key & 1 == edges[i + 1].key & 1))
            } else {
                for k in i..<j { closed[Int(edges[k].face)] = false }
            }
            i = j
        }
        var counts = [Int32](repeating: 0, count: triangles.count + 1)
        for p in pairs { counts[Int(p.a) + 1] += 1; counts[Int(p.b) + 1] += 1 }
        for f in 0..<triangles.count { counts[f + 1] += counts[f] }
        var fill = counts
        var neighbours = [(face: Int32, same: Bool)](repeating: (0, false), count: pairs.count * 2)
        for p in pairs {
            neighbours[Int(fill[Int(p.a)])] = (p.b, p.same); fill[Int(p.a)] += 1
            neighbours[Int(fill[Int(p.b)])] = (p.a, p.same); fill[Int(p.b)] += 1
        }
        return (counts, neighbours, closed)
    }

    /// Connected patches (through two-face edges), each listed in ascending face order, in order of their lowest face.
    func patches(_ adjacency: (start: [Int32], neighbours: [(face: Int32, same: Bool)], closed: [Bool])) throws -> [[Int32]] {
        var seen = [Bool](repeating: false, count: triangles.count)
        var result: [[Int32]] = []
        for seed in triangles.indices where alive[seed] && !seen[seed] {
            try check(seed)
            var members: [Int32] = [Int32(seed)]
            seen[seed] = true
            var head = 0
            while head < members.count {
                let f = Int(members[head]); head += 1
                for k in Int(adjacency.start[f])..<Int(adjacency.start[f + 1]) {
                    let other = Int(adjacency.neighbours[k].face)
                    if !seen[other] { seen[other] = true; members.append(Int32(other)) }
                }
            }
            result.append(members.sorted())
        }
        return result
    }

    /// Breadth-first from each patch's lowest face, turning neighbours round to match. Within each patch the smaller
    /// set of faces is the one turned. A patch that can't be made consistent (a Möbius-like surface) keeps its
    /// conflicts for the final check to report.
    mutating func orientConsistently(_ summary: inout MeshRepairSummary) throws {
        let adjacency = try manifoldAdjacency()
        var flip = [Bool](repeating: false, count: triangles.count)
        var seen = [Bool](repeating: false, count: triangles.count)
        for seed in triangles.indices where alive[seed] && !seen[seed] {
            try check(seed)
            var members: [Int32] = [Int32(seed)]
            seen[seed] = true
            var head = 0
            while head < members.count {
                let f = Int(members[head]); head += 1
                for k in Int(adjacency.start[f])..<Int(adjacency.start[f + 1]) {
                    let (other32, same) = adjacency.neighbours[k]
                    let other = Int(other32)
                    guard !seen[other] else { continue }
                    seen[other] = true
                    flip[other] = flip[f] != same
                    members.append(other32)
                }
            }
            let flipped = members.filter { flip[Int($0)] }.count
            if flipped * 2 > members.count { for f in members { flip[Int(f)].toggle() } }
        }
        for f in triangles.indices where alive[f] && flip[f] {
            let t = triangles[f]
            triangles[f] = SIMD3(t.x, t.z, t.y)
            summary.flippedTriangles += 1
        }
    }

    // MARK: Holes

    /// Caps each simple boundary loop of at most `maximumEdges` edges: ear clipping on the loop's best-fit plane (best
    /// shaped ear first, ties to the lowest position), or a fan from the loop's centre when no clean ear remains. A cap
    /// that would reuse an existing edge or fold against its loop is skipped.
    mutating func fillHoles(maximumEdges: Int, _ summary: inout MeshRepairSummary) throws {
        let edges = try sortedEdges()
        // Every undirected edge in use, for the "diagonal already exists" check. Looked up only.
        var used: [UInt64: Bool] = [:]
        used.reserveCapacity(edges.count / 2)
        // Cap edges run opposite to the open edges: (start, end), with the face the open edge belongs to.
        var caps: [(start: Int32, end: Int32, face: Int32)] = []
        var i = 0
        while i < edges.count {
            var j = i
            while j < edges.count, edges[j].key >> 1 == edges[i].key >> 1 { j += 1 }
            used[edges[i].key >> 1] = true
            if j - i == 1 {
                let key = edges[i].key
                let low = Int32(truncatingIfNeeded: key >> 33), high = Int32(truncatingIfNeeded: (key >> 1) & 0xFFFF_FFFF)
                let (from, to) = key & 1 == 0 ? (low, high) : (high, low)
                caps.append((to, from, edges[i].face))
            }
            i = j
        }
        guard !caps.isEmpty else { return }
        caps.sort { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }
        func firstCap(from vertex: Int32) -> Int {
            var lo = 0, hi = caps.count
            while lo < hi { let mid = (lo + hi) / 2; if caps[mid].start < vertex { lo = mid + 1 } else { hi = mid } }
            return lo
        }
        var consumed = [Bool](repeating: false, count: caps.count)
        var onLoop = [Int32](repeating: -1, count: points.count)
        var loopID: Int32 = 0
        for seed in caps.indices where !consumed[seed] {
            try check(seed)
            loopID += 1
            consumed[seed] = true
            var loop: [Int32] = [caps[seed].start]
            onLoop[Int(caps[seed].start)] = loopID
            var current = caps[seed].end
            var simple = true
            var faces: [Int32] = [caps[seed].face]
            while current != loop[0] {
                if onLoop[Int(current)] == loopID { simple = false; break }
                onLoop[Int(current)] = loopID
                loop.append(current)
                var k = firstCap(from: current)
                while k < caps.count, caps[k].start == current, consumed[k] { k += 1 }
                guard k < caps.count, caps[k].start == current else { simple = false; break }
                consumed[k] = true
                faces.append(caps[k].face)
                current = caps[k].end
            }
            // A lone triangle's own outline isn't a hole: capping it would only add its reverse.
            if simple, loop.count == 3, faces.allSatisfy({ $0 == faces[0] }) { continue }
            guard simple, loop.count >= 3, loop.count <= maximumEdges,
                  let cap = capTriangles(loop, used: used) else {
                summary.unfilledHoles += 1
                summary.largestUnfilledHole = max(summary.largestUnfilledHole, loop.count)
                continue
            }
            for t in cap.triangles {
                triangles.append(t)
                alive.append(true)
                for (p, q) in [(t.x, t.y), (t.y, t.z), (t.z, t.x)] { used[meshDirectedEdgeKey(p, q) >> 1] = true }
            }
            if let centre = cap.centre { points.append(centre); onLoop.append(-1) }
            summary.filledHoles += 1
            summary.addedTriangles += cap.triangles.count
            if triangles.count > STLMesh.maximumTriangles * 2 { throw MeshToolError.tooLarge }
        }
    }

    /// Triangles closing `loop` (in cap order), plus a new centre vertex for a fan; nil when no clean cap exists.
    func capTriangles(_ loop: [Int32], used: [UInt64: Bool]) -> (triangles: [SIMD3<Int32>], centre: SIMD3<Float>?)? {
        let count = loop.count
        let p = loop.map(position)
        if count == 3 {
            guard !meshTriangleIsZeroArea(p[0], p[1], p[2]) else { return nil }
            return ([SIMD3(loop[0], loop[1], loop[2])], nil)
        }
        // Newell normal: the cap's facing for this traversal.
        var normal = SIMD3<Double>()
        for k in 0..<count {
            let a = p[k], b = p[(k + 1) % count]
            normal += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
        }
        guard simd_length(normal) > 0 else { return nil }
        normal = simd_normalize(normal)
        let axis: SIMD3<Double> = abs(normal.x) < 0.6 ? SIMD3(1, 0, 0) : (abs(normal.y) < 0.6 ? SIMD3(0, 1, 0) : SIMD3(0, 0, 1))
        let u = simd_normalize(simd_cross(axis, normal)), w = simd_cross(normal, u)
        let flat = p.map { SIMD2(simd_dot($0, u), simd_dot($0, w)) }
        func faces(_ a: Int, _ b: Int, _ c: Int) -> Bool {
            !meshTriangleIsZeroArea(p[a], p[b], p[c]) && simd_dot(simd_cross(p[b] - p[a], p[c] - p[a]), normal) > 0
        }
        func cross2(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
            (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
        }
        var remaining = Array(0..<count)
        var result: [SIMD3<Int32>] = []
        while remaining.count > 3 {
            let m = remaining.count
            var best = -1, bestScore = -Double.infinity
            for j in 0..<m {
                let a = remaining[(j + m - 1) % m], b = remaining[j], c = remaining[(j + 1) % m]
                guard cross2(flat[a], flat[b], flat[c]) > 0, faces(a, b, c) else { continue }
                // The new diagonal must not already be an edge elsewhere in the mesh.
                guard used[meshDirectedEdgeKey(loop[a], loop[c]) >> 1] == nil else { continue }
                // No other loop corner may sit inside or on the ear.
                let blocked = remaining.contains { o in
                    o != a && o != b && o != c && cross2(flat[a], flat[b], flat[o]) >= 0
                        && cross2(flat[b], flat[c], flat[o]) >= 0 && cross2(flat[c], flat[a], flat[o]) >= 0
                }
                guard !blocked else { continue }
                let area = simd_length(simd_cross(p[b] - p[a], p[c] - p[a]))
                let edges = simd_length_squared(p[b] - p[a]) + simd_length_squared(p[c] - p[b]) + simd_length_squared(p[a] - p[c])
                let score = area / edges
                if score > bestScore { bestScore = score; best = j }
            }
            guard best >= 0 else { result = []; break }
            let a = remaining[(best + m - 1) % m], b = remaining[best], c = remaining[(best + 1) % m]
            result.append(SIMD3(loop[a], loop[b], loop[c]))
            remaining.remove(at: best)
        }
        if remaining.count == 3, faces(remaining[0], remaining[1], remaining[2]) {
            result.append(SIMD3(loop[remaining[0]], loop[remaining[1]], loop[remaining[2]]))
            return (result, nil)
        }
        // Fan from the loop's centre, which needs a new vertex but can't reuse an edge.
        let centre = p.reduce(SIMD3<Double>(), +) / Double(count)
        let centreID = Int32(points.count)
        var fan: [SIMD3<Int32>] = []
        for k in 0..<count {
            let a = p[k], b = p[(k + 1) % count]
            guard !meshTriangleIsZeroArea(a, b, centre), simd_dot(simd_cross(b - a, centre - a), normal) > 0 else { return nil }
            fan.append(SIMD3(loop[k], loop[(k + 1) % count], centreID))
        }
        return (fan, SIMD3<Float>(centre + origin))
    }

    // MARK: Separate parts

    /// Groups live triangles into parts joined through shared vertices; each part lists its faces in ascending order,
    /// parts in order of their lowest face.
    func shells() throws -> [[Int32]] {
        var parent = [Int32](0..<Int32(points.count))
        func root(_ x: Int32) -> Int32 {
            var r = x
            while parent[Int(r)] != r { r = parent[Int(r)] }
            var c = x
            while parent[Int(c)] != r { let next = parent[Int(c)]; parent[Int(c)] = r; c = next }
            return r
        }
        func union(_ a: Int32, _ b: Int32) {
            let ra = root(a), rb = root(b)
            if ra != rb { if ra < rb { parent[Int(rb)] = ra } else { parent[Int(ra)] = rb } }
        }
        for f in triangles.indices where alive[f] {
            try check(f)
            union(triangles[f].x, triangles[f].y)
            union(triangles[f].x, triangles[f].z)
        }
        var slot = [Int32](repeating: -1, count: points.count)
        var groups: [[Int32]] = []
        for f in triangles.indices where alive[f] {
            let r = Int(root(triangles[f].x))
            if slot[r] < 0 { slot[r] = Int32(groups.count); groups.append([]) }
            groups[Int(slot[r])].append(Int32(f))
        }
        return groups
    }

    /// Signed volume of a set of faces, measured from the first face's first corner.
    func volume(_ faces: [Int32]) -> Double {
        guard let first = faces.first else { return 0 }
        let o = position(triangles[Int(first)].x)
        var total = 0.0
        for f in faces {
            let t = triangles[Int(f)]
            total += simd_dot(position(t.x) - o, simd_cross(position(t.y) - o, position(t.z) - o)) / 6
        }
        return total
    }

    /// Keeps the part with the largest volume (then most triangles) and removes any other part with fewer than
    /// `minimumTriangles` triangles or less than `volumeFraction` of the largest part's volume.
    mutating func removeSmallShells(minimumTriangles: Int, volumeFraction: Double, _ summary: inout MeshRepairSummary) throws {
        let groups = try shells()
        guard groups.count > 1 else { return }
        let volumes = groups.map { abs(volume($0)) }
        var main = 0
        for g in groups.indices.dropFirst() {
            if volumes[g] > volumes[main] || (volumes[g] == volumes[main] && groups[g].count > groups[main].count) { main = g }
        }
        for g in groups.indices where g != main {
            guard groups[g].count < minimumTriangles || volumes[g] < volumeFraction * volumes[main] else { continue }
            for f in groups[g] { alive[Int(f)] = false }
            summary.removedShells.append(RemovedMeshShell(triangles: groups[g].count, volume: volumes[g]))
        }
    }

    // MARK: Outward

    /// Turns a closed, consistently wound patch outward when it encloses negative volume, unless it sits inside another
    /// closed patch (a deliberate cavity), judged by bounds and up to eight of its corners. Open patches are left, and so
    /// is any patch still unjudged once the containment tests reach their budget: a cavity is never turned by guesswork.
    mutating func orientOutward(_ summary: inout MeshRepairSummary) throws {
        let adjacency = try manifoldAdjacency()
        let groups = try patches(adjacency)
        var closed: [Bool] = []
        var consistent: [Bool] = []
        for g in groups {
            closed.append(g.allSatisfy { adjacency.closed[Int($0)] })
            consistent.append(g.allSatisfy { f in
                (Int(adjacency.start[Int(f)])..<Int(adjacency.start[Int(f) + 1])).allSatisfy { !adjacency.neighbours[$0].same }
            })
        }
        func bounds(_ g: [Int32]) -> (SIMD3<Double>, SIMD3<Double>) {
            var low = SIMD3<Double>(repeating: .greatestFiniteMagnitude), high = -low
            for f in g { for id in [triangles[Int(f)].x, triangles[Int(f)].y, triangles[Int(f)].z] {
                low = simd_min(low, position(id)); high = simd_max(high, position(id))
            } }
            return (low, high)
        }
        let ray = simd_normalize(SIMD3<Double>(0.5773, 0.5779, 0.5766))
        func inside(_ point: SIMD3<Double>, _ g: [Int32]) -> Bool {
            var hits = 0
            for f in g {
                let t = triangles[Int(f)]
                let a = position(t.x), e1 = position(t.y) - a, e2 = position(t.z) - a
                let h = simd_cross(ray, e2), det = simd_dot(e1, h)
                guard abs(det) > 1e-18 else { continue }
                let s = point - a, bu = simd_dot(s, h) / det
                guard bu >= 0, bu <= 1 else { continue }
                let q = simd_cross(s, e1), bv = simd_dot(ray, q) / det
                guard bv >= 0, bu + bv <= 1 else { continue }
                if simd_dot(e2, q) / det > 1e-12 { hits += 1 }
            }
            return hits % 2 == 1
        }
        let allBounds = groups.map(bounds)
        var budget = 50_000_000 // ray–triangle tests
        for g in groups.indices where closed[g] && consistent[g] {
            try check(g)
            guard volume(groups[g]) < 0 else { continue }
            let corners = groups[g].map { triangles[Int($0)].x }
            let stride = max(1, corners.count / 8)
            let samples = Swift.stride(from: 0, to: corners.count, by: stride).prefix(8).map { position(corners[$0]) }
            let (low, high) = allBounds[g]
            var nested = false
            for h in groups.indices where h != g && closed[h] && !nested {
                guard all(allBounds[h].0 .<= low), all(allBounds[h].1 .>= high) else { continue }
                budget -= samples.count * groups[h].count
                guard budget >= 0 else { nested = true; break }
                if isCancelled() { throw MeshToolError.cancelled }
                var all = true
                for point in samples where all { all = inside(point, groups[h]) }
                nested = all
            }
            guard !nested else { continue }
            for f in groups[g] {
                let t = triangles[Int(f)]
                triangles[Int(f)] = SIMD3(t.x, t.z, t.y)
            }
            summary.flippedTriangles += groups[g].count
            summary.invertedShells += 1
        }
    }
}

// MARK: - Summary copy

private func meshCount(_ n: Int, _ singular: String, _ plural: String) -> String {
    "\(n.formatted()) \(n == 1 ? singular : plural)"
}

/// What a repair changed, one line each, then the final check. Never says "repaired" unless the final check is sound.
func meshRepairSummaryLines(_ summary: MeshRepairSummary) -> [String] {
    var lines: [String] = []
    if summary.weldedVertices > 0 { lines.append("Joined \(meshCount(summary.weldedVertices, "nearby vertex", "nearby vertices")).") }
    if summary.removedDegenerate > 0 {
        lines.append("Removed \(meshCount(summary.removedDegenerate, "zero-area triangle", "zero-area triangles"))"
                     + (summary.splitTriangles > 0 ? ", splitting \(meshCount(summary.splitTriangles, "neighbour", "neighbours")) to keep seams closed." : "."))
    }
    if summary.removedDuplicates > 0 { lines.append("Removed \(meshCount(summary.removedDuplicates, "repeated triangle", "repeated triangles")).") }
    if summary.removedFlaps > 0 { lines.append("Removed \(meshCount(summary.removedFlaps, "loose flap triangle", "loose flap triangles")).") }
    if summary.filledHoles > 0 {
        lines.append("Closed \(meshCount(summary.filledHoles, "hole", "holes")) with \(meshCount(summary.addedTriangles, "triangle", "triangles")).")
    }
    if summary.flippedTriangles > 0 {
        let shells = summary.invertedShells > 0 ? ", including \(meshCount(summary.invertedShells, "inside-out part", "inside-out parts"))" : ""
        lines.append("Turned \(meshCount(summary.flippedTriangles, "triangle", "triangles")) to face the right way\(shells).")
    }
    if !summary.removedShells.isEmpty {
        let triangles = summary.removedShells.reduce(0) { $0 + $1.triangles }
        lines.append("Removed \(meshCount(summary.removedShells.count, "loose fragment", "loose fragments")) (\(meshCount(triangles, "triangle", "triangles"))).")
    }
    if summary.unfilledHoles > 0 {
        lines.append("Left \(meshCount(summary.unfilledHoles, "opening", "openings")) open: too large (up to \(summary.largestUnfilledHole.formatted()) edges) or too irregular to close automatically.")
    }
    lines.append(meshRepairOutcomeLine(summary.after))
    return lines
}

/// The final check in one sentence; "Closed and consistent" only when `meshHealthIsSound`.
func meshRepairOutcomeLine(_ report: MeshHealthReport) -> String {
    if meshHealthIsSound(report) {
        return "Mesh check: closed and consistent, \(meshCount(report.shells, "part", "parts"))."
    }
    var problems: [String] = []
    if report.openEdges > 0 { problems.append(meshCount(report.openEdges, "open edge", "open edges")) }
    if report.nonManifoldEdges > 0 { problems.append(meshCount(report.nonManifoldEdges, "edge shared by more than two faces", "edges shared by more than two faces")) }
    if report.flippedEdges > 0 { problems.append(meshCount(report.flippedEdges, "flipped edge", "flipped edges")) }
    if report.isInsideOut { problems.append("faces pointing inward") }
    if report.degenerateTriangles > 0 { problems.append(meshCount(report.degenerateTriangles, "zero-area triangle", "zero-area triangles")) }
    return "Mesh check: still needs work — \(problems.joined(separator: ", ")). Fix the rest in your CAD tool or a repair tool."
}
