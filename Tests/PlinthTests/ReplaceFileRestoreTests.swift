import XCTest
@testable import Plinth

/// A Models Replace File that stopped before any bytes could be sent puts back the library links it cleared before
/// sending (owner decision, delegated, 13 Nov 2026), only where that is still safe; Upload from URL is unchanged. Pure
/// helpers and source checks only (never `StudioStore()`); every name and ID is invented.
final class ReplaceFileRestoreTests: XCTestCase {
    private func model(_ name: String, _ link: String?) -> LocalModel {
        LocalModel(name: name, filePath: "/x/\(name).stl", remoteID: link)
    }

    // MARK: What the unlinking clears

    func testTheClearedLinksMirrorTheUnlinking() {
        let bracket = model("Bracket", "file-f"), padded = model("Bracket (copy)", " file-f "), hook = model("Hook", "file-h")
        let uploaded = model("Bracket v2", "file-g"), loose = model("Loose", nil), blank = model("Blank", "  ")
        let library = [bracket, padded, hook, uploaded, loose, blank]
        let links = replaceFileClearedLinks(models: library, replacedFileID: "file-f", uploadedModelID: uploaded.id)
        // Every model linked to the replaced file (trimmed, as `clearLinks` matches), each link exactly as stored, and
        // the uploaded model's own link to another file (its earlier upload under another name).
        XCTAssertEqual(links, [bracket.id: "file-f", padded.id: " file-f ", uploaded.id: "file-g"])
        // A blank link has nothing to put back, even on the uploaded model.
        XCTAssertEqual(replaceFileClearedLinks(models: library, replacedFileID: "file-f", uploadedModelID: blank.id),
                       [bracket.id: "file-f", padded.id: " file-f "])
        // Upload from URL unlinks no uploaded model.
        XCTAssertEqual(replaceFileClearedLinks(models: library, replacedFileID: "file-h", uploadedModelID: nil), [hook.id: "file-h"])
        // No library model linked to the replaced file (a Slant file with the same name): only the uploaded model's link.
        XCTAssertEqual(replaceFileClearedLinks(models: library, replacedFileID: "file-z", uploadedModelID: uploaded.id),
                       [uploaded.id: "file-g"])
        XCTAssertEqual(replaceFileClearedLinks(models: library, replacedFileID: "file-z", uploadedModelID: loose.id), [:])
        // A blank file ID matches nothing.
        XCTAssertEqual(replaceFileClearedLinks(models: library, replacedFileID: "", uploadedModelID: nil), [:])
    }

    // MARK: Which links come back

    func testOnlyModelsStillThereAndStillUnlinkedComeBack() {
        let a = model("A", nil), b = model("B", nil), m = model("M", nil)
        let cleared: [UUID: String] = [a.id: "file-f", b.id: "file-f", m.id: "file-g"]
        // Two models that shared the file before (a Download a Separate Copy pair) both come back, as they were.
        XCTAssertEqual(replaceFileLinksToRestore(cleared, models: [a, b, m]), cleared)
        // Removed meanwhile: skipped.
        XCTAssertEqual(replaceFileLinksToRestore(cleared, models: [b, m]), [b.id: "file-f", m.id: "file-g"])
        // Linked to something else meanwhile: skipped, and its new link blocks that file for the others.
        var relinked = a
        relinked.remoteID = "file-g"
        XCTAssertEqual(replaceFileLinksToRestore(cleared, models: [relinked, b, m]), [b.id: "file-f"])
        // A blank link counts as unlinked.
        var blankA = a
        blankA.remoteID = " "
        XCTAssertEqual(replaceFileLinksToRestore(cleared, models: [blankA, b, m]), cleared)
    }

