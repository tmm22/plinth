import XCTest
import simd
@testable import SlantStudio

final class ModelLibraryActionsTests: XCTestCase {
    // MARK: Rename

    func testValidatedModelNameTrimsAndRejectsUnsafeNames() {
        XCTAssertEqual(validatedModelName("  Bracket v2 \n"), "Bracket v2")
        XCTAssertNil(validatedModelName(""))
        XCTAssertNil(validatedModelName("   \n\t "))
        XCTAssertNil(validatedModelName("parts/bracket"))
        XCTAssertNil(validatedModelName("bracket:left"))
        XCTAssertNil(validatedModelName("brack\u{0007}et"))
        XCTAssertNil(validatedModelName("two\nlines"))
        XCTAssertEqual(validatedModelName(String(repeating: "a", count: maximumModelNameLength)), String(repeating: "a", count: maximumModelNameLength))
        XCTAssertNil(validatedModelName(String(repeating: "a", count: maximumModelNameLength + 1)))
        XCTAssertEqual(validatedModelName("Ünïcode bracket – 2"), "Ünïcode bracket – 2")
    }

    func testModelNameProblemExplainsEachRejection() {
        XCTAssertEqual(modelNameProblem(" "), "Enter a name.")
        XCTAssertEqual(modelNameProblem("a/b"), "Names can’t contain “/” or “:”.")
        XCTAssertNotNil(modelNameProblem("a\u{0000}b"))
        XCTAssertNil(modelNameProblem("Bracket"))
    }

    func testRenameNoteOnlyForUploadedModels() {
        XCTAssertNil(renameUploadedNote(isUploaded: false))
        XCTAssertTrue(renameUploadedNote(isUploaded: true)!.contains("keeps its original name"))
    }

    // MARK: Export

    func testExportFileNameSanitisesAndKeepsExtension() {
        XCTAssertEqual(exportFileName(modelName: "bracket-prepared", fileExtension: "STL"), "bracket-prepared.stl")
        XCTAssertEqual(exportFileName(modelName: "a/b:c", fileExtension: "stl"), "a-b-c.stl")
        XCTAssertEqual(exportFileName(modelName: "..hidden", fileExtension: "obj"), "hidden.obj")
        XCTAssertEqual(exportFileName(modelName: "   ", fileExtension: "3mf"), "Model.3mf")
        XCTAssertEqual(exportFileName(modelName: "line\nbreak", fileExtension: "stl"), "line-break.stl")
        XCTAssertEqual(exportFileName(modelName: "noext", fileExtension: ""), "noext")
    }

    func testExportDestinationRefusesLibraryFolderAndSourceFile() {
        let support = URL(fileURLWithPath: "/tmp/SlantStudioSupportTest", isDirectory: true)
        let source = support.appendingPathComponent("Models/ABC.stl")
        XCTAssertNotNil(exportDestinationProblem(source: source, destination: source, supportDirectory: support))
        XCTAssertNotNil(exportDestinationProblem(source: source, destination: support.appendingPathComponent("Models/other.stl"), supportDirectory: support))
        XCTAssertNotNil(exportDestinationProblem(source: source, destination: support.appendingPathComponent("models.json"), supportDirectory: support))
        XCTAssertNil(exportDestinationProblem(source: source, destination: URL(fileURLWithPath: "/tmp/Exports/bracket.stl"), supportDirectory: support))
        XCTAssertNil(exportDestinationProblem(source: source, destination: URL(fileURLWithPath: "/tmp/SlantStudioSupportTest-other/bracket.stl"), supportDirectory: support))
    }

    func testExportCopiesWithoutTouchingSourceAndReplacesExisting() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.stl")
        try Data("solid new".utf8).write(to: source)
        let destination = folder.appendingPathComponent("export.stl")
        try exportModelFile(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("solid new".utf8))
        XCTAssertEqual(try Data(contentsOf: source), Data("solid new".utf8))

