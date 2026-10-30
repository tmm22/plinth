import Foundation
import simd

// Bottom-edge chamfer: a 45° chamfer round the outer edge of a part's bed face, so the first layer's spread ("elephant's
// foot") stays inside the part's outline. Slant prints a 0.3 mm first layer on a textured bed with no brims; 0.4 mm
// suits that first layer (0.2–0.5 mm is the usual range for fitted parts).
//
// The part must stand on a flat bed face with upright sides for the chamfer's height. Over that height the solid is
// then a prism of its footprint, so the chamfer is built directly, as the Size and base tools build their results:
// every triangle above the plane z = bed + size is kept, the upright walls crossing it are cut there, and below it the
// walls and bed face are replaced by a 45° band from the outline at the plane down to the outline moved in by the size
// at the bed, plus a new bed face. Hole entries in the bed face keep their walls and size by default, so a bore keeps its
// fitted size at the bed. No Boolean library is involved: the result is exact, closed and the same bytes on every run.
//
// Pure and deterministic: triangles, points, loops and segments are walked in index order, and dictionaries are only
// used for lookups, never iterated for output.

// MARK: - Defaults

/// 0.4 mm suits Slant's 0.3 mm first layer; 0.2–0.5 mm is the usual range for fitted parts.
let bottomChamferDefaultSizeMM: Float = 0.4
/// The sizes `bottomChamferCopy` accepts.
let bottomChamferSizeRangeMM: ClosedRange<Float> = 0.1...1
/// Footprints narrower than this (across the bed outline's bounding box) are left alone: the chamfer would take too
/// much of their contact.
let bottomChamferMinimumFootprintMM: Float = 5
/// The chamfer keeps at least this share of the bed contact, so thin walls keep their grip on a brimless bed.
let bottomChamferMinimumContactFraction = 0.6
/// Meshes above this many triangles are skipped: the library's own limit. In a release build one run on a holed ring
/// took 0.03 s at 20,000 triangles, 0.12 s at 100,000 and 0.51 s at 400,000 (`BottomChamferTests.testTiming`), so
/// nothing smaller is needed.
let bottomChamferMaximumTriangles = 500_000
/// A wall below the plane counts as upright when its normal's vertical part is at most this (about 0.1°, under 1 µm
/// of drift over the chamfer's height).
let bottomChamferUprightTolerance = 0.002
/// A corner whose mitre would reach further than this many chamfer sizes from it (a turn sharper than about 166°) is
/// too sharp to chamfer.
let bottomChamferMaximumMitre = 8.0
/// Bed triangles: within this distance of the lowest point and facing straight down, the rule `bottomContactAreaMM2`
/// and the internal walls use.
private let bottomChamferBedToleranceMM: Float = 0.0001
/// Less flat downward area than this at the lowest point is not a bed face.
private let bottomChamferMinimumBedAreaMM2 = 1.0
/// The cut plane keeps this far (in mm) from every vertex height, so no cut piece is a sliver.
private let bottomChamferPlaneClearanceMM: Float = 0.002
/// The furthest the plane may move up to find that gap.
private let bottomChamferMaximumNudgeMM: Float = 0.1
/// Segment pairs the outline checks may compare before the outline counts as too intricate.
private let bottomChamferCheckWorkLimit = 100_000_000

// MARK: - Types

/// Why no copy was made. Each is a normal outcome, not an error.
enum BottomChamferSkipReason: String, Equatable, Sendable, CaseIterable {
    case notClosedSolid
    case tooManyTriangles
    case noFlatBedFace
    case tooSmall
    /// Something other than upright walls lies within the chamfer's height of the bed: the sides flare or step.
    case sidesNotUpright
    /// The sides step in near the bed, as an existing chamfer or rounded edge does.
    case alreadyTapered
    case tooIntricate
    case wouldReduceContactTooMuch
    case resultFailedChecks
    /// A flat, downward face lies within the chamfer's height of the bed: a shallow recess (such as debossed text) or a
    /// step in the bottom face.
    case recessInBedFace

    var message: String {
        switch self {
        case .notClosedSolid:
            return "A bottom chamfer needs a closed, outward-facing mesh with no zero-area triangles. Repair a copy first."
        case .tooManyTriangles:
            return "This model has more than \(bottomChamferMaximumTriangles.formatted()) triangles, too many for a bottom chamfer. Simplify a copy first."
        case .noFlatBedFace:
            return "No bottom chamfer was added: the model has no flat face at its lowest point. Orient it with a flat face down first."
        case .tooSmall:
            return "No bottom chamfer was added: the part’s footprint is under \(Int(bottomChamferMinimumFootprintMM)) mm across, or it is too thin, so a chamfer would take too much of it."
        case .sidesNotUpright:
            return "No bottom chamfer was added: the sides aren’t upright just above the bed, so the chamfer couldn’t follow them."
        case .alreadyTapered:
            return "No bottom chamfer was added: the bottom edge already slopes in, like a chamfer or rounded edge."
        case .tooIntricate:
            return "No bottom chamfer was added: the bottom edge is too intricate, with sharp corners, narrow parts or holes close to the edge."
        case .wouldReduceContactTooMuch:
            return "No bottom chamfer was added: it would take more than \(Int(((1 - bottomChamferMinimumContactFraction) * 100).rounded()))% of the part’s contact with the bed."
        case .resultFailedChecks:
            return "No bottom chamfer was added: the result didn’t pass Plinth’s mesh checks."
        case .recessInBedFace:
            return "No bottom chamfer was added: the bottom face has a shallow recess or step."
        }
    }
}

