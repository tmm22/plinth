import SwiftUI
import simd

/// Rigid, right-handed rotations: the source axis listed becomes the build Z axis. `turned` follows a placement with a
/// turn about the build Z axis (counter-clockwise seen from above), which lines up faces drawn at an angle with X and Y.
indirect enum PrintOrientation: Hashable, CaseIterable, Identifiable, Codable, Sendable {
    case zUp, zDown, xUp, xDown, yUp, yDown
    case face(SIMD3<Float>)
    case turned(PrintOrientation, degrees: Float)
    static let allCases: [PrintOrientation] = [.zUp, .zDown, .xUp, .xDown, .yUp, .yDown]
    private static let names = ["zUp", "zDown", "xUp", "xDown", "yUp", "yDown"]
    private struct Turn: Codable {
        let base: PrintOrientation
        let zTurnDegrees: Float
    }
    var id: String {
        switch self {
        case .face(let n): return "face-\(n.x)-\(n.y)-\(n.z)"
        case .turned(let base, let degrees): return "\(base.id)-turn-\(degrees)"
        default: return Self.names[Self.allCases.firstIndex(of: self)!]
        }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self), let index = Self.names.firstIndex(of: name) {
            self = Self.allCases[index]
        } else if let n = try? container.decode(SIMD3<Float>.self) {
            guard n.x.isFinite, n.y.isFinite, n.z.isFinite, abs(simd_length(n) - 1) < 0.0001 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid face normal")
            }
            self = .face(n)
        } else {
            let turn = try container.decode(Turn.self)
            guard turn.zTurnDegrees.isFinite, turn.zTurnDegrees != 0, abs(turn.zTurnDegrees) <= 180 else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid turn about Z")
            }
            if case .turned = turn.base {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "Nested turn about Z")
            }
            self = .turned(turn.base, degrees: turn.zTurnDegrees)
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .face(let normal): try container.encode(normal)
        case .turned(let base, let degrees): try container.encode(Turn(base: base, zTurnDegrees: degrees))
        default: try container.encode(id)
        }
    }
    var label: String {
        switch self {
        case .face: return "Flat face on bed"
        case .zUp: return "Original · Z up"
        case .zDown: return "Flip · Z down"
        case .xUp: return "Side · X up"
        case .xDown: return "Side · X down"
        case .yUp: return "Side · Y up"
        case .yDown: return "Side · Y down"
        case .turned(let base, let degrees): return "\(base.label) · turned \(printPlacementTurnDegreesLabel(degrees)) about Z"
        }
    }
    /// The placement without its turn about Z.
    var base: PrintOrientation {
        if case .turned(let base, _) = self { return base }
        return self
    }
    /// The turn about Z after the placement, in degrees counter-clockwise seen from above; 0 when there is none.
    var zTurnDegrees: Float {
        if case .turned(_, let degrees) = self { return degrees }
        return 0
    }
    /// This placement followed by a further turn about Z. Turns combine, so a turn is never nested in another.
    func turned(byDegrees degrees: Float) -> PrintOrientation {
        var total = zTurnDegrees + degrees
        guard total.isFinite else { return self }
        total = total.truncatingRemainder(dividingBy: 360)
        if total > 180 { total -= 360 } else if total <= -180 { total += 360 }
        return total == 0 ? base : .turned(base, degrees: total)
    }
    func rotate(_ p: SIMD3<Float>) -> SIMD3<Float> {
        switch self {
        case .face(let normal): return simd_quatf(from: normal, to: SIMD3<Float>(0, 0, -1)).act(p)
        case .zUp: return p
        case .zDown: return SIMD3(p.x, -p.y, -p.z)
        case .xUp: return SIMD3(-p.z, p.y, p.x)
        case .xDown: return SIMD3(p.z, p.y, -p.x)
        case .yUp: return SIMD3(p.x, -p.z, p.y)
        case .yDown: return SIMD3(p.x, p.z, -p.y)
        case .turned(let base, let degrees):
            let q = base.rotate(p)
            // In Double, so the same angle always gives the same rotation.
            let radians = Double(degrees) * .pi / 180
            let c = Float(cos(radians)), s = Float(sin(radians))
            return SIMD3(q.x * c - q.y * s, q.x * s + q.y * c, q.z)
        }
    }
}

enum PrintPriority: String, CaseIterable, Identifiable {
    case balanced = "Balanced", economy = "Lower support / cost", strength = "Strength"
    var id: String { rawValue }
}

enum PrintLoadAxis: String, CaseIterable, Identifiable, Codable, Sendable {
    case unknown = "Not specified", x = "Original X", y = "Original Y", z = "Original Z"
    var id: String { rawValue }
    var vector: SIMD3<Float>? {
        switch self {
        case .unknown: return nil
        case .x: return SIMD3(1, 0, 0)
        case .y: return SIMD3(0, 1, 0)
        case .z: return SIMD3(0, 0, 1)
        }
    }
}

/// Bed contact Studio looks for: the flat-base tool's target, the smaller of 100 mm² and 15% of the footprint.
func placementMinimumContactMM2(footprintMM2: Float) -> Float {
    max(min(Float(flatBaseDefaultMinimumContactMM2), footprintMM2 * Float(flatBaseDefaultContactFraction)), 0.000001)
}
/// The centre of mass must sit at least this far inside the outline of what touches the bed.
let placementTipMarginMM: Float = 1
/// Taller than this many times the contact's smallest width counts as slender on the bed.
let placementSlenderRatio: Float = 3
/// Slant prints overhangs to 50° from vertical; Studio's own overhang measure and chamfers use 45°, a margin.
let slantOverhangLimitDegrees: Float = 50

