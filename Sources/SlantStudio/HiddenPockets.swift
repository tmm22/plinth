import Foundation
import simd

// Hidden pockets: closed cavities sealed inside a part. Each is a shell of its own, facing inward, and Slant bills every
// body after the first (about $0.39 each in a live estimate on 25 Oct 2026, where nine closed voids in a block gave ten
// bodies). Studio reports them per model and, only when the seller asks, saves a copy with them filled solid by
// removing the cavity shells' triangles. Nothing is filled automatically.
//
// Shells are groups of triangles joined through shared vertices, as the mesh check counts them, so a cavity open to
// the outside is part of the outer surface and never counts. Nesting follows the rule `repairMesh` uses to orient
// shells: a closed shell is inside another when every sampled corner of it is (ray parity), and its parent is the
// innermost shell around it. A pocket is an inward shell whose parent is an outward part; an outward solid inside a
// pocket is redundant once the pocket is filled, so it goes with the pocket. Separate outward parts are never removed.
//
// Pure and deterministic: triangles, vertices, edges and shells are walked in index order, and dictionaries are only
// used for lookups, never iterated for output.

// MARK: - Defaults

/// What Slant charged for each extra body in a live estimate on 25 Oct 2026 (`meshBodyChargeNote`).
let hiddenPocketBodyChargeUSD = Decimal(string: "0.39")!
let hiddenPocketBodyChargeDate = "25 Oct 2026"
/// The library's own limit. In a release build the report took 0.15 s and a fill 0.47 s at 400,000 triangles
/// (`BottomChamferTests.testTiming`).
let hiddenPocketsMaximumTriangles = 500_000
/// Corners of each shell tested for containment; every one must be inside.
let hiddenPocketsSamplesPerShell = 32
/// Ray–triangle tests allowed in one analysis; shells still unjudged after that are never counted or filled.
let hiddenPocketsRayTestLimit = 200_000_000
/// Shell-against-shell box comparisons allowed in one analysis (every pair is compared, so a model of many loose
/// parts is bounded too); shells still unjudged after that are never counted or filled, and the report is incomplete.
let hiddenPocketsBoxComparisonLimit = 20_000_000

// MARK: - Types

struct HiddenPocket: Equatable, Sendable {
    let triangles: Int
    /// The cavity's enclosed volume, positive.
    let volumeMM3: Double
    let low: SIMD3<Float>
    let high: SIMD3<Float>
    /// Shells inside this pocket (loose solids, and any pockets within them), removed when it is filled.
    let shellsInside: Int
}

struct HiddenPocketsReport: Equatable, Sendable {
    /// Every shell in the model.
    let shells: Int
    /// Closed inward cavities directly inside one of the model's parts, in order of their first triangle.
    let pockets: [HiddenPocket]
    /// Outward shells inside no other: the model's own separate parts. Filling never touches them.
    let separateParts: Int
    /// Shells inside the pockets, removed with them.
    let shellsInsidePockets: Int
    /// Shells that are none of these: open or inconsistent, inside out, a solid inside a solid, or not judged in time.
    let otherShells: Int
    /// False when the test budget ran out before every closed shell was placed; unplaced shells are never filled.
    let complete: Bool
    /// The volume filling would add: the pockets less the solids inside them.
    let addedVolumeMM3: Double

    var count: Int { pockets.count }
    /// The bodies a fill removes, each one Slant bills.
    var removableBodies: Int { pockets.count + shellsInsidePockets }
    /// `removableBodies` × `hiddenPocketBodyChargeUSD`: an estimate, from Slant's price on `hiddenPocketBodyChargeDate`.
    var estimatedExtraCostUSD: Decimal { Decimal(removableBodies) * hiddenPocketBodyChargeUSD }
}

/// Why no copy was made. Each is a normal outcome, not an error.
enum HiddenPocketsSkipReason: String, Equatable, Sendable, CaseIterable {
    case notClosedSolid
    case tooManyTriangles
    case noPockets
    case resultFailedChecks
    /// A shell to be removed has a corner that isn't inside the shell around it: it crosses that surface, so it isn't
    /// wholly a pocket.
    case couldNotConfirm
    /// The check ran out of its budget before every shell was placed (`HiddenPocketsReport.complete` false).
    case tooManyParts

