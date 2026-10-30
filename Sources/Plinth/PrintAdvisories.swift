import Foundation
import simd

// Print advisories: short, advisory-only notes about how a part will print on Slant, measured on this Mac. Pure, in
// memory only, and never a change to the model. Wording stays relative ("likely stronger"), never a promise.

// MARK: - Overhangs past a limit

/// Downward-facing surface steeper than `limitDegrees` from vertical, by `overhangShare`'s rule (faces lying flat on
/// the bed don't count). At 45° this is `overhangShare(mesh)` itself, so that measure never changes.
func overhangShare(_ mesh: STLMesh, limitDegrees: Double) -> OverhangShare {
    if limitDegrees == 45 { return overhangShare(mesh) }
    // A face at angle α from vertical has a normal pointing down by sin α.
    let limit = sin(limitDegrees * .pi / 180)
    let v = mesh.vertices
    let floor = Double(mesh.minimum.z) + 0.0001
    var surface = 0.0, overhang = 0.0
    var i = 0
    while i + 8 < v.count {
        let a = SIMD3<Double>(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))
        let b = SIMD3<Double>(Double(v[i + 3]), Double(v[i + 4]), Double(v[i + 5]))
        let c = SIMD3<Double>(Double(v[i + 6]), Double(v[i + 7]), Double(v[i + 8]))
        i += 9
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        guard length > 0, length.isFinite else { continue }
        let area = length / 2
        surface += area
        let nz = cross.z / length
        let onBed = max(a.z, b.z, c.z) <= floor && nz <= -0.999999
        if !onBed, nz < -limit { overhang += area }
    }
    return OverhangShare(overhangAreaMM2: overhang, surfaceAreaMM2: surface)
}

// MARK: - Advisories

enum PrintAdvisoryKind: String, CaseIterable, Sendable {
    /// In report order.
    case smallBedContact, tipping, steepOverhangs, slenderUpright, thinPin, holeNearEdge, sharpFootprintCorners

    /// Kept in view even when the rest of a list is collapsed: a part that lifts or tips can fail the whole print.
    var alwaysShown: Bool { self == .smallBedContact || self == .tipping }
}

struct PrintAdvisory: Identifiable, Equatable, Sendable {
    let kind: PrintAdvisoryKind
    /// One line for the seller.
    let message: String
    /// Where, measured from the model's lowest corner, when the advisory is about one place.
    var location: SIMD3<Float>? = nil
    /// The main figure: mm² of bed contact, a share (0–1) of the surface for overhangs, otherwise millimetres.
    var figure: Double? = nil
    /// Every figure the line is built from, in `printAdvisoryMessage`'s order, so a saved advisory is rebuilt in the
    /// current wording when it is shown.
    var values: [Double] = []
    var id: String { "\(kind.rawValue)|\(message)" }
}

let printAdvisoryMaximumCount = 8
let printAdvisoryMaximumPerKind = 2
/// Overhangs past Slant's 50° are reported from this share of the surface (the review's "minor" limit).
let printAdvisorySteepOverhangShare = printReviewOverhangLimit
/// Upright features taller than this many times their thickness, and twice their width, are reported.
let slenderFeatureRatio: Float = 3
let slenderFeatureWidthRatio: Float = 2
/// Thicker features stand up well enough on their own; shorter ones are too small to matter here.
let slenderFeatureMaximumThicknessMM: Float = 8
let slenderFeatureMinimumHeightMM: Float = 6
let slenderFeatureSamples = 4_000
/// Centre-to-edge distance, in hole diameters, under which a vertical hole is reported. Pin-bearing studies measure
/// from the centre and cite about 3 diameters (PMC10097255); 1.5 (about 1 diameter of material beside the hole) is
/// half that, so only clearly close holes are reported.
let holeEdgeDistanceRatio: Float = 1.5
/// Fastener-sized holes only: wider round openings aren't pin-loaded.
let holeEdgeMinimumDiameterMM: Float = 1.2
let holeEdgeMaximumDiameterMM: Float = 12
let holeEdgeMaximumHoles = 32
/// A bed contact longer than this, and at least `sharpFootprintMinimumWidthMM` the other way, with corners turning at
/// least `sharpCornerMinimumTurnDegrees` (90° or sharper, with a little slack) is reported.
let sharpFootprintMinimumLengthMM: Float = 100
let sharpFootprintMinimumWidthMM: Float = 60
let sharpCornerMinimumTurnDegrees: Double = 85