struct OrientationAssessment: Identifiable, Equatable, Sendable {
    let orientation: PrintOrientation
    let size: SIMD3<Float>
    let contactArea: Float
    let overhangArea: Float
    let surfaceArea: Float
    var contactWidth: Float? = nil
    /// How far inside the convex outline of the bed contact the centre of mass sits, seen from above (negative:
    /// outside it). Nil when not measured.
    var tipMarginMM: Float? = nil
    /// The smallest width of the bed contact's convex outline. Nil when not measured.
    var contactHullWidth: Float? = nil
    /// Downward area steeper than Slant's 50° (`slantOverhangLimitDegrees`), beside `overhangArea`'s 45°.
    var steepOverhangArea: Float = 0
    var id: String { orientation.id }
    var fits: Bool { size.max() <= slantBuildVolumeMM }
    var contactRatio: Float { contactArea / max(size.x * size.y, 0.000001) }
    var hasFlatContact: Bool { contactArea.isFinite && contactArea > 0.000001 }
    var minimumContactMM2: Float { placementMinimumContactMM2(footprintMM2: size.x * size.y) }
    /// At least the flat-base tool's target touches the bed.
    var meetsMinimumContact: Bool { hasFlatContact && contactArea >= minimumContactMM2 }
    /// The centre of mass sits outside, or within `placementTipMarginMM` of the edge of, what touches the bed.
    var centreOfMassNearEdge: Bool { tipMarginMM.map { $0 < placementTipMarginMM } ?? false }
    /// Taller than `placementSlenderRatio` times the contact's smallest width.
    var slenderOnBed: Bool { contactHullWidth.map { size.z > placementSlenderRatio * $0 } ?? false }
    var tippingProne: Bool { centreOfMassNearEdge || slenderOnBed }
    /// Added to the score: tipping-prone placements score worse, and one whose centre of mass is outside its contact
    /// worse still. Unmeasured figures add nothing.
    var tippingPenalty: Float {
        var penalty: Float = tippingProne ? 1.5 : 0
        if let margin = tipMarginMM, margin < 0 { penalty += 3 }
        return penalty
    }
    var slendernessPenalty: Float {
        let width = min(contactWidth ?? sqrt(max(contactArea, 0)), sqrt(max(contactArea, 0)))
        let ratio = size.z / max(width, 0.000001)
        return ratio / (1 + ratio)
    }
    func score(priority: PrintPriority, load: PrintLoadAxis) -> Float {
        // Relative heuristics only: neither a slicer estimate nor a mechanical simulation.
        let support = overhangArea / max(surfaceArea, 0.000001)
        let height = size.z / max(size.max(), 0.000001)
        let contactPenalty = 1 - min(contactRatio, 1)
        let crossLayer = load.vector.map { abs(orientation.rotate($0).z) } ?? 0
        let strengthWeight: Float = priority == .strength ? 4 : (priority == .balanced ? 1 : 0.25)
        return support * (priority == .economy ? 5 : 3) + height * 0.25 + contactPenalty * 0.5
            + slendernessPenalty * 0.75 + crossLayer * strengthWeight + (fits ? 0 : 100) + (contactArea > 0 ? 0 : 10)
            + tippingPenalty
    }
}

