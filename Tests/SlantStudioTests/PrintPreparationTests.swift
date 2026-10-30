import XCTest
import Euclid
import simd
@testable import SlantStudio

final class PrintPreparationTests: XCTestCase {
    private func exported(_ mesh: Mesh) throws -> STLMesh { try ReinforcementEngine.stl(mesh.makeWatertight()) }
    private func block(_ x: Double, _ y: Double, _ z: Double) throws -> STLMesh {
        try exported(.cube(center: Vector(x / 2, y / 2, z / 2), size: Vector(x, y, z)))
    }
    /// A wall with a free 10 mm ledge at the top, from the Auto-improve tests.
    private func ledgePart() throws -> STLMesh {
        let wall = Mesh.cube(center: Vector(10, 2.5, 10), size: Vector(20, 5, 20))
        let ledge = Mesh.cube(center: Vector(10, 10, 17.5), size: Vector(20, 10, 5))
        return try exported(wall.union(ledge))
    }
    /// 20 mm tray with 1.8 mm walls: the full Auto-improve matches its walls and fillets its inside corners.
    private func tray() throws -> STLMesh {
        let cube = Mesh.cube(center: Vector(10, 10, 10), size: Vector(20, 20, 20))
        return try exported(cube.subtracting(Mesh.cube(center: Vector(10, 10, 12), size: Vector(16.4, 16.4, 20))))
    }
    private func input(walls: Bool = true, intent: PartIntent? = nil, chamfer: Bool = true) -> PrintPreparationInput {
        PrintPreparationInput(sourceID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, sourceName: "Part",
                              savedIntent: intent, internalWalls: walls, bottomChamfer: chamfer)
    }
    private let fixedDate = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: Settings

    func testSettingsDefaultToOnAndOn() throws {
        let name = "PrintPreparationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(PrintPreparationSettings(defaults: defaults), PrintPreparationSettings(enabled: true, internalWalls: true, bottomChamfer: true))
        defaults.set(false, forKey: printPreparationInternalWallsDefaultsKey)
        XCTAssertEqual(PrintPreparationSettings(defaults: defaults), PrintPreparationSettings(enabled: true, internalWalls: false))
        defaults.set(false, forKey: printPreparationBottomChamferDefaultsKey)
        XCTAssertEqual(PrintPreparationSettings(defaults: defaults), PrintPreparationSettings(enabled: true, internalWalls: false, bottomChamfer: false))
        defaults.set(false, forKey: printPreparationEnabledDefaultsKey)
        XCTAssertFalse(PrintPreparationSettings(defaults: defaults).enabled)
        XCTAssertEqual(PrintPreparationSettings(), PrintPreparationSettings(enabled: true, internalWalls: true, bottomChamfer: true))
        // The footer lists the steps and says pockets are never filled automatically.
        XCTAssertTrue(printPreparationSettingsFooter.contains("0.4 mm chamfer round the bottom edge"))
        XCTAssertTrue(printPreparationSettingsFooter.contains("never fills hidden pockets"))
        XCTAssertTrue(printPreparationSettingsFooter.contains("turned square"))
        XCTAssertTrue(printPreparationBottomChamferCaption.contains("Hole entries keep their size"))
        // No strength claim in the caption; the dated, sized price finding is there.
        XCTAssertFalse(printPreparationInternalWallsCaption.lowercased().contains("strong"))
        XCTAssertTrue(printPreparationInternalWallsCaption.contains("25 Oct 2026"))
        XCTAssertTrue(printPreparationInternalWallsCaption.contains("40 × 40 × 20 mm"))
        XCTAssertTrue(printPreparationInternalWallsCaption.contains("27%"))
        XCTAssertTrue(printPreparationSettingsFooter.contains(printPreparationChamferCaution))
        XCTAssertTrue(printPreparationSettingsFooter.contains("never uploads"))
    }

    // MARK: Eligibility

    func testOnlyImportsSTLCopiesAndReplicasArePrepared() {
        let eligible: [ModelImportOrigin] = [.imported, .stlCopyOfOtherFormat, .replica]
        let never: [ModelImportOrigin] = [.downloadedFromSlant, .personalised, .designedAccessory, .workbench, .studioToolCopy]
        for origin in eligible { XCTAssertTrue(origin.mayPrepareForPrinting, "\(origin)") }
        for origin in never { XCTAssertFalse(origin.mayPrepareForPrinting, "\(origin)") }
    }