enum BottomChamferError: LocalizedError, Equatable {
    case invalidSize
    case stopped

    var errorDescription: String? {
        switch self {
        case .invalidSize: return "Use a chamfer from 0.1 to 1 mm."
        case .stopped: return "Stopped. Nothing was saved."
        }
    }
}

struct BottomChamferResult: Sendable {
    /// The chamfered copy, or nil when skipped.
    let mesh: STLMesh?
    /// The copy as binary STL, the bytes to save.
    let data: Data?
    let skipped: BottomChamferSkipReason?
    /// The chamfer's height and inset as built: the size asked for, raised by at most 0.1 mm (usually a few
    /// micrometres or nothing) so the cut stays clear of the model's own vertices. Its faces are exactly 45°.
    let sizeMM: Float
    /// Outer outlines of the bed face that were chamfered.
    let chamferedOutlines: Int
    /// Hole entries in the bed face that were chamfered (only with `chamferHoleEntries`).
    let chamferedHoleEntries: Int
    /// Hole entries in the bed face left at their size.
    let keptHoleEntries: Int
    /// The length of the chamfered outlines.
    let outlineLengthMM: Double
    let removedVolumeMM3: Double
    let contactBeforeMM2: Double
    let contactAfterMM2: Double
    let shellsBefore: Int
    let shellsAfter: Int

    var applied: Bool { mesh != nil }
}

/// One line for the seller, such as "Adds a 0.4 mm chamfer round the bottom edge (160 mm of outline), so the first
/// layer’s spread stays inside the part’s outline. 1 hole entry keeps its size. Bed contact 1,600 → 1,536 mm²."
func bottomChamferSummary(_ result: BottomChamferResult) -> String {
    if let reason = result.skipped { return reason.message }
    let size = String(format: "%.1f", result.sizeMM)
    var text = "Adds a \(size) mm chamfer round the bottom edge (\(Int(result.outlineLengthMM.rounded()).formatted()) mm of outline), so the first layer’s spread stays inside the part’s outline."
    if result.chamferedHoleEntries > 0 {
        text += result.chamferedHoleEntries == 1 ? " 1 hole entry is chamfered too, so it is wider at the bed."
            : " \(result.chamferedHoleEntries.formatted()) hole entries are chamfered too, so they are wider at the bed."
    }
    if result.keptHoleEntries > 0 {
        text += result.keptHoleEntries == 1 ? " 1 hole entry keeps its size." : " \(result.keptHoleEntries.formatted()) hole entries keep their size."
    }
    text += " Bed contact \(Int(result.contactBeforeMM2.rounded()).formatted()) → \(Int(result.contactAfterMM2.rounded()).formatted()) mm²."
    return text
}

// MARK: - Engine

