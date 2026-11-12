import XCTest
@testable import Plinth

/// Round 22: Replace File's name and target check (I4-1), the same-name key (C2-2), the note for links a Replace File
/// cleared before stopping (I4-2), the library save before sending (I4-3), storage download wording (C2-3), storage
/// and picture links (I1-2, I4-8, I1-3) and the Workbench's secret and file bookkeeping (I4-4, I4-5). Pure helpers
/// only; every name and ID is invented.
final class UploadsRound22Tests: XCTestCase {
    private func files(_ names: [String]) -> [Record] {
        names.enumerated().map { Record(values: ["publicFileServiceId": "file-\($0.offset)", "name": $0.element]) }
    }

    private func conflict(name: String, existing: String, fileID: String? = "file-f") -> UploadNameConflict {
        UploadNameConflict(modelID: UUID(), name: name, existing: existing, existingFileID: fileID, suggested: "\(name) 2",
                           ownEarlierUpload: false, earlierUploadUnconfirmed: false, protectedFiles: [:], protectedWhenReplacing: [:])
    }

    // MARK: I4-1 Replace File sends the listed name and stops for another file

    func testReplaceFileSendsTheListedFilesOwnName() {
        XCTAssertEqual(uploadReplaceFileName(conflict(name: "bracket", existing: "Bracket")), "Bracket", "case only")
        XCTAssertEqual(uploadReplaceFileName(conflict(name: "Phone   Stand", existing: "Phone Stand")), "Phone Stand", "spacing only")
        XCTAssertEqual(uploadReplaceFileName(conflict(name: "Hook", existing: "Hook.stl")), "Hook.stl", "a model ending only")
        XCTAssertEqual(uploadReplaceFileName(conflict(name: "Hook", existing: "  Hook  ")), "Hook", "trimmed")
        XCTAssertEqual(uploadReplaceFileName(conflict(name: "Hook", existing: "   ")), "Hook", "a blank listed name falls back")
        // The check's own conflict carries the listed name through.
        let result = slantUploadNameCheckResult(name: "bracket", linkedFileID: nil, files: files(["Bracket.stl"]))
        let fromCheck = UploadNameConflict(result: result, modelID: UUID(), earlierUploadUnconfirmed: false)
        XCTAssertEqual(fromCheck.map(uploadReplaceFileName), "Bracket.stl")
        XCTAssertEqual(fromCheck?.name, "bracket", "Upload Again's confirmation keeps the checked name")
    }

    func testPlaceholderMismatchNeedsBothIDsAndADifference() {
        XCTAssertTrue(uploadReplacePlaceholderMismatch(["publicFileServiceId": "file-g"], replacingFileID: "file-f"))
        XCTAssertTrue(uploadReplacePlaceholderMismatch(["id": 7, "publicFileServiceId": " file-g "], replacingFileID: " file-f "))
        XCTAssertFalse(uploadReplacePlaceholderMismatch(["publicFileServiceId": " file-f "], replacingFileID: "file-f"), "same after trimming")
        XCTAssertFalse(uploadReplacePlaceholderMismatch(["id": 7], replacingFileID: "file-f"), "no ID passes, as the guard does")
        XCTAssertFalse(uploadReplacePlaceholderMismatch(["publicFileServiceId": "  "], replacingFileID: "file-f"))
        XCTAssertFalse(uploadReplacePlaceholderMismatch(["publicFileServiceId": 42], replacingFileID: "file-f"))
        XCTAssertFalse(uploadReplacePlaceholderMismatch(["publicFileServiceId": "file-g"], replacingFileID: nil), "not a Replace File")
        XCTAssertFalse(uploadReplacePlaceholderMismatch(["publicFileServiceId": "file-g"], replacingFileID: "  "), "the file's ID wasn't listed")
    }