/// Upright-feature notes are about loads, so they appear only for a saved bracket, clip or custom purpose: never for a
/// missing purpose or a decorative one.
func slenderUprightAdvisoryApplies(_ intent: PartIntent?) -> Bool {
    guard let purpose = intent?.purpose else { return false }
    return purpose == .bracket || purpose == .clip || purpose == .custom
}

/// The line for an advisory, built from its figures (`PrintAdvisory.values`), or nil when they don't fit the kind.
/// `onCopy`: the line is for a print-ready copy, whose Size and base tools are blocked, so a base is added to the
/// original. Positions are measured from the model's lowest corner.
func printAdvisoryMessage(_ kind: PrintAdvisoryKind, values v: [Double], onCopy: Bool = false) -> String? {
    guard v.allSatisfy(\.isFinite) else { return nil }
    func at(_ i: Int) -> String { String(format: "X %.0f, Y %.0f, Z %.0f", v[i], v[i + 1], v[i + 2]) }
    switch kind {
    case .smallBedContact:
        // [has a flat contact (0 or 1), contact mm², minimum mm²]
        guard v.count == 3 else { return nil }
        return printPlacementSmallContactText(contactMM2: v[0] > 0 ? Float(v[1]) : nil, minimumMM2: Float(v[2]), onCopy: onCopy)
    case .tipping:
        // [kind, height, contact width]
        guard v.count == 3, let tipping = PrintPlacementTipping(rawValue: Int(v[0])) else { return nil }
        return printPlacementTippingText(tipping, heightMM: Float(v[1]), widthMM: Float(v[2]), onCopy: onCopy)
    case .steepOverhangs:
        // [share, mm²]
        guard v.count == 2 else { return nil }
        return "Overhangs: \(percentLabel(v[0])) of the surface (\(Int(v[1].rounded()).formatted()) mm²) faces down more steeply than Slant’s 50° limit, as placed. Those areas may sag or print rough; a different placement, or Reinforce’s overhang chamfer under them, helps."
    case .slenderUpright:
        // [x, y, z, height, thickness]
        guard v.count == 5 else { return nil }
        return String(format: "Slender upright feature near %@: about %.0f mm tall and %.1f mm thick, standing up as placed. ", at(0), v[3], v[4])
            + "Layers run across it, and the bond between layers is the weakest direction in a print, so it is likely weaker standing than lying flat. If it carries load along its length, Lay It Flat Along Its Length… in Optimise for purpose on the original usually does better, then use Make Print-Ready Copy; or add a rib or gusset in Reinforce."
    case .thinPin:
        // [x, y, z, width]
        guard v.count == 4 else { return nil }
        return String(format: "Pin or post about %.1f mm across near %@. Pins and posts under 3 mm across can snap; they print best at 3–5 mm or more.", v[3], at(0))
    case .holeNearEdge:
        // [x, y, z, diameter, centre-to-edge distance]
        guard v.count == 5, v[3] > 0 else { return nil }
        return String(format: "⌀%.1f mm hole near %@: about %.1f mm from its centre to the nearest edge (%.1f diameters). Studies of pin-loaded holes use about 3 diameters; a hole this close is more likely to tear out under load, so moving it inward or adding material around it helps.", v[3], at(0), v[4], v[4] / v[3])
    case .sharpFootprintCorners:
        // [length, corners]
        guard v.count == 2, v[1] >= 1 else { return nil }
        let corners = Int(v[1]) == 1 ? "1 sharp corner" : "\(Int(v[1])) sharp corners"
        return String(format: "Large flat footprint, about %.0f mm long, with %@. Large flat parts can lift at sharp corners (Slant uses no brims); round the corners in your CAD tool.", v[0], corners)
    }
}

