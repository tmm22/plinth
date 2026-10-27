import Foundation
import simd

// Fit coupons: a small test piece cut from a model, round one fitting feature (a round hole opening through the bed
// face, a round hole running sideways, or a pin) or as a slice of its whole footprint, so the seller can order it and check how it fits a mating part
// before ordering the full part. The piece is the model's own geometry inside a box that always starts at the model's
// lowest point, so it keeps the bed face, the first layers and the way up (layers run as in the full print), and slots
// that open through the bed face stay open: no closed void can appear. Everything is pure and deterministic, walking
// triangles, loops and features in index order. Studio checks the piece's geometry, never how anything fits.

/// Material kept round a feature on every side.
let fitCouponMarginMM: Float = 3
/// The piece is at least this wide and deep where the model allows: Slant prints nothing smaller than 20 mm cubed.
let fitCouponMinimumWidthMM: Float = 20
/// Kept above the feature's top, so a blind hole keeps its ceiling and a pin its tip.
let fitCouponHeadroomMM: Float = 2
/// A piece narrower than this across (X or Y) is refused.
let fitCouponMinimumSizeMM: Float = 5
/// Features listed, holes first.
let fitCouponMaximumFeatures = 12
/// Bed-face holes from 1.5 mm (as for hole rings) up to 60 mm across, so bearing and magnet seats are listed too.
let fitCouponHoleDiameterRangeMM: ClosedRange<Float> = 1.5...60
/// Pins: flat-topped, 1 to 8.5 mm across (the flat-top search's width), standing at least 2 mm.
let fitCouponPinWidthRangeMM: ClosedRange<Float> = 1...(internalWallsPinWidthRangeMM.upperBound + 0.5)
let fitCouponMinimumPinHeightMM: Float = 2
/// The Bottom slice: the whole footprint up to this height above the lowest point.
let fitCouponBottomSliceDefaultMM: Double = 3
let fitCouponBottomSliceRangeMM: ClosedRange<Double> = 1...20

enum FitCouponFeatureKind: String, Equatable, Sendable {
    case hole, pin
    /// A round hole running sideways (within 5° of horizontal), as Teardrop holes finds them (`teardropCandidates`):
    /// a hinge, axle or pin hole through a wall.
    case sideHole

    /// "hole" or "pin", for sentences.
    var word: String { self == .pin ? "pin" : "hole" }
}

/// A feature a coupon can be cut round, in the mesh's own coordinates.
struct FitCouponFeature: Equatable, Sendable {
    let kind: FitCouponFeatureKind
    let centre: SIMD2<Float>
    /// Across X and Y: a hole's diameter both ways, a pin's section, a side hole's extent seen from above (its length
    /// along its axis, its diameter across).
    let sizeMM: SIMD2<Float>
    /// Where the feature ends: a blind hole's ceiling, the top of the material round a through hole, a pin's top, a side
    /// hole's top.
    let topZ: Float
    /// A hole that runs up through the part, with no ceiling above it.
    let throughHole: Bool
    /// Such as "10.0 mm hole near the left".
    let label: String
}

/// What the coupon is cut round: a listed feature (by index) or the Bottom slice.
enum FitCouponChoice: Hashable, Sendable {
    case feature(Int)
    case bottomSlice
}

/// The box a coupon is cut to. Its bottom is always the model's lowest point; sides may lie outside the model, where
/// nothing is cut.
struct FitCouponRegion: Equatable, Sendable {
    let low: SIMD2<Float>
    let high: SIMD2<Float>
    let topZ: Float
}

// MARK: - Features

/// "near the front left", "near the back", "in the middle": where `point` lies in thirds of the box `low`–`high`, seen
/// from above with Y running from front to back.
func fitCouponPositionWords(_ point: SIMD2<Float>, low: SIMD2<Float>, high: SIMD2<Float>) -> String {
    func third(_ value: Float, _ lo: Float, _ hi: Float) -> Int {
        guard hi - lo > 0 else { return 1 }
        let t = (value - lo) / (hi - lo)
        return t < 1 / 3 ? 0 : (t > 2 / 3 ? 2 : 1)
    }
    let row = ["front", "", "back"][third(point.y, low.y, high.y)]
    let column = ["left", "", "right"][third(point.x, low.x, high.x)]
    let words = [row, column].filter { !$0.isEmpty }
    return words.isEmpty ? "in the middle" : "near the " + words.joined(separator: " ")
}

