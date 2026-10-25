import Foundation
import simd

// Internal walls: thin vertical slots cut up from the bed face into thick, solid regions. Slant's slicer prints its
// walls (1 mm, about two lines) on both sides of every slot, so each slot turns a band of 25% infill into solid wall.
// Every slot opens through the bed face: Slant bills each closed internal void as an extra body (a live estimate on
// 25 Oct 2026 charged $3.50 for nine closed voids, and nothing for the same slots opened through the bottom).
//
// The slots are proven clear of every surface except the bed face before anything is built, so the cut only ever
// meets the bed face. The result is therefore assembled directly, as the Size and base tools do: the bed face is
// re-triangulated with a rectangular hole per slot and each slot's four walls and ceiling are added. No Boolean
// library is involved, so the result is exact, fast on large meshes and the same bytes on every run.
//
// Pure and deterministic: triangles, lines, columns and slots are walked in index order, and dictionaries are only
// used for lookups, never iterated for output.

// MARK: - Defaults

/// Slot width. Slicers close gaps narrower than about 0.1 mm (a 0.049 mm closing radius is the common default), so
/// slots must be wider than that to force walls; 0.2–0.3 mm is the workable window, and Slant's live estimate of
/// 25 Oct 2026 used 0.25 mm and kept the part one body.
let internalWallsSlotWidthMM: Float = 0.25
/// Centre-to-centre spacing between slot lines. With Slant's 1 mm walls each slot becomes a band of solid wall about
/// 2.25 mm wide (1 mm, the slot, 1 mm); at 4 mm about 1.75 mm of 25% infill is left between bands. At 3 mm the bands
/// almost touch and the region prints nearly solid, costing material without adding separate walls; at 5 mm and more
/// fewer walls are added per millimetre. 4 mm is also the spacing Slant priced in the live test (+27% cost on a
/// 40 × 40 × 20 mm block). When the volume cap below needs it, the spacing is widened in 0.5 mm steps.
let internalWallsSlotSpacingMM: Float = 4
/// Material kept between every slot and every other surface: outer walls, holes, the top and any other face. It is
/// twice Slant's 1 mm wall, so the walls the slicer prints round a slot never merge with the part's own skin.
let internalWallsClearanceMM: Float = 2
/// Regions thinner than this across either horizontal direction get no slots: their walls and infill are already
/// close together. 5 mm is about the narrowest region the clearance allows anyway (2 × (2 mm + the 0.37 mm sampling
/// margin) + the 0.25 mm slot = 4.99 mm), so the clearance proof, not this filter, keeps every slot 2 mm from the skin.
let internalWallsMinimumRegionMM: Float = 5
/// Slots shorter than this from the bed add too few layers of wall to be worth the cut.
let internalWallsMinimumSlotHeightMM: Float = 3
/// Slots shorter than this along their length are left out.
let internalWallsMinimumSlotLengthMM: Float = 3
/// The most of the part's volume the slots may remove; the spacing is widened until the plan fits. 6% keeps the 4 mm
/// spacing Slant priced on 25 Oct 2026 (9 slots in a 40×40×20 mm block removed 4.4%) on most parts.
let internalWallsMaximumRemovedFraction = 0.06
/// Distance between sample columns along a slot line, and between sample heights in a column.
let internalWallsSampleStepMM: Float = 0.5
/// Adjacent slots on one line whose heights differ by more than this become separate slots, 1 mm apart, so a tall
/// region beside a low one gets full-height slots.
let internalWallsHeightSplitMM: Float = 2
/// A bed triangle lies within this distance of the lowest point and faces straight down, the same rule as
/// `bottomContactAreaMM2`.
let internalWallsBedToleranceMM: Float = 0.0001
/// Less flat downward area than this at the lowest point is not a bed face.
let internalWallsMinimumBedAreaMM2 = 1.0
/// Meshes above this many triangles are skipped: the library's own limit. In a release build one run took 0.3 s at
/// 100,000 triangles, 0.5 s at 200,000 and 0.7 s at 400,000 (Euclid needed 83 s for the same slots in an 80,000-triangle
/// disc), so nothing smaller is needed.
let internalWallsMaximumTriangles = 500_000

// MARK: - Types

/// The direction the slots run along. Automatic picks the bed footprint's longer side (X on a tie): fewer, longer
/// slots with fewer ends, and walls along a part's length work like the web of a beam when the part bends lengthways.
enum InternalWallsAxis: String, Codable, Sendable, CaseIterable {
    case automatic, x, y
}

/// A world-coordinate box no slot may enter.
struct InternalWallsKeepClearBox: Equatable, Sendable {
    var low: SIMD3<Float>
    var high: SIMD3<Float>
}

struct InternalWallsOptions: Equatable, Sendable {
    var slotWidthMM: Float = internalWallsSlotWidthMM
    var spacingMM: Float = internalWallsSlotSpacingMM
    var clearanceMM: Float = internalWallsClearanceMM
    var minimumRegionMM: Float = internalWallsMinimumRegionMM
    var maximumRemovedFraction: Double = internalWallsMaximumRemovedFraction
    var axis: InternalWallsAxis = .automatic
    var keepClear: [InternalWallsKeepClearBox] = []
    var maximumTriangles: Int = internalWallsMaximumTriangles
}