/// Advisories for `mesh`, at most `printAdvisoryMaximumCount`, no more than `printAdvisoryMaximumPerKind` of a kind,
/// without repeats, in `PrintAdvisoryKind` order.
/// - `placed`: the mesh is as it will print (Slant keeps the uploaded orientation). Bed contact, tipping, overhangs
///   past 50°, upright features and footprint corners need it; thin pins and holes near an edge don't.
/// - `intent`: the saved purpose. Upright features need a bracket, clip or custom one
///   (`slenderUprightAdvisoryApplies`); a decorative part gets no hole-edge notes either.
/// - `wallThickness`: an existing `analyzeWallThickness` report for this mesh, to avoid measuring twice.
/// - `onCopy`: for a print-ready copy. Its base advice points to the original, and overhangs past 50° are left to
///   the copy's overhang line (`printPreparationOverhangLine`).
/// Empty when cancelled.
func printAdvisories(for mesh: STLMesh, placed: Bool, intent: PartIntent?, wallThickness: WallThicknessReport? = nil,
                     onCopy: Bool = false, isCancelled: () -> Bool = { false }) -> [PrintAdvisory] {
    guard mesh.triangleCount > 0 else { return [] }
    let origin = mesh.minimum
    let functional = intent?.purpose != .decorative
    var found: [PrintAdvisory] = []
    func add(_ kind: PrintAdvisoryKind, _ values: [Double], location: SIMD3<Float>? = nil, figure: Double? = nil) {
        guard let message = printAdvisoryMessage(kind, values: values, onCopy: onCopy) else { return }
        found.append(PrintAdvisory(kind: kind, message: message, location: location, figure: figure, values: values))
    }
    func position(_ p: SIMD3<Float>) -> [Double] {
        let q = p - origin
        return [Double(q.x), Double(q.y), Double(q.z)]
    }

    if placed {
        let assessment = mesh.orientationAssessment(.zUp)
        if !assessment.meetsMinimumContact {
            add(.smallBedContact, [assessment.hasFlatContact ? 1 : 0, Double(assessment.contactArea), Double(assessment.minimumContactMM2)],
                figure: Double(assessment.contactArea))
        }
        if assessment.hasFlatContact, let tipping = printPlacementTipping(assessment) {
            add(.tipping, [Double(tipping.kind.rawValue), Double(tipping.heightMM), Double(tipping.widthMM)],
                figure: assessment.tipMarginMM.map(Double.init))
        }
        if !onCopy {
            let steep = overhangShare(mesh, limitDegrees: Double(slantOverhangLimitDegrees))
            if steep.overhangAreaMM2 > 0, steep.fraction >= printAdvisorySteepOverhangShare {
                add(.steepOverhangs, [steep.fraction, steep.overhangAreaMM2], figure: steep.fraction)
            }
        }
        if let footprint = sharpFootprintCorners(mesh) {
            add(.sharpFootprintCorners, [Double(footprint.lengthMM), Double(footprint.corners)],
                location: footprint.firstCorner - origin, figure: Double(footprint.lengthMM))
        }
    }
    if isCancelled() { return [] }
    guard let index = TriangleRayIndex(mesh, isCancelled: isCancelled), !isCancelled() else { return [] }

    if placed && slenderUprightAdvisoryApplies(intent) {
        guard let features = slenderUprightFeatures(mesh, index: index, isCancelled: isCancelled) else { return [] }
        for feature in features {
            add(.slenderUpright, position(feature.centre) + [Double(feature.heightMM), Double(feature.thicknessMM)],
                location: feature.centre - origin, figure: Double(feature.thicknessMM))
        }
    }

    guard let report = wallThickness ?? analyzeWallThickness(mesh, isCancelled: isCancelled), !isCancelled() else { return [] }
    for feature in report.smallFeatures {
        add(.thinPin, position(feature.centre) + [Double(feature.widthMM)], location: feature.centre - origin, figure: Double(feature.widthMM))
    }

    if functional {
        guard let holes = verticalHolesNearEdges(mesh, index: index, isCancelled: isCancelled) else { return [] }
        for hole in holes {
            add(.holeNearEdge, position(hole.centre) + [Double(hole.diameterMM), Double(hole.edgeDistanceMM)],
                location: hole.centre - origin, figure: Double(hole.edgeDistanceMM))
        }
    }
    return isCancelled() ? [] : printAdvisoriesCapped(found)
}