/// "10.0 mm hole", "4.0 mm pin", "3.0 × 6.0 mm post" for a section that isn't square, or "5.0 mm side hole" (from
/// `diameterMM`).
func fitCouponFeatureName(_ kind: FitCouponFeatureKind, sizeMM: SIMD2<Float>, diameterMM: Float? = nil) -> String {
    switch kind {
    case .hole:
        return String(format: "%.1f mm hole", sizeMM.max())
    case .sideHole:
        return String(format: "%.1f mm side hole", diameterMM ?? sizeMM.min())
    case .pin:
        if abs(sizeMM.x - sizeMM.y) > 0.3 {
            return String(format: "%.1f × %.1f mm post", sizeMM.x, sizeMM.y)
        }
        return String(format: "%.1f mm pin", sizeMM.max())
    }
}

/// Round holes among the bed face's outline loops, by the hole-ring rule (`internalWallsBores`: at least 8 corners,
/// every corner within 90% of the largest radius, at least 85% of that circle's area) over a wider range of sizes.
/// Holes run anticlockwise seen from above, because the bed face faces down. In loop order.
func fitCouponRoundHoles(points: [SIMD3<Float>], loops: [[Int]]) -> [InternalWallsBore] {
    var holes: [InternalWallsBore] = []
    for loop in loops where loop.count >= internalWallsBoreMinimumCorners {
        var twiceArea = 0.0, cx = 0.0, cy = 0.0
        for i in loop.indices {
            let p = points[loop[i]], q = points[loop[(i + 1) % loop.count]]
            let cross = Double(p.x) * Double(q.y) - Double(q.x) * Double(p.y)
            twiceArea += cross
            cx += (Double(p.x) + Double(q.x)) * cross
            cy += (Double(p.y) + Double(q.y)) * cross
        }
        guard twiceArea > 0, twiceArea.isFinite else { continue }
        cx /= 3 * twiceArea; cy /= 3 * twiceArea
        var largest = 0.0, smallest = Double.greatestFiniteMagnitude
        for i in loop {
            let dx = Double(points[i].x) - cx, dy = Double(points[i].y) - cy
            let r = (dx * dx + dy * dy).squareRoot()
            largest = max(largest, r); smallest = min(smallest, r)
        }
        guard fitCouponHoleDiameterRangeMM.contains(Float(2 * largest)), smallest >= 0.9 * largest,
              twiceArea / 2 >= 0.85 * Double.pi * largest * largest else { continue }
        holes.append(InternalWallsBore(centre: SIMD2(Float(cx), Float(cy)), radiusMM: Float(largest)))
    }
    return holes
}