    var message: String {
        switch self {
        case .notClosedSolid:
            return "Filling hidden pockets needs a closed, outward-facing mesh with no zero-area triangles. Repair a copy first."
        case .tooManyTriangles:
            return "This model has more than \(hiddenPocketsMaximumTriangles.formatted()) triangles, too many to fill hidden pockets. Simplify a copy first."
        case .noPockets: return "This model has no hidden pockets to fill."
        case .resultFailedChecks: return "The pockets weren’t filled: the result didn’t pass Plinth’s mesh checks."
        case .tooManyParts:
            return "The pockets weren’t filled: there are too many separate parts to check."
        case .couldNotConfirm:
            return "The pockets weren’t filled: Plinth couldn’t confirm that every one lies wholly inside the part, so removing it could change the part’s surface."
        }
    }
}

enum HiddenPocketsError: LocalizedError, Equatable {
    case stopped
    var errorDescription: String? { "Stopped. Nothing was saved." }
}

struct HiddenPocketsResult: Sendable {
    /// The filled copy, or nil when skipped.
    let mesh: STLMesh?
    /// The copy as binary STL, the bytes to save.
    let data: Data?
    let skipped: HiddenPocketsSkipReason?
    /// The input's report, which the copy acts on.
    let report: HiddenPocketsReport
    let filledPockets: Int
    /// Shells that were inside the pockets and went with them.
    let removedInnerShells: Int
    let addedVolumeMM3: Double
    let shellsBefore: Int
    let shellsAfter: Int

    var applied: Bool { mesh != nil }
}

// MARK: - Copy

private func pocketCount(_ n: Int, _ singular: String, _ plural: String) -> String {
    "\(n.formatted()) \(n == 1 ? singular : plural)"
}

/// "$0.78": the estimate to the cent.
func hiddenPocketsCostText(_ cost: Decimal) -> String {
    var rounded = Decimal()
    var value = cost
    NSDecimalRound(&rounded, &value, 2, .plain)
    return "$" + String(format: "%.2f", NSDecimalNumber(decimal: rounded).doubleValue)
}

/// The per-model line, or nil when there are no pockets, such as "2 hidden pockets cost about $0.78 extra in total
/// (Slant bills each as a separate body; test on 25 Oct 2026). Filling uses about 1.2 cm³ more material. Get an
/// estimate for both." The cost is the bodies a fill removes × `hiddenPocketBodyChargeUSD`, an estimate from Slant's
/// price on `hiddenPocketBodyChargeDate`. Never says filling makes a part stronger.
func hiddenPocketsSummaryText(count: Int, shellsInside: Int, addedVolumeMM3: Double) -> String? {
    guard count > 0 else { return nil }
    let pockets = pocketCount(count, "hidden pocket", "hidden pockets")
    let inside = shellsInside > 0 ? ", with \(pocketCount(shellsInside, "loose part", "loose parts")) inside," : ""
    let verb = count == 1 && shellsInside == 0 ? "costs" : "cost"
    let bills: String
    if shellsInside > 0 { bills = "Slant bills each pocket and each loose part as a separate body" }
    else { bills = count == 1 ? "Slant bills it as a separate body" : "Slant bills each as a separate body" }
    let cost = hiddenPocketsCostText(Decimal(count + shellsInside) * hiddenPocketBodyChargeUSD)
    let centimetres = addedVolumeMM3 / 1000
    let material = centimetres >= 0.05 ? "about \(String(format: "%.1f", centimetres)) cm³ more material" : "a little more material"
    var text = "\(pockets)\(inside) \(verb) about \(cost) extra in total (\(bills); test on \(hiddenPocketBodyChargeDate)). Filling uses \(material)."
    if shellsInside > 0 { text += " Filling removes the loose parts inside them." }
    return text + " Get an estimate for both."
}

func hiddenPocketsSummary(_ report: HiddenPocketsReport) -> String? {
    guard var text = hiddenPocketsSummaryText(count: report.count, shellsInside: report.shellsInsidePockets,
                                              addedVolumeMM3: report.addedVolumeMM3) else { return nil }
    if report.separateParts > 1 {
        text += " The model’s \(report.separateParts.formatted()) separate parts aren’t pockets, so filling leaves them."
    }
    if !report.complete { text += " " + hiddenPocketsIncompleteLine }
    return text
}

/// Shown when the check ran out of its budget (`HiddenPocketsReport.complete` false).
let hiddenPocketsIncompleteLine = "Some parts weren’t checked for hidden pockets: there are too many separate parts to check."

