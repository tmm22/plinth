import XCTest
@testable import Plinth

/// Round 19: the lenient models.json read with its kept copy (LibraryFile.swift), and the library's lineage, filter,
/// sort and Remove Copies of This Model… helpers (LibraryLineage.swift).
final class LibraryFileAndLineageTests: XCTestCase {
    private var root: URL!
    private var library: URL { root.appendingPathComponent(libraryFileName) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlinthLibraryFile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func model(_ name: String, copiedFrom: UUID? = nil, remoteID: String? = nil) -> LocalModel {
        LocalModel(name: name, filePath: "/library/\(name).stl", remoteID: remoteID, added: Date(timeIntervalSince1970: 1_800_000_000),
                   copiedFromID: copiedFrom)
    }

    private func encoded(_ models: [LocalModel]) throws -> Data { try JSONEncoder().encode(models) }

    /// A JSON array of the models' entries with extra raw entries spliced in at `rawAt`.
    private func file(_ models: [LocalModel], raw: [String], at position: Int = 1) throws -> Data {
        var parts = try models.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        parts.insert(contentsOf: raw, at: min(position, parts.count))
        return Data("[\(parts.joined(separator: ","))]".utf8)
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.contains("unreadable") }.sorted()
    }

    // MARK: Reading

    func testAGoodFileReadsWholeAndWritesBackTheSameContent() throws {
        let models = [model("Owl"), model("Bracket", copiedFrom: UUID())]
        let data = try encoded(models)
        let read = readLibraryFile(data)
        XCTAssertNil(read.problem)
        XCTAssertEqual(read.models.map(\.id), models.map(\.id))
        XCTAssertTrue(read.carriedEntries.isEmpty)
        // Nothing carried: the same encoder as before, so the same content. Bytes aren't compared: JSONEncoder's key
        // order follows Swift's per-process hash seed, so two encodings of one library can order keys differently.
        let written = try libraryFileData(read.models, carrying: [])
        XCTAssertEqual(try JSONSerialization.jsonObject(with: written) as? NSArray, try JSONSerialization.jsonObject(with: data) as? NSArray)
        XCTAssertEqual(try JSONDecoder().decode([LocalModel].self, from: written).map(\.id), models.map(\.id))
    }