    func testEverySkipReason() {
        let on = PrintPreparationSettings()
        func reason(_ origin: ModelImportOrigin = .imported, ext: String = "stl", details: ModelSourceDetails? = nil,
                    settings: PrintPreparationSettings = PrintPreparationSettings(), handled: Bool = false) -> PrintPreparationSkipReason? {
            printPreparationSkipReason(origin: origin, fileExtension: ext, sourceDetails: details, settings: settings, alreadyHandled: handled)
        }
        XCTAssertNil(reason())
        XCTAssertNil(reason(ext: "STL"))
        XCTAssertNil(reason(.replica))
        XCTAssertNil(reason(.stlCopyOfOtherFormat))
        XCTAssertEqual(reason(settings: PrintPreparationSettings(enabled: false, internalWalls: true)), .settingOff)
        XCTAssertEqual(reason(.studioToolCopy), .originNotPrepared)
        XCTAssertEqual(reason(.personalised), .originNotPrepared)
        XCTAssertEqual(reason(.designedAccessory), .originNotPrepared)
        XCTAssertEqual(reason(ext: "obj"), .notSTL)
        XCTAssertEqual(reason(ext: "3mf"), .notSTL)
        XCTAssertEqual(reason(handled: true), .alreadyPrepared)
        XCTAssertEqual(reason(details: ModelSourceDetails(licence: "CC BY-ND 4.0")), .noDerivativesLicence)
        XCTAssertEqual(reason(details: ModelSourceDetails(copyright: "No derivatives allowed")), .noDerivativesLicence)
        // Non-commercial alone is shown by the licence advisory but doesn't stop an edit.
        XCTAssertNil(reason(details: ModelSourceDetails(licence: "CC BY-NC 4.0")))
        XCTAssertNil(reason(details: ModelSourceDetails(licence: "Raleigh, ND office")))
        XCTAssertEqual(on.enabled, true)
        // Only the licence skip is explained on the original; the rest are silent.
        XCTAssertNotNil(PrintPreparationSkipReason.noDerivativesLicence.message)
        for silent in [PrintPreparationSkipReason.settingOff, .originNotPrepared, .notSTL, .alreadyPrepared] { XCTAssertNil(silent.message) }
    }

    func testNeverPreparedTwice() {
        let original = LocalModel(name: "Part", filePath: "/tmp/part.stl")
        XCTAssertFalse(printPreparationAlreadyHandled(modelID: original.id, library: [original], queuedThisSession: []))
        XCTAssertTrue(printPreparationAlreadyHandled(modelID: original.id, library: [original], queuedThisSession: [original.id]))
        var withStatus = original
        withStatus.printPreparationStatus = PrintPreparationStatus(outcome: .nothingToChange, date: fixedDate)
        XCTAssertTrue(printPreparationAlreadyHandled(modelID: original.id, library: [withStatus], queuedThisSession: []))
        // Tracked by source ID in the copy's record, even if the original's status were lost.
        let record = PrintPreparationRecord(sourceID: original.id, sourceName: "Part", created: fixedDate, steps: [], orientation: .zUp,
                                            treatments: [], internalWalls: nil, notes: [])
        let copy = LocalModel(name: "Part (print-ready)", filePath: "/tmp/copy.stl", printPreparation: record)
        XCTAssertTrue(printPreparationAlreadyHandled(modelID: original.id, library: [original, copy], queuedThisSession: []))
        // The copy itself is a Studio tool copy, refused by its origin.
        XCTAssertEqual(printPreparationSkipReason(origin: .studioToolCopy, fileExtension: "stl", sourceDetails: nil,
                                                  settings: PrintPreparationSettings(), alreadyHandled: false), .originNotPrepared)
    }

    // MARK: Step plan

