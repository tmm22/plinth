import XCTest
@testable import Plinth

/// Round 22's review fixes: Undo never relinks a model to a file whose contents changed, no Try Again after a 429,
/// Upload from URL's Replace File notices, the composer's catalogue-loading flag, and the reviewers' copy. Pure helpers
/// and source checks only; every name and ID is invented.
final class ReviewFixesRound22Tests: XCTestCase {
    // MARK: Undo of a removal (R2-1)

    private func keeps(_ fileID: String, model: UUID = UUID(), deleted: Set<String> = [], linked: Set<String> = [],
                       changed: Set<String> = [], uploadedBy: [String: UUID] = [:]) -> Bool {
        restoredLibraryKeepsLink(fileID: fileID, modelID: model, deletedCloudFileIDs: deleted, linkedFileIDs: linked,
                                 changedFileIDs: changed, uploadedBy: uploadedBy)
    }

    func testUndoKeepsALinkOnlyToAFileThatStillHoldsThisModel() {
        let bracket = UUID(), hook = UUID()
        XCTAssertTrue(keeps("file-f", model: bracket), "nothing happened to the file")
        XCTAssertFalse(keeps("file-f", model: bracket, deleted: ["file-f"]), "deleted since")
        XCTAssertFalse(keeps("file-f", model: bracket, linked: ["file-f"]), "another listed model links it now")
        // Upload from URL's Replace File, a Replace File that stopped part-way, a Workbench upload: contents in doubt.
        XCTAssertFalse(keeps("file-f", model: bracket, changed: ["file-f"]))
        // A confirmed Models upload put this model's own bytes there: kept.
        XCTAssertTrue(keeps("file-f", model: bracket, changed: ["file-f"], uploadedBy: ["file-f": bracket]))
        // Another model's confirmed upload: dropped, whether or not the file was unlinked first.
        XCTAssertFalse(keeps("file-f", model: bracket, changed: ["file-f"], uploadedBy: ["file-f": hook]))
        XCTAssertFalse(keeps("file-f", model: bracket, uploadedBy: ["file-f": hook]))
        // Its own upload, but another model links the file now: still dropped (one model per file).
        XCTAssertFalse(keeps("file-f", model: bracket, linked: ["file-f"], uploadedBy: ["file-f": bracket]))
        // Other files' changes don't matter.
        XCTAssertTrue(keeps("file-f", model: bracket, changed: ["file-g"], uploadedBy: ["file-g": hook]))
    }

    func testUndoMatchesAnIDHoweverItWasSpelled() {
        XCTAssertFalse(keeps(" file-f ", changed: ["file-f"]), "a padded link to a changed file")
        XCTAssertFalse(keeps(" file-f ", deleted: ["file-f"]))
        XCTAssertFalse(keeps(" file-f ", linked: [" file-f "]))
        let model = UUID()
        XCTAssertTrue(keeps(" file-f ", model: model, changed: ["file-f"], uploadedBy: ["file-f": model]))
        // A blank link is left as it is.
        XCTAssertTrue(keeps("  ", changed: ["", "  "]))
    }

    func testTheRestoredEntryDropsALinkToAReplacedFile() {
        // B was linked to F and removed; then Upload from URL replaced F; then Edit › Undo.
        let b = LocalModel(name: "Bracket", filePath: "/x/B.stl", remoteID: "file-f")
        let removed = RemovedLibraryModel(model: b, index: 3, wasSelected: false, file: nil)
        let restored = restoredLibraryEntry(removed, deletedCloudFileIDs: [], currentCount: 5, linkedFileIDs: [],
                                            changedFileIDs: ["file-f"], uploadedBy: [:])
        XCTAssertNil(restored.model.remoteID)
        XCTAssertEqual(restored.index, 3)
        // B's own confirmed upload into F before it was removed: the link comes back.
        let own = restoredLibraryEntry(removed, deletedCloudFileIDs: [], currentCount: 5, linkedFileIDs: [],
                                       changedFileIDs: ["file-f"], uploadedBy: ["file-f": b.id])
        XCTAssertEqual(own.model.remoteID, "file-f")
        // Earlier callers' defaults are unchanged.
        XCTAssertEqual(restoredLibraryEntry(removed, deletedCloudFileIDs: [], currentCount: 5).model.remoteID, "file-f")
    }