        try Data("solid old".utf8).write(to: destination)
        try exportModelFile(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), Data("solid new".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".") }
        XCTAssertEqual(leftovers, [])
    }

    func testExportFailsWhenSourceIsMissingAndLeavesDestinationAlone() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let destination = folder.appendingPathComponent("export.stl")
        try Data("keep".utf8).write(to: destination)
        XCTAssertThrowsError(try exportModelFile(from: folder.appendingPathComponent("missing.stl"), to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("keep".utf8))
        XCTAssertTrue(missingLibraryFileMessage(name: "Bracket").contains("“Bracket”"))
    }

    // MARK: Local/cloud links

    func testLocalModelLinkedToRemoteID() {
        let newer = LocalModel(name: "Newer", filePath: "/tmp/a.stl", remoteID: "file-1")
        let older = LocalModel(name: "Older", filePath: "/tmp/b.stl", remoteID: "file-1")
        let unlinked = LocalModel(name: "Unlinked", filePath: "/tmp/c.stl")
        let models = [newer, unlinked, older]
        XCTAssertEqual(localModel(linkedTo: "file-1", in: models)?.id, newer.id)
        XCTAssertNil(localModel(linkedTo: "file-2", in: models))
        XCTAssertNil(localModel(linkedTo: "", in: models))
        XCTAssertNil(localModel(linkedTo: "file-1", in: []))
    }

    func testReuploadConfirmationNamesTheSameNameCheck() {
        // Slant keeps one file per owner and name, so the old "second file, not replaced" promise was false.
        let message = reuploadConfirmationMessage(name: "Bracket")
        XCTAssertTrue(message.contains("“Bracket”"))
        XCTAssertTrue(message.contains("asks before replacing"))
        XCTAssertFalse(message.contains("second file"))
        XCTAssertFalse(message.contains("not replaced"))
    }

    // MARK: Prepared material

    private let filaments = [
        Record(values: ["publicId": "pla", "name": "PLA Black", "profile": "PLA"]),
        Record(values: ["publicId": "petg", "name": "PETG Black", "profile": "PETG"]),
        Record(values: ["publicId": "petg-out", "name": "PETG Clear", "profile": "PETG", "available": false])
    ]

    func testPreparedMaterialMismatchOffersSavedMaterial() {
        let mismatch = preparedMaterialMismatch(recipeFilamentID: "petg", selectedFilamentID: "pla", filaments: filaments)
        XCTAssertEqual(mismatch, PreparedMaterialMismatch(filamentID: "petg", name: "PETG Black", available: nil))
        XCTAssertTrue(mismatch!.canApply)
        XCTAssertTrue(preparedMaterialMismatchMessage(mismatch!).contains("PETG Black"))
        XCTAssertEqual(preparedMaterialMismatch(recipeFilamentID: "petg", selectedFilamentID: "", filaments: filaments)?.filamentID, "petg")
    }

    func testPreparedMaterialMismatchIsNilWhenMatchingMissingOrNotLoaded() {
        XCTAssertNil(preparedMaterialMismatch(recipeFilamentID: "petg", selectedFilamentID: "petg", filaments: filaments))
        XCTAssertNil(preparedMaterialMismatch(recipeFilamentID: nil, selectedFilamentID: "pla", filaments: filaments))
        XCTAssertNil(preparedMaterialMismatch(recipeFilamentID: "  ", selectedFilamentID: "pla", filaments: filaments))
        XCTAssertNil(preparedMaterialMismatch(recipeFilamentID: "petg", selectedFilamentID: "pla", filaments: []))
    }

    func testPreparedMaterialMismatchForUnlistedOrOutOfStockCannotApply() {
        let unlisted = preparedMaterialMismatch(recipeFilamentID: "gone", selectedFilamentID: "pla", filaments: filaments)!
        XCTAssertNil(unlisted.name)
        XCTAssertFalse(unlisted.canApply)
        XCTAssertTrue(preparedMaterialMismatchMessage(unlisted).contains("no longer listed"))
        let out = preparedMaterialMismatch(recipeFilamentID: "petg-out", selectedFilamentID: "pla", filaments: filaments)!
        XCTAssertEqual(out.available, false)
        XCTAssertFalse(out.canApply)
        XCTAssertTrue(preparedMaterialMismatchMessage(out).contains("out of stock"))
    }

    // MARK: Scale

    func testScaleWarningFlagsTinyModelsWithPlausibleFactors() {
        let warning = scaleWarning(extentMM: SIMD3(2, 1, 0.5))!
        XCTAssertEqual(warning.largestMM, 2)
        XCTAssertEqual(warning.suggestions.map(\.factor), [25.4, 10])
        XCTAssertEqual(warning.suggestions.first?.title, "Save Copy ×25.4 (inches → 50.8 mm)")
        XCTAssertTrue(warning.message.contains("2.00 mm"))
        XCTAssertEqual(scaleWarning(extentMM: SIMD3(0.12, 0.05, 0.02))?.suggestions.map(\.factor), [25.4, 1000])
    }

    func testScaleWarningLeavesLargeModelsToBuildVolumeWarning() {
        // The preview already flags models larger than the build volume; the scale check doesn't repeat it.
        XCTAssertNil(scaleWarning(extentMM: SIMD3(50_000, 20_000, 10_000)))
        XCTAssertNil(scaleWarning(extentMM: SIMD3(1500, 10, 10)))
        XCTAssertNil(scaleWarning(extentMM: SIMD3(slantBuildVolumeMM + 1, 1, 1)))
    }

    func testScaleSuggestionsAreCappedAtBuildVolume() {
        // ×1000 would give 500 mm, which Slant can't print, so it isn't offered.
        XCTAssertEqual(scaleWarning(extentMM: SIMD3(0.5, 0.1, 0.1))?.suggestions.map(\.factor), [25.4, 10])
        // Exactly the build volume is still offered.
        let edge = scaleWarning(extentMM: SIMD3(0.22, 0.1, 0.1))!
        XCTAssertEqual(edge.suggestions.map(\.factor), [25.4, 1000])
        XCTAssertTrue(edge.suggestions.allSatisfy { $0.resultLargestMM <= slantBuildVolumeMM })
        // Too big at every factor: the warning stays, with no copy offered.
        XCTAssertEqual(scaleWarning(extentMM: SIMD3(2.9, 1, 1))?.suggestions.map(\.factor), [25.4, 10])
        XCTAssertEqual(scaleWarning(extentMM: SIMD3(0.001, 0.001, 0.001))?.suggestions, [])
    }

    func testScaleWarningIgnoresNormalAndDegenerateBoxes() {
        XCTAssertNil(scaleWarning(extentMM: SIMD3(3, 1, 1)))
        XCTAssertNil(scaleWarning(extentMM: SIMD3(120, 80, 40)))
        XCTAssertNil(scaleWarning(extentMM: SIMD3(1000, 1, 1)))
        XCTAssertNil(scaleWarning(extentMM: .zero))
        XCTAssertNil(scaleWarning(extentMM: SIMD3(.nan, .nan, .nan)))
        XCTAssertNil(scaleWarning(extentMM: SIMD3(.infinity, 1, 1)))
        XCTAssertNotNil(scaleWarning(extentMM: SIMD3(2, 0, 0)))
    }

    func testSmallPartAdvisoryBelowSlantsRecommendedSizeCoexistsWithTheScaleCheck() {
        XCTAssertEqual(smallPartAdvisory(extentMM: SIMD3(19.9, 5, 5)), "Slant recommends parts at least about 20 mm across; smaller parts may print poorly.")
        XCTAssertEqual(smallPartAdvisory(extentMM: SIMD3(12, 8, 4)), smallPartAdvisoryText)
        // At or above 20 mm on the largest side, nothing to say.
        XCTAssertNil(smallPartAdvisory(extentMM: SIMD3(20, 1, 1)))
        XCTAssertNil(smallPartAdvisory(extentMM: SIMD3(120, 80, 40)))
        // Under 3 mm, both the unit check and the size advice apply.
        let tiny = SIMD3<Float>(2, 1, 0.5)
        XCTAssertNotNil(scaleWarning(extentMM: tiny))
        XCTAssertEqual(smallPartAdvisory(extentMM: tiny), smallPartAdvisoryText)
        // Between 3 and 20 mm only the size advice applies; the 3 mm check is unchanged.
        XCTAssertNil(scaleWarning(extentMM: SIMD3(10, 10, 10)))
        XCTAssertNotNil(smallPartAdvisory(extentMM: SIMD3(10, 10, 10)))
        // Empty or unreadable boxes say nothing.
        XCTAssertNil(smallPartAdvisory(extentMM: .zero))
        XCTAssertNil(smallPartAdvisory(extentMM: SIMD3(.nan, 5, 5)))
        XCTAssertNil(smallPartAdvisory(extentMM: SIMD3(.infinity, 1, 1)))
        for banned in ["strong", "safe", "guaranteed", "can’t", "cannot", "blocked"] {
            XCTAssertFalse(smallPartAdvisoryText.lowercased().contains(banned), banned)
        }
    }

    func testScaledCopyOnlyForPlainImports() {
        var model = LocalModel(name: "Bracket", filePath: "/tmp/bracket.stl")
        XCTAssertTrue(canSaveScaledCopy(model))
        model.printRecipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "src", intent: PartIntent(), orientation: .zUp, materialID: nil, created: Date())
        XCTAssertFalse(canSaveScaledCopy(model))
        // OBJ now previews, so a tiny OBJ can be saved as a scaled STL copy; files without a preview still can't.
        XCTAssertTrue(canSaveScaledCopy(LocalModel(name: "Mesh", filePath: "/tmp/mesh.obj")))
        XCTAssertFalse(canSaveScaledCopy(LocalModel(name: "Mesh", filePath: "/tmp/mesh.step")))
        XCTAssertEqual(scaledCopyName("Bracket", factor: 25.4), "Bracket-scaled-x25.4")
        XCTAssertEqual(scaledCopyName("Bracket", factor: 0.001), "Bracket-scaled-x0.001")
    }

    func testScaledCopyNameDropsModelFileExtension() {
        XCTAssertEqual(scaledCopyName("bracket.stl", factor: 25.4), "bracket-scaled-x25.4")
        XCTAssertEqual(scaledCopyName("Part.STL", factor: 10), "Part-scaled-x10")
        XCTAssertEqual(scaledCopyName("mesh.Obj", factor: 10), "mesh-scaled-x10")
        XCTAssertEqual(scaledCopyName("case.3mf", factor: 1000), "case-scaled-x1000")
        XCTAssertEqual(scaledCopyName("bracket.stl.stl", factor: 10), "bracket.stl-scaled-x10", "only one extension is dropped")
        XCTAssertEqual(scaledCopyName("bracket v1.2", factor: 10), "bracket v1.2-scaled-x10", "other suffixes are kept")
        XCTAssertEqual(scaledCopyName("notes.step", factor: 10), "notes.step-scaled-x10")
        XCTAssertEqual(scaledCopyName(".stl", factor: 10), ".stl-scaled-x10", "a bare extension is not stripped to nothing")
    }

    private func cube(size: Float) -> STLMesh {
        let p: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(size, 0, 0), SIMD3(size, size, 0), SIMD3(0, size, 0),
            SIMD3(0, 0, size), SIMD3(size, 0, size), SIMD3(size, size, size), SIMD3(0, size, size)
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)
        ]
        let vertices = faces.flatMap { [p[$0.0], p[$0.1], p[$0.2]] }.flatMap { [$0.x, $0.y, $0.z] }
        return STLMesh(vertices: vertices, minimum: .zero, maximum: SIMD3(repeating: size))
    }

    func testScaledSTLDataScalesUniformlyAndParses() throws {
        let source = cube(size: 2)
        let parsed = try STLMesh.parse(try source.scaledSTLData(by: 25.4))
        XCTAssertEqual(parsed.triangleCount, source.triangleCount)
        let extent = parsed.maximum - parsed.minimum
        for axis in 0..<3 { XCTAssertEqual(extent[axis], 50.8, accuracy: 0.001) }
        XCTAssertNil(scaleWarning(extentMM: extent))
        // The source mesh is a value and is unchanged.
        XCTAssertEqual(source.maximum, SIMD3(repeating: 2))
    }

    func testScaledSTLDataRejectsInvalidFactors() {
        let source = cube(size: 2)
        XCTAssertThrowsError(try source.scaledSTLData(by: 0))
        XCTAssertThrowsError(try source.scaledSTLData(by: -25.4))
        XCTAssertThrowsError(try source.scaledSTLData(by: .nan))
        XCTAssertThrowsError(try source.scaledSTLData(by: .infinity))
    }

    func testScaledSTLDataRejectsCollapsedTriangles() {
        // Shrinking far enough underflows the coordinates to zero, which must not be saved.
        XCTAssertThrowsError(try cube(size: 2).scaledSTLData(by: 1e-45))
    }

    // MARK: Menus

    func testGoMenuOwnsUniqueNumberShortcuts() {
        XCTAssertEqual(goMenuShortcut(for: .models), "1")
        XCTAssertEqual(goMenuShortcut(for: .orders), "2")
        XCTAssertEqual(goMenuShortcut(for: .catalog), "3")
        // Developer destinations never take a number, so ⌘1–⌘3 don't move when developer tools are switched.
        XCTAssertNil(goMenuShortcut(for: .api))
        XCTAssertNil(goMenuShortcut(for: .activity))
        // Platforms live in Settings now; no Go item or shortcut.
        XCTAssertNil(goMenuShortcut(for: .platforms))
        for showDeveloperTools in [false, true] {
            let destinations = goMenuDestinations(showDeveloperTools: showDeveloperTools)
            let keys = destinations.compactMap(goMenuShortcut(for:))
            XCTAssertEqual(keys, ["1", "2", "3"])
            // File menu shortcuts use letters; Go never takes them.
            XCTAssertTrue(Set(keys).isDisjoint(with: ["n", "o", "r", "e"]))
            XCTAssertEqual(destinations, sidebarDestinations(showDeveloperTools: showDeveloperTools))
            XCTAssertEqual(destinations.count, Set(destinations).count)
        }
        XCTAssertEqual(goMenuDestinations(showDeveloperTools: false), [.models, .orders, .catalog])
        XCTAssertEqual(goMenuDestinations(showDeveloperTools: true), [.models, .orders, .catalog, .api, .activity])
    }

    func testModelFileCommandsEnabledOnlyForSelectedLocalModelOnModels() {
        XCTAssertTrue(modelFileCommandsEnabled(destination: .models, hasSelectedLocal: true, sheetPresented: false))
        XCTAssertFalse(modelFileCommandsEnabled(destination: .models, hasSelectedLocal: false, sheetPresented: false))
        XCTAssertFalse(modelFileCommandsEnabled(destination: .orders, hasSelectedLocal: true, sheetPresented: false))
        XCTAssertFalse(modelFileCommandsEnabled(destination: .models, hasSelectedLocal: true, sheetPresented: true))
    }

    func testModalStateCountsSheetsDialogsAndModalPanels() {
        XCTAssertFalse(AppModalState().isPresenting)
        // A Pay/Cancel review or confirmation dialog: the key window is the sheet itself.
        XCTAssertTrue(AppModalState(keyWindowIsSheet: true).isPresenting)
        // A sheet on any window, even when another window is key.
        XCTAssertTrue(AppModalState(anyWindowHasSheet: true).isPresenting)
        // An app-modal panel such as Export's save panel.
        XCTAssertTrue(AppModalState(hasModalWindow: true).isPresenting)
    }

    func testStaleRenameIDDoesNotCountAsPresentedSheet() {
        let model = LocalModel(name: "Bracket", filePath: "/tmp/bracket.stl")
        XCTAssertFalse(renameSheetIsShown(renamingModelID: nil, models: [model]))
        XCTAssertTrue(renameSheetIsShown(renamingModelID: model.id, models: [model]))
        XCTAssertFalse(renameSheetIsShown(renamingModelID: UUID(), models: [model]), "a removed model's rename must not block menus")
    }
}
