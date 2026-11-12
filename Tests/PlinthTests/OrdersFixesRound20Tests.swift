import XCTest
@testable import Plinth

/// Round 20 review fixes, Orders and 3DAPI: the search after an earlier lookup, shared quantity parsing, spoken names,
/// one name per action, the no-key sentence and the File menu's 3DAPI Tracking rule.
final class OrdersFixesRound20Tests: XCTestCase {
    // MARK: Return's lookup after an earlier lookup

    /// The store's search state, stepped through the same pure helpers `StudioStore.searchOrders` uses.
    private struct SearchState: Equatable {
        var searchActive = false
        var notFound: String?
        /// What the list holds: "loaded" (the seller's list) or "result" (a lookup's found order).
        var list = "loaded"

        /// Return with `typed`; `found` is the matching row count Slant returned, `reloads` whether a restore reload
        /// succeeds.
        mutating func lookUp(_ typed: String, found: Int, reloads: Bool = true) {
            switch orderSearchLookupStep(matchCount: found, searchActive: searchActive) {
            case .showFound:
                notFound = nil; searchActive = true; list = "result"
            case .keepLoadedList:
                notFound = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            case .restoreLoadedList:
                if reloads { searchActive = false; notFound = nil; list = "loaded" } // applyOrderFilter's success
                let after = orderSearchStateAfterRestore(reloaded: reloads, searchActiveNow: searchActive, typed: typed)
                searchActive = after.searchActive
                notFound = after.notFound
            }
        }
        /// Clearing the box (`searchOrders("")`): skipped while another request runs; otherwise the note goes and the
        /// list is read again, and only a read that succeeds ends the search (`applyOrderFilter`). A skipped or failed
        /// clear leaves the lookup's result listed and the search active, never an empty list.
        mutating func clear(busy: Bool = false, reloads: Bool = true) {
            guard !busy else { return }
            notFound = nil
            if reloads { searchActive = false; list = "loaded" }
        }
        func mode(_ typed: String) -> OrderSearchListMode {
            orderSearchListMode(searchActive: searchActive, notFound: notFound, typed: typed)
        }
    }

    func testANameAfterAFoundOrderRestoresTheLoadedList() {
        var state = SearchState()
        state.lookUp("SLANT_1000000000001", found: 1)
        XCTAssertEqual(state, SearchState(searchActive: true, notFound: nil, list: "result"))
        XCTAssertEqual(state.mode("SLANT_1000000000001"), .foundOrder)

        // A customer's name: Slant finds nothing, so the seller's list comes back, filtered by the name.
        state.lookUp("Ada Lovelace", found: 0)
        XCTAssertEqual(state, SearchState(searchActive: false, notFound: "Ada Lovelace", list: "loaded"))
        XCTAssertEqual(state.mode("Ada Lovelace"), .typedFilter)
        XCTAssertEqual(orderSearchHint(typed: "Ada Lovelace", searchActive: state.searchActive, notFound: state.notFound),
                       "Slant found no order numbered “Ada Lovelace”. Showing loaded orders that match.")

        // Then cleared: the list, no note.
        state.clear()
        XCTAssertEqual(state, SearchState())
        XCTAssertNil(orderSearchHint(typed: "", searchActive: state.searchActive, notFound: state.notFound))
    }

    func testARestoreThatFailsSaysTheEarlierResultIsStillListed() {
        var state = SearchState()
        state.lookUp("1000000000001", found: 1)
        state.lookUp("Ada", found: 0, reloads: false)
        XCTAssertEqual(state, SearchState(searchActive: true, notFound: "Ada", list: "result"))
        XCTAssertEqual(state.mode("Ada"), .earlierResult, "shown unfiltered, never as an empty “no loaded order matches”")
        XCTAssertEqual(orderSearchHint(typed: " Ada ", searchActive: state.searchActive, notFound: state.notFound),
                       "Slant found no order numbered “Ada”. The list still shows your earlier search’s result.")
        // Typing something else: back to the found result's own note.
        XCTAssertEqual(state.mode("Bob"), .foundOrder)
        XCTAssertEqual(orderSearchHint(typed: "Bob", searchActive: true, notFound: "Ada"),
                       "Showing what Slant found. Clear the search to return to the list.")
        // Clear Search (or clearing the box) returns to the list.
        state.clear()
        XCTAssertEqual(state.mode(""), .typedFilter)
    }

    func testAReloadThatRestoredTheListMeanwhileKeepsTheTypedFilter() {
        // The restore didn't run (another reload, such as the order watch's Show Changes, already read the list).
        let after = orderSearchStateAfterRestore(reloaded: false, searchActiveNow: false, typed: " Ada ")
        XCTAssertFalse(after.searchActive)
        XCTAssertEqual(after.notFound, "Ada")
        XCTAssertEqual(orderSearchListMode(searchActive: false, notFound: "Ada", typed: "Ada"), .typedFilter)
    }