// MARK: - Analysis

/// Counts the hidden pockets, separate parts and other shells of `mesh`. Throws `HiddenPocketsError.stopped` when
/// `isCancelled` reports true. Works on any mesh, but only closed, consistently wound shells are placed.
func hiddenPocketsReport(_ mesh: STLMesh, boxComparisonLimit: Int = hiddenPocketsBoxComparisonLimit,
                         isCancelled: () -> Bool = { false }) throws -> HiddenPocketsReport {
    try hiddenPocketsAnalysis(mesh, boxComparisonLimit: boxComparisonLimit, isCancelled: isCancelled).report
}

private struct HiddenPocketsAnalysis {
    let report: HiddenPocketsReport
    /// The shell of each triangle.
    let shellOf: [Int32]
    /// Shells a fill removes.
    let removed: [Bool]
    /// With `verifyRemoved`: every corner of every shell a fill removes is inside the shell around it.
    var verified = false
}

private enum ShellKind { case part, pocket, solidInPocket, other }

/// `verifyRemoved`: also test every corner of each shell a fill would remove (not just the samples that placed it)
/// against the shell around it, for `fillHiddenPocketsCopy`.
private func hiddenPocketsAnalysis(_ mesh: STLMesh, boxComparisonLimit: Int = hiddenPocketsBoxComparisonLimit,
                                   verifyRemoved: Bool = false, isCancelled: () -> Bool) throws -> HiddenPocketsAnalysis {
    let count = mesh.triangleCount
    let v = mesh.vertices
    let check = 8192
    guard count > 0 else {
        let empty = HiddenPocketsReport(shells: 0, pockets: [], separateParts: 0, shellsInsidePockets: 0, otherShells: 0,
                                        complete: true, addedVolumeMM3: 0)
        return HiddenPocketsAnalysis(report: empty, shellOf: [], removed: [])
    }

    // Weld identical coordinates in first-seen order, as the mesh check does.
    var ids = [Int32](repeating: 0, count: count * 3)
    var points: [SIMD3<Float>] = []
    do {
        var lookup: [SIMD3<Float>: Int32] = [:]
        lookup.reserveCapacity(min(count * 3, 1 << 21))
        for corner in 0..<(count * 3) {
            if corner % check == 0, isCancelled() { throw HiddenPocketsError.stopped }
            let p = SIMD3<Float>(v[corner * 3] + 0, v[corner * 3 + 1] + 0, v[corner * 3 + 2] + 0)
            if let id = lookup[p] { ids[corner] = id } else {
                let id = Int32(points.count)
                lookup[p] = id
                points.append(p)
                ids[corner] = id
            }
        }
    }

    // Shells: vertices joined through triangles; numbered in order of their first triangle.
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
    for t in 0..<count {
        if t % check == 0, isCancelled() { throw HiddenPocketsError.stopped }
        union(ids[3 * t], ids[3 * t + 1])
        union(ids[3 * t], ids[3 * t + 2])
    }
    var slot = [Int32](repeating: -1, count: points.count)
    var shellOf = [Int32](repeating: 0, count: count)
    var shellCount = 0
    for t in 0..<count {
        let r = Int(root(ids[3 * t]))
        if slot[r] < 0 { slot[r] = Int32(shellCount); shellCount += 1 }
        shellOf[t] = slot[r]
    }
    func shellOfVertex(_ id: Int32) -> Int { Int(slot[Int(root(id))]) }

    // Per shell: triangles, bounds, signed volume, and whether it is closed and consistently wound.
    var triangles = [Int](repeating: 0, count: shellCount)
    var low = [SIMD3<Float>](repeating: SIMD3(repeating: .greatestFiniteMagnitude), count: shellCount)
    var high = [SIMD3<Float>](repeating: SIMD3(repeating: -.greatestFiniteMagnitude), count: shellCount)
    var volume = [Double](repeating: 0, count: shellCount)
    var sound = [Bool](repeating: true, count: shellCount)
    let origin = SIMD3<Double>(mesh.minimum)
    var edges: [UInt64] = []
    edges.reserveCapacity(count * 3)
    for t in 0..<count {
        if t % check == 0, isCancelled() { throw HiddenPocketsError.stopped }
        let s = Int(shellOf[t])
        let a = ids[3 * t], b = ids[3 * t + 1], c = ids[3 * t + 2]
        triangles[s] += 1
        for id in [a, b, c] { low[s] = simd_min(low[s], points[Int(id)]); high[s] = simd_max(high[s], points[Int(id)]) }
        if a == b || b == c || a == c { sound[s] = false; continue }
        let pa = SIMD3<Double>(points[Int(a)]) - origin, pb = SIMD3<Double>(points[Int(b)]) - origin
        let pc = SIMD3<Double>(points[Int(c)]) - origin
        volume[s] += simd_dot(pa, simd_cross(pb, pc)) / 6
        edges.append(meshDirectedEdgeKey(a, b))
        edges.append(meshDirectedEdgeKey(b, c))
        edges.append(meshDirectedEdgeKey(c, a))
    }
    edges.sort()
    if isCancelled() { throw HiddenPocketsError.stopped }
    var i = 0
    while i < edges.count {
        let key = edges[i] >> 1
        var j = i, forward = 0
        while j < edges.count, edges[j] >> 1 == key {
            if edges[j] & 1 == 0 { forward += 1 }
            j += 1
        }
        if j - i != 2 || forward != 1 { sound[shellOfVertex(Int32(truncatingIfNeeded: key >> 32))] = false }
        i = j
    }
    edges = []

    // Containment among closed, consistent shells: every sampled corner inside, by ray parity.
    var cornersOf = [[Int32]](repeating: [], count: shellCount)
    for t in 0..<count { cornersOf[Int(shellOf[t])].append(ids[3 * t]) }
    var grids = [HiddenPocketsShellGrid?](repeating: nil, count: shellCount)
    var trianglesOf: [[Int32]]? = nil
    var budget = hiddenPocketsRayTestLimit
    var containers = [[Int]?](repeating: [], count: shellCount)
    // Every pair of shells is compared by box, so many loose parts need a budget of their own.
    var boxBudget = boxComparisonLimit
    for g in 0..<shellCount where sound[g] {
        if isCancelled() { throw HiddenPocketsError.stopped }
        guard boxBudget >= shellCount else { containers[g] = nil; continue }
        boxBudget -= shellCount
        let corners = cornersOf[g]
        let stride = max(1, corners.count / hiddenPocketsSamplesPerShell)
        let samples = Swift.stride(from: 0, to: corners.count, by: stride).prefix(hiddenPocketsSamplesPerShell)
            .map { SIMD3<Double>(points[Int(corners[$0])]) - origin }
        var around: [Int] = []
        for h in 0..<shellCount where h != g && sound[h] {
            guard all(low[h] .<= low[g]), all(high[h] .>= high[g]) else { continue }
            if grids[h] == nil {
                if trianglesOf == nil {
                    var lists = [[Int32]](repeating: [], count: shellCount)
                    for t in 0..<count { lists[Int(shellOf[t])].append(Int32(t)) }
                    trianglesOf = lists
                }
                grids[h] = HiddenPocketsShellGrid(triangles: trianglesOf![h].map { t in
                    (SIMD3<Double>(points[Int(ids[3 * Int(t)])]) - origin, SIMD3<Double>(points[Int(ids[3 * Int(t) + 1])]) - origin,
                     SIMD3<Double>(points[Int(ids[3 * Int(t) + 2])]) - origin)
                })
            }
            var inside = true
            for point in samples where inside {
                guard let parity = grids[h]!.contains(point, budget: &budget) else { containers[g] = nil; break }
                inside = parity
            }
            guard containers[g] != nil else { break }
            if inside { around.append(h) }
        }
        if containers[g] != nil { containers[g] = around }
    }

    // Outermost first, so each shell's parent is placed before the shells inside it.
    var kind = [ShellKind](repeating: .other, count: shellCount)
    var parentOf = [Int](repeating: -1, count: shellCount)
    let order = (0..<shellCount).filter { sound[$0] && containers[$0] != nil }.sorted {
        let a = containers[$0]!.count, b = containers[$1]!.count
        return a != b ? a < b : $0 < $1
    }
    for g in order {
        let around = containers[g]!
        if around.isEmpty {
            kind[g] = volume[g] > 0 ? .part : .other
            continue
        }
        // The innermost shell around this one: the one inside the most others (ties to the lowest index).
        var innermost = around[0]
        for h in around.dropFirst() where (containers[h]?.count ?? -1) > (containers[innermost]?.count ?? -1) { innermost = h }
        guard containers[innermost] != nil else { continue }
        parentOf[g] = innermost
        switch (volume[g] < 0, kind[innermost]) {
        case (true, .part), (true, .solidInPocket): kind[g] = .pocket
        case (false, .pocket): kind[g] = .solidInPocket
        default: kind[g] = .other
        }
    }

    // Pockets directly inside one of the model's parts are filled; everything placed inside them goes with them.
    let topPockets = (0..<shellCount).filter { kind[$0] == .pocket && parentOf[$0] >= 0 && kind[parentOf[$0]] == .part }
    var isTopPocket = [Bool](repeating: false, count: shellCount)
    for p in topPockets { isTopPocket[p] = true }
    var removed = [Bool](repeating: false, count: shellCount)
    var inside = [Int](repeating: 0, count: shellCount)
    for g in 0..<shellCount {
        if isTopPocket[g] { removed[g] = true; continue }
        guard let around = containers[g], sound[g] else { continue }
        let owners = around.filter { isTopPocket[$0] }
        guard !owners.isEmpty else { continue }
        removed[g] = true
        for p in owners { inside[p] += 1 }
    }
    // The fill's own check: every corner of each shell it removes, not only the samples that placed it, is inside the
    // shell around it. A shell crossing that surface isn't wholly a pocket, and removing it would change the part.
    var verified = false
    if verifyRemoved {
        verified = true
        var seen = [Bool](repeating: false, count: points.count)
        var verifyBudget = hiddenPocketsRayTestLimit
        outer: for g in 0..<shellCount where removed[g] {
            if isCancelled() { throw HiddenPocketsError.stopped }
            let around = parentOf[g]
            guard around >= 0, grids[around] != nil, let lists = trianglesOf else { verified = false; break }
            for t in lists[g] {
                for j in 0..<3 {
                    let id = Int(ids[3 * Int(t) + j])
                    guard !seen[id] else { continue }
                    seen[id] = true
                    guard grids[around]!.contains(SIMD3<Double>(points[id]) - origin, budget: &verifyBudget) == true else {
                        verified = false
                        break outer
                    }
                }
            }
        }
    }
    var added = 0.0
    for g in 0..<shellCount where removed[g] { added -= volume[g] }
    let pockets = topPockets.map { p in
        HiddenPocket(triangles: triangles[p], volumeMM3: -volume[p], low: low[p], high: high[p], shellsInside: inside[p])
    }
    let parts = (0..<shellCount).filter { kind[$0] == .part }.count
    let innerShells = removed.filter { $0 }.count - pockets.count
    let complete = (0..<shellCount).allSatisfy { !sound[$0] || containers[$0] != nil }
    let report = HiddenPocketsReport(shells: shellCount, pockets: pockets, separateParts: parts, shellsInsidePockets: innerShells,
                                     otherShells: shellCount - parts - pockets.count - innerShells, complete: complete,
                                     addedVolumeMM3: added)
    return HiddenPocketsAnalysis(report: report, shellOf: shellOf, removed: removed, verified: verified)
}

