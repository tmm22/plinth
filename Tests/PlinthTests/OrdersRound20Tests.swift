import XCTest
@testable import Plinth

/// Round 20, Orders: wording, layout helpers and the search that keeps the loaded list.
final class OrdersRound20Tests: XCTestCase {
    // MARK: Return's order-number lookup

    func testALookupThatFindsNothingKeepsTheLoadedList() {
        XCTAssertEqual(orderSearchLookupOutcome(matchCount: 0), .keepLoadedList)
        XCTAssertEqual(orderSearchLookupOutcome(matchCount: 1), .showFound)
        XCTAssertEqual(orderSearchLookupOutcome(matchCount: 3), .showFound)
    }

    func testOnlyMatchingRowsCountAsFound() {
        let found = Record(values: ["publicId": "SLANT_123"])
        let other = Record(values: ["publicId": "SLANT_999"])
        // A real number, as typed or bare.
        XCTAssertEqual(orderSearchMatchingRecords([found, other], typed: "slant_123").map(\.id), ["SLANT_123"])
        XCTAssertEqual(orderSearchMatchingRecords([found, other], typed: " 123 ").map(\.id), ["SLANT_123"])
        // A partial number, or a customer's name, finds nothing (Slant's reply of the newest orders isn't a match),
        // so the loaded list stays.
        XCTAssertEqual(orderSearchLookupOutcome(matchCount: orderSearchMatchingRecords([found, other], typed: "12").count),
                       .keepLoadedList)
        XCTAssertEqual(orderSearchLookupOutcome(matchCount: orderSearchMatchingRecords([found, other], typed: "Ada Lovelace").count),
                       .keepLoadedList)
        XCTAssertEqual(orderSearchLookupOutcome(matchCount: orderSearchMatchingRecords([], typed: "SLANT_123").count),
                       .keepLoadedList)
    }

    func testTheNotFoundLineShowsOnlyForTheTextLookedUp() {
        XCTAssertEqual(orderSearchHint(typed: " Ada ", searchActive: false, notFound: "Ada"),
                       "Slant found no order numbered “Ada”. Showing loaded orders that match.")
        // It wins over an earlier search's "what Slant found" note: the list now shows loaded matches.
        XCTAssertEqual(orderSearchHint(typed: "Ada", searchActive: true, notFound: "Ada"), orderSearchNotFoundLine("Ada"))
        // Other text, or an empty box, gets the usual note.
        XCTAssertEqual(orderSearchHint(typed: "Bob", searchActive: false, notFound: "Ada"),
                       "Showing loaded orders that match. Press Return to look up an order number on Slant.")
        XCTAssertNil(orderSearchHint(typed: "  ", searchActive: false, notFound: ""))
        XCTAssertNil(orderSearchHint(typed: "", searchActive: false, notFound: "Ada"))
        XCTAssertEqual(orderSearchHint(typed: "Ada", searchActive: true),
                       "Showing what Slant found. Clear the search to return to the list.")
    }

    // MARK: Typed quantities

    func testTypedQuantitiesParseLeniently() {
        XCTAssertEqual(orderQuantityFromText("40"), 40)
        XCTAssertEqual(orderQuantityFromText(" 40 "), 40)
        XCTAssertEqual(orderQuantityFromText("1,000"), 1000)
        XCTAssertEqual(orderQuantityFromText("10 000"), 10000)
        XCTAssertEqual(orderQuantityFromText("10\u{00A0}000"), 10000)
        XCTAssertEqual(orderQuantityFromText("1"), 1)
    }

    func testTypedQuantitiesOutsideTheLimitsOrNotNumbersAreRefused() {
        for text in ["", "  ", "0", "-3", "10001", "10,001", "99999999999999", "1.5", "4o", "forty", "1,00", ",100",
                     "100,", "1,,000", "12,3456", "٤٠", "+5"] {
            XCTAssertNil(orderQuantityFromText(text), text)
        }
    }

    func testABadTypedQuantityBlocksCreateOnlyForListedLines() {
        let a = UUID(), b = UUID(), removed = UUID()
        XCTAssertFalse(orderQuantityTextsHaveProblem([:], lineIDs: [a, b]))
        XCTAssertFalse(orderQuantityTextsHaveProblem([a: "12"], lineIDs: [a, b]))
        XCTAssertTrue(orderQuantityTextsHaveProblem([a: "12", b: "0"], lineIDs: [a, b]))
        XCTAssertTrue(orderQuantityTextsHaveProblem([b: ""], lineIDs: [a, b]))
        XCTAssertFalse(orderQuantityTextsHaveProblem([removed: "abc"], lineIDs: [a, b]))
    }

    // MARK: Wording

    func testPayReviewTitleMatchesItsCommand() {
        XCTAssertEqual(orderPayReviewTitle, "Review and place order")
        XCTAssertEqual(orderReviewDismissTitle(writeSucceeded: true, payNotPlaced: false), "Close")
        XCTAssertEqual(orderReviewDismissTitle(writeSucceeded: true, payNotPlaced: true), "Close")
        XCTAssertEqual(orderReviewDismissTitle(writeSucceeded: false, payNotPlaced: false), "Go Back")
    }