/// Chamfers the outer bottom edge of a copy of `mesh`, which must stand on its bed face: a flat, downward face at its
/// lowest Z, with upright sides for at least `sizeMM` above it. Hole entries in the bed face keep their size unless
/// `chamferHoleEntries` is true. Returns a skipped result (with the reason) when no copy can be made, and throws only for
/// a size outside `bottomChamferSizeRangeMM` or when `isCancelled` reports true.
///
/// A returned copy is a closed, outward, sound solid with the input's shell count and bounding box (heights exact, across
/// the bed within 1 µm, since a cut wall point may round by a Float step). Only the part
/// within `sizeMM` of the bed changes: the outline at the bed moves in by `sizeMM` and a 45° band joins it to the
/// unchanged sides. Its volume falls by exactly the chamfer's (checked against an independent prismatoid sum).
func bottomChamferCopy(of mesh: STLMesh, sizeMM: Float = bottomChamferDefaultSizeMM, chamferHoleEntries: Bool = false,
                       isCancelled: () -> Bool = { false }) throws -> BottomChamferResult {
    guard sizeMM.isFinite, bottomChamferSizeRangeMM.contains(sizeMM) else { throw BottomChamferError.invalidSize }
    func skip(_ reason: BottomChamferSkipReason, shells: Int = 0, contact: Double = 0) -> BottomChamferResult {
        BottomChamferResult(mesh: nil, data: nil, skipped: reason, sizeMM: sizeMM, chamferedOutlines: 0, chamferedHoleEntries: 0,
                            keptHoleEntries: 0, outlineLengthMM: 0, removedVolumeMM3: 0, contactBeforeMM2: contact,
                            contactAfterMM2: contact, shellsBefore: shells, shellsAfter: shells)
    }
    let count = mesh.triangleCount
    guard count <= bottomChamferMaximumTriangles, count <= STLMesh.maximumTriangles else { return skip(.tooManyTriangles) }
    guard let before = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw BottomChamferError.stopped }
    guard meshHealthIsSound(before), before.signedVolume > 0 else { return skip(.notClosedSolid, shells: before.shells) }
    let shells = before.shells
    let bounds = meshCoordinateBounds(mesh.vertices)
    let floor = bounds.low.z
    let v = mesh.vertices
    let check = 8192

    // Weld identical coordinates in first-seen order, as the mesh check does.
    var ids = [Int32](repeating: 0, count: count * 3)
    var points: [SIMD3<Float>] = []
    do {
        var lookup: [SIMD3<Float>: Int32] = [:]
        lookup.reserveCapacity(min(count * 3, 1 << 21))
        for corner in 0..<(count * 3) {
            if corner % check == 0, isCancelled() { throw BottomChamferError.stopped }
            let p = SIMD3<Float>(v[corner * 3] + 0, v[corner * 3 + 1] + 0, v[corner * 3 + 2] + 0)
            if let id = lookup[p] { ids[corner] = id } else {
                let id = Int32(points.count)
                lookup[p] = id
                points.append(p)
                ids[corner] = id
            }
        }
    }

    // The bed face: flat, downward triangles at the lowest point.
    var isBed = [Bool](repeating: false, count: count)
    var bedArea = 0.0
    for t in 0..<count {
        if t % check == 0, isCancelled() { throw BottomChamferError.stopped }
        let a = points[Int(ids[3 * t])], b = points[Int(ids[3 * t + 1])], c = points[Int(ids[3 * t + 2])]
        guard max(a.z, b.z, c.z) <= floor + bottomChamferBedToleranceMM else { continue }
        let cross = simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))
        let length = simd_length(cross)
        guard length > 0, cross.z / length <= -0.999999 else { continue }
        isBed[t] = true
        bedArea += length / 2
    }
    guard bedArea >= bottomChamferMinimumBedAreaMM2 else { return skip(.noFlatBedFace, shells: shells) }
    guard bounds.high.z - floor >= 2 * sizeMM else { return skip(.tooSmall, shells: shells, contact: bedArea) }

    // The plane, nudged up past vertex heights in ascending order until it is at least 2 µm from every vertex.
    let requested = floor + sizeMM
    var near: [Float] = []
    for p in points where p.z >= requested - bottomChamferPlaneClearanceMM
        && p.z <= requested + bottomChamferMaximumNudgeMM + bottomChamferPlaneClearanceMM {
        near.append(p.z)
    }
    near.sort()
    var h = requested
    for z in near where abs(z - h) < bottomChamferPlaneClearanceMM { h = max(h, z + bottomChamferPlaneClearanceMM) }
    guard h <= requested + bottomChamferMaximumNudgeMM else { return skip(.tooIntricate, shells: shells, contact: bedArea) }
    guard h < bounds.high.z else { return skip(.tooSmall, shells: shells, contact: bedArea) }
    let size = Double(h) - Double(floor)

    // Keep everything above the plane; cut the upright walls that cross it. Anything else below it ends the attempt.
    var kept: [SIMD3<Float>] = []
    kept.reserveCapacity(count * 3)
    var cutPoints: [SIMD3<Float>] = []
    var edgePoint: [UInt64: Int32] = [:]
    func crossing(_ p: Int32, _ q: Int32) -> Int {
        let low = min(p, q), high = max(p, q)
        let key = UInt64(UInt32(low)) << 32 | UInt64(UInt32(high))
        if let existing = edgePoint[key] { return Int(existing) }
        // Computed from the lower-numbered end, so both triangles sharing the edge get the same point.
        let a = SIMD3<Double>(points[Int(low)]), b = SIMD3<Double>(points[Int(high)])
        let s = (Double(h) - a.z) / (b.z - a.z)
        let point = SIMD3<Float>(Float(a.x + (b.x - a.x) * s), Float(a.y + (b.y - a.y) * s), h)
        edgePoint[key] = Int32(cutPoints.count)
        cutPoints.append(point)
        return cutPoints.count - 1
    }
    /// The triangle (or the better split of the quad) with the larger smallest shape ratio, so cut pieces aren't slivers.
    func quality(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> Double {
        let pa = SIMD3<Double>(a), pb = SIMD3<Double>(b), pc = SIMD3<Double>(c)
        let longest = max(simd_length_squared(pb - pa), simd_length_squared(pc - pb), simd_length_squared(pa - pc))
        return longest > 0 ? simd_length(simd_cross(pb - pa, pc - pa)) / longest : 0
    }
    var segments: [(start: Int, end: Int)] = []
    var slopedDown = 0, slopedOther = 0, recessCeilings = 0
    for t in 0..<count {
        if t % check == 0, isCancelled() { throw BottomChamferError.stopped }
        let c = [ids[3 * t], ids[3 * t + 1], ids[3 * t + 2]]
        let p = c.map { points[Int($0)] }
        let above = p.map { $0.z > h }
        let aboveCount = above.filter { $0 }.count
        if aboveCount == 3 { kept.append(contentsOf: p); continue }
        if isBed[t] { continue }
        let cross = simd_cross(SIMD3<Double>(p[1] - p[0]), SIMD3<Double>(p[2] - p[0]))
        let normalZ = cross.z / simd_length(cross)
        guard abs(normalZ) <= bottomChamferUprightTolerance else {
            if normalZ <= -0.999 { recessCeilings += 1 } else if normalZ < 0 { slopedDown += 1 } else { slopedOther += 1 }
            continue
        }
        switch aboveCount {
        case 1:
            let k = above.firstIndex(of: true)!
            let a = k, b = (k + 1) % 3, cc = (k + 2) % 3
            let ab = crossing(c[a], c[b]), ca = crossing(c[cc], c[a])
            kept.append(contentsOf: [p[a], cutPoints[ab], cutPoints[ca]])
            segments.append((ab, ca))
        case 2:
            let k = above.firstIndex(of: false)!
            let cc = k, a = (k + 1) % 3, b = (k + 2) % 3
            let bc = crossing(c[b], c[cc]), ca = crossing(c[cc], c[a])
            let xb = cutPoints[bc], xa = cutPoints[ca]
            // The quad a, b, xb, xa: split along whichever diagonal gives the better-shaped triangles.
            if min(quality(p[a], p[b], xb), quality(p[a], xb, xa)) >= min(quality(p[a], p[b], xa), quality(p[b], xb, xa)) {
                kept.append(contentsOf: [p[a], p[b], xb, p[a], xb, xa])
            } else {
                kept.append(contentsOf: [p[a], p[b], xa, p[b], xb, xa])
            }
            segments.append((bc, ca))
        default:
            continue
        }
    }
    if recessCeilings > 0 { return skip(.recessInBedFace, shells: shells, contact: bedArea) }
    if slopedDown + slopedOther > 0 {
        return skip(slopedOther == 0 ? .alreadyTapered : .sidesNotUpright, shells: shells, contact: bedArea)
    }
    guard !segments.isEmpty else { return skip(.resultFailedChecks, shells: shells, contact: bedArea) }
    edgePoint = [:]

    // Each crossing edge starts exactly one outline segment and ends one, so the segments chain into loops. They run the
    // way the kept surface's open edges run: anticlockwise round outer outlines (seen from above), clockwise round holes.
    var next = [Int](repeating: -1, count: cutPoints.count)
    var incoming = [Int](repeating: 0, count: cutPoints.count)
    for segment in segments {
        guard next[segment.start] < 0 else { return skip(.resultFailedChecks, shells: shells, contact: bedArea) }
        next[segment.start] = segment.end
        incoming[segment.end] += 1
    }
    guard next.allSatisfy({ $0 >= 0 }), incoming.allSatisfy({ $0 == 1 }) else {
        return skip(.resultFailedChecks, shells: shells, contact: bedArea)
    }
    var loops: [[Int]] = []
    do {
        var visited = [Bool](repeating: false, count: cutPoints.count)
        for start in 0..<cutPoints.count where !visited[start] {
            var loop: [Int] = []
            var p = start
            while !visited[p] { visited[p] = true; loop.append(p); p = next[p] }
            guard p == start, loop.count >= 3 else { return skip(.resultFailedChecks, shells: shells, contact: bedArea) }
            loops.append(loop)
        }
    }

    let flat = cutPoints.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
    var footLow = SIMD2<Double>(repeating: .greatestFiniteMagnitude), footHigh = -footLow
    for p in flat { footLow = simd_min(footLow, p); footHigh = simd_max(footHigh, p) }
    guard (footHigh - footLow).min() >= Double(bottomChamferMinimumFootprintMM) else {
        return skip(.tooSmall, shells: shells, contact: bedArea)
    }
    let areas = loops.map { loop in bottomChamferLoopArea(loop.map { flat[$0] }) }
    guard areas.allSatisfy({ $0 != 0 && $0.isFinite }) else { return skip(.tooIntricate, shells: shells, contact: bedArea) }
    let chamfered = loops.indices.map { areas[$0] > 0 || chamferHoleEntries }

    // The bottom outline of each loop: for a chamfered loop, its corners moved in by `size` (a mitre, so each band face
    // is a plane at exactly 45°) and the points between them projected onto the moved edges; for a kept hole entry, the
    // loop itself. `bottomOf` gives each top point's bottom point.
    var bottom: [[SIMD2<Double>]] = []
    var bottomOf: [[Int]] = []
    for (k, loop) in loops.enumerated() {
        if isCancelled() { throw BottomChamferError.stopped }
        let top = loop.map { flat[$0] }
        guard chamfered[k] else { bottom.append(top); bottomOf.append(Array(top.indices)); continue }
        guard let band = bottomChamferBand(top, by: size) else { return skip(.tooIntricate, shells: shells, contact: bedArea) }
        bottom.append(band.bottom)
        bottomOf.append(band.bottomOf)
    }
    switch bottomChamferOutlineCheck(top: loops.map { $0.map { flat[$0] } }, bottom: bottom, chamfered: chamfered,
                                     size: size, isCancelled: isCancelled) {
    case .stopped: throw BottomChamferError.stopped
    case .tooIntricate: return skip(.tooIntricate, shells: shells, contact: bedArea)
    case .clear: break
    }

    // The new bed face: the bottom outlines, holes joined to their outlines, filled and turned to face down.
    var planar: [SIMD2<Double>] = []
    var bedLoops: [[Int]] = []
    for outline in bottom {
        bedLoops.append(Array(planar.count..<(planar.count + outline.count)))
        planar.append(contentsOf: outline)
    }
    var bedTriangles: [SIMD3<Int32>]
    do {
        // Holes are joined at true corners only: a join at a point along a straight edge leaves the fill a sliver it
        // can't flip away. The points along each edge go back in once the holes are joined.
        var cornerLoops: [[Int]] = []
        var following: [Int: (next: Int, between: [Int])] = [:]
        for loop in bedLoops {
            let (start, positions) = bottomChamferCorners(loop.map { planar[$0] })
            guard positions.count >= 3 else { cornerLoops.append(loop); continue }
            let n = loop.count
            let ids = positions.map { loop[(start + $0) % n] }
            for (m, id) in ids.enumerated() {
                let end = m + 1 < positions.count ? positions[m + 1] : n
                following[id] = (ids[(m + 1) % ids.count], ((positions[m] + 1)..<end).map { loop[(start + $0) % n] })
            }
            cornerLoops.append(ids)
        }
        let bridging = try internalWallsBridgedLoops(points: planar, loops: cornerLoops, isCancelled: isCancelled)
        guard let joined = bridging.loops else { return skip(.tooIntricate, shells: shells, contact: bedArea) }
        let merged = joined.map { polygon in
            var full: [Int] = []
            for (i, id) in polygon.enumerated() {
                full.append(id)
                if let after = following[id], after.next == polygon[(i + 1) % polygon.count] { full.append(contentsOf: after.between) }
            }
            return full
        }
        bedTriangles = try triangulatePlanarRegion(points: planar, loops: merged, isCancelled: isCancelled)
    } catch InternalWallsError.stopped {
        throw BottomChamferError.stopped
    } catch MeshFitError.stopped {
        throw BottomChamferError.stopped
    } catch {
        return skip(.tooIntricate, shells: shells, contact: bedArea)
    }
    bottomChamferFlipSlivers(&bedTriangles, points: planar)
    var contactAfter = 0.0
    for t in bedTriangles {
        let a = planar[Int(t.x)], b = planar[Int(t.y)], c = planar[Int(t.z)]
        contactAfter += ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
    }
    guard contactAfter >= bottomChamferMinimumContactFraction * bedArea else {
        return skip(.wouldReduceContactTooMuch, shells: shells, contact: bedArea)
    }

    // Assemble: the kept surface, then each loop's band (45° where chamfered, upright for a kept hole entry), then the bed.
    var corners = kept
    kept = []
    var expectedRemoved = 0.0, outlineLength = 0.0
    for (k, loop) in loops.enumerated() {
        let n = loop.count
        let low = bottom[k].map { SIMD3<Float>(Float($0.x), Float($0.y), floor) }
        let top = loop.map { flat[$0] }
        // The section halfway down runs through the middle of every edge joining the top to the bottom, in order.
        var middle: [SIMD2<Double>] = []
        for i in 0..<n {
            let j = (i + 1) % n
            let bi = bottomOf[k][i], bj = bottomOf[k][j]
            let pi = cutPoints[loop[i]], pj = cutPoints[loop[j]]
            middle.append((top[i] + bottom[k][bi]) / 2)
            if bi != bj {
                corners.append(contentsOf: [low[bi], low[bj], pj, low[bi], pj, pi])
                middle.append((top[j] + bottom[k][bi]) / 2)
            } else {
                corners.append(contentsOf: [low[bi], pj, pi])
            }
        }
        guard chamfered[k] else { continue }
        // Prismatoid: the slab under the plane less the band's frustum. Exact, because every band face is a flat
        // triangle from the top to the bottom, so the section's area is quadratic in height.
        let topArea = areas[k], middleArea = bottomChamferLoopArea(middle), bottomArea = bottomChamferLoopArea(bottom[k])
        expectedRemoved += size * topArea - size / 6 * (topArea + 4 * middleArea + bottomArea)
        for i in 0..<n { outlineLength += simd_distance(top[i], top[(i + 1) % n]) }
    }
    for t in bedTriangles {
        func at(_ index: Int32) -> SIMD3<Float> { SIMD3(Float(planar[Int(index)].x), Float(planar[Int(index)].y), floor) }
        corners.append(contentsOf: [at(t.x), at(t.z), at(t.y)])
    }
    if isCancelled() { throw BottomChamferError.stopped }

    guard corners.count / 3 <= STLMesh.maximumTriangles else { return skip(.resultFailedChecks, shells: shells, contact: bedArea) }
    var floats: [Float] = []
    floats.reserveCapacity(corners.count * 3)
    for p in corners { floats.append(p.x); floats.append(p.y); floats.append(p.z) }
    corners = []
    guard let assembled = try? STLMesh.validated(floats) else { return skip(.resultFailedChecks, shells: shells, contact: bedArea) }
    let data = assembled.binarySTL()
    guard let parsed = try? STLMesh.parse(data), parsed.triangleCount == floats.count / 9 else {
        return skip(.resultFailedChecks, shells: shells, contact: bedArea)
    }
    guard let after = analyzeMeshHealth(parsed, isCancelled: isCancelled) else { throw BottomChamferError.stopped }
    // Heights are exact; across the bed a cut wall may round by a Float step, so 1 µm is allowed there.
    let lowShift = simd_abs(parsed.minimum - bounds.low), highShift = simd_abs(parsed.maximum - bounds.high)
    guard parsed.minimum.z == bounds.low.z, parsed.maximum.z == bounds.high.z,
          max(lowShift.x, lowShift.y, highShift.x, highShift.y) <= 0.001,
          bottomChamferResultIsSound(before: before, after: after, expectedRemovedMM3: expectedRemoved) else {
        return skip(.resultFailedChecks, shells: shells, contact: bedArea)
    }
    let chamferedOuter = loops.indices.filter { areas[$0] > 0 }.count
    let holes = loops.count - chamferedOuter
    return BottomChamferResult(mesh: parsed, data: data, skipped: nil, sizeMM: Float(size), chamferedOutlines: chamferedOuter,
                               chamferedHoleEntries: chamferHoleEntries ? holes : 0, keptHoleEntries: chamferHoleEntries ? 0 : holes,
                               outlineLengthMM: outlineLength, removedVolumeMM3: before.signedVolume - after.signedVolume,
                               contactBeforeMM2: bedArea, contactAfterMM2: contactAfter, shellsBefore: shells, shellsAfter: after.shells)
}

