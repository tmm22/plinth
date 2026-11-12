import XCTest
@testable import Plinth

/// Round 20 (Models, Saved Products and design tools): the shared quantity reader, copies known by their names, the
/// Show menu's label, undo names, plurals and accessible names. Pure helpers only; nothing here sends anything.
final class Round20ModelsTests: XCTestCase {
    private func model(_ name: String, copiedFrom: UUID? = nil) -> LocalModel {
        LocalModel(name: name, filePath: "/library/\(name).stl", added: Date(timeIntervalSince1970: 1_800_000_000),
                   copiedFromID: copiedFrom)
    }

    // MARK: printQuantity (Models, Get 3DAPI quote, the 3DAPI composer, Compare estimates, Saved Products)

    func testQuantityReaderKeepsItsMeaningForPlainNumbers() {
        for value in [1, 2, 9, 10, 25, 99, 100, 999, 1000, 9999, 10000] {
            XCTAssertEqual(printQuantity(String(value)), value)
        }
        // Leading zeros were accepted before and still are.
        XCTAssertEqual(printQuantity("012"), 12)
    }

    func testQuantityReaderAcceptsTypedAndDictatedForms() {
        let accepted: [(String, Int)] = [
            (" 12", 12), ("12 ", 12), ("\t12\n", 12), ("  7  ", 7),
            ("1,000", 1000), ("10,000", 10000), ("1 000", 1000), ("10 000", 10000),
            ("1\u{00A0}000", 1000), ("1\u{202F}000", 1000),
            ("12 units", 12), ("12 Units", 12), ("12 UNITS", 12), ("1 unit", 1), ("12units", 12),
            ("12x", 12), ("12 x", 12), ("12X", 12), ("12 ×", 12), ("1,000 units", 1000), (" 3 units ", 3),
        ]
        for (text, value) in accepted { XCTAssertEqual(printQuantity(text), value, text) }
    }

    func testQuantityReaderRefusesEverythingElse() {
        let refused = [
            "", " ", "0", "00", "0 units", "10001", "10,001", "-2", "+2", "-2 units", "1.5", "1.0", "1e2", "2 parts",
            "12 pieces", "x", "units", "x12", "unit 12", "12 x x", "12 units units", "1,00", "1,0000", "1,,000",
            ",100", "100,", "1, 000", "1 2", "12 3", "1,000 000", "0,001", "1_000", "1'000", "1.000", "١٢", "１２",
            "999999999999999999999999", "9,999,999,999,999,999,999", "12abc", "abc12",
        ]
        for text in refused { XCTAssertNil(printQuantity(text), text) }
    }

    /// The table from the round 20 review: the reader is shared by every quantity field, so each of these is pinned.
    func testQuantityReaderInputTable() {
        let table: [(String, Int?)] = [
            // Plain digits mean what they always did; leading zeros can't change a number, so they stay accepted.
            ("1", 1), ("10000", 10000), ("0012", 12), ("012", 12), ("00010000", 10000), ("10001", nil), ("0", nil),
            // Bad groupings, signs and decimals.
            ("10,00x", nil), ("1,00", nil), ("0,500", nil), ("1,0000", nil), ("12.5", nil), ("+12", nil), ("-12", nil),
            ("12,5", nil), ("1.000", nil), ("10,000x", 10000), ("10,000 units", 10000), ("1,000x", 1000),
            // Dictated words, one to twenty, any case, with a spaced suffix.
            ("one", 1), ("One", 1), ("ONE", 1), ("five", 5), ("Twelve", 12), ("twenty", 20), (" seven ", 7),
            ("six", 6), ("Six x", 6), ("six ×", 6), ("five units", 5), ("one unit", 1), ("Twelve Units", 12),
            ("twenty x", 20), ("fifteen\tunits", 15),
            // Not read as words: no suffix without a space, nothing past twenty, no zero, no compounds or decimals.
            ("fivex", nil), ("sixunits", nil), ("sixx", nil), ("zero", nil), ("twenty-one", nil), ("twenty one", nil),
            ("thirty", nil), ("hundred", nil), ("a dozen", nil), ("dozen", nil), ("five and a half", nil),
            ("five five", nil), ("x five", nil), ("units five", nil), ("five units units", nil), ("fives", nil),
            ("on", nil), ("tw", nil), ("five 5", nil), ("5 five", nil), ("minus five", nil), ("-five", nil),
            ("fünf", nil), ("cinq", nil), ("five.", nil), ("five,", nil),
        ]
        for (text, value) in table { XCTAssertEqual(printQuantity(text), value, text) }
        // Every word one to twenty, in three cases.
        for (word, value) in printQuantityWords {
            XCTAssertEqual(printQuantity(word), value, word)
            XCTAssertEqual(printQuantity(word.uppercased()), value, word)
            XCTAssertEqual(printQuantity(word.capitalized + " units"), value, word)
        }
        XCTAssertEqual(Set(printQuantityWords.values), Set(1...20))
    }