    func testMismatchAndLibrarySaveFailuresAreWordedAsNothingSent() {
        let mismatch = UploadReplaceWouldCreateNewFile(fileName: "Bracket")
        XCTAssertFalse(uploadOutcomeUnknown(stage: .preparing, error: mismatch))
        XCTAssertFalse(uploadReplacementMayBePartial(stage: .preparing, replacingFileID: "file-f"))
        XCTAssertEqual(uploadFailureMessage(stage: .preparing, error: mismatch),
                       "Nothing was uploaded, and “Bracket” wasn’t changed: Slant would have saved this as a new file. To add it as a new file, upload again (choose Upload as “…” if Plinth asks).")
        let unnamed = uploadFailureMessage(stage: .preparing, error: UploadReplaceWouldCreateNewFile(fileName: " "))
        XCTAssertTrue(unnamed.hasPrefix("Nothing was uploaded, and the file you chose wasn’t changed:"))
        XCTAssertLessThanOrEqual(unnamed.count, 180, "within friendlyAPIMessage's cut, so Activity shows it")
        XCTAssertEqual(friendlyAPIMessage(mismatch), uploadFailureMessage(stage: .preparing, error: mismatch))

        let notSaved = LibraryNotSavedBeforeUpload()
        XCTAssertFalse(uploadOutcomeUnknown(stage: nil, error: notSaved))
        XCTAssertFalse(uploadReplacementMayBePartial(stage: nil, replacingFileID: "file-f"))
        XCTAssertEqual(uploadFailureMessage(stage: nil, error: notSaved),
                       "Plinth couldn’t save your library, so nothing was uploaded and your Slant file wasn’t replaced. Check that your Mac has free disk space, then upload again.")
        // Upload from URL reports it through the window's usual wording, which must be the same text.
        XCTAssertEqual(friendlyAPIMessage(notSaved), libraryNotSavedBeforeUploadMessage)
        XCTAssertNil(uploadFromURLUnclearMessage(notSaved), "never read as an unclear outcome (which would clear links)")
    }

    func testUploadFromURLTypeComesFromTheTypedName() {
        // A Replace File sends the listed name, which may have no ending: the typed name keeps the right type.
        XCTAssertEqual(importModelType(url: "https://files.example.com/dl", name: "part.3mf"), "3mf")
        XCTAssertEqual(importModelType(url: "https://files.example.com/dl", name: "Part"), "stl")
        XCTAssertEqual(importModelType(url: "https://files.example.com/m.obj", name: "part.3mf"), "obj", "the link's ending still wins")
    }

    // MARK: I4-1 step 4, I4-2 notes

    func testUnlinkedNoteNamesTheModelsThatStayUnlinked() {
        XCTAssertNil(uploadReplacementUnlinkedNote(fileName: "Bracket", modelNames: []))
        XCTAssertEqual(uploadReplacementUnlinkedNote(fileName: "Bracket", modelNames: ["Bracket (old)"]),
                       "Before sending, Plinth unlinked “Bracket (old)” to replace “Bracket”, and it stays unlinked: upload it again before you use it in an order.")
        XCTAssertEqual(uploadReplacementUnlinkedNote(fileName: " ", modelNames: ["A", "B"]),
                       "Before sending, Plinth unlinked 2 models in your library to replace your Slant file, and they stay unlinked: upload them again before you use them in an order.")
    }

    func testSavedElsewhereNotice() {
        XCTAssertEqual(uploadReplaceSavedElsewhereNotice(uploadedName: "Hook", fileName: "Bracket", unlinkedNames: []),
                       "Slant saved “Hook” in another file instead of replacing “Bracket”, so drafts that use “Bracket” may still print the earlier model.")
        let withNote = uploadReplaceSavedElsewhereNotice(uploadedName: "Hook", fileName: "Bracket", unlinkedNames: ["Bracket (old)"])
        XCTAssertTrue(withNote.hasSuffix("Before sending, Plinth unlinked “Bracket (old)” to replace “Bracket”, and it stays unlinked: upload it again before you use it in an order."))
        XCTAssertTrue(uploadReplaceSavedElsewhereNotice(uploadedName: "Hook", fileName: "", unlinkedNames: [])
            .contains("instead of replacing the file you chose, so drafts that use the file you chose"))
    }

