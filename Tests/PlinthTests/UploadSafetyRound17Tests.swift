import XCTest
@testable import Plinth

/// Round 17 review fixes for uploads: the pre-PUT guard, a failed Replace File, Upload Again's name and dialog, the
/// same-name copy, suggested names, the rate-limit stop and the copy around them. All IDs and names are invented.
final class UploadSafetyRound17Tests: XCTestCase {
    private func file(_ id: Any?, _ name: Any?) -> Record {
        var values: [String: Any] = [:]
        if let id { values["publicFileServiceId"] = id }
        if let name { values["name"] = name }
        return Record(values: values)
    }

    // MARK: Pre-PUT guard

    func testPlaceholderGuardDecision() {
        let protected = ["file-a": "Bracket", "file-b": ""]
        XCTAssertEqual(uploadPlaceholderProtectedFile(["publicFileServiceId": "file-a"], protectedFiles: protected)?.name, "Bracket")
        XCTAssertEqual(uploadPlaceholderProtectedFile(["publicFileServiceId": " file-b\n"], protectedFiles: protected)?.id, "file-b")
        XCTAssertNil(uploadPlaceholderProtectedFile(["publicFileServiceId": "file-new"], protectedFiles: protected))
        XCTAssertNil(uploadPlaceholderProtectedFile(["id": 12], protectedFiles: ["12": "Number"]),
                     "the placeholder's integer id isn't a file ID")
        XCTAssertNil(uploadPlaceholderProtectedFile(["publicFileServiceId": 12], protectedFiles: ["12": "Number"]))
        XCTAssertNil(uploadPlaceholderProtectedFile(["publicFileServiceId": "  "], protectedFiles: protected))
        XCTAssertNil(uploadPlaceholderProtectedFile(["publicFileServiceId": "file-a"], protectedFiles: [:]))
        XCTAssertEqual(uploadPlaceholderFileID(["publicFileServiceId": " file-a "]), "file-a")
        XCTAssertNil(uploadPlaceholderFileID(["id": "file-a"]))
    }

    func testProtectedFilesAreEveryListedIDButTheReplacedOne() {
        let files = [file("file-a", "Bracket"), file(" file-b ", "Hook"), file(nil, "No ID"), file("file-a", "Later copy"), file(7, "Number")]
        XCTAssertEqual(uploadProtectedFiles(files), ["file-a": "Bracket", "file-b": "Hook"],
                       "own string IDs only, never a name; the first record's name is kept")
        XCTAssertEqual(uploadProtectedFiles(files, replacing: " file-a"), ["file-b": "Hook"])
        XCTAssertEqual(uploadProtectedFiles([]), [:])
    }

    func testPersonalisedUploadsProtectLoadedFilesAndLibraryLinks() {
        let files = [file("file-a", "Bracket")]
        let linked = LocalModel(name: "Stand", filePath: "/tmp/stand.stl", remoteID: " file-c ")
        let sameFile = LocalModel(name: "Bracket (old)", filePath: "/tmp/bracket.stl", remoteID: "file-a")
        let unlinked = LocalModel(name: "Clip", filePath: "/tmp/clip.stl")
        XCTAssertEqual(batchPersonaliseProtectedFiles(files: files, models: [linked, sameFile, unlinked]),
                       ["file-a": "Bracket", "file-c": "Stand"])
    }

    func testAGuardStopSkipsOnlyThatPersonalisedOrder() {
        let error = UploadWouldOverwriteExistingFile(fileID: "file-a", fileName: "Bracket")
        guard case .refused(let reason) = batchPersonaliseUploadOutcome(error: error) else { return XCTFail("a definite refusal") }
        XCTAssertTrue(reason.contains("nothing was uploaded"))
        XCTAssertFalse(reason.contains("Bracket"), "no file name in the import sheet's row")
        XCTAssertEqual(batchPersonaliseNextStep(after: .refused(reason, error), consecutiveRefusals: 1), .next,
                       "the batch goes on to the next order")
    }

