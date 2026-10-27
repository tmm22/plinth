import Foundation
import simd

struct AutoImprovementStep: Codable, Equatable, Sendable {
    let settings: ReinforcementSettings
    let summary: String
    let addedVolumeMM3: Double
    let removedVolumeMM3: Double
}

/// Saved with a one-click improved copy: what was applied, what failed its checks, and what was left for manual review.
struct AutoImprovementRecord: Codable, Equatable, Sendable {
    let sourceID: UUID
    let orientation: PrintOrientation
    let applied: [AutoImprovementStep]
    let skipped: [String]
    let manual: [String]
    let created: Date
    var requiresZUp: Bool { applied.contains { $0.settings.kind.keepsZUp } }
}

struct AutoImprovementResult: Sendable {
    let mesh: STLMesh
    let orientation: PrintOrientation
    let applied: [AutoImprovementStep]
    let skipped: [String]
    let manual: [String]
    /// A time limit cut the run short (Auto-improve's own, or a treatment's preview limit), so the result may differ
    /// from a run with no limit. Callers never save such a result: the same model must always give the same copy.
    var timedOut = false
    var changed: Bool { !applied.isEmpty || orientation != .zUp }
}

/// tan 40°, rounded up: an overhang chamfer this tall per millimetre of depth slopes at just under Slant's 50° from
/// vertical (49.97°). The overhang tool uses it for regions shorter than they are deep; Auto-improve's ledge rule
/// lets a ledge qualify with this much height below it.
let overhangChamferMinimumRise: Float = 0.84

struct AutoCandidate: Sendable {
    let settings: ReinforcementSettings
    let summary: String
    /// Tried in turn if the first placement fails a check; a different overlap avoids an unlucky near-coincidence.
    var alternatives: [ReinforcementSettings] = []
}

/// Finds axis-aligned features that suit a treatment and applies each through `ReinforcementEngine.preview`,
/// so every change gets the same closed-solid, envelope and body checks as a manual one.
/// Detection covers features aligned with the print axes; oblique or freeform features are not found.
enum AutoImprover {
    enum Phase: CaseIterable {
        case bridge, overhang, thicken, fillet
        var title: String {
            switch self {
            case .bridge: return "Counterbore bridging"
            case .overhang: return "Overhang chamfers"
            case .thicken: return "Wall matching"
            case .fillet: return "Inside-corner fillets"
            }
        }
    }

    static let maximumLedgeDepth: Float = 15
    static let maximumFillets = 12
    /// The line width wall matching rounds to. Slant publishes 1 mm walls of about 2 lines (and a 0.4 mm nozzle),
    /// so about 0.5 mm a line; it doesn't publish the width itself. A wall of whole 0.5 mm lines prints without gap
    /// fill: 0.65–1 mm walls reach Slant's 1 mm, and 1.5–2 mm walls reach 2 mm, where both sides' 2-line walls meet.
    static let lineWidth: Float = 0.5
    /// A chamfer under a ledge needs at least this much height per millimetre of depth: tan 40°, rounded up, so its
    /// slope stays within Slant's 50° overhang limit. Chamfers are 45° wherever the height allows.
    static let minimumLedgeRise: Float = overhangChamferMinimumRise

    /// Prepared or Z-up-locked copies keep their axes; others use the purpose-based placement, turned about Z to line
    /// up faces drawn at an angle (`printPlacement`).
    static func orientation(for mesh: STLMesh, intent: PartIntent, locked: Bool) -> PrintOrientation? {
        placement(for: mesh, intent: intent, locked: locked)?.orientation
    }

    /// The placement with its turn and flags. Locked copies get their own placement, unturned, with its flags.
    static func placement(for mesh: STLMesh, intent: PartIntent, locked: Bool) -> PrintPlacementChoice? {
        if locked { return PrintPlacementChoice(assessment: mesh.orientationAssessment(.zUp), zTurnDegrees: 0) }
        return mesh.printPlacement(intent: intent, allowTurn: true)
    }