/// Repeats dropped, at most `printAdvisoryMaximumPerKind` of a kind, in `PrintAdvisoryKind` order, then cut to
/// `printAdvisoryMaximumCount`.
func printAdvisoriesCapped(_ advisories: [PrintAdvisory]) -> [PrintAdvisory] {
    var seen = Set<String>(), result: [PrintAdvisory] = []
    for kind in PrintAdvisoryKind.allCases {
        var count = 0
        for advisory in advisories where advisory.kind == kind && count < printAdvisoryMaximumPerKind {
            guard seen.insert(advisory.id).inserted else { continue }
            result.append(advisory)
            count += 1
        }
    }
    return Array(result.prefix(printAdvisoryMaximumCount))
}

// MARK: - Shared geometry

private func meshCorner(_ mesh: STLMesh, _ triangle: Int, _ j: Int) -> SIMD3<Float> {
    let i = triangle * 9 + j * 3
    return SIMD3(mesh.vertices[i], mesh.vertices[i + 1], mesh.vertices[i + 2])
}

/// Whether `point` is inside the solid: the nearest face along a fixed, slightly oblique ray faces away from it.
/// Reliable on closed, outward-facing meshes.
private func pointIsInside(_ point: SIMD3<Float>, index: TriangleRayIndex) -> Bool {
    let direction = simd_normalize(SIMD3<Float>(0.0123, 0.0217, 1))
    guard let hit = index.firstHit(from: point, along: direction) else { return false }
    return simd_dot(hit.normal, direction) > 0
}

/// The distance to where the ray leaves the solid, when the first face it meets faces along it.
private func exitDistance(from point: SIMD3<Float>, along direction: SIMD3<Float>, index: TriangleRayIndex,
                          skipping: Int = -1, minimumDistance: Float = 0) -> Float? {
    guard let hit = index.firstHit(from: point, along: direction, minimumDistance: minimumDistance, skipping: skipping),
          simd_dot(hit.normal, direction) > 0 else { return nil }
    return hit.distance
}

/// Welded corners: equal positions share an index, numbered in triangle order. Triangles keep the mesh's indices.
private struct WeldedTriangles {
    var points: [SIMD3<Float>] = []
    var triangles: [SIMD3<Int>] = []
    init(_ mesh: STLMesh) {
        var index: [SIMD3<Float>: Int] = [:]
        triangles.reserveCapacity(mesh.triangleCount)
        for t in 0..<mesh.triangleCount {
            let a = meshCorner(mesh, t, 0), b = meshCorner(mesh, t, 1), c = meshCorner(mesh, t, 2)
            var corners = SIMD3<Int>()
            for (j, p) in [a, b, c].enumerated() {
                if let k = index[p] { corners[j] = k } else { index[p] = points.count; corners[j] = points.count; points.append(p) }
            }
            triangles.append(corners)
        }
    }

    /// Boundary loops (edges whose reverse isn't among `members`), following the triangles' winding. Nil when a
    /// boundary branches. Loops start at their lowest point index, in order of it.
    func loops(_ members: [Int], edgeOwner: [SIMD2<Int>: Int], memberOf: (Int) -> Bool) -> [[Int]]? {
        var next: [Int: Int] = [:]
        for t in members {
            let v = triangles[t]
            for j in 0..<3 {
                let a = v[j], b = v[(j + 1) % 3]
                if let other = edgeOwner[SIMD2(b, a)], memberOf(other) { continue }
                guard next[a] == nil else { return nil }
                next[a] = b
            }
        }
        var loops: [[Int]] = []
        for start in next.keys.sorted() where next[start] != nil {
            var loop = [start]
            var v = next.removeValue(forKey: start)!
            while v != start {
                loop.append(v)
                guard let following = next.removeValue(forKey: v), loop.count <= triangles.count * 3 else { return nil }
                v = following
            }
            loops.append(loop)
        }
        return loops
    }