    func testOverwriteCopy() {
        XCTAssertEqual(uploadWouldOverwriteMessage(fileName: " Hook "),
                       "Nothing was uploaded: Slant would have saved this into your existing file “Hook”. Choose another name and upload again.")
        XCTAssertTrue(uploadWouldOverwriteMessage(fileName: "").contains("one of your existing Slant files"))
        XCTAssertEqual(UploadWouldOverwriteExistingFile(fileID: "file-a", fileName: "Hook").localizedDescription,
                       uploadWouldOverwriteMessage(fileName: "Hook"))
    }

    // MARK: Failed Replace File

    func testReplacementMayBePartialFromTheStoragePUTOn() {
        let errors: [Error] = [URLError(.timedOut), URLError(.cannotFindHost), APIError.http(status: 403, body: "denied", retryAfter: nil, rateLimitReset: nil),
                               APIError.http(status: 400, body: #"{"message":"Bad placeholder"}"#, retryAfter: nil, rateLimitReset: nil), APIError.http(status: 500, body: "", retryAfter: nil, rateLimitReset: nil),
                               UploadConfirmMissingFileID()]
        for error in errors {
            for stage: UploadStage? in [.uploading, .confirming] {
                XCTAssertTrue(uploadReplacementMayBePartial(stage: stage, replacingFileID: "file-a"), "\(String(describing: stage)) \(error)")
                XCTAssertTrue(uploadReplacementMayBePartial(stage: stage, replacingFileID: ""),
                              "a Replace File whose file ID isn't known still counts")
                XCTAssertFalse(uploadReplacementMayBePartial(stage: stage, replacingFileID: nil), "not a Replace File")
            }
            for stage: UploadStage? in [.preparing, nil] {
                XCTAssertFalse(uploadReplacementMayBePartial(stage: stage, replacingFileID: "file-a"), "no bytes were sent")
            }
        }
    }

    func testReplacementPartialCopyNamesEveryAffectedModel() {
        let own = uploadReplacementPartialMessage(fileName: "Bracket", modelName: "Bracket", otherModelNames: [])
        XCTAssertTrue(own.contains("your Slant file “Bracket” may now hold part of this model"), own)
        XCTAssertTrue(own.contains("“Bracket” is no longer linked to that file; upload it again before you use it in an order."))
        let one = uploadReplacementPartialMessage(fileName: "Bracket", modelName: "Bracket v2", otherModelNames: ["Bracket"])
        XCTAssertTrue(one.contains("“Bracket” was linked to that file too and no longer is"), one)
        let many = uploadReplacementPartialMessage(fileName: "", modelName: "Bracket v2", otherModelNames: ["A", "B"])
        XCTAssertTrue(many.contains("the existing file in your Slant files"))
        XCTAssertTrue(many.contains("2 other models in your library"))
    }

    func testModelsLinkedToTheReplacedFile() {
        let a = LocalModel(name: "A", filePath: "/tmp/a.stl", remoteID: "file-a")
        let b = LocalModel(name: "B", filePath: "/tmp/b.stl", remoteID: " file-a ")
        let c = LocalModel(name: "C", filePath: "/tmp/c.stl", remoteID: "file-c")
        let d = LocalModel(name: "D", filePath: "/tmp/d.stl")
        XCTAssertEqual(modelsLinked(toFileIDs: ["file-a"], in: [a, b, c, d]), [a.id, b.id])
        XCTAssertEqual(modelsLinked(toFileIDs: ["file-a", "file-c"], in: [a, b, c, d]), [a.id, b.id, c.id])
        XCTAssertEqual(modelsLinked(toFileIDs: [], in: [a, b, c, d]), [])
    }

    func testUploadFromURLReplaceUnclearCopy() {
        let text = uploadFromURLReplaceUnclearMessage(URLError(.timedOut), fileName: "Bracket", modelNames: ["Bracket"])
        XCTAssertTrue(text.hasPrefix("Slant didn’t reply in time, so your Slant file “Bracket” may now hold this model"), text)
        XCTAssertTrue(text.contains("“Bracket” was linked to that file and no longer is"))
        XCTAssertTrue(text.contains("Refresh in the main window"))
        let none = uploadFromURLReplaceUnclearMessage(APIError.http(status: 502, body: "", retryAfter: nil, rateLimitReset: nil), fileName: "Bracket", modelNames: [])
        XCTAssertFalse(none.contains("linked"))
    }

    // MARK: Upload Again's name (C3) and the same-name dialog

    func testALinkedModelIsCheckedUnderItsCloudFilesName() {
        // "Bracket" (another model's file) and "Bracket 2" (this model's upload, made with Upload as…).
        let files = [file("file-a", "Bracket"), file("file-b", "Bracket 2")]
        let result = slantUploadNameCheckResult(name: "Bracket", linkedFileID: "file-b", files: files)
        XCTAssertEqual(result.name, "Bracket 2")
        XCTAssertEqual(result.check, .conflict(existing: "Bracket 2", suggested: "Bracket 2 2"))
        XCTAssertEqual(result.conflictFileID, "file-b")
        XCTAssertTrue(result.conflictIsLinkedFile)
        XCTAssertEqual(result.protectedFiles(replacing: result.conflictFileID), ["file-a": "Bracket"],
                       "Replace File can only write over this model's own file")
        XCTAssertEqual(result.protectedFiles(), ["file-a": "Bracket", "file-b": "Bracket 2"])

        // A link to a file that's no longer listed falls back to the model's name.
        let gone = slantUploadNameCheckResult(name: "Bracket", linkedFileID: "file-gone", files: files)
        XCTAssertEqual(gone.name, "Bracket")
        XCTAssertEqual(gone.conflictFileID, "file-a")
        XCTAssertFalse(gone.conflictIsLinkedFile)

        let clear = slantUploadNameCheckResult(name: "Hook", linkedFileID: nil, files: files)
        XCTAssertEqual(clear.check, .clear)
        XCTAssertNil(clear.conflictFileID)
        XCTAssertEqual(clear.protectedFiles().count, 2, "a clear name still protects every listed file")
    }

    func testConflictRecordPrefersTheLinkedFileThenAnExactName() {
        let files = [file("file-a", "bracket.stl"), file("file-b", "Bracket"), file("file-c", "BRACKET")]
        XCTAssertEqual(slantUploadNameConflictRecord(name: "Bracket", files: files).flatMap { uploadedFileID($0.values) }, "file-b")
        XCTAssertEqual(slantUploadNameConflictRecord(name: "Bracket", files: files, preferredFileID: "file-c")
            .flatMap { uploadedFileID($0.values) }, "file-c")
        XCTAssertEqual(slantUploadNameConflictRecord(name: "bracket ", files: files).flatMap { uploadedFileID($0.values) }, "file-a",
                       "no exact match: the first listed")
        XCTAssertNil(slantUploadNameConflictRecord(name: "Hook", files: files))
    }

    func testConflictDialogFromACheck() {
        let files = [file("file-a", "Bracket")]
        let own = UploadNameConflict(result: slantUploadNameCheckResult(name: "Bracket", linkedFileID: "file-a", files: files),
                                     modelID: UUID(), earlierUploadUnconfirmed: true)
        XCTAssertEqual(own?.replacement, UploadReplacement(fileID: "file-a", fileName: "Bracket"))
        XCTAssertEqual(own?.ownEarlierUpload, true)
        XCTAssertEqual(own?.earlierUploadUnconfirmed, false, "its own linked file isn't an unconfirmed upload")
        XCTAssertEqual(own?.protectedWhenReplacing, [:])
        XCTAssertEqual(own?.protectedFiles, ["file-a": "Bracket"])
        let unconfirmed = UploadNameConflict(result: slantUploadNameCheckResult(name: "Bracket", linkedFileID: nil, files: files),
                                             modelID: UUID(), earlierUploadUnconfirmed: true)
        XCTAssertEqual(unconfirmed?.earlierUploadUnconfirmed, true)
        XCTAssertNil(UploadNameConflict(result: slantUploadNameCheckResult(name: "Hook", linkedFileID: nil, files: files),
                                        modelID: nil, earlierUploadUnconfirmed: false))
    }

    func testConflictMessageNamesPlacedOrdersAndTheModelsOwnUpload() {
        let plain = slantUploadNameConflictMessage(existing: "Hook")
        XCTAssertTrue(plain.contains("replaces that file for every draft that uses it, and possibly for orders not yet printed."))
        XCTAssertFalse(plain.contains("earlier upload"))
        XCTAssertTrue(slantUploadNameConflictMessage(existing: "Hook", ownEarlierUpload: true).contains("It’s this model’s earlier upload."))
        XCTAssertTrue(slantUploadNameConflictMessage(existing: "Hook", earlierUploadUnconfirmed: true)
            .contains("Slant didn’t confirm this model’s earlier upload, so this may be that upload."))
    }

    // MARK: Suggested names keep the extension last (U5)

    func testSuggestedNamesKeepAModelExtensionLast() {
        XCTAssertEqual(slantUploadUniqueName(name: "part.3mf", files: [file("f", "part.3mf")]), "part 2.3mf")
        XCTAssertEqual(slantUploadUniqueName(name: "Part.STL", files: [file("f", "part")]), "Part 2.STL")
        XCTAssertEqual(slantUploadUniqueName(name: "hook.Obj", files: [file("f", "hook.obj"), file("g", "Hook 2")]), "hook 3.Obj")
        XCTAssertEqual(slantUploadUniqueName(name: "Bracket v1.5", files: [file("f", "Bracket v1.5")]), "Bracket v1.5 2",
                       "only model extensions move")
        XCTAssertEqual(slantUploadUniqueName(name: ".stl", files: [file("f", ".stl")]), ".stl 2", "an extension with no name stays")
        XCTAssertEqual((slantUploadUniqueName(name: "part.3mf", files: [file("f", "part")]) as NSString).pathExtension, "3mf")
        XCTAssertNil(slantUploadNameConflict(name: "part 2.3mf", files: [file("f", "part.3mf")]))
    }

    // MARK: Rate limit (S5)

    func testNameCheckStopsAtTheOrderWatchReserveOrAfterA429() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let low = RateLimitInfo(limit: 100, remaining: orderWatchRateLimitReserve, reset: now.addingTimeInterval(30), role: nil)
        XCTAssertTrue(slantUploadNameCheckRateLimitStop(rateLimit: low, observedAt: now, rateLimitedUntil: nil, now: now))
        var enough = low; enough.remaining = orderWatchRateLimitReserve + 1
        XCTAssertFalse(slantUploadNameCheckRateLimitStop(rateLimit: enough, observedAt: now, rateLimitedUntil: nil, now: now))
        var passed = low; passed.reset = now.addingTimeInterval(-1)
        XCTAssertFalse(slantUploadNameCheckRateLimitStop(rateLimit: passed, observedAt: now, rateLimitedUntil: nil, now: now))
        var noReset = low; noReset.reset = nil
        XCTAssertTrue(slantUploadNameCheckRateLimitStop(rateLimit: noReset, observedAt: now.addingTimeInterval(-30), rateLimitedUntil: nil, now: now))
        XCTAssertFalse(slantUploadNameCheckRateLimitStop(rateLimit: noReset, observedAt: now.addingTimeInterval(-61), rateLimitedUntil: nil, now: now))
        XCTAssertFalse(slantUploadNameCheckRateLimitStop(rateLimit: noReset, observedAt: nil, rateLimitedUntil: nil, now: now))
        XCTAssertFalse(slantUploadNameCheckRateLimitStop(rateLimit: nil, observedAt: nil, rateLimitedUntil: nil, now: now))
        XCTAssertTrue(slantUploadNameCheckRateLimitStop(rateLimit: nil, observedAt: nil, rateLimitedUntil: now.addingTimeInterval(5), now: now))
        XCTAssertFalse(slantUploadNameCheckRateLimitStop(rateLimit: nil, observedAt: nil, rateLimitedUntil: now, now: now))
        XCTAssertTrue(slantUploadNameCheckRateLimitedMessage.contains("nothing was uploaded"))
        XCTAssertTrue(slantUploadNameCheckRateLimitedMessage.contains("Wait a minute"))
    }