    func testStepPlanOrderLimitsAndReasons() {
        let sound = printPreparationPlan(triangles: 1_000, meshSound: true, internalWallsOn: true)
        // The bottom chamfer runs before the internal walls, so the walls are planned against the finished surface.
        XCTAssertEqual(sound.map(\.step), [.repair, .orientation, .treatments, .bottomChamfer, .internalWalls])
        XCTAssertEqual(sound.map(\.decision), [.skip(printPreparationRepairNotNeeded), .run, .run, .run, .run])
        let broken = printPreparationPlan(triangles: 1_000, meshSound: false, internalWallsOn: true)
        XCTAssertEqual(broken.first?.decision, .run)
        let large = printPreparationPlan(triangles: meshToolsReinforceTriangleLimit + 1, meshSound: true, internalWallsOn: true)
        XCTAssertEqual(large[2].decision, .skip(printPreparationTreatmentsTooLarge))
        XCTAssertEqual(large[3].decision, .run, "The bottom chamfer goes up to the library's limit")
        XCTAssertEqual(large[4].decision, .run, "Internal walls go up to the library's limit")
        XCTAssertEqual(printPreparationPlan(triangles: meshToolsReinforceTriangleLimit, meshSound: true, internalWallsOn: true)[2].decision, .run)
        let off = printPreparationPlan(triangles: 1_000, meshSound: true, internalWallsOn: false)
        XCTAssertEqual(off[4].decision, .skip(printPreparationWallsOff))
        XCTAssertEqual(off[3].decision, .run)
        let chamferOff = printPreparationPlan(triangles: 1_000, meshSound: true, internalWallsOn: true, bottomChamferOn: false)
        XCTAssertEqual(chamferOff[3].decision, .skip(printPreparationChamferOff))
        XCTAssertEqual(chamferOff[4].decision, .run)
        guard case .skip(let chamferReason) = printPreparationDecision(.bottomChamfer, triangles: bottomChamferMaximumTriangles + 1,
                                                                        meshSound: true, internalWallsOn: true) else { return XCTFail() }
        XCTAssertTrue(chamferReason.contains("too many"), chamferReason)
        guard case .skip(let reason) = printPreparationDecision(.internalWalls, triangles: internalWallsMaximumTriangles + 1,
                                                                 meshSound: true, internalWallsOn: true) else { return XCTFail() }
        XCTAssertTrue(reason.contains("too many"), reason)
        XCTAssertTrue(printPreparationTreatmentsTooLarge.contains("20,000"))
    }

    // MARK: Fit-safe profile

    func testFitSafeProfileExcludesWallMatchingAndFillets() throws {
        XCTAssertEqual(AutoImprover.Profile.fitSafe.phases, [.bridge, .overhang])
        XCTAssertEqual(AutoImprover.Profile.fitAffecting.phases, [.thicken, .fillet])
        XCTAssertEqual(AutoImprover.Profile.full.phases, AutoImprover.Phase.allCases)
        // The tray gets matched walls and fillets from the full set, and nothing from the fit-safe one.
        let source = try tray()
        let safe = try AutoImprover.improve(source, intent: PartIntent(purpose: .bracket, load: .x), orientation: .zUp, profile: .fitSafe)
        XCTAssertFalse(safe.applied.contains { [.thicken, .fillet].contains($0.settings.kind) })
        XCTAssertTrue(safe.applied.isEmpty)
        XCTAssertFalse(safe.timedOut)
        // The same tray under the full set does get walls and fillets, so the difference is the profile.
        let full = try AutoImprover.improve(source, intent: PartIntent(purpose: .bracket, load: .x), orientation: .zUp, profile: .full)
        XCTAssertTrue(full.applied.contains { $0.settings.kind == .thicken }, "\(full.skipped)")
        XCTAssertTrue(full.applied.contains { $0.settings.kind == .fillet }, "\(full.skipped)")
        let ledge = try AutoImprover.improve(try ledgePart(), intent: PartIntent(), orientation: .zUp, profile: .fitSafe)
        XCTAssertEqual(ledge.applied.map(\.settings.kind), [.overhang], "\(ledge.skipped)")
    }

    func testFitSafeProfileGivesTheSameBytesTwice() throws {
        let source = try ledgePart()
        let first = try AutoImprover.improve(source, intent: PartIntent(), orientation: .zUp, profile: .fitSafe)
        let second = try AutoImprover.improve(source, intent: PartIntent(), orientation: .zUp, profile: .fitSafe)
        XCTAssertFalse(first.applied.isEmpty)
        XCTAssertEqual(first.mesh.binarySTL(), second.mesh.binarySTL())
    }

