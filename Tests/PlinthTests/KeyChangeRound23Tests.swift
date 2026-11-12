import XCTest
@testable import Plinth

/// Round 23: Save & Test clears the loaded account data only once the new key has passed its test and the Keychain
/// holds it. A key that fails (or a test that is superseded) is no key change: the orders, files, Activity, imported
/// sale amounts, hidden drafts and done ticks stay as they were under the key still in use, and Settings says so.
/// `connect(key:)` needs a real `StudioStore` (Keychain, library), so its order is pinned by reading the source, as
/// `ReviewFixesRound22Tests` does for `run`. The round's review fixes: a failure is never lost when the Account tab has
/// gone, the status line never contradicts the field or an error, Slant's text gets a full stop before the added
/// sentence, and a new key is refused when a sheet or dialog opened during its test.
final class KeyChangeRound23Tests: XCTestCase {
    func testAKeyChangeClearsTheLoadedDataOnlyAfterTheTestPasses() throws {
        let store = try source("StudioStore.swift")
        let connect = try functionBody("func connect(key: String) async -> Bool {", in: store)
        func code(_ text: String) -> String {
            text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
        }
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

        // The reset and both forgets run only inside the key-change branch, so re-testing the saved key wipes nothing
        // (an empty branch followed by an unconditional reset would fail here); the allowance, the key and the
        // connection are set outside it, so a re-test of the same key still records its allowance.
        XCTAssertEqual(connect.components(separatedBy: "if keyChanged {").count, 2, "one key-change branch")
        let branch = try functionBody("if keyChanged {", in: connect)
        let outside = connect.replacingOccurrences(of: branch, with: "")
        XCTAssertEqual(outside.count, connect.count - branch.count, "the branch appears once")
        for change in ["resetAccountDataPreservingKey()", "forgetHiddenDrafts()", "forgetShopFollowUpDone()"] {
            XCTAssertTrue(code(branch).contains(change), change)
            XCTAssertFalse(code(outside).contains(change), "\(change) runs only for a new key")
        }
        for always in ["noteRateLimit(from: response)", "apiKey = trimmed", "setFilaments(responseRecords(response))",
                       "connected = true", "succeeded = true"] {
            XCTAssertFalse(branch.contains(always), "\(always) also runs for a re-test of the same key")
            XCTAssertTrue(code(outside).contains(always), always)
        }

        // A sheet or dialog opened during the test: a new key is refused after the probe and before the Keychain save,
        // with Settings' own reason and inputs, so nothing is saved, reset or forgotten.
        let refusalLine = "if keyChanged, let reason = accountKeyChangeBlockedReason(busy: false, modalUIShown: isPresentingSheet || appIsPresentingModalUI()) {"
        let refusal = try XCTUnwrap(connect.range(of: refusalLine))
        XCTAssertEqual(try functionBody(refusalLine, in: connect), refusalLine + "\n                throw StudioError(reason)\n            }")
        XCTAssertLessThan(superseded.lowerBound, refusal.lowerBound)
        XCTAssertLessThan(refusal.lowerBound, saved.lowerBound, "refused before the Keychain save")
        XCTAssertLessThan(refusal.lowerBound, changed.lowerBound)
        let settings = try source("SettingsView.swift")
        XCTAssertTrue(settings.contains("accountKeyChangeBlockedReason(busy: store.busy, modalUIShown: store.isPresentingSheet || appIsPresentingModalUI())"),
                      "Settings' check at the press uses the same inputs")
        XCTAssertEqual(accountKeyChangeBlockedReason(busy: false, modalUIShown: true), "Close the open sheet, alert or dialog first.")
        XCTAssertNil(accountKeyChangeBlockedReason(busy: false, modalUIShown: false))
        XCTAssertEqual(slantKeyTestFailureText("Close the open sheet, alert or dialog first.", savedKeyKept: true),
                       "Close the open sheet, alert or dialog first. Your saved key is unchanged and still in use.")

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
        XCTAssertTrue(save.contains("guard !passed, let message = store.error else { return }"))
        XCTAssertFalse(save.contains("if !store.connected"), "a failed test leaves the saved key connected, so this would hide it")
        XCTAssertTrue(settings.contains("Label(\"Testing the key…\""))

        // A failure is never lost: it is taken into the tab only while the Account tab is on screen; otherwise it stays
        // in the main window's alert, worded for the typed key, through `showError` (no Try Again).
        let decide = try XCTUnwrap(save.range(of: "if slantKeyTestFailureShowsInSettings(tabShown: visibility.shown, selectedTab: store.settingsTab) {"))
        let take = try XCTUnwrap(save.range(of: "_ = takeStoreErrorForSettings(store)\n                connectError = text"))
        let mainWindow = try XCTUnwrap(save.range(of: "} else {\n"))
        let shown = try XCTUnwrap(save.range(of: "store.showError(text)"))
        XCTAssertLessThan(decide.lowerBound, take.lowerBound)
        XCTAssertLessThan(take.lowerBound, mainWindow.lowerBound)
        XCTAssertLessThan(mainWindow.lowerBound, shown.lowerBound)
        XCTAssertEqual(save.components(separatedBy: "takeStoreErrorForSettings(").count, 2, "taken only when shown here")
        let elseBranch = save[mainWindow.lowerBound...]
        XCTAssertFalse(elseBranch.contains("connectError"), "left for the main window, never in a tab nobody sees")
        XCTAssertFalse(elseBranch.contains("dismissError"))
        XCTAssertTrue(save.contains("let visibility = self.visibility"), "the task reads the live flag, not a copy")
        XCTAssertTrue(settings.contains(".onDisappear { visibility.shown = false }"))
        XCTAssertTrue(settings.contains("visibility.shown = true"))
        XCTAssertTrue(slantKeyTestFailureShowsInSettings(tabShown: true, selectedTab: .account))
        XCTAssertFalse(slantKeyTestFailureShowsInSettings(tabShown: false, selectedTab: .account), "Settings closed")
        XCTAssertFalse(slantKeyTestFailureShowsInSettings(tabShown: true, selectedTab: .advanced), "another tab chosen")
        XCTAssertFalse(slantKeyTestFailureShowsInSettings(tabShown: true, selectedTab: .designTools), "another tab chosen")
        // `showError` never offers Try Again, so the main window can't test and save a key the seller can't see.
        let store = try source("StudioStore.swift")
        let showError = try functionBody("func showError(_ message: String) {", in: store)
        XCTAssertTrue(showError.contains("canRetry = false"))
        XCTAssertTrue(showError.contains("pendingRetry.clear()"))
    }