/// The convex hull of `points`, counter-clockwise without repeated or collinear points (monotone chain).
func placementConvexHull(_ points: [SIMD2<Double>]) -> [SIMD2<Double>] {
    let sorted = points.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    var unique: [SIMD2<Double>] = []
    unique.reserveCapacity(sorted.count)
    for p in sorted where unique.last != p { unique.append(p) }
    guard unique.count >= 3 else { return unique }
    func cross(_ o: SIMD2<Double>, _ a: SIMD2<Double>, _ b: SIMD2<Double>) -> Double {
        (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
    }
    var lower: [SIMD2<Double>] = [], upper: [SIMD2<Double>] = []
    for p in unique {
        while lower.count >= 2, cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
        lower.append(p)
    }
    for p in unique.reversed() {
        while upper.count >= 2, cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
        upper.append(p)
    }
    return Array(lower.dropLast() + upper.dropLast())
}

/// How far `point` is inside a counter-clockwise convex `hull`; negative outside it, by its distance to the outline.
/// Nil when the hull has no area.
func placementHullMargin(_ point: SIMD2<Double>, hull: [SIMD2<Double>]) -> Double? {
    guard hull.count >= 3 else { return nil }
    var inside = true
    var nearest = Double.infinity
    for i in hull.indices {
        let a = hull[i], b = hull[(i + 1) % hull.count], ab = b - a
        let length = simd_length(ab)
        guard length > 0 else { continue }
        if ab.x * (point.y - a.y) - ab.y * (point.x - a.x) < 0 { inside = false }
        let t = simd_clamp(simd_dot(point - a, ab) / (length * length), 0, 1)
        nearest = min(nearest, simd_distance(point, a + ab * t))
    }
    guard nearest.isFinite else { return nil }
    return inside ? nearest : -nearest
}

/// The smallest width of a counter-clockwise convex `hull` (rotating calipers); 0 for fewer than 3 points.
func placementHullWidth(_ hull: [SIMD2<Double>]) -> Double {
    let n = hull.count
    guard n >= 3 else { return 0 }
    func distance(_ i: Int, _ j: Int) -> Double {
        let a = hull[i], ab = hull[(i + 1) % n] - a, p = hull[j % n]
        let length = simd_length(ab)
        return length > 0 ? abs(ab.x * (p.y - a.y) - ab.y * (p.x - a.x)) / length : 0
    }
    var best = Double.infinity
    var j = 1
    for i in 0..<n {
        if j <= i { j = i + 1 }
        var steps = 0
        while steps < n, distance(i, j + 1) >= distance(i, j) { j += 1; steps += 1 }
        best = min(best, distance(i, j))
    }
    return best.isFinite ? best : 0
}

extension STLMesh {
    func oriented(_ orientation: PrintOrientation) -> STLMesh {
        let rotation = simd_float3x3(columns: (orientation.rotate(SIMD3(1, 0, 0)),
                                                orientation.rotate(SIMD3(0, 1, 0)),
                                                orientation.rotate(SIMD3(0, 0, 1))))
        var points: [Float] = []
        points.reserveCapacity(vertices.count)
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for i in stride(from: 0, to: vertices.count, by: 3) {
            let p = rotation * SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
            low = simd_min(low, p); high = simd_max(high, p)
            points.append(contentsOf: [p.x, p.y, p.z])
        }
        for i in stride(from: 0, to: points.count, by: 3) {
            points[i] -= low.x; points[i + 1] -= low.y; points[i + 2] -= low.z
        }
        return STLMesh(vertices: points, minimum: .zero, maximum: high - low)
    }

    /// Group triangle normals, then evaluate a bounded set of the largest surface directions.
    /// Full-mesh contact checks below reject internal faces and edge-only placements.
    func placementCandidates() -> [PrintOrientation] {
        var groups: [SIMD3<Int32>: (normal: SIMD3<Float>, area: Float)] = [:]
        for i in stride(from: 0, to: vertices.count, by: 9) {
            let a = SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
            let b = SIMD3(vertices[i + 3], vertices[i + 4], vertices[i + 5])
            let c = SIMD3(vertices[i + 6], vertices[i + 7], vertices[i + 8])
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length.isFinite, length > 0 else { continue }
            let normal = cross / length
            let key = SIMD3<Int32>(Int32((normal.x * 10000).rounded()), Int32((normal.y * 10000).rounded()), Int32((normal.z * 10000).rounded()))
            if var group = groups[key] { group.area += length / 2; groups[key] = group }
            else { groups[key] = (normal, length / 2) }
        }
        let sorted = groups.values.sorted {
            if $0.area != $1.area { return $0.area > $1.area }
            if $0.normal.x != $1.normal.x { return $0.normal.x < $1.normal.x }
            if $0.normal.y != $1.normal.y { return $0.normal.y < $1.normal.y }
            return $0.normal.z < $1.normal.z
        }
        var candidates = PrintOrientation.allCases
        for group in sorted {
            // Keep distinct directions; axis-aligned faces are already covered.
            if candidates.contains(where: { simd_distance($0.rotate(group.normal), SIMD3<Float>(0, 0, -1)) < 0.000001 }) { continue }
            candidates.append(.face(group.normal))
            if candidates.count == 30 { break }
        }
        return candidates
    }

    func orientationAssessments() -> [OrientationAssessment] {
        placementCandidates().map { orientationAssessment($0) }
    }

    /// Bed contact, overhangs, centre of mass and contact outline for one placement.
    func orientationAssessment(_ orientation: PrintOrientation) -> OrientationAssessment {
        let mesh = oriented(orientation)
        var surface: Float = 0, contact: Float = 0, overhang: Float = 0, steep: Float = 0
        // Numerical coplanarity tolerance, not an adhesion or manufacturing tolerance.
        let tolerance: Float = 0.0001
        // A face at angle α from vertical has a normal pointing down by sin α.
        let steepLimit = Float(sin(Double(slantOverhangLimitDegrees) * .pi / 180))
        var contactLow = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var contactHigh = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
        var contactPoints: [SIMD2<Double>] = []
        // Volume-weighted centre of mass from signed tetrahedra; the surface centroid stands in for an open mesh.
        var volume = 0.0, moment = SIMD3<Double>.zero, areaMoment = SIMD3<Double>.zero, areaSum = 0.0
        for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
            func point(_ j: Int) -> SIMD3<Float> {
                SIMD3(mesh.vertices[i + j], mesh.vertices[i + j + 1], mesh.vertices[i + j + 2])
            }
            let a = point(0), b = point(3), c = point(6)
            let da = SIMD3<Double>(a), db = SIMD3<Double>(b), dc = SIMD3<Double>(c)
            let tetrahedron = simd_dot(da, simd_cross(db, dc)) / 6
            if tetrahedron.isFinite { volume += tetrahedron; moment += (da + db + dc) * (tetrahedron / 4) }
            let cross = simd_cross(b - a, c - a)
            let length = simd_length(cross)
            guard length > 0 else { continue }
            let area = length / 2
            surface += area
            if area.isFinite { areaSum += Double(area); areaMoment += (da + db + dc) * (Double(area) / 3) }
            if max(a.z, max(b.z, c.z)) <= tolerance && abs(cross.z / length) >= 0.999999 {
                contact += abs(cross.z) / 2
                for p in [a, b, c] {
                    contactLow = simd_min(contactLow, SIMD2(p.x, p.y))
                    contactHigh = simd_max(contactHigh, SIMD2(p.x, p.y))
                    contactPoints.append(SIMD2(Double(p.x), Double(p.y)))
                }
            } else if cross.z / length < -0.7071068 {
                overhang += area
                if cross.z / length < -steepLimit { steep += area }
            }
        }
        var tipMargin: Float?, hullWidth: Float?
        if contact > 0 {
            let hull = placementConvexHull(contactPoints)
            hullWidth = Float(placementHullWidth(hull))
            let span = Double(max(mesh.maximum.max(), 0.001))
            let centre: SIMD3<Double>? = abs(volume) > 1e-9 * span * span * span ? moment / volume
                : (areaSum > 0 ? areaMoment / areaSum : nil)
            if let centre, centre.x.isFinite, centre.y.isFinite {
                // A contact without area (points on a line) leaves the part balanced on an edge.
                tipMargin = placementHullMargin(SIMD2(centre.x, centre.y), hull: hull).map { Float($0) } ?? -0.000001
            }
        }
        return OrientationAssessment(orientation: orientation, size: mesh.maximum, contactArea: contact,
                                     overhangArea: overhang, surfaceArea: surface,
                                     contactWidth: contact > 0 ? (contactHigh - contactLow).min() : 0,
                                     tipMarginMM: tipMargin, contactHullWidth: hullWidth, steepOverhangArea: steep)
    }

    /// The turn about Z, in degrees counter-clockwise from above, that lines up this (placed) mesh's largest
    /// vertical faces with X and Y: the area-weighted dominant horizontal normal direction, folded to a quarter turn,
    /// then refined to the exact direction of the largest group of faces near it. Nil when no direction dominates or
    /// the faces already line up. The smaller turn is returned (−45° to 45°); equal groups go to the smaller angle.
    func zAlignmentTurnDegrees() -> Float? {
        var c = 0.0, s = 0.0, vertical = 0.0, total = 0.0
        var faces: [(angle: Double, area: Double)] = []
        for i in stride(from: 0, to: vertices.count, by: 9) {
            let a = SIMD3<Double>(Double(vertices[i]), Double(vertices[i + 1]), Double(vertices[i + 2]))
            let b = SIMD3<Double>(Double(vertices[i + 3]), Double(vertices[i + 4]), Double(vertices[i + 5]))
            let d = SIMD3<Double>(Double(vertices[i + 6]), Double(vertices[i + 7]), Double(vertices[i + 8]))
            let cross = simd_cross(b - a, d - a)
            let length = simd_length(cross)
            guard length > 0, length.isFinite else { continue }
            let area = length / 2, n = cross / length
            total += area
            let horizontal = (n.x * n.x + n.y * n.y).squareRoot()
            // Within about 3° of vertical.
            guard horizontal > 0.9986 else { continue }
            let angle = atan2(n.y, n.x)
            vertical += area
            c += area * cos(4 * angle); s += area * sin(4 * angle)
            if abs(n.z) < 0.0001 { faces.append((zAlignmentFold(angle), area)) }
        }
        guard total > 0, vertical >= 0.05 * total, (c * c + s * s).squareRoot() >= 0.3 * vertical else { return nil }
        let estimate = atan2(s, c) / 4
        // Groups of faces within 0.0006° of each other, within 1° of the estimate (wrapping at ±45°).
        let window = Double.pi / 180, bin = 0.00001
        var groups: [Int64: (area: Double, best: Double, bestArea: Double)] = [:]
        for face in faces {
            var gap = face.angle - estimate
            if gap > .pi / 4 { gap -= .pi / 2 } else if gap < -.pi / 4 { gap += .pi / 2 }
            guard abs(gap) <= window else { continue }
            let key = Int64((face.angle / bin).rounded())
            var group = groups[key] ?? (0, face.angle, 0)
            group.area += face.area
            if face.area > group.bestArea { group.best = face.angle; group.bestArea = face.area }
            groups[key] = group
        }
        guard let chosen = groups.keys.sorted().max(by: { groups[$0]!.area < groups[$1]!.area }) .map({ groups[$0]! }),
              chosen.area >= 0.25 * vertical else { return nil }
        let turn = -chosen.best * 180 / .pi
        guard abs(turn) >= Double(placementTurnMinimumDegrees) else { return nil }
        return Float(turn)
    }

    func binarySTL() -> Data {
        var data = Data(repeating: 0, count: 80)
        func word(_ value: UInt32) {
            var little = value.littleEndian
            withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
        }
        word(UInt32(triangleCount))
        for i in stride(from: 0, to: vertices.count, by: 9) {
            let a = SIMD3(vertices[i], vertices[i + 1], vertices[i + 2])
            let b = SIMD3(vertices[i + 3], vertices[i + 4], vertices[i + 5])
            let c = SIMD3(vertices[i + 6], vertices[i + 7], vertices[i + 8])
            let cross = simd_cross(b - a, c - a)
            let normal = simd_length_squared(cross) > 0 ? simd_normalize(cross) : .zero
            for v in [normal.x, normal.y, normal.z] { word(v.bitPattern) }
            for j in 0..<9 { word(vertices[i + j].bitPattern) }
            data.append(contentsOf: [0, 0])
        }
        return data
    }
}

