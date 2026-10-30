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
        XCTAssertEqual(line, "1 hidden pocket costs about $0.39 extra in total (Slant bills it as a separate body; test on 25 Oct 2026). Filling uses about 1.0 cm³ more material. Get an estimate for both.")
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
        // The turn is shown once: in the placement's sentence, not the caption or the details.
        let shown = printPreparationAppliedLines(record) + printPreparationDetailLines(record) + [printPreparationCaption(record)]
        XCTAssertEqual(shown.filter { $0.contains("30° about Z") }, ["Placement: kept the way up it was drawn, turned 30° about Z to line up its faces."])
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
        // A saved bracket purpose: the slender-upright note is only for a bracket, clip or custom part.
        // Kept as placed, so the post stands up.
        let result = try preparePrintReadyCopy(source, input: input(intent: PartIntent(purpose: .bracket, load: .z), walls: false, kept: "Kept"),
                                               now: fixedDate)
        let record = result.record
        XCTAssertNil(result.blocked)
        let overhangs = try XCTUnwrap(record.overhangs)
        XCTAssertEqual(overhangs.share45, 0, accuracy: 1e-9)
        XCTAssertEqual(printPreparationOverhangLine(overhangs), "Overhangs: none steeper than 45° as placed.")
        let kinds = record.advisories.map(\.kind)
        XCTAssertTrue(kinds.contains(PrintAdvisoryKind.thinPin.rawValue), "\(record.advisories)")
        XCTAssertTrue(kinds.contains(PrintAdvisoryKind.slenderUpright.rawValue), "\(record.advisories)")
        XCTAssertLessThanOrEqual(record.advisories.count, printAdvisoryMaximumCount)
        let slender = try XCTUnwrap(printPreparationAdvisoryLines(record).first { $0.hasPrefix("Slender upright feature") })
        XCTAssertTrue(slender.contains("likely weaker standing than lying flat"), slender)
        XCTAssertTrue(slender.hasSuffix("then use Make Print-Ready Copy; or add a rib or gusset in Reinforce."), slender)
        for line in printPreparationAdvisoryLines(record) {
            for word in ["guarantee", "approved", "safe", "half as strong", "cnc kitchen", "%"] {
                XCTAssertFalse(line.lowercased().contains(word), line)
            }
        }
        // No saved purpose: no slender-upright note.
        XCTAssertFalse(slenderUprightAdvisoryApplies(nil))
        XCTAssertFalse(slenderUprightAdvisoryApplies(PartIntent(purpose: .decorative)))
        XCTAssertFalse(slenderUprightAdvisoryApplies(PartIntent(purpose: .enclosure)))
        XCTAssertTrue(slenderUprightAdvisoryApplies(PartIntent(purpose: .clip)))
        XCTAssertTrue(slenderUprightAdvisoryApplies(PartIntent(purpose: .custom)))
    }

    func testAdvisoriesAreCappedRebuiltAndContactStaysInline() throws {
        let many = (0..<12).map { PrintAdvisory(kind: .holeNearEdge, message: "Hole \($0)", values: [1, 2, 3, 4, Double($0) + 1]) }
        XCTAssertEqual(printPreparationAdvisoryRecords(many).count, printAdvisoryMaximumCount)
        let long = PrintPreparationAdvisoryRecord(kind: "thinPin", message: String(repeating: "x", count: 5_000))
        XCTAssertEqual(printPreparationCappedAdvisories([long, PrintPreparationAdvisoryRecord(kind: "x", message: "  ")]).map(\.message.count),
                       [printPreparationAdvisoryMaximumLength])
        // Shown lines are rebuilt from the figures, so an earlier build's saved wording never shows again; a known kind
        // without figures is left out, and only an unknown kind shows its saved line.
        var record = PrintPreparationRecord(sourceID: UUID(), sourceName: "P", created: fixedDate, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: [])
        record.advisories = [
            PrintPreparationAdvisoryRecord(kind: "slenderUpright", message: "… about half as strong as printed flat (CNC Kitchen)."),
            PrintPreparationAdvisoryRecord(kind: "slenderUpright", message: "Old text", values: [1, 2, 3, 20, 2]),
            PrintPreparationAdvisoryRecord(kind: "somethingNew", message: "A later build's note."),
            PrintPreparationAdvisoryRecord(kind: "steepOverhangs", message: "Overhangs", values: [0.05, 40]),
        ]
        let lines = printPreparationAdvisoryLines(record)
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("Slender upright feature near X 1, Y 2, Z 3: about 20 mm tall and 2.0 mm thick"), lines[0])
        XCTAssertEqual(lines[1], "A later build's note.")
        XCTAssertFalse(lines.joined().contains("CNC"))
        // On a copy, contact and tipping advice points to the original, and both stay inline when the rest collapse.
        let contact = try XCTUnwrap(printAdvisoryMessage(.smallBedContact, values: [1, 40, 100], onCopy: true))
        XCTAssertTrue(contact.hasSuffix("Add a flat base or plinth to the original in Size and base, then use Make Print-Ready Copy."), contact)
        let tip = try XCTUnwrap(printAdvisoryMessage(.tipping, values: [1, 30, 0], onCopy: true))
        XCTAssertTrue(tip.contains("add one to the original in Size and base"), tip)
        XCTAssertTrue(try XCTUnwrap(printAdvisoryMessage(.steepOverhangs, values: [0.05, 40])).contains("Reinforce’s overhang chamfer"))
        let items = [PrintPreparationAdvisoryLine(message: "a", alwaysShown: false), PrintPreparationAdvisoryLine(message: "tip", alwaysShown: true),
                     PrintPreparationAdvisoryLine(message: "b", alwaysShown: false), PrintPreparationAdvisoryLine(message: "c", alwaysShown: false)]
        XCTAssertEqual(printPreparationAdvisorySplit(items).inline, ["tip"])
        XCTAssertEqual(printPreparationAdvisorySplit(items).collapsed, ["a", "b", "c"])
        XCTAssertEqual(printPreparationAdvisorySplit(Array(items.prefix(3))).inline, ["a", "tip", "b"])
        // A large footprint needs both sides of 60 mm or more, and says how to fix it.
        let corners = try XCTUnwrap(printAdvisoryMessage(.sharpFootprintCorners, values: [120, 4]))
        XCTAssertTrue(corners.hasSuffix("round the corners in your CAD tool."), corners)
        XCTAssertNil(sharpFootprintCorners(try STLMesh.validated(cuboid(.zero, SIMD3(120, 50, 5)))))
        XCTAssertNotNil(sharpFootprintCorners(try STLMesh.validated(cuboid(.zero, SIMD3(120, 60, 5)))))
    }

    func testCopyTexts() {
        XCTAssertEqual(printPreparationPercentText(0.004), "under 1%")
        XCTAssertEqual(printPreparationPercentText(0.637), "about 64%")
        XCTAssertEqual(printPreparationOverhangLine(PrintPreparationOverhangs(share45: 0.031, share50: 0)),
                       "Overhangs: about 3% of the surface steeper than 45° as placed; none past Slant’s 50° limit.")
        XCTAssertEqual(printPreparationOverhangLine(PrintPreparationOverhangs(share45: 0.05, share50: 0.01)),
                       "Overhangs: about 5% of the surface steeper than 45° as placed; about 1% past Slant’s 50° limit.")
        // From 2% past 50°, the line says what helps (the copy has no separate overhang advisory).
        XCTAssertEqual(printPreparationOverhangLine(PrintPreparationOverhangs(share45: 0.05, share50: 0.02)),
                       "Overhangs: about 5% of the surface steeper than 45° as placed; about 2% past Slant’s 50° limit. Those areas may sag or print rough; Reinforce’s overhang chamfer under them helps.")
        XCTAssertEqual(hiddenPocketsSummaryText(count: 2, shellsInside: 0, addedVolumeMM3: 2000),
                       "2 hidden pockets cost about $0.78 extra in total (Slant bills each as a separate body; test on 25 Oct 2026). Filling uses about 2.0 cm³ more material. Get an estimate for both.")
        XCTAssertEqual(hiddenPocketsSummaryText(count: 1, shellsInside: 1, addedVolumeMM3: 10),
                       "1 hidden pocket, with 1 loose part inside, cost about $0.78 extra in total (Slant bills each pocket and each loose part as a separate body; test on 25 Oct 2026). Filling uses a little more material. Filling removes the loose parts inside them. Get an estimate for both.")
        XCTAssertNil(hiddenPocketsSummaryText(count: 0, shellsInside: 0, addedVolumeMM3: 0))
        XCTAssertEqual(pocketsFilledCopyName("Owl.stl"), "Owl (pockets filled)")
        XCTAssertEqual(hiddenPocketsActivityDetail(filled: 2, removedInside: 0), "Copy saved · 2 pockets filled")
        XCTAssertFalse(hiddenPocketsActivityDetail(filled: 1, removedInside: 1).contains("Owl"))
        // The settings texts: what the chamfer means for automatic copies, that both switches apply to Make
        // Print-Ready Copy, and which purposes get slots through thick regions.
        XCTAssertTrue(printPreparationBottomChamferCaption.contains("With this on, almost every new STL gets a print-ready copy, because most parts have a flat bottom edge."))
        XCTAssertTrue(printPreparationBottomChamferCaption.contains(printPreparationAlsoManualNote))
        XCTAssertTrue(printPreparationInternalWallsCaption.contains(printPreparationAlsoManualNote))
        XCTAssertTrue(printPreparationSettingsFooter.contains("any saved purpose except Decorative (including Enclosure and Custom)"))
        XCTAssertTrue(printPreparationNoticeText.contains("chamfer"))
        XCTAssertEqual(printPreparationNoticeDismissedDefaultsKey, "prepareNewModelsNoticeDismissedRound11")
        XCTAssertEqual(printPreparationOfferCaption(PrintPreparationSettings()),
                       "Repair if needed, placement, bridging, chamfers under ledges, a bottom-edge chamfer and internal walls, in a separate copy.")
        XCTAssertEqual(printPreparationOfferCaption(PrintPreparationSettings(enabled: false, internalWalls: false, bottomChamfer: false)),
                       "Repair if needed, placement, bridging and chamfers under ledges, in a separate copy.")
        for text in [hiddenPocketsFillCaption, hiddenPocketsSummaryText(count: 3, shellsInside: 0, addedVolumeMM3: 9)!, printPreparationBottomChamferCaption,
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
        XCTAssertEqual(personalisationTempFolderPrefixes[0], "Plinth-OpenSCAD-")
        XCTAssertEqual(personalisationTempFolderPrefixes[1], "Plinth-Personalised-")
    }

    @MainActor func testPocketCheckAndFillOfferRules() {
        let stl = LocalModel(name: "Part", filePath: "/tmp/r11-\(UUID().uuidString).stl")
        XCTAssertTrue(hiddenPocketsCheckApplies(stl))
        XCTAssertFalse(hiddenPocketsCheckApplies(LocalModel(name: "M", filePath: "/tmp/m.3mf")))
        // The menus offer it only when pockets are known: not when unknown, not when checked with none.
        XCTAssertFalse(hiddenPocketsFillOffered(stl))
        let key = hiddenPocketsCacheKey(modelID: stl.id, path: stl.filePath)
        defer { HiddenPocketsCache.reports[key] = nil }
        HiddenPocketsCache.reports[key] = HiddenPocketsReport(shells: 1, pockets: [], separateParts: 1, shellsInsidePockets: 0,
                                                             otherShells: 0, complete: true, addedVolumeMM3: 0)
        XCTAssertFalse(hiddenPocketsFillOffered(stl))
        HiddenPocketsCache.reports[key] = HiddenPocketsReport(shells: 2, pockets: [HiddenPocket(triangles: 12, volumeMM3: 1, low: .zero, high: .one, shellsInside: 0)],
                                                             separateParts: 1, shellsInsidePockets: 0, otherShells: 0, complete: true, addedVolumeMM3: 1)
        XCTAssertTrue(hiddenPocketsFillOffered(stl))
        // The fill run's state clears only when its work ends, not when Stop is pressed.
        let run = HiddenPocketsFillRun()
        XCTAssertNotNil(run.begin(stl.id))
        run.stop()
        XCTAssertEqual(run.workingModelID, stl.id)
        XCTAssertTrue(run.stopping)
        XCTAssertNil(run.begin(UUID()), "A second fill can't start while the first one's work runs")
        run.end()
        XCTAssertNil(run.workingModelID)
        XCTAssertFalse(run.stopping)
        XCTAssertNotNil(run.begin(UUID()))
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