    // MARK: Copy that names the real next step (C5, U6, C7)

    func testNameCheckFailureCopyNamesTheNextStepWhereItRan() {
        let sheet = slantUploadNameCheckFailedMessage(name: "Hook", reason: "Slant didn’t reply in time.", retryHint: slantUploadNameCheckRetryInURLSheet)
        XCTAssertTrue(sheet.hasSuffix("Press Upload to try again."), sheet)
        XCTAssertFalse(sheet.contains("Refresh"))
        XCTAssertFalse(slantUploadNameCheckTooManyFilesMessage.contains("Refresh"), "refreshing can't help past the cap")
        XCTAssertFalse(slantUploadNameCheckTooManyFilesMessage.contains("again"))
        XCTAssertTrue(slantUploadNameCheckTooManyFilesMessage.contains("5,000") || slantUploadNameCheckTooManyFilesMessage.contains("5000"))
    }

    func testDuplicatePlatformNoteSaysWhenPlatformsHaventLoaded() {
        XCTAssertEqual(orderComposerPlatformNotCopiedNote(platformsLoaded: true, hasCurrentPlatform: true),
                       "This order’s platform isn’t in your platform list, so the draft uses your current platform. Check it under More options.")
        XCTAssertEqual(orderComposerPlatformNotCopiedNote(platformsLoaded: true, hasCurrentPlatform: false),
                       "This order’s platform isn’t in your platform list. Choose a platform under More options.")
        let unloaded = orderComposerPlatformNotCopiedNote(platformsLoaded: false, hasCurrentPlatform: true)
        XCTAssertTrue(unloaded.hasPrefix("Your platforms haven’t loaded"), unloaded)
        XCTAssertFalse(unloaded.contains("isn’t in your platform list"))
    }
}