/// Ray parity against one shell's triangles, found through a grid over their XY extents. The ray runs almost straight
/// up, leaning by about 0.04° in a direction unlikely to follow an edge, so it meets only the cells along a short path.
private struct HiddenPocketsShellGrid {
    private let a: [SIMD3<Double>], e1: [SIMD3<Double>], e2: [SIMD3<Double>]
    private let low: SIMD2<Double>, cell: Double, columns: Int, rows: Int
    private let start: [Int32], items: [Int32]
    private let top: Double
    private var stamp: [Int32], query: Int32 = 0
    private static let ray = simd_normalize(SIMD3<Double>(0.000713, 0.000529, 1))
    /// Cell entries allowed before the grid falls back to one cell.
    private static let entryLimit = 16_000_000

    init(triangles: [(SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)]) {
        a = triangles.map { $0.0 }
        e1 = triangles.map { $0.1 - $0.0 }
        e2 = triangles.map { $0.2 - $0.0 }
        var lo = SIMD2<Double>(repeating: .greatestFiniteMagnitude), hi = -lo
        var highest = -Double.greatestFiniteMagnitude
        for t in triangles {
            for p in [t.0, t.1, t.2] { lo = simd_min(lo, SIMD2(p.x, p.y)); hi = simd_max(hi, SIMD2(p.x, p.y)); highest = max(highest, p.z) }
        }
        top = highest
        let side = min(max(Int(Double(triangles.count).squareRoot()), 1), 256)
        let extent = simd_max(hi - lo, SIMD2(repeating: 1e-9))
        var size = max(extent.x, extent.y) / Double(side)
        var cols = min(Int(extent.x / size) + 1, side + 1), rws = min(Int(extent.y / size) + 1, side + 1)
        func span(_ t: (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>), _ size: Double, _ cols: Int, _ rws: Int) -> (Int, Int, Int, Int) {
            let x0 = min(t.0.x, t.1.x, t.2.x), x1 = max(t.0.x, t.1.x, t.2.x)
            let y0 = min(t.0.y, t.1.y, t.2.y), y1 = max(t.0.y, t.1.y, t.2.y)
            func c(_ value: Double, _ origin: Double, _ limit: Int) -> Int { min(max(Int((value - origin) / size), 0), limit - 1) }
            return (c(x0, lo.x, cols), c(x1, lo.x, cols), c(y0, lo.y, rws), c(y1, lo.y, rws))
        }
        var entries = 0
        for t in triangles {
            let (cx0, cx1, cy0, cy1) = span(t, size, cols, rws)
            entries += (cx1 - cx0 + 1) * (cy1 - cy0 + 1)
            if entries > Self.entryLimit { break }
        }
        if entries > Self.entryLimit { size = max(extent.x, extent.y) * 2; cols = 1; rws = 1 }
        var counts = [Int32](repeating: 0, count: cols * rws + 1)
        for t in triangles {
            let (cx0, cx1, cy0, cy1) = span(t, size, cols, rws)
            for y in cy0...cy1 { for x in cx0...cx1 { counts[y * cols + x + 1] += 1 } }
        }
        for k in 0..<(cols * rws) { counts[k + 1] += counts[k] }
        var fill = counts
        var list = [Int32](repeating: 0, count: Int(counts[cols * rws]))
        for (index, t) in triangles.enumerated() {
            let (cx0, cx1, cy0, cy1) = span(t, size, cols, rws)
            for y in cy0...cy1 { for x in cx0...cx1 { list[Int(fill[y * cols + x])] = Int32(index); fill[y * cols + x] += 1 } }
        }
        low = lo; cell = size; columns = cols; rows = rws; start = counts; items = list
        stamp = [Int32](repeating: -1, count: triangles.count)
    }