    func testEveryChangeOfAFileReachesUndo() throws {
        let store = try source("StudioStore.swift")
        let lineage = try source("LibraryLineage.swift")
        // Both Undo paths go through the one helper, which passes every change Plinth recorded.
        let single = try functionBody("func restoreRemovedModel(_ removed: RemovedLibraryModel", in: store)
        XCTAssertTrue(single.contains("let entry = libraryRestoredEntry(removed)"))
        XCTAssertFalse(single.contains("restoredLibraryEntry("))
        let several = try functionBody("func restoreRemovedModels(_ removed: [RemovedLibraryModel]", in: lineage)
        XCTAssertTrue(several.contains("let entry = libraryRestoredEntry(item)"))
        XCTAssertFalse(several.contains("restoredLibraryEntry("))
        XCTAssertTrue(store.contains("changedFileIDs: libraryUnlinkedFileIDs, uploadedBy: libraryFileUploadedBy)"))
        // The changed set grows only through `noteLibraryFilesChanged`, which also forgets the file's uploader.
        let code = store.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        let grows = code.filter { $0.contains("libraryUnlinkedFileIDs.insert(") || $0.contains("libraryUnlinkedFileIDs.formUnion(") }
        XCTAssertEqual(grows.map { $0.trimmingCharacters(in: .whitespaces) }, ["libraryUnlinkedFileIDs.formUnion(ids)"])
        // Deletion, a Replace File's unlinking (before sending, or part-way) and an outside upload into a file record it.
        for function in ["func noteCloudFileDeleted(id: String) {", "private func clearLinks(toFileIDs fileIDs: Set<String>",
                         "func noteFileContentsReplaced(fileID returnedID: String"] {
            let body = try functionBody(function, in: store)
            XCTAssertTrue(body.contains("noteLibraryFilesChanged("), function)
        }
        // A confirmed Models upload records the file as this model's; a failure once bytes may have been sent records
        // the file Slant offered.
        let upload = try functionBody("func uploadModel(id: UUID, as uploadName: String", in: store)
        XCTAssertTrue(upload.contains("noteLibraryFilesChanged([remoteID])\n            libraryFileUploadedBy[remoteID] = capturedID"))
        XCTAssertTrue(upload.contains("if failedStage == .uploading || failedStage == .confirming, let offered = target.value {\n                noteLibraryFilesChanged([offered])"))
        // A Replace File whose unlinking couldn't be saved puts the uploader record back too.
        let beforeReplacing = try functionBody("private func clearLinksBeforeReplacing(", in: store)
        XCTAssertTrue(beforeReplacing.contains("libraryFileUploadedBy = uploadedBy"))
    }

    // MARK: No Try Again after a 429 (R3-F1)

    func testA429OffersNoTryAgain() throws {
        let tooMany = APIError.http(status: 429, body: "", retryAfter: "30", rateLimitReset: nil)
        XCTAssertFalse(runFailureOffersRetry(tooMany, retryable: true), "the alert says to wait; Return would resend")
        XCTAssertFalse(runFailureOffersRetry(tooMany, retryable: false))
        let others: [Error] = [APIError.http(status: 500, body: "", retryAfter: nil, rateLimitReset: nil),
                               APIError.http(status: 404, body: "", retryAfter: nil, rateLimitReset: nil),
                               URLError(.timedOut), StudioError("Slant returned no orders.")]
        for error in others {
            XCTAssertTrue(runFailureOffersRetry(error, retryable: true), "\(error)")
            XCTAssertFalse(runFailureOffersRetry(error, retryable: false), "writes never: \(error)")
        }
        let run = try functionBody("func run(\n", opening: ") async -> Bool {", in: try source("StudioStore.swift"))
        XCTAssertTrue(run.contains("if runFailureOffersRetry(error, retryable: retryable), let retry {"))
        XCTAssertFalse(run.contains("if retryable, let retry {"))
    }

    // MARK: Closing the alert keeps Try Again's action (R1-F8)

