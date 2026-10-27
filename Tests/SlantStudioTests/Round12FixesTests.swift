import XCTest
import Euclid
import simd
@testable import SlantStudio

/// Round 12 review fixes.
final class Round12FixesTests: XCTestCase {
    private static let date = Date(timeIntervalSince1970: 1_800_000_000)

    /// `mesh` turned `degrees` about Z and moved by `offset`, in Float, so faces that were axis-aligned no longer are
    /// and their corners round off the plane.
    static func turned(_ mesh: STLMesh, degrees: Float, offset: SIMD3<Float>) throws -> STLMesh {
        let a = degrees * .pi / 180, c = cos(a), s = sin(a)
        var out: [Float] = []
        out.reserveCapacity(mesh.vertices.count)
        for i in stride(from: 0, to: mesh.vertices.count, by: 3) {
            let x = mesh.vertices[i], y = mesh.vertices[i + 1], z = mesh.vertices[i + 2]
            out += [x * c - y * s + offset.x, x * s + y * c + offset.y, z + offset.z]
        }
        return try STLMesh.validated(out)
    }

    // MARK: 4. Volume check on turned parts

    func testSmallHoleOnATurnedPartFarFromTheOriginGetsItsTeardrop() throws {
        // A wide end face (the volume error from rounding grows with its area) and a small hole (a small expected change).
        let block = try r12HoledBlock(SIMD3(60, 150, 90), xHoles: [r12Hole(SIMD2(75, 30), radius: 1.55, segments: 48)], zHoles: [])
        for degrees: Float in [30, 37, 53] {
            let source = try Self.turned(block, degrees: degrees, offset: SIMD3(170, 60, 0))
            let found = try teardropCandidates(in: source)
            XCTAssertEqual(found.filter(\.eligible).count, 1, "\(degrees)°: \(found)")
            let result = try teardropHolesCopy(of: source)
            XCTAssertNotNil(result.mesh, "\(degrees)°: \(String(describing: result.problem)) \(result.record.skipped)")
        }
    }

    // MARK: 7. A hole found again after bridging and chamfers rebuild the mesh

    /// A base with a pillar and a free ledge (which gets a chamfer under it), and a ⌀5 mm hole along X through the
    /// pillar, beside the ledge.
    static func ledgedPart() throws -> STLMesh {
        let hole = Mesh.cylinder(radius: 2.5, height: 30, slices: 48).rotated(by: Rotation(roll: .halfPi)).translated(by: Vector(20, 18, 16))
        let base = Mesh.cube(center: Vector(20, 20, 4), size: Vector(40, 40, 8))
        let pillar = Mesh.cube(center: Vector(20, 20, 16), size: Vector(20, 20, 16))
        let ledge = Mesh.cube(center: Vector(20, 35, 21.5), size: Vector(20, 10, 3))
        return try repairMesh(ReinforcementEngine.stl(base.union(pillar).union(ledge).subtracting(hole).makeWatertight())).mesh
    }

    func testTickedHoleIsFoundAgainAfterBridgingAndChamfers() throws {
        let source = try Self.ledgedPart()
        var input = PrintPreparationInput(sourceID: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!, sourceName: "Part",
                                          savedIntent: nil, internalWalls: false, automatic: false)
        input.bottomChamfer = false
        let first = try preparePrintReadyCopy(source, input: input, now: Self.date)
        XCTAssertTrue(first.record.appliedSteps.contains { $0.step == .treatments }, "The ledge gets its chamfer: \(first.record.steps.map(\.lines))")
        let offer = try printPreparationTeardropOffer(original: source, record: first.record)
        XCTAssertEqual(offer.eligible.count, 1, "\(offer.holes)")
        var follow = input
        follow.teardrops = printPreparationTeardropChoice(offer.eligible.map(\.key), record: first.record)
        let result = try preparePrintReadyCopy(source, input: follow, now: Self.date)
        XCTAssertNotNil(result.mesh, "\(String(describing: result.blocked))")
        XCTAssertEqual(result.record.teardropHoles?.count, 1)
        let step = try XCTUnwrap(result.record.steps.first { $0.step == .teardrops })
        XCTAssertNil(step.lines.first { $0.contains("couldn’t be found again") }, "\(step.lines)")
        XCTAssertTrue(result.record.appliedSteps.contains { $0.step == .treatments })
    }