    /// Which treatments a run may apply. The Auto-improve card uses `.full`. The automatic print-ready copy uses
    /// `.fitSafe`, which never changes a fitting surface: bridging layers and chamfers under free ledges only. Wall
    /// matching and fillets take space from cavities and inside corners, so they come only after the seller confirms
    /// nothing has to fit (`.fitAffecting`, run on the print-ready copy, whose bridging and chamfers are already done).
    enum Profile: Sendable, CaseIterable {
        case full, fitSafe, fitAffecting
        var phases: [Phase] {
            switch self {
            case .full: return Phase.allCases
            case .fitSafe: return [.bridge, .overhang]
            case .fitAffecting: return [.thicken, .fillet]
            }
        }
    }

    static func improve(_ source: STLMesh, intent: PartIntent, orientation: PrintOrientation, profile: Profile = .full,
                        progress: @Sendable (String) -> Void = { _ in },
                        cancelled: @escaping @Sendable () -> Bool = { false }) throws -> AutoImprovementResult {
        let deadline = Date().addingTimeInterval(240)
        let stop: @Sendable () -> Bool = { cancelled() || Date() > deadline }
        func check() throws { if cancelled() { throw StudioError("Auto-improve stopped. Nothing was saved.") } }
        progress("Placing the part for printing…")
        var mesh = source.oriented(orientation)
        var solid = try mesh.reinforcementSolid()
        var applied: [AutoImprovementStep] = [], skipped: [String] = [], manual: [String] = []
        var timedOut = false
        phases: for phase in profile.phases where !stop() {
            progress("Looking for \(phase.title.lowercased())…")
            let found = candidates(phase, in: mesh, intent: intent, stop: stop)
            manual += found.manual
            for (index, candidate) in found.candidates.enumerated() {
                if stop() { break }
                progress("\(phase.title) · \(index + 1) of \(found.candidates.count)")
                var failure: Error?
                for settings in [candidate.settings] + candidate.alternatives where !stop() {
                    let started = Date()
                    do {
                        let preview = try ReinforcementEngine.preview(mesh, solid: solid, settings: settings, cancelled: stop)
                        mesh = preview.mesh
                        solid = try preview.solid ?? mesh.reinforcementSolid()
                        applied.append(AutoImprovementStep(settings: settings, summary: candidate.summary,
                                                           addedVolumeMM3: preview.addedVolume, removedVolumeMM3: preview.removedVolume))
                        failure = nil
                        break
                    } catch {
                        try check()
                        // A preview that ran out of time says nothing about whether the treatment fits.
                        if Date().timeIntervalSince(started) >= ReinforcementEngine.previewTimeLimit { timedOut = true; break phases }
                        failure = failure ?? error
                    }
                }
                if let failure { skipped.append("\(candidate.summary): \(failure.localizedDescription)") }
            }
        }
        try check()
        if Date() > deadline { timedOut = true }
        if timedOut { skipped.append("Time limit reached; the remaining treatments were not tried.") }
        // The print-ready copy (`.fitSafe`) offers Add Teardrop Holes… on its own panel instead of this note.
        manual += reviewNotes(mesh, stop: cancelled, teardrops: profile != .fitSafe)
        try check()
        return AutoImprovementResult(mesh: mesh, orientation: orientation, applied: applied, skipped: skipped, manual: manual,
                                     timedOut: timedOut)
    }

    static func candidates(_ phase: Phase, in mesh: STLMesh, intent: PartIntent, stop: @Sendable () -> Bool = { false }) -> (candidates: [AutoCandidate], manual: [String]) {
        let topology = Topology(mesh)
        switch phase {
        case .bridge: return (bridges(topology, mesh), [])
        case .overhang: return overhangs(topology, mesh, stop: stop)
        case .thicken: return (thinWalls(topology, mesh, stop: stop), [])
        case .fillet: return intent.purpose == .decorative ? ([], []) : (fillets(topology, mesh, stop: stop), [])
        }
    }

    // MARK: - Detection

    private static let up = SIMD3<Float>(0, 0, 1)
    private static let axisNames = ["X", "Y", "Z"]

