import XCTest
import Euclid
import simd
@testable import SlantStudio

/// Round 11 review fixes: pockets, the walls step's limit, review overhangs, bores, the chamfer, lineage and decoding.
final class PrintPreparationReviewFixesTests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private func cuboid(_ low: SIMD3<Float>, _ high: SIMD3<Float>, inward: Bool = false) throws -> [Float] {
        try r11PrismSoup(r11Rectangle(SIMD2(low.x, low.y), SIMD2(high.x, high.y)), from: low.z, to: high.z, inward: inward)
    }
    private func health(_ mesh: STLMesh) throws -> MeshHealthReport { try XCTUnwrap(analyzeMeshHealth(mesh)) }
    private func exported(_ mesh: Mesh) throws -> STLMesh { try repairMesh(ReinforcementEngine.stl(mesh.makeWatertight())).mesh }
    private func box(_ low: SIMD3<Double>, _ high: SIMD3<Double>) -> Mesh {
        let size = high - low, centre = (low + high) / 2
        return .cube(center: Vector(centre.x, centre.y, centre.z), size: Vector(size.x, size.y, size.z))
    }
    private func cylinder(_ x: Double, _ y: Double, radius: Double, _ z0: Double, _ z1: Double) -> Mesh {
        Mesh.cylinder(radius: radius, height: z1 - z0, slices: 32).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(x, y, (z0 + z1) / 2))
    }
    private func input(_ intent: PartIntent? = nil, wallsTimeLimit: TimeInterval = printPreparationWallsTimeLimit) -> PrintPreparationInput {
        var input = PrintPreparationInput(sourceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, sourceName: "Part",
                                          savedIntent: intent, internalWalls: true)
        input.wallsTimeLimit = wallsTimeLimit
        return input
    }

    // MARK: 7. A fill confirms every corner of what it removes

    func testFillRefusesAShellThatCrossesItsPart() throws {
        // A block with a slot cut into one side, and an inward, many-sided "pocket" with one top corner pushed out into
        // that slot: inside the block's bounds but outside its material, and a corner the 32 samples that place a shell
        // (the first corner of evenly spaced triangles) don't include.
        let notched: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(40, 0), SIMD2(40, 40), SIMD2(22, 40), SIMD2(22, 30), SIMD2(18, 30),
                                       SIMD2(18, 40), SIMD2(0, 40)]
        let block = try r11PrismSoup(notched, to: 20)
        var inner = try r11PrismSoup(r11Circle(SIMD2(20, 20), radius: 5, segments: 256), from: 5, to: 15, inward: true)
        let triangles = inner.count / 9, stride = max(1, triangles / hiddenPocketsSamplesPerShell)
        var sampled = Set<SIMD3<Float>>()
        for t in Swift.stride(from: 0, to: triangles, by: stride).prefix(hiddenPocketsSamplesPerShell) {
            sampled.insert(SIMD3(inner[t * 9], inner[t * 9 + 1], inner[t * 9 + 2]))
        }
        let moved = try XCTUnwrap((0..<(inner.count / 3)).map { SIMD3(inner[$0 * 3], inner[$0 * 3 + 1], inner[$0 * 3 + 2]) }
            .first { $0.z == 15 && !sampled.contains($0) && abs($0.x - 20) < 1 && $0.y > 24 })
        for k in Swift.stride(from: 0, to: inner.count, by: 3) where SIMD3(inner[k], inner[k + 1], inner[k + 2]) == moved { inner[k + 1] = 33 }
        let source = try STLMesh.validated(block + inner)
        XCTAssertTrue(meshHealthIsSound(try health(source)))
        // The sampled classification takes it for a pocket…
        XCTAssertEqual(try hiddenPocketsReport(source).count, 1)
        // …but the fill tests every corner and refuses, so the part's surface is never changed by a wrong removal.
        let result = try fillHiddenPocketsCopy(of: source)
        XCTAssertNil(result.mesh)
        XCTAssertEqual(result.skipped, .couldNotConfirm)
        XCTAssertTrue(HiddenPocketsSkipReason.couldNotConfirm.message.hasPrefix("The pockets weren’t filled"))
        // A real pocket is filled: the volume grows by exactly the pocket's, independently of the shell count.
        let good = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + r11PrismSoup(r11Circle(SIMD2(20, 20), radius: 5, segments: 256),
                                                                                          from: 5, to: 15, inward: true))
        let filled = try XCTUnwrap(try fillHiddenPocketsCopy(of: good).mesh)
        XCTAssertEqual(try health(filled).signedVolume, 32_000, accuracy: 0.01)
    }

    func testPocketInsideASolidInsideAPocket() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(60, 60, 20)) + cuboid(SIMD3(10, 10, 2), SIMD3(50, 50, 18), inward: true)
                                           + cuboid(SIMD3(15, 15, 4), SIMD3(45, 45, 16)) + cuboid(SIMD3(20, 20, 6), SIMD3(40, 40, 14), inward: true))
        let report = try hiddenPocketsReport(source)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.shellsInsidePockets, 2)
        XCTAssertEqual(report.removableBodies, 3)
        let filled = try XCTUnwrap(try fillHiddenPocketsCopy(of: source).mesh)
        let after = try health(filled)
        XCTAssertEqual(after.shells, 1)
        XCTAssertEqual(after.signedVolume, 60 * 60 * 20, accuracy: 0.01)
        XCTAssertTrue(try XCTUnwrap(hiddenPocketsSummary(report)).contains("Filling removes the loose parts inside them."))
    }

    // MARK: 10. Many shells are bounded

    func testTooManyPartsLeaveTheCheckIncomplete() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + cuboid(SIMD3(15, 15, 5), SIMD3(25, 25, 15), inward: true))
        let cut = try hiddenPocketsReport(source, boxComparisonLimit: 2)
        XCTAssertFalse(cut.complete)
        XCTAssertEqual(cut.count, 0)
        XCTAssertNil(hiddenPocketsSummary(cut))
        XCTAssertTrue(hiddenPocketsIncompleteLine.contains("too many separate parts to check"))
        XCTAssertTrue(try hiddenPocketsReport(source).complete)
        // The copy's record keeps the flag, and its line isn't a pocket count.
        let pockets = PrintPreparationPockets(count: 0, shellsInside: 0, addedVolumeMM3: 0, incomplete: true)
        XCTAssertNil(hiddenPocketsLine(pockets))
        let decoded = try JSONDecoder().decode(PrintPreparationPockets.self, from: JSONEncoder().encode(pockets))
        XCTAssertEqual(decoded.incomplete, true)
    }

    // MARK: 9. The walls step's time limit and many features

    func testTimedOutWallsStepSavesNothing() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)))
        XCTAssertThrowsError(try preparePrintReadyCopy(source, input: input(PartIntent(purpose: .enclosure), wallsTimeLimit: 0), now: fixedDate)) {
            XCTAssertEqual($0 as? PrintPreparationError, .wallsTookTooLong)
            // It says what to change, never just "try again".
            let message = $0.localizedDescription
            XCTAssertTrue(message.contains("Turn off Add internal walls") && message.contains("simplify a copy"), message)
            XCTAssertFalse(message.lowercased().contains("again"), message)
        }
        XCTAssertEqual(printPreparationWallsTimeLimit, 120)
    }

    private func grille(bars: Int) throws -> STLMesh {
        var shape = box(SIMD3(0, 0, 0), SIMD3(Double(bars) * 8 + 8, 30, 4))
        for k in 0..<bars {
            let x = Double(k) * 8 + 6
            shape = shape.union(box(SIMD3(x, 0, 4), SIMD3(x + 3, 30, 20)))
        }
        return try exported(shape)
    }

    func testGrilleBarsEachGetAThinSectionSlot() throws {
        let source = try grille(bars: 5)
        var options = InternalWallsOptions()
        options.plan = .targeted
        let start = Date()
        let result = try internalWallsCopy(of: source, options: options)
        print(String(format: "Grille of 5 bars: %.2f s", Date().timeIntervalSince(start)))
        XCTAssertEqual(result.count(of: .thinSlot), 5, "\(internalWallsSkipNotes(result))")
        XCTAssertEqual(try health(XCTUnwrap(result.mesh)).shells, 1)
    }

    /// Opt-in timing (set SLANT_WALLS_BENCH=1): a grille of 40 bars, every one a feature that later walls keep clear of.
    func testGrilleTiming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SLANT_WALLS_BENCH"] == "1", "Set SLANT_WALLS_BENCH=1 to time a feature-heavy grille.")
        let source = try grille(bars: 40)
        var options = InternalWallsOptions()
        options.plan = .all
        let start = Date()
        let result = try internalWallsCopy(of: source, options: options)
        print(String(format: "Grille timing: %d triangles, %.2f s, thin %d, bulk %d", source.triangleCount, Date().timeIntervalSince(start),
                     result.count(of: .thinSlot), result.count(of: .bulkSlot)))
        XCTAssertEqual(result.count(of: .thinSlot), 40)
    }

    // MARK: 8. Review for Printing and Studio's own chamfer and ceilings

    func testReviewDoesNotCountStudiosChamferOrWallCeilings() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)))
        let result = try preparePrintReadyCopy(source, input: input(PartIntent(purpose: .enclosure)), now: fixedDate)
        let copy = try XCTUnwrap(result.mesh)
        XCTAssertNotNil(result.record.bottomChamfer)
        XCTAssertGreaterThan(result.record.internalWalls?.bulkSlots ?? 0, 0)
        // The plain 45° measure counts the chamfer band and the slot ceilings…
        XCTAssertGreaterThan(overhangShare(copy).overhangAreaMM2, 0)
        // …the review's doesn't.
        XCTAssertEqual(printReviewOverhangShare(copy, record: result.record).overhangAreaMM2, 0)
        let measured = try XCTUnwrap(measureForPrintReview(copy, record: result.record, wallSamples: 200))
        XCTAssertEqual(measured.overhang.overhangAreaMM2, 0)
        // A real overhang still counts on a copy: a wide flat ceiling isn't a slot's.
        let ledge = try exported(box(SIMD3(0, 0, 0), SIMD3(20, 5, 20)).union(box(SIMD3(0, 5, 15), SIMD3(20, 15, 20))))
        XCTAssertGreaterThan(printReviewOverhangShare(ledge, record: result.record).overhangAreaMM2, 150)
        XCTAssertEqual(printReviewNarrowCeilings(ledge).filter { $0 }.count, 0)
    }

    // MARK: 15. Drafted bores and hollow bosses

    func testDraftedBoreKeepsItsRing() throws {
        var vertices = try r11PrismSoup(r11Rectangle(.zero, SIMD2(40, 40)), holes: [r11Circle(SIMD2(20, 20), radius: 3, segments: 32)], to: 20)
        // Widen the bore's top by about 0.8° of draft.
        for k in stride(from: 0, to: vertices.count, by: 3) where vertices[k + 2] == 20 {
            let d = SIMD2(vertices[k], vertices[k + 1]) - SIMD2(20, 20)
            if simd_length(d) < 3.01 {
                let wider = SIMD2<Float>(20, 20) + d * (3.28 / 3)
                vertices[k] = wider.x; vertices[k + 1] = wider.y
            }
        }
        let source = try STLMesh.validated(vertices)
        XCTAssertTrue(meshHealthIsSound(try health(source)))
        var options = InternalWallsOptions()
        options.plan = .targeted
        let result = try internalWallsCopy(of: source, options: options)
        XCTAssertEqual(result.rings.count, 1, "\(internalWallsSkipNotes(result))")
        XCTAssertEqual(try health(XCTUnwrap(result.mesh)).shells, 1)
        let cylinder = InternalWallsCylinder(centre: SIMD2(20, 20), radius: 3.02)
        let corners = (0..<source.triangleCount).flatMap { t in (0..<3).map { j in
            SIMD3(source.vertices[t * 9 + j * 3], source.vertices[t * 9 + j * 3 + 1], source.vertices[t * 9 + j * 3 + 2]) } }
        let draft = internalWallsBoreDraft(cylinder, corners: corners, floor: 0)
        XCTAssertEqual(draft, 0.26 / 20, accuracy: 0.002)
        // A straight bore measures no draft.
        let straight = try r11PrismSoup(r11Rectangle(.zero, SIMD2(40, 40)), holes: [r11Circle(SIMD2(20, 20), radius: 3, segments: 32)], to: 20)
        let straightCorners = stride(from: 0, to: straight.count, by: 3).map { SIMD3(straight[$0], straight[$0 + 1], straight[$0 + 2]) }
        XCTAssertEqual(internalWallsBoreDraft(cylinder, corners: straightCorners, floor: 0), 0)
    }

    func testHollowBossSaysWhyItGetsNoPinSlot() throws {
        let source = try exported(box(SIMD3(0, 0, 0), SIMD3(30, 30, 5)).union(cylinder(15, 15, radius: 3.5, 5, 17))
            .subtracting(cylinder(15, 15, radius: 1.5, 4.5, 20)))
        var options = InternalWallsOptions()
        options.plan = .targeted
        let result = try internalWallsCopy(of: source, options: options)
        XCTAssertEqual(result.count(of: .pinSlot), 0)
        XCTAssertEqual(result.report(.pinSlot)?.count(.hollow), 1, "\(internalWallsSkipNotes(result))")
        XCTAssertTrue(internalWallsSkipNotes(result).contains { $0.contains("hollow") }, "\(internalWallsSkipNotes(result))")
    }

    // MARK: 14. A recess in the bed face

    func testShallowRecessAtTheBedEdgeHasItsOwnReason() throws {
        let source = try exported(box(SIMD3(0, 0, 0), SIMD3(40, 40, 10)).subtracting(box(SIMD3(10, -1, -1), SIMD3(20, 5, 0.2))))
        let result = try bottomChamferCopy(of: source)
        XCTAssertEqual(result.skipped, .recessInBedFace)
        XCTAssertEqual(BottomChamferSkipReason.recessInBedFace.message, "No bottom chamfer was added: the bottom face has a shallow recess or step.")
    }

    // MARK: 12–13, 6, 17. Loads, placements, lineage and decoding

    func testTurnedRecipeKeepsAHorizontalLoad() {
        let recipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "P", intent: PartIntent(purpose: .bracket, load: .x),
                                         orientation: .turned(.zUp, degrees: 20), materialID: nil, created: fixedDate)
        XCTAssertEqual(designEditIntent(LocalModel(name: "P", filePath: "/tmp/p.stl", printRecipe: recipe))?.load, .x)
        let flipped = PreparedPrintRecipe(sourceID: UUID(), sourceName: "P", intent: PartIntent(purpose: .bracket, load: .x),
                                          orientation: .turned(.xUp, degrees: -12), materialID: nil, created: fixedDate)
        XCTAssertEqual(designEditIntent(LocalModel(name: "P", filePath: "/tmp/p.stl", printRecipe: flipped))?.load, .z)
    }

    func testAutoImproveKeepsAReplicasPlacement() {
        XCTAssertTrue(autoImproveKeepsPlacement(LocalModel(name: "Owl (replica)", filePath: "/tmp/o.stl", keepsPlacement: true)))
        XCTAssertFalse(autoImproveKeepsPlacement(LocalModel(name: "Owl", filePath: "/tmp/o.stl")))
    }

    func testCopiesOfPrintReadyCopiesAreMarkedAndNeverPreparedAgain() {
        let derived = LocalModel(name: "P (print-ready) (repaired)", filePath: "/tmp/d.stl", inheritsZUpLock: true, fromPrintReadyCopy: true)
        XCTAssertTrue(derived.derivesFromPrintReadyCopy)
        XCTAssertEqual(printPreparationManualBlockedReason(derived), printPreparationFromCopyBlocked)
        XCTAssertNil(printPreparationManualBlockedReason(LocalModel(name: "P", filePath: "/tmp/p.stl")))
        // A fill on a print-ready copy keeps its record, with the pockets now filled.
        var record = PrintPreparationRecord(sourceID: UUID(), sourceName: "P", created: fixedDate, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: [])
        record.hiddenPockets = PrintPreparationPockets(count: 2, shellsInside: 0, addedVolumeMM3: 2000)
        let kept = printPreparationRecordAfterFill(record, filled: 2)
        XCTAssertEqual(kept.sourceID, record.sourceID)
        XCTAssertEqual(kept.hiddenPockets?.count, 0)
        XCTAssertNil(hiddenPocketsLine(try! XCTUnwrap(kept.hiddenPockets)))
        XCTAssertEqual(printPreparationPocketsFilledLine(kept.hiddenPockets!), "Hidden pockets filled: 2, with Fill Hidden Pockets.")
        let filledCopy = LocalModel(name: "P (print-ready) (pockets filled)", filePath: "/tmp/f.stl", printPreparation: kept, filledPockets: true)
        XCTAssertNotNil(printPreparationManualBlockedReason(filledCopy))
        XCTAssertTrue(filledCopy.requiresZUp)
    }

    func testLibraryDropsOnlyARecordItCantRead() throws {
        let id = UUID().uuidString
        let json = """
        [{"id":"\(id)","name":"Turned","filePath":"/tmp/t.stl","added":0,"partIntent":{"purpose":"Bracket","details":"","load":"Original X"},
          "printRecipe":{"sourceID":"\(UUID().uuidString)","sourceName":"P","intent":{"purpose":"Bracket","details":"","load":"Original X"},
                         "orientation":{"aLaterKind":true},"created":0}},
         {"id":"\(UUID().uuidString)","name":"Plain","filePath":"/tmp/p.stl","added":0}]
        """
        let models = try JSONDecoder().decode([LocalModel].self, from: Data(json.utf8))
        XCTAssertEqual(models.count, 2)
        XCTAssertNil(models[0].printRecipe)
        XCTAssertEqual(models[0].partIntent?.purpose, .bracket)
        XCTAssertTrue(models[0].requiresZUp, "A record that can't be read may have locked the copy, so the lock stays")
        XCTAssertFalse(models[1].requiresZUp)
        // A turned placement round-trips in this build.
        let recipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "P", intent: PartIntent(), orientation: .turned(.yUp, degrees: 15),
                                         materialID: nil, created: fixedDate)
        let model = LocalModel(name: "R", filePath: "/tmp/r.stl", printRecipe: recipe, fromPrintReadyCopy: true)
        let back = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(back.printRecipe?.orientation, .turned(.yUp, degrees: 15))
        XCTAssertEqual(back.fromPrintReadyCopy, true)
    }

    // MARK: 18. The mesh check points to the pocket line

    func testMeshCheckBodyLinePointsToThePocketLine() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + cuboid(SIMD3(15, 15, 5), SIMD3(25, 25, 15), inward: true))
        let report = try health(source)
        let pockets = try hiddenPocketsReport(source)
        XCTAssertTrue(hiddenPocketsAccountForExtraBodies(report, pockets))
        let summary = meshHealthSummary(report, pocketsExplainBodies: true)
        XCTAssertTrue(summary.details.contains(meshBodyPocketsNote(bodies: 2)), "\(summary.details)")
        XCTAssertFalse(summary.details.joined().contains("$0.39"))
        // A separate part isn't a pocket: the usual cost line stays.
        let parts = try STLMesh.validated(cuboid(.zero, SIMD3(20, 20, 10)) + cuboid(SIMD3(30, 0, 0), SIMD3(50, 20, 10)))
        XCTAssertFalse(hiddenPocketsAccountForExtraBodies(try health(parts), try hiddenPocketsReport(parts)))
    }

    // MARK: Final batch

    func testFillRefusesWhenTheCheckIsIncomplete() throws {
        // A pocket with a loose solid inside it: with the budget spent, the solid would go unjudged and be buried.
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + cuboid(SIMD3(10, 10, 4), SIMD3(30, 30, 16), inward: true)
                                           + cuboid(SIMD3(15, 15, 6), SIMD3(25, 25, 14)))
        let cut = try fillHiddenPocketsCopy(of: source, boxComparisonLimit: 4)
        XCTAssertNil(cut.mesh)
        XCTAssertEqual(cut.skipped, .tooManyParts)
        XCTAssertTrue(HiddenPocketsSkipReason.tooManyParts.message.contains("too many separate parts to check"))
        XCTAssertNotNil(try fillHiddenPocketsCopy(of: source).mesh)
    }

    func testEveryStudioCopyCarriesItsLineage() {
        var record = PrintPreparationRecord(sourceID: UUID(), sourceName: "P", created: fixedDate, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: [])
        record.notes = []
        let printReady = LocalModel(name: "P (print-ready)", filePath: "/tmp/p.stl", printPreparation: record)
        let lineage = studioCopyLineage(printReady)
        XCTAssertTrue(lineage.inheritsZUpLock)
        XCTAssertTrue(lineage.fromPrintReadyCopy)
        XCTAssertFalse(lineage.keepsPlacement)
        let replica = studioCopyLineage(LocalModel(name: "Owl (replica)", filePath: "/tmp/o.stl", keepsPlacement: true))
        XCTAssertEqual([replica.inheritsZUpLock, replica.keepsPlacement, replica.fromPrintReadyCopy], [false, true, false])
        let derived = studioCopyLineage(LocalModel(name: "D", filePath: "/tmp/d.stl", inheritsZUpLock: true, fromPrintReadyCopy: true))
        XCTAssertTrue(derived.fromPrintReadyCopy)
    }

    func testReviewIgnoresCeilingsOnCopiesOfPrintReadyCopies() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)))
        let copy = try XCTUnwrap(preparePrintReadyCopy(source, input: input(PartIntent(purpose: .enclosure)), now: fixedDate).mesh)
        // A further copy has no record, but derives from a print-ready copy: its slot ceilings still aren't overhangs.
        XCTAssertGreaterThan(printReviewOverhangShare(copy, record: nil).overhangAreaMM2, 0)
        XCTAssertEqual(printReviewOverhangShare(copy, record: nil, fromPrintReadyCopy: true).overhangAreaMM2, 0)
    }

    func testIncompletePocketLineSaysNotEveryPartWasChecked() throws {
        let line = try XCTUnwrap(hiddenPocketsLine(PrintPreparationPockets(count: 1, shellsInside: 0, addedVolumeMM3: 1000, incomplete: true)))
        XCTAssertTrue(line.hasSuffix(hiddenPocketsIncompleteLine), line)
        XCTAssertFalse(try XCTUnwrap(hiddenPocketsLine(PrintPreparationPockets(count: 1, shellsInside: 0, addedVolumeMM3: 1000)))
            .contains(hiddenPocketsIncompleteLine))
    }

    @MainActor func testOnePocketAnalysisIsSharedPerModel() async {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0
            func add() { lock.withLock { value += 1 } }
            var count: Int { lock.withLock { value } }
        }
        let counter = Counter()
        let key = "shared-\(UUID().uuidString)"
        defer { HiddenPocketsCache.reports[key] = nil }
        let report = HiddenPocketsReport(shells: 1, pockets: [], separateParts: 1, shellsInsidePockets: 0, otherShells: 0,
                                         complete: true, addedVolumeMM3: 0)
        let analyse: @Sendable () -> HiddenPocketsReport? = {
            counter.add()
            Thread.sleep(forTimeInterval: 0.2)
            return report
        }
        async let first = hiddenPocketsSharedReport(key: key, analyse: analyse)
        async let second = hiddenPocketsSharedReport(key: key, analyse: analyse)
        let results = await [first, second]
        XCTAssertEqual(results, [report, report])
        XCTAssertEqual(counter.count, 1)
        XCTAssertNil(HiddenPocketsCache.running[key])
        // Cached afterwards: no further analysis.
        _ = await hiddenPocketsSharedReport(key: key, analyse: analyse)
        XCTAssertEqual(counter.count, 1)
    }
}
