import XCTest
import Euclid
import simd
@testable import SlantStudio

/// Round 11: the print-ready pipeline with the turn about Z, the bottom-edge chamfer, purpose-aware internal walls,
/// the copy's measurements and advisories, hidden pockets and Fill Hidden Pockets.
final class PrintPreparationRound11Tests: XCTestCase {
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)
    private func input(intent: PartIntent? = nil, walls: Bool = true, chamfer: Bool = true, kept: String? = nil) -> PrintPreparationInput {
        PrintPreparationInput(sourceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, sourceName: "Part",
                              savedIntent: intent, internalWalls: walls, automatic: true, keptPlacement: kept, bottomChamfer: chamfer)
    }
    private func cuboid(_ low: SIMD3<Float>, _ high: SIMD3<Float>, inward: Bool = false) throws -> [Float] {
        try r11PrismSoup(r11Rectangle(SIMD2(low.x, low.y), SIMD2(high.x, high.y)), from: low.z, to: high.z, inward: inward)
    }
    private func block() throws -> STLMesh { try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20))) }
    /// A 40 × 40 × 20 mm block with a 6 mm round through-hole in its middle.
    private func holedBlock() throws -> STLMesh {
        try STLMesh.validated(r11PrismSoup(r11Rectangle(.zero, SIMD2(40, 40)), holes: [r11Circle(SIMD2(20, 20), radius: 3, segments: 32)], to: 20))
    }
    /// The block with a closed 10 mm pocket in its middle: two shells.
    private func pocketedBlock() throws -> STLMesh {
        try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + cuboid(SIMD3(15, 15, 5), SIMD3(25, 25, 15), inward: true))
    }
    private func health(_ mesh: STLMesh) throws -> MeshHealthReport { try XCTUnwrap(analyzeMeshHealth(mesh)) }

    // MARK: Order: the chamfer, then the walls

    func testBlockGetsTheChamferThenWallsPlannedAgainstIt() throws {
        let source = try block()
        let result = try preparePrintReadyCopy(source, input: input(intent: PartIntent(purpose: .enclosure)), now: fixedDate)
        let record = result.record
        XCTAssertNil(result.blocked)
        XCTAssertEqual(record.appliedSteps.map(\.step), [.bottomChamfer, .internalWalls])
        let chamfer = try XCTUnwrap(record.bottomChamfer)
        XCTAssertEqual(chamfer.sizeMM, 0.4, accuracy: 0.001)
        XCTAssertEqual(chamfer.outlineLengthMM, 160, accuracy: 0.5)
        XCTAssertEqual(chamfer.keptHoleEntries, 0, "The walls come after the chamfer, so it sees no slot openings")
        let walls = try XCTUnwrap(record.internalWalls)
        XCTAssertGreaterThan(walls.bulkSlots, 0)
        // One sound part, the same bounding box, and nothing within 0.4 mm of the bed's old outline.
        let mesh = try XCTUnwrap(result.mesh)
        let after = try health(mesh)
        XCTAssertTrue(meshHealthIsSound(after))
        XCTAssertEqual(after.shells, 1)
        XCTAssertEqual(mesh.maximum - mesh.minimum, SIMD3<Float>(40, 40, 20))
        for t in 0..<mesh.triangleCount {
            for j in 0..<3 {
                let p = SIMD3(mesh.vertices[t * 9 + j * 3], mesh.vertices[t * 9 + j * 3 + 1], mesh.vertices[t * 9 + j * 3 + 2])
                guard p.z <= 0.0001 else { continue }
                XCTAssertTrue(p.x >= 0.399 && p.x <= 39.601 && p.y >= 0.399 && p.y <= 39.601, "\(p)")
            }
        }
        // The same walls as planned on the chamfered block by themselves: each keeps its clearance from the chamfer.
        let chamfered = try XCTUnwrap(try bottomChamferCopy(of: source).mesh)
        var options = InternalWallsOptions()
        options.plan = .all
        XCTAssertEqual(try internalWallsCopy(of: chamfered, options: options).data, result.data)
    }

    func testHoleGetsARingAndTheChamferKeepsItsEntry() throws {
        let result = try preparePrintReadyCopy(try holedBlock(), input: input(), now: fixedDate)
        let record = result.record
        XCTAssertNil(result.blocked)
        // No saved purpose: the targeted kinds only, so a ring and no slots through the thick region.
        let walls = try XCTUnwrap(record.internalWalls, "\(record.steps)")
        XCTAssertEqual(walls.holeRings, 1)
        XCTAssertEqual(walls.bulkSlots, 0)
        let chamfer = try XCTUnwrap(record.bottomChamfer)
        XCTAssertEqual(chamfer.keptHoleEntries, 1)
        // Only the outer edge: the ring's island round the bore is never taken for an outer edge.
        XCTAssertEqual(chamfer.outlineLengthMM, 160, accuracy: 0.5)
        // The bore keeps its size at the bed and halfway up.
        let mesh = try XCTUnwrap(result.mesh)
        let rays = try XCTUnwrap(TriangleRayIndex(mesh))
        for z: Float in [0.1, 10] {
            for angle in stride(from: Float(0.05), to: 6.2, by: 0.9) {
                let hit = try XCTUnwrap(rays.firstHit(from: SIMD3(20, 20, z), along: SIMD3(cos(angle), sin(angle), 0)))
                XCTAssertEqual(hit.distance, 3, accuracy: 0.1, "z \(z)")
            }
        }
        XCTAssertTrue(meshHealthIsSound(try health(mesh)))
        XCTAssertEqual(try health(mesh).shells, 1)
        // Measured on the outer shape: the ring's island isn't a slender post, its gap isn't a hole near an edge, and
        // the 45° bottom chamfer isn't an overhang past 45°.
        XCTAssertFalse(record.advisories.contains { [PrintAdvisoryKind.slenderUpright.rawValue, PrintAdvisoryKind.holeNearEdge.rawValue,
                                                     PrintAdvisoryKind.thinPin.rawValue].contains($0.kind) }, "\(record.advisories)")
        XCTAssertEqual(record.overhangs, PrintPreparationOverhangs(share45: 0, share50: 0))
        XCTAssertEqual(record.thinAreasUnder1MM, 0)
        let caption = printPreparationCaption(record)
        XCTAssertTrue(caption.lowercased().contains("bottom-edge chamfer"), caption)
        XCTAssertTrue(caption.contains("1 hole ring"), caption)
    }

    func testPocketIsKeptAndReportedNeverFilled() throws {
        let source = try pocketedBlock()
        let result = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        XCTAssertNil(result.blocked)
        let pockets = try XCTUnwrap(result.record.hiddenPockets)
        XCTAssertEqual(pockets.count, 1)
        XCTAssertEqual(pockets.removableBodies, 1)
        // The copy keeps both shells, so its final part-count check passes unchanged.
        XCTAssertEqual(try health(XCTUnwrap(result.mesh)).shells, 2)
        let line = try XCTUnwrap(hiddenPocketsLine(pockets))
        XCTAssertEqual(line, "1 hidden pocket: Slant would bill it as a separate body (about $0.39 extra, test on 25 Oct 2026).")
        // A one-part copy is recorded as checked, with none.
        let plain = try preparePrintReadyCopy(try block(), input: input(), now: fixedDate)
        XCTAssertEqual(plain.record.hiddenPockets, PrintPreparationPockets(count: 0, shellsInside: 0, addedVolumeMM3: 0))
        XCTAssertNil(hiddenPocketsLine(try XCTUnwrap(plain.record.hiddenPockets)))
    }

    // MARK: Purpose

    func testSavedPurposeDecidesTheWallsPlan() throws {
        let source = try block()
        // No purpose: placement uses a neutral stand-in, but the walls plan stays the targeted one, so a plain block
        // gets no slots through its thick region.
        let none = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        XCTAssertNil(none.record.internalWalls)
        let skipped = try XCTUnwrap(none.record.steps.first { $0.step == .internalWalls })
        XCTAssertFalse(skipped.applied)
        XCTAssertTrue(skipped.lines.joined().contains("No internal walls"), "\(skipped.lines)")
        // A bracket loaded along X: every kind, with the slots run along the load.
        let bracket = try preparePrintReadyCopy(source, input: input(intent: PartIntent(purpose: .bracket, load: .x)), now: fixedDate)
        XCTAssertGreaterThan(try XCTUnwrap(bracket.record.internalWalls).bulkSlots, 0)
        // Decorative: none, with the reason.
        let decorative = try preparePrintReadyCopy(source, input: input(intent: PartIntent(purpose: .decorative)), now: fixedDate)
        XCTAssertNil(decorative.record.internalWalls)
        XCTAssertEqual(decorative.record.steps.first { $0.step == .internalWalls }?.lines, [printPreparationWallsDecorative])
        // Settings: chamfer off leaves it out with the reason.
        let off = try preparePrintReadyCopy(source, input: input(chamfer: false), now: fixedDate)
        XCTAssertEqual(off.record.steps.first { $0.step == .bottomChamfer }?.lines, [printPreparationChamferOff])
        XCTAssertNil(off.record.bottomChamfer)
        XCTAssertFalse(off.changed, "A plain block with no purpose and the chamfer off has nothing to change")
    }

    // MARK: Placement, measurements and advisories

    func testTurnAboutZIsRecorded() throws {
        // A 60 × 20 × 10 mm bar drawn at 30° to the X axis.
        let angle: Float = .pi / 6
        let outline = r11Rectangle(.zero, SIMD2(60, 20)).map { p in
            SIMD2(p.x * cos(angle) - p.y * sin(angle), p.x * sin(angle) + p.y * cos(angle)) + SIMD2(30, 0)
        }
        let source = try STLMesh.validated(r11PrismSoup(outline, to: 10))
        let result = try preparePrintReadyCopy(source, input: input(chamfer: false), now: fixedDate)
        let record = result.record
        XCTAssertNil(result.blocked)
        XCTAssertEqual(abs(record.zTurnDegrees), 30, accuracy: 0.5)
        let placement = try XCTUnwrap(record.steps.first { $0.step == .orientation })
        XCTAssertTrue(placement.applied)
        XCTAssertTrue(placement.lines.contains { $0.hasPrefix("Turned 30° about Z") }, "\(placement.lines)")
        XCTAssertTrue(printPreparationCaption(record).contains("turned 30° about Z"), printPreparationCaption(record))
        // Square to the axes now: the bounding box is the bar's own.
        let mesh = try XCTUnwrap(result.mesh)
        let size = mesh.maximum - mesh.minimum
        XCTAssertEqual(size.x, 60, accuracy: 0.01)
        XCTAssertEqual(size.y, 20, accuracy: 0.01)
        // The turn survives the library's save and load.
        let restored = try JSONDecoder().decode(PrintPreparationRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored.zTurnDegrees, record.zTurnDegrees)
    }

    func testMeasurementsAndAdvisoriesAreRecorded() throws {
        // A base with a 2 mm square post standing on it: a thin pin and a slender upright feature.
        let part = Mesh.cube(center: Vector(15, 15, 2.5), size: Vector(30, 30, 5))
            .union(.cube(center: Vector(15, 15, 11), size: Vector(2, 2, 12)))
        let source = try ReinforcementEngine.stl(part.makeWatertight())
        let result = try preparePrintReadyCopy(source, input: input(walls: false), now: fixedDate)
        let record = result.record
        XCTAssertNil(result.blocked)
        let overhangs = try XCTUnwrap(record.overhangs)
        XCTAssertEqual(overhangs.share45, 0, accuracy: 1e-9)
        XCTAssertEqual(printPreparationOverhangLine(overhangs), "Overhangs: none steeper than 45° as placed.")
        let kinds = record.advisories.map(\.kind)
        XCTAssertTrue(kinds.contains(PrintAdvisoryKind.thinPin.rawValue), "\(record.advisories)")
        XCTAssertLessThanOrEqual(record.advisories.count, printAdvisoryMaximumCount)
        XCTAssertEqual(printPreparationAdvisoryLines(record), record.advisories.map(\.message))
        for line in printPreparationAdvisoryLines(record) {
            for word in ["guarantee", "approved", "safe"] { XCTAssertFalse(line.lowercased().contains(word), line) }
        }
    }

    func testAdvisoriesAreCappedAndPlacementDuplicatesDropped() throws {
        let many = (0..<12).map { PrintAdvisory(kind: .holeNearEdge, message: "Hole \($0)") }
        XCTAssertEqual(printPreparationAdvisoryRecords(many, placement: nil).count, printAdvisoryMaximumCount)
        let long = PrintPreparationAdvisoryRecord(kind: "thinPin", message: String(repeating: "x", count: 5_000))
        XCTAssertEqual(printPreparationCappedAdvisories([long, PrintPreparationAdvisoryRecord(kind: "x", message: "  ")]).map(\.message.count),
                       [printPreparationAdvisoryMaximumLength])
        // When the placement step already reported a small contact or a tipping risk, the same advisory isn't repeated.
        let small = OrientationAssessment(orientation: .zUp, size: SIMD3(10, 10, 40), contactArea: 1, overhangArea: 0, surfaceArea: 100,
                                          tipMarginMM: 0.5)
        let choice = PrintPlacementChoice(assessment: small, zTurnDegrees: 0)
        XCTAssertTrue(choice.smallBedContact)
        XCTAssertTrue(choice.tippingProne)
        let found = [PrintAdvisory(kind: .smallBedContact, message: "Small"), PrintAdvisory(kind: .tipping, message: "Tip"),
                     PrintAdvisory(kind: .thinPin, message: "Pin")]
        XCTAssertEqual(printPreparationAdvisoryRecords(found, placement: choice).map(\.message), ["Pin"])
        XCTAssertEqual(printPreparationAdvisoryRecords(found, placement: nil).map(\.message), ["Small", "Tip", "Pin"])
    }

    func testCopyTexts() {
        XCTAssertEqual(printPreparationPercentText(0.004), "under 1%")
        XCTAssertEqual(printPreparationPercentText(0.637), "about 64%")
        XCTAssertEqual(printPreparationOverhangLine(PrintPreparationOverhangs(share45: 0.031, share50: 0)),
                       "Overhangs: about 3% of the surface steeper than 45° as placed; none past Slant’s 50° limit.")
        XCTAssertEqual(printPreparationOverhangLine(PrintPreparationOverhangs(share45: 0.05, share50: 0.02)),
                       "Overhangs: about 5% of the surface steeper than 45° as placed; about 2% past Slant’s 50° limit.")
        XCTAssertEqual(hiddenPocketsLine(count: 2, shellsInside: 0),
                       "2 hidden pockets: Slant would bill each as a separate body (about $0.78 extra, test on 25 Oct 2026).")
        XCTAssertEqual(hiddenPocketsLine(count: 1, shellsInside: 1),
                       "1 hidden pocket, with 1 loose part inside: Slant would bill each as a separate body (about $0.78 extra, test on 25 Oct 2026).")
        XCTAssertNil(hiddenPocketsLine(count: 0, shellsInside: 0))
        XCTAssertEqual(pocketsFilledCopyName("Owl.stl"), "Owl (pockets filled)")
        XCTAssertEqual(hiddenPocketsActivityDetail(filled: 2, removedInside: 0), "Copy saved · 2 pockets filled")
        XCTAssertFalse(hiddenPocketsActivityDetail(filled: 1, removedInside: 1).contains("Owl"))
        for text in [hiddenPocketsFillCaption, hiddenPocketsLine(count: 3, shellsInside: 0)!, printPreparationBottomChamferCaption,
                     printPreparationInternalWallsCaption] {
            for word in ["stronger", "strong ", "guarantee", "approved", "safe"] { XCTAssertFalse(text.lowercased().contains(word), text) }
        }
    }

    // MARK: Records

    func testRecordsDecodeLeniently() throws {
        // A round 10 record: no new fields, and walls with slots only, which were all in thick regions.
        let old = """
        {"sourceID":"11111111-2222-3333-4444-555555555555","sourceName":"Part","created":0,"steps":[],"orientation":"zUp",
         "treatments":[],"notes":[],"internalWalls":{"slots":9,"totalLengthMM":315,"removedVolumeMM3":1400,"removedFraction":0.04,"spacingMM":4}}
        """
        let record = try JSONDecoder().decode(PrintPreparationRecord.self, from: Data(old.utf8))
        XCTAssertEqual(record.internalWalls?.bulkSlots, 9)
        XCTAssertEqual(record.internalWalls?.holeRings, 0)
        XCTAssertNil(record.internalWalls?.estimatedExtraMaterialFraction)
        XCTAssertEqual(record.internalWalls?.kindsList, ["9 slots in thick regions"])
        XCTAssertNil(record.bottomChamfer)
        XCTAssertNil(record.overhangs)
        XCTAssertNil(record.hiddenPockets)
        XCTAssertEqual(record.advisories, [])
        XCTAssertEqual(record.zTurnDegrees, 0)
        XCTAssertEqual(printPreparationPriceLine(record), printPreparationWallsPriceNote)
        // Damaged new fields read as empty; too many advisories are capped.
        let advisories = (0..<20).map { #"{"kind":"thinPin","message":"Pin \#($0)"}"# }.joined(separator: ",")
        let damaged = """
        {"sourceID":"11111111-2222-3333-4444-555555555555","steps":[{"step":"bottomChamfer","applied":true,"lines":["x"]}],
         "bottomChamfer":"junk","overhangs":{"share45":"x"},"hiddenPockets":{"count":-3,"shellsInside":0,"addedVolumeMM3":0},
         "advisories":[\(advisories)],"internalWalls":{"slots":2,"holeRings":1,"pinSlots":2,"bulkSlots":"x"}}
        """
        let read = try JSONDecoder().decode(PrintPreparationRecord.self, from: Data(damaged.utf8))
        XCTAssertEqual(read.steps.map(\.step), [.bottomChamfer])
        XCTAssertNil(read.bottomChamfer)
        XCTAssertNil(read.overhangs)
        XCTAssertNil(read.hiddenPockets)
        XCTAssertEqual(read.advisories.count, printAdvisoryMaximumCount)
        XCTAssertEqual(read.internalWalls?.holeRings, 1)
        XCTAssertEqual(read.internalWalls?.bulkSlots, 0)
        // A whole round 11 record round-trips.
        let made = try preparePrintReadyCopy(try holedBlock(), input: input(), now: fixedDate).record
        XCTAssertEqual(try JSONDecoder().decode(PrintPreparationRecord.self, from: JSONEncoder().encode(made)), made)
        XCTAssertNotNil(made.overhangs)
        XCTAssertNotNil(made.bottomChamfer)
        XCTAssertNotNil(made.internalWalls?.estimatedExtraMaterialFraction)
    }

    // MARK: Determinism

    func testPipelineGivesTheSameBytesTwice() throws {
        let source = try holedBlock()
        let first = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        let second = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        XCTAssertNotNil(first.data)
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.record, second.record)
    }

    // MARK: Fill Hidden Pockets

    func testFillHiddenPocketsRemovesOneBodyPerPocketAndMarksAnEditedCopy() throws {
        // Two pockets in one block.
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(60, 40, 20)) + cuboid(SIMD3(10, 10, 5), SIMD3(20, 20, 15), inward: true)
                                           + cuboid(SIMD3(35, 10, 5), SIMD3(45, 20, 15), inward: true))
        let report = try hiddenPocketsReport(source)
        XCTAssertEqual(report.count, 2)
        let result = try fillHiddenPocketsCopy(of: source)
        let filled = try XCTUnwrap(result.mesh)
        XCTAssertEqual(try health(source).shells - (try health(filled).shells), report.count)
        XCTAssertEqual(try hiddenPocketsReport(filled).count, 0)
        // The copy's flags: an edited copy for the licence advisory; the replica's way up and the Z-up lock are carried.
        let copy = LocalModel(name: "Part (pockets filled)", filePath: "/tmp/p.stl", sourceDetails: ModelSourceDetails(licence: "CC BY-ND 4.0"),
                              inheritsZUpLock: true, keepsPlacement: true, filledPockets: true)
        XCTAssertTrue(modelIsEditedCopy(copy))
        XCTAssertNotNil(modelLicenceAdvisory(copy.sourceDetails!, edited: modelIsEditedCopy(copy)))
        let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(restored.filledPockets, true)
        XCTAssertEqual(restored.keepsPlacement, true)
        XCTAssertTrue(restored.requiresZUp)
        XCTAssertFalse(modelIsEditedCopy(LocalModel(name: "Plain", filePath: "/tmp/q.stl")))
        // Older libraries load without the flag.
        let old = #"[{"id":"\#(UUID().uuidString)","name":"Old","filePath":"/tmp/x.stl","added":0}]"#
        XCTAssertNil(try JSONDecoder().decode([LocalModel].self, from: Data(old.utf8))[0].filledPockets)
        // Its temporary folders are cleaned at launch.
        XCTAssertTrue(isPersonalisationTempFolderName("\(hiddenPocketsTempFolderPrefix)\(UUID().uuidString)"))
        XCTAssertEqual(personalisationTempFolderPrefixes[0], "SlantStudio-OpenSCAD-")
        XCTAssertEqual(personalisationTempFolderPrefixes[1], "SlantStudio-Personalised-")
    }

    @MainActor func testPocketCheckAndFillOfferRules() {
        let stl = LocalModel(name: "Part", filePath: "/tmp/r11-\(UUID().uuidString).stl")
        XCTAssertTrue(hiddenPocketsCheckApplies(stl))
        XCTAssertFalse(hiddenPocketsCheckApplies(LocalModel(name: "M", filePath: "/tmp/m.3mf")))
        // Unknown: offered. Checked with none: not offered. Checked with pockets: offered.
        XCTAssertTrue(hiddenPocketsFillOffered(stl))
        let key = hiddenPocketsCacheKey(modelID: stl.id, path: stl.filePath)
        defer { HiddenPocketsCache.reports[key] = nil }
        HiddenPocketsCache.reports[key] = HiddenPocketsReport(shells: 1, pockets: [], separateParts: 1, shellsInsidePockets: 0,
                                                             otherShells: 0, complete: true, addedVolumeMM3: 0)
        XCTAssertFalse(hiddenPocketsFillOffered(stl))
        // A print-ready copy's own record decides, and its panel shows the line instead of the model checks.
        var record = PrintPreparationRecord(sourceID: UUID(), sourceName: "P", created: fixedDate, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: [])
        record.hiddenPockets = PrintPreparationPockets(count: 2, shellsInside: 0, addedVolumeMM3: 2000)
        let copy = LocalModel(name: "P (print-ready)", filePath: "/tmp/c.stl", printPreparation: record)
        XCTAssertFalse(hiddenPocketsCheckApplies(copy))
        XCTAssertTrue(hiddenPocketsFillOffered(copy))
        XCTAssertEqual(hiddenPocketsKnownCount(copy), 2)
    }
}