    /// Whether `point` is inside this closed shell, or nil once `budget` ray–triangle tests are spent.
    mutating func contains(_ point: SIMD3<Double>, budget: inout Int) -> Bool? {
        query &+= 1
        let ray = Self.ray
        let reach = max(0, top - point.z) / ray.z + 1
        let end = point + ray * reach
        func c(_ value: Double, _ origin: Double, _ limit: Int) -> Int { min(max(Int((value - origin) / cell), 0), limit - 1) }
        let cx0 = c(min(point.x, end.x), low.x, columns), cx1 = c(max(point.x, end.x), low.x, columns)
        let cy0 = c(min(point.y, end.y), low.y, rows), cy1 = c(max(point.y, end.y), low.y, rows)
        var hits = 0
        for y in cy0...cy1 {
            for x in cx0...cx1 {
                let k = y * columns + x
                for entry in Int(start[k])..<Int(start[k + 1]) {
                    let t = Int(items[entry])
                    guard stamp[t] != query else { continue }
                    stamp[t] = query
                    budget -= 1
                    guard budget >= 0 else { return nil }
                    // Möller–Trumbore, as `repairMesh` tests containment.
                    let h = simd_cross(ray, e2[t]), det = simd_dot(e1[t], h)
                    guard abs(det) > 1e-18 else { continue }
                    let s = point - a[t], u = simd_dot(s, h) / det
                    guard u >= 0, u <= 1 else { continue }
                    let q = simd_cross(s, e1[t]), w = simd_dot(ray, q) / det
                    guard w >= 0, u + w <= 1 else { continue }
                    if simd_dot(e2[t], q) / det > 1e-12 { hits += 1 }
                }
            }
        }
        return hits % 2 == 1
    }
}