    func testAClearThatCantReloadKeepsTheResultListed() {
        var state = SearchState()
        state.lookUp("SLANT_1000000000001", found: 1)
        // Another request is running: nothing changes, and Clear Search stays offered.
        state.clear(busy: true)
        XCTAssertEqual(state, SearchState(searchActive: true, notFound: nil, list: "result"))
        XCTAssertEqual(state.mode(""), .foundOrder)
        XCTAssertEqual(orderSearchHint(typed: "", searchActive: state.searchActive, notFound: state.notFound),
                       "Showing what Slant found. Clear the search to return to the list.")
        // The reload fails: the result stays, so Import Orders' duplicate check still sees a partial list.
        state.lookUp("Ada", found: 0, reloads: false)
        state.clear(reloads: false)
        XCTAssertEqual(state, SearchState(searchActive: true, notFound: nil, list: "result"))
        XCTAssertNotNil(orderImportDuplicateCoverageNotice(ordersLoaded: true, ordersHasMore: false, listIsPartial: state.searchActive))
        // Then it succeeds.
        state.clear()
        XCTAssertEqual(state, SearchState())
    }

    func testNotFoundThenFoundAndLookupsWithoutAnEarlierResult() {
        var state = SearchState()
        // Not found with the normal list: nothing to restore, the typed filter stays.
        XCTAssertEqual(orderSearchLookupStep(matchCount: 0, searchActive: false), .keepLoadedList)
        state.lookUp("Ada", found: 0)
        XCTAssertEqual(state, SearchState(searchActive: false, notFound: "Ada", list: "loaded"))
        // Then a real number: the found order replaces the list and the note goes.
        state.lookUp("SLANT_1000000000002", found: 1)
        XCTAssertEqual(state, SearchState(searchActive: true, notFound: nil, list: "result"))
        // A second found number replaces the first result; nothing to restore.
        XCTAssertEqual(orderSearchLookupStep(matchCount: 1, searchActive: true), .showFound)
        XCTAssertEqual(orderSearchLookupStep(matchCount: 0, searchActive: true), .restoreLoadedList)
    }

    func testTheListModeNeedsTheSameTextAsTheLookup() {
        XCTAssertEqual(orderSearchListMode(searchActive: false, notFound: nil, typed: "Ada"), .typedFilter)
        XCTAssertEqual(orderSearchListMode(searchActive: true, notFound: nil, typed: "Ada"), .foundOrder)
        XCTAssertEqual(orderSearchListMode(searchActive: true, notFound: "Ada", typed: " Ada "), .earlierResult)
        XCTAssertEqual(orderSearchListMode(searchActive: true, notFound: "Ada", typed: ""), .foundOrder)
        XCTAssertEqual(orderSearchListMode(searchActive: true, notFound: "", typed: ""), .foundOrder)
    }

    // MARK: One quantity parser

    func testComposerQuantitiesReadExactlyAsEveryOtherQuantityField() {
        let inputs = ["1", "40", " 40 ", "1,000", "10 000", "10\u{00A0}000", "10\u{202F}000", "10000", "12 units", "12 unit",
                      "12x", "12 ×", "12X", "0,500", "10,00x", "1,00", ",100", "100,", "1,,000", "12,3456", "0", "-3",
                      "10001", "10,001", "1.5", "4o", "forty", "", "  ", "+5", "٤٠", "99999999999999", "1 000,000",
                      "1,000 units", "units", "x", "007", "0x10"]
        for text in inputs {
            XCTAssertEqual(orderQuantityFromText(text), printQuantity(text), text)
        }
        // What both the current and the stricter shared parser agree on.
        XCTAssertEqual(orderQuantityFromText("12 units"), 12, "Models accepts it, so the composer does too")
        XCTAssertEqual(orderQuantityFromText("12x"), 12)
        // Dictation writes small numbers as words; the composer reads them as Models does, and no further.
        XCTAssertEqual(orderQuantityFromText("twelve"), 12)
        XCTAssertEqual(orderQuantityFromText("One"), 1)
        XCTAssertEqual(orderQuantityFromText("five units"), 5)
        XCTAssertNil(orderQuantityFromText("twenty-one"))
        XCTAssertNil(orderQuantityFromText("forty"))
        XCTAssertNil(orderQuantityFromText("10,00x"))
        XCTAssertEqual(orderQuantityFromText("1,000"), 1000)
        XCTAssertEqual(orderQuantityFromText("10 000"), 10000)
        for text in ["0,500", "10,00x", "1,00", "1,000 units 2", "0", "10001", "1.5", "+5"] {
            XCTAssertNil(orderQuantityFromText(text), text)
        }
        XCTAssertFalse(orderQuantityTextsHaveProblem([UUID(): "12 units"], lineIDs: []))
        let id = UUID()
        XCTAssertFalse(orderQuantityTextsHaveProblem([id: "12 units"], lineIDs: [id]))
        XCTAssertTrue(orderQuantityTextsHaveProblem([id: "0,500"], lineIDs: [id]))
    }

    // MARK: Spoken names and visible titles