/// Why no copy was made. Each is a normal outcome, not an error.
enum InternalWallsSkipReason: String, Equatable, Sendable, CaseIterable {
    case notClosedSolid
    case tooManyTriangles
    case noFlatBedFace
    case noRegionThickEnough
    case wouldRemoveTooMuch
    case wouldChangeShellCount
    case resultFailedChecks

    var message: String {
        switch self {
        case .notClosedSolid:
            return "Internal walls need a closed, outward-facing mesh with no zero-area triangles. Repair a copy first."
        case .tooManyTriangles:
            return "This model has more than \(internalWallsMaximumTriangles.formatted()) triangles, too many for internal walls. Simplify a copy first."
        case .noFlatBedFace:
            return "No internal walls were added: the model has no flat face at its lowest point for the slots to open through. Orient it with a flat face down first."
        case .noRegionThickEnough:
            return "No internal walls were added: no region is thick enough, about \(Int(internalWallsMinimumRegionMM)) mm across with \(Int(internalWallsClearanceMM)) mm of material round each slot."
        case .wouldRemoveTooMuch:
            return "No internal walls were added: the slots would remove too much of the part."
        case .wouldChangeShellCount:
            return "No internal walls were added: the slots would change the number of separate parts."
        case .resultFailedChecks:
            return "No internal walls were added: the result didn’t pass Studio’s mesh checks."
        }
    }
}

/// One slot: an axis-aligned box from the bed face up, in world coordinates.
struct InternalWallsSlot: Equatable, Sendable {
    let low: SIMD3<Float>
    let high: SIMD3<Float>
    /// Along the slot's axis.
    let lengthMM: Float
    let widthMM: Float
    var heightMM: Float { high.z - low.z }
    var volumeMM3: Double { Double(lengthMM) * Double(widthMM) * Double(heightMM) }
}

struct InternalWallsResult: Sendable {
    /// The slotted copy, or nil when skipped.
    let mesh: STLMesh?
    /// The copy as binary STL, the bytes to save.
    let data: Data?
    let skipped: InternalWallsSkipReason?
    let slots: [InternalWallsSlot]
    /// The direction the slots run along: `.x` or `.y`, or `.automatic` when skipped before one was chosen.
    let axis: InternalWallsAxis
    /// The spacing used, which may be wider than asked for to keep within the volume cap.
    let spacingMM: Float
    let removedVolumeMM3: Double
    /// Of the input's volume.
    let removedFraction: Double
    let shellsBefore: Int
    let shellsAfter: Int

    var slotCount: Int { slots.count }
    var totalSlotLengthMM: Double { slots.reduce(0) { $0 + Double($1.lengthMM) } }
    /// The slots' outline length in one layer: about the extra perimeter path the slicer prints per layer, on each side
    /// of every slot. An estimate.
    var slotPerimeterMM: Double { slots.reduce(0) { $0 + 2 * Double($1.lengthMM + $1.widthMM) } }
    var applied: Bool { mesh != nil }
}

enum InternalWallsError: LocalizedError, Equatable {
    case invalidOptions(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .invalidOptions(let problem): return problem
        case .stopped: return "Stopped. Nothing was saved."
        }
    }
}

/// Nil when the options can be used.
func internalWallsOptionsProblem(_ options: InternalWallsOptions) -> String? {
    let values = [options.slotWidthMM, options.spacingMM, options.clearanceMM, options.minimumRegionMM]
    guard values.allSatisfy({ $0.isFinite }), options.maximumRemovedFraction.isFinite else { return "Use finite values for internal walls." }
    if !(0.15...0.5).contains(options.slotWidthMM) { return "Use a slot width from 0.15 to 0.5 mm." }
    if !(2...20).contains(options.spacingMM) || options.spacingMM < options.slotWidthMM * 4 { return "Use a slot spacing from 2 to 20 mm." }
    if !(1...10).contains(options.clearanceMM) { return "Use a clearance from 1 to 10 mm." }
    if !(2...50).contains(options.minimumRegionMM) { return "Use a minimum region from 2 to 50 mm." }
    if !(0.001...0.2).contains(options.maximumRemovedFraction) { return "Use a volume limit from 0.1% to 20%." }
    if options.maximumTriangles < 1 { return "Use a positive triangle limit." }
    for box in options.keepClear {
        guard [box.low.x, box.low.y, box.low.z, box.high.x, box.high.y, box.high.z].allSatisfy({ $0.isFinite }),
              box.high.x > box.low.x, box.high.y > box.low.y, box.high.z > box.low.z else {
            return "Keep-clear regions need finite positions and positive dimensions."
        }
    }
    return nil
}

