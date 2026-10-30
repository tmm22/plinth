import XCTest
import simd
@testable import Plinth

/// Round 12: material suggestions by purpose and Lay It Flat Along Its Length.
final class MaterialAndLayFlatTests: XCTestCase {
    private let pla = Record(values: ["id": "pla", "name": "PLA Black", "profile": "PLA", "available": true])
    private let petg = Record(values: ["id": "petg", "name": "PETG Black", "profile": "PETG", "available": true])
    private let petg2 = Record(values: ["id": "petg2", "name": "PETG Blue", "profile": "PETG", "available": true])
    private let opm = Record(values: ["id": "opm", "name": "OPM Grey", "profile": "OPM", "available": true])
    private let opmOut = Record(values: ["id": "opm", "name": "OPM Grey", "profile": "OPM", "available": false])
    private let opmUnknown = Record(values: ["id": "opm", "name": "OPM Grey", "profile": "OPM"])
    private let petgCF = Record(values: ["id": "cf", "name": "PETG-CF", "profile": "PETG-CF", "available": true])

    private func hint(_ intent: PartIntent?, current: String, _ filaments: [Record], stl: Bool = true) -> MaterialPurposeHint? {
        materialPurposeHint(intent: intent, isSTL: stl, selectedFilamentID: current, filaments: filaments)
    }

    // MARK: Material by purpose

    func testPurposeMapsToARequirementAndCustomToNone() {
        XCTAssertEqual(suggestedMaterialGoal(for: .decorative), .rigid)
        XCTAssertEqual(suggestedMaterialGoal(for: .enclosure), .rigid)
        XCTAssertEqual(suggestedMaterialGoal(for: .bracket), .impact)
        XCTAssertEqual(suggestedMaterialGoal(for: .clip), .impact)
        XCTAssertNil(suggestedMaterialGoal(for: .custom))
        // The seller's own requirement wins; Keep my material means no advice at all.
        XCTAssertEqual(materialAdviceGoal(PartIntent(purpose: .clip))?.goal, .impact)
        XCTAssertEqual(materialAdviceGoal(PartIntent(purpose: .clip))?.chosen, false)
        XCTAssertEqual(materialAdviceGoal(PartIntent(purpose: .clip, materialGoal: .warm))?.goal, .warm)
        XCTAssertEqual(materialAdviceGoal(PartIntent(purpose: .clip, materialGoal: .warm))?.chosen, true)
        XCTAssertNil(materialAdviceGoal(PartIntent(purpose: .clip, materialGoal: .keepCurrent)))
        XCTAssertNil(materialAdviceGoal(PartIntent(purpose: .custom, details: "A hook")))
    }

    func testWarmSuggestsOPMFirstThenPETGAndOnlyInStock() {
        XCTAssertEqual(recommendedMaterials(for: .warm, in: [petg, pla, opm]).map(\.id), ["opm", "petg"])
        XCTAssertEqual(recommendedMaterials(for: .warm, in: [petg, opmOut]).map(\.id), ["petg"])
        XCTAssertEqual(recommendedMaterials(for: .warm, in: [petg, opmUnknown]).map(\.id), ["petg"])
        XCTAssertEqual(recommendedMaterials(for: .impact, in: [petgCF, petg2, petg]).map(\.id), ["petg", "petg2"])
        XCTAssertEqual(MaterialGoal.warm.rawValue, "Warm environment", "the saved value never changes")
        XCTAssertEqual(MaterialGoal.warm.label, "Outdoors, sun or warmth")
    }

    func testClipOnPLAGetsAPETGHintWithItsOptions() throws {
        let found = try XCTUnwrap(hint(PartIntent(purpose: .clip), current: "pla", [pla, petg2, petg]))
        XCTAssertEqual(found.message, "For a clip, PETG is a common starting point: it has more give than PLA.")
        XCTAssertEqual(found.profile, "PETG")
        XCTAssertEqual(found.options.map(\.id), ["petg", "petg2"])
        // Already PETG, or no PETG in stock: no hint. A PETG-CF isn't PETG.
        XCTAssertNil(hint(PartIntent(purpose: .clip), current: "petg", [pla, petg]))
        XCTAssertNil(hint(PartIntent(purpose: .bracket), current: "pla", [pla, petgCF]))
        XCTAssertNil(hint(PartIntent(purpose: .bracket), current: "pla", [pla, Record(values: ["id": "x", "profile": "PETG", "available": false])]))
        XCTAssertEqual(hint(PartIntent(purpose: .bracket), current: "cf", [petgCF, petg])?.profile, "PETG")
    }