    func testComposerLineControlsAreNamedForTheLine() {
        XCTAssertEqual(orderLineQuantityTitle("Bracket"), "Quantity for Bracket")
        XCTAssertEqual(orderLineRemoveTitle, "Remove")
        XCTAssertEqual(orderLineRemoveAccessibilityLabel("Bracket"), "Remove Bracket")
        XCTAssertTrue(orderLineRemoveAccessibilityLabel("Bracket").hasPrefix(orderLineRemoveTitle))
        XCTAssertEqual(orderReferenceFieldsCaption,
                       "Your own notes saved with the order on Slant, such as your shop’s order number. Each has a name and a value; up to 10.")
    }

    func testTrackingRowsAreNotAnotherDoneButton() {
        XCTAssertEqual(shopFollowUpAddedTitle, "Added to Shop")
        XCTAssertNotEqual(shopFollowUpAddedTitle, "Done", "the sheet's dismiss button is Done")
        XCTAssertEqual(shopFollowUpAddedAccessibilityLabel("Order SLANT_1"), "Added to Shop, Order SLANT_1")
        XCTAssertTrue(shopFollowUpAddedAccessibilityLabel("x").hasPrefix(shopFollowUpAddedTitle))
    }

    func testNoticeButtonsSayWhatTheyDoAndStartWithTheirTitle() {
        XCTAssertEqual(orderWatchShowChangesTitle, "Show Changes")
        XCTAssertEqual(orderWatchShowChangesAccessibilityLabel, "Show Changes, order updates")
        XCTAssertTrue(orderWatchShowChangesAccessibilityLabel.hasPrefix(orderWatchShowChangesTitle))
        XCTAssertTrue(studioNoticeButtonAccessibilityLabel("Open Settings", notice: dapiAccountNoticeAccessibilityName)
            .hasPrefix("Open Settings"))
        let look = dapiLookForOrdersButtonTitle(count: 2)
        XCTAssertTrue(studioNoticeButtonAccessibilityLabel(look, notice: dapiUnconfirmedOrdersNoticeAccessibilityName).hasPrefix(look))
        XCTAssertTrue(dapiTrackingCopyAccessibilityLabel(reference: nil, position: 1, count: 1).hasPrefix("Copy"))
    }

    // MARK: One name per action

    func testMessagesNameTheRefreshButtonsOnScreen() {
        XCTAssertEqual(webhookSecretUncertainNote,
                       "Slant may already have changed this secret, so Plinth doesn’t show the one it had. Press Refresh Platform to see the current secret.")
        let rotate = webhookSecretUnclearMessage(WebhookSecretNotReturned(), saving: false) ?? ""
        XCTAssertTrue(rotate.contains("Refresh Platform"), rotate)
        XCTAssertFalse(rotate.contains("Reload"), rotate)
        let create = platformCreateUnclearMessage(URLError(.timedOut)) ?? ""
        XCTAssertTrue(create.contains("Refresh Platforms"), create)
        XCTAssertFalse(create.contains("Reload"), create)
        for code in ["material_not_allowed", "invalid_cursor", "order_not_cancellable"] {
            let text = dapiRefusalMessage(status: 400, code: code, message: nil, placingOrder: true)
            XCTAssertFalse(text.contains("Reload"), "\(code): \(text)")
        }
        XCTAssertTrue(dapiRefusalMessage(status: 400, code: "invalid_cursor", message: nil).contains("Refresh in Orders"))
    }

    // MARK: The no-key sentence

    func testOneNoKeySentence() {
        XCTAssertEqual(dapiAddKeySentence("get a quote"), "Add a 3DAPI key in Settings › Account to get a quote.")
        XCTAssertEqual(dapiOrdersAccountNotice(configured: false, checked: false, account: nil, onboarding: nil, checkFailure: nil),
                       "Add a 3DAPI key in Settings › Account to see and place 3DAPI orders.")
        XCTAssertEqual(dapiModelsNextStepStatus(.needsKey, orderingProblem: nil),
                       "Add a 3DAPI key in Settings › Account to quote and order with 3DAPI.")
        XCTAssertEqual(printServiceDapiKeyMissingNote, "Add a 3DAPI key in the 3DAPI section below to quote and order with 3DAPI.")
        XCTAssertEqual(dapiAddKeyTitle, "Add a 3DAPI key")
        XCTAssertEqual(dapiAddKeyButtonTitle, "Add 3DAPI Key…")
    }

    // MARK: Import Orders' toolbar caption at launch

    func testNoImportCaptionWhileTheAccountConnects() {
        XCTAssertTrue(orderAccountIsConnecting(hasKey: true, connected: false, accountLoaded: false))
        XCTAssertFalse(orderAccountIsConnecting(hasKey: false, connected: false, accountLoaded: false))
        XCTAssertFalse(orderAccountIsConnecting(hasKey: true, connected: true, accountLoaded: true))
        XCTAssertNil(orderImportToolbarCaption(importReason: "Connect your account first.", draftReason: nil, connecting: true))
        XCTAssertEqual(orderImportToolbarCaption(importReason: "Connect your account first.", draftReason: nil, connecting: false),
                       "Import Orders… isn’t available: Connect your account first.")
    }
}