/// One line for the seller, such as "Adds internal walls: 6 slots, 210 mm in all, 0.25 mm wide, opening through the
/// bed face. About 930 mm³ (2.9%) removed; 1 part before and after." Never a strength claim.
func internalWallsSummary(_ result: InternalWallsResult) -> String {
    if let reason = result.skipped { return reason.message }
    let slots = result.slotCount == 1 ? "1 slot" : "\(result.slotCount.formatted()) slots"
    let parts = result.shellsAfter == 1 ? "1 part" : "\(result.shellsAfter.formatted()) parts"
    let width = String(format: "%.2f", result.slots.first?.widthMM ?? internalWallsSlotWidthMM)
    return "Adds internal walls: \(slots), \(Int(result.totalSlotLengthMM.rounded()).formatted()) mm in all, \(width) mm wide, opening through the bed face. About \(Int(result.removedVolumeMM3.rounded()).formatted()) mm³ (\(String(format: "%.1f", result.removedFraction * 100))%) removed; \(parts) before and after."
}

// MARK: - Engine

/// Cuts internal-wall slots into a copy of `mesh`, which must already sit on its bed face: a flat, downward face at its
/// lowest Z. Returns a skipped result (with the reason) when no copy can be made, and throws only for invalid options
/// or when `isCancelled` reports true. A returned copy is one closed, outward, sound solid with the input's shell
/// count, bounding box and every surface except the bed face unchanged, and its volume is the input's less exactly
/// the slots'.
func internalWallsCopy(of mesh: STLMesh, options: InternalWallsOptions = InternalWallsOptions(),
                       isCancelled: () -> Bool = { false }) throws -> InternalWallsResult {
    if let problem = internalWallsOptionsProblem(options) { throw InternalWallsError.invalidOptions(problem) }
    func skip(_ reason: InternalWallsSkipReason, shells: Int = 0, axis: InternalWallsAxis = .automatic) -> InternalWallsResult {
        InternalWallsResult(mesh: nil, data: nil, skipped: reason, slots: [], axis: axis, spacingMM: options.spacingMM,
                            removedVolumeMM3: 0, removedFraction: 0, shellsBefore: shells, shellsAfter: shells)
    }
    let count = mesh.triangleCount
    guard count <= options.maximumTriangles, count <= STLMesh.maximumTriangles else { return skip(.tooManyTriangles) }
    guard let before = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw InternalWallsError.stopped }
    guard meshHealthIsSound(before), before.signedVolume > 0 else { return skip(.notClosedSolid, shells: before.shells) }
    let shells = before.shells
    let bounds = meshCoordinateBounds(mesh.vertices)
    let floor = bounds.low.z
    let v = mesh.vertices
    func corner(_ t: Int, _ j: Int) -> SIMD3<Float> { SIMD3(v[t * 9 + j * 3], v[t * 9 + j * 3 + 1], v[t * 9 + j * 3 + 2]) }

    // The bed face: flat, downward triangles at the lowest point.
    var isBed = [Bool](repeating: false, count: count)
    var bedArea = 0.0
    var bedLow = SIMD2<Float>(repeating: .greatestFiniteMagnitude), bedHigh = -bedLow
    for t in 0..<count {
        if t % 8192 == 0, isCancelled() { throw InternalWallsError.stopped }
        let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
        guard max(a.z, b.z, c.z) <= floor + internalWallsBedToleranceMM else { continue }
        let cross = simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))
        let length = simd_length(cross)
        guard length > 0, cross.z / length <= -0.999999 else { continue }
        isBed[t] = true
        bedArea += length / 2
        for p in [a, b, c] { bedLow = simd_min(bedLow, SIMD2(p.x, p.y)); bedHigh = simd_max(bedHigh, SIMD2(p.x, p.y)) }
    }
    guard bedArea >= internalWallsMinimumBedAreaMM2 else { return skip(.noFlatBedFace, shells: shells) }
    let extent = bedHigh - bedLow
    let axis: InternalWallsAxis = options.axis != .automatic ? options.axis : (extent.y > extent.x ? .y : .x)
    let along = axis == .y ? 1 : 0, across = 1 - along

    // Indexes: rays over every triangle (bed membership and thickness); nearest distance over all but the bed face.
    guard let rays = TriangleRayIndex(mesh, isCancelled: isCancelled), !isCancelled() else { throw InternalWallsError.stopped }
    var others: [SIMD3<Float>] = []
    others.reserveCapacity((count - isBed.filter { $0 }.count) * 3)
    for t in 0..<count where !isBed[t] { others.append(corner(t, 0)); others.append(corner(t, 1)); others.append(corner(t, 2)) }
    let nearest = InternalWallsDistanceIndex(corners: others)
    others = []
    if isCancelled() { throw InternalWallsError.stopped }

    let w = options.slotWidthMM, step = internalWallsSampleStepMM
    // Every point of a slot lies within half a column, half the width and half a height step of a sample point, so a
    // sample this far from every surface but the bed keeps the whole slot `clearanceMM` away (distance is 1-Lipschitz).
    let reach = options.clearanceMM + (w * w / 4 + step * step / 4 + step * step / 4).squareRoot()
    let jumpLimit: Float = 20
    let ceiling = bounds.high.z
    let up = SIMD3<Float>(0, 0, 1)

    /// The highest clear slot top for a column at (`u` along, `p` across), or nil when the column can't take a slot.
    func columnTop(_ u: Float, _ p: Float) -> Float? {
        var base = SIMD3<Float>(0, 0, floor)
        base[along] = u; base[across] = p
        // It must start on the bed face, with material directly above it.
        guard let hit = rays.firstHit(from: base - up, along: up), isBed[hit.triangle], abs(hit.distance - 1) < 0.001 else { return nil }
        var top: Float?
        var j = 0
        while true {
            let z = floor + Float(j) * step
            guard z + step / 2 <= ceiling else { break }
            let d = nearest.distance(to: SIMD3(base.x, base.y, z), within: reach + jumpLimit)
            guard d >= reach else { break }
            // Clear here and, by the Lipschitz bound, at the next whole steps while d stays above `reach`.
            let skipped = max(0, Int(((d - reach) / step).rounded(.down)))
            let last = min(j + skipped, Int(((ceiling - step / 2 - floor) / step).rounded(.down)))
            top = floor + Float(last) * step + step / 2
            j = last + 1
        }
        guard var clear = top else { return nil }
        for box in options.keepClear {
            let cellLow = SIMD2<Float>(u - step / 2, p - w / 2), cellHigh = SIMD2<Float>(u + step / 2, p + w / 2)
            let boxLow = SIMD2(box.low[along], box.low[across]), boxHigh = SIMD2(box.high[along], box.high[across])
            guard cellLow.x < boxHigh.x, cellHigh.x > boxLow.x, cellLow.y < boxHigh.y, cellHigh.y > boxLow.y,
                  box.high.z > floor, box.low.z < clear else { continue }
            clear = box.low.z
        }
        guard clear - floor >= internalWallsMinimumSlotHeightMM else { return nil }
        // Thick enough both ways, measured part-way up the column.
        var probe = base
        probe.z = floor + min(1, (clear - floor) / 2)
        for axisIndex in [across, along] {
            var direction = SIMD3<Float>(repeating: 0)
            direction[axisIndex] = 1
            guard let ahead = rays.firstHit(from: probe, along: direction), let behind = rays.firstHit(from: probe, along: -direction),
                  ahead.distance + behind.distance >= options.minimumRegionMM else { return nil }
        }
        return clear
    }

    let lowAlong = bedLow[along], spanAlong = extent[along]
    let lowAcross = bedLow[across], spanAcross = extent[across]
    let columnCount = max(0, Int((spanAlong / step).rounded(.down)))
    let columnStart = lowAlong + (spanAlong - Float(columnCount) * step) / 2 + step / 2

    /// Slots for one spacing: lines centred across the bed footprint, columns merged into runs.
    func plan(spacing: Float) throws -> [InternalWallsSlot] {
        let usable = spanAcross - 2 * reach
        guard usable >= 0, columnCount > 0 else { return [] }
        let lineCount = Int((usable / spacing).rounded(.down)) + 1
        let firstLine = lowAcross + reach + (usable - Float(lineCount - 1) * spacing) / 2
        var slots: [InternalWallsSlot] = []
        for line in 0..<lineCount {
            let p = firstLine + Float(line) * spacing
            var tops: [Float?] = []
            tops.reserveCapacity(columnCount)
            for i in 0..<columnCount {
                if i % 64 == 0, isCancelled() { throw InternalWallsError.stopped }
                tops.append(columnTop(columnStart + Float(i) * step, p))
            }
            var first = -1, last = -1, lowest: Float = 0, highest: Float = 0
            // Slots on one line stay at least 1 mm (two columns) apart, so a thin web is never left between them.
            var previousLast = -3
            func close() {
                defer { first = -1 }
                guard first >= 0 else { return }
                previousLast = last
                let start = columnStart + Float(first) * step - step / 2, end = columnStart + Float(last) * step + step / 2
                guard end - start >= internalWallsMinimumSlotLengthMM - 1e-4 else { return }
                var low = SIMD3<Float>(0, 0, floor), high = SIMD3<Float>(0, 0, lowest)
                low[along] = start; high[along] = end
                low[across] = p - w / 2; high[across] = p + w / 2
                slots.append(InternalWallsSlot(low: low, high: high, lengthMM: end - start, widthMM: w))
            }
            for i in 0..<columnCount {
                guard let top = tops[i] else { close(); continue }
                if first >= 0 {
                    if max(highest, top) - min(lowest, top) <= internalWallsHeightSplitMM {
                        last = i; lowest = min(lowest, top); highest = max(highest, top)
                        continue
                    }
                    // A step in height ends this slot; the next starts after the gap.
                    close()
                }
                guard i >= previousLast + 3 else { continue }
                first = i; last = i; lowest = top; highest = top
            }
            close()
        }
        return slots
    }

    var spacing = options.spacingMM
    var slots = try plan(spacing: spacing)
    func removed(_ list: [InternalWallsSlot]) -> Double { list.reduce(0) { $0 + $1.volumeMM3 } }
    var attempts = 0
    while !slots.isEmpty, removed(slots) / before.signedVolume > options.maximumRemovedFraction {
        attempts += 1
        guard attempts <= 40 else { return skip(.wouldRemoveTooMuch, shells: shells, axis: axis) }
        // Removal falls roughly with the spacing; jump close to the cap, then widen in 0.5 mm steps.
        let fraction = removed(slots) / before.signedVolume
        let estimate = spacing * Float(fraction / options.maximumRemovedFraction)
        let widened = attempts == 1 ? max(spacing + 0.5, (estimate / 0.5).rounded(.down) * 0.5) : spacing + 0.5
        guard widened <= 50 else { return skip(.wouldRemoveTooMuch, shells: shells, axis: axis) }
        spacing = widened
        slots = try plan(spacing: spacing)
    }
    guard !slots.isEmpty else { return skip(.noRegionThickEnough, shells: shells, axis: axis) }

    // A slot whose opening can't be joined into the bed face's fill is left out, and the rest assembled again.
    var corners: [SIMD3<Float>] = []
    assembly: while true {
        switch try slottedCorners(mesh, isBed: isBed, slots: slots, isCancelled: isCancelled) {
        case .corners(let list): corners = list; break assembly
        case .unjoinable(let slot):
            slots.remove(at: slot)
            guard !slots.isEmpty else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
        case .failed: return skip(.resultFailedChecks, shells: shells, axis: axis)
        }
    }
    let removedVolume = removed(slots)
    guard corners.count / 3 <= STLMesh.maximumTriangles else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
    var floats: [Float] = []
    floats.reserveCapacity(corners.count * 3)
    for p in corners { floats.append(p.x); floats.append(p.y); floats.append(p.z) }
    guard let assembled = try? STLMesh.validated(floats) else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
    let data = assembled.binarySTL()
    guard let parsed = try? STLMesh.parse(data), parsed.triangleCount == corners.count / 3 else {
        return skip(.resultFailedChecks, shells: shells, axis: axis)
    }
    guard let after = analyzeMeshHealth(parsed, isCancelled: isCancelled) else { throw InternalWallsError.stopped }
    guard parsed.minimum == bounds.low, parsed.maximum == bounds.high else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
    if let problem = internalWallsResultProblem(before: before, after: after, removedVolume: removedVolume) {
        return skip(problem, shells: shells, axis: axis)
    }
    return InternalWallsResult(mesh: parsed, data: data, skipped: nil, slots: slots, axis: axis, spacingMM: spacing,
                               removedVolumeMM3: removedVolume, removedFraction: removedVolume / before.signedVolume,
                               shellsBefore: shells, shellsAfter: after.shells)
}

