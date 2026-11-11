import XCTest

/// `scripts/build-app.sh` signs ad hoc unless `SIGN_IDENTITY` is set (README, "A stable signature for local builds").
final class BuildScriptSigningTests: XCTestCase {
    private func script() throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build-app.sh")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Unset or empty keeps today's ad-hoc line exactly, and the strict verify always runs after signing.
    func testTheDefaultStaysAdHocAndIsVerified() throws {
        let text = try script()
        let lines = text.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertTrue(lines.contains(#"codesign --force --deep --sign - "$APP_DIR""#))
        XCTAssertTrue(lines.contains(#"SIGN_IDENTITY="${SIGN_IDENTITY:-}""#))
        let adHoc = try XCTUnwrap(lines.firstIndex(of: #"codesign --force --deep --sign - "$APP_DIR""#))
        let verify = try XCTUnwrap(lines.firstIndex(of: #"codesign --verify --deep --strict "$APP_DIR""#))
        XCTAssertLessThan(adHoc, verify)
        XCTAssertEqual(lines.filter { $0.hasPrefix("codesign --verify") }.count, 1)
    }

    /// A set identity is checked among valid code-signing identities before building, and signed with the same options.
    func testASetIdentityIsCheckedFirstAndSignedWithTheSameOptions() throws {
        let text = try script()
        XCTAssertTrue(text.contains("security find-identity -v -p codesigning"))
        XCTAssertTrue(text.contains(#"codesign --force --deep --sign "$SIGN_HASH" "$APP_DIR""#))
        let check = try XCTUnwrap(text.range(of: "find_signing_identity \"$SIGN_IDENTITY\""))
        let build = try XCTUnwrap(text.range(of: "\nswift build -c release\n"))
        XCTAssertLessThan(check.lowerBound, build.lowerBound, "a missing identity stops before the release build")
        XCTAssertFalse(text.contains("security add-") || text.contains("security import") || text.contains("security delete-"),
                       "the script never changes a keychain")
    }

    func testTheBuildScriptParses() throws {
        let bash = URL(fileURLWithPath: "/bin/bash")
        guard FileManager.default.isExecutableFile(atPath: bash.path) else { throw XCTSkip("no /bin/bash") }
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("scripts/build-app.sh").path
        let process = Process()
        process.executableURL = bash
        process.arguments = ["-n", path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
    }
}