    // MARK: 1. A teardrop job that saves no copy leaves the original's status alone

    private static func job(_ id: UUID, teardrops: Bool) -> PrintPreparationJob {
        PrintPreparationJob(modelID: id, url: URL(fileURLWithPath: "/tmp/\(id.uuidString).stl"), name: "Part", savedIntent: nil,
                            automatic: false, keptPlacement: nil,
                            teardrops: teardrops ? PrintPreparationTeardropChoice(holes: [], orientation: .zUp, placementStep: nil) : nil)
    }

    func testTeardropJobOutcomesGoToTheCopyUnlessACopyWasMade() {
        let tear = Self.job(UUID(), teardrops: true), plain = Self.job(UUID(), teardrops: false)
        for outcome: PrintPreparationStatus.Outcome in [.noCopy, .stopped, .nothingToChange] {
            XCTAssertFalse(printPreparationStatusGoesToOriginal(tear, status: PrintPreparationStatus(outcome: outcome, date: Self.date)), "\(outcome)")
            XCTAssertTrue(printPreparationStatusGoesToOriginal(plain, status: PrintPreparationStatus(outcome: outcome, date: Self.date)))
        }
        XCTAssertTrue(printPreparationStatusGoesToOriginal(tear, status: PrintPreparationStatus(outcome: .madeCopy, copyID: UUID(), date: Self.date)))
    }

    @MainActor func testStoppingAWaitingTeardropJobSaysSoOnTheCopy() {
        let queue = PrintPreparationQueue()
        let running = Self.job(UUID(), teardrops: false), waiting = Self.job(UUID(), teardrops: true)
        queue.enqueue(running)
        queue.enqueue(waiting)
        XCTAssertEqual(queue.teardropJob(for: waiting.modelID)?.running, false)
        queue.stop(modelID: waiting.modelID)
        XCTAssertNil(queue.teardropJob(for: waiting.modelID))
        XCTAssertEqual(queue.teardropOutcome, PrintPreparationTeardropOutcome(sourceID: waiting.modelID, message: "Stopped. Nothing was saved."))
        // Quit drops a waiting one the same way.
        let another = Self.job(UUID(), teardrops: true)
        queue.enqueue(another)
        queue.stopAll()
        XCTAssertEqual(queue.teardropOutcome?.sourceID, another.modelID)
        // A copy made clears it.
        queue.recordTeardropOutcome(sourceID: another.modelID, status: PrintPreparationStatus(outcome: .madeCopy, copyID: UUID(), date: Self.date))
        XCTAssertNil(queue.teardropOutcome)
    }

    // MARK: 2. Headings match across the 45° flip

    func testHeadingsCompareAsAxes() {
        XCTAssertEqual(teardropHeadingGap(-450, 1350), 0)
        XCTAssertEqual(teardropHeadingGap(-449, 1350), 1)
        XCTAssertEqual(teardropHeadingGap(1799, 0), 1)
        XCTAssertEqual(teardropHeadingGap(900, -900), 0)
        XCTAssertEqual(teardropHeadingGap(300, 310), 10)
        func hole(_ key: TeardropHoleKey) -> TeardropCandidate {
            TeardropCandidate(key: key, centre: .zero, axis: SIMD3(1, 0, 0), radiusMM: 2.5, startMM: 0, endMM: 10, through: true,
                              wallAboveMM: 5, skipped: nil, changeLow: .zero, changeHigh: .zero)
        }
        let ticked = TeardropHoleKey(centre: SIMD3(2000, 1000, 800), heading: -450, diameter: 500)
        let flipped = TeardropHoleKey(centre: SIMD3(2001, 1000, 800), heading: 1349, diameter: 500)
        XCTAssertEqual(printPreparationTeardropMatches(chosen: [ticked], found: [hole(flipped)]).keys, [flipped])
    }

