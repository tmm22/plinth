import XCTest
@testable import Plinth

/// Round 23: Save & Test clears the loaded account data only once the new key has passed its test and the Keychain
/// holds it. A key that fails (or a test that is superseded) is no key change: the orders, files, Activity, imported
/// sale amounts, hidden drafts and done ticks stay as they were under the key still in use, and Settings says so.
/// `connect(key:)` needs a real `StudioStore` (Keychain, library), so its order is pinned by reading the source, as
/// `ReviewFixesRound22Tests` does for `run`.
final class KeyChangeRound23Tests: XCTestCase {
    func testAKeyChangeClearsTheLoadedDataOnlyAfterTheTestPasses() throws {
        let store = try source("StudioStore.swift")
        let connect = try functionBody("func connect(key: String) async -> Bool {", in: store)
        // Nothing is cleared before the request: the only reset sits after the probe, its superseded check and the
        // Keychain save, inside the key-change branch.
        let busy = try XCTUnwrap(connect.range(of: "guard !busy else { return false }"))
        let probe = try XCTUnwrap(connect.range(of: "let response = try await probe.request(\"GET\", path: \"/filaments\")"))
        let superseded = try XCTUnwrap(connect.range(of: "guard generation == connectGeneration else { throw ConnectSuperseded() }"))
        let saved = try XCTUnwrap(connect.range(of: "try KeychainStore.save(trimmed)"))
        let changed = try XCTUnwrap(connect.range(of: "if keyChanged {"))
        let reset = try XCTUnwrap(connect.range(of: "resetAccountDataPreservingKey()"))
        let allowance = try XCTUnwrap(connect.range(of: "noteRateLimit(from: response)"))
        let inUse = try XCTUnwrap(connect.range(of: "apiKey = trimmed"))
        let connected = try XCTUnwrap(connect.range(of: "connected = true"))
        XCTAssertLessThan(busy.lowerBound, probe.lowerBound)
        XCTAssertLessThan(probe.lowerBound, superseded.lowerBound)
        XCTAssertLessThan(superseded.lowerBound, saved.lowerBound)
        XCTAssertLessThan(saved.lowerBound, changed.lowerBound)
        XCTAssertLessThan(changed.lowerBound, reset.lowerBound)
        XCTAssertLessThan(reset.lowerBound, allowance.lowerBound, "the new key's allowance survives the reset")
        XCTAssertLessThan(allowance.lowerBound, inUse.lowerBound)
        XCTAssertLessThan(inUse.lowerBound, connected.lowerBound)
        XCTAssertEqual(connect.components(separatedBy: "resetAccountDataPreservingKey()").count, 2, "one reset")
        XCTAssertFalse(connect.contains("clearLoadedAccountDataKeepingCredentials()"), "never before the probe")
        for forget in ["forgetHiddenDrafts()", "forgetShopFollowUpDone()"] {
            let range = try XCTUnwrap(connect.range(of: forget), forget)
            XCTAssertLessThan(reset.lowerBound, range.lowerBound, forget)
            XCTAssertLessThan(range.lowerBound, allowance.lowerBound, forget)
        }
        XCTAssertTrue(connect.hasSuffix("return succeeded\n    }"), "the caller learns whether the key passed")

        // The reset still forgets the earlier account's data, imported sale amounts included, and the platform and
        // client; it never touches the session's safeguards.
        let clear = try functionBody("private func clearLoadedAccountDataKeepingCredentials() {", in: store)
        for assignment in ["connected = false", "orders = []", "files = []", "activities = []", "importedSaleAmounts = [:]"] {
            XCTAssertTrue(clear.contains(assignment), assignment)
        }
        let resetBody = try functionBody("private func resetAccountDataPreservingKey() {", in: store)
        XCTAssertTrue(resetBody.contains("clearLoadedAccountDataKeepingCredentials()"))
        XCTAssertTrue(resetBody.contains("platformID = \"\""))
        XCTAssertTrue(resetBody.contains("cachedClient = nil"))
        func code(_ text: String) -> String {
            text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
        for safeguard in ["outcomeLocks", "unknownOutcomeOrderIDs", "unconfirmedDraftCreates", "orderImportLedger"] {
            XCTAssertFalse(code(clear).contains(safeguard), safeguard)
            XCTAssertFalse(code(resetBody).contains(safeguard), safeguard)
            XCTAssertFalse(code(connect).contains(safeguard), safeguard)
        }
    }

    func testSettingsJudgesSaveAndTestByTheTestNotTheConnection() throws {
        let settings = try source("SettingsView.swift")
        let save = try functionBody("private func saveAndTest() {", in: settings)
        XCTAssertTrue(save.contains("let passed = await store.connect(key: key)"))
        XCTAssertTrue(save.contains("if !passed, let message = takeStoreErrorForSettings(store) {"))
        XCTAssertFalse(save.contains("if !store.connected"), "a failed test leaves the saved key connected, so this would hide it")
        XCTAssertTrue(settings.contains("Label(\"Testing the key…\""))
    }

    func testAFailedTestNamesTheTypedKeyAndKeepsTheSavedOne() {
        let rejectedCopy = unauthorizedUserMessage(body: "")
        XCTAssertEqual(rejectedCopy, "Slant rejected the saved key. Reconnect in Settings.", "the copy this maps")
        XCTAssertEqual(unauthorizedUserMessage(body: #"{"message":"Bearer token required in Authorization header"}"#), rejectedCopy)
        // A first key: Slant refused the key just typed, never "the saved key".
        XCTAssertEqual(slantKeyTestFailureText(rejectedCopy, savedKeyKept: false),
                       "Slant didn’t accept this key. Check it, then press Save & Test again.")
        // Replacing a key: the saved key stays in use.
        XCTAssertEqual(slantKeyTestFailureText(rejectedCopy, savedKeyKept: true),
                       "Slant didn’t accept this key. Check it, then press Save & Test again. Your saved key is unchanged and still in use.")
        // Other failures keep their own copy.
        XCTAssertEqual(slantKeyTestFailureText("Check your connection and try again.", savedKeyKept: true),
                       "Check your connection and try again. Your saved key is unchanged and still in use.")
        XCTAssertEqual(slantKeyTestFailureText(slantKeySaveFailedMessage, savedKeyKept: false), slantKeySaveFailedMessage)
        // A 401 that isn't about the key keeps Slant's words.
        let other = unauthorizedUserMessage(body: #"{"message":"This file belongs to another creator"}"#)
        XCTAssertEqual(slantKeyTestFailureText(other, savedKeyKept: false), other)
    }

    // MARK: Helpers

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from `signature` to the brace that closes its body, which opens at the last character of `signature`.
    private func functionBody(_ signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), signature)
        let open = source.index(before: start.upperBound)
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