    func testTheStatusLineNeverContradictsTheFieldOrAnError() {
        func line(_ field: String, saved: String = "sl_saved", testing: Bool = false, error: Bool = false,
                  connected: Bool = true) -> SlantKeyStatusLine {
            slantKeyStatusLine(keyField: field, savedKey: saved, testing: testing, errorShown: error, connected: connected)
        }
        XCTAssertEqual(line("sl_saved"), .verified)
        XCTAssertEqual(line(" sl_saved\n"), .verified, "spacing isn't a change")
        // A typed key that isn't saved says so in place of "Connection verified" (Return doesn't save it).
        XCTAssertEqual(line("sl_new"), .notSavedYet)
        XCTAssertEqual(line("sl_new", connected: false), .notSavedYet)
        XCTAssertEqual(line("sl_new", saved: "", connected: false), .notSavedYet, "a first key")
        XCTAssertEqual(line("sl_new", error: true), .notSavedYet, "a failed new key is still not saved")
        XCTAssertEqual(slantKeyNotSavedYetText, "Not saved yet: press Save & Test.")
        // While a new key is tested.
        XCTAssertEqual(line("sl_new", testing: true), .testing)
        XCTAssertEqual(line("sl_new", saved: "", testing: true, connected: false), .testing)
        XCTAssertEqual(line("", testing: true), .testing, "the field emptied during the test")
        // No green line beside a Save & Test error (a failed re-test of the saved key, or a refused new key).
        XCTAssertEqual(line("sl_saved", error: true), .hidden)
        XCTAssertEqual(line("", error: true), .hidden)
        XCTAssertEqual(line("sl_saved", error: true, connected: false), .connectionStatus, "nothing green to contradict it")
        // Re-testing the saved key: it stays connected meanwhile.
        XCTAssertEqual(line("sl_saved", testing: true), .verified)
        // An empty field: nothing typed to save, so the saved key's own state.
        XCTAssertEqual(line(""), .verified)
        XCTAssertEqual(line("", connected: false), .connectionStatus)
        XCTAssertEqual(line("", saved: "", connected: false), .notConnected)
        XCTAssertEqual(line("  ", saved: "", connected: false), .notConnected)
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

        // Slant's text may end without a full stop: one is added before the sentence Plinth appends, and only then.
        let bare = unauthorizedUserMessage(body: #"{"message":"Forbidden"}"#)
        XCTAssertEqual(bare, "Slant refused this request. Forbidden")
        XCTAssertEqual(slantKeyTestFailureText(bare, savedKeyKept: true),
                       "Slant refused this request. Forbidden. Your saved key is unchanged and still in use.")
        XCTAssertEqual(slantKeyTestFailureText(bare, savedKeyKept: false), bare, "nothing appended, nothing changed")
        XCTAssertEqual(slantKeyTestFailureText("Slant refused this request. Forbidden  \n", savedKeyKept: true),
                       "Slant refused this request. Forbidden. Your saved key is unchanged and still in use.")
        XCTAssertEqual(slantKeyTestFailureText("Slant reported a conflict: “Try later.” Refresh first", savedKeyKept: true),
                       "Slant reported a conflict: “Try later.” Refresh first. Your saved key is unchanged and still in use.")
        XCTAssertEqual(slantKeyTestFailureText("Slant said “Invalid key”", savedKeyKept: true),
                       "Slant said “Invalid key”. Your saved key is unchanged and still in use.", "after a closing quote")
        for ended in ["Slant said “Invalid key.”", "Slant said “Invalid key!”", "Is the key right?", "Slant said: Invalid key…",
                      "Slant said (Invalid key.)", "Slant said 'Invalid key?'"] {
            XCTAssertEqual(slantKeyTestFailureText(ended, savedKeyKept: true),
                           "\(ended) Your saved key is unchanged and still in use.", ended)
        }
        XCTAssertEqual(slantSentenceEndingWithStop(""), "")
        XCTAssertEqual(slantSentenceEndingWithStop("”"), "”", "nothing but quotes: left alone")
        XCTAssertEqual(slantKeyTestFailureText("", savedKeyKept: true), "Your saved key is unchanged and still in use.")
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
