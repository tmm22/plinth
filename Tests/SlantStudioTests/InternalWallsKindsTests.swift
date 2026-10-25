import XCTest
import CryptoKit
import Euclid
import simd
@testable import SlantStudio

/// Round 11: hole rings, pin slots, thin-section slots and the purpose-aware plan.
final class InternalWallsKindsTests: XCTestCase {
    private typealias Triangle = (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)

    private func exported(_ mesh: Mesh) throws -> STLMesh { try ReinforcementEngine.stl(mesh.makeWatertight()) }
    /// Euclid's exports can carry zero-area slivers; Repair removes them, as the automatic preparation does first.
    private func repaired(_ mesh: Mesh) throws -> STLMesh {
        let result = try repairMesh(exported(mesh))
        XCTAssertTrue(result.summary.isSound)
        return result.mesh
    }
    private func box(_ low: SIMD3<Double>, _ high: SIMD3<Double>) -> Mesh {
        let size = high - low, centre = (low + high) / 2
        return .cube(center: Vector(centre.x, centre.y, centre.z), size: Vector(size.x, size.y, size.z))
    }
    /// A vertical cylinder from `z0` to `z1`.
    private func cylinder(_ x: Double, _ y: Double, radius: Double, _ z0: Double, _ z1: Double, slices: Int = 32) -> Mesh {
        Mesh.cylinder(radius: radius, height: z1 - z0, slices: slices).rotated(by: Rotation(pitch: .halfPi))
            .translated(by: Vector(x, y, (z0 + z1) / 2))
    }
    private func options(_ plan: InternalWallsPlan) -> InternalWallsOptions {
        var options = InternalWallsOptions()
        options.plan = plan
        return options
    }
    private func triangles(_ mesh: STLMesh, keep: (Triangle) -> Bool = { _ in true }) -> [Triangle] {
        (0..<mesh.triangleCount).compactMap { t in
            let p = (0..<3).map { j in SIMD3(mesh.vertices[t * 9 + j * 3], mesh.vertices[t * 9 + j * 3 + 1], mesh.vertices[t * 9 + j * 3 + 2]) }
            let triangle = (p[0], p[1], p[2])
            return keep(triangle) ? triangle : nil
        }
    }
    private func isBed(_ triangle: Triangle, floor: Float) -> Bool {
        let n = simd_normalize(simd_cross(triangle.1 - triangle.0, triangle.2 - triangle.0))
        return max(triangle.0.z, triangle.1.z, triangle.2.z) <= floor + 0.0001 && n.z < -0.9999
    }
    private func nearest(_ p: SIMD3<Float>, _ list: [Triangle]) -> Float {
        list.map { internalWallsPointTriangleDistanceSquared(p, $0.0, $0.1, $0.2) }.min()!.squareRoot()
    }
    private func sound(_ result: InternalWallsResult, _ source: STLMesh, file: StaticString = #filePath, line: UInt = #line) throws -> STLMesh {
        let mesh = try XCTUnwrap(result.mesh, "Skipped: \(String(describing: result.skipped)) \(internalWallsSkipNotes(result))", file: file, line: line)
        let before = try XCTUnwrap(analyzeMeshHealth(source)), after = try XCTUnwrap(analyzeMeshHealth(mesh))
        XCTAssertTrue(meshHealthIsSound(after), file: file, line: line)
        XCTAssertEqual(after.shells, before.shells, file: file, line: line)
        XCTAssertEqual(mesh.minimum, source.minimum, file: file, line: line)
        XCTAssertEqual(mesh.maximum, source.maximum, file: file, line: line)
        XCTAssertEqual(before.signedVolume - after.signedVolume, result.removedVolumeMM3, accuracy: max(0.01, result.removedVolumeMM3 * 0.001), file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(result.data), mesh.binarySTL(), file: file, line: line)
        // Every slot opens through the bed face and is empty, with material over it.
        for slot in result.slots {
            XCTAssertEqual(slot.low.z, source.minimum.z, file: file, line: line)
            let centre = (slot.low + slot.high) / 2
            XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(centre.x, centre.y, slot.low.z + 0.05), in: mesh), file: file, line: line)
            XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(centre.x, centre.y, slot.high.z + 0.05), in: mesh), file: file, line: line)
        }
        return mesh
    }

    // MARK: Meshes

    private func holedBlock() throws -> STLMesh {
        try repaired(box(SIMD3(0, 0, 0), SIMD3(40, 40, 20)).subtracting(cylinder(20, 20, radius: 3, -10, 30)))
    }
    private func pinOnBase() throws -> STLMesh {
        try repaired(box(SIMD3(0, 0, 0), SIMD3(30, 30, 5)).union(cylinder(15, 15, radius: 3, 5, 17)))
    }
    private func plate(thickness: Double) throws -> STLMesh {
        try exported(box(SIMD3(0, 0, 0), SIMD3(40, thickness, 20)))
    }
    /// A base with a through-hole, a pin and a thin wall on top: one of every kind.
    private func composite() throws -> STLMesh {
        let base = box(SIMD3(0, 0, 0), SIMD3(60, 40, 8))
        let wall = box(SIMD3(25, 30, 8), SIMD3(58, 33, 20))
        let pin = cylinder(45, 12, radius: 3, 8, 18)
        return try repaired(base.union(wall).union(pin).subtracting(cylinder(12, 20, radius: 2.5, -5, 15)))
    }

    // MARK: Hole rings

    func testThroughHoleGetsARingThatKeepsTheBoreAndItsClearance() throws {
        let source = try holedBlock()
        var plan = InternalWallsPlan.none
        plan.holeRings = true
        let result = try internalWallsCopy(of: source, options: options(plan))
        let mesh = try sound(result, source)
        XCTAssertEqual(result.rings.count, 1)
        XCTAssertEqual(result.count(of: .holeRing), 1)
        XCTAssertTrue(result.slots.isEmpty)
        XCTAssertEqual(try XCTUnwrap(analyzeMeshHealth(mesh)).shells, 1)
        let ring = try XCTUnwrap(result.rings.first)
        XCTAssertEqual(ring.centre.x, 20, accuracy: 0.001); XCTAssertEqual(ring.centre.y, 20, accuracy: 0.001)
        XCTAssertEqual(ring.boreRadiusMM, 3, accuracy: 0.001)
        XCTAssertFalse(ring.blind)
        // 1.375 mm of material between the bore and the gap: the gap's middle is about 1.5 mm out from the bore wall.
        XCTAssertEqual(ring.innerRadiusMM - ring.boreRadiusMM, internalWallsRingWallMM + internalWallsBoreRadiusToleranceMM, accuracy: 0.0001)
        XCTAssertEqual((ring.innerRadiusMM + ring.outerRadiusMM) / 2 - 3, 1.52, accuracy: 0.01)
        XCTAssertEqual(ring.outerRadiusMM - ring.innerRadiusMM, internalWallsSlotWidthMM, accuracy: 0.0001)
        XCTAssertEqual(ring.floorZ, 0)
        // 2 mm (plus the sampling margin) below the top face.
        XCTAssertLessThanOrEqual(ring.topZ, 20 - internalWallsClearanceMM)
        XCTAssertGreaterThan(ring.topZ, 16)
        XCTAssertEqual(result.removedVolumeMM3, ring.volumeMM3, accuracy: 0.001)

        // The bore is unchanged: every triangle but the bed face's comes first in the copy, in order and bit for bit.
        let kept = triangles(source) { !self.isBed($0, floor: 0) }
        let copied = triangles(mesh)
        XCTAssertGreaterThan(copied.count, kept.count)
        for (k, triangle) in kept.enumerated() {
            XCTAssertTrue(copied[k].0 == triangle.0 && copied[k].1 == triangle.1 && copied[k].2 == triangle.2, "Triangle \(k) changed")
        }
        // The same radius measured across the bore, halfway up.
        let rays = try XCTUnwrap(TriangleRayIndex(mesh))
        for angle in stride(from: Float(0.05), to: 6.2, by: 0.7) {
            let hit = try XCTUnwrap(rays.firstHit(from: SIMD3(20, 20, 10), along: SIMD3(cos(angle), sin(angle), 0)))
            XCTAssertEqual(hit.distance, 3, accuracy: 0.02)
        }

        // The ring is at least 2 mm from every other surface, and its 1.375 mm band from the bore's own walls.
        let bore = triangles(source) { t in
            [t.0, t.1, t.2].allSatisfy { simd_distance(SIMD2($0.x, $0.y), SIMD2(20, 20)) <= 3.02 } && !self.isBed(t, floor: 0)
        }
        let rest = triangles(source) { t in
            !self.isBed(t, floor: 0) && ![t.0, t.1, t.2].allSatisfy { simd_distance(SIMD2($0.x, $0.y), SIMD2(20, 20)) <= 3.02 }
        }
        XCTAssertFalse(bore.isEmpty)
        for k in stride(from: 0, to: ring.inner.count, by: 3) {
            for fz in stride(from: Float(0), through: 1, by: 0.25) {
                let z = ring.floorZ + (ring.topZ - ring.floorZ) * fz
                for point in [ring.inner[k], ring.outer[k]] {
                    XCTAssertGreaterThanOrEqual(nearest(SIMD3(point, z), rest), internalWallsClearanceMM - 0.001)
                }
                XCTAssertGreaterThanOrEqual(nearest(SIMD3(ring.inner[k], z), bore), internalWallsRingWallMM - 0.001)
            }
        }
        // Open at the bed, material over its ceiling.
        let middle = (ring.inner[0] + ring.outer[0]) / 2
        XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(middle, 0.05), in: mesh))
        XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(middle, ring.topZ - 0.05), in: mesh))
        XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(middle, ring.topZ + 0.05), in: mesh))

        // The report and summary name the ring, without claims.
        XCTAssertEqual(result.report(.holeRing)?.made, 1)
        let text = internalWallsSummary(result)
        XCTAssertTrue(text.hasPrefix("Adds internal walls: 1 hole ring, 0.25 mm wide, opening through the bed face."), text)
        for word in ["strong", "guarantee", "safe", "approved"] { XCTAssertFalse(text.lowercased().contains(word), text) }
    }

    func testBulkSlotsKeepClearOfTheRing() throws {
        let source = try holedBlock()
        let result = try internalWallsCopy(of: source, options: options(.all))
        _ = try sound(result, source)
        let ring = try XCTUnwrap(result.rings.first)
        XCTAssertGreaterThan(result.count(of: .bulkSlot), 0)
        for slot in result.slots where slot.kind == .bulkSlot {
            let closest = simd_clamp(ring.centre, SIMD2(slot.low.x, slot.low.y), SIMD2(slot.high.x, slot.high.y))
            XCTAssertGreaterThanOrEqual(simd_distance(closest, ring.centre), ring.outerRadiusMM + internalWallsClearanceMM - 0.001)
        }
    }

    func testBlindBoreRingStopsBelowItsCeiling() throws {
        let source = try repaired(box(SIMD3(0, 0, 0), SIMD3(40, 40, 20)).subtracting(cylinder(20, 20, radius: 3, -5, 10)))
        var plan = InternalWallsPlan.none
        plan.holeRings = true
        let result = try internalWallsCopy(of: source, options: options(plan))
        _ = try sound(result, source)
        let ring = try XCTUnwrap(result.rings.first)
        XCTAssertTrue(ring.blind)
        XCTAssertLessThanOrEqual(ring.topZ, 10 - internalWallsRingBlindTopClearanceMM)
        XCTAssertGreaterThanOrEqual(ring.heightMM, internalWallsMinimumSlotHeightMM)
    }

    func testBoreDetectionNeedsARoundHole() {
        func loop(_ count: Int, radius: Float, square: Bool = false) -> (points: [SIMD3<Float>], loops: [[Int]]) {
            let points: [SIMD3<Float>] = (0..<count).map { k in
                let angle = 2 * Float.pi * Float(k) / Float(count)
                let r = square && k % 2 == 1 ? radius * 0.7071 : radius
                return SIMD3(10 + r * cos(angle), 10 + r * sin(angle), 0)
            }
            return (points, [Array(0..<count)])
        }
        let round = loop(16, radius: 3)
        XCTAssertEqual(internalWallsBores(points: round.points, loops: round.loops).count, 1)
        XCTAssertEqual(internalWallsBores(points: round.points, loops: round.loops).first?.radiusMM ?? 0, 3, accuracy: 0.0001)
        // Clockwise seen from above: the outer outline, not a hole.
        XCTAssertTrue(internalWallsBores(points: round.points, loops: [Array(round.loops[0].reversed())]).isEmpty)
        let square = loop(8, radius: 3, square: true)
        XCTAssertTrue(internalWallsBores(points: square.points, loops: square.loops).isEmpty)
        let few = loop(6, radius: 3)
        XCTAssertTrue(internalWallsBores(points: few.points, loops: few.loops).isEmpty)
        let huge = loop(64, radius: 15)
        XCTAssertTrue(internalWallsBores(points: huge.points, loops: huge.loops).isEmpty)
        let tiny = loop(16, radius: 0.5)
        XCTAssertTrue(internalWallsBores(points: tiny.points, loops: tiny.loops).isEmpty)
    }

    // MARK: Pin slots

    func testUprightPinOnABaseGetsACentreSlot() throws {
        let source = try pinOnBase()
        var plan = InternalWallsPlan.none
        plan.pinSlots = true
        let result = try internalWallsCopy(of: source, options: options(plan), isCancelled: { false })
        _ = try sound(result, source)
        XCTAssertEqual(result.count(of: .pinSlot), 1, "\(internalWallsSkipNotes(result))")
        let slot = try XCTUnwrap(result.slots.first)
        XCTAssertEqual(slot.kind, .pinSlot)
        // Along X through the middle, from the bed up into the pin.
        XCTAssertEqual((slot.low.y + slot.high.y) / 2, 15, accuracy: 0.01)
        XCTAssertEqual((slot.low.x + slot.high.x) / 2, 15, accuracy: 0.13)
        XCTAssertGreaterThan(slot.lengthMM, slot.high.y - slot.low.y)
        XCTAssertEqual(slot.low.z, 0)
        XCTAssertGreaterThan(slot.high.z, 12)
        XCTAssertLessThanOrEqual(slot.high.z, 17 - internalWallsTargetedClearanceMM)
        // At least 1 mm from every surface but the bed face.
        let surfaces = triangles(source) { !self.isBed($0, floor: 0) }
        for fx in stride(from: Float(0), through: 1, by: 0.125) {
            for fy in [Float(0), 1] {
                for fz in stride(from: Float(0), through: 1, by: 0.1) {
                    let p = slot.low + (slot.high - slot.low) * SIMD3(fx, fy, fz)
                    XCTAssertGreaterThanOrEqual(nearest(p, surfaces), internalWallsTargetedClearanceMM - 0.001, "\(p)")
                }
            }
        }
    }

    func testPinStandingOnTheBedGetsASlot() throws {
        let source = try exported(cylinder(10, 10, radius: 3, 0, 15))
        var plan = InternalWallsPlan.none
        plan.pinSlots = true
        let result = try internalWallsCopy(of: source, options: options(plan))
        _ = try sound(result, source)
        XCTAssertEqual(result.count(of: .pinSlot), 1, "\(internalWallsSkipNotes(result))")
    }

    // MARK: Thin-section slots

    func testThreeMillimetrePlateGetsAThinSectionSlotWithAMillimetreEachSide() throws {
        let source = try plate(thickness: 3)
        var plan = InternalWallsPlan.none
        plan.thinSlots = true
        let result = try internalWallsCopy(of: source, options: options(plan))
        _ = try sound(result, source)
        XCTAssertEqual(result.count(of: .thinSlot), 1, "\(internalWallsSkipNotes(result))")
        let slot = try XCTUnwrap(result.slots.first)
        XCTAssertEqual(slot.kind, .thinSlot)
        XCTAssertEqual((slot.low.y + slot.high.y) / 2, 1.5, accuracy: 0.001)
        // 1.375 mm each side.
        XCTAssertGreaterThanOrEqual(slot.low.y, 1); XCTAssertLessThanOrEqual(slot.high.y, 2)
        XCTAssertGreaterThan(slot.lengthMM, 35)
        XCTAssertGreaterThan(slot.high.z, 17)
        let surfaces = triangles(source) { !self.isBed($0, floor: 0) }
        for fx in stride(from: Float(0), through: 1, by: 0.05) {
            for fy in [Float(0), 1] {
                for fz in stride(from: Float(0), through: 1, by: 0.1) {
                    let p = slot.low + (slot.high - slot.low) * SIMD3(fx, fy, fz)
                    XCTAssertGreaterThanOrEqual(nearest(p, surfaces), internalWallsTargetedClearanceMM - 0.001, "\(p)")
                }
            }
        }
        // The band each side is 0.375 mm of what was infill beyond Slant's 1 mm wall.
        XCTAssertEqual(slot.infillBandMM, 0.375, accuracy: 0.001)

        // 2.5 mm is the thinnest that takes one.
        XCTAssertEqual(try internalWallsCopy(of: plate(thickness: 2.5), options: options(plan)).count(of: .thinSlot), 1)
    }

    func testTooThinPlateGetsNoSlotAndSaysWhy() throws {
        let result = try internalWallsCopy(of: plate(thickness: 2.2), options: options(.all))
        XCTAssertNil(result.mesh)
        XCTAssertEqual(result.skipped, .noFeatureSuitable)
        XCTAssertEqual(result.report(.thinSlot)?.count(.tooThin), 1)
        XCTAssertEqual(result.report(.bulkSlot)?.count(.noneFound), 1)
        XCTAssertTrue(internalWallsSkipNotes(result).contains { $0.hasPrefix("1 thin section got no slot: under 2.5 mm thick") }, "\(internalWallsSkipNotes(result))")
    }

    // MARK: Plan

    func testPlanFollowsThePurpose() {
        XCTAssertEqual(internalWallsPlan(for: PartIntent(purpose: .decorative)), .none)
        for purpose in [PartPurpose.bracket, .clip, .enclosure, .custom] {
            XCTAssertEqual(internalWallsPlan(for: PartIntent(purpose: purpose)), .all, purpose.rawValue)
        }
        let neutral = internalWallsPlan(for: nil)
        XCTAssertEqual(neutral, .targeted)
        XCTAssertTrue(neutral.holeRings && neutral.pinSlots && neutral.thinSlots)
        XCTAssertFalse(neutral.bulkSlots)
        // The default options keep the slots in thick regions only, as before.
        XCTAssertEqual(InternalWallsOptions().plan, .bulkOnly)
        XCTAssertTrue(InternalWallsPlan.none.isEmpty)
    }

    func testDecorativePlanDoesNothing() throws {
        let source = try holedBlock()
        let result = try internalWallsCopy(of: source, options: internalWallsOptions(for: PartIntent(purpose: .decorative)))
        XCTAssertNil(result.mesh)
        XCTAssertNil(result.data)
        XCTAssertEqual(result.skipped, .nothingPlanned)
        XCTAssertTrue(result.slots.isEmpty && result.rings.isEmpty)
        XCTAssertTrue(result.kinds.allSatisfy { !$0.planned && $0.made == 0 })
    }

    func testLoadDirectionSetsTheSlotAxis() throws {
        XCTAssertEqual(internalWallsAxis(forLoad: nil), .automatic)
        XCTAssertEqual(internalWallsAxis(forLoad: SIMD3(1, 0, 0)), .x)
        XCTAssertEqual(internalWallsAxis(forLoad: SIMD3(0, -2, 0)), .y)
        XCTAssertEqual(internalWallsAxis(forLoad: SIMD3(0, 0, 1)), .automatic)
        XCTAssertEqual(internalWallsAxis(forLoad: SIMD3(0.2, 0.1, 1)), .automatic)
        XCTAssertEqual(internalWallsAxis(forLoad: SIMD3(1, 1, 0)), .automatic)
        XCTAssertEqual(internalWallsAxis(forLoad: SIMD3(0.3, 1, 0.2)), .y)
        XCTAssertEqual(internalWallsAxis(forLoad: SIMD3(.nan, 0, 0)), .automatic)

        let bracket = PartIntent(purpose: .bracket, details: "", load: .y)
        XCTAssertEqual(internalWallsOptions(for: bracket).axis, .y)
        // Placed on its side (original X up), an X load is vertical: automatic.
        XCTAssertEqual(internalWallsOptions(for: PartIntent(purpose: .bracket, load: .x), rotate: PrintOrientation.xUp.rotate).axis, .automatic)
        // Original Z placed along Y.
        XCTAssertEqual(internalWallsOptions(for: PartIntent(purpose: .clip, load: .z), rotate: PrintOrientation.yUp.rotate).axis, .y)
        // A decorative part's load is ignored.
        XCTAssertEqual(internalWallsOptions(for: PartIntent(purpose: .decorative, load: .y)).axis, .automatic)

        // On a 60 × 30 block the automatic slots run along X; a Y load turns them.
        let block = try exported(box(SIMD3(0, 0, 0), SIMD3(60, 30, 20)))
        let automatic = try internalWallsCopy(of: block, options: options(.all))
        XCTAssertEqual(automatic.axis, .x)
        let loaded = try internalWallsCopy(of: block, options: internalWallsOptions(for: bracket))
        _ = try sound(loaded, block)
        XCTAssertEqual(loaded.axis, .y)
        XCTAssertTrue(loaded.slots.filter { $0.kind == .bulkSlot }.allSatisfy { $0.high.y - $0.low.y > $0.high.x - $0.low.x })
    }

    // MARK: Every kind together

    func testCompositeGetsEveryKindAndTheSameBytesTwice() throws {
        let source = try composite()
        let first = try internalWallsCopy(of: source, options: options(.all))
        _ = try sound(first, source)
        XCTAssertEqual(first.count(of: .holeRing), 1, "\(internalWallsSkipNotes(first))")
        XCTAssertEqual(first.count(of: .pinSlot), 1, "\(internalWallsSkipNotes(first))")
        XCTAssertGreaterThanOrEqual(first.count(of: .thinSlot), 1, "\(internalWallsSkipNotes(first))")
        XCTAssertGreaterThanOrEqual(first.count(of: .bulkSlot), 1, "\(internalWallsSkipNotes(first))")
        XCTAssertEqual(first.slots.map(\.kind), first.slots.map(\.kind).sorted { $0.index < $1.index })
        XCTAssertEqual(first.kinds.map(\.kind), InternalWallsKind.allCases)
        // Walls of different kinds never come within 1 mm of each other.
        for (i, a) in first.slots.enumerated() {
            for b in first.slots[(i + 1)...] where a.kind != b.kind {
                let gap = simd_max(simd_max(a.low - b.high, b.low - a.high), SIMD3(repeating: 0))
                XCTAssertGreaterThanOrEqual(simd_length(SIMD2(gap.x, gap.y)), internalWallsTargetedClearanceMM - 0.001)
            }
        }
        let text = internalWallsSummary(first)
        XCTAssertTrue(text.hasPrefix("Adds internal walls: 1 hole ring, 1 pin slot, "), text)
        XCTAssertTrue(text.contains("all opening through the bed face"), text)
        XCTAssertTrue(text.contains("25 Oct 2026"), text)
        let second = try internalWallsCopy(of: source, options: options(.all))
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.slots, second.slots)
        XCTAssertEqual(first.rings, second.rings)
    }

    /// Run only as a subprocess by the test below: writes the output's hash to the named file.
    func testHashSeedProbeWritesWallsHash() throws {
        guard let out = ProcessInfo.processInfo.environment["SLANT_WALLS_HASH_OUT"] else { return }
        let result = try internalWallsCopy(of: composite(), options: options(.all))
        let digest = SHA256.hash(data: try XCTUnwrap(result.data)).map { String(format: "%02x", $0) }.joined()
        try digest.write(toFile: out, atomically: true, encoding: .utf8)
    }

    /// The same bytes whatever the process's hash seed: two runs of this test bundle, one with
    /// `SWIFT_DETERMINISTIC_HASHING=1` and one with a random seed, against this process's own result.
    func testWallsBytesMatchAcrossHashSeeds() throws {
        guard ProcessInfo.processInfo.environment["SLANT_WALLS_HASH_OUT"] == nil else { return }
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else { throw XCTSkip("xcrun isn't available") }
        let bundle = Bundle(for: Self.self).bundlePath
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SlantStudioWallsHashSeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func hash(deterministic: Bool) throws -> String {
            let out = folder.appendingPathComponent(deterministic ? "fixed.txt" : "random.txt").path
            var environment = ProcessInfo.processInfo.environment
            environment["SLANT_WALLS_HASH_OUT"] = out
            if deterministic { environment["SWIFT_DETERMINISTIC_HASHING"] = "1" } else { environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING") }
            let process = Process()
            process.executableURL = xcrun
            process.arguments = ["xctest", "-XCTest", "SlantStudioTests.InternalWallsKindsTests/testHashSeedProbeWritesWallsHash", bundle]
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(180)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { process.terminate(); XCTFail("The subprocess didn't finish") }
            return try String(contentsOfFile: out, encoding: .utf8)
        }
        let here = try internalWallsCopy(of: composite(), options: options(.all))
        let local = SHA256.hash(data: try XCTUnwrap(here.data)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try hash(deterministic: true), local)
        XCTAssertEqual(try hash(deterministic: false), local)
    }

    // MARK: Skip reasons

    func testSkipReasonsPerKind() throws {
        // A plain block: no holes, pins or thin sections; only the slots in thick regions.
        let plain = try exported(box(SIMD3(0, 0, 0), SIMD3(40, 40, 20)))
        let all = try internalWallsCopy(of: plain, options: options(.all))
        _ = try sound(all, plain)
        XCTAssertEqual(all.report(.holeRing)?.count(.noneFound), 1)
        XCTAssertEqual(all.report(.pinSlot)?.count(.noneFound), 1)
        XCTAssertEqual(all.report(.thinSlot)?.count(.noneFound), 1)
        XCTAssertEqual(all.report(.bulkSlot)?.made, 9)
        XCTAssertEqual(all.report(.bulkSlot)?.skipped, [])
        // Kinds left out of the plan are reported as not planned, with nothing skipped.
        let bulk = try internalWallsCopy(of: plain)
        XCTAssertEqual(bulk.kinds.filter(\.planned).map(\.kind), [.bulkSlot])
        XCTAssertTrue(bulk.kinds.allSatisfy { $0.planned || $0.skipped.isEmpty })

        var rings = InternalWallsPlan.none
        rings.holeRings = true
        // A 6 mm hole 3 mm from the side: no room for the ring and its 2 mm.
        let edge = try repaired(box(SIMD3(0, 0, 0), SIMD3(40, 40, 20)).subtracting(cylinder(6, 20, radius: 3, -5, 25)))
        let edgeResult = try internalWallsCopy(of: edge, options: options(rings))
        XCTAssertEqual(edgeResult.skipped, .noFeatureSuitable)
        XCTAssertEqual(edgeResult.report(.holeRing)?.count(.tooCloseToSurface), 1, "\(edgeResult.kinds)")
        // A 3 mm blind bore: the ring would be under 3 mm tall.
        let shallow = try repaired(box(SIMD3(0, 0, 0), SIMD3(40, 40, 20)).subtracting(cylinder(20, 20, radius: 3, -5, 3)))
        XCTAssertEqual(try internalWallsCopy(of: shallow, options: options(rings)).report(.holeRing)?.count(.tooShort), 1)

        var pins = InternalWallsPlan.none
        pins.pinSlots = true
        // A 4.2 mm pin: a slot 1 mm under its top is under 3 mm tall.
        let stub = try exported(cylinder(10, 10, radius: 3, 0, 4.2))
        let stubResult = try internalWallsCopy(of: stub, options: options(pins))
        XCTAssertEqual(stubResult.report(.pinSlot)?.count(.tooShort), 1, "\(stubResult.kinds)")

        for kind in InternalWallsKind.allCases {
            for reason in InternalWallsFeatureSkipReason.allCases {
                let text = internalWallsSkipNote(kind, InternalWallsFeatureSkip(reason: reason, count: 2))
                XCTAssertFalse(text.isEmpty)
                for word in ["strong", "guarantee", "safe", "approved"] { XCTAssertFalse(text.lowercased().contains(word), text) }
            }
        }
        XCTAssertEqual(internalWallsSkipNote(.holeRing, InternalWallsFeatureSkip(reason: .tooCloseToSurface, count: 2)),
                       "2 holes got no ring: another surface or wall is within 2 mm.")
        XCTAssertEqual(internalWallsSkipNote(.pinSlot, InternalWallsFeatureSkip(reason: .tooShort, count: 1)),
                       "1 pin got no slot: there isn’t room for a ring or slot at least 3 mm tall.")
        XCTAssertEqual(internalWallsSkipNote(.bulkSlot, InternalWallsFeatureSkip(reason: .wouldRemoveTooMuch, count: 1)),
                       "Slots in thick regions were left out: they would remove too much of the part.")
        XCTAssertFalse(internalWallsSkipNote(.bulkSlot, InternalWallsFeatureSkip(reason: .noneFound, count: 1)).hasPrefix("No internal walls"))
        for reason in InternalWallsSkipReason.allCases {
            for word in ["strong", "guarantee", "safe", "approved"] { XCTAssertFalse(reason.message.lowercased().contains(word), reason.rawValue) }
        }
    }

    // MARK: Bounds

    func testRingCountAndBridgingStayBounded() throws {
        // Nine holed tiles, each a separate part (Euclid's many-hole plates leave folded slivers in the bed face); a
        // limit of four leaves five without a ring.
        let tile = try repaired(box(SIMD3(0, 0, 0), SIMD3(16, 16, 10)).subtracting(cylinder(8, 8, radius: 2, -5, 15, slices: 24)))
        var floats: [Float] = []
        for i in 0..<3 {
            for j in 0..<3 {
                for k in stride(from: 0, to: tile.vertices.count, by: 3) {
                    floats += [tile.vertices[k] + Float(20 * i), tile.vertices[k + 1] + Float(20 * j), tile.vertices[k + 2]]
                }
            }
        }
        let source = try STLMesh.validated(floats)
        XCTAssertEqual(try XCTUnwrap(analyzeMeshHealth(source)).shells, 9)
        var limited = options(.targeted)
        limited.maximumRings = 4
        let result = try internalWallsCopy(of: source, options: limited)
        _ = try sound(result, source, file: #filePath, line: #line)
        XCTAssertEqual(result.rings.count, 4)
        XCTAssertEqual(result.report(.holeRing)?.count(.limitReached), 5)
        let every = try internalWallsCopy(of: source, options: options(.targeted))
        _ = try sound(every, source)
        XCTAssertEqual(every.rings.count, 9)

        // A ring's outlines never exceed 256 corners, so the bridging work per ring is bounded.
        XCTAssertEqual(internalWallsRingOutlines(centre: .zero, innerRadius: 60, outerRadius: 60.25).inner.count, 256)
        XCTAssertEqual(internalWallsRingOutlines(centre: .zero, innerRadius: 1, outerRadius: 1.25).outer.count, 24)
        // A ring opening bridged into an outline (mirrored in X, as the assembly does, so the outline is anticlockwise
        // and the ring's outer outline a clockwise hole): joined within the budget, and an exhausted budget is a failure.
        let shape = internalWallsRingOutlines(centre: SIMD2(20, 20), innerRadius: 4, outerRadius: 4.25)
        var points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(0, 40), SIMD2(-40, 40), SIMD2(-40, 0)]
        points += shape.outer.map { SIMD2(-Double($0.x), Double($0.y)) }
        let loops = [[0, 1, 2, 3], Array(4..<points.count)]
        let joined = try internalWallsBridgedLoops(points: points, loops: loops)
        XCTAssertNotNil(joined.loops)
        XCTAssertEqual(joined.loops?.first?.count, 4 + shape.outer.count + 2)
        let starved = try internalWallsBridgedLoops(points: points, loops: loops, workLimit: 100)
        XCTAssertNil(starved.loops)
        XCTAssertTrue(starved.workLimitReached)
    }

    func testMaterialEstimateMatchesSlantsBlock() throws {
        let block = try exported(box(SIMD3(0, 0, 0), SIMD3(40, 40, 20)))
        let result = try internalWallsCopy(of: block)
        XCTAssertEqual(result.slotCount, 9)
        XCTAssertEqual(result.addedSurfaceAreaMM2, 9 * (2 * 35 * 17.75 + 2 * 0.25 * 17.75 + 35 * 0.25), accuracy: 0.5)
        // Slant's own estimate on 25 Oct 2026 showed 69% more material; Studio's simpler model gives about 64%.
        XCTAssertEqual(result.estimatedExtraMaterialFraction, 0.637, accuracy: 0.01)
        XCTAssertEqual(internalWallsBaselineMaterialMM3(volumeMM3: 32_000, surfaceAreaMM2: 6_400), 12_800, accuracy: 0.001)
        XCTAssertEqual(internalWallsBaselineMaterialMM3(volumeMM3: 100, surfaceAreaMM2: 400), 100, accuracy: 0.001)
        XCTAssertEqual(internalWallsEstimatedExtraMaterialMM3(slots: [], rings: []), 0)
        let text = internalWallsSummary(result)
        XCTAssertTrue(text.contains("an estimated 64% more filament"), text)
    }

    func testCancellationStopsEveryKind() throws {
        let source = try composite()
        var total = 0
        _ = try internalWallsCopy(of: source, options: options(.all), isCancelled: { total += 1; return false })
        XCTAssertGreaterThan(total, 20)
        for limit in [2, total / 4, total / 2, total - 1] {
            var calls = 0
            XCTAssertThrowsError(try internalWallsCopy(of: source, options: options(.all), isCancelled: { calls += 1; return calls > limit })) {
                XCTAssertEqual($0 as? InternalWallsError, .stopped)
            }
        }
        // A stop at the very end of a plan that finds nothing is still a stop, never "nothing found".
        let thin = try plate(thickness: 2.2)
        var planned = 0
        XCTAssertEqual(try internalWallsCopy(of: thin, options: options(.all), isCancelled: { planned += 1; return false }).skipped, .noFeatureSuitable)
        var calls = 0
        XCTAssertThrowsError(try internalWallsCopy(of: thin, options: options(.all), isCancelled: { calls += 1; return calls >= planned })) {
            XCTAssertEqual($0 as? InternalWallsError, .stopped)
        }
    }

    // MARK: Timing

    /// Splits every triangle into four at its edges' midpoints: the same solid, sound, with 4× the triangles.
    private func subdivided(_ mesh: STLMesh) throws -> STLMesh {
        var out: [Float] = []
        out.reserveCapacity(mesh.vertices.count * 4)
        for t in 0..<mesh.triangleCount {
            let p = (0..<3).map { j in SIMD3(mesh.vertices[t * 9 + j * 3], mesh.vertices[t * 9 + j * 3 + 1], mesh.vertices[t * 9 + j * 3 + 2]) }
            let ab = (p[0] + p[1]) / 2, bc = (p[1] + p[2]) / 2, ca = (p[2] + p[0]) / 2
            for q in [p[0], ab, ca, ab, p[1], bc, ca, bc, p[2], ab, bc, ca] { out += [q.x, q.y, q.z] }
        }
        return try STLMesh.validated(out)
    }

    /// Splits every triangle into three at its centroid: the same solid, sound, with 3× the triangles.
    private func split(_ mesh: STLMesh) throws -> STLMesh {
        var out: [Float] = []
        out.reserveCapacity(mesh.vertices.count * 3)
        for t in 0..<mesh.triangleCount {
            let p = (0..<3).map { j in SIMD3(mesh.vertices[t * 9 + j * 3], mesh.vertices[t * 9 + j * 3 + 1], mesh.vertices[t * 9 + j * 3 + 2]) }
            let g = (p[0] + p[1] + p[2]) / 3
            for q in [p[0], p[1], g, p[1], p[2], g, p[2], p[0], g] { out += [q.x, q.y, q.z] }
        }
        return try STLMesh.validated(out)
    }

    /// A finely triangulated bed face gets the same walls: axis-aligned probe rays through many triangle corners used
    /// to be dropped by the ray index's box test (0 × ∞), losing most slots in thick regions.
    func testDenseBedFaceGetsTheSameWalls() throws {
        let coarse = try composite()
        var dense = coarse
        for _ in 0..<3 { dense = try subdivided(dense) }
        XCTAssertGreaterThan(dense.triangleCount, 30_000)
        let a = try internalWallsCopy(of: coarse, options: options(.all))
        let b = try internalWallsCopy(of: dense, options: options(.all))
        _ = try sound(b, dense)
        XCTAssertEqual(a.slots, b.slots)
        XCTAssertEqual(a.rings.count, b.rings.count)
        XCTAssertEqual(b.count(of: .bulkSlot), a.count(of: .bulkSlot))
    }

    /// Opt-in timing (set SLANT_WALLS_BENCH=1); run in release. About 20,000, 100,000 and 400,000 triangles.
    func testTimingOnLargeMeshes() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SLANT_WALLS_BENCH"] == "1", "Set SLANT_WALLS_BENCH=1 to time internal walls.")
        var small = try composite()
        while small.triangleCount * 4 <= 10_000 { small = try subdivided(small) }
        let medium = try subdivided(subdivided(small))
        for sample in [try split(small), medium, try split(medium)] {
            let start = Date()
            let result = try internalWallsCopy(of: sample, options: options(.all))
            let seconds = Date().timeIntervalSince(start)
            print(String(format: "InternalWalls timing: %d triangles, %.2f s, rings %d, pins %d, thin %d, bulk %d, skipped %@",
                         sample.triangleCount, seconds, result.count(of: .holeRing), result.count(of: .pinSlot),
                         result.count(of: .thinSlot), result.count(of: .bulkSlot), String(describing: result.skipped)))
            XCTAssertNotNil(result.mesh)
        }
    }
}