    func testDictatedWordsReachTheLargeQuantityNoticeAsNumbers() {
        // Words stop at twenty, under the large-quantity notice's threshold.
        XCTAssertNil(printQuantityNotice("twenty"))
        XCTAssertEqual(printQuantityNotice("25"), largeQuantityNotice(25))
    }

    func testCompareEstimatesStillSplitsOnCommasAndSpaces() {
        // Its own reader splits first, so "1, 5, 10" stays three quantities and "1,500" stays refused.
        XCTAssertEqual(parseComparisonQuantities("1, 5, 10").values, [1, 5, 10])
        XCTAssertNotNil(parseComparisonQuantities("1,500").problem)
        XCTAssertEqual(parseComparisonQuantities("5x 10x").values, [5, 10])
    }

    func testQuantityNoticeFollowsTheReader() {
        XCTAssertEqual(printQuantityNotice("1,000"), largeQuantityNotice(1000))
        XCTAssertNil(printQuantityNotice(" 3 "))
    }

    // MARK: Copies known by their names

    func testCopyNamesFromEveryToolAreRecognised() {
        let names = [
            meshToolCopyName("Owl", kind: .repair), meshToolCopyName("Owl", kind: .simplify(target: 500)),
            stlCopyName("Owl.3mf"), stlCopyName("Owl.obj"), autoImproveCopyName("Owl"), reviewedCopyName("Owl.stl"),
            printReadyCopyName("Owl"), printReadyTeardropCopyName("Owl"), pocketsFilledCopyName("Owl"),
            flatBaseCopyName("Owl"), plinthCopyName("Owl"), fitCouponCopyName("Owl"),
            scaledToSizeCopyName("Owl", plan: ScaleToSizePlan(axis: .longest, targetMM: 50, factor: 2, resultSizeMM: .zero)),
            scaledToSizeCopyName("Owl", plan: ScaleToSizePlan(axis: .z, targetMM: 12.5, factor: 2, resultSizeMM: .zero)),
            scaledToSizeCopyName("Owl", plan: ScaleToSizePlan(axis: .x, targetMM: 50, factor: 2, resultSizeMM: .zero)),
            scaledToSizeCopyName("Owl", plan: ScaleToSizePlan(axis: .y, targetMM: 50, factor: 2, resultSizeMM: .zero)),
            scaledCopyName("Owl.stl", factor: 25.4), scaledCopyName("Owl", factor: 0.03937),
            studioCopyName("Owl", suffix: "edge-improved"), studioCopyName("Owl", suffix: "prepared"),
            reinforcementCopyName("Owl", kind: .split, part: 1), reinforcementCopyName("Owl", kind: .split, part: 2),
        ] + ReinforcementKind.allCases.filter { $0 != .split }.map { reinforcementCopyName("Owl", kind: $0) }
        for name in names { XCTAssertTrue(libraryNameLooksLikeCopy(name), name) }
        // A copy of a copy, and a copy of an OBJ or 3MF original whose name kept its extension.
        XCTAssertTrue(libraryNameLooksLikeCopy("Owl (print-ready) (auto-improved)"))
        XCTAssertTrue(libraryNameLooksLikeCopy(meshToolCopyName("Owl.3mf", kind: .repair)))
        XCTAssertTrue(libraryNameLooksLikeCopy("  Owl (STL copy)  "))
        // No Plinth tool saves a bare "(part)": a split always saves two numbered parts.
        XCTAssertFalse(libraryNameLooksLikeCopy("Castle (part)"))
        XCTAssertTrue(libraryNameLooksLikeCopy("Castle (part 2)"))
    }

