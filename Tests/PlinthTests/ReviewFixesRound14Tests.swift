import XCTest
@testable import Plinth

/// Round 14 review fixes: copy for pages trimmed by the date filter, unknown outcomes in the pay/cancel review and the
/// Workbench, creates that may already exist, the quantity check and the status hints.
final class ReviewFixesRound14Tests: XCTestCase {
    func testEmptyFilteredListWithMorePagesSaysSoFar() {
        let dated = OrderFilter(startDate: Date())
        XCTAssertEqual(orderFilterEmptyDetail(dated, moreOnServer: true),
                       "No orders in the chosen dates on the pages loaded so far. Load More reads the next page from Slant.")
        XCTAssertEqual(orderFilterEmptyDetail(dated, search: " ada ", moreOnServer: true),
                       "No orders in the chosen dates match “ada” on the pages loaded so far. Load More reads the next page from Slant.")
        // Unchanged without more pages.
        XCTAssertEqual(orderFilterEmptyDetail(dated), "No orders in the chosen dates.")
    }

    func testUnknownPayOrCancelNamesTheCauseWithoutRetryAdvice() {
        let timeout = URLError(.timedOut)
        let pay = orderConfirmUnknownOutcomeMessage(isPay: true, error: timeout)
        XCTAssertEqual(pay, "Slant didn’t reply in time, so the result is unknown: the order may have been placed and charged. Reload the order to see what Slant shows.")
        let server = APIError.http(status: 503, body: "", retryAfter: nil, rateLimitReset: nil)
        let cancel = orderConfirmUnknownOutcomeMessage(isPay: false, error: server)
        XCTAssertTrue(cancel.hasPrefix("Slant replied with HTTP 503, so the result is unknown: the cancellation may have gone through."))
        for message in [pay, cancel] {
            XCTAssertFalse(message.localizedCaseInsensitiveContains("try again"))
            XCTAssertFalse(message.localizedCaseInsensitiveContains("failed"))
        }
        XCTAssertEqual(slantUnclearReplyCause(URLError(.networkConnectionLost)), "The connection to Slant was interrupted")
        XCTAssertEqual(slantUnclearReplyCause(APIError.invalidResponse("x")), "Slant’s reply didn’t confirm it")
    }

    func testReviewDismissTitle() {
        XCTAssertEqual(orderReviewDismissTitle(writeSucceeded: false, payNotPlaced: false), "Go Back")
        XCTAssertEqual(orderReviewDismissTitle(writeSucceeded: true, payNotPlaced: false), "Done")
        XCTAssertEqual(orderReviewDismissTitle(writeSucceeded: true, payNotPlaced: true), "Close")
    }

    func testWorkbenchReloadNoteNamesTheStatus() {
        XCTAssertEqual(workbenchReloadResolvedNote(status: "SUBMITTED"),
                       "The reload shows the outcome: Slant now lists this order as “Submitted”.")
    }

    func testCreatesThatMayExistSayToCheckFirst() {
        let unclear: [Error] = [
            APIError.http(status: 502, body: "", retryAfter: nil, rateLimitReset: nil),
            APIError.http(status: 408, body: "", retryAfter: nil, rateLimitReset: nil),
            APIError.invalidResponse("unreadable"),
            URLError(.timedOut),
            URLError(.networkConnectionLost),
        ]
        for error in unclear {
            XCTAssertTrue(slantCreateOutcomeUnclear(error), "\(error)")
            let upload = uploadFromURLUnclearMessage(error) ?? ""
            XCTAssertTrue(upload.contains("may already be in your Slant files"))
            XCTAssertTrue(upload.contains("Refresh"))
            let platform = platformCreateUnclearMessage(error) ?? ""
            XCTAssertTrue(platform.contains("may already exist"))
            XCTAssertTrue(platform.contains("Reload Platforms"))
        }
        let definite: [Error] = [
            APIError.http(status: 400, body: "", retryAfter: nil, rateLimitReset: nil),
            APIError.http(status: 404, body: "", retryAfter: nil, rateLimitReset: nil),
            APIError.http(status: 429, body: "", retryAfter: nil, rateLimitReset: nil),
            APIError.invalidRequest("bad"),
            URLError(.cannotFindHost),
            StudioError("Slant didn’t return the new platform’s ID. Reload platforms to check before creating another."),
        ]
        for error in definite {
            XCTAssertFalse(slantCreateOutcomeUnclear(error), "\(error)")
            XCTAssertNil(uploadFromURLUnclearMessage(error))
            XCTAssertNil(platformCreateUnclearMessage(error))
        }
        // The 404/405 "no longer takes links" copy still comes first.
        XCTAssertNotNil(uploadFromURLUnavailableMessage(APIError.http(status: 405, body: "", retryAfter: nil, rateLimitReset: nil)))
    }

    func testQuantityMismatchCopy() {
        guard case .unusable(let reason) = comparisonPrice(from: ["quantity": 3, "total": "9.00"], requestedQuantity: 5) else {
            return XCTFail("Expected a mismatch")
        }
        XCTAssertEqual(reason, "Slant priced a quantity of 3, not the 5 you asked for.")
    }

    func testStatusHints() {
        XCTAssertEqual(orderStatusHelp("submitted"), "Paid, waiting to print")
        XCTAssertEqual(orderStatusHelp("PRINTING"), "In production: printing, finishing and packing")
        XCTAssertNil(orderStatusHelp("SHIPPED"))
        XCTAssertNil(orderStatusHelp("DRAFT"))
    }

    func testUnconfirmedUploadCopyPointsToRefreshAndUploadAgain() {
        XCTAssertEqual(uploadUnconfirmedStatusText, uploadUnconfirmedMessage)
        XCTAssertTrue(uploadUnconfirmedMessage.contains("Refresh"))
        XCTAssertTrue(uploadUnconfirmedMessage.contains("Upload Again…"))
    }
}