    // MARK: 3. Side holes only when measured end to end

    func testCounterboredSideHoleIsListedOnlyWhereMeasured() throws {
        // A ⌀2 mm blind hole along Y with a drill-point floor: its far end isn't one flat face, so its length isn't
        // measured, and it's too small for a teardrop, a skip decided before the end is checked. A plain ⌀2 mm hole
        // along X beside it is measured.
        let block = Mesh.cube(center: Vector(20, 15, 10), size: Vector(40, 30, 20))
        let drilled = Mesh.cylinder(radius: 1, height: 25, slices: 32).translated(by: Vector(10, 7.5, 10))
            .union(Mesh.cone(radius: 1, height: 1, slices: 32).translated(by: Vector(10, 20.5, 10)))
        let plain = Mesh.cylinder(radius: 1, height: 50, slices: 32).rotated(by: Rotation(roll: .halfPi)).translated(by: Vector(20, 15, 4))
        let mesh = try repairMesh(ReinforcementEngine.stl(block.subtracting(drilled).subtracting(plain).makeWatertight())).mesh
        let candidates = try teardropCandidates(in: mesh)
        let along = { (c: TeardropCandidate) in abs(c.axis.y) > 0.99 }
        XCTAssertEqual(candidates.filter(along).map(\.measured), [false], "\(candidates.map { ($0.axis, $0.skipped as Any, $0.measured) })")
        XCTAssertEqual(candidates.filter(along).first?.skipped, .tooSmall)
        let side = try XCTUnwrap(fitCouponSideHoles(in: mesh))
        XCTAssertEqual(side.count, 1, "Only the measured hole: \(side)")
        XCTAssertEqual(side.first?.sizeMM.x ?? 0, 40, accuracy: 0.05)
    }

    // MARK: 4. Volume tolerance and its own reason

    func testVolumeToleranceGrowsWithTheRetriangulatedAreaAndHasItsOwnReason() {
        XCTAssertEqual(teardropVolumeTolerance(expectedMM3: 0.5, retriangulatedAreaMM2: 0, largestCoordinateMM: 100), 0.01)
        XCTAssertEqual(teardropVolumeTolerance(expectedMM3: 10, retriangulatedAreaMM2: 0, largestCoordinateMM: 100), 0.1, accuracy: 1e-12)
        let wide = teardropVolumeTolerance(expectedMM3: 0.5, retriangulatedAreaMM2: 6_000, largestCoordinateMM: 200)
        XCTAssertGreaterThan(wide, 0.01)
        XCTAssertLessThan(wide, 0.5, "Never so loose that a wrong shape passes")
        XCTAssertNotEqual(TeardropCopyProblem.volumeMismatch.message, TeardropCopyProblem.resultFailedChecks.message)
        XCTAssertFalse(TeardropCopyProblem.volumeMismatch.message.contains("mesh check"))
    }

    // MARK: 5. A damaged teardrop record still marks the copy

    func testDamagedTeardropRecordStillMarksTheCopy() throws {
        let original = LocalModel(name: "Owl", filePath: "/tmp/owl.stl")
        var record = PrintPreparationRecord(sourceID: original.id, sourceName: "Owl", created: Self.date,
                                            steps: [PrintPreparationStepRecord(step: .teardrops, applied: true, lines: ["x"])],
                                            orientation: .zUp, treatments: [], internalWalls: nil, notes: [])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as? [String: Any])
        json["teardropHoles"] = "damaged"
        record = try JSONDecoder().decode(PrintPreparationRecord.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(record.teardropHoles)
        XCTAssertTrue(record.hasTeardropHoles)
        let copy = LocalModel(name: "Owl (print-ready, teardrop holes)", filePath: "/tmp/t.stl", printPreparation: record)
        XCTAssertFalse(printPreparationTeardropOfferApplies(copy, library: [original, copy]), "Never offered twice")
        let lines = printPreparationAppliedLines(record) + [printPreparationCaption(record)]
        XCTAssertFalse(lines.contains { $0.contains(" 0 ") }, "\(lines)")
        XCTAssertTrue(printPreparationCautions(record).contains(printPreparationTeardropCaution))
    }