enum PartPurpose: String, CaseIterable, Identifiable, Codable, Sendable {
    case bracket = "Bracket", enclosure = "Enclosure", clip = "Clip", decorative = "Decorative", custom = "Custom"
    var id: String { rawValue }
    var priority: PrintPriority {
        switch self {
        case .bracket, .clip, .custom: return .strength
        case .enclosure: return .balanced
        case .decorative: return .economy
        }
    }
    var needsDirection: Bool { self == .bracket || self == .clip || self == .custom }
}

struct PartIntent: Codable, Equatable, Sendable {
    var purpose: PartPurpose = .enclosure
    var details = ""
    var load: PrintLoadAxis = .unknown
    var materialGoal: MaterialGoal? = nil
    var effectiveLoad: PrintLoadAxis { purpose == .decorative ? .unknown : load }
    var isReady: Bool {
        (!purpose.needsDirection || load != .unknown) &&
        (purpose != .custom || !details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    var explanation: String {
        if effectiveLoad != .unknown {
            return "Balances layer alignment with your stress direction, bed contact, support needs and print height."
        }
        return purpose == .decorative
            ? "Favours reduced support needs, stable bed contact and a lower print height."
            : "Balances stable bed contact, support needs and print height for your enclosure."
    }
}

struct PreparedPrintRecipe: Codable, Equatable, Sendable {
    let sourceID: UUID
    let sourceName: String
    let intent: PartIntent
    let orientation: PrintOrientation
    let materialID: String?
    let created: Date
}

/// The best placement for `intent`. Placements that don't fit or have no flat face on the bed are never chosen; among
/// the rest, those with the minimum bed contact (`meetsMinimumContact`) are preferred, and only when none has it is
/// the best of all chosen (`PrintPlacementChoice.smallBedContact` flags it).
func preferredOrientation(_ assessments: [OrientationAssessment], intent: PartIntent) -> OrientationAssessment? {
    guard intent.isReady else { return nil }
    // Reject unusable placements rather than allowing a penalty to be outweighed.
    let usable = assessments.filter { $0.fits && $0.hasFlatContact && $0.surfaceArea.isFinite && $0.surfaceArea > 0 }
    let pool = usable.contains(where: \.meetsMinimumContact) ? usable.filter(\.meetsMinimumContact) : usable
    return pool.min {
        let lhs = $0.score(priority: intent.purpose.priority, load: intent.effectiveLoad)
        let rhs = $1.score(priority: intent.purpose.priority, load: intent.effectiveLoad)
        if lhs == rhs {
            return (PrintOrientation.allCases.firstIndex(of: $0.orientation) ?? 6) < (PrintOrientation.allCases.firstIndex(of: $1.orientation) ?? 6)
        }
        return lhs < rhs
    }
}

/// Turns smaller than this are left alone: the faces already line up.
let placementTurnMinimumDegrees: Float = 0.01

/// An angle in radians folded into a quarter turn, (−45°, 45°].
func zAlignmentFold(_ angle: Double) -> Double {
    var folded = angle.truncatingRemainder(dividingBy: .pi / 2)
    if folded > .pi / 4 { folded -= .pi / 2 } else if folded <= -.pi / 4 { folded += .pi / 2 }
    return folded
}

/// "23°", or "under 1°".
func printPlacementTurnDegreesLabel(_ degrees: Float) -> String {
    let whole = Int(abs(degrees).rounded())
    return whole == 0 ? "under 1°" : "\(whole)°"
}

/// The placement Studio chose, any turn about Z after it, and what to tell the seller about it.
struct PrintPlacementChoice: Equatable, Sendable {
    /// The chosen placement before the turn; its contact and overhang figures don't change with the turn.
    let assessment: OrientationAssessment
    /// Counter-clockwise from above, −45° to 45°; 0 when not turned.
    let zTurnDegrees: Float
    /// The placement including the turn, ready for `STLMesh.oriented`.
    var orientation: PrintOrientation { assessment.orientation.turned(byDegrees: zTurnDegrees) }
    /// Less than the minimum bed contact touches the bed, because no placement had it.
    var smallBedContact: Bool { !assessment.meetsMinimumContact }
    var tippingProne: Bool { assessment.tippingProne }
    /// One line each for the turn, a small bed contact and a tipping risk, in that order.
    var lines: [String] {
        [printPlacementTurnLine(zTurnDegrees), smallBedContact ? printPlacementSmallContactLine(assessment) : nil,
         printPlacementTippingLine(assessment)].compactMap { $0 }
    }
}

func printPlacementTurnLine(_ degrees: Float) -> String? {
    degrees == 0 ? nil : "Turned \(printPlacementTurnDegreesLabel(degrees)) about Z to line up its faces."
}

/// Where a base goes. Size and base is blocked on a print-ready copy, so its advice points to the original.
func printPlacementBaseAdvice(onCopy: Bool) -> String {
    onCopy ? "Add a flat base or plinth to the original in Size and base, then use Make Print-Ready Copy."
        : "Add a flat base or plinth in Size and base."
}

/// The small-contact line from its figures; a nil contact means no flat face touches the bed.
func printPlacementSmallContactText(contactMM2: Float?, minimumMM2: Float, onCopy: Bool = false) -> String {
    guard let contactMM2 else { return "No flat face touches the bed. \(printPlacementBaseAdvice(onCopy: onCopy))" }
    return String(format: "Small bed contact: about %.0f mm² touches the bed, under the %.0f mm² Studio looks for. ", contactMM2, minimumMM2)
        + printPlacementBaseAdvice(onCopy: onCopy)
}

func printPlacementSmallContactLine(_ assessment: OrientationAssessment, onCopy: Bool = false) -> String {
    printPlacementSmallContactText(contactMM2: assessment.hasFlatContact ? assessment.contactArea : nil,
                                   minimumMM2: assessment.minimumContactMM2, onCopy: onCopy)
}

/// Why a placement could tip, in report order of severity.
enum PrintPlacementTipping: Int, Sendable {
    case beyondEdge = 0, nearEdge = 1, slender = 2
}

/// The tipping risk and the figures its line uses (height and contact width, for a slender part), or nil.
func printPlacementTipping(_ assessment: OrientationAssessment) -> (kind: PrintPlacementTipping, heightMM: Float, widthMM: Float)? {
    if let margin = assessment.tipMarginMM, margin < 0 { return (.beyondEdge, assessment.size.z, 0) }
    if assessment.centreOfMassNearEdge { return (.nearEdge, assessment.size.z, 0) }
    if assessment.slenderOnBed, let width = assessment.contactHullWidth { return (.slender, assessment.size.z, width) }
    return nil
}

func printPlacementTippingText(_ kind: PrintPlacementTipping, heightMM: Float, widthMM: Float, onCopy: Bool = false) -> String {
    let fix = onCopy ? ": add one to the original in Size and base, then use Make Print-Ready Copy." : "."
    switch kind {
    case .beyondEdge:
        return "Could tip: its centre of mass is beyond the edge of what touches the bed. A plinth or a wider flat base helps it stay put\(fix)"
    case .nearEdge:
        return "Could tip: its centre of mass is close to the edge of what touches the bed. A plinth or a wider flat base helps it stay put\(fix)"
    case .slender:
        return String(format: "Tall and narrow on the bed: about %.0f mm tall on a contact %.1f mm wide. Slant uses no brims, so a plinth or a wider base helps it stay put",
                      heightMM, widthMM) + fix
    }
}

/// Why the placement could tip, or nil.
func printPlacementTippingLine(_ assessment: OrientationAssessment, onCopy: Bool = false) -> String? {
    printPlacementTipping(assessment).map { printPlacementTippingText($0.kind, heightMM: $0.heightMM, widthMM: $0.widthMM, onCopy: onCopy) }
}

/// The preferred placement (`preferredOrientation`), then, when `allowTurn`, a turn about Z that lines up its largest
/// vertical faces with X and Y (`zAlignmentTurnDegrees`), kept only if the turned part still fits the build volume.
/// Locked or kept placements pass `allowTurn: false`.
func printPlacement(_ assessments: [OrientationAssessment], in mesh: STLMesh, intent: PartIntent,
                    allowTurn: Bool) -> PrintPlacementChoice? {
    guard let best = preferredOrientation(assessments, intent: intent) else { return nil }
    return PrintPlacementChoice(assessment: best, zTurnDegrees: allowTurn ? mesh.placementTurnDegrees(after: best.orientation) : 0)
}

extension STLMesh {
    func printPlacement(intent: PartIntent, allowTurn: Bool = true) -> PrintPlacementChoice? {
        SlantStudio.printPlacement(orientationAssessments(), in: self, intent: intent, allowTurn: allowTurn)
    }

    /// The turn about Z that lines up this mesh's faces once placed in `orientation`, or 0 when there is none or the
    /// turned part wouldn't fit Slant's build volume.
    func placementTurnDegrees(after orientation: PrintOrientation) -> Float {
        guard let found = oriented(orientation).zAlignmentTurnDegrees(),
              oriented(orientation.turned(byDegrees: found)).maximum.max() <= slantBuildVolumeMM else { return 0 }
        return found
    }
}

// MARK: - Lay It Flat Along Its Length

/// The longest side counts as the part's length only when it is at least this many times its shortest side.
let layFlatMinimumLengthRatio: Float = 1.5
/// Sides within this share of the longest count as equally long; the first of X, Y, Z is then chosen.
let layFlatTieTolerance: Float = 0.005
/// The length lies along the bed when it rises no more than this from it once placed.
let layFlatMaximumRiseDegrees: Float = 15

/// The original axis with the largest extent, or nil for an empty or non-finite size. Ties (within
/// `layFlatTieTolerance` of the longest) go to the first of X, Y, Z, so the choice never depends on rounding.
func layFlatLengthAxis(extents: SIMD3<Float>) -> PrintLoadAxis? {
    let sides = [extents.x, extents.y, extents.z]
    guard sides.allSatisfy({ $0.isFinite && $0 >= 0 }), let longest = sides.max(), longest > 0 else { return nil }
    let index = sides.firstIndex { $0 >= longest * (1 - layFlatTieTolerance) } ?? 0
    return [PrintLoadAxis.x, .y, .z][index]
}

/// Under the Lay It Flat button when it is offered.
let layFlatCaption = "The bond between layers is the weakest direction in a print, so a part loaded along its length usually does better lying down."

/// Why Lay It Flat isn't offered, with the line that says so.
enum LayFlatUnavailable: Equatable, Sendable {
    case zUpLocked, keptPlacement, fromPrintReadyCopy, preparedCopy, decorative, needsDescription, noClearLength, alreadySet
    case noPlacement, noFlatSide, placementStandsItUp

    var message: String {
        switch self {
        case .preparedCopy:
            return "This copy is already placed for its purpose, and its directions describe the original. Use Lay It Flat on the original instead."
        case .zUpLocked:
            return "This copy keeps Z up because its features depend on the print layers. Use Lay It Flat on the original instead."
        case .keptPlacement:
            return "Its way up was chosen in Which way is up?, so Studio keeps that placement."
        case .fromPrintReadyCopy:
            return "This is a copy of a print-ready copy, and its directions describe the original. Use Lay It Flat on the original instead."
        case .decorative:
            return "Decorative parts are placed for fewer overhangs and a steady base, so a stress direction is ignored."
        case .needsDescription:
            return "Describe what the part does first."
        case .noClearLength:
            return "Its sides are close in length, so it has no clear length to lay along. Choose the stress direction yourself."
        case .alreadySet:
            return "The stress direction already runs along its length."
        case .noPlacement:
            return "No flat-bed placement fits among the positions checked."
        case .noFlatSide:
            return "It has no flat side to lie on: add a flat base in Size and base first."
        case .placementStandsItUp:
            return "Placement would still stand it on end: for this purpose, fewer overhangs and a steadier bed face count for more. If it carries load, choose Bracket, Clip or Custom as its purpose."
        }
    }
}

/// What Lay It Flat would save and how the part would then be placed, for the seller to see before saving.
struct LayFlatPlan: Equatable, Sendable {
    /// The intent to save: the same purpose, details and material requirement, with the load along the length.
    let intent: PartIntent
    let axis: PrintLoadAxis
    let lengthMM: Float
    /// The placement the existing ranking chooses for `intent`.
    let placement: PrintPlacementChoice
    /// The part as imported, for the overhang comparison; nil when it wasn't measured.
    let asImported: OrientationAssessment?

    /// The placement, before any turn about Z, differs from the file's own way up.
    var changesPlacement: Bool { placement.assessment.orientation != .zUp }

    var lines: [String] {
        let axisName = "the original \(axis.rawValue.suffix(1)) axis"
        var result = [String(format: "Sets the main stress direction to %@, its longest side (about %.0f mm), and keeps the purpose (%@).",
                             axisName, lengthMM, intent.purpose.rawValue.lowercased())]
        result.append(changesPlacement
            ? "Placement then lays it down (\(placement.orientation.base.label)), so layers run along its length instead of across it."
            : "It already lies along its length as imported, so the placement stays as it is and layers run along its length.")
        let laid = placement.assessment
        if let asImported, changesPlacement {
            result.append(String(format: "Overhangs steeper than 45°: about %.0f mm² as imported, %.0f mm² laid flat. Bed contact: about %.0f mm².",
                                 asImported.overhangArea, laid.overhangArea, laid.contactArea))
        } else {
            result.append(String(format: "Overhangs steeper than 45°: about %.0f mm². Bed contact: about %.0f mm².",
                                 laid.overhangArea, laid.contactArea))
        }
        return result + placement.lines
    }
}

enum LayFlatOutcome: Equatable, Sendable {
    case plan(LayFlatPlan)
    case unavailable(LayFlatUnavailable)

    var plan: LayFlatPlan? { if case .plan(let plan) = self { return plan }; return nil }
    var unavailable: LayFlatUnavailable? { if case .unavailable(let reason) = self { return reason }; return nil }
}

/// Lay It Flat Along Its Length: sets the saved load direction to the original axis with the largest extent
/// (`layFlatLengthAxis`), keeping the purpose, so the existing placement ranking lays it along the bed. Never
/// automatic: it only describes what pressing the button would save. Refused for Z-up-locked copies, kept placements
/// (replicas), copies of print-ready copies, Optimise & Save Copy's prepared copies (`preparedCopy`: their saved
/// directions describe the original) and decorative parts. A round part (pin, rod) whose lying placements touch
/// the bed less than Studio looks for gets `.noFlatSide` rather than a placement that could roll.
/// - `extents`: the original mesh's size along X, Y, Z.
/// - `assessments`: its `orientationAssessments()`; `turns`: turns about Z by placement ID, as Optimise for purpose
///   measures them (none means no turn).
func layFlatOutcome(intent: PartIntent, extents: SIMD3<Float>, assessments: [OrientationAssessment], turns: [String: Float] = [:],
                    requiresZUp: Bool, keepsPlacement: Bool, fromPrintReadyCopy: Bool, preparedCopy: Bool = false) -> LayFlatOutcome {
    if requiresZUp { return .unavailable(.zUpLocked) }
    if keepsPlacement { return .unavailable(.keptPlacement) }
    if fromPrintReadyCopy { return .unavailable(.fromPrintReadyCopy) }
    if preparedCopy { return .unavailable(.preparedCopy) }
    if intent.purpose == .decorative { return .unavailable(.decorative) }
    if intent.purpose == .custom && intent.details.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        return .unavailable(.needsDescription)
    }
    guard let axis = layFlatLengthAxis(extents: extents), let vector = axis.vector else { return .unavailable(.noPlacement) }
    let lengths = [extents.x, extents.y, extents.z]
    let length = lengths.max() ?? 0
    if length < layFlatMinimumLengthRatio * (lengths.min() ?? 0) { return .unavailable(.noClearLength) }
    if intent.load == axis { return .unavailable(.alreadySet) }
    var laid = intent
    laid.load = axis
    guard let best = preferredOrientation(assessments, intent: laid) else { return .unavailable(.noPlacement) }
    let rise = Float(sin(Double(layFlatMaximumRiseDegrees) * .pi / 180))
    func liesFlat(_ assessment: OrientationAssessment) -> Bool { abs(assessment.orientation.rotate(vector).z) <= rise }
    guard liesFlat(best) else {
        // Lying placements the ranking may pick from: they fit, rest on a flat face and touch the bed enough.
        let canLie = assessments.contains {
            liesFlat($0) && $0.fits && $0.meetsMinimumContact && $0.surfaceArea.isFinite && $0.surfaceArea > 0
        }
        return .unavailable(canLie ? .placementStandsItUp : .noFlatSide)
    }
    // Lying on a sliver of a round side would roll: a flat base is the fix, never such a placement.
    guard best.meetsMinimumContact else { return .unavailable(.noFlatSide) }
    let choice = PrintPlacementChoice(assessment: best, zTurnDegrees: turns[best.id] ?? 0)
    return .plan(LayFlatPlan(intent: laid, axis: axis, lengthMM: length, placement: choice,
                             asImported: assessments.first { $0.orientation == .zUp }))
}

extension STLMesh {
    /// `layFlatOutcome` for this (original) mesh and `model`, measuring its placements and the chosen one's turn.
    func layFlatOutcome(for model: LocalModel) -> LayFlatOutcome {
        let intent = model.partIntent ?? PartIntent()
        let lineage = studioCopyLineage(model)
        // Refusals first, so a locked copy is never measured.
        let quick = SlantStudio.layFlatOutcome(intent: intent, extents: maximum - minimum, assessments: [],
                                               requiresZUp: lineage.inheritsZUpLock, keepsPlacement: lineage.keepsPlacement,
                                               fromPrintReadyCopy: lineage.fromPrintReadyCopy, preparedCopy: model.printRecipe != nil)
        guard quick.unavailable == .noPlacement else { return quick }
        let assessments = orientationAssessments()
        let outcome = SlantStudio.layFlatOutcome(intent: intent, extents: maximum - minimum, assessments: assessments,
                                                 requiresZUp: false, keepsPlacement: false, fromPrintReadyCopy: false)
        guard let plan = outcome.plan else { return outcome }
        let turn = placementTurnDegrees(after: plan.placement.assessment.orientation)
        return SlantStudio.layFlatOutcome(intent: intent, extents: maximum - minimum, assessments: assessments,
                                          turns: [plan.placement.assessment.id: turn],
                                          requiresZUp: false, keepsPlacement: false, fromPrintReadyCopy: false)
    }
}

/// For callers outside Optimise for purpose (such as the print-ready copy's slender-upright advisory): the intent
/// Lay It Flat would save on `model`, the original, with `mesh` read from its file, or the reason it isn't offered.
/// Saving the intent is the caller's explicit action (`StudioStore.savePartIntent`); nothing is saved here.
func layFlatIntent(for model: LocalModel, mesh: STLMesh) -> (intent: PartIntent?, reason: String?) {
    switch mesh.layFlatOutcome(for: model) {
    case .plan(let plan): return (plan.intent, nil)
    case .unavailable(let reason): return (nil, reason.message)
    }
}

struct PrintOrientationCard: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    @State private var mesh: STLMesh?
    @State private var assessments: [OrientationAssessment] = []
    @State private var failure: String?
    @State private var intent = PartIntent()
    @State private var preparing = false
    @State private var loaded = false
    @State private var expanded = false
    /// Turns about Z by placement ID, measured with the assessments (none for locked or kept placements).
    @State private var turns: [String: Float] = [:]
    /// Lay It Flat's plan, shown for the seller to confirm before anything is saved.
    @State private var layFlatPreview: LayFlatPlan?