    func testClosingTheAlertLeavesTheRetrySlotAlone() throws {
        let store = try source("StudioStore.swift")
        let closed = try functionBody("func errorAlertClosed() {", in: store)
        XCTAssertTrue(closed.contains("error = nil"))
        XCTAssertTrue(closed.contains("canRetry = false"))
        XCTAssertFalse(closed.contains("pendingRetry"), "the queued Try Again must still find its action")
        XCTAssertFalse(closed.contains("dismissError()"))
        // OK still forgets it.
        let dismissed = try functionBody("func dismissError() {", in: store)
        XCTAssertTrue(dismissed.contains("pendingRetry.clear()"))
    }

    // MARK: Upload from URL's Replace File (R1-F3, F4)

    func testAReplaceWithoutAFileIDNamesTheModelsLeftUnlinked() {
        XCTAssertNil(uploadFromURLReplaceNoFileIDNotice(uploadedName: "Bracket v2", fileName: "Bracket", unlinkedNames: []))
        XCTAssertEqual(uploadFromURLReplaceNoFileIDNotice(uploadedName: "Bracket v2", fileName: "Bracket", unlinkedNames: ["Bracket"]),
                       "Slant took “Bracket v2” but didn’t say which of your Slant files holds it. Before sending, Plinth unlinked “Bracket” to replace “Bracket”, and it stays unlinked: upload it again before you use it in an order.")
        let several = uploadFromURLReplaceNoFileIDNotice(uploadedName: "Hook", fileName: "", unlinkedNames: ["A", "B"]) ?? ""
        XCTAssertTrue(several.hasSuffix("Plinth unlinked 2 models in your library to replace your Slant file, and they stay unlinked: upload them again before you use them in an order."))
    }

    func testURLReplaceNoticesNameTheUploadAsTyped() throws {
        let body = try functionBody("func importModelFromURL(", in: try source("StudioStore.swift"))
        XCTAssertTrue(body.contains("let typedName = hint.isEmpty ? trimmedName : hint"))
        XCTAssertTrue(body.contains("noteFileContentsReplaced(fileID: returnedID, uploadedName: typedName,"))
        XCTAssertTrue(body.contains("noteReplaceSavedElsewhere(uploadedName: typedName,"))
        XCTAssertFalse(body.contains("uploadedName: trimmedName"), "the listed name Replace File sends")
        XCTAssertTrue(body.contains("uploadFromURLReplaceNoFileIDNotice(uploadedName: typedName"))
        // The sheet passes the typed name for a Replace File.
        let models = try source("ModelsView.swift")
        XCTAssertTrue(models.contains("send(url, name: uploadReplaceFileName(conflict), typeHint: conflict.name, replacing: conflict.replacement)"))
    }

    // MARK: The composer's catalogue-loading flag (R1-F5)

    func testOnlyTheNewestRunClearsTheFlag() throws {
        var flag = LatestRunFlag()
        XCTAssertFalse(flag.isOn)
        let old = flag.begin()
        let new = flag.begin()
        flag.end(old)
        XCTAssertTrue(flag.isOn, "a cancelled older run finishing late leaves the newer run's flag on")
        flag.end(new)
        XCTAssertFalse(flag.isOn)
        // The force button's run after a finished one.
        let again = flag.begin()
        XCTAssertTrue(flag.isOn)
        flag.end(again)
        flag.end(again)
        XCTAssertFalse(flag.isOn)

        let orders = try source("OrdersView.swift")
        let load = try functionBody("func loadNeededCatalogs(force: Bool = false) async {", in: orders)
        XCTAssertTrue(load.contains("let run = catalogLoads.begin()\n        defer { catalogLoads.end(run) }"))
        XCTAssertFalse(orders.contains("catalogsLoading = "), "only the run flag sets it")
        XCTAssertGreaterThanOrEqual(load.components(separatedBy: "if Task.isCancelled { return }").count - 1, 5,
                                    "a cancelled run starts no further load")
    }

    // MARK: Copy (R3)

