import XCTest
import Euclid
import simd
@testable import SlantStudio

/// Round 10 review fixes for the print-ready copy, internal walls and the copy tools.
final class PrintPreparationFixesTests: XCTestCase {
    private func exported(_ mesh: Mesh) throws -> STLMesh { try ReinforcementEngine.stl(mesh.makeWatertight()) }
    private func block(_ x: Double, _ y: Double, _ z: Double) throws -> STLMesh {
        try exported(.cube(center: Vector(x / 2, y / 2, z / 2), size: Vector(x, y, z)))
    }
    /// A thick 40 × 40 × 8 mm base with a 20 mm pillar and a free 10 mm ledge sticking out at the top: it stays as
    /// placed, so the chamfer under the ledge and internal walls in the base both run end to end.
    private func ledgedBase() throws -> STLMesh {
        let base = Mesh.cube(center: Vector(20, 20, 4), size: Vector(40, 40, 8))
        let pillar = Mesh.cube(center: Vector(20, 20, 16), size: Vector(20, 20, 16))
        let ledge = Mesh.cube(center: Vector(20, 35, 21.5), size: Vector(20, 10, 3))
        return try exported(base.union(pillar).union(ledge))
    }
    private func input(walls: Bool = true, intent: PartIntent? = nil, automatic: Bool = true, kept: String? = nil) -> PrintPreparationInput {
        PrintPreparationInput(sourceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, sourceName: "Part",
                              savedIntent: intent, internalWalls: walls, automatic: automatic, keptPlacement: kept)
    }
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private func slottedBlock() throws -> STLMesh {
        try XCTUnwrap(internalWallsCopy(of: block(40, 40, 20)).mesh)
    }

    // MARK: 1. Lock propagation and shell refusals

    func testPlinthOnASlottedMeshIsRefused() throws {
        let slotted = try slottedBlock()
        XCTAssertThrowsError(try slotted.plinthCopy(PlinthSettings(shape: .rectangular, marginMM: 3, thicknessMM: 3, joinDepthMM: 0.5))) {
            XCTAssertEqual($0 as? MeshFitError, .addedParts, "\($0.localizedDescription)")
        }
        // The rule itself: a result with more parts than its input is refused, with a reason.
        let report = MeshHealthReport(triangleCount: 12, vertexCount: 8, openEdges: 0, nonManifoldEdges: 0, flippedEdges: 0,
                                      degenerateTriangles: 0, shells: 3, signedVolume: 10)
        XCTAssertEqual(meshFitResultProblem(report, inputZeroArea: 0, inputShells: 1), .addedParts)
        XCTAssertNil(meshFitResultProblem(report, inputZeroArea: 0, inputShells: 3))
        XCTAssertTrue(MeshFitError.addedParts.localizedDescription.contains("extra bodies"))
        XCTAssertTrue(MeshToolError.addedParts.localizedDescription.contains("no copy was made"))
    }

    func testSimplifyNeverAddsParts() throws {
        let slotted = try slottedBlock()
        let before = try XCTUnwrap(analyzeMeshHealth(slotted))
        var options = MeshSimplifyOptions()
        options.targetTriangles = 100
        do {
            let result = try simplifyMesh(slotted, options: options)
            XCTAssertLessThanOrEqual(result.after.shells, before.shells)
        } catch let error as MeshToolError {
            XCTAssertTrue([.addedParts, .openedSurface].contains(error), "\(error)")
        }
    }

    func testSlottedCopiesFurtherCopiesKeepTheZUpLock() throws {
        let record = PrintPreparationRecord(sourceID: UUID(), sourceName: "Part", created: fixedDate, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: [])
        let printReady = LocalModel(name: "Part (print-ready)", filePath: "/tmp/a.stl", printPreparation: record)
        let thicken = AutoImprovementStep(settings: ReinforcementSettings(kind: .thicken), summary: "Wall", addedVolumeMM3: 1, removedVolumeMM3: 0)
        let autoImproved = LocalModel(name: "Part-auto-improved", filePath: "/tmp/b.stl",
                                      autoImprovement: AutoImprovementRecord(sourceID: UUID(), orientation: .zUp, applied: [thicken],
                                                                             skipped: [], manual: [], created: fixedDate))
        for source in [printReady, autoImproved] {
            XCTAssertTrue(source.requiresZUp)
            // Prepared (Optimise & Save Copy), edge-edit, repair/simplify and Auto-improve copies carry these records.
            let copy = LocalModel(name: "Copy", filePath: "/tmp/c.stl", printRecipe: nil, designImprovement: nil,
                                  reinforcement: source.reinforcement, autoImprovement: source.autoImprovement,
                                  printPreparation: source.printPreparation)
            XCTAssertTrue(copy.requiresZUp, source.name)
            XCTAssertNotNil(meshFitEditBlockedReason(copy, tool: .plinth))
            XCTAssertNotNil(meshFitEditBlockedReason(copy, tool: .flatBase))
            XCTAssertNotNil(meshFitEditBlockedReason(copy, tool: .scale))
        }
        // A reinforced copy keeps the lock through its inherited flag.
        let reinforced = ReinforcementRecord(sourceID: UUID(), settings: ReinforcementSettings(kind: .fillet), addedVolumeMM3: 0,
                                             removedVolumeMM3: 0, created: fixedDate, inheritedCellRoofs: printReady.requiresZUp ? true : nil)
        XCTAssertTrue(LocalModel(name: "R", filePath: "/tmp/r.stl", reinforcement: reinforced).requiresZUp)
    }

