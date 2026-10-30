import XCTest
import Euclid
import simd
@testable import Plinth

final class InternalWallsTests: XCTestCase {
    private func exported(_ mesh: Mesh) throws -> STLMesh { try ReinforcementEngine.stl(mesh.makeWatertight()) }
    /// Euclid's exports can carry zero-area slivers; Repair removes them, as the automatic preparation does first.
    private func repaired(_ mesh: Mesh) throws -> STLMesh {
        let result = try repairMesh(exported(mesh))
        XCTAssertTrue(result.summary.isSound)
        return result.mesh
    }
    private func holedBlock() throws -> STLMesh {
        let hole = Mesh.cylinder(radius: 3, height: 40, slices: 32).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(20, 20, 10))
        return try repaired(Mesh.cube(center: Vector(20, 20, 10), size: Vector(40, 40, 20)).subtracting(hole))
    }
    /// The live test's 40 × 40 × 20 mm block, from the origin.
    private func block(_ size: SIMD3<Double> = SIMD3(40, 40, 20)) throws -> STLMesh {
        try exported(.cube(center: Vector(size.x / 2, size.y / 2, size.z / 2), size: Vector(size.x, size.y, size.z)))
    }
    private func health(_ mesh: STLMesh) throws -> MeshHealthReport { try XCTUnwrap(analyzeMeshHealth(mesh)) }

    /// Every slot is at least `clearance` from every surface of `source` except its bed face, sampled over each slot's
    /// faces with an independent brute-force distance.
    private func assertClearance(_ result: InternalWallsResult, _ source: STLMesh, clearance: Float = internalWallsClearanceMM,
                                 file: StaticString = #filePath, line: UInt = #line) {
        let floor = source.minimum.z
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for t in 0..<source.triangleCount {
            let p = (0..<3).map { j in SIMD3(source.vertices[t * 9 + j * 3], source.vertices[t * 9 + j * 3 + 1], source.vertices[t * 9 + j * 3 + 2]) }
            let n = simd_normalize(simd_cross(p[1] - p[0], p[2] - p[0]))
            if p.allSatisfy({ $0.z <= floor + 0.0001 }), n.z < -0.9999 { continue }
            triangles.append((p[0], p[1], p[2]))
        }
        for slot in result.slots {
            for fx in stride(from: Float(0), through: 1, by: 0.125) {
                for fy in [Float(0), 1] {
                    for fz in stride(from: Float(0), through: 1, by: 0.125) {
                        let p = slot.low + (slot.high - slot.low) * SIMD3(fx, fy, fz)
                        let d = triangles.map { internalWallsPointTriangleDistanceSquared(p, $0.0, $0.1, $0.2) }.min()!.squareRoot()
                        XCTAssertGreaterThanOrEqual(d, clearance - 0.001, "Slot point \(p) is \(d) mm from a surface", file: file, line: line)
                    }
                }
            }
        }
    }

    private func assertSoundCopy(_ result: InternalWallsResult, _ source: STLMesh, cap: Double = internalWallsMaximumRemovedFraction,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let mesh = try XCTUnwrap(result.mesh, "Skipped: \(String(describing: result.skipped))", file: file, line: line)
        XCTAssertNil(result.skipped, file: file, line: line)
        XCTAssertEqual(mesh.minimum, source.minimum, file: file, line: line)
        XCTAssertEqual(mesh.maximum, source.maximum, file: file, line: line)
        let before = try health(source), after = try health(mesh)
        XCTAssertTrue(meshHealthIsSound(after), file: file, line: line)
        XCTAssertEqual(after.shells, before.shells, file: file, line: line)
        XCTAssertEqual(result.shellsBefore, before.shells, file: file, line: line)
        XCTAssertEqual(result.shellsAfter, after.shells, file: file, line: line)
        XCTAssertEqual(before.signedVolume - after.signedVolume, result.removedVolumeMM3, accuracy: max(0.01, result.removedVolumeMM3 * 0.001), file: file, line: line)
        XCTAssertLessThanOrEqual(result.removedFraction, cap + 1e-9, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(result.data), mesh.binarySTL(), file: file, line: line)
        // Euclid agrees that it is one closed, outward solid per shell.
        if mesh.triangleCount <= 20_000 {
            let solid = try mesh.reinforcementSolid()
            XCTAssertTrue(solid.isWatertight, file: file, line: line)
            XCTAssertEqual(solid.signedVolume, after.signedVolume, accuracy: 0.01, file: file, line: line)
        }
        for slot in result.slots {
            XCTAssertEqual(slot.low.z, source.minimum.z, "Every slot opens through the bed face", file: file, line: line)
            let centre = (slot.low + slot.high) / 2
            XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(centre.x, centre.y, slot.low.z + 0.05), in: mesh), file: file, line: line)
            XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(centre.x, centre.y, slot.high.z - 0.05), in: mesh), file: file, line: line)
            XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(centre.x, centre.y, slot.high.z + 0.05), in: mesh), file: file, line: line)
        }
    }

    func testBlockGetsSlotsOpenThroughTheBottom() throws {
        let source = try block()
        let result = try internalWallsCopy(of: source)
        try assertSoundCopy(result, source)
        assertClearance(result, source)
        // The clearance margin is 2 mm plus half the slot width, column step and height step (0.28 mm with defaults):
        // slots run x = 2.5–37.5 mm and up to z = 17.75 mm. Nine lines at the default 4 mm remove 4.4%, within the 6%
        // cap: the spacing Slant priced on 25 Oct 2026.
        XCTAssertEqual(result.axis, .x)
        XCTAssertEqual(result.spacingMM, 4)
        XCTAssertEqual(result.slotCount, 9)
        for slot in result.slots {
            XCTAssertEqual(slot.low.x, 2.5, accuracy: 0.0001); XCTAssertEqual(slot.high.x, 37.5, accuracy: 0.0001)
            XCTAssertEqual(slot.high.z, 17.75, accuracy: 0.0001)
            XCTAssertEqual(slot.high.y - slot.low.y, 0.25, accuracy: 0.0001)
        }
        XCTAssertEqual(result.removedVolumeMM3, 9 * 0.25 * 35 * 17.75, accuracy: 0.01)
        XCTAssertEqual(result.totalSlotLengthMM, 9 * 35, accuracy: 0.01)
        XCTAssertEqual(result.slotPerimeterMM, 9 * 2 * 35.25, accuracy: 0.01)
        XCTAssertEqual(result.shellsBefore, 1); XCTAssertEqual(result.shellsAfter, 1)
    }

    func testALowerVolumeLimitWidensTheSpacing() throws {
        let source = try block()
        var options = InternalWallsOptions()
        options.maximumRemovedFraction = 0.03
        let result = try internalWallsCopy(of: source, options: options)
        try assertSoundCopy(result, source, cap: 0.03)
        // Nine lines at 4 mm would remove 4.4%, over a 3% limit, so the spacing widens to 6 mm: six lines.
        XCTAssertEqual(result.spacingMM, 6)
        XCTAssertEqual(result.slotCount, 6)
        XCTAssertEqual(result.removedVolumeMM3, 6 * 0.25 * 35 * 17.75, accuracy: 0.01)
    }

    func testThinWalledBoxGetsNoSlots() throws {
        let outer = Mesh.cube(center: Vector(15, 15, 10), size: Vector(30, 30, 20))
        let cavity = Mesh.cube(center: Vector(15, 15, 12), size: Vector(26, 26, 20))
        let result = try internalWallsCopy(of: exported(outer.subtracting(cavity)))
        XCTAssertNil(result.mesh)
        XCTAssertEqual(result.skipped, .noRegionThickEnough)
        XCTAssertTrue(result.slots.isEmpty)
    }

    func testVerticalHoleKeepsClearance() throws {
        let source = try holedBlock()
        let result = try internalWallsCopy(of: source)
        try assertSoundCopy(result, source)
        assertClearance(result, source)
        XCTAssertGreaterThan(result.slotCount, 0)
        for slot in result.slots {
            // Distance from the hole's axis to the slot's footprint.
            let nearest = simd_clamp(SIMD2<Float>(20, 20), SIMD2(slot.low.x, slot.low.y), SIMD2(slot.high.x, slot.high.y))
            XCTAssertGreaterThanOrEqual(simd_distance(nearest, SIMD2(20, 20)), 3 + internalWallsClearanceMM - 0.001)
        }
        // The line through the hole is split into two slots, one either side.
        XCTAssertTrue(result.slots.contains { $0.high.x < 20 } && result.slots.contains { $0.low.x > 20 })
    }

    func testSameBytesEveryRun() throws {
        let source = try holedBlock()
        let first = try XCTUnwrap(internalWallsCopy(of: source).data)
        let second = try XCTUnwrap(internalWallsCopy(of: source).data)
        XCTAssertEqual(first, second)
        // Compared across processes with and without SWIFT_DETERMINISTIC_HASHING=1.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in first { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        print("InternalWalls output hash: \(String(hash, radix: 16)) (\(first.count) bytes)")
    }

    func testCancellationStops() throws {
        let source = try block()
        XCTAssertThrowsError(try internalWallsCopy(of: source, isCancelled: { true })) { XCTAssertEqual($0 as? InternalWallsError, .stopped) }
        // Part-way through the plan.
        var calls = 0
        XCTAssertThrowsError(try internalWallsCopy(of: source, isCancelled: { calls += 1; return calls > 3 })) {
            XCTAssertEqual($0 as? InternalWallsError, .stopped)
        }
    }

    func testSkipReasons() throws {
        let source = try block()
        var few = InternalWallsOptions(); few.maximumTriangles = 5
        XCTAssertEqual(try internalWallsCopy(of: source, options: few).skipped, .tooManyTriangles)

        // Standing on an edge: no flat face at the lowest point.
        let edgeDown = try exported(Mesh.cube(center: .zero, size: Vector(30, 30, 30)).rotated(by: Rotation(pitch: .radians(.pi / 4))))
        XCTAssertLessThan(edgeDown.bottomContactAreaMM2(), 0.001)
        XCTAssertEqual(try internalWallsCopy(of: edgeDown).skipped, .noFlatBedFace)

        let open = STLMesh(vertices: Array(source.vertices.dropLast(9)), minimum: source.minimum, maximum: source.maximum)
        XCTAssertEqual(try internalWallsCopy(of: open).skipped, .notClosedSolid)

        var strict = InternalWallsOptions(); strict.maximumRemovedFraction = 0.001
        XCTAssertEqual(try internalWallsCopy(of: source, options: strict).skipped, .wouldRemoveTooMuch)

        var invalid = InternalWallsOptions(); invalid.slotWidthMM = 0.05
        XCTAssertThrowsError(try internalWallsCopy(of: source, options: invalid))
        for reason in InternalWallsSkipReason.allCases {
            XCTAssertFalse(reason.message.isEmpty)
            for word in ["strong", "guarantee", "safe", "approved"] { XCTAssertFalse(reason.message.lowercased().contains(word), reason.rawValue) }
        }
    }

    func testResultChecksReportShellCountAndFailures() {
        func report(shells: Int, open: Int = 0, volume: Double = 100) -> MeshHealthReport {
            MeshHealthReport(triangleCount: 12, vertexCount: 8, openEdges: open, nonManifoldEdges: 0, flippedEdges: 0,
                             degenerateTriangles: 0, shells: shells, signedVolume: volume)
        }
        XCTAssertNil(internalWallsResultProblem(before: report(shells: 1), after: report(shells: 1, volume: 90), removedVolume: 10))
        XCTAssertEqual(internalWallsResultProblem(before: report(shells: 1), after: report(shells: 2, volume: 90), removedVolume: 10), .wouldChangeShellCount)
        XCTAssertEqual(internalWallsResultProblem(before: report(shells: 2), after: report(shells: 1, volume: 90), removedVolume: 10), .wouldChangeShellCount)
        XCTAssertEqual(internalWallsResultProblem(before: report(shells: 1), after: report(shells: 1, open: 2, volume: 90), removedVolume: 10), .resultFailedChecks)
        XCTAssertEqual(internalWallsResultProblem(before: report(shells: 1), after: report(shells: 1, volume: 80), removedVolume: 10), .resultFailedChecks)
    }

    func testShellCountUnchangedForSeparateParts() throws {
        let a = Mesh.cube(center: Vector(15, 15, 10), size: Vector(30, 30, 20))
        let b = Mesh.cube(center: Vector(60, 15, 10), size: Vector(30, 30, 20))
        let source = try exported(a.union(b))
        XCTAssertEqual(try health(source).shells, 2)
        let result = try internalWallsCopy(of: source)
        try assertSoundCopy(result, source)
        assertClearance(result, source)
        XCTAssertEqual(result.shellsAfter, 2)
        XCTAssertTrue(result.slots.contains { $0.high.x < 30 } && result.slots.contains { $0.low.x > 45 })
    }

    func testAxisFollowsTheLongerSideAndKeepClearIsRespected() throws {
        let source = try block(SIMD3(60, 30, 20))
        let automatic = try internalWallsCopy(of: source)
        try assertSoundCopy(automatic, source)
        XCTAssertEqual(automatic.axis, .x)
        XCTAssertTrue(automatic.slots.allSatisfy { $0.high.x - $0.low.x > $0.high.y - $0.low.y })
        var across = InternalWallsOptions(); across.axis = .y
        let turned = try internalWallsCopy(of: source, options: across)
        try assertSoundCopy(turned, source)
        XCTAssertTrue(turned.slots.allSatisfy { $0.high.y - $0.low.y > $0.high.x - $0.low.x })

        var guarded = InternalWallsOptions()
        let keep = InternalWallsKeepClearBox(low: SIMD3(30, -1, -1), high: SIMD3(61, 31, 21))
        guarded.keepClear = [keep]
        let kept = try internalWallsCopy(of: source, options: guarded)
        try assertSoundCopy(kept, source)
        XCTAssertGreaterThan(kept.slotCount, 0)
        XCTAssertTrue(kept.slots.allSatisfy { $0.high.x <= keep.low.x })
    }

    func testSteppedPartGetsTallSlotsWhereItIsTall() throws {
        // A 10 mm plate with a 30 mm tall block on one half.
        let plate = Mesh.cube(center: Vector(30, 15, 5), size: Vector(60, 30, 10))
        let tower = Mesh.cube(center: Vector(15, 15, 15), size: Vector(30, 30, 30))
        let source = try exported(plate.union(tower))
        let result = try internalWallsCopy(of: source)
        try assertSoundCopy(result, source)
        assertClearance(result, source)
        XCTAssertTrue(result.slots.contains { $0.high.z > 25 })
        XCTAssertTrue(result.slots.contains { $0.high.z < 9 && $0.high.x > 50 })
    }

    func testDiamondFootprintAndSlantedSides() throws {
        // A cube turned 45° about Z: the slots stop 2 mm from the sloping sides.
        let source = try exported(Mesh.cube(center: Vector(0, 0, 15), size: Vector(30, 30, 30)).rotated(by: Rotation(roll: .radians(.pi / 4))))
        let result = try internalWallsCopy(of: source)
        try assertSoundCopy(result, source)
        assertClearance(result, source)
        XCTAssertGreaterThan(result.slotCount, 3)
    }

    func testSummaryNamesTheWallsWithoutStrengthClaims() throws {
        let result = try internalWallsCopy(of: block())
        let text = internalWallsSummary(result)
        XCTAssertTrue(text.hasPrefix("Adds internal walls: 9 slots"), text)
        XCTAssertTrue(text.contains("opening through the bed face"), text)
        for word in ["strong", "stronger", "%-", "guarantee", "safe"] { XCTAssertFalse(text.lowercased().contains(word), text) }
    }
}
