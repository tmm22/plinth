import XCTest
@testable import Plinth

/// `scripts/check-slant-api.py` is the release gate for Slant's API, and the app's daily check (`SlantAPIChanges.swift`)
/// must judge a change the same way: otherwise the script can say "no change" or "wording only" while every seller
/// sees a notice. These tests keep the two key lists equal and run the script's offline self-test.
final class SlantAPIScriptParityTests: XCTestCase {
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let script = repositoryRoot.appendingPathComponent("scripts/check-slant-api.py")

    /// The strings of the script's one-line-or-more set literal `NAME = {"a", "b", …}` at the start of a line.
    private func pythonSet(_ name: String, in source: String) throws -> Set<String> {
        let pattern = "^" + NSRegularExpression.escapedPattern(for: name) + #" = \{([^}]*)\}"#
        let regex = try NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines])
        let range = NSRange(source.startIndex..., in: source)
        let matches = regex.matches(in: source, range: range)
        XCTAssertEqual(matches.count, 1, "the script should assign \(name) once, as a set literal")
        let match = try XCTUnwrap(matches.first, "\(name) not found in check-slant-api.py")
        let body = try XCTUnwrap(Range(match.range(at: 1), in: source).map { String(source[$0]) })
        let strings = try NSRegularExpression(pattern: #""([^"\\]*)""#)
        let values = strings.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
        XCTAssertFalse(values.isEmpty, "\(name) is empty")
        XCTAssertEqual(values.count, Set(values).count, "\(name) repeats an entry")
        return Set(values)
    }

    func testTheScriptsKeyListsMatchTheApps() throws {
        let source = try String(contentsOf: Self.script, encoding: .utf8)
        XCTAssertEqual(try pythonSet("WORDING_KEYS", in: source), slantAPIIgnoredKeys)
        XCTAssertEqual(try pythonSet("NAME_MAPS", in: source), slantAPINameMapKeys)
        XCTAssertEqual(try pythonSet("DATA_KEYS", in: source), slantAPIDataKeys)
        XCTAssertEqual(try pythonSet("ORDERED_LIST_KEYS", in: source), slantAPIOrderedArrayKeys)
        XCTAssertEqual(try pythonSet("METHODS", in: source), Set(slantAPIMethods))
        XCTAssertTrue(source.contains(#"TAG = "\#(OpenAPISnapshotTests.sourceTag)""#))
        XCTAssertTrue(source.contains(#"TAG_VALUES = ("docs", "live")"#))
        XCTAssertTrue(source.contains(#"SPEC_URL = "\#(slantAPISpecURL.absoluteString)""#), "the script and the app fetch different URLs")
        XCTAssertTrue(source.contains("MAX_BYTES = 2 * 1024 * 1024") && slantAPISpecMaxBytes == 2 * 1024 * 1024)
    }

    /// The script's own fixtures, offline: every exit code and comparison rule, with no request and nothing written
    /// outside a temporary folder. Skipped only where no Python 3 is installed.
    func testTheScriptsSelfTestPasses() throws {
        let python = URL(fileURLWithPath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("no /usr/bin/python3; run python3 -I scripts/check-slant-api.py --self-test by hand")
        }
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("slant-api-self-test-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: log) }
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let process = Process()
        process.executableURL = python
        process.arguments = ["-I", Self.script.path, "--self-test"]
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 120) == .timedOut {
            process.terminate()
            XCTFail("the self-test took over 120 s")
            return
        }
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, text)
        XCTAssertTrue(text.contains("Self-test: all"), text)
    }
}