    // MARK: 2–3. Copy lookup, manual runs and placement

    func testPrintReadyCopyLookupAndManualRule() {
        let original = LocalModel(name: "Part", filePath: "/tmp/p.stl")
        let record = PrintPreparationRecord(sourceID: original.id, sourceName: "Part", created: fixedDate, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: [])
        let copy = LocalModel(name: "Part (print-ready)", filePath: "/tmp/c.stl", printPreparation: record)
        XCTAssertNil(printReadyCopy(of: original, in: [original]))
        XCTAssertEqual(printReadyCopy(of: original, in: [copy, original])?.id, copy.id)
        XCTAssertNil(printPreparationManualBlockedReason(original))
        XCTAssertNotNil(printPreparationManualBlockedReason(copy))
        XCTAssertNotNil(printPreparationManualBlockedReason(LocalModel(name: "M", filePath: "/tmp/m.3mf")))
        // Studio's own copies are allowed manually, though never automatically.
        let scaled = LocalModel(name: "Part (scaled to 50 mm)", filePath: "/tmp/s.stl")
        XCTAssertNil(printPreparationManualBlockedReason(scaled))
        // The automatic never-twice rule doesn't apply to manual runs: the queue only refuses a model already queued.
        XCTAssertTrue(printPreparationAlreadyHandled(modelID: original.id, library: [copy, original], queuedThisSession: []))
    }

