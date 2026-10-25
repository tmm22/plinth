import XCTest
import Euclid
import simd
@testable import SlantStudio

final class ReinforcementTests: XCTestCase {
    private func tray() throws -> STLMesh {
        let outer = Mesh.cube(center: Vector(10,10,10), size: Vector(20,20,20))
        let cavity = Mesh.cube(center: Vector(10,10,12), size: Vector(16,16,20))
        return try ReinforcementEngine.stl(outer.subtracting(cavity).makeWatertight())
    }
    private func block() throws -> STLMesh {
        try ReinforcementEngine.stl(.cube(center: Vector(10,10,10), size: Vector(20,20,20)))
    }
    func testAllFeatureToolsAreClosedPositiveSolids() throws {
        for kind in ReinforcementKind.allCases {
            let settings = ReinforcementSettings(kind: kind, size: SIMD3(8,8,8))
            let tool = try ReinforcementEngine.tool(settings)
            XCTAssertTrue(tool.isWatertight, kind.rawValue)
            XCTAssertGreaterThan(tool.signedVolume, 0, kind.rawValue)
        }
    }
    func testRibGussetAndFilletFuseIntoTrayWithoutChangingExterior() throws {
        let source = try tray()
        for kind in [ReinforcementKind.rib, .gusset, .fillet] {
            let settings = ReinforcementSettings(kind: kind, offset: SIMD3(5,1.8,1.8), size: SIMD3(8,8,8))
            let result = try ReinforcementEngine.preview(source, settings: settings)
            XCTAssertGreaterThan(result.addedVolume, 0, kind.rawValue)
            XCTAssertEqual(result.removedVolume, 0, accuracy: 0.0001)
            XCTAssertEqual(result.mesh.minimum, source.minimum)
            XCTAssertEqual(result.mesh.maximum, source.maximum)
            XCTAssertTrue(try result.mesh.reinforcementSolid().isWatertight)
            XCTAssertNotNil(result.proposedSection)
            let original = try source.reinforcementSolid()
            let edited = try result.mesh.reinforcementSolid()
            XCTAssertEqual(original.subtracting(edited).signedVolume, 0, accuracy: 0.001)
        }
    }
    func testClosedVoidTreatmentsAreWithdrawn() throws {
        // Cells and the shell gap always leave a closed void, which Slant bills as an extra body.
        let source = try block()
        for kind in [ReinforcementKind.cells, .shell] {
            XCTAssertTrue(kind.isWithdrawn)
            XCTAssertFalse(ReinforcementKind.offered.contains(kind))
            let settings = ReinforcementSettings(kind: kind, offset: SIMD3(repeating: 5), size: SIMD3(repeating: 10))
            XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: settings)) {
                XCTAssertEqual($0.localizedDescription, reinforcementClosedVoidWithdrawal)
            }
            XCTAssertThrowsError(try ReinforcementEngine.suggestPosition(source, settings: settings))
            XCTAssertEqual(kind.explanation, reinforcementClosedVoidWithdrawal)
        }
        XCTAssertTrue(ReinforcementKind.offered.contains(.internalWalls))
        XCTAssertTrue(reinforcementClosedVoidWithdrawal.contains("Internal walls"))
    }

    func testShellCheckRefusesClosedVoids() throws {
        XCTAssertNil(reinforcementShellGrowthProblem(before: 1, after: 1))
        XCTAssertNil(reinforcementShellGrowthProblem(before: 2, after: 1))
        let problem = try XCTUnwrap(reinforcementShellGrowthProblem(before: 1, after: 2))
        XCTAssertTrue(problem.contains("extra body"), problem)
        // A block with a sealed cavity has two shells: the cavity's surface is its own.
        let voided = try ReinforcementEngine.stl(cube20.subtracting(.cube(center: Vector(10,10,10), size: Vector(6,6,6))).makeWatertight())
        XCTAssertEqual(try ReinforcementEngine.shellCounts(try block(), [try block()], { false }).after, 1)
        XCTAssertThrowsError(try ReinforcementEngine.shellCounts(try block(), [voided], { false }))
        XCTAssertEqual(reinforcementShellLine(before: 1, after: 1, split: false), "Separate shells: 1 before · 1 after")
    }

    func testInternalWallsTreatmentCutsSlotsThroughTheBed() throws {
        let source = try ReinforcementEngine.stl(.cube(center: Vector(20,20,10), size: Vector(40,40,20)))
        let settings = ReinforcementSettings(kind: .internalWalls)
        let result = try ReinforcementEngine.preview(source, settings: settings)
        try assertPreserved(result, source)
        XCTAssertEqual(result.addedVolume, 0)
        XCTAssertEqual(result.removedVolume, 9 * 0.25 * 35 * 17.75, accuracy: 0.01)
        XCTAssertEqual(result.shellsBefore, 1); XCTAssertEqual(result.shellsAfter, 1)
        XCTAssertTrue(try XCTUnwrap(result.detail).hasPrefix("Adds internal walls"))
        XCTAssertNotNil(result.proposedSection)
        XCTAssertTrue(ReinforcementKind.internalWalls.keepsZUp)
        XCTAssertFalse(ReinforcementKind.internalWalls.isExperimental)
        XCTAssertThrowsError(try ReinforcementEngine.suggestPosition(source, settings: settings))
        // Keep-clear regions are left uncut.
        var guarded = settings
        guarded.protectedRegions = [ReinforcementBox(offset: SIMD3(0, 0, 0), size: SIMD3(40, 20, 20))]
        let kept = try ReinforcementEngine.preview(source, settings: guarded)
        XCTAssertEqual(try occupied(kept.mesh, .cube(center: Vector(20,10,10), size: Vector(40,20,20))), 16000, accuracy: 0.01)
        XCTAssertLessThan(kept.removedVolume, result.removedVolume)
        // A part too thin for slots says why.
        XCTAssertThrowsError(try ReinforcementEngine.preview(tray(), settings: settings)) {
            XCTAssertEqual($0.localizedDescription, InternalWallsSkipReason.noRegionThickEnough.message)
        }
    }
    func testFloatingNoOpOutOfBoundsAndProtectedRegionsAreRejected() throws {
        let source = try tray()
        let attached = ReinforcementSettings(offset: SIMD3(5,1.8,1.8), size: SIMD3(8,8,8))
        var floating = attached; floating.offset = SIMD3(5,5,5)
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: floating))
        var outside = attached; outside.offset.x = 100
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: outside))
        XCTAssertThrowsError(try ReinforcementEngine.preview(block(), settings: attached))
        var protected = attached
        protected.protectedRegions = [ReinforcementBox(offset: .zero, size: SIMD3(repeating: 20))]
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: protected))
        protected.protectedRegions = [ReinforcementBox(offset: SIMD3(17,17,10), size: SIMD3(repeating: 1))]
        XCTAssertNoThrow(try ReinforcementEngine.preview(source, settings: protected))
    }
    func testMountNeverDrillsAndKeepsExistingBoreClear() throws {
        let source = try tray()
        let settings = ReinforcementSettings(kind: .mount, offset: SIMD3(6,6,1.8), size: SIMD3(8,8,8), boreDiameter: 3)
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: settings))
        // Fixtures are exported to STL once, like a CAD part, rather than re-exported from an earlier STL.
        let outer = Mesh.cube(center: Vector(10,10,10), size: Vector(20,20,20))
        let tray = outer.subtracting(Mesh.cube(center: Vector(10,10,12), size: Vector(16,16,20)))
        // Square bore is intentionally larger than the requested circular clearance.
        let bore = Mesh.cube(center: Vector(10,10,5), size: Vector(4,4,12))
        let withBore = try ReinforcementEngine.stl(tray.subtracting(bore).makeWatertight())
        XCTAssertThrowsError(try ReinforcementEngine.preview(withBore, settings: settings), "Must not shrink a larger existing opening at the mounting surface")
        let roundBore = ReinforcementEngine.boreClearance(settings).translated(by: Vector(6,6,-1))
        let roundSource = try ReinforcementEngine.stl(tray.subtracting(roundBore).makeWatertight())
        let result = try ReinforcementEngine.preview(roundSource, settings: settings)
        XCTAssertGreaterThan(result.addedVolume, 0)
        let core = Mesh.cube(center: Vector(10,10,5), size: Vector(2,2,12))
        XCTAssertEqual(try result.mesh.reinforcementSolid().intersection(core).signedVolume, 0, accuracy: 0.001)
    }
    func testMountFusesWithIndependentlyTessellatedFloatBore() throws {
        let outer = Mesh.cube(center: Vector(10,10,10), size: Vector(20,20,20))
        let tray = outer.subtracting(Mesh.cube(center: Vector(10,10,12), size: Vector(16,16,20)))
        let bore = Mesh.cylinder(radius: 1.6, height: 12, slices: 32).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(10,10,3))
        let native = tray.subtracting(bore)
        let source = try ReinforcementEngine.stl(native.makeWatertight())
        // Snapping Float STL vertices onto their faces must not change the solid.
        XCTAssertEqual(try source.reinforcementSolid().signedVolume, native.signedVolume, accuracy: 0.001)
        let settings = ReinforcementSettings(kind: .mount, offset: SIMD3(6,6,1.8), size: SIMD3(8,8,8), boreDiameter: 3.17)
        let result = try ReinforcementEngine.preview(source, settings: settings)
        XCTAssertGreaterThan(result.addedVolume, 0)
        XCTAssertEqual(result.removedVolume, 0, accuracy: 0.001)
        let core = Mesh.cylinder(radius: 1.5, height: 12, slices: 32).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(10,10,5))
        XCTAssertEqual(try result.mesh.reinforcementSolid().intersection(core).signedVolume, 0, accuracy: 0.001)
    }
    private func exportedOnce(_ mesh: Mesh) throws -> STLMesh { try ReinforcementEngine.stl(mesh.makeWatertight()) }
    private let cube20 = Mesh.cube(center: Vector(10,10,10), size: Vector(20,20,20))
    private func assertPreserved(_ result: ReinforcementPreview, _ source: STLMesh, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(result.mesh.minimum, source.minimum, file: file, line: line)
        XCTAssertEqual(result.mesh.maximum, source.maximum, file: file, line: line)
        XCTAssertTrue(try result.mesh.reinforcementSolid().isWatertight, file: file, line: line)
    }
    private func occupied(_ mesh: STLMesh, _ probe: Mesh) throws -> Double { try mesh.reinforcementSolid().intersection(probe).signedVolume }

    func testHoleRingOpensThroughTheBedAndKeepsBore() throws {
        let bore = Mesh.cylinder(radius: 1.6, height: 30, slices: 32).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(10,10,10))
        let source = try exportedOnce(cube20.subtracting(bore))
        let settings = ReinforcementSettings(kind: .holeRing, offset: SIMD3(4,4,0), size: SIMD3(12,12,12), boreDiameter: 3.17)
        let result = try ReinforcementEngine.preview(source, settings: settings)
        try assertPreserved(result, source)
        XCTAssertGreaterThan(result.removedVolume, 1)
        XCTAssertEqual(result.shellsAfter, result.shellsBefore, "The ring opens through the bed face, so it is no separate shell")
        let core = Mesh.cylinder(radius: 1.5, height: 30, slices: 32).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(10,10,10))
        XCTAssertEqual(try occupied(result.mesh, core), 0, accuracy: 0.001)
        // The gap is open at the bed face and closed by the cover at its top.
        let ring = Float(3.17) / 2 / cos(Float.pi / 48) + settings.thickness + settings.gapWidth / 2
        XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(10 + ring, 10, 0.1), in: result.mesh))
        XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(10 + ring, 10, 11.9), in: result.mesh))
        XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(10 + ring, 10, 12.1), in: result.mesh))
        XCTAssertThrowsError(try ReinforcementEngine.preview(block(), settings: settings), "No bore to ring")
        // A ring that starts above the bed would be a closed void.
        var raised = settings; raised.offset.z = 4
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: raised)) {
            XCTAssertTrue($0.localizedDescription.contains("position Z to 0"), $0.localizedDescription)
        }
    }
    func testTeardropRaisesHoleRoofOnly() throws {
        // Horizontal 4 mm hole along X at y = z = 10.
        let hole = Mesh.cylinder(radius: 2.0, height: 30, slices: 32).rotated(by: Rotation(roll: .halfPi)).translated(by: Vector(10,10,10))
        let source = try exportedOnce(cube20.subtracting(hole))
        XCTAssertEqual(try occupied(source, .cube(center: Vector(10,10,10), size: Vector(30,1,1))), 0, accuracy: 0.001, "Fixture hole runs along X")
        let settings = ReinforcementSettings(kind: .teardrop, offset: SIMD3(2,5,5), size: SIMD3(16,10,10), boreDiameter: 3.9)
        let result = try ReinforcementEngine.preview(source, settings: settings)
        try assertPreserved(result, source)
        XCTAssertGreaterThan(result.removedVolume, 1)
        XCTAssertEqual(result.addedVolume, 0)
        // Above the old roof is now open; below the hole is unchanged.
        XCTAssertEqual(try occupied(result.mesh, .cube(center: Vector(10,10,12.3), size: Vector(10,0.3,0.3))), 0, accuracy: 0.001)
        XCTAssertEqual(try occupied(result.mesh, .cube(center: Vector(10,10,7.5), size: Vector(10,0.3,0.3))), 0.9, accuracy: 0.001)
        var turned = settings; turned.quarterTurns = 1
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: turned), "Hole does not run along world Y")
        XCTAssertThrowsError(try ReinforcementEngine.preview(block(), settings: settings))
    }
    func testCounterboreBridgingCutsTwoLayersAtTheCeiling() throws {
        // 8 mm counterbore from the bed up to z = 5, then a 3 mm through-hole.
        let counterbore = Mesh.cylinder(radius: 4.1, height: 10, slices: 48).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(10,10,0))
        let through = Mesh.cylinder(radius: 1.55, height: 30, slices: 32).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(10,10,10))
        let source = try exportedOnce(cube20.subtracting(counterbore).subtracting(through))
        let settings = ReinforcementSettings(kind: .bridge, offset: SIMD3(6,6,5), size: SIMD3(8,8,1.2), boreDiameter: 3)
        let result = try ReinforcementEngine.preview(source, settings: settings)
        try assertPreserved(result, source)
        XCTAssertGreaterThan(result.removedVolume, 0.5)
        XCTAssertLessThan(result.removedVolume, 8*3*0.2 + 9*0.2)
        // The strip runs along X in the first layer only.
        XCTAssertEqual(try occupied(result.mesh, .cube(center: Vector(12.8,10,5.1), size: Vector(0.5,0.5,0.1))), 0, accuracy: 0.001)
        XCTAssertGreaterThan(try occupied(result.mesh, .cube(center: Vector(12.8,10,5.3), size: Vector(0.5,0.5,0.1))), 0.02)
        var high = settings; high.offset.z = 7
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: high), "Not at the ceiling")
    }
    func testOverhangChamferFillsUnderLedge() throws {
        let wall = Mesh.cube(center: Vector(10,2.5,10), size: Vector(20,5,20))
        let ledge = Mesh.cube(center: Vector(10,10,17.5), size: Vector(20,10,5))
        let source = try exportedOnce(wall.union(ledge))
        let settings = ReinforcementSettings(kind: .overhang, offset: SIMD3(5,4.8,10.2), size: SIMD3(10,5,5))
        let result = try ReinforcementEngine.preview(source, settings: settings)
        try assertPreserved(result, source)
        // A 5 mm 45° triangle along 10 mm, less the 0.2 mm overlaps into the wall and ledge.
        let triangle: Double = 5 * 5 / 2 * 10
        XCTAssertEqual(result.addedVolume, triangle - 18, accuracy: 2)
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: { var s = settings; s.orientation = .xUp; return s }()))
    }
    func testWallMatchingThickensToWholeLines() throws {
        let source = try tray() // 2 mm walls
        // Local +Y turned to world +X: thicken the x = 0..2 wall towards the cavity.
        let settings = ReinforcementSettings(kind: .thicken, offset: SIMD3(0,6,6), size: SIMD3(8,2,8), quarterTurns: 3, lineWidth: 0.45)
        let result = try ReinforcementEngine.preview(source, settings: settings)
        try assertPreserved(result, source)
        XCTAssertEqual(result.addedVolume, 0.25 * 8 * 8, accuracy: 0.05)
        XCTAssertGreaterThan(try occupied(result.mesh, .cube(center: Vector(2.2,10,10), size: Vector(0.1,1,1))), 0.099)
        var outward = settings; outward.quarterTurns = 1
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: outward), "Outside the model envelope")
        var matched = settings; matched.lineWidth = 0.5
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: matched), "Already 4 lines")
        var air = settings; air.offset.x = 4
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: air), "Centre not in a wall")
    }
    func testSplitMakesTwoClosedPartsWithMatchingPinHoles() throws {
        let source = try block()
        let settings = ReinforcementSettings(kind: .split, offset: SIMD3(2,6,5), size: SIMD3(16,8,10), thickness: 1.6, boreDiameter: 3)
        let result = try ReinforcementEngine.preview(source, settings: settings)
        let second = try XCTUnwrap(result.secondPart)
        XCTAssertEqual(result.mesh.maximum.z, 10, accuracy: 0.0001)
        XCTAssertEqual(second.minimum.z, 10, accuracy: 0.0001)
        let first = try result.mesh.reinforcementSolid(), top = try second.reinforcementSolid()
        XCTAssertTrue(first.isWatertight); XCTAssertTrue(top.isWatertight)
        XCTAssertEqual(first.signedVolume + top.signedVolume + result.removedVolume, 8000, accuracy: 0.01)
        XCTAssertGreaterThan(result.removedVolume, 2 * 2.0 * 10)
        // Matching blind holes either side of the cut, five mm deep.
        for z in [7.0, 13.0] { XCTAssertEqual(try occupied(z < 10 ? result.mesh : second, .cube(center: Vector(6,10,z), size: Vector(1,1,1))), 0, accuracy: 0.001) }
        XCTAssertNotNil(result.exploded)
        var outside = settings; outside.offset.z = 10.5
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: outside), "Pins break through the top")
    }
    func testNewTreatmentsKeepZUpAndLegacySettingsDecode() throws {
        for kind in [ReinforcementKind.shell, .holeRing, .teardrop, .bridge, .overhang, .thicken, .internalWalls] {
            let record = ReinforcementRecord(sourceID: UUID(), settings: ReinforcementSettings(kind: kind), addedVolumeMM3: 0, removedVolumeMM3: 0, created: Date())
            XCTAssertTrue(record.requiresZUp, kind.rawValue)
        }
        XCTAssertFalse(ReinforcementRecord(sourceID: UUID(), settings: ReinforcementSettings(kind: .split), addedVolumeMM3: 0, removedVolumeMM3: 0, created: Date()).requiresZUp)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(ReinforcementSettings(kind: .mount))) as? [String: Any])
        for key in ["quarterTurns", "gapWidth", "layerHeight", "lineWidth"] { XCTAssertNotNil(json.removeValue(forKey: key), key) }
        let legacy = try JSONDecoder().decode(ReinforcementSettings.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(legacy, ReinforcementSettings(kind: .mount))
    }
    func testInvalidInputsAndCancellationAreRejected() throws {
        let source = try tray()
        var invalid = ReinforcementSettings()
        invalid.thickness = .nan
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: invalid))
        invalid.thickness = 0.2
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: invalid))
        XCTAssertThrowsError(try ReinforcementEngine.preview(source, settings: .init(), cancelled: { true }))
        let open = STLMesh(vertices: Array(source.vertices.dropLast(9)), minimum: source.minimum, maximum: source.maximum)
        XCTAssertThrowsError(try open.reinforcementSolid())
    }
    func testSuggestionsFindAttachedRibAndRefuseCells() throws {
        let source = try tray()
        let settings = ReinforcementSettings(size: SIMD3(8,8,8))
        let suggestion = try ReinforcementEngine.suggestPosition(source, settings: settings)
        XCTAssertNoThrow(try ReinforcementEngine.preview(source, settings: suggestion))
        let cells = ReinforcementSettings(kind: .cells, size: SIMD3(8,8,8))
        XCTAssertThrowsError(try ReinforcementEngine.suggestPosition(block(), settings: cells), "Withdrawn: cells leave closed voids")
    }
    func testReversedFaceAndDuplicateShellAreRejected() throws {
        let source = try block()
        var vertices = source.vertices
        for i in 0..<3 { vertices.swapAt(3+i,6+i) }
        XCTAssertThrowsError(try STLMesh(vertices: vertices, minimum: source.minimum, maximum: source.maximum).reinforcementSolid())
        XCTAssertThrowsError(try STLMesh(vertices: source.vertices+source.vertices, minimum: source.minimum, maximum: source.maximum).reinforcementSolid())
    }

    func testMetadataRoundtripAndLegacyLibrary() throws {
        let settings = ReinforcementSettings(kind: .cells, protectedRegions: [ReinforcementBox(offset: .zero, size: .one)])
        let record = ReinforcementRecord(sourceID: UUID(), settings: settings, addedVolumeMM3: 0, removedVolumeMM3: 12, created: Date())
        let model = LocalModel(name: "test", filePath: "/tmp/test.stl", reinforcement: record)
        let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored.reinforcement, record)
        XCTAssertFalse(try XCTUnwrap(restored.reinforcement).testPrintApproved)
        let legacy = LocalModel(name: "old", filePath: "/tmp/old.stl")
        XCTAssertNil(try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(legacy)).reinforcement)
    }
}
