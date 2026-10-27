import XCTest
import CryptoKit
import Euclid
import simd
@testable import SlantStudio

final class TeardropTests: XCTestCase {
    private static func exported(_ mesh: Mesh) throws -> STLMesh { try ReinforcementEngine.stl(mesh.makeWatertight()) }
    /// A hole along X through the whole block, centred at (y, z).
    private static func holeX(radius: Double, y: Double, z: Double, slices: Int = 48, from: Double = -5, to: Double = 45) -> Mesh {
        Mesh.cylinder(radius: radius, height: to - from, slices: slices).rotated(by: Rotation(roll: .halfPi))
            .translated(by: Vector((from + to) / 2, y, z))
    }
    /// A hole along Y (Euclid's cylinder axis) from `y0` to `y1`, centred at (x, z).
    private static func holeY(radius: Double, x: Double, z: Double, y0: Double, y1: Double, slices: Int = 48) -> Mesh {
        Mesh.cylinder(radius: radius, height: y1 - y0, slices: slices).translated(by: Vector(x, (y0 + y1) / 2, z))
    }
    private static let block = Mesh.cube(center: Vector(20, 15, 10), size: Vector(40, 30, 20))
    /// The same block for `r12HoledBlock`, whose exact holes need no Boolean (most of these tests' time). The Euclid
    /// fixtures stay where Euclid's own tessellation is what's tested.
    private static let blockSize = SIMD3<Float>(40, 30, 20)

    /// 40 × 30 × 20 mm block: a ⌀5 mm X through hole at y 8, z 8, and a ⌀6 mm Y blind hole from the +Y face to y 14,
    /// at x 28, z 12.
    static func twoHoleBlock() throws -> STLMesh {
        if let cached = cachedTwoHoleBlock { return cached }
        let mesh = try exported(block.subtracting(holeX(radius: 2.5, y: 8, z: 8)).subtracting(holeY(radius: 3, x: 28, z: 12, y0: 14, y1: 35)))
        cachedTwoHoleBlock = mesh
        return mesh
    }
    /// Built once per process: Euclid's Boolean is most of these tests' time. Tests in a class run one at a time.
    nonisolated(unsafe) private static var cachedTwoHoleBlock: STLMesh?

    func testFindsXThroughAndYBlindHolesWithTheirCentres() throws {
        let source = try Self.twoHoleBlock()
        let found = try teardropCandidates(in: source)
        XCTAssertEqual(found.count, 2, "\(found)")
        let x = try XCTUnwrap(found.first { abs($0.axis.x) > 0.99 }), y = try XCTUnwrap(found.first { abs($0.axis.y) > 0.99 })
        XCTAssertTrue(x.eligible, "\(String(describing: x.skipped))")
        XCTAssertTrue(y.eligible, "\(String(describing: y.skipped))")
        // The X hole's centre is in Y and Z; the Y hole's in X and Z (not swapped).
        XCTAssertEqual(x.centre.y, 8, accuracy: 0.01)
        XCTAssertEqual(x.centre.z, 8, accuracy: 0.01)
        XCTAssertEqual(x.centre.x, 20, accuracy: 0.01)
        XCTAssertEqual(y.centre.x, 28, accuracy: 0.01)
        XCTAssertEqual(y.centre.z, 12, accuracy: 0.01)
        XCTAssertEqual(y.centre.y, 22, accuracy: 0.01)
        XCTAssertEqual(x.axis, SIMD3(1, 0, 0))
        XCTAssertEqual(y.axis, SIMD3(0, 1, 0))
        XCTAssertEqual(x.diameterMM, 5, accuracy: 0.05)
        XCTAssertEqual(y.diameterMM, 6, accuracy: 0.05)
        XCTAssertTrue(x.through)
        XCTAssertFalse(y.through)
        XCTAssertEqual(x.startMM, 0, accuracy: 0.001)
        XCTAssertEqual(x.endMM, 40, accuracy: 0.001)
        XCTAssertEqual(y.startMM, 14, accuracy: 0.001)
        XCTAssertEqual(y.endMM, 30, accuracy: 0.001)
        // Material above each new flat top: 20 − 10.5 and 20 − 15 mm, capped at the measuring reach.
        XCTAssertEqual(try XCTUnwrap(x.wallAboveMM), min(teardropWallReachMM, 9.5), accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(y.wallAboveMM), 5, accuracy: 0.05)
        XCTAssertTrue(teardropCandidateLabel(x, minimum: source.minimum).contains("through hole along X · centre Y 8.0, Z 8.0"),
                      teardropCandidateLabel(x, minimum: source.minimum))
        XCTAssertTrue(teardropCandidateLabel(y, minimum: source.minimum).contains("blind hole along Y · centre X 28.0, Z 12.0"),
                      teardropCandidateLabel(y, minimum: source.minimum))
    }