    func testCopyNameBaseIsTheNameBeforeTheEnding() {
        XCTAssertEqual(libraryCopyNameBase("Owl (simplified)"), "Owl")
        XCTAssertEqual(libraryCopyNameBase("Owl (print-ready) (auto-improved)"), "Owl (print-ready)")
        XCTAssertEqual(libraryCopyNameBase("Owl (scaled to 50 mm wide)"), "Owl")
        XCTAssertEqual(libraryCopyNameBase("Owl (part 2)"), "Owl")
        XCTAssertEqual(libraryCopyNameBase(scaledCopyName("Owl.stl", factor: 25.4)), "Owl")
        XCTAssertNil(libraryCopyNameBase("Owl"))
        XCTAssertNil(libraryCopyNameBase("Owl (my remix)"))
        XCTAssertEqual(libraryCopyNameKey(" Owl.3MF "), "owl")
        XCTAssertEqual(libraryCopyNameKey("A/B: c"), "a-b- c")
    }

    /// Item 1 of the round 20 review: a copy-like name alone never moves an original to Copies.
    func testImportedOriginalsWithToolLikeNamesStayOriginals() {
        let imported = ["Benchy (simplified)", "Lamp (repaired)", "Castle (part 2)", "Statue (plinth)", "Vase (STL copy)",
                        "Gear (scaled to 50 mm)", "Bracket-scaled-x2", "Owl (print-ready) (auto-improved)"].map { model($0) }
        for filter in [LibraryFilter.originals, .copies] {
            let shown = libraryModelsShown(imported, search: "", filter: filter, sort: .newest).map(\.name)
            XCTAssertEqual(shown, filter == .originals ? imported.map(\.name) : [], "\(filter)")
        }
        // An OBJ or 3MF original with such a name, too.
        let objOriginal = LocalModel(name: "Benchy (simplified)", filePath: "/library/a.obj")
        let threeMF = LocalModel(name: "Lamp (repaired)", filePath: "/library/b.3mf")
        XCTAssertFalse(objOriginal.isShownAsLibraryCopy(libraryNameKeys: libraryCopyNameKeys([objOriginal, threeMF])))
        XCTAssertFalse(threeMF.isShownAsLibraryCopy(libraryNameKeys: libraryCopyNameKeys([objOriginal, threeMF])))
        // Even beside a model of the base name: every Plinth tool saves STL copies.
        let besides = [objOriginal, threeMF, model("Benchy"), model("Lamp")]
        XCTAssertFalse(objOriginal.isShownAsLibraryCopy(libraryNameKeys: libraryCopyNameKeys(besides)))
        XCTAssertFalse(threeMF.isShownAsLibraryCopy(libraryNameKeys: libraryCopyNameKeys(besides)))
        var lockedOBJ = objOriginal
        lockedOBJ.inheritsZUpLock = true
        XCTAssertFalse(lockedOBJ.isShownAsLibraryCopy(libraryNameKeys: []))
    }

    func testOldCopiesNextToTheirOriginalAreCopies() {
        let library = [model("Owl"), model("Owl (simplified)"), model("Owl (print-ready) (auto-improved)"),
                       model("Bracket.3mf (repaired)"), model("Bracket"), model("Gear-scaled-x25.4"), model("gear"),
                       model("Desk Lamp (scaled to 50 mm tall)"), model("desk lamp.obj"), model("Benchy (simplified)")]
        XCTAssertEqual(libraryModelsShown(library, search: "", filter: .copies, sort: .newest).map(\.name),
                       ["Owl (simplified)", "Owl (print-ready) (auto-improved)", "Bracket.3mf (repaired)", "Gear-scaled-x25.4",
                        "Desk Lamp (scaled to 50 mm tall)"])
        XCTAssertEqual(libraryModelsShown(library, search: "", filter: .originals, sort: .newest).map(\.name),
                       ["Owl", "Bracket", "gear", "desk lamp.obj", "Benchy (simplified)"])
    }