    func edgeOwners() -> [SIMD2<Int>: Int] {
        var owner: [SIMD2<Int>: Int] = [:]
        for (t, v) in triangles.enumerated() { for j in 0..<3 { owner[SIMD2(v[j], v[(j + 1) % 3])] = t } }
        return owner
    }
}

private func signedAreaXY(_ loop: [Int], _ points: [SIMD3<Float>]) -> Double {
    var area = 0.0
    for k in loop.indices {
        let p = points[loop[k]], q = points[loop[(k + 1) % loop.count]]
        area += Double(p.x) * Double(q.y) - Double(q.x) * Double(p.y)
    }
    return area / 2
}

// MARK: - Slender upright features

struct SlenderUprightFeature: Equatable, Sendable {
    /// The middle of the feature, in the mesh's coordinates.
    let centre: SIMD3<Float>
    let heightMM: Float
    /// The smaller horizontal size across the feature (average of its readings).
    let thicknessMM: Float
    let widthMM: Float
    let samples: Int
}

/// Upright features, such as a pin, hook arm or standing tab: sample points on near-vertical faces (by area, in
/// triangle order, a fixed sequence) are measured through the feature horizontally (thickness along the face normal,
/// width across it) and vertically. A reading counts when the material runs at least `slenderFeatureRatio` times its
/// thickness and `slenderFeatureWidthRatio` times its width up through the feature's middle, so wide walls aren't
/// counted. Readings are grouped by position seen from above; the two most slender groups are returned. Nil when
/// cancelled.
func slenderUprightFeatures(_ mesh: STLMesh, index: TriangleRayIndex, maximumSamples: Int = slenderFeatureSamples,
                            isCancelled: () -> Bool = { false }) -> [SlenderUprightFeature]? {
    var candidates: [(triangle: Int, area: Double)] = []
    var total = 0.0
    for t in 0..<mesh.triangleCount {
        let a = meshCorner(mesh, t, 0), b = meshCorner(mesh, t, 1), c = meshCorner(mesh, t, 2)
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        guard length > 0, length.isFinite, abs(cross.z / length) < 0.2 else { continue }
        candidates.append((t, Double(length) / 2))
        total += Double(length) / 2
    }
    guard total > 0, maximumSamples > 0 else { return [] }
    let up = SIMD3<Float>(0, 0, 1)
    let tolerance = max(Float(1e-5), 1e-6 * (mesh.maximum - mesh.minimum).max())
    struct Group { var sumXY: SIMD2<Double>; var count: Int; var low: Float; var high: Float; var thickness: Double; var width: Double; var first: Int }
    var groups: [Group] = []
    var cursor = 0, cumulative = 0.0
    let count = min(maximumSamples, 100_000)
    for k in 0..<count {
        if k % 256 == 0, isCancelled() { return nil }
        let position = (Double(k) + 0.5) * total / Double(count)
        while cursor < candidates.count - 1, cumulative + candidates[cursor].area < position {
            cumulative += candidates[cursor].area
            cursor += 1
        }
        let t = candidates[cursor].triangle
        let a = meshCorner(mesh, t, 0), b = meshCorner(mesh, t, 1), c = meshCorner(mesh, t, 2)
        let cross = simd_cross(b - a, c - a)
        let normal = cross / simd_length(cross)
        var u = Float((0.5 + Double(k) * 0.7548776662466927).truncatingRemainder(dividingBy: 1))
        var v = Float((0.5 + Double(k) * 0.5698402909980532).truncatingRemainder(dividingBy: 1))
        if u + v > 1 { u = 1 - u; v = 1 - v }
        let point = a + (b - a) * u + (c - a) * v
        guard let thickness = exitDistance(from: point, along: -normal, index: index, skipping: t, minimumDistance: tolerance),
              thickness <= slenderFeatureMaximumThicknessMM else { continue }
        let middle = point - normal * (thickness / 2)
        let across = simd_cross(up, normal)
        guard simd_length(across) > 0.5 else { continue }
        let side = simd_normalize(across)
        guard let forward = exitDistance(from: middle, along: side, index: index),
              let backward = exitDistance(from: middle, along: -side, index: index),
              let above = exitDistance(from: middle, along: up, index: index),
              let below = exitDistance(from: middle, along: -up, index: index) else { continue }
        let width = forward + backward, height = above + below
        let thin = min(thickness, width), wide = max(thickness, width)
        guard height >= slenderFeatureMinimumHeightMM, height >= slenderFeatureRatio * thin,
              height >= slenderFeatureWidthRatio * wide else { continue }
        let xy = SIMD2<Double>(Double(middle.x), Double(middle.y))
        let low = middle.z - below, high = middle.z + above
        if let match = groups.indices.first(where: {
            simd_distance(groups[$0].sumXY / Double(groups[$0].count), xy) <= Double(smallFeatureClusterRadiusMM)
        }) {
            groups[match].sumXY += xy
            groups[match].count += 1
            groups[match].low = min(groups[match].low, low)
            groups[match].high = max(groups[match].high, high)
            groups[match].thickness += Double(thin)
            groups[match].width += Double(wide)
        } else if groups.count < smallFeatureMaximumClusters {
            groups.append(Group(sumXY: xy, count: 1, low: low, high: high, thickness: Double(thin), width: Double(wide), first: k))
        }
    }
    let features = groups.filter { $0.count >= 2 }.map { group -> (SlenderUprightFeature, Float, Int) in
        let xy = group.sumXY / Double(group.count)
        let thickness = Float(group.thickness / Double(group.count))
        let height = group.high - group.low
        let feature = SlenderUprightFeature(centre: SIMD3(Float(xy.x), Float(xy.y), (group.low + group.high) / 2),
                                            heightMM: height, thicknessMM: thickness,
                                            widthMM: Float(group.width / Double(group.count)), samples: group.count)
        return (feature, height / max(thickness, 0.001), group.first)
    }
    return features.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }.prefix(printAdvisoryMaximumPerKind).map(\.0)
}

