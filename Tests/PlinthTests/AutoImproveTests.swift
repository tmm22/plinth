import XCTest
import Euclid
import simd
@testable import Plinth

final class AutoImproveTests: XCTestCase {
    private let cube20 = Mesh.cube(center: Vector(10,10,10), size: Vector(20,20,20))
    private func exported(_ mesh: Mesh) throws -> STLMesh { try ReinforcementEngine.stl(mesh.makeWatertight()) }
    /// 20 mm tray with 1.8 mm walls and a 2 mm floor, open at the top.
    private func tray() throws -> STLMesh {
        try exported(cube20.subtracting(Mesh.cube(center: Vector(10,10,12), size: Vector(16.4,16.4,20))))
    }
    private func kinds(_ result: AutoImprovementResult) -> [ReinforcementKind] { result.applied.map(\.settings.kind) }
    private func assertClosedAndEnveloped(_ result: AutoImprovementResult, _ source: STLMesh, file: StaticString = #filePath, line: UInt = #line) throws {
        let solid = try result.mesh.reinforcementSolid()
        XCTAssertTrue(solid.isWatertight, file: file, line: line)
        XCTAssertEqual(result.mesh.minimum, source.minimum, file: file, line: line)
        XCTAssertEqual(result.mesh.maximum, source.maximum, file: file, line: line)
    }