// MARK: - Fill

/// Saves a copy of `mesh` with its hidden pockets filled: each pocket's triangles are removed, with every shell inside
/// it, so the pocket becomes solid. The outer surface and every separate part are unchanged. Returns a skipped result
/// (with the reason) when no copy can be made, and throws only when `isCancelled` reports true.
///
/// A returned copy is one closed, outward, sound mesh with fewer shells, the same bounding box and a larger volume: the
/// input's plus exactly the pockets', less the solids that were inside them.
func fillHiddenPocketsCopy(of mesh: STLMesh, boxComparisonLimit: Int = hiddenPocketsBoxComparisonLimit,
                           isCancelled: () -> Bool = { false }) throws -> HiddenPocketsResult {
    let empty = HiddenPocketsReport(shells: 0, pockets: [], separateParts: 0, shellsInsidePockets: 0, otherShells: 0,
                                    complete: true, addedVolumeMM3: 0)
    func skip(_ reason: HiddenPocketsSkipReason, report: HiddenPocketsReport = empty, shells: Int = 0) -> HiddenPocketsResult {
        HiddenPocketsResult(mesh: nil, data: nil, skipped: reason, report: report, filledPockets: 0, removedInnerShells: 0,
                            addedVolumeMM3: 0, shellsBefore: shells, shellsAfter: shells)
    }
    let count = mesh.triangleCount
    guard count <= hiddenPocketsMaximumTriangles, count <= STLMesh.maximumTriangles else { return skip(.tooManyTriangles) }
    guard let before = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw HiddenPocketsError.stopped }
    guard meshHealthIsSound(before), before.signedVolume > 0 else { return skip(.notClosedSolid, shells: before.shells) }
    let analysis = try hiddenPocketsAnalysis(mesh, boxComparisonLimit: boxComparisonLimit, verifyRemoved: true, isCancelled: isCancelled)
    let report = analysis.report
    // An unjudged shell could be a loose solid inside a pocket, which a fill would bury, so an incomplete check never fills.
    guard report.complete else { return skip(.tooManyParts, report: report, shells: before.shells) }
    guard !report.pockets.isEmpty else { return skip(.noPockets, report: report, shells: before.shells) }
    guard analysis.verified else { return skip(.couldNotConfirm, report: report, shells: before.shells) }

    var floats: [Float] = []
    floats.reserveCapacity(mesh.vertices.count)
    for t in 0..<count where !analysis.removed[Int(analysis.shellOf[t])] {
        floats.append(contentsOf: mesh.vertices[(t * 9)..<(t * 9 + 9)])
    }
    if isCancelled() { throw HiddenPocketsError.stopped }
    guard let assembled = try? STLMesh.validated(floats) else { return skip(.resultFailedChecks, report: report, shells: before.shells) }
    let data = assembled.binarySTL()
    guard let parsed = try? STLMesh.parse(data), parsed.triangleCount == floats.count / 9 else {
        return skip(.resultFailedChecks, report: report, shells: before.shells)
    }
    guard let after = analyzeMeshHealth(parsed, isCancelled: isCancelled) else { throw HiddenPocketsError.stopped }
    let removedShells = report.removableBodies
    guard parsed.minimum == mesh.minimum, parsed.maximum == mesh.maximum,
          hiddenPocketsFillIsSound(before: before, after: after, removedShells: removedShells, addedVolumeMM3: report.addedVolumeMM3) else {
        return skip(.resultFailedChecks, report: report, shells: before.shells)
    }
    return HiddenPocketsResult(mesh: parsed, data: data, skipped: nil, report: report, filledPockets: report.count,
                               removedInnerShells: report.shellsInsidePockets,
                               addedVolumeMM3: after.signedVolume - before.signedVolume, shellsBefore: before.shells,
                               shellsAfter: after.shells)
}

/// A filled copy can be saved only when it is sound, no worse than the input, has exactly the removed shells fewer, and
/// its volume grew by the pockets' less the solids inside them.
func hiddenPocketsFillIsSound(before: MeshHealthReport, after: MeshHealthReport, removedShells: Int, addedVolumeMM3: Double) -> Bool {
    guard meshHealthIsSound(after), !meshToolMadeWorse(before: before, after: after), after.signedVolume > 0,
          removedShells > 0, after.shells == before.shells - removedShells, addedVolumeMM3 > 0,
          after.signedVolume > before.signedVolume else { return false }
    let added = after.signedVolume - before.signedVolume
    return abs(added - addedVolumeMM3) <= max(1e-6, addedVolumeMM3 * 1e-6) + before.signedVolume * 1e-9
}