/// Features a fit coupon can be cut round: round holes that open through the bed face (flat, downward faces at the
/// lowest point, the internal walls' rule), round holes running sideways (`fitCouponSideHoles`), then flat-topped pins
/// and posts that rise from the part (not from the bed). Listed nearest the bed first (by the height of the piece each
/// would make), then by kind, X and Y; at most `fitCouponMaximumFeatures`. Labels that would repeat get the position
/// from the model's lowest corner. Nil when cancelled.
func fitCouponFeatures(in mesh: STLMesh, isCancelled: () -> Bool = { false }) -> [FitCouponFeature]? {
    let count = mesh.triangleCount
    guard count > 0, count <= STLMesh.maximumTriangles else { return [] }
    let v = mesh.vertices
    let bounds = meshCoordinateBounds(v)
    let floor = bounds.low.z
    func corner(_ t: Int, _ j: Int) -> SIMD3<Float> { SIMD3(v[t * 9 + j * 3], v[t * 9 + j * 3 + 1], v[t * 9 + j * 3 + 2]) }

    var isBed = [Bool](repeating: false, count: count)
    for t in 0..<count {
        if t % 8192 == 0, isCancelled() { return nil }
        let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
        guard max(a.z, b.z, c.z) <= floor + internalWallsBedToleranceMM else { continue }
        let cross = simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))
        let length = simd_length(cross)
        if length > 0, cross.z / length <= -0.999999 { isBed[t] = true }
    }
    guard let rays = TriangleRayIndex(mesh, isCancelled: isCancelled), !isCancelled() else { return nil }
    let up = SIMD3<Float>(0, 0, 1)

    struct Found {
        let kind: FitCouponFeatureKind; let centre: SIMD2<Float>; let size: SIMD2<Float>; let top: Float; let through: Bool
        var diameter: Float? = nil
    }
    var holes: [Found] = []
    if let outline = internalWallsBedOutline(mesh, isBed: isBed) {
        for hole in fitCouponRoundHoles(points: outline.points, loops: outline.loops) {
            if isCancelled() { return nil }
            let c = hole.centre, r = hole.radiusMM
            // Nothing on the bed inside the loop: a loop round an island of material (such as a hole ring's outer
            // outline, with the ring's wall inside it) isn't a hole.
            var clear = true
            for fraction: Float in [0.5, 0.75, 0.9] where clear {
                for k in 0..<4 {
                    let angle = Float(k) * .pi / 2 + .pi / 4
                    let start = SIMD3<Float>(c.x + cos(angle) * r * fraction, c.y + sin(angle) * r * fraction, floor - 1)
                    if let hit = rays.firstHit(from: start, along: up), hit.distance <= 1.01 { clear = false; break }
                }
            }
            guard clear else { continue }
            var top: Float
            var through = false
            if let hit = rays.firstHit(from: SIMD3(c.x, c.y, floor - 1), along: up) {
                // Material at the bed inside the loop, or a face that isn't a ceiling: not an open hole.
                guard hit.distance > 1.01, hit.normal.z < 0 else { continue }
                top = floor - 1 + hit.distance
            } else {
                // A through hole: the top of the material just round it.
                through = true
                top = floor
                for k in 0..<8 {
                    let angle = Float(k) * .pi / 4
                    let start = SIMD3<Float>(c.x + cos(angle) * (r + 1), c.y + sin(angle) * (r + 1), floor + 0.01)
                    guard let exit = rays.firstHit(from: start, along: up), exit.normal.z > 0 else { continue }
                    top = max(top, start.z + exit.distance)
                }
                if top <= floor + 0.01 { top = bounds.high.z }
            }
            holes.append(Found(kind: .hole, centre: c, size: SIMD2(repeating: 2 * r), top: top, through: through))
        }
    }

    // Pins: flat upward faces no wider than a pin, whose section stays that narrow down to where it widens into the
    // part. The section at a height comes from rays that must leave the material in each direction.
    func section(_ xy: SIMD2<Float>, _ z: Float) -> (low: SIMD2<Float>, high: SIMD2<Float>)? {
        let p = SIMD3<Float>(xy.x, xy.y, z)
        var low = xy, high = xy
        for axis in 0..<2 {
            for sign: Float in [1, -1] {
                var direction = SIMD3<Float>(repeating: 0)
                direction[axis] = sign
                guard let hit = rays.firstHit(from: p, along: direction), simd_dot(hit.normal, direction) > 0 else { return nil }
                if sign > 0 { high[axis] = xy[axis] + hit.distance } else { low[axis] = xy[axis] - hit.distance }
            }
        }
        return (low, high)
    }
    let widest = fitCouponPinWidthRangeMM.upperBound
    var pins: [Found] = []
    let tops = internalWallsFlatTops(mesh, minimumZ: floor + fitCouponMinimumPinHeightMM, isCancelled: isCancelled)
    if isCancelled() { return nil }
    for top in tops {
        if isCancelled() { return nil }
        let probeZ = top.z - min(0.75, (top.z - floor) / 4)
        guard let first = section(top.centre, probeZ) else { continue }
        var centre = (first.low + first.high) / 2
        guard let settled = section(centre, probeZ) else { continue }
        centre = (settled.low + settled.high) / 2
        var size = settled.high - settled.low
        guard size.min() >= fitCouponPinWidthRangeMM.lowerBound, size.max() <= widest else { continue }
        var root = floor
        var z = probeZ - 0.5
        while z >= floor + 0.25 {
            guard let here = section(centre, z) else { root = z + 0.25; break }
            let dims = here.high - here.low
            guard dims.x <= widest, dims.y <= widest else { root = z + 0.25; break }
            size = simd_max(size, dims)
            z -= 0.5
        }
        // A column standing on the bed is the part itself, not a pin on it.
        guard root > floor + 0.3, top.z - root >= fitCouponMinimumPinHeightMM,
              !pins.contains(where: { simd_distance($0.centre, centre) < 1 }) else { continue }
        pins.append(Found(kind: .pin, centre: centre, size: size, top: top.z, through: false))
    }

    // Round holes running sideways, as Teardrop holes finds them.
    guard let side = fitCouponSideHoles(in: mesh, isCancelled: isCancelled) else { return nil }
    let sideHoles = side.map { Found(kind: .sideHole, centre: $0.centre, size: $0.sizeMM, top: $0.topZ, through: $0.through, diameter: $0.diameterMM) }

    // By X, then Y, to the nearest 0.1 mm, so centres a rounding step apart don't decide the order.
    func ordered(_ list: [Found]) -> [Found] {
        func key(_ f: Found) -> SIMD2<Float> { (f.centre * 10).rounded(.toNearestOrAwayFromZero) }
        return list.enumerated().sorted { a, b in
            let p = key(a.element), q = key(b.element)
            if p.x != q.x { return p.x < q.x }
            if p.y != q.y { return p.y < q.y }
            return a.offset < b.offset
        }.map(\.element)
    }
    // Nearest the bed first: by the height of the piece each would make (to 0.1 mm), then X and Y. Bed-face holes,
    // side holes and pins are listed in that order where those are equal.
    let all = ordered(holes) + ordered(sideHoles) + ordered(pins)
    func pieceTop(_ f: Found) -> Int { Int(((min(f.top + fitCouponHeadroomMM, bounds.high.z) - floor) * 10).rounded()) }
    let found = Array(all.enumerated().sorted { a, b in
        let p = pieceTop(a.element), q = pieceTop(b.element)
        return p != q ? p < q : a.offset < b.offset
    }.map(\.element).prefix(fitCouponMaximumFeatures))
    let lowXY = SIMD2(bounds.low.x, bounds.low.y), highXY = SIMD2(bounds.high.x, bounds.high.y)
    let labels = found.map {
        "\(fitCouponFeatureName($0.kind, sizeMM: $0.size, diameterMM: $0.diameter)) \(fitCouponPositionWords($0.centre, low: lowXY, high: highXY))"
    }
    return found.indices.map { i in
        let f = found[i]
        var label = labels[i]
        if labels.filter({ $0 == label }).count > 1 {
            label += String(format: " (X %.0f, Y %.0f)", f.centre.x - lowXY.x, f.centre.y - lowXY.y)
        }
        return FitCouponFeature(kind: f.kind, centre: f.centre, sizeMM: f.size, topZ: f.top, throughHole: f.through, label: label)
    }
}