    func testOldCopyWhoseOriginalWasRemovedShowsAsAnOriginal() {
        let orphan = model("Owl (simplified)")
        XCTAssertFalse(orphan.isShownAsLibraryCopy(libraryNameKeys: libraryCopyNameKeys([orphan])))
        // A model doesn't count as its own original, even with odd spacing.
        XCTAssertFalse(model("Owl (simplified)").isShownAsLibraryCopy(libraryNameKeys: ["owl (simplified)"]))
        // A middle copy removed: the chain still reaches the original.
        let deep = model("Owl (print-ready) (auto-improved)")
        XCTAssertTrue(deep.isShownAsLibraryCopy(libraryNameKeys: libraryCopyNameKeys([deep, model("Owl")])))
    }

    func testToolEvidenceMakesACopyWhateverTheLibraryHolds() {
        var locked = model("Owl (simplified)")
        locked.inheritsZUpLock = true
        XCTAssertTrue(locked.isShownAsLibraryCopy(libraryNameKeys: []))
        // The lock alone, with a name no tool gives, isn't read as a name-copy (and isn't a known copy).
        var lockedPlain = model("My owl")
        lockedPlain.inheritsZUpLock = true
        XCTAssertFalse(lockedPlain.isShownAsLibraryCopy(libraryNameKeys: []))
        // A tool record is a copy whatever its name.
        var coupon = model("Anything at all")
        coupon.fitCoupon = true
        XCTAssertTrue(coupon.isShownAsLibraryCopy(libraryNameKeys: []))
        XCTAssertTrue(model("Renamed", copiedFrom: UUID()).isShownAsLibraryCopy(libraryNameKeys: []))
    }

    func testOriginalsAndLookalikesAreNotCopies() {
        let names = [
            "Owl", replicaCopyName("Dragon"), accessoryLibraryName(suggested: "Phone stand", description: ""),
            accessoryFitTestLibraryName(libraryName: "Phone stand (designed)"),
            "(repaired)", " (repaired)", "Owl (Repaired)", "Owl (repaired) v2", "Owl (repaired", "Owl repaired",
            "Owl (scaled to big)", "Owl (scaled to 50mm)", "Owl (part one)", "Owl (part 12345)", "Owl (part)x",
            "-scaled-x2", "Owl-scaled-x", "Owl-scaled-xabc", "Owl (my remix)",
        ]
        for name in names { XCTAssertFalse(libraryNameLooksLikeCopy(name), name) }
    }

    func testTheFilterUsesNamesButNothingElseDoes() {
        let original = model("Owl")
        let oldCopy = model("Owl (simplified)")          // saved before lineage was recorded
        let known = model("Desk owl", copiedFrom: original.id)
        let models = [original, oldCopy, known]
        XCTAssertEqual(libraryModelsShown(models, search: "", filter: .copies, sort: .newest).map(\.name), ["Owl (simplified)", "Desk owl"])
        XCTAssertEqual(libraryModelsShown(models, search: "", filter: .originals, sort: .newest).map(\.name), ["Owl"])
        XCTAssertEqual(libraryModelsShown(models, search: "simp", filter: .copies, sort: .newest).map(\.name), ["Owl (simplified)"])
        XCTAssertTrue(libraryModelsShown(models, search: "zz", filter: .copies, sort: .newest).isEmpty)
        // Display only: lineage, captions and Remove Copies don't change.
        XCTAssertFalse(oldCopy.isLibraryCopy)
        XCTAssertTrue(oldCopy.isShownAsLibraryCopy(libraryNameKeys: libraryCopyNameKeys(models)))
        XCTAssertNil(oldCopy.originalModelID)
        XCTAssertEqual(libraryCopyIDs(of: original.id, in: models), [known.id])
        XCTAssertNil(libraryCopyCaption(oldCopy, modelsByID: libraryModelsByID(models)))
    }

    // MARK: Show menu, undo names

