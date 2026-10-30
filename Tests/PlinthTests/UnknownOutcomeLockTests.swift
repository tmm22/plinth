import XCTest
@testable import Plinth

final class UnknownOutcomeLockTests: XCTestCase {
    func testPayLockClearsOnlyOnceTheOrderLeavesDraft() {
        let context = UnknownOutcomeContext(action: .pay, reviewedStatus: "DRAFT")
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: context, reloadedStatus: "DRAFT"))
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: context, reloadedStatus: "draft"))
        XCTAssertTrue(unknownOutcomeResolvedByReload(context: context, reloadedStatus: "PROCESSING"))
    }

    func testCancelLockClearsOnlyWhenStatusChangesFromWhereItWasSent() {
        let context = UnknownOutcomeContext(action: .cancel, reviewedStatus: "PROCESSING")
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: context, reloadedStatus: "PROCESSING"))
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: context, reloadedStatus: "processing"))
        XCTAssertTrue(unknownOutcomeResolvedByReload(context: context, reloadedStatus: "CANCELLED"))
    }

    func testLockStaysWhenAReloadCannotShowWhatHappened() {
        // No record of the attempt: even a non-draft status can't prove which request took effect.
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: nil, reloadedStatus: "PROCESSING"))
        // A cancel without the status it was sent from can't be compared.
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: UnknownOutcomeContext(action: .cancel, reviewedStatus: ""), reloadedStatus: "CANCELLED"))
        // A reload without a status resolves nothing.
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: UnknownOutcomeContext(action: .pay, reviewedStatus: "DRAFT"), reloadedStatus: ""))
    }

    func testOnlyDefiniteRejectionsLiftTheLock() {
        func http(_ status: Int) -> APIError { .http(status: status, body: "", retryAfter: nil, rateLimitReset: nil) }
        // Refused by Slant, or never sent: nothing is pending.
        for status in [400, 401, 402, 403, 404, 422, 429] {
            XCTAssertTrue(orderMutationErrorProvesNoEffect(http(status)), "HTTP \(status)")
        }
        XCTAssertTrue(orderMutationErrorProvesNoEffect(APIError.invalidRequest("Connect your account in Settings first.")))
        // Outcome unknown: the request may have been processed.
        for status in [408, 409, 500, 502, 503, 504] {
            XCTAssertFalse(orderMutationErrorProvesNoEffect(http(status)), "HTTP \(status)")
        }
        XCTAssertFalse(orderMutationErrorProvesNoEffect(APIError.invalidResponse("The API reported a failure (HTTP 200)")))
        XCTAssertFalse(orderMutationErrorProvesNoEffect(URLError(.timedOut)))
        XCTAssertFalse(orderMutationErrorProvesNoEffect(URLError(.networkConnectionLost)))
        XCTAssertFalse(orderMutationErrorProvesNoEffect(StudioError("Something else")))
    }

    func testWorkbenchStyleReloadWithUnchangedStatusKeepsCancelLock() {
        // A cancel sent from PROCESSING that timed out; a reload still shows PROCESSING.
        let recorded = UnknownOutcomeContext(action: .cancel, reviewedStatus: "PROCESSING")
        XCTAssertFalse(unknownOutcomeResolvedByReload(context: recorded, reloadedStatus: "processing"))
    }
}