    func testCopyKeepsBottomAndHeightAndAddsOnlyShoulders() throws {
        let source = try Self.twoHoleBlock()
        let found = try teardropCandidates(in: source)
        let result = try teardropHolesCopy(of: source, candidates: found)
        let copy = try XCTUnwrap(result.mesh, "\(String(describing: result.problem))")
        XCTAssertEqual(result.record.count, 2)
        XCTAssertEqual(result.shellsBefore, 1)
        XCTAssertEqual(result.shellsAfter, 1)
        XCTAssertEqual(copy.minimum, source.minimum)
        XCTAssertEqual(copy.maximum, source.maximum)

        // The hole's lowest and highest points are unchanged: the ring's bottom vertices stay where they were, and the new
        // flat top's two corners sit exactly at the ring's old top.
        func ring(_ mesh: STLMesh, x: Float) -> [SIMD2<Float>] {
            stride(from: 0, to: mesh.vertices.count, by: 3).compactMap { i -> SIMD2<Float>? in
                guard mesh.vertices[i] == x else { return nil }
                let q = SIMD2(mesh.vertices[i + 1], mesh.vertices[i + 2])
                return abs(simd_distance(q, SIMD2(8, 8)) - 2.5) < 0.005 ? q : nil
            }
        }
        for x in [Float(0), 40] {
            let before = ring(source, x: x), after = Set(stride(from: 0, to: copy.vertices.count, by: 3).filter { copy.vertices[$0] == x }
                .map { SIMD2(copy.vertices[$0 + 1], copy.vertices[$0 + 2]) })
            let low = before.map(\.y).min()!, high = before.map(\.y).max()!
            XCTAssertEqual(low, 5.5, accuracy: 0.001)
            XCTAssertEqual(high, 10.5, accuracy: 0.001)
            // Every ring vertex below the shoulders is kept exactly.
            for q in before where q.y < 8 + 2.5 * 0.7 { XCTAssertTrue(after.contains(q), "\(q)") }
            // The flat top: two corners at exactly the old top, about 0.41 r either side of the centre.
            let corners = after.filter { $0.y == high && abs(abs($0.x - 8) - 2.5 * (Float(2).squareRoot() - 1)) < 0.02 }
            XCTAssertEqual(corners.count, 2, "\(after.filter { $0.y > 9 })")
            // Nothing new above the old top: the hole is no taller.
            let old = Set(stride(from: 0, to: source.vertices.count, by: 3).filter { source.vertices[$0] == x }
                .map { SIMD2(source.vertices[$0 + 1], source.vertices[$0 + 2]) })
            XCTAssertFalse(after.contains { $0.y > high && !old.contains($0) })
        }
        let health = try XCTUnwrap(analyzeMeshHealth(copy)), sourceHealth = try XCTUnwrap(analyzeMeshHealth(source))
        XCTAssertTrue(teardropInputUsable(health))
        XCTAssertLessThanOrEqual(health.degenerateTriangles, sourceHealth.degenerateTriangles)

        // The shoulder between the circle and the 45° face is now open; above the flat top, beside it and below the
        // hole stay solid.
        let r: Float = 2.5
        for x in [Float(1), 20, 39] {
            XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(x, 8 + 0.45 * r, 8 + 0.92 * r), in: source))
            XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(x, 8 + 0.45 * r, 8 + 0.92 * r), in: copy))
            XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(x, 8 - 0.45 * r, 8 + 0.92 * r), in: copy))
            XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(x, 8, 8 + r + 0.05), in: copy))
            XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(x, 8 + 0.55 * r, 8 + r - 0.02), in: copy))
            XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(x, 8, 8 - r - 0.05), in: copy))
        }
        // Blind hole: the shoulder opens down to the floor, and the floor stays where it was.
        XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(28 + 0.45 * 3, 14.2, 12 + 0.92 * 3), in: copy))
        XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(28 + 0.45 * 3, 13.8, 12 + 0.92 * 3), in: copy))
        XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(28, 13.8, 12), in: copy))

        // Removed volume: the truncated teardrop's extra area per mm times each hole's length. For a true circle the
        // extra area is r²(2√2 − 2 − π/4) (the 45° kite less the quarter circle, less the point above the flat top); a
        // 48-sided hole loses a little more, since its cap is slightly smaller than the circle's.
        let exact = { (r: Double) in r * r * (2 * 2.0.squareRoot() - 2 - Double.pi / 4) }
        let continuous = exact(2.5) * 40 + exact(3) * 16
        XCTAssertGreaterThan(result.record.removedVolumeMM3, continuous)
        XCTAssertLessThan(result.record.removedVolumeMM3, continuous * 1.08)
        // Every new face is no steeper than 45° from vertical: probes just outside the 45° line are still solid.
        for x in [Float(1), 39] {
            for u in [Float(0.75), 0.85, 0.95] {
                let s = Float(2).squareRoot() * 2.5 - u * 2.5 + 0.03
                XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(x, 8 + s, 8 + u * 2.5), in: copy), "\(u)")
            }
        }
    }

    func testFineHoleMatchesTheTruncatedTeardropArea() throws {
        let source = try r12HoledBlock(Self.blockSize, xHoles: [r12Hole(SIMD2(12, 9), radius: 4, segments: 96)], zHoles: [])
        let result = try teardropHolesCopy(of: source)
        XCTAssertEqual(result.record.count, 1, "\(result.record.skipped) \(String(describing: result.problem))")
        let perMM = result.record.removedVolumeMM3 / 40
        let expected = 16 * (2 * 2.0.squareRoot() - 2 - Double.pi / 4)
        XCTAssertEqual(perMM, expected, accuracy: expected * 0.03)
    }

    func testHoleAtAnAngleInPlanIsFound() throws {
        // A hole along X turned 30° about Z (Euclid's roll): horizontal, so still a teardrop hole.
        let hole = Mesh.cylinder(radius: 2.5, height: 80, slices: 48).rotated(by: Rotation(roll: .radians(Double.pi / 2 + Double.pi / 6)))
            .translated(by: Vector(20, 15, 9))
        let source = try Self.exported(Self.block.subtracting(hole))
        let found = try teardropCandidates(in: source)
        XCTAssertEqual(found.count, 1, "\(found)")
        let only = try XCTUnwrap(found.first)
        XCTAssertNil(only.skipped)
        XCTAssertEqual(abs(only.axis.z), 0, accuracy: 1e-5)
        XCTAssertEqual(abs(atan2(only.axis.y, only.axis.x)) * 180 / .pi, 30, accuracy: 0.1)
        XCTAssertTrue(teardropAxisLabel(only.axis).hasPrefix("at "), teardropAxisLabel(only.axis))
        let result = try teardropHolesCopy(of: source, candidates: found)
        let copy = try XCTUnwrap(result.mesh, "\(result.record.skipped) \(String(describing: result.problem))")
        // The shoulder above the axis at the block's middle opens; the top stays.
        let perpendicular = simd_normalize(SIMD3<Float>(-only.axis.y, only.axis.x, 0))
        XCTAssertFalse(ReinforcementEngine.containsMaterial(only.centre + perpendicular * (0.45 * 2.5) + SIMD3(0, 0, 0.92 * 2.5), in: copy))
        XCTAssertTrue(ReinforcementEngine.containsMaterial(only.centre + SIMD3(0, 0, 2.55), in: copy))

        // Tilted 10° from horizontal (Euclid's yaw turns about Y): found, but left alone.
        let tilted = Mesh.cylinder(radius: 2.5, height: 80, slices: 48).rotated(by: Rotation(roll: .halfPi))
            .rotated(by: Rotation(yaw: .radians(Double.pi / 18))).translated(by: Vector(20, 15, 9))
        let tiltedFound = try teardropCandidates(in: Self.exported(Self.block.subtracting(tilted)))
        XCTAssertEqual(tiltedFound.map(\.skipped), [.tilted])
    }

    func testSmallHolesThinRoofsVerticalHolesAndPlainBlocks() throws {
        let source = try r12HoledBlock(Self.blockSize, xHoles: [r12Hole(SIMD2(6, 6), radius: 1, segments: 48),
                                                                r12Hole(SIMD2(20, 16.8), radius: 2.5, segments: 48)],
                                       zHoles: [r12Hole(SIMD2(10, 26), radius: 2.5, segments: 48)])
        let found = try teardropCandidates(in: source)
        XCTAssertEqual(found.count, 2, "Vertical holes aren't listed: \(found)")
        let skipped = Dictionary(uniqueKeysWithValues: found.map { (Int($0.diameterMM.rounded()), $0.skipped) })
        XCTAssertEqual(skipped[2], .tooSmall)
        XCTAssertEqual(skipped[5], .thinRoof)
        XCTAssertTrue(TeardropSkipReason.thinRoof.message.contains("1 mm"))
        let result = try teardropHolesCopy(of: source)
        XCTAssertNil(result.mesh)
        XCTAssertEqual(result.problem, .noHolesChosen)
        XCTAssertEqual(Set(result.record.skipped.map(\.reason)), [.tooSmall, .thinRoof])
        XCTAssertTrue(result.record.skipped.allSatisfy { teardropSkipNote($0).hasPrefix("⌀") })

        let plain = try r12HoledBlock(Self.blockSize, xHoles: [], zHoles: [])
        XCTAssertTrue(try teardropCandidates(in: plain).isEmpty)
        // A horizontal pin isn't a hole.
        let pin = try Self.exported(Self.block.union(Self.holeX(radius: 2.5, y: 15, z: 10, from: 39, to: 50)))
        XCTAssertTrue(try teardropCandidates(in: pin).isEmpty)
    }

    func testHolesSharingFacesThinSideWallsAndKeepClearRegions() throws {
        // Three holes through the same two faces. The third is 0.9 mm from the +Y side, but the shoulders sit inside the
        // circle's own width, so that wall isn't thinned and the hole can still take a teardrop.
        let source = try r12HoledBlock(Self.blockSize, xHoles: [Float(7), 16, 26.6].map { r12Hole(SIMD2($0, 8), radius: 2.5, segments: 48) },
                                       zHoles: [])
        let found = try teardropCandidates(in: source)
        XCTAssertEqual(found.count, 3, "\(found)")
        XCTAssertEqual(found.filter(\.eligible).count, 3, "\(found.map(\.skipped))")
        let result = try teardropHolesCopy(of: source, candidates: found)
        let copy = try XCTUnwrap(result.mesh, "\(String(describing: result.problem))")
        XCTAssertEqual(result.record.count, 3)
        XCTAssertEqual(result.record.skipped.map(\.reason), [])
        for y in [Float(7), 16, 26.6] {
            XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(20, y + 0.45 * 2.5, 8 + 0.92 * 2.5), in: copy))
        }
        XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(20, 29.5, 8), in: copy))

        // Reinforce's preview refuses a ticked hole whose new shoulders enter a keep-clear region.
        let first = try XCTUnwrap(found.first { $0.centre.y < 10 })
        let region = ReinforcementBox(offset: SIMD3(10, 7, 9.5), size: SIMD3(2, 2, 2))
        XCTAssertThrowsError(try ReinforcementEngine.teardropHolesPreview(source, holes: [first], protectedRegions: [region])) {
            XCTAssertTrue($0.localizedDescription.contains("keep-clear"), $0.localizedDescription)
        }
        let preview = try ReinforcementEngine.teardropHolesPreview(source, holes: [first], protectedRegions: [])
        XCTAssertEqual(preview.teardrops?.count, 1)
        XCTAssertEqual(preview.shellsAfter, preview.shellsBefore)
        XCTAssertNotNil(preview.proposedSection)
    }

    func testOnlyChosenHolesChangeAndStaleChoicesAreIgnored() throws {
        let source = try Self.twoHoleBlock()
        let found = try teardropCandidates(in: source)
        let x = try XCTUnwrap(found.first { abs($0.axis.x) > 0.99 })
        let result = try teardropHolesCopy(of: source, candidates: [x])
        XCTAssertEqual(result.record.count, 1)
        XCTAssertEqual(result.record.holes.first?.axis, "X")
        let copy = try XCTUnwrap(result.mesh)
        // The Y hole is untouched: still found, still round.
        let again = try teardropCandidates(in: copy)
        XCTAssertTrue(again.contains { abs($0.axis.y) > 0.99 && $0.eligible })
        // The reshaped X hole is no longer round, so it isn't offered twice.
        XCTAssertFalse(again.contains { abs($0.axis.x) > 0.99 && $0.eligible })
        // A key from another model matches nothing.
        let stale = TeardropHoleKey(centre: SIMD3(1, 2, 3), heading: 0, diameter: 500)
        XCTAssertEqual(try teardropHolesCopy(of: source, keys: [stale]).problem, .noHolesChosen)
        XCTAssertThrowsError(try teardropHolesCopy(of: source, isCancelled: { true })) { XCTAssertEqual($0 as? TeardropError, .stopped) }
    }

    func testRecordDecodesLeniently() throws {
        let record = TeardropHolesRecord(holes: [TeardropHoleRecord(diameterMM: 5, lengthMM: 40, through: true, axis: "X", centreMM: [20, 8, 8], wallAboveMM: 9.5)],
                                         skipped: [TeardropSkipRecord(reason: .tooSmall, diameterMM: 2)], removedVolumeMM3: 12)
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(TeardropHolesRecord.self, from: data), record)
        let damaged = #"{"holes":[{"diameterMM":"x"},{"diameterMM":5,"lengthMM":40,"through":true,"axis":"X","centreMM":[1,2,3]}],"skipped":[{"reason":"someday"}]}"#
        let read = try JSONDecoder().decode(TeardropHolesRecord.self, from: Data(damaged.utf8))
        XCTAssertEqual(read.count, 1)
        XCTAssertTrue(read.skipped.isEmpty)
        XCTAssertEqual(read.removedVolumeMM3, 0)
        XCTAssertEqual(try JSONDecoder().decode(TeardropHolesRecord.self, from: Data("[]".utf8)).count, 0)
        XCTAssertTrue(teardropHolesSummary(record).contains("1 hole (⌀5.0 mm)"), teardropHolesSummary(record))
        // A reinforcement record saved before teardrop holes still reads.
        let old = ReinforcementRecord(sourceID: UUID(), settings: ReinforcementSettings(kind: .teardrop), addedVolumeMM3: 0, removedVolumeMM3: 1, created: Date())
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "teardropHoles")
        XCTAssertNil(try JSONDecoder().decode(ReinforcementRecord.self, from: JSONSerialization.data(withJSONObject: json)).teardropHoles)
    }

    func testReviewNoteNamesTheAction() throws {
        XCTAssertNil(teardropReviewNote(eligibleCount: 0))
        let note = try XCTUnwrap(teardropReviewNote(eligibleCount: 2))
        XCTAssertTrue(note.contains("2 horizontal round holes"))
        XCTAssertTrue(note.contains("Find Horizontal Holes"))
        for word in ["strong", "safe", "%"] { XCTAssertFalse(note.lowercased().contains(word), word) }
    }

    // MARK: Determinism

    static func geometryDigest() throws -> String {
        let source = try twoHoleBlock()
        let data = try XCTUnwrap(teardropHolesCopy(of: source).data)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func testSameBytesEveryRun() throws {
        XCTAssertEqual(try Self.geometryDigest(), try Self.geometryDigest())
    }

    /// Run only as a subprocess by `PrintPreparationFixesTests.testPipelineBytesMatchAcrossHashSeeds`: writes the copy's
    /// hash to the named file.
    func testHashSeedProbeWritesTeardropHash() throws {
        guard let out = ProcessInfo.processInfo.environment["SLANT_TEARDROP_HASH_OUT"] else { return }
        try Self.geometryDigest().write(toFile: out, atomically: true, encoding: .utf8)
    }

    // Compared across hash seeds by `PrintPreparationFixesTests.testPipelineBytesMatchAcrossHashSeeds`, with the other
    // geometry probes, so the bundle is launched once per seed.
}
