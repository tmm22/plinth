import Foundation
import XCTest

/// Prefix of the temporary folder that holds one test's UserDefaults suite.
let testDefaultsFolderPrefix = "TestDefaults-"

/// A fresh UserDefaults suite name for one test. A suite named by an absolute path keeps its plist at that path, so
/// each test's suite lives in its own temporary folder rather than ~/Library/Preferences, where
/// `removePersistentDomain(forName:)` leaves an empty plist behind (cfprefsd writes it, sometimes after the test ends,
/// so deleting the file there doesn't stick).
func testDefaultsSuiteName(_ label: String) -> String {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(testDefaultsFolderPrefix)\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("\(label).\(UUID().uuidString)", isDirectory: false).path
}

/// Whether `suite` names a suite made by `testDefaultsSuiteName`, whose folder may be deleted.
func testDefaultsSuiteFolder(_ suite: String) -> URL? {
    guard suite.hasPrefix("/") else { return nil }
    let folder = URL(fileURLWithPath: suite).deletingLastPathComponent()
    guard folder.lastPathComponent.hasPrefix(testDefaultsFolderPrefix),
          UUID(uuidString: String(folder.lastPathComponent.dropFirst(testDefaultsFolderPrefix.count))) != nil,
          folder.deletingLastPathComponent().standardizedFileURL.path
            == FileManager.default.temporaryDirectory.standardizedFileURL.path else { return nil }
    return folder
}

/// Removes a test's own suite: its domain, and the temporary folder `testDefaultsSuiteName` made for it.
func removeTestDefaultsSuite(_ defaults: UserDefaults, named suite: String) {
    defaults.removePersistentDomain(forName: suite)
    if let folder = testDefaultsSuiteFolder(suite) { try? FileManager.default.removeItem(at: folder) }
}

final class TestDefaultsSuiteTests: XCTestCase {
    func testSuitesLiveInTheirOwnTemporaryFolder() throws {
        let suite = testDefaultsSuiteName("Probe")
        XCTAssertTrue(suite.hasPrefix(FileManager.default.temporaryDirectory.path), suite)
        let folder = try XCTUnwrap(testDefaultsSuiteFolder(suite))
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "probe")
        XCTAssertEqual(defaults.persistentDomain(forName: suite)?["probe"] as? Bool, true)
        removeTestDefaultsSuite(defaults, named: suite)
        XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let preferences = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
        let leaked = ((try? FileManager.default.contentsOfDirectory(atPath: preferences.path)) ?? [])
            .filter { $0.contains(URL(fileURLWithPath: suite).lastPathComponent) }
        XCTAssertEqual(leaked, [])
    }

    func testOnlyFoldersItMadeAreRemoved() {
        let temp = FileManager.default.temporaryDirectory
        for name in ["app.slantstudio.mac", "io.github.tmm22.plinth", "MarginTests.\(UUID().uuidString)",
                     temp.appendingPathComponent("Other-\(UUID().uuidString)/X.1").path,
                     temp.appendingPathComponent("TestDefaults-not-a-uuid/X.1").path,
                     "/Users/x/Library/Preferences/TestDefaults-\(UUID().uuidString)/X.1"] {
            XCTAssertNil(testDefaultsSuiteFolder(name), name)
        }
    }
}