    // MARK: Placement

    func testNeutralPlacementIntent() {
        let none = printPreparationPlacementIntent(saved: nil)
        XCTAssertEqual(none.intent.load, .unknown)
        XCTAssertEqual(none.intent.purpose.priority, .balanced)
        XCTAssertTrue(none.intent.isReady)
        XCTAssertTrue(none.note.contains("Neutral placement"))
        XCTAssertTrue(none.note.contains("no load direction was assumed"))
        // A bracket without a direction never gets a guessed one.
        let bracket = printPreparationPlacementIntent(saved: PartIntent(purpose: .bracket))
        XCTAssertEqual(bracket.intent, none.intent)
        XCTAssertTrue(bracket.note.contains("never guesses"), bracket.note)
        let directed = PartIntent(purpose: .bracket, load: .x)
        XCTAssertEqual(printPreparationPlacementIntent(saved: directed).intent, directed)
        XCTAssertEqual(printPreparationPlacementIntent(saved: PartIntent(purpose: .decorative)).intent.purpose, .decorative)
    }

    func testNeutralPlacementLaysATallPlateFlat() throws {
        let plate = try block(40, 10, 60)
        let best = try XCTUnwrap(preferredOrientation(plate.orientationAssessments(), intent: printPreparationPlacementIntent(saved: nil).intent))
        XCTAssertEqual(best.size.z, 10, accuracy: 0.001)
        // A part already lying on its largest face stays as it is.
        let flat = try block(40, 40, 10)
        XCTAssertEqual(preferredOrientation(flat.orientationAssessments(), intent: printPreparationPlacementIntent(saved: nil).intent)?.orientation, .zUp)
    }

    // MARK: Pipeline and record

    func testBlockGetsInternalWallsAndARecord() throws {
        let source = try block(40, 40, 20)
        // A functional saved purpose: slots through thick regions as well as the targeted kinds.
        let result = try preparePrintReadyCopy(source, input: input(intent: PartIntent(purpose: .enclosure)), now: fixedDate)
        XCTAssertNil(result.blocked)
        XCTAssertTrue(result.changed)
        let record = result.record
        XCTAssertEqual(record.steps.map(\.step), [.repair, .orientation, .treatments, .bottomChamfer, .internalWalls])
        XCTAssertEqual(record.sourceID, input().sourceID)
        XCTAssertEqual(record.sourceName, "Part")
        XCTAssertEqual(record.created, fixedDate)
        XCTAssertEqual(record.orientation, .zUp)
        XCTAssertTrue(record.treatments.isEmpty)
        let walls = try XCTUnwrap(record.internalWalls)
        XCTAssertGreaterThan(walls.slots, 0)
        XCTAssertEqual(walls.bulkSlots, walls.slots)
        XCTAssertGreaterThan(walls.removedVolumeMM3, 0)
        XCTAssertLessThanOrEqual(walls.removedFraction, internalWallsMaximumRemovedFraction)
        XCTAssertGreaterThan(try XCTUnwrap(walls.estimatedExtraMaterialFraction), 0)
        XCTAssertEqual(record.appliedSteps.map(\.step), [.bottomChamfer, .internalWalls])
        XCTAssertTrue(printPreparationAppliedLines(record)[1].hasPrefix("Internal walls: "), printPreparationAppliedLines(record)[1])
        XCTAssertTrue(printPreparationDetailLines(record).contains { $0.hasPrefix("Internal walls: Adds internal walls") })
        XCTAssertTrue(printPreparationCaption(record).contains("slots in thick regions"), printPreparationCaption(record))
        // Never a strength claim or percentage of strength.
        for line in printPreparationAppliedLines(record) + printPreparationSkippedLines(record) + [printPreparationCaption(record)] {
            for word in ["stronger", "strong ", "guaranteed", "approved", "safe"] {
                XCTAssertFalse(line.lowercased().contains(word), line)
            }
        }
        // The copy is one sound part, the same size.
        let mesh = try XCTUnwrap(result.mesh)
        let health = try XCTUnwrap(analyzeMeshHealth(mesh))
        XCTAssertTrue(meshHealthIsSound(health))
        XCTAssertEqual(health.shells, 1)
        XCTAssertEqual(try STLMesh.parse(XCTUnwrap(result.data)).triangleCount, mesh.triangleCount)
        let bounds = meshCoordinateBounds(mesh.vertices)
        XCTAssertEqual(bounds.high - bounds.low, SIMD3<Float>(40, 40, 20))
    }