/// A round hole running sideways, seen from above: its centre, its extent (length along the axis, diameter across),
/// its top and size.
struct FitCouponSideHole: Equatable, Sendable {
    let centre: SIMD2<Float>
    let sizeMM: SIMD2<Float>
    let topZ: Float
    let diameterMM: Float
    let through: Bool
}

/// Teardrop holes' horizontal round holes (`teardropCandidates`) that are round, level and measured end to end, whether
/// or not they could take a teardrop roof: a 2 mm pin hole is as much a fitting feature as a 6 mm one. Tilted or
/// out-of-round holes, and any whose tube and far end weren't measured (`TeardropCandidate.measured`: stepped, tapered
/// or crossing holes), are left out. In the finder's order; nil when cancelled.
func fitCouponSideHoles(in mesh: STLMesh, isCancelled: () -> Bool = { false }) -> [FitCouponSideHole]? {
    let candidates: [TeardropCandidate]
    do { candidates = try teardropCandidates(in: mesh, isCancelled: isCancelled) } catch { return nil }
    return candidates.compactMap { hole in
        // Only holes followed end to end: a size skip is decided before the tube and its far end are measured.
        guard hole.measured, hole.skipped != .notRound, hole.skipped != .tilted else { return nil }
        let axis = SIMD2(abs(hole.axis.x), abs(hole.axis.y))
        let length = hole.lengthMM, diameter = hole.diameterMM
        guard length > 0, diameter > 0, length.isFinite, diameter.isFinite else { return nil }
        let mid = hole.centre
        let size = SIMD2(axis.x * length + axis.y * diameter, axis.y * length + axis.x * diameter)
        return FitCouponSideHole(centre: SIMD2(mid.x, mid.y), sizeMM: size, topZ: mid.z + hole.radiusMM,
                                 diameterMM: diameter, through: hole.through)
    }
}