    private static func bridges(_ topology: Topology, _ mesh: STLMesh) -> [AutoCandidate] {
        var result: [AutoCandidate] = []
        for facet in topology.facets where facet.normal == -up {
            let z = -facet.coord
            guard z > mesh.minimum.z + 0.3, mesh.maximum.z - z >= 1.2,
                  let loops = topology.loops(facet), loops.count == 2,
                  let a = topology.circle(loops[0], normal: facet.normal), let b = topology.circle(loops[1], normal: facet.normal) else { continue }
            let (outer, inner) = abs(a.area) > abs(b.area) ? (a, b) : (b, a)
            // The strip stays within the counterbore's flats, and spans the full through-hole.
            let d = 2 * inner.radius, s = 2 * outer.inradius
            guard simd_distance(outer.centre, inner.centre) < 0.05, d / 2 >= 0.6, s >= d + 1.2 else { continue }
            var settings = ReinforcementSettings(kind: .bridge)
            settings.size = SIMD3(s, s, 1.2)
            settings.boreDiameter = d
            settings.offset = SIMD3(outer.centre.x - s / 2, outer.centre.y - s / 2, z) - mesh.minimum
            result.append(AutoCandidate(settings: settings, summary: String(format: "Counterbore bridging · ⌀%.1f mm hole at X %.1f, Y %.1f", d, outer.centre.x - mesh.minimum.x, outer.centre.y - mesh.minimum.y)))
        }
        return result
    }

    private static func overhangs(_ topology: Topology, _ mesh: STLMesh, stop: () -> Bool) -> (candidates: [AutoCandidate], manual: [String]) {
        var result: [AutoCandidate] = [], manual: [String] = []
        for run in topology.concaveRuns(in: mesh) where !stop() {
            guard let (n, ledge) = run.pair(with: -up), n.z == 0 else { continue }
            let z = -ledge.coord, mid = run.point(at: (run.start + run.end) / 2)
            let inside = mid + n * 0.01 + up * 0.05
            guard ReinforcementEngine.containsMaterial(inside, in: mesh),
                  let reach = ReinforcementEngine.distanceToSurface(from: inside, along: n, in: mesh) else { continue }
            let depth = reach + 0.01
            let label = String(format: "%.1f mm ledge along %@ at Z %.1f", depth, axisNames[run.axis], z - mesh.minimum.z)
            guard depth >= 1 else { continue }
            guard depth <= maximumLedgeDepth else {
                manual.append("\(label) is too deep for an automatic chamfer. Use supports, or redesign it in CAD.")
                continue
            }
            // 45° where the height below allows it; otherwise as tall as fits, keeping 0.1 mm clear of the bed, and
            // never steeper than Slant's 50° (`minimumLedgeRise`).
            let below = z - mesh.minimum.z
            guard below >= depth * minimumLedgeRise else {
                manual.append("\(label) has too little height below it for a chamfer within Slant’s 50° overhang limit.")
                continue
            }
            let rise = below >= depth ? depth : max(depth * minimumLedgeRise, below - 0.1)
            // Only free cantilevered ledges: the wedge must sit entirely in open space.
            let wedge: [(Float, Float)] = [(0.1, 0.1), (0.5, 0.1), (0.85, 0.05), (0.1, 0.5), (0.05, 0.85)]
            let clear = [Float(0.1), 0.5, 0.9].allSatisfy { u in
                let base = run.point(at: run.start + (run.end - run.start) * u)
                return wedge.allSatisfy { !ReinforcementEngine.containsMaterial(base + n * ($0.0 * depth) - up * ($0.1 * rise), in: mesh) }
            }
            guard clear, let (orientation, turns) = frame(y: n, z: up) else { continue }
            let ends = trimmed(run, probe: n * (0.3 * depth) - up * (0.3 * rise), in: mesh)
            func placed(overlap: Float) -> ReinforcementSettings {
                var settings = ReinforcementSettings(kind: .overhang)
                settings.orientation = orientation
                settings.quarterTurns = turns
                settings.size = SIMD3(ends.end - ends.start, depth + overlap, rise + overlap)
                var low = SIMD3<Float>.zero
                low[run.axis] = ends.start
                let wall = run.coordinate(of: n)
                low[n.axisIndex] = n.isPositive ? wall - overlap : wall - depth
                low.z = z - rise
                settings.offset = low - mesh.minimum
                return settings
            }
            let slope = rise < depth ? String(format: ", %.0f° slope", atan(depth / rise) * 180 / .pi) : ""
            result.append(AutoCandidate(settings: placed(overlap: 0.2), summary: "Overhang chamfer · \(label)\(slope)", alternatives: [placed(overlap: 0.27)]))
        }
        return (result, manual)
    }

