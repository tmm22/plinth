import XCTest
import Security
@testable import Plinth

/// The move from Slant Studio to Plinth. Every test works in its own temporary folder with in-memory preferences and
/// a fake Keychain: nothing here touches the real Keychain, preference domains or ~/Library.
final class LegacyMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PlinthLegacyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root {
            // Restore permissions a test may have removed, so the folder can be deleted.
            if let enumerator = FileManager.default.enumerator(atPath: root.path) {
                for case let relative as String in enumerator {
                    try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                           ofItemAtPath: root.appendingPathComponent(relative).path)
                }
            }
            try? FileManager.default.removeItem(at: root)
        }
    }

    // MARK: Helpers

    private final class FakeDefaults: MigrationDefaults {
        var values: [String: Any] = [:]
        var writes: [String] = []
        func object(forKey defaultName: String) -> Any? { values[defaultName] }
        func set(_ value: Any?, forKey defaultName: String) {
            writes.append(defaultName)
            values[defaultName] = value
        }
        func removeObject(forKey defaultName: String) { values[defaultName] = nil }
    }

    private var legacy: URL { root.appendingPathComponent(legacySupportFolderName, isDirectory: true) }
    private var plinth: URL { root.appendingPathComponent(plinthSupportFolderName, isDirectory: true) }

    private func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// A Slant Studio folder with two library models, saved products, order-watch state and thumbnails.
    @discardableResult
    private func makeLegacyLibrary(extraModels: [LocalModel] = []) throws -> [LocalModel] {
        let models = legacy.appendingPathComponent("Models", isDirectory: true)
        try write("solid a", to: models.appendingPathComponent("A.stl"))
        try write("solid b", to: models.appendingPathComponent("B.stl"))
        try write("thumb", to: legacy.appendingPathComponent("Thumbnails/x.png"))
        try write("[]", to: legacy.appendingPathComponent("products.json"))
        try write("{}", to: legacy.appendingPathComponent("order-watch.json"))
        var a = LocalModel(name: "Bracket", filePath: models.appendingPathComponent("A.stl").path, remoteID: "file-1")
        a.partIntent = nil
        let b = LocalModel(name: "Hook", filePath: models.appendingPathComponent("B.stl").path)
        let library = [a, b] + extraModels
        try JSONEncoder().encode(library).write(to: legacy.appendingPathComponent("models.json"))
        return library
    }

    private func environment(_ defaults: FakeDefaults, identity: AppIdentity = .plinth,
                             legacyDomain: [String: Any]? = nil, legacyPlistExists: Bool = false,
                             newKeys: Set<String> = []) -> LegacyMigrationEnvironment {
        LegacyMigrationEnvironment(identity: identity, applicationSupport: root, defaults: defaults,
                                   legacyDomain: { legacyDomain }, legacyPlistExists: legacyPlistExists,
                                   newDomainKeys: newKeys)
    }

    private func decodedLibrary(at folder: URL) throws -> [LocalModel] {
        try JSONDecoder().decode([LocalModel].self, from: Data(contentsOf: folder.appendingPathComponent("models.json")))
    }

    // MARK: Gate

    func testOnlyThePackagedPlinthAppMigrates() {
        XCTAssertTrue(legacyMigrationGate(bundleIdentifier: "io.github.tmm22.plinth"))
        XCTAssertFalse(legacyMigrationGate(bundleIdentifier: nil))
        XCTAssertFalse(legacyMigrationGate(bundleIdentifier: "com.apple.dt.xctest.tool"))
        XCTAssertFalse(legacyMigrationGate(bundleIdentifier: "app.slantstudio.mac"))
        XCTAssertEqual(appIdentity(bundleIdentifier: "app.slantstudio.mac"), .legacy)
        XCTAssertEqual(appIdentity(bundleIdentifier: nil), .other)
        // The test runner itself never migrates.
        XCTAssertNotEqual(runningAppIdentity, .plinth)
    }

    /// The gate compares with the bundle ID the packaged app is built with.
    func testBuildScriptUsesThePlinthBundleIdentifier() throws {
        let script = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build-app.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let pattern = try NSRegularExpression(pattern: "<key>CFBundleIdentifier</key>\\s*<string>([^<]*)</string>")
        let match = try XCTUnwrap(pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)))
        let identifier = String(text[Range(match.range(at: 1), in: text)!])
        XCTAssertEqual(identifier, plinthBundleIdentifier)
    }

    // MARK: Preferences

    func testDefaultsCopyEveryMissingKeyNeverOverwritingAndNeverTheMigrationsOwn() throws {
        let legacyDomain: [String: Any] = ["platformID": "p-1", "ownerID": "o-1", "showDeveloperTools": true,
                                           "lastSidebarDestination": "Orders", "plinth.migration.defaults": true,
                                           "plinth.migration.keychainAccounts": ["api-key"]]
        guard case .copy(let copy) = defaultsMergePlan(legacyDomain: legacyDomain, legacyPlistExists: true,
                                                       newDomainKeys: ["lastSidebarDestination"], markerSet: false) else {
            return XCTFail("Expected a copy")
        }
        XCTAssertEqual(copy.values.map(\.key), ["ownerID", "platformID", "showDeveloperTools"])
        XCTAssertFalse(copy.turnsOffNotifications)

        let defaults = FakeDefaults()
        defaults.values["lastSidebarDestination"] = "Models"
        XCTAssertEqual(applyDefaultsMerge(copy, to: defaults), 3)
        XCTAssertEqual(defaults.values["lastSidebarDestination"] as? String, "Models")
        XCTAssertEqual(defaults.values["platformID"] as? String, "p-1")
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.defaults] as? Bool, true)
        XCTAssertNil(defaults.values[LegacyMigrationKeys.keychainAccounts])
        // The marker is written last, after every key.
        XCTAssertEqual(defaults.writes.last, LegacyMigrationKeys.defaults)
    }

    func testOrderNotificationsAreCarriedAsOffAndFlaggedFirst() throws {
        guard case .copy(let copy) = defaultsMergePlan(legacyDomain: [orderWatchNotifyDefaultsKey: true, "a": 1],
                                                       legacyPlistExists: true, newDomainKeys: [], markerSet: false) else {
            return XCTFail("Expected a copy")
        }
        XCTAssertTrue(copy.turnsOffNotifications)
        let defaults = FakeDefaults()
        applyDefaultsMerge(copy, to: defaults)
        XCTAssertEqual(defaults.values[orderWatchNotifyDefaultsKey] as? Bool, false)
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.notifyWasOn] as? Bool, true)
        XCTAssertEqual(defaults.writes.first, LegacyMigrationKeys.notifyWasOn)

        guard case .copy(let off) = defaultsMergePlan(legacyDomain: [orderWatchNotifyDefaultsKey: false],
                                                      legacyPlistExists: true, newDomainKeys: [], markerSet: false) else {
            return XCTFail("Expected a copy")
        }
        XCTAssertFalse(off.turnsOffNotifications)
        // Already set in Plinth: kept, and no notice.
        guard case .copy(let kept) = defaultsMergePlan(legacyDomain: [orderWatchNotifyDefaultsKey: true],
                                                       legacyPlistExists: true, newDomainKeys: [orderWatchNotifyDefaultsKey],
                                                       markerSet: false) else {
            return XCTFail("Expected a copy")
        }
        XCTAssertTrue(kept.values.isEmpty)
        XCTAssertFalse(kept.turnsOffNotifications)
    }

    func testDefaultsRetryWhenTheOldFileCantBeReadAndStopOnceMarked() {
        if case .retryLater = defaultsMergePlan(legacyDomain: nil, legacyPlistExists: true, newDomainKeys: [], markerSet: false) {} else {
            XCTFail("An unreadable old domain must be tried again")
        }
        if case .retryLater = defaultsMergePlan(legacyDomain: nil, legacyPlistExists: true, newDomainKeys: [], markerSet: false,
                                                unreadableLaunchesSoFar: legacyDefaultsUnreadableRetryLimit - 1) {} else {
            XCTFail("Still within the retry limit")
        }
        if case .nothingToCopy = defaultsMergePlan(legacyDomain: nil, legacyPlistExists: true, newDomainKeys: [], markerSet: false,
                                                   unreadableLaunchesSoFar: legacyDefaultsUnreadableRetryLimit) {} else {
            XCTFail("An old file that stays unreadable is given up after the retries")
        }
        if case .nothingToCopy = defaultsMergePlan(legacyDomain: [:], legacyPlistExists: true, newDomainKeys: [], markerSet: false) {} else {
            XCTFail("An empty old domain has nothing to copy")
        }
        if case .nothingToCopy = defaultsMergePlan(legacyDomain: nil, legacyPlistExists: false, newDomainKeys: [], markerSet: false) {} else {
            XCTFail("A fresh install has nothing to copy")
        }
        if case .alreadyDone = defaultsMergePlan(legacyDomain: ["a": 1], legacyPlistExists: true, newDomainKeys: [], markerSet: true) {} else {
            XCTFail("The marker ends the copy")
        }
    }

    func testAnUnreadableOldFileIsTriedOnFourLaunchesThenMarkedAndNeverBlocks() {
        let defaults = FakeDefaults()
        // The plist exists but reads as nil: Slant Studio running never makes the seller wait for it.
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults, legacyDomain: nil, legacyPlistExists: true)))
        for launch in 1...legacyDefaultsUnreadableRetryLimit {
            _ = performLegacyMigration(environment(defaults, legacyDomain: nil, legacyPlistExists: true))
            XCTAssertNil(defaults.values[LegacyMigrationKeys.defaults], "launch \(launch) leaves the marker unset")
            XCTAssertEqual(defaults.values[LegacyMigrationKeys.defaultsUnreadableLaunches] as? Int, launch)
        }
        let last = performLegacyMigration(environment(defaults, legacyDomain: nil, legacyPlistExists: true))
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.defaults] as? Bool, true)
        XCTAssertNil(last.movedSettings)
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults, legacyDomain: ["a": 1], legacyPlistExists: true)))
    }

    func testAnEmptyOldFileIsMarkedAtOnceAndNeverBlocks() {
        let defaults = FakeDefaults()
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults, legacyDomain: [:], legacyPlistExists: true)))
        let outcome = performLegacyMigration(environment(defaults, legacyDomain: [:], legacyPlistExists: true))
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.defaults] as? Bool, true)
        XCTAssertNil(outcome.movedSettings)
        XCTAssertNil(legacyMigrationActivityDetail(outcome))
    }

    func testOnlyReadableNewKeysMakeTheSellerWait() {
        let defaults = FakeDefaults()
        XCTAssertTrue(legacyMigrationWouldCopy(environment(defaults, legacyDomain: ["a": 1], legacyPlistExists: true)))
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults, legacyDomain: ["a": 1], legacyPlistExists: true, newKeys: ["a"])),
                       "Every key is already set in Plinth, so nothing would be copied")
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults, legacyDomain: [LegacyMigrationKeys.defaults: true],
                                                            legacyPlistExists: true)), "The migration's own keys never count")
    }

    // MARK: Support folder plan

    func testSupportFolderPlanTable() {
        XCTAssertEqual(supportFolderPlan(legacyHasUserData: false, newExists: false, newHasUserData: false), .nothing)
        XCTAssertEqual(supportFolderPlan(legacyHasUserData: false, newExists: true, newHasUserData: true), .nothing)
        XCTAssertEqual(supportFolderPlan(legacyHasUserData: true, newExists: false, newHasUserData: false), .copy)
        XCTAssertEqual(supportFolderPlan(legacyHasUserData: true, newExists: true, newHasUserData: false), .setAsideThenCopy)
        XCTAssertEqual(supportFolderPlan(legacyHasUserData: true, newExists: true, newHasUserData: true), .conflict)
        XCTAssertEqual(supportFolderPlan(legacyHasUserData: true, newExists: true, newHasUserData: true, newHasMoveMarker: true),
                       .alreadyMoved)
        XCTAssertEqual(supportFolderPlan(legacyHasUserData: false, newExists: true, newHasUserData: true, newHasMoveMarker: true),
                       .alreadyMoved)
        XCTAssertEqual(supportFolderPlan(legacyHasUserData: true, newExists: false, newHasUserData: false, newHasMoveMarker: true),
                       .copy)
    }

    func testUserDataMeansSavedFilesOrNonEmptyModelsOrRemoved() throws {
        let folder = root.appendingPathComponent("Check", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Models"), withIntermediateDirectories: true)
        try write("png", to: folder.appendingPathComponent("Thumbnails/a.png"))
        try write("", to: folder.appendingPathComponent("Models/.DS_Store"))
        XCTAssertFalse(supportFolderHasUserData(folder))
        try write("x", to: folder.appendingPathComponent("Removed/abc/x.stl"))
        XCTAssertTrue(supportFolderHasUserData(folder))
        for name in supportFolderUserDataFiles {
            let only = root.appendingPathComponent("Only-\(name)", isDirectory: true)
            try write("{}", to: only.appendingPathComponent(name))
            XCTAssertTrue(supportFolderHasUserData(only), name)
        }
    }

    // MARK: models.json rewrite

    func testModelsRewriteChangesOnlyFilePathsInsideTheOldFolderAndKeepsUnknownKeys() throws {
        let old = URL(fileURLWithPath: "/Users/me/Library/Application Support/SlantStudio")
        let new = URL(fileURLWithPath: "/Users/me/Library/Application Support/Plinth")
        // Escaped slashes, as JSONEncoder writes them; a record from a later version; paths outside the folder.
        let json = #"""
        [{"id":"11111111-1111-1111-1111-111111111111","name":"A","filePath":"\/Users\/me\/Library\/Application Support\/SlantStudio\/Models\/A.stl","futureRecord":{"x":[1,2.5,true]},"added":783456789.123456},
         {"id":"22222222-2222-2222-2222-222222222222","name":"B","filePath":"/Users/me/Desktop/B.stl","added":1},
         {"id":"33333333-3333-3333-3333-333333333333","name":"C","filePath":"/Users/me/Library/Application Support/SlantStudioBackup/Models/C.stl","added":2}]
        """#
        let data = try XCTUnwrap(modelsJSONRemappingFilePaths(Data(json.utf8), legacy: old, new: new))
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [Any])
        XCTAssertEqual(rows.count, 3)
        let first = try XCTUnwrap(rows[0] as? [String: Any])
        XCTAssertEqual(first["filePath"] as? String, "/Users/me/Library/Application Support/Plinth/Models/A.stl")
        XCTAssertEqual(first["name"] as? String, "A")
        XCTAssertEqual(first["added"] as? Double, 783456789.123456)
        let future = try XCTUnwrap(first["futureRecord"] as? [String: Any])
        XCTAssertEqual(future["x"] as? [AnyHashable], [1, 2.5, true] as [AnyHashable])
        XCTAssertEqual((rows[1] as? [String: Any])?["filePath"] as? String, "/Users/me/Desktop/B.stl")
        XCTAssertEqual((rows[2] as? [String: Any])?["filePath"] as? String,
                       "/Users/me/Library/Application Support/SlantStudioBackup/Models/C.stl")
    }

    func testModelsRewriteLeavesALibraryTheDecoderRejectsAlone() {
        let old = URL(fileURLWithPath: "/x/SlantStudio"), new = URL(fileURLWithPath: "/x/Plinth")
        // The second row has no `added`, so the app's decoder refuses the whole library.
        let json = #"[{"id":"11111111-1111-1111-1111-111111111111","name":"A","filePath":"/x/SlantStudio/Models/A.stl","added":1},"#
            + #"{"id":"22222222-2222-2222-2222-222222222222","name":"B","filePath":"/x/SlantStudio/Models/B.stl"}]"#
        XCTAssertNil(try? JSONDecoder().decode([LocalModel].self, from: Data(json.utf8)))
        XCTAssertNil(modelsJSONRemappingFilePaths(Data(json.utf8), legacy: old, new: new))
        XCTAssertNil(modelsJSONRemappingFilePaths(Data(#"[{"filePath":"/x/SlantStudio/a"}, "not a model"]"#.utf8), legacy: old, new: new))
    }

    func testModelsRewriteLeavesMalformedOrUnchangedFilesAlone() {
        let old = URL(fileURLWithPath: "/x/SlantStudio"), new = URL(fileURLWithPath: "/x/Plinth")
        XCTAssertNil(modelsJSONRemappingFilePaths(Data("[{\"filePath\":".utf8), legacy: old, new: new))
        XCTAssertNil(modelsJSONRemappingFilePaths(Data("{\"filePath\":\"/x/SlantStudio/a\"}".utf8), legacy: old, new: new))
        XCTAssertNil(modelsJSONRemappingFilePaths(Data("[{\"filePath\":\"/elsewhere/a.stl\"}]".utf8), legacy: old, new: new))
        // A path climbing out of the folder isn't inside it.
        XCTAssertNil(pathRemappedIntoFolder("/x/SlantStudio/Models/../../etc/a", legacy: old, new: new))
        XCTAssertNil(pathRemappedIntoFolder("/x/SlantStudio", legacy: old, new: new))
        XCTAssertEqual(pathRemappedIntoFolder("/x/SlantStudio/Removed/u/a.stl", legacy: old, new: new), "/x/Plinth/Removed/u/a.stl")
    }

    func testRewriteMatchesTheSymlinkResolvedFormOfTheFolder() throws {
        let real = root.appendingPathComponent("RealHome/SlantStudio", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        let link = root.appendingPathComponent("LinkHome")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root.appendingPathComponent("RealHome"))
        let viaLink = link.appendingPathComponent("SlantStudio")
        let new = link.appendingPathComponent("Plinth")
        let resolvedPath = real.resolvingSymlinksInPath().appendingPathComponent("Models/A.stl").path
        XCTAssertEqual(pathRemappedIntoFolder(resolvedPath, legacy: viaLink, new: new), new.appendingPathComponent("Models/A.stl").path)
        XCTAssertEqual(pathRemappedIntoFolder(viaLink.appendingPathComponent("Models/A.stl").path, legacy: viaLink, new: new),
                       new.appendingPathComponent("Models/A.stl").path)
    }

    func testProductTemplatePathsAreRewrittenOnlyInsideTheOldFolder() throws {
        let old = URL(fileURLWithPath: "/x/SlantStudio"), new = URL(fileURLWithPath: "/x/Plinth")
        let outside = #"[{"name":"P","lines":[{"template":{"templatePath":"/Users/me/t.scad","valueName":"n"}}]}]"#
        XCTAssertNil(productsJSONRemappingTemplatePaths(Data(outside.utf8), legacy: old, new: new))
        let inside = #"[{"name":"P","lines":[{"template":{"templatePath":"\/x\/SlantStudio\/t.scad","valueName":"n"}}]}]"#
        let data = try XCTUnwrap(productsJSONRemappingTemplatePaths(Data(inside.utf8), legacy: old, new: new))
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("/x/Plinth/t.scad"))
        XCTAssertTrue(text.contains("\"valueName\":\"n\""))
    }

    // MARK: Folder copy

    func testCopyBringsTheLibraryOverAndNeverChangesTheOldFolder() throws {
        let library = try makeLegacyLibrary()
        let before = try XCTUnwrap(supportFolderInventory(legacy))
        let oldModelsJSON = try Data(contentsOf: legacy.appendingPathComponent("models.json"))
        // A copy cut short by an earlier crash.
        try write("partial", to: root.appendingPathComponent(".Plinth-migrating-OLD/models.json"))

        XCTAssertEqual(migrateSupportFolder(legacy: legacy, new: plinth), .moved(models: 2))

        XCTAssertEqual(supportFolderInventory(legacy), before)
        XCTAssertEqual(try Data(contentsOf: legacy.appendingPathComponent("models.json")), oldModelsJSON)
        let moved = try decodedLibrary(at: plinth)
        XCTAssertEqual(moved.map(\.id), library.map(\.id))
        XCTAssertEqual(moved.map(\.name), ["Bracket", "Hook"])
        XCTAssertEqual(moved.first?.remoteID, "file-1")
        for model in moved {
            XCTAssertTrue(model.filePath.hasPrefix(plinth.path + "/Models/"), model.filePath)
            XCTAssertTrue(FileManager.default.fileExists(atPath: model.filePath))
            XCTAssertTrue(isManagedModelCopy(model.url, supportDirectory: plinth))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: plinth.appendingPathComponent("order-watch.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: plinth.appendingPathComponent("Thumbnails/x.png").path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".Plinth-migrating-") }
        XCTAssertEqual(leftovers, [])
        // The copy carries the migration's marker file; the old folder never does.
        XCTAssertTrue(FileManager.default.fileExists(atPath: plinth.appendingPathComponent(supportFolderMovedMarkerName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.appendingPathComponent(supportFolderMovedMarkerName).path))
        XCTAssertFalse(supportFolderUserDataFiles.contains(supportFolderMovedMarkerName))
        // Run again: Plinth's folder is the migration's own copy, so it is never a conflict and nothing is merged.
        XCTAssertEqual(migrateSupportFolder(legacy: legacy, new: plinth), .alreadyMoved)
    }

    func testACrashAfterTheMoveButBeforeTheMarkerCountsAsMovedWithNoNotice() throws {
        try makeLegacyLibrary()
        XCTAssertEqual(migrateSupportFolder(legacy: legacy, new: plinth), .moved(models: 2))
        let library = try Data(contentsOf: plinth.appendingPathComponent("models.json"))
        // The preference marker was never written (the app stopped right after the move).
        let defaults = FakeDefaults()
        defaults.values[LegacyMigrationKeys.defaults] = true
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults)))
        let outcome = performLegacyMigration(environment(defaults))
        XCTAssertEqual(outcome.supportDirectory, plinth)
        XCTAssertFalse(outcome.libraryKeptSeparate)
        XCTAssertFalse(outcome.copyFailed)
        XCTAssertNil(legacyMigrationKeptSeparateActivity(outcome))
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.supportFolder] as? Bool, true)
        XCTAssertEqual(try Data(contentsOf: plinth.appendingPathComponent("models.json")), library)
    }

    func testVerificationIgnoresTheMarkerFileOnly() throws {
        try makeLegacyLibrary()
        let copy = root.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: legacy, to: copy)
        try Data().write(to: copy.appendingPathComponent(supportFolderMovedMarkerName))
        XCTAssertTrue(verifySupportFolderCopy(legacy: legacy, copy: copy, finalLocation: plinth))
        try write("extra", to: copy.appendingPathComponent(".other-hidden-file"))
        XCTAssertFalse(verifySupportFolderCopy(legacy: legacy, copy: copy, finalLocation: plinth))
    }

    func testAPlinthFolderWithoutUserDataIsSetAsideNeverDeleted() throws {
        try makeLegacyLibrary()
        try write("png", to: plinth.appendingPathComponent("Thumbnails/dev.png"))
        XCTAssertEqual(migrateSupportFolder(legacy: legacy, new: plinth), .moved(models: 2))
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("Plinth.pre-migration-") }
        XCTAssertEqual(aside.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(aside[0]).appendingPathComponent("Thumbnails/dev.png").path))
    }

    func testAPlinthFolderWithDataIsUsedAndNothingIsMerged() throws {
        try makeLegacyLibrary()
        try write("[]", to: plinth.appendingPathComponent("models.json"))
        XCTAssertEqual(migrateSupportFolder(legacy: legacy, new: plinth), .conflict)
        XCTAssertEqual(try String(contentsOf: plinth.appendingPathComponent("models.json"), encoding: .utf8), "[]")
        XCTAssertFalse(FileManager.default.fileExists(atPath: plinth.appendingPathComponent("order-watch.json").path))
    }

    func testAConflictIsReportedUntilTheSellerDismissesIt() throws {
        try makeLegacyLibrary()
        try write("[]", to: plinth.appendingPathComponent("models.json"))
        let defaults = FakeDefaults()
        let outcome = performLegacyMigration(environment(defaults))
        XCTAssertEqual(outcome.supportDirectory, plinth)
        XCTAssertTrue(outcome.libraryKeptSeparate)
        XCTAssertNil(outcome.movedModels)
        XCTAssertNil(defaults.values[LegacyMigrationKeys.supportFolder], "No marker until the seller dismisses the notice")
        let activity = try XCTUnwrap(legacyMigrationKeptSeparateActivity(outcome))
        XCTAssertFalse(activity.title.contains("/"))
        XCTAssertFalse(activity.detail.contains("/"))
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: false, folderNoticeDismissed: false, notificationsWereOn: false,
                                              notificationsOnNow: false, orderWatchEnabled: true,
                                              libraryKeptSeparate: outcome.libraryKeptSeparate), [.libraryKeptSeparate])
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: false, folderNoticeDismissed: false, notificationsWereOn: false,
                                              notificationsOnNow: false, orderWatchEnabled: true,
                                              libraryKeptSeparate: true, libraryNoticeDismissed: true), [])
        // Dismiss writes the folder marker; from then on the launch step never looks again.
        defaults.values[LegacyMigrationKeys.supportFolder] = true
        let next = performLegacyMigration(environment(defaults))
        XCTAssertFalse(next.libraryKeptSeparate)
        XCTAssertEqual(try String(contentsOf: plinth.appendingPathComponent("models.json"), encoding: .utf8), "[]")
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.appendingPathComponent("models.json").path))
    }

    func testAMalformedLibraryIsCopiedUnchanged() throws {
        try write("{ not json", to: legacy.appendingPathComponent("models.json"))
        try write("solid", to: legacy.appendingPathComponent("Models/A.stl"))
        XCTAssertEqual(migrateSupportFolder(legacy: legacy, new: plinth), .moved(models: 0))
        XCTAssertEqual(try String(contentsOf: plinth.appendingPathComponent("models.json"), encoding: .utf8), "{ not json")
    }

    func testALibraryWithARowTheDecoderRejectsIsCopiedByteForByte() throws {
        try write("solid", to: legacy.appendingPathComponent("Models/A.stl"))
        let inside = legacy.appendingPathComponent("Models/A.stl").path
        // Valid JSON, but the second row lacks `added`: the app's decoder refuses it, so nothing may be rewritten.
        let json = #"[{"id":"11111111-1111-1111-1111-111111111111","name":"A","filePath":"\#(inside)","added":1},"#
            + #"{"id":"22222222-2222-2222-2222-222222222222","name":"B","filePath":"\#(inside)"}]"#
        try write(json, to: legacy.appendingPathComponent("models.json"))
        let defaults = FakeDefaults()
        let outcome = performLegacyMigration(environment(defaults))
        XCTAssertFalse(outcome.copyFailed, "The copy must not fail verification on every launch")
        XCTAssertEqual(outcome.supportDirectory, plinth)
        XCTAssertEqual(try Data(contentsOf: plinth.appendingPathComponent("models.json")), Data(json.utf8))
        XCTAssertNil(legacyMigrationActivityDetail(outcome), "No “0 models” line")
    }

    func testModelsOutsideTheFolderKeepTheirPaths() throws {
        let outside = LocalModel(name: "Desk", filePath: "/Users/someone/Desktop/desk.stl")
        try makeLegacyLibrary(extraModels: [outside])
        XCTAssertEqual(migrateSupportFolder(legacy: legacy, new: plinth), .moved(models: 3))
        XCTAssertEqual(try decodedLibrary(at: plinth).last?.filePath, "/Users/someone/Desktop/desk.stl")
    }

    func testAFailedCopyLeavesNothingBehindAndUsesTheOldFolderThisLaunch() throws {
        try makeLegacyLibrary()
        let unreadable = legacy.appendingPathComponent("Models/locked")
        try write("x", to: unreadable.appendingPathComponent("secret.stl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadable.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path) }

        let defaults = FakeDefaults()
        let outcome = performLegacyMigration(environment(defaults))
        XCTAssertTrue(outcome.copyFailed)
        XCTAssertEqual(outcome.supportDirectory, legacy)
        XCTAssertEqual(outcome.otherSupportDirectory, plinth)
        XCTAssertNil(defaults.values[LegacyMigrationKeys.supportFolder])
        XCTAssertFalse(FileManager.default.fileExists(atPath: plinth.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".Plinth-migrating-") }
        XCTAssertEqual(leftovers, [])
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: outcome.copyFailed, folderNoticeDismissed: false,
                                              notificationsWereOn: false, notificationsOnNow: false, orderWatchEnabled: true),
                       [.folderNotMoved])

        // Next launch, once the folder can be read, the copy happens.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadable.path)
        let retry = performLegacyMigration(environment(defaults))
        XCTAssertFalse(retry.copyFailed)
        XCTAssertEqual(retry.supportDirectory, plinth)
        XCTAssertEqual(retry.movedModels, 2)
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.supportFolder] as? Bool, true)
    }

    func testVerificationRefusesACopyMissingAModelFile() throws {
        try makeLegacyLibrary()
        let copy = root.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: legacy, to: copy)
        let data = try Data(contentsOf: copy.appendingPathComponent("models.json"))
        try XCTUnwrap(modelsJSONRemappingFilePaths(data, legacy: legacy, new: plinth)).write(to: copy.appendingPathComponent("models.json"))
        XCTAssertTrue(verifySupportFolderCopy(legacy: legacy, copy: copy, finalLocation: plinth))
        try FileManager.default.removeItem(at: copy.appendingPathComponent("Models/B.stl"))
        XCTAssertFalse(verifySupportFolderCopy(legacy: legacy, copy: copy, finalLocation: plinth))
    }

    func testVerificationRefusesAChangedLibrary() throws {
        try makeLegacyLibrary()
        let copy = root.appendingPathComponent("Copy", isDirectory: true)
        try FileManager.default.copyItem(at: legacy, to: copy)
        var models = try decodedLibrary(at: copy)
        models[0].name = "Renamed"
        try JSONEncoder().encode(models).write(to: copy.appendingPathComponent("models.json"))
        XCTAssertFalse(verifySupportFolderCopy(legacy: legacy, copy: copy, finalLocation: plinth))
    }

    func testFullLaunchStepIsIdempotent() throws {
        try makeLegacyLibrary()
        let defaults = FakeDefaults()
        let domain: [String: Any] = ["platformID": "p", orderWatchNotifyDefaultsKey: true]
        let first = performLegacyMigration(environment(defaults, legacyDomain: domain, legacyPlistExists: true))
        XCTAssertEqual(first.supportDirectory, plinth)
        XCTAssertEqual(first.movedModels, 2)
        XCTAssertEqual(first.movedSettings, 2)
        XCTAssertEqual(legacyMigrationActivityDetail(first), "2 models · 2 settings")
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.notifyWasOn] as? Bool, true)
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults, legacyDomain: domain, legacyPlistExists: true)))

        let library = try Data(contentsOf: plinth.appendingPathComponent("models.json"))
        let second = performLegacyMigration(environment(defaults, legacyDomain: ["platformID": "changed"], legacyPlistExists: true))
        XCTAssertEqual(second.supportDirectory, plinth)
        XCTAssertNil(legacyMigrationActivityDetail(second))
        XCTAssertEqual(defaults.values["platformID"] as? String, "p")
        XCTAssertEqual(try Data(contentsOf: plinth.appendingPathComponent("models.json")), library)
    }

    func testFreshInstallMarksDoneAndCopiesNothing() {
        let defaults = FakeDefaults()
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults)))
        let outcome = performLegacyMigration(environment(defaults))
        XCTAssertEqual(outcome.supportDirectory, plinth)
        XCTAssertFalse(outcome.copyFailed)
        XCTAssertNil(legacyMigrationActivityDetail(outcome))
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.defaults] as? Bool, true)
        XCTAssertEqual(defaults.values[LegacyMigrationKeys.supportFolder] as? Bool, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plinth.path))
    }

    func testOtherBuildsNeverMigrate() throws {
        try makeLegacyLibrary()
        let defaults = FakeDefaults()
        let dev = performLegacyMigration(environment(defaults, identity: .other, legacyDomain: ["a": 1], legacyPlistExists: true))
        XCTAssertEqual(dev.supportDirectory, plinth)
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults, identity: .other, legacyDomain: ["a": 1], legacyPlistExists: true)))
        let old = performLegacyMigration(environment(defaults, identity: .legacy, legacyDomain: ["a": 1], legacyPlistExists: true))
        XCTAssertEqual(old.supportDirectory, legacy)
        XCTAssertTrue(defaults.values.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: plinth.path))
    }

    func testTheOldAppRunningBlocksOnlyWhenSomethingWouldBeCopied() throws {
        XCTAssertTrue(legacyAppBlocksMigration(runningLegacyPIDs: [42], ownPID: 7, migrationWouldCopy: true))
        XCTAssertFalse(legacyAppBlocksMigration(runningLegacyPIDs: [42], ownPID: 7, migrationWouldCopy: false))
        XCTAssertFalse(legacyAppBlocksMigration(runningLegacyPIDs: [], ownPID: 7, migrationWouldCopy: true))
        XCTAssertFalse(legacyAppBlocksMigration(runningLegacyPIDs: [7], ownPID: 7, migrationWouldCopy: true))

        let defaults = FakeDefaults()
        XCTAssertTrue(legacyMigrationWouldCopy(environment(defaults, legacyDomain: ["a": 1], legacyPlistExists: true)))
        defaults.values[LegacyMigrationKeys.defaults] = true
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults, legacyDomain: ["a": 1], legacyPlistExists: true)))
        try makeLegacyLibrary()
        XCTAssertTrue(legacyMigrationWouldCopy(environment(defaults)))
        try write("[]", to: plinth.appendingPathComponent("models.json"))
        XCTAssertFalse(legacyMigrationWouldCopy(environment(defaults)), "A conflict copies nothing, so it never waits")
    }

    // MARK: Load-time remap

    func testLoadTimeRemapMovesOnlyDirectModelsChildrenWhoseCopyExists() throws {
        let models = [LocalModel(name: "A", filePath: legacy.appendingPathComponent("Models/A.stl").path),
                      LocalModel(name: "B", filePath: legacy.appendingPathComponent("Models/B.stl").path),
                      LocalModel(name: "C", filePath: legacy.appendingPathComponent("Models/sub/C.stl").path),
                      LocalModel(name: "D", filePath: "/Users/me/Desktop/D.stl"),
                      LocalModel(name: "E", filePath: plinth.appendingPathComponent("Models/E.stl").path)]
        let existing: Set<String> = [plinth.appendingPathComponent("Models/A.stl").path,
                                     plinth.appendingPathComponent("Models/sub/C.stl").path]
        let remapped = try XCTUnwrap(libraryRemappingLegacyModelPaths(models, legacy: legacy, current: plinth,
                                                                      fileExists: { existing.contains($0) }))
        XCTAssertEqual(remapped.map(\.filePath), [plinth.appendingPathComponent("Models/A.stl").path, models[1].filePath,
                                                  models[2].filePath, models[3].filePath, models[4].filePath])
        XCTAssertNil(libraryRemappingLegacyModelPaths(models, legacy: legacy, current: plinth, fileExists: { _ in false }))
        XCTAssertNil(libraryRemappingLegacyModelPaths(models, legacy: legacy, current: legacy, fileExists: { _ in true }))
        // The managed-copy check stays strict to the folder in use.
        XCTAssertFalse(isManagedModelCopy(models[0].url, supportDirectory: plinth))
    }

    func testExportRefusesTheOtherAppsFolderToo() {
        let source = plinth.appendingPathComponent("Models/A.stl")
        XCTAssertNotNil(exportDestinationProblem(source: source, destination: legacy.appendingPathComponent("Models/A.stl"),
                                                 supportDirectory: plinth, otherSupportDirectories: [legacy]))
        XCTAssertNotNil(exportDestinationProblem(source: source, destination: legacy.appendingPathComponent("models.json"),
                                                 supportDirectory: plinth, otherSupportDirectories: [legacy]))
        XCTAssertNil(exportDestinationProblem(source: source, destination: root.appendingPathComponent("SlantStudioExports/A.stl"),
                                              supportDirectory: plinth, otherSupportDirectories: [legacy]))
        XCTAssertNil(exportDestinationProblem(source: source, destination: legacy.appendingPathComponent("A.stl"),
                                              supportDirectory: plinth))
    }

    // MARK: Notices

    func testNoticesOnlyWhenNeeded() {
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: false, folderNoticeDismissed: false, notificationsWereOn: false,
                                              notificationsOnNow: false, orderWatchEnabled: true), [])
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: false, folderNoticeDismissed: false, notificationsWereOn: true,
                                              notificationsOnNow: false, orderWatchEnabled: true), [.notificationsOff])
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: false, folderNoticeDismissed: false, notificationsWereOn: true,
                                              notificationsOnNow: true, orderWatchEnabled: true), [])
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: false, folderNoticeDismissed: false, notificationsWereOn: true,
                                              notificationsOnNow: false, orderWatchEnabled: false), [])
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: true, folderNoticeDismissed: true, notificationsWereOn: true,
                                              notificationsOnNow: false, orderWatchEnabled: true), [.notificationsOff])
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: true, folderNoticeDismissed: false, notificationsWereOn: true,
                                              notificationsOnNow: false, orderWatchEnabled: true), [.folderNotMoved, .notificationsOff])
        // Slant Studio running alongside comes first; the folder and library notices never both apply.
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: true, folderNoticeDismissed: false, notificationsWereOn: true,
                                              notificationsOnNow: false, orderWatchEnabled: true, slantStudioOpen: true),
                       [.slantStudioOpen, .folderNotMoved, .notificationsOff])
        XCTAssertEqual(legacyMigrationNotices(copyFailedThisLaunch: false, folderNoticeDismissed: false, notificationsWereOn: false,
                                              notificationsOnNow: false, orderWatchEnabled: true, slantStudioOpen: true,
                                              libraryKeptSeparate: true), [.slantStudioOpen, .libraryKeptSeparate])
        XCTAssertTrue(legacyNotifyFlagIsSpent(notificationsOnNow: true, orderWatchEnabled: true))
        XCTAssertTrue(legacyNotifyFlagIsSpent(notificationsOnNow: false, orderWatchEnabled: false))
        XCTAssertFalse(legacyNotifyFlagIsSpent(notificationsOnNow: false, orderWatchEnabled: true))
    }

    func testTheBothAppsNoticeFollowsOnlyAnotherSlantStudioProcess() {
        XCTAssertTrue(slantStudioRunsAlongside(runningLegacyPIDs: [42], ownPID: 7, identity: .plinth))
        XCTAssertTrue(slantStudioRunsAlongside(runningLegacyPIDs: [42], ownPID: 7, identity: .other), "swift run warns too")
        XCTAssertFalse(slantStudioRunsAlongside(runningLegacyPIDs: [], ownPID: 7, identity: .plinth))
        XCTAssertFalse(slantStudioRunsAlongside(runningLegacyPIDs: [7], ownPID: 7, identity: .plinth))
        XCTAssertFalse(slantStudioRunsAlongside(runningLegacyPIDs: [42], ownPID: 7, endedPID: 42, identity: .plinth),
                       "An app that has just quit may still be listed")
        XCTAssertTrue(slantStudioRunsAlongside(runningLegacyPIDs: [42, 43], ownPID: 7, endedPID: 42, identity: .plinth))
        XCTAssertFalse(slantStudioRunsAlongside(runningLegacyPIDs: [42], ownPID: 7, identity: .legacy),
                       "A build running as Slant Studio never warns about itself")
        XCTAssertTrue(legacySlantStudioOpenNoticeText.contains("don’t share their payment and draft safeguards"))
    }

    func testSellerAddressRemoveAlsoListsSlantStudiosCopiesOnlyWhenGiven() {
        let required = [plinth.appendingPathComponent("seller-address.json"), plinth.appendingPathComponent("seller-address.unreadable.json")]
        let none = sellerAddressFilesToRemove(supportDirectory: plinth, slantStudioDirectory: nil)
        XCTAssertEqual(none.required, required)
        XCTAssertEqual(none.bestEffort, [])
        let both = sellerAddressFilesToRemove(supportDirectory: plinth, slantStudioDirectory: legacy)
        XCTAssertEqual(both.required, required)
        XCTAssertEqual(both.bestEffort, [legacy.appendingPathComponent("seller-address.json"),
                                         legacy.appendingPathComponent("seller-address.unreadable.json")])
        // A launch whose copy failed works in Slant Studio's folder: each file is listed once, as required.
        let failed = sellerAddressFilesToRemove(supportDirectory: legacy, slantStudioDirectory: legacy)
        XCTAssertEqual(failed.required.map(\.lastPathComponent), ["seller-address.json", "seller-address.unreadable.json"])
        XCTAssertEqual(failed.bestEffort, [])
        // Only the packaged Plinth app's launch step names Slant Studio's folder.
        let defaults = FakeDefaults()
        XCTAssertEqual(performLegacyMigration(environment(defaults)).slantStudioDirectory, legacy)
        XCTAssertNil(performLegacyMigration(environment(defaults, identity: .other)).slantStudioDirectory)
        XCTAssertNil(performLegacyMigration(environment(defaults, identity: .legacy)).slantStudioDirectory)
    }

    func testTheActivityLineOmitsZeroCounts() {
        func detail(_ models: Int?, _ settings: Int?) -> String? {
            legacyMigrationActivityDetail(LegacyMigrationOutcome(supportDirectory: plinth, otherSupportDirectory: legacy,
                                                                 movedModels: models, movedSettings: settings))
        }
        XCTAssertNil(detail(0, nil))
        XCTAssertNil(detail(0, 0))
        XCTAssertEqual(detail(0, 3), "3 settings")
        XCTAssertEqual(detail(2, 0), "2 models")
        XCTAssertEqual(detail(1, 1), "1 model · 1 setting")
    }

    func testNoticeAndActivityTextNamesNoPathsOrSecrets() {
        XCTAssertTrue(legacyFolderNotMovedNoticeText.contains("Nothing was deleted."))
        XCTAssertFalse(legacyFolderNotMovedNoticeText.contains("/"))
        XCTAssertTrue(legacyLibraryKeptSeparateNoticeText.contains("nothing was deleted"))
        for text in [legacyLibraryKeptSeparateNoticeText, legacyLibraryKeptSeparateActivityTitle,
                     legacyLibraryKeptSeparateActivityDetail, legacySlantStudioOpenNoticeText] {
            XCTAssertFalse(text.contains("/"), text)
        }
        XCTAssertTrue(legacyNotificationsOffNoticeText.contains("permission"))
        let outcome = LegacyMigrationOutcome(supportDirectory: plinth, otherSupportDirectory: legacy, movedModels: 1, movedSettings: 1)
        let detail = legacyMigrationActivityDetail(outcome)
        XCTAssertEqual(detail, "1 model · 1 setting")
        XCTAssertFalse(detail?.contains("/") ?? true)
    }

    // MARK: Keychain

    private final class FakeKeychain: KeychainBackend, @unchecked Sendable {
        var items: [String: Data] = [:]
        var readFailures: [String: OSStatus] = [:]
        var deleteFailures: [String: OSStatus] = [:]
        var corruptOnAdd = false
        var duplicateOnAdd: Data?
        var calls: [String] = []
        private func key(_ service: String, _ account: String) -> String { "\(service)/\(account)" }

        func read(service: String, account: String) -> KeychainRead {
            calls.append("read \(service)")
            if let status = readFailures[key(service, account)] { return .failed(status) }
            return items[key(service, account)].map(KeychainRead.found) ?? .notFound
        }
        func add(service: String, account: String, data: Data) -> OSStatus {
            calls.append("add \(service)")
            if let duplicateOnAdd {
                items[key(service, account)] = duplicateOnAdd
                return errSecDuplicateItem
            }
            guard items[key(service, account)] == nil else { return errSecDuplicateItem }
            items[key(service, account)] = corruptOnAdd ? Data("other".utf8) : data
            return errSecSuccess
        }
        func update(service: String, account: String, data: Data) -> OSStatus {
            calls.append("update \(service)")
            guard items[key(service, account)] != nil else { return errSecItemNotFound }
            items[key(service, account)] = data
            return errSecSuccess
        }
        func delete(service: String, account: String) -> OSStatus {
            calls.append("delete \(service)")
            if let status = deleteFailures[key(service, account)] { return status }
            return items.removeValue(forKey: key(service, account)) == nil ? errSecItemNotFound : errSecSuccess
        }
    }

    private final class FakeTombstones: KeychainTombstones, @unchecked Sendable {
        var accounts: Set<String> = []
        func contains(_ account: String) -> Bool { accounts.contains(account) }
        func insert(_ account: String) { accounts.insert(account) }
    }

    private func store(_ keychain: FakeKeychain, _ tombstones: FakeTombstones, migrating: Bool = true) -> KeychainItemStore {
        KeychainItemStore(account: "api-key", service: plinthKeychainService,
                          legacyService: migrating ? legacyKeychainService : nil, backend: keychain, tombstones: tombstones)
    }

    private let secret = Data("sl-test-not-a-real-key".utf8)

    private func assertKeychainError(_ expression: () throws -> Void, status: OSStatus, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try expression(), file: file, line: line) { error in
            guard case APIError.keychain(let thrown)? = error as? APIError else {
                return XCTFail("Expected APIError.keychain, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(thrown, status, file: file, line: line)
        }
    }

    func testTheNewItemIsUsedFirst() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["Plinth/api-key"] = secret
        keychain.items["SlantStudio/api-key"] = Data("old".utf8)
        XCTAssertEqual(try store(keychain, tombstones).load(), .data(secret))
        XCTAssertEqual(keychain.calls, ["read Plinth"])
    }

    func testAnOldKeyIsCopiedCheckedAndMarkedButNeverDeleted() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["SlantStudio/api-key"] = secret
        XCTAssertEqual(try store(keychain, tombstones).load(), .data(secret))
        XCTAssertEqual(keychain.items["Plinth/api-key"], secret)
        XCTAssertEqual(keychain.items["SlantStudio/api-key"], secret)
        XCTAssertEqual(tombstones.accounts, ["api-key"])
        XCTAssertEqual(keychain.calls, ["read Plinth", "read SlantStudio", "add Plinth", "read Plinth"])
    }

    func testARefusedOldReadThrowsTheSameErrorAndMarksNothing() {
        for status in [errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed] {
            let keychain = FakeKeychain(), tombstones = FakeTombstones()
            keychain.items["SlantStudio/api-key"] = secret
            keychain.readFailures["SlantStudio/api-key"] = status
            assertKeychainError({ _ = try store(keychain, tombstones).load() }, status: status)
            XCTAssertTrue(tombstones.accounts.isEmpty)
            XCTAssertNil(keychain.items["Plinth/api-key"])
            XCTAssertEqual(keychain.items["SlantStudio/api-key"], secret)
            // Allowed next time: brought over then.
            keychain.readFailures = [:]
            XCTAssertEqual(try? store(keychain, tombstones).load(), .data(secret))
        }
    }

    func testANewItemReadFailureThrowsWithoutTouchingTheOldOne() {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.readFailures["Plinth/api-key"] = errSecInteractionNotAllowed
        keychain.items["SlantStudio/api-key"] = secret
        assertKeychainError({ _ = try store(keychain, tombstones).load() }, status: errSecInteractionNotAllowed)
        XCTAssertEqual(keychain.calls, ["read Plinth"])
    }

    func testNoOldItemMarksTheAccountSoItIsNeverReadAgain() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        XCTAssertEqual(try store(keychain, tombstones).load(), KeychainValue.none)
        XCTAssertEqual(tombstones.accounts, ["api-key"])
        keychain.items["SlantStudio/api-key"] = secret
        keychain.calls = []
        XCTAssertEqual(try store(keychain, tombstones).load(), KeychainValue.none)
        XCTAssertEqual(keychain.calls, ["read Plinth"])
    }

    func testAMismatchedCopyIsRemovedAndTheOldValueUsedUnmarked() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["SlantStudio/api-key"] = secret
        keychain.corruptOnAdd = true
        XCTAssertEqual(try store(keychain, tombstones).load(), .data(secret))
        XCTAssertNil(keychain.items["Plinth/api-key"])
        XCTAssertTrue(tombstones.accounts.isEmpty)
        XCTAssertEqual(keychain.items["SlantStudio/api-key"], secret)
    }

    func testADuplicateAddUsesTheNewItem() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["SlantStudio/api-key"] = secret
        let newer = Data("sl-newer".utf8)
        keychain.duplicateOnAdd = newer
        XCTAssertEqual(try store(keychain, tombstones).load(), .data(newer))
        XCTAssertEqual(tombstones.accounts, ["api-key"])
    }

    func testSavingMarksTheAccountAndKeepsTheOldItem() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["SlantStudio/api-key"] = Data("old".utf8)
        try store(keychain, tombstones).save(secret)
        XCTAssertEqual(keychain.items["Plinth/api-key"], secret)
        XCTAssertEqual(tombstones.accounts, ["api-key"])
        XCTAssertEqual(try store(keychain, tombstones).load(), .data(secret))
        // Update failure keeps the error type.
        keychain.items = [:]
        let failing = FakeKeychain()
        failing.items["Plinth/api-key"] = secret
        let refusing = KeychainItemStore(account: "api-key", service: plinthKeychainService, legacyService: nil,
                                         backend: RefusingUpdates(inner: failing), tombstones: FakeTombstones())
        assertKeychainError({ try refusing.save(secret) }, status: errSecInvalidOwnerEdit)
    }

    private struct RefusingUpdates: KeychainBackend {
        let inner: FakeKeychain
        func read(service: String, account: String) -> KeychainRead { inner.read(service: service, account: account) }
        func add(service: String, account: String, data: Data) -> OSStatus { inner.add(service: service, account: account, data: data) }
        func update(service: String, account: String, data: Data) -> OSStatus { errSecInvalidOwnerEdit }
        func delete(service: String, account: String) -> OSStatus { inner.delete(service: service, account: account) }
    }

    func testARemovedKeyNeverComesBackEvenWhenTheOldItemCantBeDeleted() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["SlantStudio/api-key"] = secret
        keychain.deleteFailures["SlantStudio/api-key"] = errSecInvalidOwnerEdit
        XCTAssertEqual(try store(keychain, tombstones).load(), .data(secret))
        try store(keychain, tombstones).delete()
        XCTAssertNil(keychain.items["Plinth/api-key"])
        XCTAssertEqual(keychain.items["SlantStudio/api-key"], secret, "The refused delete is ignored")
        XCTAssertEqual(try store(keychain, tombstones).load(), KeychainValue.none)
    }

    func testRemovingBeforeAnyReadAlsoRemovesTheOldItem() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["SlantStudio/api-key"] = secret
        try store(keychain, tombstones).delete()
        XCTAssertNil(keychain.items["SlantStudio/api-key"])
        XCTAssertEqual(tombstones.accounts, ["api-key"])
        XCTAssertEqual(try store(keychain, tombstones).load(), KeychainValue.none)
    }

    func testOutsideThePackagedAppTheOldServiceIsNeverRead() throws {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["SlantStudio/api-key"] = secret
        let plain = store(keychain, tombstones, migrating: false)
        XCTAssertEqual(try plain.load(), KeychainValue.none)
        try plain.delete()
        XCTAssertEqual(keychain.items["SlantStudio/api-key"], secret)
        XCTAssertTrue(tombstones.accounts.isEmpty)
        XCTAssertFalse(keychain.calls.contains { $0.hasSuffix("SlantStudio") })
    }

    func testANewItemDeleteFailureStillThrows() {
        let keychain = FakeKeychain(), tombstones = FakeTombstones()
        keychain.items["Plinth/api-key"] = secret
        keychain.deleteFailures["Plinth/api-key"] = errSecInvalidOwnerEdit
        assertKeychainError({ try store(keychain, tombstones).delete() }, status: errSecInvalidOwnerEdit)
        XCTAssertEqual(tombstones.accounts, ["api-key"])
    }
}