    func testHintNeedsAnSTLWithASavedPurpose() {
        XCTAssertNil(hint(nil, current: "pla", [pla, petg]))
        XCTAssertNil(hint(PartIntent(purpose: .clip), current: "pla", [pla, petg], stl: false))
        XCTAssertNil(hint(PartIntent(purpose: .custom, details: "A hook"), current: "pla", [pla, petg]))
        XCTAssertNil(hint(PartIntent(purpose: .clip, materialGoal: .keepCurrent), current: "pla", [pla, petg]))
        XCTAssertNil(hint(PartIntent(purpose: .clip, materialGoal: .repeatedFlex), current: "pla", [pla, petg]))
        XCTAssertEqual(hint(PartIntent(purpose: .custom, details: "A hook", materialGoal: .impact), current: "pla", [pla, petg])?.message,
                       "For a part that takes knocks and some flex, PETG is a common starting point: it has more give than PLA.")
    }

    func testPurposeStiffPLASuggestionNeverSecondGuessesAChosenMaterial() {
        XCTAssertNil(hint(PartIntent(purpose: .enclosure), current: "petg", [pla, petg]))
        XCTAssertNil(hint(PartIntent(purpose: .decorative), current: "opm", [pla, opm]))
        XCTAssertEqual(hint(PartIntent(purpose: .enclosure), current: "", [pla, petg])?.message,
                       "For an enclosure, PLA is a common starting point: it is stiffer than PETG.")
        // The seller's own stiff requirement does.
        XCTAssertEqual(hint(PartIntent(purpose: .enclosure, materialGoal: .rigid), current: "petg", [pla, petg])?.profile, "PLA")
    }

    func testOutdoorRequirementFallsBackToPETGWhenOPMIsMissingOrOutOfStock() throws {
        let outdoor = PartIntent(purpose: .bracket, load: .x, materialGoal: .warm)
        XCTAssertEqual(hint(outdoor, current: "pla", [pla, petg, opm])?.message,
                       "For a part that lives outdoors or in the sun, OPM is a common starting point: it handles warmth and sun better than PLA, though large flat parts can lift at the corners.")
        for missing in [[pla, petg, opmOut], [pla, petg, opmUnknown], [pla, petg]] {
            let found = try XCTUnwrap(hint(outdoor, current: "pla", missing))
            XCTAssertEqual(found.profile, "PETG")
            XCTAssertTrue(found.message.contains("though not on a car dashboard or behind glass"), found.message)
        }
        XCTAssertNil(hint(outdoor, current: "pla", [pla, opmOut]))
        XCTAssertNil(hint(outdoor, current: "petg", [pla, petg, opm]), "PETG is one of the requirement's profiles")
        XCTAssertNil(hint(outdoor, current: "opm", [pla, petg, opm]))
    }

    // MARK: Lay It Flat

    private func bar(_ size: SIMD3<Float>) throws -> STLMesh {
        try STLMesh.validated(r11PrismSoup(r11Rectangle(.zero, SIMD2(size.x, size.y)), to: size.z))
    }
    private func outcome(_ mesh: STLMesh, _ intent: PartIntent, requiresZUp: Bool = false, keepsPlacement: Bool = false,
                         fromPrintReadyCopy: Bool = false) -> LayFlatOutcome {
        layFlatOutcome(intent: intent, extents: mesh.maximum - mesh.minimum, assessments: mesh.orientationAssessments(),
                       requiresZUp: requiresZUp, keepsPlacement: keepsPlacement, fromPrintReadyCopy: fromPrintReadyCopy)
    }

    func testLongestAxisAndTies() {
        XCTAssertEqual(layFlatLengthAxis(extents: SIMD3(10, 40, 5)), .y)
        XCTAssertEqual(layFlatLengthAxis(extents: SIMD3(10, 5, 40)), .z)
        XCTAssertEqual(layFlatLengthAxis(extents: SIMD3(40, 40, 5)), .x)
        XCTAssertEqual(layFlatLengthAxis(extents: SIMD3(5, 40, 40)), .y)
        // Within the tolerance counts as a tie, so float noise never flips the choice.
        XCTAssertEqual(layFlatLengthAxis(extents: SIMD3(5, 40, 40.1)), .y)
        XCTAssertEqual(layFlatLengthAxis(extents: SIMD3(5, 40, 41)), .z)
        XCTAssertNil(layFlatLengthAxis(extents: .zero))
        XCTAssertNil(layFlatLengthAxis(extents: SIMD3(.nan, 1, 1)))
        XCTAssertNil(layFlatLengthAxis(extents: SIMD3(-1, 1, 1)))
    }