/// A chamfered result can be saved only when it is sound, no worse than the input, has the same shell count, and its
/// volume fell by the chamfer's (an independent check on the assembly).
func bottomChamferResultIsSound(before: MeshHealthReport, after: MeshHealthReport, expectedRemovedMM3: Double) -> Bool {
    guard meshHealthIsSound(after), !meshToolMadeWorse(before: before, after: after), after.signedVolume > 0,
          after.shells == before.shells, expectedRemovedMM3 > 0 else { return false }
    let removed = before.signedVolume - after.signedVolume
    return abs(removed - expectedRemovedMM3) <= max(0.01, expectedRemovedMM3 * 0.002)
}

// MARK: - Outline geometry

/// Twice-halved shoelace area: positive for an anticlockwise loop.
func bottomChamferLoopArea(_ loop: [SIMD2<Double>]) -> Double {
    var sum = 0.0
    for i in loop.indices {
        let p = loop[i], q = loop[(i + 1) % loop.count]
        sum += p.x * q.y - q.x * p.y
    }
    return sum / 2
}

/// Each point of `loop` moved `distance` to the left of the loop's direction (into the material, for an anticlockwise
/// outer outline or a clockwise hole), where the two neighbouring edges' offset lines meet: a mitre at every corner, so
/// each offset edge stays exactly `distance` from its own edge. At a concave corner the mitre takes a little more than a
/// rounded offset would, which only deepens the chamfer there. Nil when a corner is sharper than
/// `bottomChamferMaximumMitre` allows or two neighbouring points coincide.
func bottomChamferMitreInset(_ loop: [SIMD2<Double>], by distance: Double) -> [SIMD2<Double>]? {
    let n = loop.count
    guard n >= 3, distance > 0 else { return nil }
    var result: [SIMD2<Double>] = []
    result.reserveCapacity(n)
    let limit = 2 / (bottomChamferMaximumMitre * bottomChamferMaximumMitre)
    for i in 0..<n {
        let previous = loop[(i + n - 1) % n], point = loop[i], following = loop[(i + 1) % n]
        let incoming = point - previous, outgoing = following - point
        let lengthIn = simd_length(incoming), lengthOut = simd_length(outgoing)
        guard lengthIn > 0, lengthOut > 0 else { return nil }
        let d1 = incoming / lengthIn, d2 = outgoing / lengthOut
        let n1 = SIMD2(-d1.y, d1.x), n2 = SIMD2(-d2.y, d2.x)
        let c = simd_dot(n1, n2)
        // The mitre reaches distance × √(2 / (1 + c)) from the corner.
        guard 1 + c >= limit else { return nil }
        result.append(point + (n1 + n2) * (distance / (1 + c)))
    }
    return result
}