// MARK: - Holes near an edge

struct HoleNearEdge: Equatable, Sendable {
    /// The hole's centre where it opens, in the mesh's coordinates.
    let centre: SIMD3<Float>
    let diameterMM: Float
    /// From the hole's centre to the nearest outside surface or opening, measured across, just inside the opening.
    let edgeDistanceMM: Float
}

/// Round vertical holes (axis along Z) of `holeEdgeMinimumDiameterMM`–`holeEdgeMaximumDiameterMM` whose centre is
/// less than `holeEdgeDistanceRatio` diameters from the nearest edge, measured by 16 horizontal rays from the hole's
/// wall 0.5 mm inside its opening (less for a shallow hole). Holes are round loops of at least 12 points cut into a
/// flat horizontal face, with nothing below (or, on a downward face, above) their centre. Nil when cancelled.
func verticalHolesNearEdges(_ mesh: STLMesh, index: TriangleRayIndex,
                            isCancelled: () -> Bool = { false }) -> [HoleNearEdge]? {
    let welded = WeldedTriangles(mesh)
    if isCancelled() { return nil }
    let owner = welded.edgeOwners()
    let points = welded.points
    // Flat horizontal faces: seeded from the largest flat triangles, then joined by position across shared edges, so
    // needle and zero-area triangles in the same plane belong to the face (their own normals are unreliable).
    var seeds: [(triangle: Int, area: Double, up: Bool)] = []
    for (t, v) in welded.triangles.enumerated() {
        let cross = simd_cross(SIMD3<Double>(points[v.y] - points[v.x]), SIMD3<Double>(points[v.z] - points[v.x]))
        let length = simd_length(cross)
        guard length > 0, length.isFinite, abs(cross.z / length) >= 0.9999 else { continue }
        seeds.append((t, length, cross.z > 0))
    }
    seeds.sort { $0.area != $1.area ? $0.area > $1.area : $0.triangle < $1.triangle }
    var facetOf = [Int](repeating: -1, count: welded.triangles.count)
    var facets: [(members: [Int], up: Bool, z: Float)] = []
    for seed in seeds where facetOf[seed.triangle] < 0 {
        let z = points[welded.triangles[seed.triangle].x].z
        var members: [Int] = [], stack = [seed.triangle]
        facetOf[seed.triangle] = facets.count
        while let t = stack.popLast() {
            members.append(t)
            let v = welded.triangles[t]
            for j in 0..<3 {
                guard let other = owner[SIMD2(v[(j + 1) % 3], v[j])], facetOf[other] < 0 else { continue }
                let w = welded.triangles[other]
                guard abs(points[w.x].z - z) < 0.0001, abs(points[w.y].z - z) < 0.0001, abs(points[w.z].z - z) < 0.0001 else { continue }
                facetOf[other] = facets.count
                stack.append(other)
            }
        }
        facets.append((members, seed.up, z))
    }
    if isCancelled() { return nil }

    var holes: [HoleNearEdge] = []
    var seen = Set<SIMD3<Int32>>()
    var examined = 0
    for (f, facet) in facets.enumerated() {
        if examined >= holeEdgeMaximumHoles || isCancelled() { break }
        guard let loops = welded.loops(facet.members, edgeOwner: owner, memberOf: { facetOf[$0] == f }), loops.count > 1 else { continue }
        let facing: Float = facet.up ? 1 : -1
        let z = facet.z
        for loop in loops where loop.count >= 12 {
            // Inner loops run against the face's own winding.
            guard signedAreaXY(loop, points) * Double(facing) < 0 else { continue }
            let planar = loop.map { SIMD2<Double>(Double(points[$0].x), Double(points[$0].y)) }
            var area = 0.0, centre = SIMD2<Double>.zero
            for k in planar.indices {
                let q = planar[k], r = planar[(k + 1) % planar.count], cross = q.x * r.y - r.x * q.y
                area += cross; centre += (q + r) * cross
            }
            guard abs(area) > 1e-6 else { continue }
            area /= 2; centre /= 6 * area
            let radii = planar.map { simd_distance($0, centre) }
            let radius = radii.reduce(0, +) / Double(radii.count)
            guard radii.allSatisfy({ abs($0 - radius) <= 0.03 * radius + 0.01 }) else { continue }
            let diameter = Float(2 * radius)
            guard diameter >= holeEdgeMinimumDiameterMM, diameter <= holeEdgeMaximumDiameterMM else { continue }
            let key = SIMD3<Int32>(Int32((centre.x * 10).rounded()), Int32((centre.y * 10).rounded()), Int32((Double(diameter) * 10).rounded()))
            guard !seen.contains(key) else { continue }
            let mouth = SIMD3<Float>(Float(centre.x), Float(centre.y), z)
            // A boss standing on the face also leaves a round loop; a hole has no material just inside its opening.
            let into = SIMD3<Float>(0, 0, -facing)
            guard !pointIsInside(mouth + into * 0.05, index: index) else { continue }
            seen.insert(key)
            examined += 1
            let depth = index.firstHit(from: mouth + into * 0.01, along: into)?.distance ?? .infinity
            let probe = mouth + into * min(0.5, depth / 2)
            var nearest = Float.infinity, measured = 0
            for k in 0..<16 {
                let angle = Double(k) * .pi / 8
                let direction = SIMD3<Float>(Float(cos(angle)), Float(sin(angle)), 0)
                let start = probe + direction * (Float(radius) + 0.02)
                guard pointIsInside(start, index: index), let reach = exitDistance(from: start, along: direction, index: index) else { continue }
                measured += 1
                nearest = min(nearest, Float(radius) + 0.02 + reach)
            }
            guard measured >= 8, nearest.isFinite, nearest < holeEdgeDistanceRatio * diameter else { continue }
            holes.append(HoleNearEdge(centre: mouth, diameterMM: diameter, edgeDistanceMM: nearest))
            if examined >= holeEdgeMaximumHoles { break }
        }
    }
    return holes.sorted { ($0.edgeDistanceMM / $0.diameterMM, $0.centre.x, $0.centre.y) < ($1.edgeDistanceMM / $1.diameterMM, $1.centre.x, $1.centre.y) }
}

