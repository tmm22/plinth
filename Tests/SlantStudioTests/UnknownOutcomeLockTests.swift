import XCTest
@testable import SlantStudio

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
}