/// A point within this distance (in mm) of the straight line between its neighbouring corners lies on that edge, not at
/// a corner of its own: cut points along a straight wall, or a curve finer than this.
let bottomChamferStraightToleranceMM = 0.0001
/// Bottom points along a moved edge closer than this (in mm) are merged into one.
let bottomChamferMergeMM = 0.001

struct BottomChamferBand: Equatable, Sendable {
    /// The bottom outline: the corners moved in, with the points between them on the moved edges, rounded to Float.
    let bottom: [SIMD2<Double>]
    /// For each top point, the index of its bottom point. Never decreases round the loop, so the band's faces don't cross.
    let bottomOf: [Int]
}

/// The corners of the closed outline `loop`, as positions counted from `start`, its lowest point by (x, y): a corner of
/// the convex hull, so a true corner. Each edge reaches as far as the points along it stay within
/// `bottomChamferStraightToleranceMM` of a straight line (at most 4,096 points, after which a point simply becomes a
/// corner, with an unchanged direction).
func bottomChamferCorners(_ loop: [SIMD2<Double>]) -> (start: Int, corners: [Int]) {
    let n = loop.count
    guard n >= 3 else { return (0, Array(0..<n)) }
    var start = 0
    for i in 1..<n where loop[i].x < loop[start].x || (loop[i].x == loop[start].x && loop[i].y < loop[start].y) { start = i }
    func at(_ k: Int) -> SIMD2<Double> { loop[(start + k) % n] }
    func straight(_ from: Int, _ to: Int) -> Bool {
        let a = at(from), b = at(to)
        let ab = b - a, length = simd_length(ab)
        guard length > 0 else { return false }
        for k in (from + 1)..<to {
            let ap = at(k) - a
            let along = simd_dot(ap, ab) / (length * length)
            guard along > 0, along < 1, abs(ab.x * ap.y - ab.y * ap.x) / length <= bottomChamferStraightToleranceMM else { return false }
        }
        return true
    }
    var corners = [0]
    while corners.last! < n {
        let from = corners.last!
        var to = from + 1
        while to < n, to - from < 4096, straight(from, to + 1) { to += 1 }
        corners.append(to)
    }
    corners.removeLast()
    return (start, corners)
}