    private var best: PrintPlacementChoice? {
        preferredOrientation(assessments, intent: intent).map { PrintPlacementChoice(assessment: $0, zTurnDegrees: turns[$0.id] ?? 0) }
    }

    var body: some View {
        Card {
            DisclosureGroup(isExpanded: $expanded) {
                VStack(alignment: .leading, spacing: 16) {
                    if let recipe = model.printRecipe {
                        preparedSummary(recipe)
                    } else if !model.supportsPreview {
                        Text(stlOnlyToolNote(model) ?? stlCopyToolNote)
                    } else if let failure {
                        Text(failure)
                    } else if let mesh {
                        purposeForm(mesh)
                        if model.requiresZUp {
                            Text("Keeps Z up: this copy has features that depend on the print layers, such as cells, gaps, teardrop holes, bridging or matched walls. Prepare a different orientation from the source before adding them.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        if let best {
                            DisclosureGroup("Preview print placement") {
                                VStack(alignment: .leading, spacing: 8) {
                                    STLSceneView(mesh: mesh.oriented(best.orientation), showsPrintBed: true)
                                        .id(best.orientation).frame(height: 220)
                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                    Text("Flat face on bed · Base at Z = 0").font(.callout).foregroundStyle(.secondary)
                                }.padding(.top, 8)
                            }.studioDisclosureStyle()
                            Text(intent.explanation).font(.callout).foregroundStyle(.secondary)
                            ForEach(best.lines, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                            Button(preparing ? "Preparing…" : "Optimise & Save Copy") { prepareCopy(mesh, orientation: best.orientation) }
                                .buttonStyle(.borderedProminent)
                                .disabled(store.busy || preparing)
                        } else if intent.isReady {
                            Text("No flat-bed placement fits among the positions checked. Prepare a custom orientation in your CAD tool or slicer, then import it here.")
                        }
                        materialAdvice
                        DisclosureGroup("How optimisation works") {
                            Text("Compares standard placements and up to 24 additional face directions, preferring ones with enough flat contact and a centre of mass well inside it, then turns the part about Z so faces drawn at an angle line up with the print axes. Shape, dimensions, holes and clearances don’t change. Uses your chosen material. Slant prints a part in the placement it is uploaded in, re-orienting only an obviously wrong upload, so this choice decides which way the layers run. Slant’s settings are fixed (0.2 mm layers, 1 mm walls, 25% infill, overhangs up to 50°); its tolerances aren’t published, and this is not a mechanical simulation.")
                                .font(.callout).foregroundStyle(.secondary).padding(.top, 8)
                        }.studioDisclosureStyle()
                    } else {
                        ProgressView("Preparing placement options…")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 16)
            } label: {
                SectionHeading(title: "Optimise for purpose", caption: model.printRecipe.map { "Prepared for \($0.intent.purpose.rawValue.lowercased()) · View recipe" } ?? "Choose how this part sits on the print bed for its use")
            }.studioDisclosureStyle()
        }
        .task(id: model.id) {
            loaded = false
            intent = model.partIntent ?? PartIntent()
            mesh = nil; assessments = []; failure = nil; turns = [:]; layFlatPreview = nil
            guard model.supportsPreview, model.printRecipe == nil else { return }
            let url = model.url
            let keepCellRoofsUp = model.requiresZUp
            // A locked or kept placement keeps its way round as well as its way up.
            let mayTurn = !model.requiresZUp && model.keepsPlacement != true
            let result = await Task.detached(priority: .userInitiated) {
                Result {
                    let mesh = try STLMesh.read(from: url)
                    let assessments = mesh.orientationAssessments().filter { !keepCellRoofsUp || $0.orientation == .zUp }
                    var turns: [String: Float] = [:]
                    if mayTurn {
                        for assessment in assessments where assessment.fits && assessment.hasFlatContact {
                            if Task.isCancelled { break }
                            turns[assessment.id] = mesh.placementTurnDegrees(after: assessment.orientation)
                        }
                    }
                    return (mesh, assessments, turns)
                }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let value): mesh = value.0; assessments = value.1; turns = value.2
            case .failure(let error): failure = error.localizedDescription
            }
            loaded = true
        }
        .onChange(of: intent) { _, value in
            // A plan describes the intent it was made from.
            layFlatPreview = nil
            guard loaded else { return }
            store.savePartIntent(value, modelID: model.id)
        }
    }

    private func purposeForm(_ mesh: STLMesh) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Part purpose", selection: $intent.purpose) {
                ForEach(PartPurpose.allCases) { Text($0.rawValue).tag($0) }
            }
            if intent.purpose == .custom {
                TextField("What will this part do?", text: $intent.details)
                    .textFieldStyle(.roundedBorder)
                Text("Your description is saved with the part. Choose the stress direction below to guide placement.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if intent.purpose != .decorative {
                Picker("Main stress direction", selection: $intent.load) {
                    ForEach(PrintLoadAxis.allCases) { Text($0.rawValue).tag($0) }
                }
                Text(intent.purpose == .clip
                     ? "Choose the original STL axis along the flexing arm."
                     : "Choose the original STL axis of the main tensile stress. For bending, use the length of the loaded arm.")
                    .font(.callout).foregroundStyle(.secondary)
                if intent.purpose.needsDirection && intent.load == .unknown {
                    Text("Choose a direction to prepare this part for its purpose.").font(.caption)
                }
                layFlatControls(mesh)
            }
        }
        .disabled(preparing)
    }