    func testShowMenuNamesTheFilterAndItsAccessibleNameStartsWithIt() {
        XCTAssertEqual(libraryFilterMenuTitle(.all), "Show: All Models")
        XCTAssertEqual(libraryFilterMenuTitle(.copies), "Show: Copies")
        for filter in LibraryFilter.allCases {
            XCTAssertTrue(libraryFilterMenuAccessibilityLabel(filter).hasPrefix(libraryFilterMenuTitle(filter)))
        }
    }

    func testUndoNamesSayWhatIsUndone() {
        XCTAssertEqual(libraryRemoveCopiesUndoName, "Remove Copies")
        // Named as the commands are: Remove Copies of This Model… and Remove from Library….
        XCTAssertEqual(libraryRemoveModelUndoName, "Remove from Library")
    }

    func testUndoAndRedoCarryTheActionName() {
        let manager = UndoManager()
        manager.groupsByEvent = false
        final class Target: NSObject { var count = 0 }
        let target = Target()
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target) { t in
            t.count += 1
            manager.registerUndo(withTarget: t) { $0.count -= 1 }
            manager.setActionName(libraryRemoveCopiesUndoName)
        }
        manager.setActionName(libraryRemoveCopiesUndoName)
        manager.endUndoGrouping()
        XCTAssertEqual(manager.undoMenuItemTitle, "Undo Remove Copies")
        manager.undo()
        XCTAssertEqual(manager.redoMenuItemTitle, "Redo Remove Copies")
    }

    // MARK: Plurals and accessible names

    func testPlurals() {
        XCTAssertEqual(materialTypeChipAccessibilityLabel("PLA", count: 1), "PLA, 1 material")
        XCTAssertEqual(materialTypeChipAccessibilityLabel("PETG", count: 12), "PETG, 12 materials")
        XCTAssertEqual(materialTypeChipAccessibilityLabel("Other", count: 0), "Other, 0 materials")
        func report(errors: Int, warnings: Int) -> MeshyPrintabilityReport {
            MeshyPrintabilityReport(taskID: "t", verdict: .warning, errorCount: errors, warningCount: warnings, isWatertight: nil,
                                    holes: nil, nonManifoldEdges: nil, degenerateFaces: nil, hasThinWalls: nil,
                                    thinAreaRatio: nil, wallThicknessMM: nil, dimensionsMM: nil)
        }
        XCTAssertEqual(replicaAnalysisActivityDetail(report(errors: 1, warnings: 1)), "Meshy: warning, 1 error, 1 warning")
        XCTAssertEqual(replicaAnalysisActivityDetail(report(errors: 0, warnings: 2)), "Meshy: warning, 0 errors, 2 warnings")
    }

    func testMeshyFindingsUseTheMeshChecksPlainWords() {
        let one = MeshyPrintabilityReport(taskID: "t", verdict: .error, errorCount: 1, warningCount: 0, isWatertight: false,
                                          holes: 1, nonManifoldEdges: 1, degenerateFaces: 1, hasThinWalls: nil,
                                          thinAreaRatio: nil, wallThicknessMM: nil, dimensionsMM: nil)
        XCTAssertEqual(one.findings, ["Not closed", "1 hole", "1 edge shared by more than two faces", "1 zero-area face"])
        XCTAssertFalse(one.summary.lowercased().contains("manifold"))
    }

    func testCompareEstimatesUseButtonsCanBeToldApart() {
        XCTAssertEqual(comparisonUseAccessibilityLabel(materialName: "PLA Black", quantity: 10), "Use PLA Black, quantity 10")
        XCTAssertTrue(comparisonUseAccessibilityLabel(materialName: "X", quantity: 1).hasPrefix("Use"))
        let filaments = [Record(values: ["publicId": "a", "available": true]), Record(values: ["publicId": "b", "available": false])]
        XCTAssertNil(comparisonUseMaterialBlockedReason(filamentID: "a", filaments: filaments))
        XCTAssertEqual(comparisonUseMaterialBlockedReason(filamentID: "b", filaments: filaments), "This material is now out of stock.")
        XCTAssertEqual(comparisonUseMaterialBlockedReason(filamentID: "c", filaments: filaments), "This material is no longer offered.")
        // The combined reason is unchanged.
        XCTAssertEqual(comparisonUseBlockedReason(planFileID: "f", currentFileID: "f", filamentID: "b", filaments: filaments, busy: false),
                       "This material is now out of stock.")
        XCTAssertEqual(comparisonUseBlockedReason(planFileID: "f", currentFileID: "f", filamentID: "a", filaments: filaments, busy: true),
                       "Wait for the current task to finish.")
    }

    func testSavedProductAndAccessoryNamesIncludeTheItem() {
        XCTAssertEqual(savedProductQuantityLabel("Bracket"), "Quantity for Bracket")
        XCTAssertEqual(savedProductQuantityInvalidText, "Enter a whole number from 1 to 10,000. Save Product waits until then.")
        XCTAssertEqual(savedProductRemoveItemLabel("Packing slip"), "Remove Packing slip")
        XCTAssertEqual(accessoryRemoveMeasurementLabel("  Phone thickness "), "Remove Measurement: Phone thickness")
        XCTAssertEqual(accessoryRemoveMeasurementLabel("  "), "Remove Measurement")
    }

    func testReinforceRefusalPointsToRepairInPlainWords() {
        let text = reinforcementNeedsRepairMessage
        XCTAssertTrue(text.contains("Repair & Save Copy"))
        XCTAssertTrue(text.contains("edges shared by more than two faces"))
        for jargon in ["manifold", "CAD first", "consistently oriented"] { XCTAssertFalse(text.contains(jargon), jargon) }
        for promise in ["strong", "guarantee", "will print"] { XCTAssertFalse(text.lowercased().contains(promise), promise) }
    }

    func testPrintReviewMissingKeyNoticeNamesWhereToAddIt() {
        XCTAssertTrue(printReviewMissingKeyText.contains("Settings › Design Tools › Claude (Anthropic)"))
    }

    // MARK: Round 20 review fixes

    func testSavedProductSaveWaitsForEveryTypedQuantity() {
        let a = UUID(), b = UUID(), removed = UUID()
        XCTAssertFalse(savedProductQuantityTextsBlockSave(invalidLineIDs: [], lineIDs: [a, b]))
        XCTAssertTrue(savedProductQuantityTextsBlockSave(invalidLineIDs: [b], lineIDs: [a, b]))
        // A line removed while its field was invalid no longer holds Save Product.
        XCTAssertFalse(savedProductQuantityTextsBlockSave(invalidLineIDs: [removed], lineIDs: [a, b]))
        XCTAssertTrue(savedProductQuantityTextsBlockSave(invalidLineIDs: [removed, a], lineIDs: [a, b]))
        XCTAssertEqual(savedProductQuantityBlockedReason, "Enter a whole number from 1 to 10,000 for every quantity.")
    }

    func testSeller45DegreeFiguresNameSlantsLimit() {
        XCTAssertEqual(plinthOverhangMarginNote, "Plinth’s margin under Slant’s 50° limit")
        let none = printReviewOverhangLine(OverhangShare(overhangAreaMM2: 0, surfaceAreaMM2: 100))
        let some = printReviewOverhangLine(OverhangShare(overhangAreaMM2: 10, surfaceAreaMM2: 100))
        for line in [none, some, replicaNoProblemsLine, accessoryOverhangLine(OverhangShare(overhangAreaMM2: 0, surfaceAreaMM2: 1), location: nil)] {
            XCTAssertTrue(line.contains("45°"), line)
            XCTAssertTrue(line.contains("Slant’s 50° limit"), line)
        }
        XCTAssertTrue(previewShowOverhangsHelp.contains("Slant’s 50° overhang limit"))
        XCTAssertFalse(previewShowOverhangsHelp.contains("Plinth’s 50°"))
    }

    func testAlternativeButtonsAccessibleNameStartsWithTheirTitle() {
        XCTAssertEqual(accessoryAlternativeAccessibilityLabel("Gaming headset"), "Gaming headset, puts it in What is it?")
        let long = String(repeating: "Wireless gaming headset stand ", count: 3)
        let title = accessoryAlternativeButtonTitle(long)
        XCTAssertTrue(accessoryAlternativeAccessibilityLabel(long).hasPrefix(String(title.dropLast())), title)
    }
}
