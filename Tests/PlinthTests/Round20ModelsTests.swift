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
            "999999999999999999999999", "9,999,999,999,999,999,999", "twelve", "12abc", "abc12",
        ]
        for text in refused { XCTAssertNil(printQuantity(text), text) }
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
        ] + ReinforcementKind.allCases.map { reinforcementCopyName("Owl", kind: $0) }
        for name in names { XCTAssertTrue(libraryNameLooksLikeCopy(name), name) }
        // A copy of a copy, and a copy of an OBJ or 3MF original whose name kept its extension.
        XCTAssertTrue(libraryNameLooksLikeCopy("Owl (print-ready) (auto-improved)"))
        XCTAssertTrue(libraryNameLooksLikeCopy(meshToolCopyName("Owl.3mf", kind: .repair)))
        XCTAssertTrue(libraryNameLooksLikeCopy("  Owl (STL copy)  "))
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
        XCTAssertTrue(oldCopy.isShownAsLibraryCopy)
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
        XCTAssertEqual(libraryRemoveModelUndoName, "Remove Model")
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
        XCTAssertEqual(savedProductQuantityLabel("Bracket"), "Quantity of Bracket")
        XCTAssertEqual(savedProductQuantityInvalidText(3), "Enter a whole number from 1 to 10,000. The quantity stays 3 until then.")
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

    func testMeshFitBusyCaption() {
        XCTAssertEqual(meshFitBusyCaption, "Available once the current task finishes.")
    }
}