    /// Lay It Flat Along Its Length: the seller presses it, sees what it would save and how the part would be placed,
    /// then confirms. Nothing changes until Set Stress Direction.
    @ViewBuilder private func layFlatControls(_ mesh: STLMesh) -> some View {
        let outcome = layFlatOutcome(intent: intent, extents: mesh.maximum - mesh.minimum, assessments: assessments, turns: turns,
                                     requiresZUp: model.requiresZUp, keepsPlacement: model.keepsPlacement == true,
                                     fromPrintReadyCopy: model.derivesFromPrintReadyCopy, preparedCopy: model.printRecipe != nil)
        if let preview = layFlatPreview {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(preview.lines, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
                HStack {
                    Button("Cancel") { layFlatPreview = nil }
                    Button("Set Stress Direction") {
                        let saved = preview.intent
                        layFlatPreview = nil
                        intent = saved
                    }
                    .disabled(store.busy)
                }
            }
            .padding(10)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
            .fixedSize(horizontal: false, vertical: true)
        } else if outcome.unavailable != .alreadySet && outcome.unavailable != .noClearLength {
            // Not shown at all for a boxy part (no clear length) or when the direction is already set.
            VStack(alignment: .leading, spacing: 4) {
                Button("Lay It Flat Along Its Length…") { layFlatPreview = outcome.plan }
                    .disabled(outcome.plan == nil || store.busy)
                    .help("Sets the stress direction to its longest side, so layers run along it. Shows what changes first.")
                Text(outcome.unavailable?.message ?? layFlatCaption)
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Optional guidance under the placement. The material itself is chosen in Print configuration; a suggestion
    /// changes it only when picked here. Without the seller's own requirement, the purpose's suggestion is shown
    /// (`materialAdviceGoal`) and nothing is saved until the seller picks one.
    private var materialAdvice: some View {
        DisclosureGroup("Material suggestions for this use") {
            VStack(alignment: .leading, spacing: 10) {
                let advice = materialAdviceGoal(intent)
                Picker("Main requirement", selection: Binding(get: { advice?.goal ?? .keepCurrent }, set: { intent.materialGoal = $0 })) {
                    ForEach(MaterialGoal.allCases) { Text($0.label).tag($0) }
                }
                .fixedSize()
                if let advice {
                    if !advice.chosen {
                        Text(materialSuggestedCaption(intent.purpose))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text(advice.goal.guidance).font(.callout).foregroundStyle(.secondary)
                    let options = recommendedMaterials(for: advice.goal, in: store.filaments)
                    if options.isEmpty && !advice.goal.profiles.isEmpty {
                        Text("No matching material is currently listed as available. Keep the material chosen in Print configuration.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else {
                        let selected = options.first(where: { $0.id == store.filamentID })
                        let others = options.filter { $0.id != store.filamentID }
                        let showsType = Set(options.map(filamentType)).count > 1
                        if let selected {
                            Label("Print configuration already uses \(selected.name).", systemImage: "checkmark.circle")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        // Kept alongside the "already uses" line so another suggestion can still be chosen.
                        if !others.isEmpty {
                            Menu(selected == nil ? "Use a Suggested Material" : "Use Another Suggested Material") {
                                ForEach(others) { material in
                                    Button(showsType ? "\(filamentType(material)) · \(material.name)" : material.name) { store.filamentID = material.id }
                                }
                            }
                            .fixedSize()
                            .disabled(store.busy || preparing)
                            .help("Sets the material in Print configuration")
                        }
                    }
                }
                Text(materialAdviceFoodNote).font(.callout).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }.studioDisclosureStyle()
        .font(.callout)
    }

    private func preparedSummary(_ recipe: PreparedPrintRecipe) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Prepared copy saved", systemImage: "checkmark.circle.fill").font(.headline)
            Text("Shape and dimensions preserved. Upload this copy and estimate it with your chosen material.")
                .font(.callout).foregroundStyle(.secondary)
            DisclosureGroup("Recipe details") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(recipe.intent.explanation)
                    if !recipe.intent.details.isEmpty { Text(recipe.intent.details) }
                    Text("Original: \(recipe.sourceName)")
                }.font(.callout).foregroundStyle(.secondary).padding(.top, 8)
            }.studioDisclosureStyle()
            if let material = recipe.materialID, material != store.filamentID {
                Text("The material selection has changed since preparation. Placement is preserved; strength depends on the material used.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if let original = store.localModels.first(where: { $0.id == recipe.sourceID }) {
                Button("Prepare Another Version") { store.select(original) }
                    .disabled(store.busy)
            }
        }
    }

    private func prepareCopy(_ mesh: STLMesh, orientation: PrintOrientation) {
        preparing = true
        let name = model.name
        let recipe = PreparedPrintRecipe(sourceID: model.id, sourceName: name, intent: intent,
                                         orientation: orientation, materialID: store.filamentID.isEmpty ? nil : store.filamentID,
                                         created: Date())
        store.savePartIntent(intent, modelID: model.id)
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Result { () -> URL in
                    let folder = studioTempFolderURL(prefix: preparedCopyTempFolderPrefix)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    let safeName = URL(fileURLWithPath: name).lastPathComponent
                    let url = folder.appendingPathComponent("\(safeName)-\(recipe.intent.purpose.rawValue.lowercased())-prepared.stl")
                    do { try mesh.oriented(orientation).binarySTL().write(to: url, options: .atomic) }
                    catch { try? FileManager.default.removeItem(at: folder); throw error }
                    return url
                }
            }.value
            switch result {
            case .success(let url):
                // Lock-bearing records go with the copy, so a Z-up-locked model's copy stays locked (`requiresZUp`).
                store.importModel(url, recipe: recipe, improvement: model.designImprovement, reinforcement: model.reinforcement,
                                  autoImprovement: model.autoImprovement, sourceDetails: model.sourceDetails,
                                  inheritsZUpLock: model.requiresZUp, origin: .studioToolCopy, keepsPlacement: model.keepsPlacement == true, fromPrintReadyCopy: model.derivesFromPrintReadyCopy)
                try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            case .failure(let error): store.showError(error.localizedDescription)
            }
            preparing = false
        }
    }
}