// MARK: - Regions

/// One axis of a feature's box: at least `fitCouponMinimumWidthMM`, and the feature's size plus the margin each side,
/// moved inward where it would run off the model so the piece keeps that width of material.
private func fitCouponSpan(centre: Float, size: Float, low: Float, high: Float) -> (Float, Float) {
    let width = max(fitCouponMinimumWidthMM, size + 2 * fitCouponMarginMM)
    // The whole model fits: nothing is cut on this axis.
    guard high - low > width else { return (low - 1, high + 1) }
    let start = min(max(centre - width / 2, low), high - width)
    return (start, start + width)
}

/// The box round `feature`: the margin all round, at least 20 mm across where the model allows, and up to the
/// feature's top plus `fitCouponHeadroomMM` (or the model's full height).
func fitCouponRegion(around feature: FitCouponFeature, meshMinimum: SIMD3<Float>, meshMaximum: SIMD3<Float>) -> FitCouponRegion {
    let x = fitCouponSpan(centre: feature.centre.x, size: feature.sizeMM.x, low: meshMinimum.x, high: meshMaximum.x)
    let y = fitCouponSpan(centre: feature.centre.y, size: feature.sizeMM.y, low: meshMinimum.y, high: meshMaximum.y)
    let top = min(feature.topZ + fitCouponHeadroomMM, meshMaximum.z)
    return FitCouponRegion(low: SIMD2(x.0, y.0), high: SIMD2(x.1, y.1), topZ: top)
}

/// The Bottom slice: the whole footprint up to `heightMM` above the lowest point. Nil outside 1–20 mm, or when the
/// slice would be the whole model.
func fitCouponBottomSliceRegion(heightMM: Double, meshMinimum: SIMD3<Float>, meshMaximum: SIMD3<Float>) -> FitCouponRegion? {
    guard heightMM.isFinite, fitCouponBottomSliceRangeMM.contains(heightMM),
          Float(heightMM) < meshMaximum.z - meshMinimum.z - 0.5 else { return nil }
    return FitCouponRegion(low: SIMD2(meshMinimum.x - 1, meshMinimum.y - 1), high: SIMD2(meshMaximum.x + 1, meshMaximum.y + 1),
                           topZ: meshMinimum.z + Float(heightMM))
}

/// The region for a choice, or nil when the choice doesn't name a listed feature or the slice height is out of range.
func fitCouponRegion(for choice: FitCouponChoice, features: [FitCouponFeature], sliceHeightMM: Double?,
                     meshMinimum: SIMD3<Float>, meshMaximum: SIMD3<Float>) -> FitCouponRegion? {
    switch choice {
    case .feature(let index):
        guard features.indices.contains(index) else { return nil }
        return fitCouponRegion(around: features[index], meshMinimum: meshMinimum, meshMaximum: meshMaximum)
    case .bottomSlice:
        guard let sliceHeightMM else { return nil }
        return fitCouponBottomSliceRegion(heightMM: sliceHeightMM, meshMinimum: meshMinimum, meshMaximum: meshMaximum)
    }
}

/// The piece's expected size before it is cut: the box clipped to the model's bounds.
func fitCouponExpectedSize(_ region: FitCouponRegion, meshMinimum: SIMD3<Float>, meshMaximum: SIMD3<Float>) -> SIMD3<Float> {
    let low = simd_max(SIMD3(region.low.x, region.low.y, meshMinimum.z), meshMinimum)
    let high = simd_min(SIMD3(region.high.x, region.high.y, region.topZ), meshMaximum)
    return simd_max(high - low, .zero)
}

/// A cut plane is kept this far from every vertex on its axis (the model's own and those earlier cuts made), so it
/// doesn't pass through or graze an edge (CAD models often have them at round numbers) and leave slivers.
let fitCouponPlaneClearanceMM: Float = 0.05
/// The furthest a side moves outward, growing the piece, to find that clearance.
let fitCouponPlaneMaximumMoveMM: Float = 1