    func testBatchLockNoticeSendsTheSellerToOrders() {
        XCTAssertEqual(batchPayLockNotice(lockedOrderNumbers: ["SLANT_2"]),
                       "A payment or cancel request for order SLANT_2 didn’t confirm this session, so Plinth won’t pay several drafts at once. Refresh it in Orders (select the order, or use Refresh Order in its details); until the result is clear, pay drafts one at a time.")
        let several = batchPayLockNotice(lockedOrderNumbers: ["SLANT_2", "SLANT_1"]) ?? ""
        XCTAssertTrue(several.contains("Refresh them in Orders (select each order,"))
        XCTAssertFalse(several.contains("below"))
    }

    func testTheShippedSinceCancelNoteSaysDuplicatingWaitsToo() {
        XCTAssertTrue(unknownOutcomeShippedSinceCancelMessage.hasSuffix(
            "Until Slant shows the order cancelled or you quit and reopen Plinth, Plinth won’t send another cancel, duplicate this order or pay drafts in a batch."))
    }

    func testRefusedDownloadLinksSayWhyAndDontSuggestTryingAgain() {
        let refused = SlantDownloadLinkRefused(problem: "it points to a local or numeric address")
        XCTAssertEqual(refused.localizedDescription,
                       "Nothing was downloaded: Slant’s download link for this model failed Plinth’s safety check because it points to a local or numeric address.")
        // What the window's alert and Activity show is that text, never the generic "Try again" copy.
        XCTAssertEqual(friendlyAPIMessage(refused), refused.localizedDescription)
        XCTAssertEqual(activityDetail(for: refused), refused.localizedDescription)
        for link in ["http://storage.example/m.stl", "https://127.0.0.1/m.stl", "https://user:pw@storage.example/m.stl",
                     "https://storage.example:8443/m.stl", "https://storage.example/m.stl#x"] {
            let problem = storageLinkProblem(URL(string: link)!)
            XCTAssertNotNil(problem, link)
            let text = SlantDownloadLinkRefused(problem: problem ?? "").localizedDescription
            XCTAssertFalse(text.localizedCaseInsensitiveContains("try again"), link)
            XCTAssertLessThanOrEqual(text.count, 180, link)
        }
    }

    func testWorkbenchUnknownResultNoteNamesRefreshOrder() {
        XCTAssertEqual(workbenchMutationSendAllowed(attempted: true, succeeded: false).1, workbenchUnknownResultNote)
        XCTAssertTrue(workbenchUnknownResultNote.contains("Refresh Order"))
        XCTAssertFalse(workbenchUnknownResultNote.localizedCaseInsensitiveContains("reload"))
    }

    func testCheckCostSaysStationeryMayBeFree() {
        func part(_ id: Int, _ state: ProductCostPartState) -> ProductCostPart {
            ProductCostPart(id: id, type: "STATIONERY", title: "Part \(id)", quantity: 1, perOrder: false, state: state)
        }
        let print = part(0, .priced(total: 4, detail: "Estimate"))
        let card = part(1, .unavailable(productCostStationeryNoPriceText))
        let unloaded = part(2, .unavailable("Load stationery to price it."))
        func text(_ parts: [ProductCostPart]) -> String? {
            productCostUnpricedText(parts, summary: productCostSummary(parts, units: 1))
        }
        XCTAssertNil(text([print]), "everything priced")
        XCTAssertEqual(text([print, card]),
                       "1 of 2 parts aren’t priced (stationery Slant’s docs list as free), so the real cost may be higher.")
        XCTAssertEqual(text([print, card, unloaded]), "2 of 3 parts aren’t priced, so the real cost is higher.")
        XCTAssertEqual(text([print, unloaded]), "1 of 2 parts aren’t priced, so the real cost is higher.")
        // The part note no longer reads as both free and unpriced without saying why.
        XCTAssertEqual(productCostStationeryNoPriceText,
                       "Slant lists no price for it. Slant’s docs say stationery can be included free, but Plinth doesn’t count a missing price as free.")
        // The listing price check still needs every part priced (counting it as free is the owner's decision).
        XCTAssertNil(listingPriceCheckCost(productCostSummary([print, card], units: 1)))
    }

    // MARK: Helpers

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from `signature` to the brace that closes its body, which opens at the last character of the first
    /// `opening` from `signature` on (a parameter's default closure needs a longer `opening`).
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