/// Why a slotted result can't be saved, or nil: it must be sound, no worse than the input, with the same shell count,
/// and its volume must fall by the slots' volume (a check on the assembly, independent of how it was built).
func internalWallsResultProblem(before: MeshHealthReport, after: MeshHealthReport, removedVolume: Double) -> InternalWallsSkipReason? {
    guard meshHealthIsSound(after), !meshToolMadeWorse(before: before, after: after), after.signedVolume > 0 else { return .resultFailedChecks }
    guard after.shells == before.shells else { return .wouldChangeShellCount }
    guard abs((before.signedVolume - after.signedVolume) - removedVolume) <= max(0.05, removedVolume * 0.005) else { return .resultFailedChecks }
    return nil
}

private enum SlottedAssembly {
    case corners([SIMD3<Float>])
    /// This slot's opening couldn't be joined into the bed face's fill.
    case unjoinable(Int)
    case failed
}

/// Every non-bed triangle in input order, then the bed face re-triangulated with a hole per slot, then each slot's
/// walls and ceiling facing into the slot.
private func slottedCorners(_ mesh: STLMesh, isBed: [Bool], slots: [InternalWallsSlot],
                            isCancelled: () -> Bool) throws -> SlottedAssembly {
    let v = mesh.vertices, count = mesh.triangleCount
    func corner(_ t: Int, _ j: Int) -> SIMD3<Float> { SIMD3(v[t * 9 + j * 3] + 0, v[t * 9 + j * 3 + 1] + 0, v[t * 9 + j * 3 + 2] + 0) }
    var corners: [SIMD3<Float>] = []
    corners.reserveCapacity(count * 3 + slots.count * 60)
    for t in 0..<count where !isBed[t] { corners.append(corner(t, 0)); corners.append(corner(t, 1)); corners.append(corner(t, 2)) }

    // Weld the bed corners in first-seen order and collect the bed's directed edges.
    var lookup: [SIMD3<Float>: Int] = [:]
    var points: [SIMD3<Float>] = []
    var edges: [SIMD2<Int>] = []
    for t in 0..<count where isBed[t] {
        let ids = (0..<3).map { j -> Int in
            let p = corner(t, j)
            if let id = lookup[p] { return id }
            lookup[p] = points.count
            points.append(p)
            return points.count - 1
        }
        for j in 0..<3 { edges.append(SIMD2(ids[j], ids[(j + 1) % 3])) }
    }
    if isCancelled() { throw InternalWallsError.stopped }
    let edgeSet = Set(edges)
    // The outline: directed bed edges whose reverse isn't a bed edge. Each outline point must start exactly one.
    var next = [Int](repeating: -1, count: points.count)
    var starts: [Int] = []
    for edge in edges where !edgeSet.contains(SIMD2(edge.y, edge.x)) {
        guard next[edge.x] < 0 else { return .failed }
        next[edge.x] = edge.y
        starts.append(edge.x)
    }
    var visited = [Bool](repeating: false, count: points.count)
    var loops: [[Int]] = []
    for start in starts where !visited[start] {
        var loop: [Int] = []
        var p = start
        while !visited[p] {
            visited[p] = true
            loop.append(p)
            p = next[p]
            guard p >= 0 else { return .failed }
        }
        guard p == start, loop.count >= 3 else { return .failed }
        loops.append(loop)
    }
    // Mirrored in X, so the downward bed reads anticlockwise, as the flat base cap does. Slot holes follow, clockwise
    // once mirrored.
    let bedLoops = loops.count
    var planar = points.map { SIMD2<Double>(-Double($0.x), Double($0.y)) }
    var where3D = points
    for slot in slots {
        let base = planar.count
        let rectangle = [SIMD2(slot.low.x, slot.low.y), SIMD2(slot.high.x, slot.low.y),
                         SIMD2(slot.high.x, slot.high.y), SIMD2(slot.low.x, slot.high.y)]
        for q in rectangle {
            planar.append(SIMD2(-Double(q.x), Double(q.y)))
            where3D.append(SIMD3(q.x, q.y, slot.low.z))
        }
        loops.append([base, base + 1, base + 2, base + 3])
    }
    // Holes are joined to their outlines here, each bridge ending at a point no other bridge uses, so the filled
    // outlines never repeat a point more than twice; the shared filler then sees no holes.
    let bridging = try internalWallsBridgedLoops(points: planar, loops: loops, isCancelled: isCancelled)
    if isCancelled() { throw InternalWallsError.stopped }
    guard let merged = bridging.loops else {
        // An exhausted work budget is a failure for the whole plan, never a reason to drop one slot and try again.
        if bridging.workLimitReached { return .failed }
        if let hole = bridging.unjoinedLoop, hole >= bedLoops { return .unjoinable(hole - bedLoops) }
        return .failed
    }
    guard let triangles = try? triangulatePlanarRegion(points: planar, loops: merged, isCancelled: isCancelled) else {
        if isCancelled() { throw InternalWallsError.stopped }
        return .failed
    }
    for t in triangles { corners.append(where3D[Int(t.x)]); corners.append(where3D[Int(t.y)]); corners.append(where3D[Int(t.z)]) }

    // Walls and ceiling, each facing into the slot.
    func quad(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>, facing n: SIMD3<Float>) {
        if simd_dot(simd_cross(b - a, c - a), n) >= 0 {
            corners.append(contentsOf: [a, b, c, a, c, d])
        } else {
            corners.append(contentsOf: [a, c, b, a, d, c])
        }
    }
    for slot in slots {
        let l = slot.low, h = slot.high
        let p000 = SIMD3(l.x, l.y, l.z), p100 = SIMD3(h.x, l.y, l.z), p110 = SIMD3(h.x, h.y, l.z), p010 = SIMD3(l.x, h.y, l.z)
        let p001 = SIMD3(l.x, l.y, h.z), p101 = SIMD3(h.x, l.y, h.z), p111 = SIMD3(h.x, h.y, h.z), p011 = SIMD3(l.x, h.y, h.z)
        quad(p000, p100, p101, p001, facing: SIMD3(0, 1, 0))
        quad(p010, p011, p111, p110, facing: SIMD3(0, -1, 0))
        quad(p000, p001, p011, p010, facing: SIMD3(1, 0, 0))
        quad(p100, p110, p111, p101, facing: SIMD3(-1, 0, 0))
        quad(p001, p101, p111, p011, facing: SIMD3(0, 0, -1))
    }
    return .corners(corners)
}