    private static func thinWalls(_ topology: Topology, _ mesh: STLMesh, stop: () -> Bool) -> [AutoCandidate] {
        var result: [AutoCandidate] = []
        let walls = topology.facets.filter { $0.normal.z == 0 && topology.area($0) >= 16 }.sorted { topology.area($0) > topology.area($1) }
        for facet in walls.prefix(16) where !stop() {
            let n = facet.normal, i = n.axisIndex, k = i == 0 ? 1 : 0
            let plane = facet.coord * (n.isPositive ? 1 : -1)
            // Only inner faces of outer walls are thickened, so the exterior is never changed.
            let outside = n.isPositive ? mesh.minimum[i] : mesh.maximum[i]
            guard abs(plane - mesh.minimum[i]) > 0.001, abs(plane - mesh.maximum[i]) > 0.001 else { continue }
            let (low, high) = topology.extent(facet)
            let width = high[k] - low[k], height = high.z - low.z
            guard width >= 3, height >= 3 else { continue }
            var thicknesses: [Float] = []
            var supported = true
            for fu in [Float(0.05), 0.275, 0.5, 0.725, 0.95] {
                for fv in [Float(0.05), 0.275, 0.5, 0.725, 0.95] {
                    var p = SIMD3<Float>.zero
                    p[i] = plane; p[k] = low[k] + width * fu; p.z = low.z + height * fv
                    let behind = p - n * 0.01
                    guard ReinforcementEngine.containsMaterial(behind, in: mesh), !ReinforcementEngine.containsMaterial(p + n * 0.3, in: mesh),
                          let reach = ReinforcementEngine.distanceToSurface(from: behind, along: -n, in: mesh) else { supported = false; break }
                    thicknesses.append(reach + 0.01)
                }
                if !supported { break }
            }
            guard supported, let t = thicknesses.min(), let tMax = thicknesses.max(), tMax - t <= 0.02,
                  t >= 0.65, t <= 6 * lineWidth, abs(plane - (n.isPositive ? t : -t) - outside) < 0.01 else { continue }
            let extra = (t / lineWidth - 0.001).rounded(.up) * lineWidth - t
            guard extra >= 0.02, let (orientation, turns) = frame(y: n, z: up) else { continue }
            // Run 0.05 mm into neighbouring material, and stop 0.05 mm short of open edges: a slab face
            // coincident with an existing face makes the Boolean unreliable. Both are well under one layer.
            func reach(_ axis: Int, _ value: Float, _ direction: Float) -> Float {
                var probe = SIMD3<Float>.zero
                probe[i] = plane + (n.isPositive ? 0.1 : -0.1)
                probe[k] = low[k] + width / 2; probe.z = low.z + height / 2
                probe[axis] = value + direction * 0.1
                return ReinforcementEngine.containsMaterial(probe, in: mesh) ? 0.05 : -0.05
            }
            let k0 = low[k] - reach(k, low[k], -1), k1 = high[k] + reach(k, high[k], 1)
            let z0 = low.z - reach(2, low.z, -1), z1 = high.z + reach(2, high.z, 1)
            let depth = max(Float(1.2), t)
            var settings = ReinforcementSettings(kind: .thicken)
            settings.orientation = orientation
            settings.quarterTurns = turns
            settings.lineWidth = lineWidth
            settings.size = SIMD3(k1 - k0, depth, z1 - z0)
            var corner = SIMD3<Float>.zero
            corner[i] = n.isPositive ? outside : outside - depth
            corner[k] = k0; corner.z = z0
            settings.offset = corner - mesh.minimum
            result.append(AutoCandidate(settings: settings, summary: String(format: "Wall matching · %.2f mm wall facing %@%@ thickened to %.2f mm", t, n.isPositive ? "+" : "−", axisNames[i], t + extra)))
        }
        return result
    }