    func testTrayGetsMatchedInnerWallsAndInsideFillets() throws {
        let source = try tray()
        let result = try AutoImprover.improve(source, intent: PartIntent(purpose: .bracket, load: .x), orientation: .zUp)
        try assertClosedAndEnveloped(result, source)
        // 1.8 mm walls become four 0.5 mm lines (2 mm) on the inside only.
        XCTAssertEqual(kinds(result).filter { $0 == .thicken }.count, 4, "\(result.skipped)")
        XCTAssertEqual(kinds(result).filter { $0 == .fillet }.count, 8, "\(result.skipped)")
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
        // Sampled rather than Boolean-compared: subtracting near-identical meshes is itself unreliable.
        var points: [SIMD3<Float>] = []
        for x in stride(from: Float(0.37), to: 20, by: 1.1) { for y in stride(from: Float(0.41), to: 20, by: 1.1) { for z in stride(from: Float(0.43), to: 20, by: 1.1) { points.append(SIMD3(x, y, z)) } } }
        for p in points where ReinforcementEngine.containsMaterial(p, in: source) {
            XCTAssertTrue(ReinforcementEngine.containsMaterial(p, in: result.mesh), "Material removed at \(p)")
        }
        // Inner faces gain 0.2 mm, to 2 mm; the outside stays where it was.
        XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(1.95, 10, 10), in: source))
        XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(1.95, 10, 10), in: result.mesh))
        XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(2.05, 10, 10), in: result.mesh))
        for outside in [SIMD3<Float>(-0.05, 10, 10), SIMD3(10, 20.05, 10), SIMD3(10, 10, 20.05)] {
            XCTAssertFalse(ReinforcementEngine.containsMaterial(outside, in: result.mesh))
        }
        // The vertical inside corner is rounded.
        XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(2.2, 2.2, 10), in: result.mesh))
        XCTAssertTrue(result.changed)
    }

    func testDecorativePartsGetNoFillets() throws {
        let result = try AutoImprover.improve(try tray(), intent: PartIntent(purpose: .decorative), orientation: .zUp)
        XCTAssertFalse(kinds(result).contains(.fillet))
        XCTAssertTrue(kinds(result).contains(.thicken))
    }

    func testCounterboreIsBridgedAutomatically() throws {
        let counterbore = Mesh.cylinder(radius: 4.1, height: 10, slices: 48).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(10,10,0))
        let through = Mesh.cylinder(radius: 1.55, height: 30, slices: 32).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(10,10,10))
        let source = try exported(cube20.subtracting(counterbore).subtracting(through))
        let found = AutoImprover.candidates(.bridge, in: source, intent: PartIntent())
        XCTAssertEqual(found.candidates.count, 1)
        let result = try AutoImprover.improve(source, intent: PartIntent(), orientation: .zUp)
        try assertClosedAndEnveloped(result, source)
        XCTAssertEqual(kinds(result).filter { $0 == .bridge }.count, 1, "\(result.skipped)")
        XCTAssertTrue(result.manual.contains { $0.contains("vertical bore") })
        XCTAssertEqual(try result.mesh.reinforcementSolid().intersection(.cube(center: Vector(12.8,10,5.1), size: Vector(0.5,0.5,0.1))).signedVolume, 0, accuracy: 0.001)
    }

    func testCantileveredLedgeGetsChamferAndDeepLedgeIsReported() throws {
        let wall = Mesh.cube(center: Vector(10,2.5,10), size: Vector(20,5,20))
        let ledge = Mesh.cube(center: Vector(10,10,17.5), size: Vector(20,10,5))
        let source = try exported(wall.union(ledge))
        let result = try AutoImprover.improve(source, intent: PartIntent(), orientation: .zUp)
        try assertClosedAndEnveloped(result, source)
        XCTAssertEqual(kinds(result).filter { $0 == .overhang }.count, 1, "\(result.skipped)")
        // A full 10 mm 45° wedge under the 10 mm ledge, along 20 mm, less the overlaps.
        XCTAssertEqual(result.applied.first { $0.settings.kind == .overhang }!.addedVolumeMM3, 1000, accuracy: 60)
        XCTAssertEqual(try result.mesh.reinforcementSolid().intersection(.cube(center: Vector(10,6,14), size: Vector(1,1,1))).signedVolume, 1, accuracy: 0.001)

        let deep = try exported(Mesh.cube(center: Vector(10,2.5,15), size: Vector(20,5,30)).union(.cube(center: Vector(10,15,27.5), size: Vector(20,20,5))))
        let found = AutoImprover.candidates(.overhang, in: deep, intent: PartIntent())
        XCTAssertTrue(found.candidates.isEmpty)
        XCTAssertTrue(found.manual.contains { $0.contains("too deep") }, "\(found.manual)")
    }

    func testLedgeWithLessHeightBelowGetsAChamferWithinFiftyDegrees() throws {
        // A 10 mm ledge with 9 mm below it: too little for 45°, enough for Slant's 50° (8.4 mm).
        let wall = Mesh.cube(center: Vector(10,2.5,7), size: Vector(20,5,14))
        let ledge = Mesh.cube(center: Vector(10,10,11.5), size: Vector(20,10,5))
        let source = try exported(wall.union(ledge))
        let found = AutoImprover.candidates(.overhang, in: source, intent: PartIntent())
        XCTAssertEqual(found.candidates.count, 1, "\(found.manual)")
        // As tall as fits, 0.1 mm clear of the bed: 8.9 mm, about 48°.
        XCTAssertTrue(found.candidates[0].summary.hasSuffix("10.0 mm ledge along X at Z 9.0, 48° slope"), found.candidates[0].summary)
        let result = try AutoImprover.improve(source, intent: PartIntent(), orientation: .zUp, profile: .fitSafe)
        try assertClosedAndEnveloped(result, source)
        XCTAssertEqual(kinds(result), [.overhang], "\(result.skipped)")
        XCTAssertEqual(result.applied[0].addedVolumeMM3, 890, accuracy: 60)
        XCTAssertTrue(ReinforcementEngine.containsMaterial(SIMD3(10, 6, 6), in: result.mesh))
        XCTAssertFalse(ReinforcementEngine.containsMaterial(SIMD3(10, 14, 2), in: result.mesh))
        XCTAssertGreaterThan(result.mesh.minimum.z, -0.0001)

        // 8 mm below a 10 mm ledge is steeper than 50°: reported, not changed.
        let short = try exported(Mesh.cube(center: Vector(10,2.5,6.5), size: Vector(20,5,13)).union(.cube(center: Vector(10,10,10.5), size: Vector(20,10,5))))
        let shortFound = AutoImprover.candidates(.overhang, in: short, intent: PartIntent())
        XCTAssertTrue(shortFound.candidates.isEmpty)
        XCTAssertTrue(shortFound.manual.contains { $0.contains("too little height below it for a chamfer within Slant’s 50° overhang limit") }, "\(shortFound.manual)")
    }

    func testOverhangToolSlopesAcrossTheFullDepthOnlyWithinFiftyDegrees() throws {
        var settings = ReinforcementSettings(kind: .overhang)
        settings.size = SIMD3(10, 10, 9)
        XCTAssertEqual(abs(try ReinforcementEngine.tool(settings).signedVolume), 450, accuracy: 0.5, "Full depth, 9 mm tall")
        settings.size = SIMD3(10, 10, 10)
        XCTAssertEqual(abs(try ReinforcementEngine.tool(settings).signedVolume), 500, accuracy: 0.5, "45°")
        settings.size = SIMD3(10, 10, 8)
        XCTAssertEqual(abs(try ReinforcementEngine.tool(settings).signedVolume), 320, accuracy: 0.5, "Steeper than 50°: the 45° wedge of its height")
        settings.size = SIMD3(10, 8, 10)
        XCTAssertEqual(abs(try ReinforcementEngine.tool(settings).signedVolume), 320, accuracy: 0.5, "Taller than deep: 45°")
    }

    func testWallMatchingRoundsToHalfMillimetreLines() throws {
        XCTAssertEqual(AutoImprover.lineWidth, 0.5)
        let found = AutoImprover.candidates(.thicken, in: try tray(), intent: PartIntent())
        XCTAssertEqual(found.candidates.count, 4)
        XCTAssertTrue(found.candidates.allSatisfy { $0.summary.contains("1.80 mm wall facing") && $0.summary.hasSuffix("thickened to 2.00 mm") && $0.settings.lineWidth == 0.5 },
                      "\(found.candidates.map(\.summary))")
        // A 2 mm wall is already four whole lines.
        let even = try exported(cube20.subtracting(Mesh.cube(center: Vector(10,10,12), size: Vector(16,16,20))))
        XCTAssertTrue(AutoImprover.candidates(.thicken, in: even, intent: PartIntent()).candidates.isEmpty)
    }

    func testPlainBlockChangesNothingAndPointsToEdgeTreatments() throws {
        let source = try exported(cube20)
        let result = try AutoImprover.improve(source, intent: PartIntent(), orientation: .zUp)
        XCTAssertTrue(result.applied.isEmpty)
        XCTAssertFalse(result.changed)
        XCTAssertTrue(result.manual.contains { $0.contains("Design improvements") })
    }

    func testHorizontalHoleIsReportedNotChanged() throws {
        let hole = Mesh.cylinder(radius: 2.0, height: 30, slices: 32).rotated(by: Rotation(roll: .halfPi)).translated(by: Vector(10,10,10))
        let source = try exported(cube20.subtracting(hole))
        let result = try AutoImprover.improve(source, intent: PartIntent(), orientation: .zUp)
        XCTAssertFalse(kinds(result).contains(.teardrop))
        XCTAssertTrue(result.manual.contains { $0.contains("1 horizontal round hole") && $0.contains("Find Horizontal Holes") }, "\(result.manual)")
        // A hole too small for a teardrop gets no note.
        let small = Mesh.cylinder(radius: 1.0, height: 30, slices: 32).rotated(by: Rotation(roll: .halfPi)).translated(by: Vector(10,10,10))
        let smallResult = try AutoImprover.improve(try exported(cube20.subtracting(small)), intent: PartIntent(), orientation: .zUp)
        XCTAssertFalse(smallResult.manual.contains { $0.contains("horizontal round hole") }, "\(smallResult.manual)")
    }

    func testOrientationIsLockedForPreparedCopiesAndCancellationStops() throws {
        let source = try tray()
        XCTAssertEqual(AutoImprover.orientation(for: source, intent: PartIntent(), locked: true), .zUp)
        XCTAssertNil(AutoImprover.orientation(for: source, intent: PartIntent(purpose: .bracket), locked: false), "Bracket needs a stress direction")
        XCTAssertThrowsError(try AutoImprover.improve(source, intent: PartIntent(), orientation: .zUp, cancelled: { true }))
    }

    func testRecordRoundTripsAndLocksZUp() throws {
        let step = AutoImprovementStep(settings: ReinforcementSettings(kind: .thicken), summary: "Wall", addedVolumeMM3: 1, removedVolumeMM3: 0)
        let record = AutoImprovementRecord(sourceID: UUID(), orientation: .xUp, applied: [step], skipped: ["a"], manual: ["b"], created: Date())
        let model = LocalModel(name: "auto", filePath: "/tmp/auto.stl", autoImprovement: record)
        let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored.autoImprovement, record)
        XCTAssertTrue(restored.requiresZUp)
        XCTAssertFalse(LocalModel(name: "plain", filePath: "/tmp/plain.stl").requiresZUp)
    }
}
