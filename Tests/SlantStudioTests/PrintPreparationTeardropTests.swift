import XCTest
import CryptoKit
import Euclid
import simd
@testable import SlantStudio

/// A round hole for `r12HoledBlock`: its outline anticlockwise round `centre`, in the face it opens through.
struct R12Hole {
    let centre: SIMD2<Float>
    let outline: [SIMD2<Float>]
}

func r12Hole(_ centre: SIMD2<Float>, radius: Float, segments: Int) -> R12Hole {
    R12Hole(centre: centre, outline: r11Circle(centre, radius: radius, segments: segments))
}

/// A block from the origin to `size` with straight round holes right through it: along X (centres in Y and Z) and up
/// through the bed (centres in X and Y). Built face by face, so every face is one clean outline and no Boolean is needed
/// (a Boolean would split the faces along the holes' planes, and is most of a test's time). The holes mustn't meet.
func r12HoledBlock(_ size: SIMD3<Float>, xHoles: [R12Hole], zHoles: [R12Hole]) throws -> STLMesh {
    var corners: [SIMD3<Float>] = []
    func add(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, facing: SIMD3<Float>) {
        corners += simd_dot(simd_cross(b - a, c - a), facing) >= 0 ? [a, b, c] : [a, c, b]
    }
    /// A flat face: a rectangle with holes, mapped into 3D, its triangles turned to face `facing`.
    func face(_ high: SIMD2<Float>, holes: [R12Hole], facing: SIMD3<Float>, _ map: (SIMD2<Float>) -> SIMD3<Float>) throws {
        let flat = r11Rectangle(.zero, high) + holes.flatMap(\.outline)
        var loops = [Array(0..<4)]
        var start = 4
        for hole in holes {
            loops.append(Array((start..<(start + hole.outline.count)).reversed()))
            start += hole.outline.count
        }
        for t in try triangulatePlanarRegion(points: flat.map { SIMD2<Double>(Double($0.x), Double($0.y)) }, loops: loops) {
            add(map(flat[Int(t.x)]), map(flat[Int(t.y)]), map(flat[Int(t.z)]), facing: facing)
        }
    }
    try face(SIMD2(size.x, size.y), holes: zHoles, facing: SIMD3(0, 0, -1)) { SIMD3($0.x, $0.y, 0) }
    try face(SIMD2(size.x, size.y), holes: zHoles, facing: SIMD3(0, 0, 1)) { SIMD3($0.x, $0.y, size.z) }
    try face(SIMD2(size.x, size.z), holes: [], facing: SIMD3(0, -1, 0)) { SIMD3($0.x, 0, $0.y) }
    try face(SIMD2(size.x, size.z), holes: [], facing: SIMD3(0, 1, 0)) { SIMD3($0.x, size.y, $0.y) }
    try face(SIMD2(size.y, size.z), holes: xHoles, facing: SIMD3(-1, 0, 0)) { SIMD3(0, $0.x, $0.y) }
    try face(SIMD2(size.y, size.z), holes: xHoles, facing: SIMD3(1, 0, 0)) { SIMD3(size.x, $0.x, $0.y) }
    // Hole walls, facing their axes.
    for hole in zHoles {
        let ring = hole.outline
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], mid = (a + b) / 2
            let facing = SIMD3<Float>(hole.centre.x - mid.x, hole.centre.y - mid.y, 0)
            let p = [SIMD3(a.x, a.y, 0), SIMD3(b.x, b.y, 0), SIMD3(b.x, b.y, size.z), SIMD3(a.x, a.y, size.z)]
            add(p[0], p[1], p[2], facing: facing); add(p[0], p[2], p[3], facing: facing)
        }
    }
    for hole in xHoles {
        let ring = hole.outline
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count], mid = (a + b) / 2
            let facing = SIMD3<Float>(0, hole.centre.x - mid.x, hole.centre.y - mid.y)
            let p = [SIMD3(0, a.x, a.y), SIMD3(0, b.x, b.y), SIMD3(size.x, b.x, b.y), SIMD3(size.x, a.x, a.y)]
            add(p[0], p[1], p[2], facing: facing); add(p[0], p[2], p[3], facing: facing)
        }
    }
    return try STLMesh.validated(corners.flatMap { [$0.x, $0.y, $0.z] })
}