    func testOneBadEntryKeepsTheRestAndIsCarriedThrough() throws {
        let models = [model("Owl"), model("Bracket")]
        let bad = #"{"name":"No ID","filePath":"/library/x.stl","added":1,"futureField":{"kind":"new"}}"#
        let read = readLibraryFile(try file(models, raw: [bad]))
        XCTAssertEqual(read.models.map(\.name), ["Owl", "Bracket"])
        XCTAssertEqual(read.problem, .entriesUnreadable(count: 1))
        XCTAssertEqual(read.carriedEntries.count, 1)
        XCTAssertEqual(read.droppedEntries, 0)
        // Written back after the readable ones, its content unchanged.
        let rewritten = try libraryFileData(read.models, carrying: read.carriedEntries)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: rewritten) as? [[String: Any]])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[2]["name"] as? String, "No ID")
        XCTAssertEqual((rows[2]["futureField"] as? [String: Any])?["kind"] as? String, "new")
        // And it reads the same way again, so nothing is lost across launches.
        let again = readLibraryFile(rewritten)
        XCTAssertEqual(again.models.map(\.id), models.map(\.id))
        XCTAssertEqual(again.carriedEntries, read.carriedEntries)
    }

    func testAnEntryThatIsNotAnObjectIsDroppedNotCarried() throws {
        let read = readLibraryFile(try file([model("Owl")], raw: ["42", "null"]))
        XCTAssertEqual(read.models.count, 1)
        XCTAssertEqual(read.droppedEntries, 2)
        XCTAssertTrue(read.carriedEntries.isEmpty)
        XCTAssertEqual(read.problem, .entriesUnreadable(count: 2))
        XCTAssertTrue(librarySaveWouldLoseData(read))
    }

    func testAWhollyUnreadableFileLoadsNothing() {
        for data in [Data("{not json".utf8), Data(#"{"models":[]}"#.utf8), Data([0xFF, 0x00, 0x13])] {
            let read = readLibraryFile(data)
            XCTAssertEqual(read.problem, .wholeFileUnreadable)
            XCTAssertTrue(read.models.isEmpty)
            XCTAssertTrue(librarySaveWouldLoseData(read))
        }
    }

    func testAnEmptyFileIsAFreshLibrary() {
        let read = readLibraryFile(Data())
        XCTAssertNil(read.problem)
        XCTAssertTrue(read.models.isEmpty)
    }

    func testLegacyMigrationStillSeesAFileItsDecoderRejects() throws {
        // The migration copies a models.json the app's decoder rejects byte for byte; the lenient read is separate.
        let data = try file([model("Owl")], raw: [#"{"name":"No ID"}"#])
        XCTAssertNil(try? JSONDecoder().decode([LocalModel].self, from: data))
        XCTAssertNil(modelsJSONRemappingFilePaths(data, legacy: URL(fileURLWithPath: "/a"), new: URL(fileURLWithPath: "/b")))
    }

    // MARK: Loading and the kept copy

    func testAMissingFileIsSilent() {
        let outcome = loadLibraryFile(at: library)
        XCTAssertNil(outcome.read.problem)
        XCTAssertNil(libraryLoadAlertMessage(outcome))
        XCTAssertNil(libraryLoadActivityDetail(outcome))
        XCTAssertFalse(outcome.saveBlocked)
        XCTAssertTrue(backups().isEmpty)
    }

    func testAGoodFileKeepsNoCopy() throws {
        try encoded([model("Owl")]).write(to: library)
        let outcome = loadLibraryFile(at: library)
        XCTAssertNil(outcome.read.problem)
        XCTAssertTrue(backups().isEmpty)
    }

    func testAWhollyUnreadableFileIsKeptBeforeAnySave() throws {
        let damaged = Data("[{\"id\": broken".utf8)
        try damaged.write(to: library)
        let outcome = loadLibraryFile(at: library)
        XCTAssertEqual(outcome.read.problem, .wholeFileUnreadable)
        XCTAssertEqual(outcome.keptCopyName, "models.unreadable.json")
        XCTAssertTrue(outcome.keptNewCopy)
        XCTAssertFalse(outcome.saveBlocked)
        XCTAssertEqual(try Data(contentsOf: libraryBackupURL(for: library, slot: 1)), damaged)
        let alert = try XCTUnwrap(libraryLoadAlertMessage(outcome))
        XCTAssertTrue(alert.contains("models.unreadable.json"))
        XCTAssertTrue(alert.contains("Models folder"))
        let activity = try XCTUnwrap(libraryLoadActivityDetail(outcome))
        XCTAssertFalse(activity.contains("/"), "no paths in Activity")
        XCTAssertFalse(activity.contains(".json"))
    }

    func testRepeatedLaunchesDoNotPileUpOrReplaceTheKeptCopy() throws {
        let first = Data("garbage one".utf8)
        try first.write(to: library)
        _ = loadLibraryFile(at: library)
        // The next launch with the same bytes keeps nothing new.
        let again = loadLibraryFile(at: library)
        XCTAssertEqual(again.keptCopyName, "models.unreadable.json")
        XCTAssertFalse(again.keptNewCopy)
        XCTAssertEqual(backups(), ["models.unreadable.json"])
        // Different damage later goes beside it; the first kept copy is never replaced.
        let second = Data("garbage two".utf8)
        try second.write(to: library)
        let later = loadLibraryFile(at: library)
        XCTAssertEqual(later.keptCopyName, "models.unreadable-2.json")
        XCTAssertEqual(try Data(contentsOf: libraryBackupURL(for: library, slot: 1)), first)
        XCTAssertEqual(try Data(contentsOf: libraryBackupURL(for: library, slot: 2)), second)
        XCTAssertEqual(backups(), ["models.unreadable-2.json", "models.unreadable.json"])
    }

    func testPartialDamageIsKeptOnceAndCarriedThroughAfterwards() throws {
        let original = try file([model("Owl"), model("Bracket")], raw: [#"{"name":"No ID","filePath":"/x.stl"}"#])
        try original.write(to: library)
        let first = loadLibraryFile(at: library)
        XCTAssertEqual(first.read.problem, .entriesUnreadable(count: 1))
        XCTAssertTrue(first.keptNewCopy)
        XCTAssertNotNil(libraryLoadAlertMessage(first), "the seller hears about it once")
        // A save rewrites the file with the carried entry; the next launch reads it the same way, keeps no new copy
        // and doesn't show the alert again (the sidebar note and Activity still say so).
        var models = first.read.models
        models.insert(model("New import"), at: 0)
        try libraryFileData(models, carrying: first.read.carriedEntries).write(to: library, options: .atomic)
        let second = loadLibraryFile(at: library)
        XCTAssertEqual(second.read.models.count, 3)
        XCTAssertEqual(second.read.carriedEntries.count, 1)
        XCTAssertFalse(second.keptNewCopy)
        XCTAssertNil(libraryLoadAlertMessage(second))
        XCTAssertEqual(libraryLoadActivityDetail(second), "1 entry couldn’t be read; kept in the library file")
        XCTAssertEqual(backups(), ["models.unreadable.json"])
        XCTAssertEqual(try Data(contentsOf: libraryBackupURL(for: library, slot: 1)), original)
        XCTAssertNotNil(libraryUnreadableEntriesNote(second.read.carriedEntries.count))
        XCTAssertNil(libraryUnreadableEntriesNote(0))
    }

    func testWithEveryCopySlotTakenSavingIsBlocked() throws {
        for slot in 1...libraryBackupSlotLimit {
            try Data("old \(slot)".utf8).write(to: libraryBackupURL(for: library, slot: slot))
        }
        try Data("new damage".utf8).write(to: library)
        let outcome = loadLibraryFile(at: library)
        XCTAssertTrue(outcome.saveBlocked, "the only copy of this file must not be replaced")
        XCTAssertNil(outcome.keptCopyName)
        XCTAssertTrue(try XCTUnwrap(libraryLoadAlertMessage(outcome)).contains("won’t be saved"))
        XCTAssertEqual(try Data(contentsOf: libraryBackupURL(for: library, slot: 1)), Data("old 1".utf8))
    }

    func testBlockedSavingIsSaidAtLaunchEvenForUnreadableEntries() throws {
        // A dropped entry (not an object) would be lost by a save, and every copy slot is taken: saving is refused,
        // and the seller hears so at launch rather than at their first import.
        for slot in 1...libraryBackupSlotLimit {
            try Data("old \(slot)".utf8).write(to: libraryBackupURL(for: library, slot: slot))
        }
        try file([model("Owl")], raw: ["42"]).write(to: library)
        let outcome = loadLibraryFile(at: library)
        XCTAssertEqual(outcome.read.problem, .entriesUnreadable(count: 1))
        XCTAssertTrue(outcome.saveBlocked)
        let alert = try XCTUnwrap(libraryLoadAlertMessage(outcome))
        XCTAssertTrue(alert.contains("won’t be saved this session"))
        XCTAssertTrue(try XCTUnwrap(libraryLoadActivityDetail(outcome)).contains("aren’t saved this session"))
    }

    func testAFileThatCantBeOpenedIsNeverMovedInSlantStudiosFolder() throws {
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)   // unreadable as a file
        let kept = loadLibraryFile(at: library, mayMoveFile: false)
        XCTAssertEqual(kept.read.problem, .couldNotOpen)
        XCTAssertTrue(kept.saveBlocked, "left in place, so saving is refused instead")
        XCTAssertNil(kept.keptCopyName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.path))
        XCTAssertTrue(backups().isEmpty)
        XCTAssertTrue(try XCTUnwrap(libraryLoadAlertMessage(kept)).contains("won’t be saved this session"))
        // In Plinth's own folder it is moved aside, as before.
        let moved = loadLibraryFile(at: library)
        XCTAssertFalse(moved.saveBlocked)
        XCTAssertEqual(moved.keptCopyName, "models.unreadable.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.path))
    }

    func testACarriedEntryLosesItsLinkToAReplacedOrSharedFile() throws {
        let linked = #"{"name":"No ID","filePath":"/library/x.stl","added":1,"remoteID":"file-F","futureField":{"kind":"new"}}"#
        let other = #"{"name":"Also no ID","filePath":"/library/y.stl","added":1,"remoteID":"file-G"}"#
        let read = readLibraryFile(try file([model("Owl")], raw: [linked, other]))
        XCTAssertEqual(read.carriedEntries.count, 2)
        // Nothing named: returned as they were, byte for byte.
        XCTAssertEqual(libraryCarriedEntriesDroppingLinks(read.carriedEntries, toFileIDs: []), read.carriedEntries)
        XCTAssertEqual(libraryCarriedEntriesDroppingLinks(read.carriedEntries, toFileIDs: ["file-Z"]), read.carriedEntries)
        // File F was replaced (or is now linked by a listed model): only that entry's link goes, nothing else in it.
        let dropped = libraryCarriedEntriesDroppingLinks(read.carriedEntries, toFileIDs: ["file-F"])
        XCTAssertEqual(dropped[1], read.carriedEntries[1])
        let entry = try XCTUnwrap(try JSONSerialization.jsonObject(with: dropped[0]) as? [String: Any])
        XCTAssertNil(entry["remoteID"])
        XCTAssertEqual(entry["name"] as? String, "No ID")
        XCTAssertEqual((entry["futureField"] as? [String: Any])?["kind"] as? String, "new")
        // And the file written with it reads back with one linked carried entry, not two.
        let rewritten = try libraryFileData(read.models, carrying: dropped)
        let rows = try XCTUnwrap(try JSONSerialization.jsonObject(with: rewritten) as? [[String: Any]])
        XCTAssertEqual(rows.compactMap { $0["remoteID"] as? String }, ["file-G"])
        // An entry that can't be parsed is left alone rather than lost.
        let junk = [Data("not json".utf8)]
        XCTAssertEqual(libraryCarriedEntriesDroppingLinks(junk, toFileIDs: ["file-F"]), junk)
    }

    func testBackupPlanRules() {
        let data = Data("x".utf8)
        var existing: [URL: Data] = [:]
        func plan(_ loses: Bool) -> LibraryBackupPlan {
            libraryBackupPlan(losesDataOnSave: loses, data: data, library: library,
                              exists: { existing[$0] != nil }, contents: { existing[$0] })
        }
        XCTAssertEqual(plan(false), .keep(libraryBackupURL(for: library, slot: 1)))
        existing[libraryBackupURL(for: library, slot: 1)] = Data("other".utf8)
        XCTAssertEqual(plan(false), .notNeeded, "carried entries: an earlier kept copy stays and none is added")
        XCTAssertEqual(plan(true), .keep(libraryBackupURL(for: library, slot: 2)))
        existing[libraryBackupURL(for: library, slot: 3)] = data
        XCTAssertEqual(plan(true), .alreadyKept(libraryBackupURL(for: library, slot: 3)))
        XCTAssertEqual(libraryBackupURL(for: library, slot: 1).lastPathComponent, "models.unreadable.json")
        XCTAssertEqual(libraryBackupURL(for: library, slot: 4).lastPathComponent, "models.unreadable-4.json")
    }

    // MARK: Lineage

    func testCopiedFromIDRoundTripsAndOldLibrariesLoadWithoutIt() throws {
        let original = model("Owl")
        let copy = model("Owl (repaired)", copiedFrom: original.id)
        let decoded = try JSONDecoder().decode([LocalModel].self, from: try encoded([original, copy]))
        XCTAssertNil(decoded[0].copiedFromID)
        XCTAssertEqual(decoded[1].copiedFromID, original.id)
        // An older entry has no key; a damaged value reads as nil rather than dropping the model.
        let old = #"[{"id":"\#(UUID().uuidString)","name":"Old","filePath":"/x.stl","added":1}]"#
        XCTAssertNil(try JSONDecoder().decode([LocalModel].self, from: Data(old.utf8))[0].copiedFromID)
        let damaged = #"[{"id":"\#(UUID().uuidString)","name":"Old","filePath":"/x.stl","added":1,"copiedFromID":"nope"}]"#
        let read = try JSONDecoder().decode([LocalModel].self, from: Data(damaged.utf8))
        XCTAssertEqual(read.count, 1)
        XCTAssertNil(read[0].copiedFromID)
    }

    func testAnOldPrintReadyCopyUsesItsRecordsSource() {
        let original = model("Owl")
        var copy = model("Owl (print-ready)")
        copy.printPreparation = PrintPreparationRecord(sourceID: original.id, sourceName: "Owl", created: Date(), steps: [],
                                                       orientation: .zUp, treatments: [], internalWalls: nil, notes: [])
        XCTAssertEqual(copy.originalModelID, original.id)
        XCTAssertTrue(copy.isLibraryCopy)
        XCTAssertFalse(original.isLibraryCopy)
        // copiedFromID wins over the record (a pockets-filled copy of a print-ready copy keeps the record).
        var filled = copy
        filled.id = UUID()
        filled.copiedFromID = copy.id
        XCTAssertEqual(filled.originalModelID, copy.id)
    }

    func testCopyCaptionNamesTheOriginalOrSaysItWasRemoved() {
        let original = model("Owl")
        let copy = model("Owl (repaired)", copiedFrom: original.id)
        // A copy whose name still starts with its original's already says where it came from.
        XCTAssertNil(libraryCopyCaption(copy, modelsByID: libraryModelsByID([original, copy])))
        // A renamed copy, or a renamed original, gets the caption.
        let renamed = model("Desk owl", copiedFrom: original.id)
        XCTAssertEqual(libraryCopyCaption(renamed, modelsByID: libraryModelsByID([original, renamed])), "Copy of “Owl”")
        var renamedOriginal = original
        renamedOriginal.name = "Barn owl"
        XCTAssertEqual(libraryCopyCaption(copy, modelsByID: libraryModelsByID([renamedOriginal, copy])), "Copy of “Barn owl”")
        // Nothing to say, or to do, about an original that is no longer in the library.
        XCTAssertNil(libraryCopyCaption(copy, modelsByID: libraryModelsByID([copy])))
        XCTAssertNil(libraryCopyCaption(original, modelsByID: libraryModelsByID([original, copy])))
    }

    func testCopyIDsIncludeCopiesOfCopiesInLibraryOrderAndSurviveCycles() {
        let a = model("A")
        let b = model("B", copiedFrom: a.id)
        let c = model("C", copiedFrom: b.id)
        let other = model("Other")
        let d = model("D", copiedFrom: a.id)
        let library = [d, other, c, a, b]
        XCTAssertEqual(libraryCopyIDs(of: a.id, in: library), [d.id, c.id, b.id])
        XCTAssertEqual(libraryCopyIDs(of: b.id, in: library), [c.id])
        XCTAssertEqual(libraryCopyIDs(of: other.id, in: library), [])
        // A damaged file naming each other never loops, and never includes the model asked about.
        var x = model("X")
        var y = model("Y", copiedFrom: x.id)
        x.copiedFromID = y.id
        y.copiedFromID = x.id
        XCTAssertEqual(libraryCopyIDs(of: x.id, in: [x, y]), [y.id])
        var selfCopy = model("Self")
        selfCopy.copiedFromID = selfCopy.id
        XCTAssertEqual(libraryCopyIDs(of: selfCopy.id, in: [selfCopy]), [])
        XCTAssertNil(libraryCopyCaption(selfCopy, modelsByID: libraryModelsByID([selfCopy])))
    }

    // MARK: Filter and sort

    func testFilterAndSort() {
        let owl = model("owl", remoteID: "file-1")
        let bracket = model("Bracket")
        let copy = model("Bracket (repaired)", copiedFrom: bracket.id)
        var recordCopy = model("Older copy")
        recordCopy.filledPockets = true
        let library = [copy, recordCopy, owl, bracket]
        func names(_ filter: LibraryFilter, _ sort: LibrarySort = .newest, search: String = "") -> [String] {
            libraryModelsShown(library, search: search, filter: filter, sort: sort).map(\.name)
        }
        XCTAssertEqual(names(.all), ["Bracket (repaired)", "Older copy", "owl", "Bracket"])
        XCTAssertEqual(names(.originals), ["owl", "Bracket"])
        XCTAssertEqual(names(.copies), ["Bracket (repaired)", "Older copy"])
        XCTAssertEqual(names(.uploaded), ["owl"])
        XCTAssertEqual(names(.readyToUpload), ["Bracket (repaired)", "Older copy", "Bracket"])
        XCTAssertEqual(names(.all, .oldest), ["Bracket", "owl", "Older copy", "Bracket (repaired)"])
        XCTAssertEqual(names(.all, .name), ["Bracket", "Bracket (repaired)", "Older copy", "owl"])
        XCTAssertEqual(names(.copies, .name, search: "  bracket "), ["Bracket (repaired)"])
    }

    func testNameSortKeepsLibraryOrderForTies() {
        let first = model("Same")
        let second = model("Same")
        XCTAssertEqual(libraryModelsShown([first, second], search: "", filter: .all, sort: .name).map(\.id), [first.id, second.id])
    }

    func testEmptyListTextNamesTheFilter() {
        XCTAssertEqual(libraryEmptyListText(filter: .all, search: "owl"), "No local models match “owl”.")
        XCTAssertEqual(libraryEmptyListText(filter: .copies, search: ""), "No copies on this Mac.")
        XCTAssertEqual(libraryEmptyListText(filter: .copies, search: "owl"), "No copies match “owl”.")
        XCTAssertEqual(libraryEmptyListText(filter: .readyToUpload, search: ""), "Every model on this Mac is uploaded.")
        for filter in LibraryFilter.allCases where filter != .all {
            XCTAssertNotNil(filter.showingText)
            XCTAssertFalse(libraryEmptyListText(filter: filter, search: "").isEmpty)
        }
        XCTAssertNil(LibraryFilter.all.showingText)
        XCTAssertEqual(LibrarySort(rawValue: "unknown"), nil, "an unknown saved sort falls back in the view")
    }

    // MARK: Remove Copies of This Model…

    func testRemoveCopiesCopy() {
        XCTAssertEqual(libraryRemoveCopiesMenuTitle(count: 3), "Remove 3 Copies of This Model…")
        XCTAssertEqual(libraryRemoveCopiesMenuTitle(count: 1), "Remove 1 Copy of This Model…")
        XCTAssertEqual(libraryRemoveCopiesTitle(count: 2, originalName: "Owl"), "Remove 2 copies of “Owl” from your library?")
        XCTAssertEqual(libraryRemoveCopiesButtonTitle(count: 2), "Remove 2 Copies")
        let message = libraryRemoveCopiesMessage(count: 2, originalName: "Owl", uploadedCount: 1)
        XCTAssertTrue(message.contains("Trash"))
        XCTAssertTrue(message.contains("Edit › Undo"))
        XCTAssertTrue(message.contains("“Owl” itself stays."))
        XCTAssertTrue(message.contains("Slant account"))
        XCTAssertFalse(libraryRemoveCopiesMessage(count: 1, originalName: "Owl", uploadedCount: 0).contains("Slant"))
        XCTAssertFalse(libraryRemoveCopiesMessage(count: 2, originalName: "Owl", uploadedCount: 0, movesToTrash: false).contains("Trash"))
        // What the seller might not expect to go with the copies is named before the button is pressed.
        XCTAssertFalse(message.contains("print-ready"))
        XCTAssertFalse(message.contains("saved product"))
        let warned = libraryRemoveCopiesMessage(count: 3, originalName: "Owl", uploadedCount: 0, includesPrintReady: true, usedBySavedProducts: 2)
        XCTAssertTrue(warned.contains("This includes the print-ready copy."))
        XCTAssertTrue(warned.contains("2 of them are used in saved products, so check those products afterwards."))
        XCTAssertTrue(libraryRemoveCopiesMessage(count: 3, originalName: "Owl", uploadedCount: 0, usedBySavedProducts: 1)
            .contains("1 of them is used in saved products, so check those products afterwards."))
        let single = libraryRemoveCopiesMessage(count: 1, originalName: "Owl", uploadedCount: 0, includesPrintReady: true, usedBySavedProducts: 1)
        XCTAssertTrue(single.contains("It is the print-ready copy."))
        XCTAssertTrue(single.contains("A saved product uses it, so check that product afterwards."))
    }

    func testRestoreOrderRebuildsTheLibrary() {
        let library = (0..<6).map { model("M\($0)") }
        let removedIndices = [4, 1, 3]
        let removed = removedIndices.map { RemovedLibraryModel(model: library[$0], index: $0, wasSelected: false, file: nil) }
        var remaining = library.enumerated().filter { !removedIndices.contains($0.offset) }.map(\.element)
        for item in libraryRestoreOrder(removed) {
            let entry = restoredLibraryEntry(item, deletedCloudFileIDs: [], currentCount: remaining.count)
            remaining.insert(entry.model, at: entry.index)
        }
        XCTAssertEqual(remaining.map(\.id), library.map(\.id))
    }

    func testARestoredModelNeverSharesAFileLinkWithAnother() {
        let removed = RemovedLibraryModel(model: model("Owl", remoteID: "file-1"), index: 0, wasSelected: false, file: nil)
        XCTAssertEqual(restoredLibraryEntry(removed, deletedCloudFileIDs: [], currentCount: 0, linkedFileIDs: ["file-2"]).model.remoteID, "file-1")
        XCTAssertNil(restoredLibraryEntry(removed, deletedCloudFileIDs: [], currentCount: 0, linkedFileIDs: ["file-1"]).model.remoteID)
    }
}