    private static func fillets(_ topology: Topology, _ mesh: STLMesh, stop: () -> Bool) -> [AutoCandidate] {
        var result: [AutoCandidate] = []
        // Fillets under a downward face would print as overhangs.
        let runs = topology.concaveRuns(in: mesh).filter { $0.n1 != -up && $0.n2 != -up }.sorted { $0.length > $1.length }
        for run in runs where !stop() {
            if result.count == maximumFillets { break }
            let n1 = run.n1, n2 = run.n2, mid = run.point(at: (run.start + run.end) / 2)
            func wall(_ n: SIMD3<Float>, beside other: SIMD3<Float>) -> Float? {
                let inside = mid + other * 2 - n * 0.01
                guard ReinforcementEngine.containsMaterial(inside, in: mesh) else { return nil }
                return ReinforcementEngine.distanceToSurface(from: inside, along: -n, in: mesh).map { $0 + 0.01 }
            }
            guard let t1 = wall(n1, beside: n2), let t2 = wall(n2, beside: n1) else { continue }
            let r = min(max(min(t1, t2) / 2, 1.2), 3)
            let clear = [Float(0.15), 0.5, 0.85].allSatisfy { u in
                let p = run.point(at: run.start + (run.end - run.start) * u)
                let air = [p + (n1 + n2) * (0.3 * r), p + n1 * (1.5 * r + 0.3) + n2 * 0.1, p + n2 * (1.5 * r + 0.3) + n1 * 0.1]
                let solid = [p + n2 * (0.5 * r) - n1 * 0.1, p + n1 * (0.5 * r) - n2 * 0.1]
                return air.allSatisfy { !ReinforcementEngine.containsMaterial($0, in: mesh) } && solid.allSatisfy { ReinforcementEngine.containsMaterial($0, in: mesh) }
            }
            guard clear, let (orientation, turns) = frame(y: n1, z: n2) else { continue }
            let ends = trimmed(run, probe: (n1 + n2) * (0.15 * r), in: mesh)
            func placed(overlap: Float, inset: Float = 0) -> ReinforcementSettings {
                var settings = ReinforcementSettings(kind: .fillet)
                settings.orientation = orientation
                settings.quarterTurns = turns
                settings.size = SIMD3(ends.end - ends.start - 2 * inset, r + overlap, r + overlap)
                settings.thickness = 1.2
                var low = SIMD3<Float>.zero
                low[run.axis] = ends.start + inset
                for n in [n1, n2] {
                    let c = run.coordinate(of: n)
                    low[n.axisIndex] = n.isPositive ? c - overlap : c - r
                }
                settings.offset = low - mesh.minimum
                return settings
            }
            // Last resort: stop clear of fillets crossing at each end, which can leave seams too fine to close.
            result.append(AutoCandidate(settings: placed(overlap: 0.05), summary: String(format: "Inside-corner fillet · %.1f mm radius along %@, %.1f mm long", r, axisNames[run.axis], run.length),
                                        alternatives: [placed(overlap: 0.13)] + (run.length - 2 * (r + 0.1) >= 3 ? [placed(overlap: 0.05, inset: r + 0.1)] : [])))
        }
        return result
    }

    /// Run ends extended 0.05 mm into material that continues past them, or pulled 0.05 mm back from open ends,
    /// so the feature's end faces never coincide with existing faces. `probe` is a point inside the feature's profile.
    private static func trimmed(_ run: Topology.Run, probe offset: SIMD3<Float>, in mesh: STLMesh) -> (start: Float, end: Float) {
        func adjust(_ u: Float, _ direction: Float) -> Float {
            var p = run.point(at: u) + offset
            p[run.axis] = u + direction * 0.1
            return u + direction * (ReinforcementEngine.containsMaterial(p, in: mesh) ? 0.05 : -0.05)
        }
        return (adjust(run.start, -1), adjust(run.end, 1))
    }