    func testAModelThatNowLinksTheFileBlocksIt() {
        let a = model("A", nil), m = model("M", nil)
        let cleared: [UUID: String] = [a.id: "file-f", m.id: "file-g"]
        // Edit › Undo put back a model linked to G (G was never recorded as changed): M stays unlinked, one model per file.
        let undone = model("Gear", "file-g")
        XCTAssertEqual(replaceFileLinksToRestore(cleared, models: [a, m, undone]), [a.id: "file-f"])
        // Matched trimmed either way.
        let padded = model("Gear", " file-f ")
        XCTAssertEqual(replaceFileLinksToRestore(cleared, models: [a, m, padded]), [m.id: "file-g"])
        XCTAssertEqual(replaceFileLinksToRestore([a.id: " file-f "], models: [a, model("Other", "file-f")]), [:])
    }

    func testARawLinkComesBackExactlyAsStored() {
        let a = model("A", nil)
        XCTAssertEqual(replaceFileLinksToRestore([a.id: " file-f\n"], models: [a]), [a.id: " file-f\n"])
        XCTAssertEqual(replaceFileLinksToRestore([:], models: [a]), [:])
    }

    // MARK: The models named afterwards

    func testTheModelsLeftUnlinkedAreNamedInLibraryOrder() {
        let a = model("Alpha", nil), b = model("Beta", nil), c = model("Gamma", nil), d = model("Delta", "file-d")
        let cleared: [UUID: String] = [c.id: "file-f", a.id: "file-f", b.id: "file-g"]
        // Library order, not the cleared map's.
        XCTAssertEqual(replaceFileModelsLeftUnlinked(cleared, restoring: [:], models: [c, d, b, a]), ["Gamma", "Beta", "Alpha"])
        XCTAssertEqual(replaceFileModelsLeftUnlinked(cleared, restoring: [a.id: "file-f"], models: [a, b, c]), ["Beta", "Gamma"])
        // Every link came back: nothing to name.
        XCTAssertEqual(replaceFileModelsLeftUnlinked(cleared, restoring: cleared, models: [a, b, c]), [])
        // A model removed meanwhile isn't named; one linked to something else meanwhile isn't unlinked.
        var relinked = b
        relinked.remoteID = "file-h"
        XCTAssertEqual(replaceFileModelsLeftUnlinked(cleared, restoring: [:], models: [relinked, c]), ["Gamma"])
        // Current names: a model renamed meanwhile is named as it is now.
        var renamed = a
        renamed.name = "Alpha (renamed)"
        XCTAssertEqual(replaceFileModelsLeftUnlinked([a.id: "file-f"], restoring: [:], models: [renamed]), ["Alpha (renamed)"])
    }

    // MARK: The selected file

    func testTheSelectedFileComesBackOnlyWhileTheSelectionStayed() {
        let m = UUID(), other = UUID()
        let restoredM: [UUID: String] = [m: " file-f "]
        func after(selected: UUID?, fileID: String = "", restored: [UUID: String]? = nil,
                   cleared: (localID: UUID?, fileID: String), replaced: String = "file-f") -> String? {
            replaceFileSelectedFileAfterRestore(selectedLocalID: selected, fileID: fileID, restored: restored ?? restoredM,
                                                clearedSelection: cleared, replacedFileID: replaced)
        }
        // 1. The selected model's link came back: it is the selected file again, as stored (as selecting it would).
        XCTAssertEqual(after(selected: m, cleared: (m, " file-f ")), " file-f ")
        XCTAssertEqual(after(selected: m, cleared: (other, "file-o")), " file-f ", "selected meanwhile: select() gave it a blank file")
        // 2. No model selected, then or now, and the replaced file was the selected Slant file: selected again.
        XCTAssertEqual(after(selected: nil, cleared: (nil, " file-f")), " file-f")
        XCTAssertNil(after(selected: nil, cleared: (nil, "file-o")), "another file was selected then: nothing to put back")
        XCTAssertNil(after(selected: nil, cleared: (nil, "")))
        XCTAssertNil(after(selected: nil, cleared: (m, " file-f ")), "a model was selected then; the selection moved")
        // 3. The selection moved to a model whose link didn't come back (an imported model, another unlinked one).
        XCTAssertNil(after(selected: other, cleared: (m, " file-f ")))
        XCTAssertNil(after(selected: m, restored: [:], cleared: (m, " file-f ")), "its link didn't come back")
        // 4. A file is selected now: left alone.
        XCTAssertNil(after(selected: m, fileID: "file-o", cleared: (m, " file-f ")))
        XCTAssertNil(after(selected: nil, fileID: "file-o", cleared: (nil, "file-f")))
    }