/// Round 12 integration: Add Teardrop Holes… on the print-ready copy, side holes in fit coupons, and the rules that
/// keep coupon copies out of automatic preparation.
final class PrintPreparationTeardropTests: XCTestCase {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)
    static let input = PrintPreparationInput(sourceID: UUID(uuidString: "22222222-3333-4444-5555-666666666666")!, sourceName: "Block",
                                             savedIntent: PartIntent(purpose: .enclosure), internalWalls: true, automatic: false)

    /// 40 × 30 × 16 mm block with a ⌀5 mm hole along X at y 10, z 8 (through) and a ⌀4 mm hole up through it from the
    /// bed at x 28, y 20 (a hole ring).
    static func block(sideHole: Bool = true) throws -> STLMesh {
        if sideHole, let cachedBlock { return cachedBlock }
        let mesh = try r12HoledBlock(SIMD3(40, 30, 16), xHoles: sideHole ? [r12Hole(SIMD2(10, 8), radius: 2.5, segments: 48)] : [],
                                     zHoles: [r12Hole(SIMD2(28, 20), radius: 2, segments: 32)])
        if sideHole { cachedBlock = mesh }
        return mesh
    }
    nonisolated(unsafe) private static var cachedBlock: STLMesh?
    nonisolated(unsafe) private static var cachedFirst: PrintPreparationResult?

    /// The ordinary print-ready copy of the block, without the walls and chamfer the follow-up doesn't read (its placement
    /// and notes are the same), to keep the test quick.
    static func firstCopy() throws -> PrintPreparationResult {
        if let cachedFirst { return cachedFirst }
        var quick = input
        quick.internalWalls = false
        quick.bottomChamfer = false
        let result = try preparePrintReadyCopy(try block(), input: quick, now: date)
        cachedFirst = result
        return result
    }

    /// Add Teardrop Holes… with every offered hole ticked.
    static func teardropCopy() throws -> (offer: PrintPreparationTeardropOffer, result: PrintPreparationResult) {
        let first = try firstCopy()
        let offer = try printPreparationTeardropOffer(original: try block(), record: first.record)
        var follow = input
        follow.teardrops = printPreparationTeardropChoice(offer.eligible.map(\.key), record: first.record)
        return (offer, try preparePrintReadyCopy(try block(), input: follow, now: date))
    }

    static func followUpDigest() throws -> String {
        SHA256.hash(data: try XCTUnwrap(teardropCopy().result.data)).map { String(format: "%02x", $0) }.joined()
    }

    /// Distance from `point` to a truncated teardrop (45° shoulders up to a flat top at the circle's top) round `hole`,
    /// measured across the hole's axis; nil when the point lies beyond the hole's ends.
    private static func distanceToTeardrop(_ point: SIMD3<Float>, hole: TeardropCandidate) -> Float? {
        let along = simd_dot(point, hole.axis)
        guard along >= hole.startMM - 0.01, along <= hole.endMM + 0.01 else { return nil }
        let up = SIMD3<Float>(0, 0, 1)
        let side = simd_normalize(simd_cross(up, hole.axis))
        let offset = point - hole.centre
        let q = SIMD2(simd_dot(offset, side), offset.z)
        let r = hole.radiusMM, half = r * (Float(2).squareRoot() - 1)
        // Well clear of the shape, which lies within 1.09 r of the axis: not worth measuring exactly.
        if simd_length(q) > 1.09 * r + 6 { return .greatestFiniteMagnitude }
        var boundary: [SIMD2<Float>] = []
        for step in 0..<3600 {
            let angle = Float(step) / 10 * .pi / 180
            let p = SIMD2(cos(angle), sin(angle)) * r
            // The circle, except its top between the two 45° tangent points.
            if !(angle > .pi / 4 && angle < 3 * .pi / 4) { boundary.append(p) }
        }
        let tangent = SIMD2<Float>(r / Float(2).squareRoot(), r / Float(2).squareRoot())
        for i in 0...400 {
            let t = Float(i) / 400
            boundary.append(tangent + (SIMD2(half, r) - tangent) * t)
            boundary.append(SIMD2(-tangent.x, tangent.y) + (SIMD2(-half, r) - SIMD2(-tangent.x, tangent.y)) * t)
            boundary.append(SIMD2(-half + 2 * half * t, r))
        }
        return boundary.map { simd_distance($0, q) }.min()
    }

    /// Run only as a subprocess by `PrintPreparationFixesTests.testPipelineBytesMatchAcrossHashSeeds`, which compares it
    /// across hash seeds with this process's own `followUpDigest()`.
    func testHashSeedProbeWritesFollowUpHash() throws {
        guard let out = ProcessInfo.processInfo.environment["SLANT_R12_FOLLOWUP_HASH_OUT"] else { return }
        try Self.followUpDigest().write(toFile: out, atomically: true, encoding: .utf8)
    }

    // MARK: The follow-up

    func testTeardropCopyKeepsChamferWallsAndRingAndWallsClearTheNewShoulders() throws {
        let first = try Self.firstCopy()
        XCTAssertNil(first.record.teardropHoles)
        XCTAssertFalse(first.record.steps.contains { $0.step == .teardrops }, "Never added automatically")
        XCTAssertFalse(first.record.notes.contains { $0.contains("teardrop") }, "The copy's panel offers it instead: \(first.record.notes)")

        let (offer, result) = try Self.teardropCopy()
        XCTAssertEqual(offer.eligible.count, 1, "\(offer.holes)")
        let hole = try XCTUnwrap(offer.eligible.first)
        XCTAssertEqual(hole.diameterMM, 5, accuracy: 0.05)
        XCTAssertTrue(hole.through)

        let record = result.record
        let mesh = try XCTUnwrap(result.mesh, "\(String(describing: result.blocked)) \(record.steps)")
        XCTAssertEqual(record.orientation, first.record.orientation, "Placed as the earlier copy")
        XCTAssertEqual(record.teardropHoles?.count, 1)
        let applied = record.appliedSteps.map(\.step)
        XCTAssertEqual(applied.filter { [.teardrops, .bottomChamfer, .internalWalls].contains($0) }, [.teardrops, .bottomChamfer, .internalWalls], "\(record.steps)")
        XCTAssertEqual(record.internalWalls?.holeRings, 1, "The ring round the bed-face hole stays: \(record.steps.map(\.lines))")
        XCTAssertTrue(printPreparationAppliedLines(record).contains("Teardrop holes: a teardrop roof on 1 horizontal hole."))
        XCTAssertTrue(printPreparationCaption(record).contains("1 teardrop hole"), printPreparationCaption(record))
        XCTAssertTrue(printPreparationCautions(record).contains(printPreparationTeardropCaution))

        let health = try XCTUnwrap(analyzeMeshHealth(mesh))
        XCTAssertTrue(meshHealthIsSound(health))
        XCTAssertEqual(health.shells, 1)
        // The hole now has its roof: the finder no longer lists it as one that could take one.
        let after = try teardropCandidates(in: mesh)
        XCTAssertFalse(after.contains { $0.eligible && abs($0.centre.z - hole.centre.z) < 0.1 && abs($0.diameterMM - 5) < 0.1 }, "\(after)")
        XCTAssertGreaterThan(record.teardropHoles?.removedVolumeMM3 ?? 0, 0)

        // Every vertex the walls made (inside the part, off the bed face and off the teardrop itself) keeps the walls'
        // clearance from the new shoulders, because the walls were planned after them.
        let bounds = meshCoordinateBounds(mesh.vertices)
        var nearest = Float.greatestFiniteMagnitude
        for i in stride(from: 0, to: mesh.vertices.count, by: 3) {
            let v = SIMD3(mesh.vertices[i], mesh.vertices[i + 1], mesh.vertices[i + 2])
            let onOutside = (0..<3).contains { abs(v[$0] - bounds.low[$0]) < 1e-3 || abs(v[$0] - bounds.high[$0]) < 1e-3 }
            guard !onOutside, let d = Self.distanceToTeardrop(v, hole: hole), d > 0.05 else { continue }
            nearest = min(nearest, d)
        }
        XCTAssertGreaterThanOrEqual(nearest, internalWallsClearanceMM - 0.05)
        XCTAssertLessThan(nearest, internalWallsClearanceMM + 3, "Some wall lies near the hole, so the check means something")
    }

    func testTeardropStepTimeLimitSavesNothing() throws {
        let first = try Self.firstCopy()
        var follow = Self.input
        follow.teardrops = printPreparationTeardropChoice([TeardropHoleKey(centre: .zero, heading: 0, diameter: 500)], record: first.record)
        follow.teardropTimeLimit = -1
        XCTAssertThrowsError(try preparePrintReadyCopy(try Self.block(), input: follow, now: Self.date)) {
            XCTAssertEqual($0 as? PrintPreparationError, .teardropsTookTooLong)
        }
        XCTAssertTrue(PrintPreparationError.teardropsTookTooLong.isTimeLimit)
        XCTAssertFalse(PrintPreparationError.stopped.isTimeLimit)
    }

    func testNotOfferedWithoutEligibleHoles() throws {
        // Only the bed-face hole: nothing horizontal to offer.
        let plain = try Self.block(sideHole: false)
        let record = PrintPreparationRecord(sourceID: UUID(), sourceName: "P", created: Self.date, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: [])
        let offer = try printPreparationTeardropOffer(original: plain, record: record)
        XCTAssertTrue(offer.eligible.isEmpty, "\(offer.holes)")
        // A chosen hole that isn't there any more saves nothing.
        var follow = Self.input
        follow.internalWalls = false
        follow.teardrops = printPreparationTeardropChoice([TeardropHoleKey(centre: SIMD3(2000, 1000, 800), heading: 0, diameter: 500)], record: record)
        let result = try preparePrintReadyCopy(plain, input: follow, now: Self.date)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.blocked, printPreparationTeardropsNoneFound)
    }

    func testOfferRulesAndChoice() {
        let original = LocalModel(name: "Owl", filePath: "/tmp/owl.stl")
        let record = PrintPreparationRecord(sourceID: original.id, sourceName: "Owl", created: Self.date,
                                            steps: [PrintPreparationStepRecord(step: .orientation, applied: true, lines: ["On its side."])],
                                            orientation: .xUp, treatments: [], internalWalls: nil, notes: [])
        let copy = LocalModel(name: "Owl (print-ready)", filePath: "/tmp/owl-pr.stl", printPreparation: record)
        XCTAssertTrue(printPreparationTeardropOfferApplies(copy, library: [original, copy]))
        XCTAssertFalse(printPreparationTeardropOfferApplies(copy, library: [copy]), "Needs the original")
        XCTAssertFalse(printPreparationTeardropOfferApplies(original, library: [original, copy]), "Only on a print-ready copy")
        var withHoles = record
        withHoles.teardropHoles = TeardropHolesRecord(holes: [TeardropHoleRecord(diameterMM: 5, lengthMM: 40, through: true, axis: "X", centreMM: [20, 8, 8])],
                                                      skipped: [], removedVolumeMM3: 3)
        XCTAssertFalse(printPreparationTeardropOfferApplies(LocalModel(name: "T", filePath: "/tmp/t.stl", printPreparation: withHoles), library: [original]))
        let filled = LocalModel(name: "F", filePath: "/tmp/f.stl", printPreparation: printPreparationRecordAfterFill(record, filled: 1), filledPockets: true)
        XCTAssertFalse(printPreparationTeardropOfferApplies(filled, library: [original, filled]), "A re-preparation would undo the fill")
        XCTAssertFalse(printPreparationTeardropOfferApplies(LocalModel(name: "O", filePath: "/tmp/o.obj", printPreparation: record), library: [original]))

        let a = TeardropHoleKey(centre: SIMD3(100, 200, 300), heading: 0, diameter: 500)
        let b = TeardropHoleKey(centre: SIMD3(50, 200, 300), heading: 900, diameter: 600)
        let choice = printPreparationTeardropChoice([a, b, a], record: record)
        XCTAssertEqual(choice.holes, [b, a], "Each key once, in a fixed order")
        XCTAssertEqual(choice.orientation, .xUp)
        XCTAssertEqual(choice.placementStep, record.steps[0])
        XCTAssertEqual(printReadyTeardropCopyName("Owl.stl"), "Owl (print-ready, teardrop holes)")
        XCTAssertEqual(printReadyTeardropCopyName(" "), "Model (print-ready, teardrop holes)")
        XCTAssertTrue(modelIsEditedCopy(LocalModel(name: "T", filePath: "/tmp/t.stl", printPreparation: withHoles)), "Counts as an edited copy for the licence advisory")
    }

    func testMatchingTicksWithinTheTolerance() {
        func hole(_ key: TeardropHoleKey, eligible: Bool = true) -> TeardropCandidate {
            TeardropCandidate(key: key, centre: .zero, axis: SIMD3(1, 0, 0), radiusMM: 2.5, startMM: 0, endMM: 10, through: true,
                              wallAboveMM: 5, skipped: eligible ? nil : .thinRoof, changeLow: .zero, changeHigh: .zero)
        }
        let ticked = TeardropHoleKey(centre: SIMD3(2000, 1000, 800), heading: 0, diameter: 500)
        let moved = TeardropHoleKey(centre: SIMD3(2003, 1000, 799), heading: 0, diameter: 501)
        let far = TeardropHoleKey(centre: SIMD3(2010, 1000, 800), heading: 0, diameter: 500)
        XCTAssertEqual(printPreparationTeardropMatches(chosen: [ticked], found: [hole(ticked)]).keys, [ticked])
        XCTAssertEqual(printPreparationTeardropMatches(chosen: [ticked], found: [hole(far), hole(moved)]).keys, [moved])
        let none = printPreparationTeardropMatches(chosen: [ticked], found: [hole(far), hole(moved, eligible: false)])
        XCTAssertTrue(none.keys.isEmpty)
        XCTAssertEqual(none.unmatched, 1)
        // One found hole answers one ticked key.
        let twice = printPreparationTeardropMatches(chosen: [ticked, moved], found: [hole(moved)])
        XCTAssertEqual(twice.keys, [moved])
        XCTAssertEqual(twice.unmatched, 1)
        XCTAssertNil(printPreparationTeardropsMissingLine(0))
        XCTAssertTrue(printPreparationTeardropsMissingLine(2)?.contains("2 ticked holes") == true)
    }

    func testRecordWithTeardropsDecodesLeniently() throws {
        var record = PrintPreparationRecord(sourceID: UUID(), sourceName: "P", created: Self.date, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: ["n"])
        record.teardropHoles = TeardropHolesRecord(holes: [TeardropHoleRecord(diameterMM: 5, lengthMM: 40, through: true, axis: "X", centreMM: [20, 8, 8])],
                                                   skipped: [TeardropSkipRecord(reason: .tooSmall, diameterMM: 2)], removedVolumeMM3: 3)
        record.steps = [PrintPreparationStepRecord(step: .teardrops, applied: true, lines: ["Teardrop roofs on 1 hole."])]
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(PrintPreparationRecord.self, from: data), record)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["teardropHoles"] = "damaged"
        let damaged = try JSONDecoder().decode(PrintPreparationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(damaged.teardropHoles)
        XCTAssertEqual(damaged.notes, ["n"], "Only the damaged field is dropped")
        json["teardropHoles"] = ["holes": [], "skipped": [], "removedVolumeMM3": 0]
        XCTAssertNil(try JSONDecoder().decode(PrintPreparationRecord.self, from: JSONSerialization.data(withJSONObject: json)).teardropHoles,
                     "A record that reshaped nothing reads as none")
        json.removeValue(forKey: "teardropHoles")
        XCTAssertNil(try JSONDecoder().decode(PrintPreparationRecord.self, from: JSONSerialization.data(withJSONObject: json)).teardropHoles)
        // The planned steps never include teardrops.
        XCTAssertFalse(PrintPreparationStep.planned.contains(.teardrops))
        XCTAssertEqual(PrintPreparationStep.allCases.firstIndex(of: .teardrops), 3)
    }

    func testWordingPromisesNothing() {
        for text in [printPreparationTeardropConfirmText, printPreparationTeardropCaution, printPreparationTeardropOfferLine(count: 1),
                     printPreparationTeardropOfferLine(count: 3), printPreparationTeardropsTookTooLong, printPreparationTeardropsNoneFound] {
            for word in ["strong", "safe", "guarantee", "will fit", "%"] {
                XCTAssertFalse(text.lowercased().contains(word), "\(word) in \(text)")
            }
        }
        XCTAssertTrue(printPreparationTeardropConfirmText.contains("45°"))
        XCTAssertTrue(printPreparationTeardropConfirmText.contains("bottom and height are unchanged"))
        XCTAssertTrue(printPreparationTeardropConfirmText.contains("looser"))
        XCTAssertTrue(printPreparationTeardropOfferLine(count: 1).hasPrefix("1 horizontal round hole could"))
        XCTAssertTrue(printPreparationSettingsFooter.contains("never adds fillets, thickens walls or gives holes teardrop roofs"))
    }

    // MARK: Fit coupons

    func testCouponCopiesAreNeverPreparedAutomatically() {
        // Make Fit Coupon saves through `saveMeshFitCopy` with `.studioToolCopy`.
        XCTAssertEqual(printPreparationSkipReason(origin: .studioToolCopy, fileExtension: "stl", sourceDetails: nil,
                                                  settings: PrintPreparationSettings(), alreadyHandled: false), .originNotPrepared)
        XCTAssertFalse(ModelImportOrigin.studioToolCopy.mayPrepareForPrinting)
        XCTAssertEqual(fitCouponCopyName("Bracket.stl"), "Bracket (fit coupon)")
    }

    func testSideHoleIsACouponFeatureAndItsCouponHoldsTheWholeHole() throws {
        let source = try Self.block()
        let features = try XCTUnwrap(fitCouponFeatures(in: source))
        XCTAssertEqual(features.map(\.kind), [.hole, .sideHole], "\(features.map(\.label))")
        let side = try XCTUnwrap(features.first { $0.kind == .sideHole })
        XCTAssertTrue(side.label.hasPrefix("5.0 mm side hole"), side.label)
        XCTAssertEqual(side.topZ, 10.5, accuracy: 0.05)
        XCTAssertEqual(side.sizeMM.x, 40, accuracy: 0.05)
        XCTAssertEqual(side.sizeMM.y, 5, accuracy: 0.05)
        XCTAssertTrue(fitCouponFeatureNote(side).contains("past its ends"), fitCouponFeatureNote(side))
        let region = fitCouponRegion(around: side, meshMinimum: source.minimum, meshMaximum: source.maximum)
        XCTAssertEqual(region.topZ, 12.5, accuracy: 0.05)
        let coupon = try fitCouponCopy(of: source, region: region)
        XCTAssertEqual(coupon.mesh.minimum.z, source.minimum.z)
        XCTAssertLessThan(coupon.sizeMM.z, 13)
        // The hole is still whole in the piece.
        let found = try teardropCandidates(in: coupon.mesh)
        XCTAssertTrue(found.contains { abs($0.diameterMM - 5) < 0.05 && $0.through && abs($0.lengthMM - 40) < 0.05 }, "\(found)")
    }
}