    func testPipelineGivesTheSameBytesTwice() throws {
        let source = try block(60, 10, 30)
        let first = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        let second = try preparePrintReadyCopy(source, input: input(), now: fixedDate)
        XCTAssertNotNil(first.data)
        XCTAssertEqual(first.data, second.data)
        XCTAssertEqual(first.record, second.record)
        XCTAssertTrue(first.record.appliedSteps.contains { $0.step == .orientation }, "\(first.record.steps)")
    }

    func testNothingToChangeMakesNoCopy() throws {
        // Already flat, no ledges, internal walls and the bottom chamfer off.
        let result = try preparePrintReadyCopy(try block(40, 40, 10), input: input(walls: false, chamfer: false), now: fixedDate)
        XCTAssertFalse(result.changed)
        XCTAssertNil(result.mesh)
        XCTAssertNil(result.data)
        XCTAssertNil(result.blocked)
        XCTAssertTrue(printPreparationSkippedLines(result.record).contains { $0.contains(printPreparationWallsOff) })
    }

    func testUnrepairableMeshStopsWithoutACopy() throws {
        // A lone triangle: open, and nothing a repair can close into a solid.
        let lone = STLMesh(vertices: [0, 0, 0, 10, 0, 0, 0, 10, 0], minimum: .zero, maximum: SIMD3(10, 10, 0))
        let result = try preparePrintReadyCopy(lone, input: input(), now: fixedDate)
        XCTAssertNil(result.data)
        let reason = try XCTUnwrap(result.blocked)
        XCTAssertTrue(reason.contains("Repair and simplify"), reason)
    }

    func testStopThrowsAndSavesNothing() throws {
        XCTAssertThrowsError(try preparePrintReadyCopy(try block(40, 40, 20), input: input(), isCancelled: { true })) {
            XCTAssertEqual($0 as? PrintPreparationError, .stopped)
        }
    }

    func testRecordRoundTripsLocksZUpAndCountsAsAnEditedCopy() throws {
        let result = try preparePrintReadyCopy(try block(40, 40, 20), input: input(), now: fixedDate)
        let copy = LocalModel(name: "Part (print-ready)", filePath: "/tmp/copy.stl",
                              sourceDetails: ModelSourceDetails(licence: "CC BY-ND 4.0"), printPreparation: result.record)
        let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(copy))
        XCTAssertEqual(restored.printPreparation, result.record)
        XCTAssertTrue(restored.requiresZUp)
        XCTAssertTrue(modelIsEditedCopy(restored))
        XCTAssertFalse(canSaveScaledCopy(restored))
        XCTAssertNotNil(modelLicenceAdvisory(restored.sourceDetails!, edited: modelIsEditedCopy(restored)))
        XCTAssertEqual(meshFitEditBlockedReason(restored, tool: .plinth) != nil, true)