/// The bottom of a 45° chamfer band under the closed outline `top`, moved `distance` to the left of its direction.
///
/// Only true corners (`bottomChamferCorners`) are moved, by `bottomChamferMitreInset`; the points between them stay on
/// their edge and are projected onto the moved edge, held between its moved ends. So a cut point less than `distance`
/// from a corner shares the corner's bottom point instead of folding the edge back on itself. Nil when the corners can't
/// be moved cleanly: a corner too sharp, or an edge that would reverse.
func bottomChamferBand(_ top: [SIMD2<Double>], by distance: Double) -> BottomChamferBand? {
    let n = top.count
    guard n >= 3, distance > 0 else { return nil }
    let (start, corners) = bottomChamferCorners(top)
    func at(_ k: Int) -> SIMD2<Double> { top[(start + k) % n] }
    guard corners.count >= 3 else { return nil }
    guard let moved = bottomChamferMitreInset(corners.map { at($0) }, by: distance) else { return nil }
    let m = corners.count
    var bottom: [SIMD2<Double>] = []
    var bottomOf = [Int](repeating: 0, count: n)
    func add(_ point: SIMD2<Double>, for k: Int) {
        let rounded = SIMD2<Double>(Double(Float(point.x)), Double(Float(point.y)))
        if bottom.last != rounded { bottom.append(rounded) }
        bottomOf[(start + k) % n] = bottom.count - 1
    }
    for c in 0..<m {
        let from = corners[c], to = c + 1 < m ? corners[c + 1] : n
        let a = at(from), edge = at(to) - a
        let length2 = simd_length_squared(edge)
        let normal = SIMD2(-edge.y, edge.x) / length2.squareRoot()
        let base = a + normal * distance
        // The moved edge runs from `low` to `high` along `edge`; it must keep its direction.
        let end = moved[(c + 1) % m]
        let low = simd_dot(moved[c] - base, edge) / length2, high = simd_dot(end - base, edge) / length2
        guard high > low else { return nil }
        add(moved[c], for: from)
        var last = low
        var previous = moved[c]
        for k in (from + 1)..<to {
            last = min(max(simd_dot(at(k) - a, edge) / length2, last), high)
            var point = base + edge * last
            // Points closer than the merge distance share one bottom point, so the band and the bed get no slivers.
            if simd_distance(point, end) < bottomChamferMergeMM { point = end }
            else if simd_distance(point, previous) < bottomChamferMergeMM { point = previous }
            previous = point
            add(point, for: k)
        }
    }
    // The last edge ends at the start corner, whose bottom point is the first.
    if bottom.count > 1, bottom.last == bottom[0] {
        bottom.removeLast()
        for i in 0..<n where bottomOf[i] == bottom.count { bottomOf[i] = 0 }
    }
    guard bottom.count >= 3 else { return nil }
    return BottomChamferBand(bottom: bottom, bottomOf: bottomOf)
}