    func testKeptPlacementReasons() {
        let plain = LocalModel(name: "P", filePath: "/tmp/p.stl")
        XCTAssertNil(printPreparationKeptPlacementReason(plain, origin: .imported))
        XCTAssertNotNil(printPreparationKeptPlacementReason(plain, origin: .replica))
        XCTAssertNotNil(printPreparationKeptPlacementReason(LocalModel(name: "D", filePath: "/tmp/d.stl", partIntent: PartIntent(purpose: .decorative)), origin: .imported))
        let recipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "P", intent: PartIntent(), orientation: .xUp, materialID: nil, created: fixedDate)
        XCTAssertNotNil(printPreparationKeptPlacementReason(LocalModel(name: "R", filePath: "/tmp/r.stl", printRecipe: recipe), origin: nil))
        let plan = printPreparationPlan(triangles: 100, meshSound: true, internalWallsOn: true, decorative: true, keptPlacement: "Kept")
        XCTAssertEqual(plan[1].decision, .skip("Kept"))
        XCTAssertEqual(plan[3].decision, .skip(printPreparationWallsDecorative))
        XCTAssertTrue(printPreparationSetPurposeNote.contains("Make Print-Ready Copy"))
        XCTAssertTrue(printPreparationPlacementIntent(saved: nil).note.contains("Make Print-Ready Copy"))
    }

    func testReplicaAndDecorativeKeepTheirPlacement() throws {
        // A standing plate would be laid flat; a replica's kept placement leaves it as saved.
        let plate = try block(40, 10, 60)
        let kept = try preparePrintReadyCopy(plate, input: input(kept: printPreparationKeptPlacementReason(LocalModel(name: "R", filePath: "/tmp/r.stl"), origin: .replica)),
                                             now: fixedDate)
        XCTAssertEqual(kept.record.orientation, .zUp)
        XCTAssertFalse(kept.record.steps.first { $0.step == .orientation }!.applied)
        let decorative = try preparePrintReadyCopy(try block(40, 40, 20), input: input(intent: PartIntent(purpose: .decorative)), now: fixedDate)
        XCTAssertNil(decorative.record.internalWalls)
        XCTAssertEqual(decorative.record.steps.first { $0.step == .internalWalls }?.lines, [printPreparationWallsDecorative])
    }

    func testAutomaticRunWaitsForTheScaleCheck() throws {
        // 2 mm across: probably exported in inches or centimetres.
        let tiny = try block(2, 2, 1)
        let automatic = try preparePrintReadyCopy(tiny, input: input(), now: fixedDate)
        XCTAssertEqual(automatic.blocked, printPreparationScaleFirst)
        XCTAssertTrue(printPreparationScaleFirst.contains("Scale it first, then use Make Print-Ready Copy"))
        let manual = try preparePrintReadyCopy(tiny, input: input(automatic: false), now: fixedDate)
        XCTAssertNotEqual(manual.blocked, printPreparationScaleFirst)
    }

    // MARK: 4, 9, 11. Price, thin walls and cautions

    func testCopyTextsPriceCautionsAndThinAreas() throws {
        let result = try preparePrintReadyCopy(try ledgedBase(), input: input(), now: fixedDate)
        let record = result.record
        XCTAssertNil(result.blocked)
        XCTAssertGreaterThan(record.chamferCount, 0, "\(record.steps)")
        XCTAssertNotNil(record.internalWalls, "\(record.steps)")
        XCTAssertEqual(printPreparationPriceLine(record), printPreparationWallsPriceNote)
        XCTAssertTrue(printPreparationWallsPriceNote.contains("(25 Oct 2026)"))
        XCTAssertTrue(printPreparationCautions(record).contains(printPreparationChamferCaution))
        XCTAssertNotNil(record.thinAreasUnder1MM)
        var plain = record
        plain.internalWalls = nil
        plain.treatments = []
        XCTAssertEqual(printPreparationPriceLine(plain), printPreparationPriceNote)
        XCTAssertTrue(printPreparationCautions(plain).isEmpty)
        plain.thinAreasUnder1MM = 2
        XCTAssertEqual(printPreparationCautions(plain), ["2 areas thinner than 1 mm: Slant’s 1 mm walls may not print them well."])
        XCTAssertNil(printPreparationThinAreasLine(0))
        // The copy is still one sound part with the same footprint.
        let health = try XCTUnwrap(analyzeMeshHealth(XCTUnwrap(result.mesh)))
        XCTAssertTrue(meshHealthIsSound(health))
        XCTAssertEqual(health.shells, 1)
    }

    func testThinAreasAreClusteredAndAThinFinIsFound() throws {
        let fin = try exported(Mesh.cube(center: Vector(20, 20, 3), size: Vector(40, 40, 6))
            .union(.cube(center: Vector(20, 20, 16), size: Vector(30, 0.6, 20))))
        let report = try XCTUnwrap(analyzeWallThickness(fin, maximumSamples: printPreparationWallThicknessSamples))
        let count = printPreparationThinAreaCount(report)
        XCTAssertGreaterThan(count, 0)
        XCTAssertLessThan(count, report.thinSpots.count)
        let spots = WallThicknessReport(sampleCount: 3, measuredCount: 3, surfaceAreaMM2: 1, thinnestMM: 0.5, percentile5MM: 0.5, medianMM: 2,
                                        fractionUnder1MM: 0.6, fractionUnder2MM: 0.6, bands: [],
                                        thinSpots: [ThinSpot(point: .zero, thicknessMM: 0.5), ThinSpot(point: SIMD3(1, 0, 0), thicknessMM: 0.6),
                                                    ThinSpot(point: SIMD3(30, 0, 0), thicknessMM: 0.4), ThinSpot(point: SIMD3(60, 0, 0), thicknessMM: 1.5)],
                                        smallFeatures: [])
        XCTAssertEqual(printPreparationThinAreaCount(spots), 2)
    }

    // MARK: 6. Treatments end to end, and determinism

    func testTreatmentsRunEndToEndAndGiveTheSameBytes() throws {
        let source = try ledgedBase()
        let first = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        let second = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        let treatments = try XCTUnwrap(first.record.steps.first { $0.step == .treatments })
        XCTAssertTrue(treatments.applied, "\(treatments.lines)")
        XCTAssertEqual(first.record.orientation, .zUp, "The base stays on the bed")
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.record, second.record)
    }

    // MARK: 7, 10. Internal walls

    func testBridgingWorkLimitIsAFailureAndUnjoinableHolesAreNamed() throws {
        // An outline with one hole inside it.
        let points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10),
                                       SIMD2(4, 4), SIMD2(4, 6), SIMD2(6, 6), SIMD2(6, 4)]
        let loops = [[0, 1, 2, 3], [4, 5, 6, 7]]
        let joined = try internalWallsBridgedLoops(points: points, loops: loops)
        XCTAssertNotNil(joined.loops)
        XCTAssertFalse(joined.workLimitReached)
        let starved = try internalWallsBridgedLoops(points: points, loops: loops, workLimit: 1)
        XCTAssertNil(starved.loops)
        XCTAssertTrue(starved.workLimitReached)
        XCTAssertEqual(starved.unjoinedLoop, 1)
        // A hole outside every outline can't be joined: named, without the work-limit flag.
        let outside = points + [SIMD2(20, 20), SIMD2(20, 22), SIMD2(22, 22), SIMD2(22, 20)]
        let lost = try internalWallsBridgedLoops(points: outside, loops: loops + [[8, 9, 10, 11]])
        XCTAssertNil(lost.loops)
        XCTAssertEqual(lost.unjoinedLoop, 2)
        XCTAssertFalse(lost.workLimitReached)
        XCTAssertThrowsError(try internalWallsBridgedLoops(points: points, loops: loops, isCancelled: { true })) {
            XCTAssertEqual($0 as? InternalWallsError, .stopped)
        }
    }

    func testFiveMillimetreRegionsGetSlotsWithTheClearanceKept() throws {
        XCTAssertEqual(internalWallsMinimumRegionMM, 5)
        let bar = try block(60, 6, 12)
        let result = try internalWallsCopy(of: bar)
        XCTAssertGreaterThan(result.slotCount, 0, "\(String(describing: result.skipped))")
        // Every slot corner stays at least 2 mm from every surface but the bed face.
        var triangles: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
        for t in 0..<bar.triangleCount {
            let p = (0..<3).map { j in SIMD3(bar.vertices[t * 9 + j * 3], bar.vertices[t * 9 + j * 3 + 1], bar.vertices[t * 9 + j * 3 + 2]) }
            if p.allSatisfy({ $0.z <= 0.0001 }) { continue }
            triangles.append((p[0], p[1], p[2]))
        }
        for slot in result.slots {
            for fx in [Float(0), 0.5, 1] { for fy in [Float(0), 1] { for fz in [Float(0.01), 0.5, 1] {
                let p = slot.low + (slot.high - slot.low) * SIMD3(fx, fy, fz)
                let d = triangles.map { internalWallsPointTriangleDistanceSquared(p, $0.0, $0.1, $0.2) }.min()!.squareRoot()
                XCTAssertGreaterThanOrEqual(d, internalWallsClearanceMM - 0.001)
            } } }
        }
    }

    func testClosedCavityUnderThickRegionsKeepsItsPartsAndClearance() throws {
        let solid = Mesh.cube(center: Vector(25, 25, 10), size: Vector(50, 50, 20))
        let cavity = Mesh.cube(center: Vector(25, 25, 10), size: Vector(10, 10, 6))
        let source = try exported(solid.subtracting(cavity))
        let before = try XCTUnwrap(analyzeMeshHealth(source))
        let result = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        XCTAssertNil(result.blocked)
        let after = try XCTUnwrap(analyzeMeshHealth(XCTUnwrap(result.mesh)))
        XCTAssertEqual(after.shells, before.shells)
        let walls = try XCTUnwrap(internalWallsCopy(of: source))
        for slot in walls.slots {
            // The cavity is x, y 20–30 and z 7–13: every slot stays 2 mm clear of it.
            let gapX = max(20 - slot.high.x, slot.low.x - 30), gapY = max(20 - slot.high.y, slot.low.y - 30), gapZ = 7 - slot.high.z
            XCTAssertGreaterThanOrEqual(max(gapX, gapY, gapZ), internalWallsClearanceMM - 0.001)
        }
    }

    func testFitAffectingProfileOnASlottedCopyAddsNoParts() throws {
        let slotted = try slottedBlock()
        let result = try AutoImprover.improve(slotted, intent: PartIntent(), orientation: .zUp, profile: .fitAffecting)
        XCTAssertFalse(result.applied.contains { [.bridge, .overhang].contains($0.settings.kind) })
        let health = try XCTUnwrap(analyzeMeshHealth(result.mesh))
        XCTAssertEqual(health.shells, 1)
        XCTAssertTrue(health.isClosed)
    }

    // MARK: 12–15

    func testNoticeShowsOnceUntilDismissedAndReviewedCopiesAreDistinct() {
        XCTAssertTrue(printPreparationNoticeShouldShow(dismissed: false, automaticCopySavedThisSession: true))
        XCTAssertFalse(printPreparationNoticeShouldShow(dismissed: true, automaticCopySavedThisSession: true))
        XCTAssertFalse(printPreparationNoticeShouldShow(dismissed: false, automaticCopySavedThisSession: false))
        XCTAssertTrue(printPreparationNoticeText.contains("Settings › Design Tools"))
        XCTAssertEqual(reviewedCopyName("Owl"), "Owl (reviewed)")
        XCTAssertEqual(printReadyCopyName("Owl"), "Owl (print-ready)")
        XCTAssertTrue(printPreparationTookTooLong.contains("Make Print-Ready Copy"))
        XCTAssertEqual(PrintPreparationError.tookTooLong.localizedDescription, printPreparationTookTooLong)
    }
}