    // MARK: Copy

    func testNothingIsAddedWhenEveryLinkCameBack() {
        XCTAssertNil(uploadReplacementRestoreNote(fileName: "Bracket", leftUnlinked: [], restoreNotSaved: false))
        // Models left unlinked keep the shared note's wording.
        XCTAssertEqual(uploadReplacementRestoreNote(fileName: "Bracket", leftUnlinked: ["Bracket (old)"], restoreNotSaved: false),
                       uploadReplacementUnlinkedNote(fileName: "Bracket", modelNames: ["Bracket (old)"]))
        XCTAssertEqual(uploadReplacementRestoreNote(fileName: "Bracket", leftUnlinked: ["Bracket (old)"], restoreNotSaved: false),
                       "Before sending, Plinth unlinked “Bracket (old)” to replace “Bracket”, and it stays unlinked: upload it again before you use it in an order.")
        // A restore that couldn't be saved says so first, with the disk-space advice the save's own alert would have
        // given (the upload's message replaces it), agreeing in number with the models named after it.
        XCTAssertEqual(uploadReplacementRestoreNote(fileName: " ", leftUnlinked: ["A", "B"], restoreNotSaved: true),
                       "Plinth couldn’t save your library (check that your Mac has free disk space), so it couldn’t link these models again. Before sending, Plinth unlinked 2 models in your library to replace your Slant file, and they stay unlinked: upload them again before you use them in an order.")
        XCTAssertEqual(uploadReplacementRestoreNote(fileName: "Bracket", leftUnlinked: ["Bracket (old)"], restoreNotSaved: true),
                       "Plinth couldn’t save your library (check that your Mac has free disk space), so it couldn’t link this model again. Before sending, Plinth unlinked “Bracket (old)” to replace “Bracket”, and it stays unlinked: upload it again before you use it in an order.")
        XCTAssertEqual(uploadReplacementRestoreNote(fileName: "Bracket", leftUnlinked: [], restoreNotSaved: true),
                       uploadReplacementRestoreNotSavedNote(modelCount: 0))
        XCTAssertFalse(uploadReplacementRestoreNotSavedNote(modelCount: 2).contains("cleared"), "the seller's word is unlinked")
    }

    // MARK: Where it runs

    func testOnlyAModelsReplaceFileThatSentNothingPutsLinksBack() throws {
        let store = try source("StudioStore.swift")
        let upload = try functionBody("func uploadModel(id: UUID, as uploadName: String", in: store)
        // Called once, only when no bytes can have been sent.
        XCTAssertEqual(upload.components(separatedBy: "restoreLinksAfterReplaceSentNothing(").count, 2)
        XCTAssertTrue(upload.contains("if let cleared = clearedBeforeSending, !uploadReplacementMayBePartial(stage: failedStage, replacingFileID: replacedID) {\n                let restored = self.restoreLinksAfterReplaceSentNothing(cleared)"))
        // It comes after the part-way branch, which still clears every link and returns.
        let partial = try XCTUnwrap(upload.range(of: "if uploadReplacementMayBePartial(stage: failedStage, replacingFileID: replacedID) {"))
        let restore = try XCTUnwrap(upload.range(of: "self.restoreLinksAfterReplaceSentNothing(cleared)"))
        XCTAssertLessThan(partial.lowerBound, restore.lowerBound)
        XCTAssertTrue(upload.contains("let others = unlinkedBeforeSending + self.clearLinks(toFileIDs: changed, alsoUnlinking: capturedID)"))
        // Never on success, and Upload from URL never calls it.
        let operation = try XCTUnwrap(upload.range(of: "let write = SlantWritesInFlight.shared.begin(.upload)"))
        XCTAssertFalse(upload[operation.lowerBound...].contains("restoreLinksAfterReplaceSentNothing"))
        let url = try functionBody("func importModelFromURL(", in: store)
        XCTAssertFalse(url.contains("restoreLinksAfterReplaceSentNothing"))
        XCTAssertFalse(url.contains("ReplaceFileClearedLinks"))
        XCTAssertTrue(url.contains("unlinkedBeforeSending = try clearLinksBeforeReplacing(fileID: replaced, alsoUnlinking: nil).otherNames"))
    }