/// Zero-area by the mesh check's rule, with a twofold margin. The bed's points are already the Float coordinates that
/// are written, so only the check's own arithmetic needs the margin.
func bottomChamferIsSliver(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
    let longest = max(simd_distance_squared(a, b), simd_distance_squared(b, c), simd_distance_squared(c, a))
    return abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) <= 2 * meshHealthDegenerateRatio * longest
}

/// Removes slivers an ear-clipped fill can be left with (its last ear has no choice, often three points along a
/// straight edge) by flipping the sliver's longest edge with the one triangle across it, when both new triangles are
/// anticlockwise, not slivers and don't repeat an existing edge. MeshFit's own pass skips edges at a hole's join, where
/// such slivers sit, so this one finds neighbours by undirected edge. Triangles are visited in index order and edges
/// found through lookups only, so the result is deterministic. Slivers it can't flip are left for the mesh check.
func bottomChamferFlipSlivers(_ triangles: inout [SIMD3<Int32>], points: [SIMD2<Double>]) {
    func key(_ p: Int32, _ q: Int32) -> UInt64 { UInt64(UInt32(min(p, q))) << 32 | UInt64(UInt32(max(p, q))) }
    func p(_ i: Int32) -> SIMD2<Double> { points[Int(i)] }
    func area(_ a: Int32, _ b: Int32, _ c: Int32) -> Double {
        let pa = p(a), pb = p(b), pc = p(c)
        return (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
    }
    guard triangles.contains(where: { bottomChamferIsSliver(p($0.x), p($0.y), p($0.z)) }) else { return }
    var users: [UInt64: [Int]] = [:]
    func edges(_ t: SIMD3<Int32>) -> [(Int32, Int32)] { [(t.x, t.y), (t.y, t.z), (t.z, t.x)] }
    for (index, t) in triangles.enumerated() { for (a, b) in edges(t) { users[key(a, b), default: []].append(index) } }
    for _ in 0..<8 {
        var flipped = false
        for t in triangles.indices {
            let v = triangles[t]
            guard bottomChamferIsSliver(p(v.x), p(v.y), p(v.z)) else { continue }
            let corners = [v.x, v.y, v.z]
            var j = 0, longest = -1.0
            for k in 0..<3 {
                let length = simd_distance_squared(p(corners[k]), p(corners[(k + 1) % 3]))
                if length > longest { longest = length; j = k }
            }
            let u = corners[j], w = corners[(j + 1) % 3], m = corners[(j + 2) % 3]
            let across = (users[key(u, w)] ?? []).filter { $0 != t }
            guard across.count == 1 else { continue }
            let n = across[0]
            let other = triangles[n]
            // The neighbour must run the shared edge the other way, w → u.
            guard edges(other).contains(where: { $0 == (w, u) }),
                  let r = [other.x, other.y, other.z].first(where: { $0 != u && $0 != w }), r != m,
                  users[key(r, m)] == nil else { continue }
            let first = SIMD3(u, r, m), second = SIMD3(r, w, m)
            guard area(u, r, m) > 0, area(r, w, m) > 0, !bottomChamferIsSliver(p(u), p(r), p(m)),
                  !bottomChamferIsSliver(p(r), p(w), p(m)) else { continue }
            for old in [t, n] { for (a, b) in edges(triangles[old]) { users[key(a, b)]?.removeAll { $0 == old } } }
            triangles[t] = first
            triangles[n] = second
            for new in [t, n] { for (a, b) in edges(triangles[new]) { users[key(a, b), default: []].append(new) } }
            flipped = true
        }
        if !flipped { break }
    }
}

enum BottomChamferOutlineCheck: Equatable { case clear, tooIntricate, stopped }

/// Checks the moved outlines before anything is built. Each chamfered bottom outline must stay at least `size` (less a
/// rounding margin) from every top outline, its own included, so it never reaches a hole or a narrow part, and never
/// touch any other bottom outline or itself except at neighbouring edges. A sweep over the segments' x-extents keeps this
/// near-linear for ordinary outlines; past `bottomChamferCheckWorkLimit` pair tests the outline counts as too intricate.
func bottomChamferOutlineCheck(top: [[SIMD2<Double>]], bottom: [[SIMD2<Double>]], chamfered: [Bool], size: Double,
                               isCancelled: () -> Bool = { false }) -> BottomChamferOutlineCheck {
    struct Segment {
        let a: SIMD2<Double>, b: SIMD2<Double>
        let loop: Int, index: Int, isBottom: Bool
        var minX: Double { min(a.x, b.x) }
        var maxX: Double { max(a.x, b.x) }
    }
    var segments: [Segment] = []
    for k in top.indices {
        let n = top[k].count
        for i in 0..<n { segments.append(Segment(a: top[k][i], b: top[k][(i + 1) % n], loop: k, index: i, isBottom: false)) }
        guard chamfered[k] else { continue }
        let m = bottom[k].count
        for i in 0..<m { segments.append(Segment(a: bottom[k][i], b: bottom[k][(i + 1) % m], loop: k, index: i, isBottom: true)) }
    }
    let order = segments.indices.sorted { segments[$0].minX != segments[$1].minX ? segments[$0].minX < segments[$1].minX : $0 < $1 }
    let reach = size
    let required = size * (1 - 1e-3)
    var active: [Int] = []
    var work = 0
    for (step, s) in order.enumerated() {
        if step % 4096 == 0, isCancelled() { return .stopped }
        let current = segments[s]
        active.removeAll { segments[$0].maxX + reach < current.minX }
        work += active.count
        guard work <= bottomChamferCheckWorkLimit else { return .tooIntricate }
        let lowY = min(current.a.y, current.b.y) - reach, highY = max(current.a.y, current.b.y) + reach
        for other in active {
            let o = segments[other]
            guard current.isBottom || o.isBottom else { continue }
            guard max(o.a.y, o.b.y) >= lowY, min(o.a.y, o.b.y) <= highY else { continue }
            if current.isBottom && o.isBottom {
                if current.loop == o.loop {
                    let n = bottom[current.loop].count
                    let gap = abs(current.index - o.index)
                    if gap == 1 || gap == n - 1 { continue }
                }
                if bottomChamferSegmentsTouch(current.a, current.b, o.a, o.b) { return .tooIntricate }
            } else if bottomChamferSegmentDistance(current.a, current.b, o.a, o.b) < required {
                return .tooIntricate
            }
        }
        active.append(s)
    }
    return .clear
}

/// Whether two segments meet, ends and collinear overlaps included. The same test as MeshFit's private
/// `segmentsTouch`, copied here so that file stays unchanged.
func bottomChamferSegmentsTouch(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
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

/// The shortest distance between two segments in the plane.
func bottomChamferSegmentDistance(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Double {
    if bottomChamferSegmentsTouch(p1, p2, q1, q2) { return 0 }
    func pointDistance(_ p: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        let ab = b - a
        let length = simd_length_squared(ab)
        let t = length > 0 ? min(max(simd_dot(p - a, ab) / length, 0), 1) : 0
        return simd_distance(p, a + ab * t)
    }
    return min(pointDistance(p1, q1, q2), pointDistance(p2, q1, q2), pointDistance(q1, p1, p2), pointDistance(q2, p1, p2))
}