final class UploadSafetyLeadFollowUpTests: XCTestCase {
    func testModelsGuardAlsoProtectsLibraryLinksExceptTheReplacedFile() {
        let models = [
            LocalModel(name: "Stand", filePath: "/tmp/stand.stl", remoteID: " file-c "),
            LocalModel(name: "Bracket", filePath: "/tmp/bracket.stl", remoteID: "file-a"),
            LocalModel(name: "Clip", filePath: "/tmp/clip.stl")
        ]
        let listed = ["file-a": "Bracket listed", "file-b": "Hook"]
        let kept = uploadProtectedFilesAddingLibraryLinks(listed, models: models, replacing: nil)
        XCTAssertEqual(kept, ["file-a": "Bracket listed", "file-b": "Hook", "file-c": "Stand"])
        let replacing = uploadProtectedFilesAddingLibraryLinks(listed, models: models, replacing: " file-a ")
        XCTAssertEqual(replacing, ["file-b": "Hook", "file-c": "Stand"])
        XCTAssertNotNil(uploadPlaceholderProtectedFile(["publicFileServiceId": "file-c"], protectedFiles: replacing))
        XCTAssertNil(uploadPlaceholderProtectedFile(["publicFileServiceId": "file-a"], protectedFiles: replacing))
    }

    func testBatchPayNamesTheOrderNumberOverAnInternalID() {
        XCTAssertEqual(batchPayLockedOrderLabel(["a1b2", "SLANT_1000000000001"]), "SLANT_1000000000001")
        XCTAssertEqual(batchPayLockedOrderLabel(["b2", "a1"]), "a1")
        XCTAssertNil(batchPayLockedOrderLabel([]))
    }

    func testPayOutcomeReadsTheStatusTrimmedAndInAnyCase() {
        XCTAssertFalse(outcomeResolved(action: .pay, reviewedStatus: "DRAFT", reloadedStatus: " draft "))
        XCTAssertTrue(outcomeResolved(action: .pay, reviewedStatus: "DRAFT", reloadedStatus: "submitted"))
    }
}