    func testTheRestoreIsTargetedAndSaved() throws {
        let store = try source("StudioStore.swift")
        let body = try functionBody("private func restoreLinksAfterReplaceSentNothing(", in: store)
        XCTAssertTrue(body.contains("let restoring = replaceFileLinksToRestore(cleared.links, models: localModels)"))
        // Only this unlinking's bookkeeping is taken back; the changed set never grows here.
        XCTAssertTrue(body.contains("libraryUnlinkedFileIDs.subtract(cleared.addedChangedFileIDs)"))
        XCTAssertTrue(body.contains("for (id, uploader) in cleared.removedUploaders where libraryFileUploadedBy[id] == nil {"))
        XCTAssertFalse(body.contains("formUnion"))
        XCTAssertFalse(body.contains("libraryCarriedEntries = libraryCarriedEntriesDroppingLinks"), "carried entries keep their dropped links")
        XCTAssertFalse(body.contains("estimate"), "the estimate stays cleared")
        // A failed save puts everything back, so memory matches the file (links cleared).
        let save = try XCTUnwrap(body.range(of: "guard saveModels() else {"))
        let revert = body[save.lowerBound...]
        for line in ["localModels = models", "fileID = selectedFile", "libraryUnlinkedFileIDs = unlinkedIDs",
                     "libraryFileUploadedBy = uploadedBy", "libraryCarriedEntries = carried"] {
            XCTAssertTrue(revert.contains(line), line)
        }
        XCTAssertTrue(revert.contains("return (replaceFileModelsLeftUnlinked(cleared.links, restoring: [:], models: localModels), true)"))
        // The snapshots are taken before anything changes.
        let snapshot = try XCTUnwrap(body.range(of: "let models = localModels, selectedFile = fileID"))
        let firstChange = try XCTUnwrap(body.range(of: "localModels[index].remoteID = link"))
        XCTAssertLessThan(snapshot.lowerBound, firstChange.lowerBound)
        // Only what the restore changed is reverted: no whole snapshot from before the upload is ever applied.
        let clearing = try functionBody("private func clearLinksBeforeReplacing(", in: store)
        XCTAssertTrue(clearing.contains("let links = replaceFileClearedLinks(models: models, replacedFileID: replacedID, uploadedModelID: modelID)\n        let others = clearLinks(toFileIDs: [replacedID], alsoUnlinking: modelID)"))
        XCTAssertTrue(clearing.contains("addedChangedFileIDs: libraryUnlinkedFileIDs.subtracting(unlinkedIDs)"))
        XCTAssertTrue(clearing.contains("removedUploaders: uploadedBy.filter { libraryFileUploadedBy[$0.key] == nil }"))
        // `clearLinks` matches through `modelsLinked`, as `replaceFileClearedLinks` does.
        let clearLinks = try functionBody("private func clearLinks(toFileIDs fileIDs: Set<String>", in: store)
        XCTAssertTrue(clearLinks.contains("let affected = modelsLinked(toFileIDs: fileIDs, in: localModels)"))
        XCTAssertTrue(clearLinks.contains("where affected.contains(localModels[index].id) || localModels[index].id == modelID {"))
    }

    // MARK: Helpers

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from `signature` to the brace that closes its body, which opens at the last character of the first
    /// `opening` from `signature` on.
    private func functionBody(_ signature: String, opening: String = "{", in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), signature)
        let openRange = try XCTUnwrap(source.range(of: opening, range: start.lowerBound..<source.endIndex), signature)
        let open = source.index(before: openRange.upperBound)
        XCTAssertEqual(source[open], "{", signature)
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        throw XCTSkip("unbalanced braces after \(signature)")
    }
}