    func testRefreshIsTheOneWordForReading() {
        XCTAssertTrue(orderListChangedWhileLoadingNote.hasSuffix("Refresh to see them all."))
        XCTAssertFalse(unknownOutcomeBlockMessage.contains("Reload"))
        XCTAssertFalse(orderReviewDifferentOrderMessage.contains("Reload"))
        XCTAssertTrue(batchPayLockNotice(lockedOrderNumbers: ["SLANT_1"])?.contains("Press Refresh Order on it") == true)
        XCTAssertFalse(batchPayLockedMessage(lockedOrderIDs: ["SLANT_1"]).contains("Reload"))
        for state: BatchPayRowState in [.unknown, .unclear, .reloaded("SUBMITTED")] {
            XCTAssertFalse(batchPayStateText(state).contains("Reload"))
        }
    }

    func testLookForOrdersPluralises() {
        XCTAssertEqual(dapiLookForOrdersButtonTitle(count: 1), "Look for Order on 3DAPI")
        XCTAssertEqual(dapiLookForOrdersButtonTitle(count: 0), "Look for Order on 3DAPI")
        XCTAssertEqual(dapiLookForOrdersButtonTitle(count: 2), "Look for Orders on 3DAPI")
        let discard = dapiComposerDiscardMessage(hasUnconfirmedAttempt: true)
        XCTAssertTrue(dapiNamingLookForButton(discard, count: 3).contains("use Look for Orders on 3DAPI."))
        XCTAssertEqual(dapiNamingLookForButton(discard, count: 1), discard)
        XCTAssertTrue(dapiNamingLookForButton(dapiPlaceUnknownText, count: 2).contains("Press Look for Orders on 3DAPI"))
    }

    func testThreeDAPINoKeyStateIsWordedOnce() {
        XCTAssertEqual(dapiAddKeyTitle, "Add a 3DAPI key")
        XCTAssertEqual(dapiAddKeyButtonTitle, "Add 3DAPI Key…")
    }

    func testAttentionEmptyTextNamesOnlyTheFiltersInUse() {
        XCTAssertEqual(orderAttentionEmptyDetail(statusFilter: "PRINTING", datesFiltered: false, search: ""),
                       "None of the loaded Printing orders need attention.")
        XCTAssertFalse(orderAttentionEmptyDetail(statusFilter: nil, datesFiltered: false).contains("status"))
        XCTAssertFalse(orderAttentionEmptyDetail(statusFilter: nil, datesFiltered: false).contains("dates"))
    }

    // MARK: Disabled reasons and labels

    func testDisabledActionCaptionsSkipMomentaryReasons() {
        XCTAssertEqual(orderDisabledActionCaption("Duplicate as New Draft…", reason: "Finish or close the open order draft first."),
                       "Duplicate as New Draft… isn’t available: Finish or close the open order draft first.")
        XCTAssertNil(orderDisabledActionCaption("Duplicate as New Draft…", reason: nil))
        XCTAssertNil(orderDisabledActionCaption("Duplicate as New Draft…", reason: "Working…"))
        XCTAssertNil(orderDisabledActionCaption("Import Orders…", reason: "Wait for the current task to finish."))
        XCTAssertNil(orderDisabledActionCaption("Import Orders…", reason: "  "))
    }

    func testImportCaptionOnlyWhenTheDraftCaptionDoesntSayIt() {
        XCTAssertNil(orderImportToolbarCaption(importReason: nil, draftReason: nil))
        XCTAssertNil(orderImportToolbarCaption(importReason: "Connect your account first.", draftReason: "Connect your account first."))
        XCTAssertEqual(orderImportToolbarCaption(importReason: "Connect your account first.", draftReason: nil),
                       "Import Orders… isn’t available: Connect your account first.")
        XCTAssertNil(orderImportToolbarCaption(importReason: "Wait for the current task to finish.", draftReason: nil))
    }

    func testTrackingRowCopyLabelNamesTheReferenceOrPosition() {
        XCTAssertEqual(dapiTrackingCopyAccessibilityLabel(reference: "Etsy 123", position: 2, count: 5), "Copy, Etsy 123")
        XCTAssertEqual(dapiTrackingCopyAccessibilityLabel(reference: nil, position: 2, count: 5), "Copy, order 2 of 5")
        XCTAssertEqual(dapiTrackingCopyAccessibilityLabel(reference: "  ", position: 1, count: 1), "Copy, order 1 of 1")
    }

    func testShopFollowUpTitleSuffix() {
        XCTAssertEqual(shopFollowUpOrderSuffix(firstName: "Ada", status: "SHIPPED"), " · Ada · Shipped")
        XCTAssertEqual(shopFollowUpOrderSuffix(firstName: nil, status: "PRINTING"), " · Printing")
        XCTAssertEqual(shopFollowUpOrderSuffix(firstName: " ", status: "SHIPPED"), " · Shipped")
    }
}