    // MARK: 6. The fillets follow-up adds no teardrop note

    func testFitAffectingRunAddsNoTeardropNote() throws {
        let block = try r12HoledBlock(SIMD3(40, 30, 20), xHoles: [r12Hole(SIMD2(15, 9), radius: 2.5, segments: 48)], zHoles: [])
        let result = try AutoImprover.improve(block, intent: PartIntent(purpose: .enclosure), orientation: .zUp, profile: .fitAffecting)
        XCTAssertFalse(result.manual.contains { $0.contains("teardrop") }, "\(result.manual)")
    }

    // MARK: 8, 22. Material hint

    func testMaterialHintNeverOnAPreparedCopyAndKeepCurrentStopsIt() {
        let petg = Record(values: ["id": "petg", "name": "PETG Black", "profile": "PETG", "available": true])
        let opm = Record(values: ["id": "opm", "name": "OPM Grey", "profile": "OPM", "available": true])
        let bracket = PartIntent(purpose: .bracket)
        XCTAssertEqual(materialPurposeHint(intent: bracket, isSTL: true, selectedFilamentID: "", filaments: [petg])?.profile, "PETG")
        XCTAssertNil(materialPurposeHint(intent: bracket, isSTL: true, selectedFilamentID: "", filaments: [petg], preparedCopy: true))
        let kept = materialIntentKeepingCurrent(bracket)
        XCTAssertEqual(kept.materialGoal, .keepCurrent)
        XCTAssertEqual(kept.purpose, .bracket)
        XCTAssertNil(materialPurposeHint(intent: kept, isSTL: true, selectedFilamentID: "", filaments: [petg]))
        let warm = materialPurposeHint(intent: PartIntent(purpose: .bracket, materialGoal: .warm), isSTL: true, selectedFilamentID: "", filaments: [opm])
        XCTAssertEqual(warm?.profile, "OPM")
        XCTAssertTrue(warm?.message.contains("large flat parts can lift at the corners") == true, warm?.message ?? "")
    }

    // MARK: 10, 11, 12, 18, 19. Wording

    func testTeardropWordingIsRelativeAndFollowsTheSettings() throws {
        let texts = [teardropReviewNote(eligibleCount: 1) ?? "", teardropReviewNote(eligibleCount: 2) ?? "", printPreparationTeardropOfferLine(count: 2),
                     TeardropSkipReason.tooSmall.message, TeardropSkipReason.thinWall.message, ReinforcementKind.teardrop.explanation,
                     teardropHolesSummary(TeardropHolesRecord(holes: [TeardropHoleRecord(diameterMM: 5, lengthMM: 40, through: true, axis: "X", centreMM: [1, 2, 3])],
                                                              skipped: [], removedVolumeMM3: 1)),
                     printPreparationTeardropCaution, teardropTickCaption, printPreparationTeardropConfirmText(PrintPreparationSettings(), decorative: false)]
        for text in texts {
            XCTAssertFalse(text.contains("without drooping"), text)
            XCTAssertFalse(text.lowercased().contains("shoulder"), text)
            XCTAssertFalse(text.contains("need to fit"), text)
        }
        XCTAssertTrue(TeardropSkipReason.tooSmall.message.contains("usually prints its top cleanly"))
        XCTAssertTrue(printPreparationTeardropOfferLine(count: 1).contains("less likely to droop"))
        XCTAssertTrue(teardropTickCaption.contains("don’t have to fit"))

        let all = printPreparationTeardropConfirmText(PrintPreparationSettings(), decorative: false)
        XCTAssertTrue(all.contains("adds the bottom-edge chamfer and internal walls round the new shapes"), all)
        let decorative = printPreparationTeardropConfirmText(PrintPreparationSettings(), decorative: true)
        XCTAssertTrue(decorative.contains("adds the bottom-edge chamfer round the new shapes"), decorative)
        let none = printPreparationTeardropConfirmText(PrintPreparationSettings(enabled: true, internalWalls: false, bottomChamfer: false), decorative: false)
        XCTAssertFalse(none.contains("adds the"), none)
        XCTAssertTrue(none.contains("repeats the earlier copy’s other steps"), none)

        XCTAssertNil(printPreparationFitChangingCaption(fillets: false, teardropHoles: 0))
        let filletsOnly = try XCTUnwrap(printPreparationFitChangingCaption(fillets: true, teardropHoles: 0))
        XCTAssertFalse(filletsOnly.contains("teardrop"))
        let both = try XCTUnwrap(printPreparationFitChangingCaption(fillets: true, teardropHoles: 2))
        XCTAssertTrue(both.contains("2 horizontal round holes could take a teardrop roof"))
        XCTAssertTrue(both.contains("add teardrop holes first"))
        XCTAssertFalse(try XCTUnwrap(printPreparationFitChangingCaption(fillets: false, teardropHoles: 1)).contains("first"))
        XCTAssertTrue(reinforceTeardropOnPrintReadyCopyNote.contains("Add Teardrop Holes…"))
    }