// MARK: - Sharp-cornered footprints

struct SharpFootprint: Equatable, Sendable {
    /// The bed contact's longest side, seen from above.
    let lengthMM: Float
    let corners: Int
    /// The first sharp corner, in the mesh's coordinates.
    let firstCorner: SIMD3<Float>
}

/// A bed contact (flat, downward faces within 0.0001 mm of the lowest point) whose box is at least
/// `sharpFootprintMinimumLengthMM` long, with outer corners turning by at least `sharpCornerMinimumTurnDegrees`. A
/// rounded corner turns in many small steps, so it doesn't count. Nil when there are none.
func sharpFootprintCorners(_ mesh: STLMesh) -> SharpFootprint? {
    let floor = mesh.minimum.z + 0.0001
    let welded = WeldedTriangles(mesh)
    // Every triangle lying in the bed plane that doesn't face up, zero-area ones included, so the outline closes.
    var member = [Bool](repeating: false, count: welded.triangles.count)
    var members: [Int] = []
    var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude), high = -low
    for (t, v) in welded.triangles.enumerated() {
        let a = welded.points[v.x], b = welded.points[v.y], c = welded.points[v.z]
        guard max(a.z, b.z, c.z) <= floor else { continue }
        let cross = simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))
        let length = simd_length(cross)
        guard length == 0 || cross.z / length <= -0.999999 else { continue }
        member[t] = true
        members.append(t)
        for p in [a, b, c] { low = simd_min(low, SIMD2(p.x, p.y)); high = simd_max(high, SIMD2(p.x, p.y)) }
    }
    guard !members.isEmpty else { return nil }
    let length = (high - low).max()
    guard length >= sharpFootprintMinimumLengthMM, (high - low).min() >= sharpFootprintMinimumWidthMM else { return nil }
    let owner = welded.edgeOwners()
    guard let loops = welded.loops(members, edgeOwner: owner, memberOf: { member[$0] }), !loops.isEmpty else { return nil }
    let areas = loops.map { signedAreaXY($0, welded.points) }
    guard let largest = areas.indices.max(by: { abs(areas[$0]) < abs(areas[$1]) }) else { return nil }
    let outerSign: Double = areas[largest] < 0 ? -1 : 1
    let limit = sharpCornerMinimumTurnDegrees * .pi / 180
    var corners = 0
    var first: SIMD3<Float>?
    for (l, loop) in loops.enumerated() where areas[l] * outerSign > 0 && loop.count >= 3 {
        for k in loop.indices {
            let p = welded.points[loop[(k + loop.count - 1) % loop.count]], q = welded.points[loop[k]]
            let r = welded.points[loop[(k + 1) % loop.count]]
            let e1 = SIMD2<Double>(Double(q.x - p.x), Double(q.y - p.y)), e2 = SIMD2<Double>(Double(r.x - q.x), Double(r.y - q.y))
            guard simd_length(e1) > 0, simd_length(e2) > 0 else { continue }
            let turn = atan2(e1.x * e2.y - e1.y * e2.x, simd_dot(e1, e2))
            // Convex corners turn the same way as the outline runs. A turn of nearly 180° is a sliver doubling back
            // along the outline, not a corner.
            guard turn * outerSign >= limit, abs(turn) < 175 * .pi / 180 else { continue }
            corners += 1
            if first == nil { first = q }
        }
    }
    guard corners > 0, let first else { return nil }
    return SharpFootprint(lengthMM: length, corners: corners, firstCorner: first)
}