/// Joins every clockwise hole loop to the anticlockwise outline that most tightly contains it, in the style of the
/// flat base cap's filler: holes rightmost first, each by a two-way cut to the nearest outline point it can see without
/// touching any edge of the outline, this hole or the holes still to be joined. Unlike that filler, a cut may start at
/// any of the hole's points, and never ends at a point an earlier cut used, so no point appears more than twice in a
/// filled outline. Returns the joined outlines, or the index of the first loop that couldn't be joined, with
/// `workLimitReached` when it stopped because the work budget ran out (a failure, not an unjoinable hole).
///
/// Only the `internalWallsBridgeCandidatesPerPoint` nearest outline points of each hole point are tried, so the
/// candidates sorted per hole stay bounded however large the outline grows; distance computations, the sort and the
/// visibility tests all count against `workLimit`. Throws `InternalWallsError.stopped` when `isCancelled` reports true.
func internalWallsBridgedLoops(points: [SIMD2<Double>], loops: [[Int]], workLimit: Int = 200_000_000,
                               candidatesPerPoint: Int = internalWallsBridgeCandidatesPerPoint,
                               isCancelled: () -> Bool = { false }) throws -> (loops: [[Int]]?, unjoinedLoop: Int?, workLimitReached: Bool) {
    func area(_ loop: [Int]) -> Double {
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
    func orient(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
    func onSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        min(a.x, b.x) <= c.x && c.x <= max(a.x, b.x) && min(a.y, b.y) <= c.y && c.y <= max(a.y, b.y)
    }
    func touch(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2), d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
        if d1 == 0, onSegment(q1, q2, p1) { return true }
        if d2 == 0, onSegment(q1, q2, p2) { return true }
        if d3 == 0, onSegment(p1, p2, q1) { return true }
        if d4 == 0, onSegment(p1, p2, q2) { return true }
        return false
    }
    let areas = loops.map(area)
    if let flat = areas.firstIndex(where: { !($0 != 0 && $0.isFinite) }) { return (nil, flat, false) }
    let outers = loops.indices.filter { areas[$0] > 0 }
    var holesOf = [[Int]](repeating: [], count: loops.count)
    for hole in loops.indices where areas[hole] < 0 {
        let probe = points[loops[hole][0]]
        guard let owner = outers.filter({ contains(loops[$0], probe) }).min(by: { (areas[$0], $0) < (areas[$1], $1) }) else {
            return (nil, hole, false)
        }
        holesOf[owner].append(hole)
    }
    var work = 0
    var result: [[Int]] = []
    for outer in outers {
        var polygon = loops[outer]
        // Lookups only: points already at the end of a cut.
        var used = Set<Int>()
        let holes = holesOf[outer].sorted {
            let a = loops[$0].map { points[$0].x }.max()!, b = loops[$1].map { points[$0].x }.max()!
            return a != b ? a > b : $0 < $1
        }
        for (position, holeIndex) in holes.enumerated() {
            let hole = loops[holeIndex]
            var edges: [(SIMD2<Double>, SIMD2<Double>)] = []
            for loop in [polygon, hole] + holes[(position + 1)...].map({ loops[$0] }) {
                for i in loop.indices { edges.append((points[loop[i]], points[loop[(i + 1) % loop.count]])) }
            }
            if isCancelled() { throw InternalWallsError.stopped }
            // The nearest few outline points of each hole point, kept in order by (distance, from, to).
            typealias Pair = (distance: Double, from: Int, to: Int)
            func before(_ a: Pair, _ b: Pair) -> Bool { (a.distance, a.from, a.to) < (b.distance, b.from, b.to) }
            var pairs: [Pair] = []
            for from in hole.indices {
                work += polygon.count
                guard work <= workLimit else { return (nil, holeIndex, true) }
                var nearest: [Pair] = []
                for to in polygon.indices where !used.contains(polygon[to]) && points[polygon[to]] != points[hole[from]] {
                    let pair: Pair = (simd_distance_squared(points[hole[from]], points[polygon[to]]), from, to)
                    if nearest.count == candidatesPerPoint, let last = nearest.last, !before(pair, last) { continue }
                    let at = nearest.firstIndex { before(pair, $0) } ?? nearest.count
                    nearest.insert(pair, at: at)
                    if nearest.count > candidatesPerPoint { nearest.removeLast() }
                }
                pairs.append(contentsOf: nearest)
            }
            // The sort is counted too (n log n comparisons).
            work += pairs.count * max(1, Int(log2(Double(max(pairs.count, 2)))))
            guard work <= workLimit else { return (nil, holeIndex, true) }
            pairs.sort(by: before)
            var joined: [Int]?
            for pair in pairs {
                if isCancelled() { throw InternalWallsError.stopped }
                let m = points[hole[pair.from]], target = points[polygon[pair.to]]
                work += edges.count
                guard work <= workLimit else { return (nil, holeIndex, true) }
                let blocked = edges.contains { edge in
                    // Edges ending at either end of the cut can only meet it there.
                    if edge.0 == m || edge.1 == m || edge.0 == target || edge.1 == target { return false }
                    return touch(m, target, edge.0, edge.1)
                }
                guard !blocked else { continue }
                var merged = Array(polygon[...pair.to])
                merged.append(contentsOf: hole[pair.from...] + hole[..<pair.from])
                merged.append(hole[pair.from])
                merged.append(polygon[pair.to])
                merged.append(contentsOf: polygon[(pair.to + 1)...])
                used.insert(polygon[pair.to])
                used.insert(hole[pair.from])
                joined = merged
                break
            }
            guard let joined else { return (nil, holeIndex, false) }
            polygon = joined
        }
        result.append(polygon)
    }
    return (result, nil, false)
}