    // MARK: 13, 14. Lay It Flat

    func testLayFlatSaysHowToSaveAndTheAdvisoryNamesIt() throws {
        XCTAssertTrue(layFlatSetLine.hasPrefix("Stress direction set."))
        XCTAssertTrue(layFlatSetLine.hasSuffix(layFlatSaveLine.replacingOccurrences(of: "Then use", with: "Use")))
        let advisory = try XCTUnwrap(printAdvisoryMessage(.slenderUpright, values: [10, 10, 10, 30, 3], onCopy: true))
        XCTAssertTrue(advisory.contains("Lay It Flat Along Its Length… in Optimise for purpose on the original"), advisory)
        XCTAssertTrue(advisory.contains("rib or gusset"), advisory)
        for word in ["strong", "safe", "%"] { XCTAssertFalse(advisory.lowercased().contains(word), word) }
    }

    // MARK: 15, 16, 20, 21. Coupons and labels

    func testCouponOrderTallNoteRefusalsHintAndHoleLabels() throws {
        XCTAssertNil(fitCouponTallPieceNote(heightMM: 20))
        XCTAssertEqual(fitCouponTallPieceNote(heightMM: 34.4), "Coupons suit features near the bed; this piece is 34 mm tall.")
        // A 40 mm tall block with a through bed hole (a piece the full height) and a side hole near the bed.
        let tall = try r12HoledBlock(SIMD3(40, 30, 40), xHoles: [r12Hole(SIMD2(20, 6), radius: 2, segments: 32)],
                                     zHoles: [r12Hole(SIMD2(10, 10), radius: 2, segments: 32)])
        let features = try XCTUnwrap(fitCouponFeatures(in: tall))
        XCTAssertEqual(features.map(\.kind), [.sideHole, .hole], "\(features.map(\.label))")
        for error in [FitCouponError.notClosedSolid, .missesModel, .noBedFace, .failedChecks] {
            let text = error.errorDescription ?? ""
            XCTAssertFalse(text.contains("box"), text)
            XCTAssertFalse(text.contains("mesh check above"), text)
        }
        XCTAssertTrue(FitCouponError.notClosedSolid.errorDescription?.contains("Use Repair & Save Copy first") == true)
        XCTAssertTrue(FitCouponError.noBedFace.errorDescription?.contains("Bottom slice") == true)
        XCTAssertTrue(fitCouponPrintReadyHint.contains("same placement and changes"))
        XCTAssertTrue(fitCouponPrintReadyHint.contains("standing up and lying down"))

        let block = try PrintPreparationTeardropTests.block()
        let hole = try XCTUnwrap(try teardropCandidates(in: block).first)
        XCTAssertEqual(teardropCandidateLabel(hole, low: block.minimum, high: block.maximum), "5.0 mm through hole in the middle, along X")
        XCTAssertTrue(teardropCandidateDetail(hole, minimum: block.minimum).contains("centre Y 10.0, Z 8.0"))
    }
}