    func testRefusalsForLockedKeptCopiesAndDecorativeParts() throws {
        let mesh = try bar(SIMD3(6, 4, 60))
        let bracket = PartIntent(purpose: .bracket)
        XCTAssertEqual(outcome(mesh, bracket, requiresZUp: true).unavailable, .zUpLocked)
        XCTAssertEqual(outcome(mesh, bracket, keepsPlacement: true).unavailable, .keptPlacement)
        XCTAssertEqual(outcome(mesh, bracket, fromPrintReadyCopy: true).unavailable, .fromPrintReadyCopy)
        XCTAssertEqual(outcome(mesh, PartIntent(purpose: .decorative)).unavailable, .decorative)
        XCTAssertEqual(outcome(mesh, PartIntent(purpose: .custom, details: "  ")).unavailable, .needsDescription)
        XCTAssertEqual(outcome(mesh, PartIntent(purpose: .bracket, load: .z)).unavailable, .alreadySet)
        XCTAssertEqual(outcome(try bar(SIMD3(20, 22, 25)), bracket).unavailable, .noClearLength)

        // Through a library model: its lineage decides, and a locked copy is never measured.
        let locked = LocalModel(name: "copy", filePath: "/tmp/copy.stl", partIntent: bracket, inheritsZUpLock: true)
        XCTAssertEqual(mesh.layFlatOutcome(for: locked).unavailable, .zUpLocked)
        let replica = LocalModel(name: "replica", filePath: "/tmp/replica.stl", partIntent: bracket, keepsPlacement: true)
        XCTAssertEqual(mesh.layFlatOutcome(for: replica).unavailable?.message, LayFlatUnavailable.keptPlacement.message)
        XCTAssertNil(mesh.layFlatOutcome(for: replica).plan)
        // Optimise & Save Copy's prepared copy: already placed, and its saved directions describe the original.
        let recipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "bar", intent: bracket, orientation: .xUp, materialID: nil, created: Date())
        let prepared = LocalModel(name: "prepared", filePath: "/tmp/prepared.stl", partIntent: bracket, printRecipe: recipe)
        XCTAssertEqual(mesh.layFlatOutcome(for: prepared).unavailable, .preparedCopy)
        let printReady = LocalModel(name: "ready", filePath: "/tmp/ready.stl", partIntent: bracket, fromPrintReadyCopy: true)
        XCTAssertEqual(mesh.layFlatOutcome(for: printReady).unavailable, .fromPrintReadyCopy)
    }

    func testSlenderUprightBarLaysDownKeepingItsPurpose() throws {
        let mesh = try bar(SIMD3(6, 4, 60))
        for purpose in [PartPurpose.bracket, .clip, .enclosure] {
            let intent = PartIntent(purpose: purpose, details: "", load: .unknown, materialGoal: .impact)
            let plan = try XCTUnwrap(outcome(mesh, intent).plan, "\(purpose)")
            XCTAssertEqual(plan.axis, .z)
            XCTAssertEqual(plan.intent.load, .z)
            XCTAssertEqual(plan.intent.purpose, purpose)
            XCTAssertEqual(plan.intent.materialGoal, .impact)
            XCTAssertEqual(plan.lengthMM, 60, accuracy: 0.001)
            XCTAssertTrue(plan.changesPlacement)
            XCTAssertEqual(plan.placement.orientation.rotate(SIMD3(0, 0, 1)).z, 0, accuracy: 0.0001)
            XCTAssertTrue(plan.placement.assessment.meetsMinimumContact)
            // The existing ranking, given the saved intent, chooses the same placement.
            XCTAssertEqual(preferredOrientation(mesh.orientationAssessments(), intent: plan.intent)?.orientation,
                           plan.placement.assessment.orientation)
            XCTAssertTrue(plan.lines[0].hasPrefix("Sets the main stress direction to the original Z axis, its longest side (about 60 mm)"), plan.lines[0])
            XCTAssertTrue(plan.lines[1].contains("layers run along its length"), plan.lines[1])
            XCTAssertTrue(plan.lines[2].hasPrefix("Overhangs steeper than 45°"), plan.lines[2])
        }
        let model = LocalModel(name: "bar", filePath: "/tmp/bar.stl", partIntent: PartIntent(purpose: .bracket))
        XCTAssertEqual(mesh.layFlatOutcome(for: model).plan?.intent.load, .z)
        XCTAssertNil(mesh.layFlatOutcome(for: model).unavailable)
        XCTAssertEqual(mesh.layFlatOutcome(for: model).plan?.lines.last, layFlatSaveLine)
        XCTAssertEqual(mesh.layFlatOutcome(for: model), mesh.layFlatOutcome(for: model))
    }

    func testAPartAlreadyLyingKeepsItsPlacement() throws {
        let plan = try XCTUnwrap(outcome(try bar(SIMD3(60, 6, 4)), PartIntent(purpose: .bracket)).plan)
        XCTAssertEqual(plan.axis, .x)
        XCTAssertFalse(plan.changesPlacement)
        XCTAssertTrue(plan.lines[1].hasPrefix("It already lies along its length"), plan.lines[1])
    }

    func testRoundRodHasNoFlatSideToLieOn() throws {
        let rod = try STLMesh.validated(r11PrismSoup(r11Circle(SIMD2(3, 3), radius: 3, segments: 64), to: 60))
        XCTAssertEqual(outcome(rod, PartIntent(purpose: .bracket)).unavailable, .noFlatSide)
        let model = LocalModel(name: "pin", filePath: "/tmp/pin.stl", partIntent: PartIntent(purpose: .clip))
        XCTAssertEqual(rod.layFlatOutcome(for: model).unavailable?.message,
                       "It has no flat side to lie on: add a flat base in Size and base first.")
    }

    func testPurposeDecidesWhetherOverhangsOutweighTheLength() {
        // Standing: small steady contact, no overhangs. Lying: large overhangs.
        let standing = OrientationAssessment(orientation: .zUp, size: SIMD3(5, 5, 60), contactArea: 25, overhangArea: 0, surfaceArea: 1000)
        let lying = OrientationAssessment(orientation: .xUp, size: SIMD3(60, 5, 5), contactArea: 300, overhangArea: 800, surfaceArea: 1000)
        let narrow = OrientationAssessment(orientation: .yUp, size: SIMD3(5, 60, 5), contactArea: 10, overhangArea: 0, surfaceArea: 1000)
        func run(_ purpose: PartPurpose, _ assessments: [OrientationAssessment]) -> LayFlatOutcome {
            layFlatOutcome(intent: PartIntent(purpose: purpose), extents: SIMD3(5, 5, 60), assessments: assessments,
                           requiresZUp: false, keepsPlacement: false, fromPrintReadyCopy: false)
        }
        XCTAssertEqual(run(.enclosure, [standing, lying]).unavailable, .placementStandsItUp)
        XCTAssertEqual(run(.bracket, [standing, lying]).plan?.placement.assessment.orientation, .xUp)
        // Lying only on a sliver under the contact Studio looks for: no rolling placement.
        XCTAssertEqual(run(.bracket, [standing, narrow]).unavailable, .noFlatSide)
        XCTAssertEqual(run(.bracket, [narrow]).unavailable, .noFlatSide)
        XCTAssertEqual(run(.bracket, []).unavailable, .noPlacement)
    }

    // MARK: Wording

    func testNoStrengthFiguresTemperaturesOrFoodClaims() throws {
        var texts = MaterialGoal.allCases.map(\.guidance) + MaterialGoal.allCases.map(\.label)
        texts += PartPurpose.allCases.map(materialSuggestedCaption)
        texts += [materialAdviceFoodNote, layFlatCaption]
        let catalogs = [[pla, petg, opm], [pla, petg], [pla, petg, opmOut], [petg, opm], [pla, opm], [pla]]
        for purpose in PartPurpose.allCases {
            for goal in [nil] + MaterialGoal.allCases.map(Optional.some) {
                for catalog in catalogs {
                    for current in ["", "pla", "petg", "opm"] {
                        let intent = PartIntent(purpose: purpose, details: "A part", load: .x, materialGoal: goal)
                        if let found = hint(intent, current: current, catalog) { texts.append(found.message) }
                    }
                }
            }
        }
        texts += [LayFlatUnavailable.zUpLocked, .keptPlacement, .fromPrintReadyCopy, .preparedCopy, .decorative, .needsDescription, .noClearLength,
                  .alreadySet, .noPlacement, .noFlatSide, .placementStandsItUp].map(\.message)
        texts += try XCTUnwrap(outcome(try bar(SIMD3(6, 4, 60)), PartIntent(purpose: .bracket)).plan).lines
        texts += try XCTUnwrap(outcome(try bar(SIMD3(60, 6, 4)), PartIntent(purpose: .bracket)).plan).lines
        XCTAssertGreaterThan(texts.count, 40)
        for text in texts {
            let lower = text.lowercased()
            for word in ["strong", "strength", "safe", "guarantee", "approved", "%", "°c", "°f", "℃", "food-safe", "food safe", "for food"] {
                XCTAssertFalse(lower.contains(word), "\(word) in: \(text)")
            }
        }
    }
}