    /// Treatments that depend on fit or fastener use are reported, not applied. Horizontal holes are counted by the
    /// teardrop finder, so the note counts exactly the holes Find Horizontal Holes would offer.
    private static func reviewNotes(_ mesh: STLMesh, stop: () -> Bool = { false }, teardrops: Bool = true) -> [String] {
        let topology = Topology(mesh)
        var vertical = Set<SIMD3<Int32>>()
        for facet in topology.facets where facet.normal.z != 0 {
            guard let loops = topology.loops(facet), loops.count > 1 else { continue }
            let circles = loops.compactMap { topology.circle($0, normal: facet.normal) }
            guard let outer = loops.map({ abs(topology.signedArea($0, normal: facet.normal)) }).max() else { continue }
            for circle in circles where abs(circle.area) < outer && circle.radius >= 0.6 {
                vertical.insert(SIMD3<Int32>(Int32(facet.normal.axisIndex), Int32((circle.centre.x * 10).rounded()), Int32((circle.centre.y * 10).rounded())))
            }
        }
        var notes: [String] = []
        if teardrops {
            let eligible = ((try? teardropCandidates(in: mesh, isCancelled: stop)) ?? []).filter(\.eligible).count
            if let note = teardropReviewNote(eligibleCount: eligible) { notes.append(note) }
        }
        if !vertical.isEmpty {
            notes.append("\(vertical.count) vertical bore\(vertical.count == 1 ? "" : "s") found. Mounting collars depend on where fasteners go, so none were added. Add them in Reinforce this part.")
        }
        if mesh.edgeDesignCheck().plainBox {
            notes.append("Square outer edges: a bottom chamfer or rounded corners is available in Design improvements. Not applied, because these change bed contact or remove material.")
        }
        return notes
    }

    /// The axis-permutation frame whose local +Y and +Z point along `y` and `z`.
    private static func frame(y: SIMD3<Float>, z: SIMD3<Float>) -> (PrintOrientation, Int)? {
        for orientation in PrintOrientation.allCases {
            for turns in 0..<4 {
                var settings = ReinforcementSettings()
                settings.orientation = orientation
                settings.quarterTurns = turns
                if settings.rotate(SIMD3(0, 1, 0)) == y && settings.rotate(SIMD3(0, 0, 1)) == z { return (orientation, turns) }
            }
        }
        return nil
    }
}

private extension SIMD3 where Scalar == Float {
    var axisIndex: Int { abs(x) > 0.5 ? 0 : (abs(y) > 0.5 ? 1 : 2) }
    var isPositive: Bool { self[axisIndex] > 0 }
}

/// Welded triangles grouped into flat axis-aligned faces.
private struct Topology {
    struct Facet {
        let normal: SIMD3<Float>
        /// Signed plane offset: dot(normal, point).
        let coord: Float
        var triangles: [Int]
    }
    struct Circle {
        let centre: SIMD2<Float>
        let radius: Float
        let inradius: Float
        let area: Float
    }
    /// A straight inside corner between two perpendicular faces, along `axis` from `start` to `end`.
    struct Run {
        let n1: SIMD3<Float>, n2: SIMD3<Float>
        let c1: Float, c2: Float
        let axis: Int
        var start: Float, end: Float
        var length: Float { end - start }
        func coordinate(of n: SIMD3<Float>) -> Float { (n == n1 ? c1 : c2) * (n.isPositive ? 1 : -1) }
        func point(at u: Float) -> SIMD3<Float> {
            var p = n1 * c1 + n2 * c2
            p[axis] = u
            return p
        }
        /// The other face's normal, and that face, when one face has normal `n`.
        func pair(with n: SIMD3<Float>) -> (SIMD3<Float>, (normal: SIMD3<Float>, coord: Float))? {
            if n1 == n { return (n2, (n1, c1)) }
            if n2 == n { return (n1, (n2, c2)) }
            return nil
        }
    }

    let points: [SIMD3<Float>]
    let triangles: [[Int]]
    let normals: [SIMD3<Float>]
    let owner: [SIMD2<Int>: Int]
    let facetOf: [Int]
    let facets: [Facet]