        var original = LocalModel(name: "Part", filePath: "/tmp/part.stl")
        original.printPreparationStatus = PrintPreparationStatus(outcome: .madeCopy, copyID: copy.id, date: fixedDate)
        let back = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(back.printPreparationStatus, original.printPreparationStatus)
        XCTAssertFalse(back.requiresZUp)
    }

    func testDamagedRecordsNeverStopTheLibraryLoading() throws {
        let json = """
        [{"id":"\(UUID().uuidString)","name":"Copy","filePath":"/tmp/a.stl","added":0,
          "printPreparation":{"sourceID":"not-a-uuid","steps":"junk","orientation":42},
          "printPreparationStatus":{"outcome":"somethingNew","date":"x"}}]
        """
        let models = try JSONDecoder().decode([LocalModel].self, from: Data(json.utf8))
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models[0].printPreparation?.sourceID, printPreparationUnknownSourceID)
        XCTAssertEqual(models[0].printPreparation?.steps, [])
        XCTAssertTrue(models[0].requiresZUp)
        XCTAssertEqual(models[0].printPreparationStatus?.outcome, .noCopy)
    }

    func testActivityDetailHasCountsAndStatusOnly() {
        let made = PrintPreparationStatus(outcome: .madeCopy, copyID: UUID(), lines: ["Secret name"], date: fixedDate)
        XCTAssertEqual(printPreparationActivityDetail(made, applied: 2, skipped: 1), "Print-ready copy saved · 2 applied, 1 skipped")
        XCTAssertEqual(printPreparationActivityDetail(PrintPreparationStatus(outcome: .nothingToChange, date: fixedDate)),
                       "Already print-ready: nothing to change")
        XCTAssertFalse(printPreparationActivityDetail(PrintPreparationStatus(outcome: .noCopy, lines: ["Secret name"], date: fixedDate)).contains("Secret"))
    }

    // MARK: Housekeeping

    func testStudioCopyTempFoldersAreCleanedAtLaunch() {
        XCTAssertEqual(personalisationTempFolderPrefixes[0], "Plinth-OpenSCAD-")
        XCTAssertEqual(personalisationTempFolderPrefixes[1], "Plinth-Personalised-")
        for prefix in [printReadyTempFolderPrefix, autoImproveTempFolderPrefix, preparedCopyTempFolderPrefix, edgeEditTempFolderPrefix,
                       reinforceTempFolderPrefix, stlCopyTempFolderPrefix, scaledCopyTempFolderPrefix] {
            XCTAssertTrue(prefix.hasPrefix("Plinth-"))
            XCTAssertTrue(isPersonalisationTempFolderName("\(prefix)\(UUID().uuidString)"), prefix)
            XCTAssertTrue(studioTempFolderURL(prefix: prefix).lastPathComponent.hasPrefix(prefix))
        }
        XCTAssertEqual(Set(personalisationTempFolderPrefixes).count, personalisationTempFolderPrefixes.count)
    }

    func testTempFoldersAreMadeWithPlinthNamesAndSlantStudioNamesAreStillCleaned() {
        // Every folder is made under a Plinth name, and the list starts with them (callers index [0] and [1]).
        XCTAssertEqual(Array(personalisationTempFolderPrefixes.prefix(currentTempFolderPrefixes.count)), currentTempFolderPrefixes)
        for prefix in currentTempFolderPrefixes + [ModelDragExport.folderPrefix] {
            XCTAssertTrue(prefix.hasPrefix("Plinth-"), prefix)
            XCTAssertFalse(prefix.hasPrefix("SlantStudio-"), prefix)
        }
        for prefix in [imageTo3DTempFolderPrefix, meshToolsTempFolderPrefix, meshFitTempFolderPrefix, replicaTempFolderPrefix,
                       accessoryTempFolderPrefix, printReadyTempFolderPrefix, autoImproveTempFolderPrefix,
                       preparedCopyTempFolderPrefix, edgeEditTempFolderPrefix, reinforceTempFolderPrefix, stlCopyTempFolderPrefix,
                       scaledCopyTempFolderPrefix, hiddenPocketsTempFolderPrefix] {
            XCTAssertTrue(currentTempFolderPrefixes.contains(prefix), prefix)
        }
        // Slant Studio's names come after, one for each current name, and are still recognised for clean-up: they may
        // hold buyer personalisation text.
        XCTAssertEqual(Array(personalisationTempFolderPrefixes.suffix(legacyTempFolderPrefixes.count)), legacyTempFolderPrefixes)
        XCTAssertEqual(personalisationTempFolderPrefixes.count, currentTempFolderPrefixes.count + legacyTempFolderPrefixes.count)
        // Every name Slant Studio made (its 15) is listed, each the old form of a current one.
        XCTAssertEqual(legacyTempFolderPrefixes.count, 15)
        XCTAssertEqual(Set(legacyTempFolderPrefixes).count, legacyTempFolderPrefixes.count)
        for legacy in legacyTempFolderPrefixes {
            XCTAssertTrue(legacy.hasPrefix("SlantStudio-"), legacy)
            XCTAssertTrue(currentTempFolderPrefixes.contains("Plinth-" + legacy.dropFirst("SlantStudio-".count)), legacy)
        }
        XCTAssertTrue(legacyTempFolderPrefixes.contains("SlantStudio-OpenSCAD-"))
        XCTAssertTrue(legacyTempFolderPrefixes.contains("SlantStudio-Personalised-"))
        let id = UUID().uuidString
        XCTAssertTrue(isPersonalisationTempFolderName("SlantStudio-OpenSCAD-\(id)"))
        XCTAssertTrue(isPersonalisationTempFolderName("SlantStudio-Personalised-\(id)"))
        XCTAssertTrue(isPersonalisationTempFolderName("SlantStudio-Generated3D-\(id)"))
        XCTAssertTrue(isPersonalisationTempFolderName("SlantStudio-PocketsFilled-\(id)"))
        XCTAssertFalse(isPersonalisationTempFolderName("SlantStudio-OpenSCAD-notauuid"))
        XCTAssertEqual(stalePersonalisationTempFolderNames([("SlantStudio-OpenSCAD-\(id)", nil)], now: Date(),
                                                           otherInstanceMayBeRunning: false), ["SlantStudio-OpenSCAD-\(id)"])
        // The callers that index the list make Plinth folders.
        XCTAssertTrue("\(personalisationTempFolderPrefixes[0])\(id)".hasPrefix("Plinth-OpenSCAD-"))
        XCTAssertTrue("\(personalisationTempFolderPrefixes[1])\(id)".hasPrefix("Plinth-Personalised-"))
        for prefix in currentTempFolderPrefixes {
            XCTAssertTrue(studioTempFolderURL(prefix: prefix).lastPathComponent.hasPrefix("Plinth-"), prefix)
        }
    }

    func testAnotherCopyUnderEitherBundleIDKeepsItsFolders() {
        let me: pid_t = 100
        func running(_ table: [String: [pid_t]]) -> (String) -> [pid_t] { { table[$0] ?? [] } }
        XCTAssertEqual(appBundleIdentifier, "io.github.tmm22.plinth")
        XCTAssertEqual(legacyAppBundleIdentifier, "app.slantstudio.mac")
        // Alone (only this process is listed under its own ID).
        XCTAssertFalse(otherAppInstanceMayBeRunning(currentBundleID: appBundleIdentifier, myProcessID: me,
                                                    runningProcessIDs: running([appBundleIdentifier: [me]])))
        XCTAssertFalse(otherAppInstanceMayBeRunning(currentBundleID: appBundleIdentifier, myProcessID: me, runningProcessIDs: running([:])))
        // Another Plinth, or an old Slant Studio, is running.
        XCTAssertTrue(otherAppInstanceMayBeRunning(currentBundleID: appBundleIdentifier, myProcessID: me,
                                                   runningProcessIDs: running([appBundleIdentifier: [me, 200]])))
        XCTAssertTrue(otherAppInstanceMayBeRunning(currentBundleID: appBundleIdentifier, myProcessID: me,
                                                   runningProcessIDs: running([appBundleIdentifier: [me], legacyAppBundleIdentifier: [300]])))
        // Run as the old ID (or any other), Plinth's copies still count, and so does a copy under that ID.
        XCTAssertTrue(otherAppInstanceMayBeRunning(currentBundleID: legacyAppBundleIdentifier, myProcessID: me,
                                                   runningProcessIDs: running([appBundleIdentifier: [200]])))
        XCTAssertTrue(otherAppInstanceMayBeRunning(currentBundleID: "com.example.other", myProcessID: me,
                                                   runningProcessIDs: running(["com.example.other": [me, 400]])))
        XCTAssertTrue(otherAppInstanceMayBeRunning(currentBundleID: "com.example.other", myProcessID: me,
                                                   runningProcessIDs: running([legacyAppBundleIdentifier: [300]])))
        XCTAssertFalse(otherAppInstanceMayBeRunning(currentBundleID: "com.example.other", myProcessID: me,
                                                    runningProcessIDs: running(["com.example.other": [me]])))
        // Without a bundle ID this copy can't tell, so it assumes another may be running.
        XCTAssertTrue(otherAppInstanceMayBeRunning(currentBundleID: nil, myProcessID: me, runningProcessIDs: running([:])))
    }
}