// MARK: - The coupon

enum FitCouponError: LocalizedError, Equatable {
    case notClosedSolid
    case missesModel
    case splits(pieces: Int)
    case noBedFace
    case tooSmall(SIMD3<Float>)
    case exceedsBuildVolume(largestMM: Float)
    case failedChecks
    case cutFailed(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .notClosedSolid:
            return "A fit coupon needs a closed, outward-facing mesh. Use Repair & Save Copy first, then make the coupon from the repaired copy."
        case .missesModel:
            return "The piece wouldn’t include any of the model. Choose another feature or slice height."
        case .splits(let pieces):
            return "The piece would have \(pieces) separate parts or closed pockets, which Slant charges as separate bodies, so it wasn’t made. Choose another feature or slice height."
        case .noBedFace:
            return "The piece wouldn’t include any of the model’s bed face, so it wouldn’t print the way the full part does. Choose a feature nearer the bed, or the Bottom slice."
        case .tooSmall(let size):
            return "The piece would be only \(meshFitSizeLabel(size)), under \(Int(fitCouponMinimumSizeMM)) mm across, so it wasn’t made."
        case .exceedsBuildVolume(let largest):
            return "The piece would be \(String(format: "%.1f", largest)) mm on its longest side, larger than Slant’s 220 mm build volume, so it wasn’t made."
        case .failedChecks:
            return "The piece didn’t come out as one closed solid, so it wasn’t made. Use Repair & Save Copy first, or choose another feature."
        case .cutFailed(let reason): return reason
        case .stopped: return "Stopped. Nothing was saved."
        }
    }
}

struct FitCouponResult: Sendable {
    let mesh: STLMesh
    let data: Data
    let volumeMM3: Double
    /// Flat area on the bed, measured as the flat base tool does.
    let bedContactMM2: Double
    var sizeMM: SIMD3<Float> { mesh.maximum - mesh.minimum }
}

/// The part of `mesh` inside `region`, saved as one closed, outward-facing solid that keeps the model's lowest point and
/// orientation. Refused when the crop would make separate parts (it never drops pieces), would have none of the bed
/// face, is under 5 mm in any direction, has more zero-area triangles than the model, fails a mesh check the model
/// passed, or is larger than Slant's build volume.
func fitCouponCopy(of mesh: STLMesh, region: FitCouponRegion, isCancelled: () -> Bool = { false }) throws -> FitCouponResult {
    guard let input = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw FitCouponError.stopped }
    guard input.isClosed, input.isConsistentlyOriented, input.signedVolume > 0 else { throw FitCouponError.notClosedSolid }
    let bounds = meshCoordinateBounds(mesh.vertices)
    guard region.low.x < bounds.high.x, region.high.x > bounds.low.x, region.low.y < bounds.high.y,
          region.high.y > bounds.low.y, region.topZ > bounds.low.z, region.low.x < region.high.x,
          region.low.y < region.high.y else { throw FitCouponError.missesModel }
    let corners: [SIMD3<Float>]
    do {
        corners = try meshFitBoxCropCorners(mesh, low: region.low, high: region.high, topZ: region.topZ,
                                            planeClearanceMM: fitCouponPlaneClearanceMM,
                                            maximumPlaneMoveMM: fitCouponPlaneMaximumMoveMM, isCancelled: isCancelled)
    } catch MeshFitError.stopped {
        throw FitCouponError.stopped
    } catch MeshFitError.invalidCutHeight {
        throw FitCouponError.missesModel
    } catch let error as MeshFitError {
        throw FitCouponError.cutFailed(error.errorDescription ?? "The cut couldn’t be filled.")
    }
    guard !corners.isEmpty else { throw FitCouponError.missesModel }
    guard corners.count / 3 <= STLMesh.maximumTriangles else { throw FitCouponError.failedChecks }
    var floats: [Float] = []
    floats.reserveCapacity(corners.count * 3)
    for p in corners { floats.append(p.x); floats.append(p.y); floats.append(p.z) }
    let data = try STLMesh.validated(floats).binarySTL()
    let parsed = try STLMesh.parse(data)
    guard parsed.triangleCount == corners.count / 3 else { throw FitCouponError.failedChecks }
    if isCancelled() { throw FitCouponError.stopped }
    guard let report = analyzeMeshHealth(parsed, isCancelled: isCancelled) else { throw FitCouponError.stopped }
    guard report.isClosed, report.isConsistentlyOriented, report.signedVolume > 0,
          report.degenerateTriangles <= input.degenerateTriangles,
          !meshToolMadeWorse(before: input, after: report) else { throw FitCouponError.failedChecks }
    guard report.shells == 1 else { throw FitCouponError.splits(pieces: report.shells) }
    let contact = parsed.bottomContactAreaMM2()
    guard parsed.minimum.z == bounds.low.z, contact > 0 else { throw FitCouponError.noBedFace }
    let size = parsed.maximum - parsed.minimum
    // Across, at least 5 mm; a Bottom slice may be as thin as 1 mm.
    guard size.x >= fitCouponMinimumSizeMM, size.y >= fitCouponMinimumSizeMM,
          size.z >= Float(fitCouponBottomSliceRangeMM.lowerBound) - 0.11 else { throw FitCouponError.tooSmall(size) }
    guard size.max() <= slantBuildVolumeMM else { throw FitCouponError.exceedsBuildVolume(largestMM: size.max()) }
    return FitCouponResult(mesh: parsed, data: data, volumeMM3: report.signedVolume, bedContactMM2: contact)
}