/// Outline points tried per hole point when joining slot openings to the bed outline (`internalWallsBridgedLoops`).
/// A slot opening has four points, so at most 128 candidate cuts are sorted per slot.
let internalWallsBridgeCandidatesPerPoint = 32

// MARK: - Nearest-surface index

/// A bounding-volume hierarchy for the distance from a point to the nearest triangle. Built like `TriangleRayIndex`:
/// triangles ordered by the Morton code of their centroid (ties by index) and split at the middle of each range.
struct InternalWallsDistanceIndex {
    private let a: [SIMD3<Float>], b: [SIMD3<Float>], c: [SIMD3<Float>]
    private let order: [Int32]
    private var low: [SIMD3<Float>] = [], high: [SIMD3<Float>] = []
    private var start: [Int32] = [], extra: [Int32] = []
    static let leafSize = 4

    /// `corners` holds three points per triangle.
    init(corners: [SIMD3<Float>]) {
        let count = corners.count / 3
        var a = [SIMD3<Float>](), b = [SIMD3<Float>](), c = [SIMD3<Float>]()
        a.reserveCapacity(count); b.reserveCapacity(count); c.reserveCapacity(count)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for t in 0..<count {
            a.append(corners[3 * t]); b.append(corners[3 * t + 1]); c.append(corners[3 * t + 2])
            lo = simd_min(lo, simd_min(a[t], simd_min(b[t], c[t]))); hi = simd_max(hi, simd_max(a[t], simd_max(b[t], c[t])))
        }
        let span = simd_max(hi - lo, SIMD3(repeating: 1e-12))
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
            let centroid = ((a[t] + b[t] + c[t]) / 3 - lo) / span
            let q = simd_clamp(centroid, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 1_048_575
            keys[t] = spread(UInt32(q.x)) | spread(UInt32(q.y)) << 1 | spread(UInt32(q.z)) << 2
        }
        self.a = a; self.b = b; self.c = c
        self.order = (0..<Int32(count)).sorted { keys[Int($0)] != keys[Int($1)] ? keys[Int($0)] < keys[Int($1)] : $0 < $1 }
        if count > 0 { build(0, count) }
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

    private func boxDistanceSquared(_ node: Int, _ p: SIMD3<Float>) -> Float {
        let d = simd_max(simd_max(low[node] - p, p - high[node]), SIMD3(repeating: 0))
        return simd_length_squared(d)
    }

    /// The distance from `p` to the nearest triangle, or `limit` when none is nearer.
    func distance(to p: SIMD3<Float>, within limit: Float) -> Float {
        guard !low.isEmpty else { return limit }
        var best = limit * limit
        var stack = [Int](repeating: 0, count: 64)
        var depth = 1
        stack[0] = 0
        while depth > 0 {
            depth -= 1
            let node = stack[depth]
            guard boxDistanceSquared(node, p) < best else { continue }
            if start[node] >= 0 {
                for k in Int(start[node])..<Int(start[node] + extra[node]) {
                    let t = Int(order[k])
                    best = min(best, internalWallsPointTriangleDistanceSquared(p, a[t], b[t], c[t]))
                }
            } else if depth + 2 <= stack.count {
                let left = node + 1, right = Int(extra[node])
                // The nearer child is searched first.
                if boxDistanceSquared(left, p) <= boxDistanceSquared(right, p) {
                    stack[depth] = right; stack[depth + 1] = left
                } else {
                    stack[depth] = left; stack[depth + 1] = right
                }
                depth += 2
            }
        }
        return best.squareRoot()
    }
}

/// Squared distance from `p` to triangle `abc` (Ericson, Real-Time Collision Detection, 5.1.5), in Double.
func internalWallsPointTriangleDistanceSquared(_ point: SIMD3<Float>, _ a32: SIMD3<Float>, _ b32: SIMD3<Float>, _ c32: SIMD3<Float>) -> Float {
    let p = SIMD3<Double>(point), a = SIMD3<Double>(a32), b = SIMD3<Double>(b32), c = SIMD3<Double>(c32)
    let ab = b - a, ac = c - a, ap = p - a
    let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
    if d1 <= 0 && d2 <= 0 { return Float(simd_length_squared(ap)) }
    let bp = p - b
    let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
    if d3 >= 0 && d4 <= d3 { return Float(simd_length_squared(bp)) }
    let vc = d1 * d4 - d3 * d2
    if vc <= 0 && d1 >= 0 && d3 <= 0, d1 - d3 > 0 { return Float(simd_length_squared(p - (a + ab * (d1 / (d1 - d3))))) }
    let cp = p - c
    let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
    if d6 >= 0 && d5 <= d6 { return Float(simd_length_squared(cp)) }
    let vb = d5 * d2 - d1 * d6
    if vb <= 0 && d2 >= 0 && d6 <= 0, d2 - d6 > 0 { return Float(simd_length_squared(p - (a + ac * (d2 / (d2 - d6))))) }
    let va = d3 * d6 - d5 * d4
    if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0, (d4 - d3) + (d5 - d6) > 0 {
        return Float(simd_length_squared(p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))))))
    }
    let sum = va + vb + vc
    // Only a zero-area triangle gets here without a positive sum; sound meshes, the only input, have none.
    guard sum > 0, sum.isFinite else { return Float(min(simd_length_squared(ap), simd_length_squared(bp), simd_length_squared(cp))) }
    let v = vb / sum, w = vc / sum
    return Float(simd_length_squared(p - (a + ab * v + ac * w)))
}