    func testPlainUploadFailuresAreUnchanged() {
        let limited = APIError.http(status: 429, body: "", retryAfter: nil, rateLimitReset: nil)
        XCTAssertEqual(uploadFailureMessage(stage: .preparing, error: limited), friendlyAPIMessage(limited))
        XCTAssertEqual(uploadFailureMessage(stage: .preparing, error: APIError.invalidResponse("x")), uploadLinkMissingMessage)
        XCTAssertEqual(uploadFailureMessage(stage: .preparing, error: UploadWouldOverwriteExistingFile(fileID: "file-k", fileName: "Kept")),
                       uploadWouldOverwriteMessage(fileName: "Kept"))
    }

    // MARK: C2-2 trailing model endings

    func testNameKeyStripsEveryTrailingModelEndingButNeverEverything() {
        XCTAssertEqual(slantUploadNameKey("Bracket.3mf.stl"), slantUploadNameKey("bracket"))
        XCTAssertEqual(slantUploadNameKey("Bracket.3mf"), slantUploadNameKey("bracket"))
        XCTAssertEqual(slantUploadNameKey(" Bracket .STL.Obj "), slantUploadNameKey("BRACKET"))
        XCTAssertEqual(slantUploadNameKey("a.stl.stl"), "a")
        XCTAssertFalse(slantUploadNameKey(".stl").isEmpty)
        XCTAssertFalse(slantUploadNameKey("stl.stl").isEmpty)
        XCTAssertEqual(slantUploadNameKey("stl.stl"), "stl")
        XCTAssertFalse(slantUploadNameKey(".stl.stl").isEmpty)
        // Only model endings: "v1.5" and ".step" are part of the name.
        XCTAssertNotEqual(slantUploadNameKey("Bracket v1.5"), slantUploadNameKey("Bracket v1"))
        XCTAssertNotEqual(slantUploadNameKey("Bracket.step"), slantUploadNameKey("Bracket"))

        XCTAssertEqual(slantUploadNameConflict(name: "Bracket.3mf", files: files(["Bracket.3mf.stl"])), "Bracket.3mf.stl")
        XCTAssertEqual(slantUploadNameConflict(name: "Bracket", files: files(["Bracket.obj.3mf"])), "Bracket.obj.3mf")
        XCTAssertEqual(slantUploadUniqueName(name: "Bracket.3mf", files: files(["Bracket 2.3mf.stl"])), "Bracket 3.3mf")
        XCTAssertNotNil(slantUploadNameConflict(name: ".stl", files: files([".stl"])), "an all-ending name still matches itself")
    }

    // MARK: C2-3 download wording