/// Why the typed Bottom slice height can't be used, for a model `modelHeightMM` tall.
func fitCouponSliceHeightProblem(modelHeightMM: Double) -> String {
    let highest = min(fitCouponBottomSliceRangeMM.upperBound, modelHeightMM - 0.5)
    guard highest >= fitCouponBottomSliceRangeMM.lowerBound else {
        return "This model is too thin for a Bottom slice: the slice would be the whole model."
    }
    return "Enter a slice height from 1 to \(meshFitHeightText(Float((highest * 10).rounded(.down) / 10))) mm."
}

/// How the piece round `feature` is cut, for the sheet.
func fitCouponFeatureNote(_ feature: FitCouponFeature) -> String {
    let margin = meshFitHeightText(fitCouponMarginMM)
    let reach = feature.kind == .hole && feature.throughHole
        ? "up to the top of the material round it"
        : "up to \(meshFitHeightText(fitCouponHeadroomMM)) mm above its \(feature.kind == .hole ? "ceiling" : "top")"
    let round = feature.kind == .sideHole ? "the hole and past its ends" : "the \(feature.kind.word)"
    return "Cut from the bed \(reach), with at least \(margin) mm all round \(round) and at least \(Int(fitCouponMinimumWidthMM)) mm across where the model allows."
}

/// "Bracket (fit coupon)".
func fitCouponCopyName(_ name: String) -> String { "\(meshFitCopyBaseName(name)) (fit coupon)" }

/// The sheet's caption. It promises nothing about fit.
let fitCouponCaption = "Saves a small piece cut from this model, with its bed face and the same way up, so you can order it (for example with Order a Sample to Me…) and check how it fits before ordering the full part. Studio checks only that the piece is one closed solid; it checks nothing about fit."
/// Shown when the model isn't a print-ready copy or one of its copies.
let fitCouponPrintReadyHint = "This model has a print-ready copy. If you’ll order that copy, make the coupon from it, so the piece has the same placement and changes: holes print differently standing up and lying down."

/// Fit coupons suit features near the bed: the piece is cut from the bed up, so a high feature makes a tall piece.
let fitCouponTallPieceMM: Float = 20

/// "Coupons suit features near the bed; this piece is 34 mm tall.", for a piece taller than `fitCouponTallPieceMM`.
func fitCouponTallPieceNote(heightMM: Float) -> String? {
    guard heightMM.isFinite, heightMM > fitCouponTallPieceMM else { return nil }
    return "Coupons suit features near the bed; this piece is \(Int(heightMM.rounded())) mm tall."
}

/// Fit coupons keep the bed face and the way up, so they are saved Z-up locked: no later tool places them again.
func meshFitCopyLocksZUp(_ tool: MeshFitTool) -> Bool { tool == .fitCoupon }