    init(_ mesh: STLMesh) {
        var index: [SIMD3<Float>: Int] = [:], points: [SIMD3<Float>] = [], triangles: [[Int]] = []
        for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
            triangles.append((0..<3).map { j in
                let p = SIMD3(mesh.vertices[i+3*j], mesh.vertices[i+3*j+1], mesh.vertices[i+3*j+2])
                if let k = index[p] { return k }
                index[p] = points.count
                points.append(p)
                return points.count - 1
            })
        }
        let normals = triangles.map { t -> SIMD3<Float> in
            let c = simd_cross(points[t[1]] - points[t[0]], points[t[2]] - points[t[0]])
            let l = simd_length(c)
            return l > 0 ? c / l : .zero
        }
        var owner: [SIMD2<Int>: Int] = [:]
        for (ti, t) in triangles.enumerated() { for j in 0..<3 { owner[SIMD2(t[j], t[(j+1)%3])] = ti } }
        func axis(_ n: SIMD3<Float>) -> SIMD3<Float>? {
            for k in 0..<3 where abs(n[k]) > 0.9999 { var a = SIMD3<Float>.zero; a[k] = n[k] > 0 ? 1 : -1; return a }
            return nil
        }
        var facetOf = Array(repeating: -1, count: triangles.count), facets: [Facet] = []
        func doubleArea(_ t: Int) -> Float { simd_length(simd_cross(points[triangles[t][1]] - points[triangles[t][0]], points[triangles[t][2]] - points[triangles[t][0]])) }
        // Seeded from the largest triangles; folded needle triangles on the same plane join by position, not by normal.
        for seed in triangles.indices.sorted(by: { doubleArea($0) > doubleArea($1) }) where facetOf[seed] < 0 {
            guard let n = axis(normals[seed]) else { continue }
            let c = simd_dot(n, points[triangles[seed][0]])
            var facet = Facet(normal: n, coord: c, triangles: [])
            facetOf[seed] = facets.count
            var stack = [seed]
            while let ti = stack.popLast() {
                facet.triangles.append(ti)
                let t = triangles[ti]
                for j in 0..<3 {
                    guard let other = owner[SIMD2(t[(j+1)%3], t[j])], facetOf[other] < 0,
                          triangles[other].allSatisfy({ abs(simd_dot(n, points[$0]) - c) < 1e-4 }) else { continue }
                    facetOf[other] = facets.count
                    stack.append(other)
                }
            }
            facets.append(facet)
        }
        self.points = points; self.triangles = triangles; self.normals = normals
        self.owner = owner; self.facetOf = facetOf; self.facets = facets
    }

    func area(_ facet: Facet) -> Float {
        facet.triangles.reduce(0) { sum, t in
            let p = triangles[t].map { points[$0] }
            return sum + simd_length(simd_cross(p[1] - p[0], p[2] - p[0])) / 2
        }
    }

    func extent(_ facet: Facet) -> (SIMD3<Float>, SIMD3<Float>) {
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude), high = -low
        for t in facet.triangles { for v in triangles[t] { low = simd_min(low, points[v]); high = simd_max(high, points[v]) } }
        return (low, high)
    }

    /// Boundary loops following triangle winding; nil when the boundary branches.
    func loops(_ facet: Facet) -> [[Int]]? {
        let members = Set(facet.triangles)
        var next: [Int: Int] = [:]
        for t in facet.triangles {
            let v = triangles[t]
            for j in 0..<3 {
                let a = v[j], b = v[(j+1)%3]
                if let other = owner[SIMD2(b, a)], members.contains(other) { continue }
                guard next[a] == nil else { return nil }
                next[a] = b
            }
        }
        var loops: [[Int]] = []
        while let start = next.keys.min() {
            var loop = [start], v = next.removeValue(forKey: start)!
            while v != start {
                loop.append(v)
                guard let following = next.removeValue(forKey: v) else { return nil }
                v = following
            }
            loops.append(loop)
        }
        return loops
    }

    private func planar(_ loop: [Int], normal: SIMD3<Float>) -> [SIMD2<Float>] {
        let k = normal.axisIndex, i = (k + 1) % 3, j = (k + 2) % 3
        return loop.map { SIMD2(points[$0][i], points[$0][j]) }
    }

    func signedArea(_ loop: [Int], normal: SIMD3<Float>) -> Float {
        let p = planar(loop, normal: normal)
        return p.indices.reduce(0) { $0 + (p[$1].x * p[($1+1)%p.count].y - p[($1+1)%p.count].x * p[$1].y) } / 2
    }

    /// A loop of at least 12 points within 3% of a common radius. Centre and radius are in the plane's two other axes.
    func circle(_ loop: [Int], normal: SIMD3<Float>) -> Circle? {
        guard loop.count >= 12 else { return nil }
        let p = planar(loop, normal: normal)
        var area: Float = 0, centre = SIMD2<Float>.zero
        for k in p.indices {
            let q = p[k], r = p[(k+1)%p.count], cross = q.x * r.y - r.x * q.y
            area += cross; centre += (q + r) * cross
        }
        guard abs(area) > 1e-6 else { return nil }
        area /= 2; centre /= 6 * area
        let radii = p.map { simd_distance($0, centre) }
        let mean = radii.reduce(0, +) / Float(radii.count)
        guard radii.allSatisfy({ abs($0 - mean) <= 0.03 * mean + 0.01 }) else { return nil }
        let inradius = p.indices.map { k -> Float in
            let a = p[k], b = p[(k+1)%p.count], ab = b - a
            let t = simd_clamp(simd_dot(centre - a, ab) / max(simd_length_squared(ab), 1e-12), 0, 1)
            return simd_distance(centre, a + ab * t)
        }.min() ?? mean
        return Circle(centre: centre, radius: mean, inradius: inradius, area: area)
    }

    /// Straight concave edges between perpendicular axis-aligned faces, merged into continuous runs of at least `minimumLength`.
    /// Concavity is sampled in the solid at each run's middle: needle triangles along an edge have no reliable side.
    func concaveRuns(in mesh: STLMesh, minimumLength: Float = 3) -> [Run] {
        struct Key: Hashable { let n1: SIMD3<Float>, n2: SIMD3<Float>, c1: Int32, c2: Int32 }
        func rank(_ n: SIMD3<Float>) -> Int { n.axisIndex * 2 + (n.isPositive ? 1 : 0) }
        var spans: [Key: (c1: Float, c2: Float, axis: Int, intervals: [(Float, Float)])] = [:]
        for (ti, t) in triangles.enumerated() where facetOf[ti] >= 0 {
            for j in 0..<3 {
                let a = t[j], b = t[(j+1)%3]
                guard let other = owner[SIMD2(b, a)], facetOf[other] >= 0, facetOf[ti] < facetOf[other] else { continue }
                var n1 = facets[facetOf[ti]].normal, n2 = facets[facetOf[other]].normal
                guard simd_dot(n1, n2) == 0 else { continue }
                if rank(n1) > rank(n2) { swap(&n1, &n2) }
                let axis = 3 - n1.axisIndex - n2.axisIndex
                let c1 = simd_dot(n1, points[a]), c2 = simd_dot(n2, points[a])
                let key = Key(n1: n1, n2: n2, c1: Int32((c1 * 1000).rounded()), c2: Int32((c2 * 1000).rounded()))
                let u = points[a][axis], v = points[b][axis]
                spans[key, default: (c1, c2, axis, [])].intervals.append((min(u, v), max(u, v)))
            }
        }
        var runs: [Run] = []
        for (key, span) in spans {
            var current: Run?
            for interval in span.intervals.sorted(by: { $0.0 < $1.0 }) {
                if var run = current, interval.0 <= run.end + 0.001 {
                    run.end = max(run.end, interval.1)
                    current = run
                } else {
                    if let current { runs.append(current) }
                    current = Run(n1: key.n1, n2: key.n2, c1: span.c1, c2: span.c2, axis: span.axis, start: interval.0, end: interval.1)
                }
            }
            if let current { runs.append(current) }
        }
        return runs.filter { run in
            guard run.length >= minimumLength else { return false }
            let p = run.point(at: (run.start + run.end) / 2), d: Float = 0.05
            return ReinforcementEngine.containsMaterial(p + (run.n1 - run.n2) * d, in: mesh)
                && ReinforcementEngine.containsMaterial(p + (run.n2 - run.n1) * d, in: mesh)
                && !ReinforcementEngine.containsMaterial(p + (run.n1 + run.n2) * d, in: mesh)
        }.sorted { ($0.axis, $0.start, $0.c1, $0.c2, rank($0.n1), rank($0.n2)) < ($1.axis, $1.start, $1.c1, $1.c2, rank($1.n1), rank($1.n2)) }
    }
}