    func testStorageDownloadFailuresNeverBlameTheKey() {
        for status in [302, 403, 404, 500, 503] {
            let text = slantDownloadFailureMessage(status: status)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("API key"), "\(status)")
            XCTAssertTrue(text.contains("HTTP \(status)"), "\(status)")
            XCTAssertTrue(text.contains("storage"), "\(status)")
        }
        XCTAssertTrue(slantDownloadFailureMessage(status: 403).contains("fresh link"))
        XCTAssertTrue(slantDownloadFailureMessage(status: 404).contains("doesn’t have this model’s file"))
        XCTAssertTrue(slantDownloadFailureMessage(status: 502).contains("Try again in a moment"))
        XCTAssertTrue(slantDownloadFailureMessage(status: 302).contains("didn’t send the model"))
    }

    // MARK: I1-3 pictures

    func testPicturesFromLocalOrOddLinksAreNotLoaded() {
        for raw in ["https://192.168.1.2/p.png", "https://localhost/p.png", "https://cdn.example.com:8443/p.png",
                    "https://u:p@cdn.example.com/p.png", "https://printer.local/p.png", "https://[::1]/p.png", "https://cdn/p.png"] {
            XCTAssertNil(httpsPreviewImageURL(Record(values: ["imageURL": raw])), raw)
            XCTAssertNil(httpsPreviewImageURL(Record(values: ["metrics": ["imageUrl": raw]])), raw)
            XCTAssertNil(catalogItemImageURL(Record(values: ["imageUrl": raw])), raw)
        }
        for raw in ["https://slant-gatekeeper.s3.us-west-2.amazonaws.com/p.png?X-Amz-Signature=x", "https://cdn.slant3dapi.com/c.png",
                    "https://krakensystem.s3.us-west-2.amazonaws.com/c.png", "https://cdn.example.com:443/p.png"] {
            XCTAssertNotNil(httpsPreviewImageURL(Record(values: ["imageURL": raw])), raw)
            XCTAssertNotNil(catalogItemImageURL(Record(values: ["image_url": raw])), raw)
        }
    }

    // MARK: I4-4, I4-5 the Workbench

    func testWhichWorkbenchRequestsSetTheWebhookSecret() {
        XCTAssertTrue(workbenchSetsWebhookSecret(endpointID: "PATCH /platforms/{platformId}/webhook-secret", body: nil))
        XCTAssertTrue(workbenchSetsWebhookSecret(endpointID: "PATCH /platforms/{platformId}", body: ["webhookSecret": "s"]))
        XCTAssertTrue(workbenchSetsWebhookSecret(endpointID: "PATCH /platforms/{platformId}", body: ["name": "Shop", "webhookSecret": NSNull()]))
        XCTAssertFalse(workbenchSetsWebhookSecret(endpointID: "PATCH /platforms/{platformId}", body: ["name": "Shop"]))
        XCTAssertFalse(workbenchSetsWebhookSecret(endpointID: "PATCH /platforms/{platformId}", body: nil))
        XCTAssertFalse(workbenchSetsWebhookSecret(endpointID: "POST /platforms", body: ["webhookSecret": "s"]))
        XCTAssertFalse(workbenchSetsWebhookSecret(endpointID: "PATCH /platforms/{platformId}/enable", body: nil))
        // The failure rule is built on it.
        let unclear = APIError.http(status: 500, body: "", retryAfter: nil, rateLimitReset: nil)
        XCTAssertFalse(workbenchSecretChangeMayHaveHappened(endpointID: "PATCH /platforms/{platformId}", body: ["name": "Shop"], error: unclear))
        XCTAssertTrue(workbenchSecretChangeMayHaveHappened(endpointID: "PATCH /platforms/{platformId}", body: ["webhookSecret": "s"], error: unclear))
    }

    func testWorkbenchFileBookkeeping() {
        XCTAssertEqual(workbenchFileBookkeeping(endpointID: "POST /files", path: "/files", reply: ["publicFileServiceId": " file-f "]),
                       .contentsChanged("file-f"))
        XCTAssertEqual(workbenchFileBookkeeping(endpointID: "POST /files/confirm-upload", path: "/files/confirm-upload",
                                                reply: ["publicId": "file-g", "name": "Hook"]), .contentsChanged("file-g"))
        XCTAssertEqual(workbenchFileBookkeeping(endpointID: "POST /files", path: "/files", reply: ["id": 7, "name": "Hook"]), .none,
                       "a number or a name is never a file ID")
        XCTAssertEqual(workbenchFileBookkeeping(endpointID: "POST /files", path: "/files", reply: [:]), .none)
        XCTAssertEqual(workbenchFileBookkeeping(endpointID: "POST /files/direct-upload", path: "/files/direct-upload",
                                                reply: ["publicFileServiceId": "file-f"]), .none, "no bytes are sent from the Workbench")
        XCTAssertEqual(workbenchFileBookkeeping(endpointID: "DELETE /files/{publicFileId}", path: "/files/file-d", reply: [:]), .deleted("file-d"))
        XCTAssertEqual(workbenchFileBookkeeping(endpointID: "DELETE /files/{publicFileId}", path: "/files/", reply: [:]), .none)
        XCTAssertEqual(workbenchFileBookkeeping(endpointID: "GET /files/{publicFileId}", path: "/files/file-d",
                                                reply: ["publicFileServiceId": "file-d"]), .none)
    }

    func testWorkbenchUploadedName() {
        XCTAssertEqual(workbenchUploadedName(reply: ["name": " Hook "], body: ["name": "Other"]), "Hook")
        XCTAssertEqual(workbenchUploadedName(reply: [:], body: ["name": "Hook", "URL": "https://files.example.com/m.stl"]), "Hook")
        XCTAssertEqual(workbenchUploadedName(reply: ["name": 4], body: ["filePlaceholder": ["name": "Hook"]]), "Hook")
        XCTAssertEqual(workbenchUploadedName(reply: [:], body: nil), "the uploaded model")
    }
}
