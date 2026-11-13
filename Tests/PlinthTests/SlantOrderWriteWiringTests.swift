import XCTest
@testable import Plinth

/// The wiring of the two Slant money paths: the single pay/cancel review (`orderReviewWrite` and what the sheet then
/// shows, `orderReviewSheetResult`, SlantOrderWrite.swift) and Pay Several Drafts' one order (`batchPayOne`) and review
/// (`batchPayReviewedDrafts`, BatchPay.swift). A recording fake stands in
/// for Slant, the shared unknown-outcome lock and the quit guard, so each scenario asserts the exact order of the
/// re-fetch, the checks, the lock, the write and the lift. The fake's POST and DELETE fail the test unless the lock is
/// already recorded, and unless the scenario expects a write at all. No real order IDs, tracking numbers or payment IDs.
@MainActor
final class SlantOrderWriteWiringTests: XCTestCase {

    // MARK: The recording fake

    enum Step: Equatable {
        case get(String)
        case post(String)
        case delete(String)
        case checkLock(String)
        case lock(String, OutcomeAction, String?)
        case unlock(String)
        /// The single review's `onWriteAttempted` hook.
        case attempted(Bool)
        case beginWrite(SlantWriteKind)
        case endWrite
        case noteRateLimit
        case noteRateLimitError
    }

    @MainActor final class FakeSlant {
        var log: [Step] = []
        private(set) var locks: [String: (action: OutcomeAction, status: String?)] = [:]
        var lockedIDs: Set<String> { Set(locks.keys) }
        /// Replies to the GETs, in turn. A GET beyond them fails the test.
        private var reads: [Result<[String: Any], Error>]
        /// The reply to the one POST or DELETE. Nil means the scenario must send none: sending one fails the test.
        private var write: Result<[String: Any], Error>?
        /// The single review registers its write with the quit guard before sending; Pay Several Drafts' batch token
        /// covers its orders, so `batchPayOne` never does.
        private let writeNeedsToken: Bool
        private var openTokens: [UUID] = []

        init(reads: [Result<[String: Any], Error>], write: Result<[String: Any], Error>? = nil,
             writeNeedsToken: Bool, alreadyLocked: [String] = []) {
            self.reads = reads
            self.write = write
            self.writeNeedsToken = writeNeedsToken
            for id in alreadyLocked { locks[id] = (.pay, "DRAFT") }
        }

        var env: SlantOrderWriteEnvironment {
            SlantOrderWriteEnvironment(
                request: { method, path in try self.handle(method, path) },
                isOutcomeUnknown: { id in
                    self.log.append(.checkLock(id))
                    return self.locks[id] != nil
                },
                markOutcomeUnknown: { id, action, status in
                    self.log.append(.lock(id, action, status))
                    self.locks[id] = (action, status)
                },
                clearOutcomeUnknown: { id in
                    self.log.append(.unlock(id))
                    self.locks[id] = nil
                },
                beginWrite: { kind in
                    self.log.append(.beginWrite(kind))
                    let token = UUID()
                    self.openTokens.append(token)
                    return token
                },
                endWrite: { token in
                    self.log.append(.endWrite)
                    XCTAssertEqual(self.openTokens.last, token, "Ends the write it began")
                    self.openTokens.removeAll { $0 == token }
                },
                noteRateLimit: { _ in self.log.append(.noteRateLimit) },
                noteRateLimitError: { _ in self.log.append(.noteRateLimitError) })
        }

        private func handle(_ method: String, _ path: String) throws -> APIResponse {
            let prefix = "/orders/"
            XCTAssertTrue(path.hasPrefix(prefix), "Only order requests: \(path)")
            let id = String(path.dropFirst(prefix.count))
            switch method {
            case "GET":
                log.append(.get(id))
                guard !reads.isEmpty else {
                    XCTFail("An unexpected GET of \(id)")
                    throw StudioError("Unexpected GET")
                }
                return try Self.reply(reads.removeFirst().get())
            case "POST", "DELETE":
                log.append(method == "POST" ? .post(id) : .delete(id))
                XCTAssertNotNil(locks[id], "The lock must be recorded before the \(method) is sent")
                if writeNeedsToken { XCTAssertFalse(openTokens.isEmpty, "Quit must ask while the \(method) waits") }
                guard let reply = write else {
                    XCTFail("A \(method) was sent in a scenario that must send none")
                    throw StudioError("Unexpected write")
                }
                write = nil
                return try Self.reply(reply.get())
            default:
                XCTFail("Unexpected method \(method)")
                throw StudioError("Unexpected method")
            }
        }

        static func reply(_ object: [String: Any]) throws -> APIResponse {
            APIResponse(data: try JSONSerialization.data(withJSONObject: object), statusCode: 200)
        }
    }

    // MARK: Fixtures

    nonisolated static let orderID = "ord-test-1"

    static func order(_ id: String = orderID, status: String, extra: [String: Any] = [:]) -> [String: Any] {
        var order: [String: Any] = ["publicId": id, "status": status, "printingCost": 8.5, "deliveryCost": 4.25]
        order.merge(extra) { _, new in new }
        return order
    }

    static func http(_ status: Int, body: String = "") -> APIError {
        .http(status: status, body: body, retryAfter: nil, rateLimitReset: nil)
    }

    /// Errors after which the request may have reached Slant: the lock stays.
    static let unclearErrors: [Error] = [http(408), http(409), http(500), http(503), URLError(.timedOut),
                                         URLError(.networkConnectionLost), URLError(.notConnectedToInternet)]

    func review(_ fake: FakeSlant, method: String, shown: [String: Any], id: String = orderID)
        async -> (record: OrderReviewWriteRecord, error: Error?) {
        let record = OrderReviewWriteRecord()
        record.onWriteAttempted = { fake.log.append(.attempted($0)) }
        do {
            try await orderReviewWrite(orderID: id, method: method, shown: shown, env: fake.env, record: record)
            return (record, nil)
        } catch {
            return (record, error)
        }
    }

    func message(_ error: Error?) -> String? { (error as? StudioError)?.message }

    let id = SlantOrderWriteWiringTests.orderID
    var payPrefix: [Step] {
        [.get(id), .checkLock(id), .lock(id, .pay, "DRAFT"), .attempted(true), .beginWrite(.payment), .post(id)]
    }
    var cancelPrefix: [Step] {
        [.get(id), .checkLock(id), .lock(id, .cancel, "SUBMITTED"), .attempted(true), .beginWrite(.cancellation), .delete(id)]
    }

    // MARK: Single review: pay

    func testAPlacedPayLocksBeforeSendingAndLiftsAfterTheRefresh() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: "SUBMITTED"))],
                             write: .success(Self.order(status: "SUBMITTED")), writeNeedsToken: true)
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertNil(error)
        XCTAssertEqual(fake.log, payPrefix + [.get(id), .unlock(id), .endWrite])
        XCTAssertTrue(fake.lockedIDs.isEmpty)
        XCTAssertTrue(record.didWrite)
        XCTAssertTrue(record.attemptedWrite)
        XCTAssertFalse(record.payAcceptedUnconfirmed)
        XCTAssertEqual(record.payOutcome, .placed)
        XCTAssertEqual(record.outcome, .proceed)
        XCTAssertEqual(record.completedOrder?["status"] as? String, "SUBMITTED")
        XCTAssertEqual(record.latestOrder?["status"] as? String, "DRAFT")
    }

    func testAPayIsNotSentWhenTheOrderIsNoLongerADraft() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "SUBMITTED"))], writeNeedsToken: true)
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(message(error), "Only drafts can be placed.")
        XCTAssertEqual(fake.log, [.get(id)])
        XCTAssertEqual(record.outcome, .statusBlocked("Only drafts can be placed."))
        XCTAssertFalse(record.attemptedWrite)
        XCTAssertTrue(fake.lockedIDs.isEmpty)
    }

    func testAPayIsNotSentWhenAnUnlistedCostAppeared() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT", extra: ["taxCost": 1.5]))], writeNeedsToken: true)
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(message(error), "The price changed. Review the new total.")
        XCTAssertEqual(fake.log, [.get(id)])
        XCTAssertEqual(record.outcome, .priceChanged)
        XCTAssertTrue(fake.lockedIDs.isEmpty)
    }

    func testAPayIsNotSentWhenThePriceChanged() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT", extra: ["deliveryCost": 9.0]))], writeNeedsToken: true)
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(message(error), "The price changed. Review the new total.")
        XCTAssertEqual(fake.log, [.get(id)])
        XCTAssertEqual(record.outcome, .priceChanged)
    }

    func testAPayIsNotSentWhileTheOrderIsAlreadyLocked() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))], writeNeedsToken: true, alreadyLocked: [id])
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(message(error), unknownOutcomeBlockMessage)
        XCTAssertEqual(fake.log, [.get(id), .checkLock(id)])
        XCTAssertEqual(fake.lockedIDs, [id], "The earlier lock stays")
        XCTAssertFalse(record.attemptedWrite)
    }

    func testAReplyForAnotherOrderStopsBeforeAnything() async {
        let fake = FakeSlant(reads: [.success(Self.order("ord-test-other", status: "DRAFT"))], writeNeedsToken: true)
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(message(error), orderReviewDifferentOrderMessage)
        XCTAssertEqual(fake.log, [.get(id)])
        XCTAssertNil(record.latestOrder)
        // The cancel review stops the same way.
        let cancel = FakeSlant(reads: [.success(Self.order("ord-test-other", status: "SUBMITTED"))], writeNeedsToken: true)
        let cancelled = await review(cancel, method: "DELETE", shown: Self.order(status: "SUBMITTED"))
        XCTAssertEqual(message(cancelled.error), orderReviewDifferentOrderMessage)
        XCTAssertEqual(cancel.log, [.get(id)])
    }

    func testAFailedFirstReadSendsNothing() async {
        let fake = FakeSlant(reads: [.failure(URLError(.timedOut))], writeNeedsToken: true)
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual((error as? URLError)?.code, .timedOut)
        XCTAssertEqual(fake.log, [.get(id)])
        XCTAssertFalse(record.attemptedWrite)
    }

    func testAPayWithAnUnclearOutcomeKeepsTheLock() async {
        for failure in Self.unclearErrors {
            let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))], write: .failure(failure), writeNeedsToken: true)
            let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
            XCTAssertEqual(fake.log, payPrefix + [.endWrite], "\(failure)")
            XCTAssertEqual(fake.lockedIDs, [id], "\(failure)")
            XCTAssertEqual(message(error), slantUnclearReplyCause(failure) + ", so the result is unknown.")
            XCTAssertTrue(record.attemptedWrite)
            XCTAssertNotNil(record.unknownWriteError)
            XCTAssertFalse(record.rejected)
        }
        // The text Activity shows, pinned once.
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))], write: .failure(Self.http(503)), writeNeedsToken: true)
        let (_, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(message(error), "Slant replied with HTTP 503, so the result is unknown.")
    }

    func testAPayRefusedOrNeverSentLiftsTheLock() async {
        let refusals: [Error] = [Self.http(400, body: #"{"message":"Card declined"}"#), Self.http(401), Self.http(404),
                                 Self.http(422), URLError(.cannotFindHost), URLError(.dnsLookupFailed), URLError(.badURL),
                                 APIError.invalidRequest("Bad path")]
        for failure in refusals {
            let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))], write: .failure(failure), writeNeedsToken: true)
            let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
            XCTAssertEqual(fake.log, payPrefix + [.unlock(id), .attempted(false), .endWrite], "\(failure)")
            XCTAssertTrue(fake.lockedIDs.isEmpty, "\(failure)")
            XCTAssertNotNil(error)
            XCTAssertNil(error as? StudioError, "The refusal itself is rethrown")
            XCTAssertTrue(record.rejected)
            XCTAssertFalse(record.attemptedWrite)
            XCTAssertEqual(record.refusal, orderConfirmRefusalMessage(isPay: true, error: failure))
            XCTAssertNil(record.unknownWriteError)
        }
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))],
                             write: .failure(Self.http(422, body: #"{"message":"Card declined"}"#)), writeNeedsToken: true)
        let (record, _) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(record.refusal, "Slant didn’t accept the payment request. Slant said: “Card declined.”")
    }

    func testAnAcceptedPayStillShowingADraftKeepsTheLock() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: "DRAFT"))],
                             write: .success(Self.order(status: "DRAFT")), writeNeedsToken: true)
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(fake.log, payPrefix + [.get(id), .endWrite])
        XCTAssertEqual(fake.lockedIDs, [id])
        XCTAssertTrue(record.payAcceptedUnconfirmed)
        XCTAssertFalse(record.didWrite)
        XCTAssertEqual(message(error), orderPayActivityDetail(batchPayOutcomeAfterSuccess(Self.order(status: "DRAFT"))))
        XCTAssertTrue(message(error)?.hasPrefix("Accepted, but not placed.") == true)
    }

    func testAnAcceptedPayWithNoReadableOrderKeepsTheLock() async {
        // The refresh fails and the reply names no order: whether it was charged isn't known.
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .failure(URLError(.timedOut))],
                             write: .success([:]), writeNeedsToken: true)
        let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(fake.log, payPrefix + [.get(id), .endWrite])
        XCTAssertEqual(fake.lockedIDs, [id])
        XCTAssertTrue(record.payAcceptedUnconfirmed)
        XCTAssertNil(record.completedOrder)
        XCTAssertEqual(record.payOutcome, .unclear)
        XCTAssertEqual(message(error), "Accepted, but Slant’s reply didn’t show the order’s status, so it may still be charged")
    }

    func testAnAcceptedPayIsJudgedOnlyByThisOrder() async {
        // The refresh returns another order, so the reply decides: placed.
        let replyDecides = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order("ord-test-other", status: "DRAFT"))],
                                     write: .success(Self.order(status: "SUBMITTED")), writeNeedsToken: true)
        let placed = await review(replyDecides, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertNil(placed.error)
        XCTAssertEqual(replyDecides.log, payPrefix + [.get(id), .unlock(id), .endWrite])
        XCTAssertEqual(placed.record.payOutcome, .placed)
        // Both name another order: unclear, and the lock stays.
        let neither = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order("ord-test-other", status: "SUBMITTED"))],
                                write: .success(Self.order("ord-test-other", status: "SUBMITTED")), writeNeedsToken: true)
        let unclear = await review(neither, method: "POST", shown: Self.order(status: "DRAFT"))
        XCTAssertEqual(neither.log, payPrefix + [.get(id), .endWrite])
        XCTAssertEqual(neither.lockedIDs, [id])
        XCTAssertEqual(unclear.record.payOutcome, .unclear)
        XCTAssertTrue(unclear.record.payAcceptedUnconfirmed)
    }

    func testAnAcceptedPayThatWasNotPlacedLiftsTheLockButIsNotReportedAsPlaced() async {
        for status in ["CANCELLED", "PAYMENT_ERROR", "SOMETHING_NEW"] {
            let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: status))],
                                 write: .success(Self.order(status: status)), writeNeedsToken: true)
            let (record, error) = await review(fake, method: "POST", shown: Self.order(status: "DRAFT"))
            XCTAssertEqual(fake.log, payPrefix + [.get(id), .unlock(id), .endWrite], status)
            XCTAssertTrue(fake.lockedIDs.isEmpty, status)
            XCTAssertTrue(record.didWrite, status)
            XCTAssertNotEqual(record.payOutcome, .placed, status)
            XCTAssertEqual(message(error), orderPayActivityDetail(batchPayOutcomeAfterSuccess(Self.order(status: status))), status)
        }
    }

    // MARK: Single review: cancel

    func testACancelLocksBeforeSendingAndLiftsOnSuccess() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "SUBMITTED")), .success(Self.order(status: "CANCELLED"))],
                             write: .success(Self.order(status: "CANCELLED")), writeNeedsToken: true)
        let (record, error) = await review(fake, method: "DELETE", shown: Self.order(status: "SUBMITTED"))
        XCTAssertNil(error)
        XCTAssertEqual(fake.log, cancelPrefix + [.get(id), .unlock(id), .endWrite])
        XCTAssertTrue(fake.lockedIDs.isEmpty)
        XCTAssertTrue(record.didWrite)
        XCTAssertNil(record.payOutcome)
    }

    func testACancelIsNotSentWhenTheStatusChanged() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "PRINTING"))], writeNeedsToken: true)
        let (record, error) = await review(fake, method: "DELETE", shown: Self.order(status: "SUBMITTED"))
        XCTAssertEqual(message(error), "This order’s status changed. Review it again.")
        XCTAssertEqual(fake.log, [.get(id)])
        XCTAssertEqual(record.outcome, .statusBlocked("This order’s status changed. Review it again."))
        XCTAssertTrue(fake.lockedIDs.isEmpty)
    }

    func testACancelIsNotSentWhenTheShippingDetailsChanged() async {
        let shipped = Self.order(status: "SUBMITTED", extra: ["fulfillment": ["trackingNumber": "TEST-TRACKING-0001"]])
        let fake = FakeSlant(reads: [.success(shipped)], writeNeedsToken: true)
        let (record, error) = await review(fake, method: "DELETE", shown: Self.order(status: "SUBMITTED"))
        XCTAssertEqual(message(error), orderShippingDetailsChangedMessage)
        XCTAssertEqual(fake.log, [.get(id)])
        XCTAssertEqual(record.outcome, .statusBlocked(orderShippingDetailsChangedMessage))
    }

    func testACancelIsNotSentForAnOrderThatCantBeCancelled() async {
        for status in ["DRAFT", "CANCELLED", "SOMETHING_NEW"] {
            let fake = FakeSlant(reads: [.success(Self.order(status: status))], writeNeedsToken: true)
            let (_, error) = await review(fake, method: "DELETE", shown: Self.order(status: status))
            XCTAssertEqual(message(error), orderCancellationBlockedReason(status), status)
            XCTAssertEqual(fake.log, [.get(id)], status)
        }
    }

    func testACancelIsNotSentWhileTheOrderIsAlreadyLocked() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "SUBMITTED"))], writeNeedsToken: true, alreadyLocked: [id])
        let (_, error) = await review(fake, method: "DELETE", shown: Self.order(status: "SUBMITTED"))
        XCTAssertEqual(message(error), unknownOutcomeBlockMessage)
        XCTAssertEqual(fake.log, [.get(id), .checkLock(id)])
    }

    func testACancelWithAnUnclearOutcomeKeepsTheLock() async {
        // A DNS failure may be resent on a fresh connection for a DELETE, so it keeps the lock too.
        for failure in Self.unclearErrors + [URLError(.cannotFindHost), URLError(.dnsLookupFailed)] {
            let fake = FakeSlant(reads: [.success(Self.order(status: "SUBMITTED"))], write: .failure(failure), writeNeedsToken: true)
            let (record, error) = await review(fake, method: "DELETE", shown: Self.order(status: "SUBMITTED"))
            XCTAssertEqual(fake.log, cancelPrefix + [.endWrite], "\(failure)")
            XCTAssertEqual(fake.lockedIDs, [id], "\(failure)")
            XCTAssertEqual(message(error), slantUnclearReplyCause(failure) + ", so the result is unknown.")
            XCTAssertTrue(record.attemptedWrite)
        }
    }

    func testACancelRefusedOrNeverSentLiftsTheLock() async {
        for failure in [Self.http(400), Self.http(403), Self.http(422), URLError(.badURL)] as [Error] {
            let fake = FakeSlant(reads: [.success(Self.order(status: "SUBMITTED"))], write: .failure(failure), writeNeedsToken: true)
            let (record, _) = await review(fake, method: "DELETE", shown: Self.order(status: "SUBMITTED"))
            XCTAssertEqual(fake.log, cancelPrefix + [.unlock(id), .attempted(false), .endWrite], "\(failure)")
            XCTAssertTrue(fake.lockedIDs.isEmpty, "\(failure)")
            XCTAssertEqual(record.refusal, orderConfirmRefusalMessage(isPay: false, error: failure))
        }
    }

    // MARK: Single review: what the sheet shows

    func sheet(_ record: OrderReviewWriteRecord, ran: Bool = true, failure: String? = nil, isPay: Bool = true,
               refundOnly: Bool = false) -> OrderReviewSheetResult {
        orderReviewSheetResult(record: record, ran: ran, failure: failure, isPay: isPay, refundOnly: refundOnly,
                               shown: Self.order(status: isPay ? "DRAFT" : "SUBMITTED"))
    }

    func testTheSheetSaysPlacedOnlyForAConfirmedPlacedPay() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: "SUBMITTED"))],
                             write: .success(Self.order(status: "SUBMITTED")), writeNeedsToken: true)
        let result = sheet(await review(fake, method: "POST", shown: Self.order(status: "DRAFT")).record)
        XCTAssertFalse(result.awaitingBusy)
        XCTAssertEqual(result.succeeded?.successMessage, "Order placed.")
        XCTAssertEqual(result.succeeded?.payNotPlaced, false)
        XCTAssertEqual(result.succeeded?.order["status"] as? String, "SUBMITTED", "The order Slant now shows")
        XCTAssertEqual(result.shownOrder?["status"] as? String, "SUBMITTED")
        XCTAssertNil(result.actionMessage)
    }

    func testTheSheetSaysCancellationOrRefundForAConfirmedCancel() async {
        for refundOnly in [false, true] {
            let fake = FakeSlant(reads: [.success(Self.order(status: "SUBMITTED")), .success(Self.order(status: "CANCELLED"))],
                                 write: .success(Self.order(status: "CANCELLED")), writeNeedsToken: true)
            let record = await review(fake, method: "DELETE", shown: Self.order(status: "SUBMITTED")).record
            let result = sheet(record, isPay: false, refundOnly: refundOnly)
            XCTAssertEqual(result.succeeded?.successMessage, refundOnly ? "Refund requested." : "Cancellation requested.")
            XCTAssertEqual(result.succeeded?.order["status"] as? String, "CANCELLED")
            XCTAssertNil(result.actionMessage)
        }
    }

    func testTheSheetExplainsAnAcceptedPayThatWasNotPlaced() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: "PAYMENT_ERROR"))],
                             write: .success(Self.order(status: "PAYMENT_ERROR")), writeNeedsToken: true)
        let record = await review(fake, method: "POST", shown: Self.order(status: "DRAFT")).record
        let result = sheet(record)
        XCTAssertEqual(result.succeeded?.payNotPlaced, true, "No next draft is offered")
        XCTAssertNil(result.succeeded?.successMessage, "Never “Order placed.”")
        XCTAssertEqual(result.actionMessage, orderPayAcceptedMessage(batchPayOutcomeAfterSuccess(Self.order(status: "PAYMENT_ERROR"))))
        XCTAssertNotNil(result.actionMessage)
    }

    func testTheSheetWarnsWhenAnAcceptedPayStillShowsADraft() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: "DRAFT"))],
                             write: .success(Self.order(status: "DRAFT")), writeNeedsToken: true)
        let record = await review(fake, method: "POST", shown: Self.order(status: "DRAFT")).record
        let result = sheet(record)
        XCTAssertNil(result.succeeded, "Not a confirmed charge")
        XCTAssertEqual(result.actionMessage, "Slant accepted the payment request but doesn’t show the order as placed yet, so it may still be charged. Press Refresh Order before doing anything else.")
        XCTAssertEqual(result.shownOrder?["status"] as? String, "DRAFT")
    }

    func testTheSheetSaysTheOutcomeIsUnknownAfterAnUnclearReply() async {
        for isPay in [true, false] {
            let fake = FakeSlant(reads: [.success(Self.order(status: isPay ? "DRAFT" : "SUBMITTED"))],
                                 write: .failure(Self.http(503)), writeNeedsToken: true)
            let record = await review(fake, method: isPay ? "POST" : "DELETE", shown: Self.order(status: isPay ? "DRAFT" : "SUBMITTED")).record
            let result = sheet(record, failure: "The run's own message", isPay: isPay)
            XCTAssertNil(result.succeeded)
            XCTAssertNotNil(record.unknownWriteError)
            XCTAssertEqual(result.actionMessage, record.unknownWriteError.map { orderConfirmUnknownOutcomeMessage(isPay: isPay, error: $0) })
            XCTAssertNotEqual(result.actionMessage, "The run's own message", "The unknown outcome is explained, not the run's error")
        }
    }

    func testTheSheetShowsSlantsRefusal() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))],
                             write: .failure(Self.http(400, body: #"{"message":"Card declined"}"#)), writeNeedsToken: true)
        let record = await review(fake, method: "POST", shown: Self.order(status: "DRAFT")).record
        let result = sheet(record, failure: "The run's own message")
        XCTAssertNil(result.succeeded)
        XCTAssertNotNil(record.refusal)
        XCTAssertEqual(result.actionMessage, record.refusal)
    }

    func testTheSheetSaysWhyNothingWasSent() async {
        let blocked = FakeSlant(reads: [.success(Self.order(status: "SUBMITTED"))], writeNeedsToken: true)
        let blockedResult = sheet(await review(blocked, method: "POST", shown: Self.order(status: "DRAFT")).record)
        XCTAssertNil(blockedResult.succeeded)
        XCTAssertEqual(blockedResult.actionMessage, "Only drafts can be placed.")
        XCTAssertEqual(blockedResult.shownOrder?["status"] as? String, "SUBMITTED", "The review shows the order as it now is")

        let repriced = FakeSlant(reads: [.success(Self.order(status: "DRAFT", extra: ["deliveryCost": 9.0]))], writeNeedsToken: true)
        let repricedResult = sheet(await review(repriced, method: "POST", shown: Self.order(status: "DRAFT")).record)
        XCTAssertEqual(repricedResult.actionMessage, "The price changed. Review the new total.")

        let unread = FakeSlant(reads: [.failure(Self.http(500))], writeNeedsToken: true)
        let unreadResult = sheet(await review(unread, method: "POST", shown: Self.order(status: "DRAFT")).record,
                                 failure: "Slant had a problem.")
        XCTAssertNil(unreadResult.succeeded)
        XCTAssertNil(unreadResult.shownOrder)
        XCTAssertEqual(unreadResult.actionMessage, "Slant had a problem.", "The run's own message when nothing was sent")
    }

    func testTheSheetWaitsWhenTheRunNeverStarted() {
        let result = sheet(OrderReviewWriteRecord(), ran: false, failure: "ignored")
        XCTAssertTrue(result.awaitingBusy)
        XCTAssertNil(result.succeeded)
        XCTAssertNil(result.shownOrder)
        XCTAssertNil(result.actionMessage)
    }

    // MARK: Pay Several Drafts: one order

    /// Pays the reviewed draft (`Self.order(status: "DRAFT")` unless given).
    func pay(_ fake: FakeSlant, reviewed: [String: Any]? = nil)
        async -> (outcome: BatchPayOutcome, completed: [String: Any]?, error: Error?) {
        await batchPayOne(id, reviewed: reviewed ?? Self.order(status: "DRAFT"), env: fake.env)
    }

    var batchPrefix: [Step] { [.get(id), .noteRateLimit, .checkLock(id), .lock(id, .pay, "DRAFT"), .post(id)] }

    func testTheBatchPaysAPlacedOrderAndLiftsTheLock() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: "SUBMITTED"))],
                             write: .success(Self.order(status: "SUBMITTED")), writeNeedsToken: false)
        let result = await pay(fake)
        XCTAssertEqual(result.outcome, .placed)
        XCTAssertNil(result.error)
        XCTAssertEqual(result.completed?["status"] as? String, "SUBMITTED")
        // No write token per order: the batch's own covers it.
        XCTAssertEqual(fake.log, batchPrefix + [.noteRateLimit, .get(id), .noteRateLimit, .unlock(id)])
        XCTAssertTrue(fake.lockedIDs.isEmpty)
    }

    func testTheBatchSendsNothingWhenTheRefreshFails() async {
        let fake = FakeSlant(reads: [.failure(Self.http(500))], writeNeedsToken: false)
        let result = await pay(fake)
        XCTAssertEqual(result.outcome, .notSent("Couldn’t refresh it before paying. \(friendlyAPIMessage(Self.http(500)))"))
        XCTAssertNotNil(result.error)
        XCTAssertEqual(fake.log, [.get(id), .noteRateLimitError])
    }

    func testTheBatchSendsNothingForAnotherOrder() async {
        let fake = FakeSlant(reads: [.success(Self.order("ord-test-other", status: "DRAFT"))], writeNeedsToken: false)
        let result = await pay(fake)
        XCTAssertEqual(result.outcome, .changed("Slant returned a different order."))
        XCTAssertEqual(fake.log, [.get(id), .noteRateLimit])
    }

    func testTheBatchSendsNothingWhenTheOrderIsNoLongerADraft() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "SUBMITTED"))], writeNeedsToken: false)
        let result = await pay(fake)
        XCTAssertEqual(result.outcome, .changed("Only drafts can be placed."))
        XCTAssertEqual(fake.log, [.get(id), .noteRateLimit])
        XCTAssertTrue(fake.lockedIDs.isEmpty)
    }

    func testTheBatchSendsNothingWhenAnUnlistedCostAppeared() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT", extra: ["serviceFee": 2]))], writeNeedsToken: false)
        let result = await pay(fake)
        XCTAssertEqual(result.outcome, .changed("The price changed. Review the new total."))
        XCTAssertEqual(fake.log, [.get(id), .noteRateLimit])
    }

    func testTheBatchSendsNothingWhileTheOrderIsLocked() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))], writeNeedsToken: false, alreadyLocked: [id])
        let result = await pay(fake)
        XCTAssertEqual(result.outcome, .notSent(unknownOutcomeBlockMessage))
        XCTAssertEqual(fake.log, [.get(id), .noteRateLimit, .checkLock(id)])
        XCTAssertEqual(fake.lockedIDs, [id])
    }

    func testTheBatchKeepsTheLockAfterAnUnclearPay() async {
        for failure in Self.unclearErrors + [URLError(.cancelled)] {
            let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))], write: .failure(failure), writeNeedsToken: false)
            let result = await pay(fake)
            XCTAssertEqual(result.outcome, .unknown(friendlyAPIMessage(failure)), "\(failure)")
            XCTAssertEqual(fake.log, batchPrefix + [.noteRateLimitError], "\(failure)")
            XCTAssertEqual(fake.lockedIDs, [id], "\(failure)")
        }
    }

    func testTheBatchLiftsTheLockAfterARefusalOrAFailureBeforeSending() async {
        for failure in [Self.http(400), Self.http(402), Self.http(422), Self.http(429), URLError(.cannotFindHost),
                        URLError(.unsupportedURL)] as [Error] {
            let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT"))], write: .failure(failure), writeNeedsToken: false)
            let result = await pay(fake)
            XCTAssertEqual(result.outcome, .refused(orderConfirmRefusalMessage(isPay: true, error: failure)), "\(failure)")
            XCTAssertEqual(fake.log, batchPrefix + [.noteRateLimitError, .unlock(id)], "\(failure)")
            XCTAssertTrue(fake.lockedIDs.isEmpty, "\(failure)")
        }
    }

    func testTheBatchKeepsTheLockWhenAnAcceptedPayStillShowsADraft() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: "DRAFT"))],
                             write: .success(Self.order(status: "DRAFT")), writeNeedsToken: false)
        let result = await pay(fake)
        XCTAssertEqual(result.outcome, batchPayOutcomeAfterSuccess(Self.order(status: "DRAFT")))
        XCTAssertEqual(fake.log, batchPrefix + [.noteRateLimit, .get(id), .noteRateLimit])
        XCTAssertEqual(fake.lockedIDs, [id])
        // No readable order at all: unclear, and locked.
        let unreadable = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .failure(URLError(.timedOut))],
                                   write: .success([:]), writeNeedsToken: false)
        let unclear = await pay(unreadable)
        XCTAssertEqual(unclear.outcome, .unclear)
        XCTAssertEqual(unreadable.log, batchPrefix + [.noteRateLimit, .get(id)])
        XCTAssertEqual(unreadable.lockedIDs, [id])
    }

    func testTheBatchJudgesByTheReplyWhenTheRefreshFails() async {
        let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .failure(URLError(.timedOut))],
                             write: .success(Self.order(status: "SUBMITTED")), writeNeedsToken: false)
        let result = await pay(fake)
        XCTAssertEqual(result.outcome, .placed)
        XCTAssertEqual(fake.log, batchPrefix + [.noteRateLimit, .get(id), .unlock(id)])
    }

    func testTheBatchLiftsTheLockForAnAcceptedPayThatWasNotPlaced() async {
        for status in ["CANCELLED", "PAYMENT_ERROR", "SOMETHING_NEW"] {
            let fake = FakeSlant(reads: [.success(Self.order(status: "DRAFT")), .success(Self.order(status: status))],
                                 write: .success(Self.order(status: status)), writeNeedsToken: false)
            let result = await pay(fake)
            XCTAssertNotEqual(result.outcome, .placed, status)
            XCTAssertEqual(fake.log, batchPrefix + [.noteRateLimit, .get(id), .noteRateLimit, .unlock(id)], status)
            XCTAssertTrue(fake.lockedIDs.isEmpty, status)
        }
    }

    // MARK: Pay Several Drafts: the review

    static let sale: [String: Any] = ["metadata": ["source": "etsy", "sourceOrderId": "TEST-SALE-1"]]
    static let saleLine = "Etsy order TEST-SALE-1"

    static func draft(_ id: String, extra: [String: Any] = [:]) -> [String: Any] { order(id, status: "DRAFT", extra: extra) }

    func reviewed(_ ids: [String], loaded: [String: [String: Any]], failures: [String: String] = [:],
                  locked: Set<String> = [], placed: Set<String> = [], listed: [Record] = [], recentPlaced: [Record] = [],
                  hidden: Set<String> = [], checkNeeded: Bool = false, recent: RecentOrdersRead? = nil)
        -> (exclusions: [String: String?], uncheckedLeftOut: Int?, ids: [String]) {
        let result = batchPayReviewedDrafts(ids: ids, loaded: loaded, failures: failures, lockedIDs: locked, placedIDs: placed,
                                            listed: listed, recentPlaced: recentPlaced, hiddenDraftIDs: hidden,
                                            checkNeeded: checkNeeded, recent: recent)
        var exclusions: [String: String?] = [:]
        for draft in result.reviewed { exclusions[draft.id] = .some(draft.exclusion) }
        return (exclusions, result.uncheckedLeftOut, result.reviewed.map(\.id))
    }

    func testTheReviewAppliesEveryExclusionReason() {
        let taxed = Self.draft("taxed", extra: ["taxCost": 1.5])
        let ids = ["locked", "failed", "missing", "other", "submitted", "nostatus", "nototal", "taxed", "sent", "sentlocked", "ok"]
        let loaded: [String: [String: Any]] = [
            "locked": Self.draft("locked"),
            "other": Self.draft("someone-else"),
            "submitted": Self.order("submitted", status: "SUBMITTED"),
            "nostatus": ["publicId": "nostatus", "printingCost": 1, "deliveryCost": 1],
            "nototal": ["publicId": "nototal", "status": "DRAFT"],
            "taxed": taxed,
            "sent": Self.draft("sent"),
            "sentlocked": Self.draft("sentlocked"),
            "ok": Self.draft("ok")
        ]
        let result = reviewed(ids, loaded: loaded, failures: ["failed": "Slant didn’t reply."],
                              locked: ["locked", "sentlocked"], placed: ["sent", "sentlocked"])
        XCTAssertEqual(result.ids, ids, "In the chosen order")
        // The wording is pinned in BatchPayTests: here, that each draft carries its own reason (or none).
        var expected: [String: String?] = [:]
        for id in ids {
            expected[id] = ["sent", "sentlocked"].contains(id)
                ? "It was sent for payment in this batch."
                : batchPayExclusionReason(orderID: id, order: loaded[id], loadFailure: id == "failed" ? "Slant didn’t reply." : nil,
                                          locked: ["locked", "sentlocked"].contains(id))
        }
        XCTAssertEqual(ids.filter { expected[$0] == .some(nil) }, ["ok"], "Every other draft is left out for a reason")
        XCTAssertEqual(result.exclusions, expected)
        XCTAssertTrue(orderUnlistedCostBatchReason(orderUnlistedCosts(taxed))?.hasPrefix("Slant also lists taxCost for it") == true)
        XCTAssertNil(result.uncheckedLeftOut)
    }

    func testTheReviewLeavesOutMarketplaceDuplicates() {
        // Two drafts for one sale: only the first.
        let pair = reviewed(["first", "second"], loaded: ["first": Self.draft("first", extra: Self.sale),
                                                          "second": Self.draft("second", extra: Self.sale)])
        XCTAssertEqual(pair.exclusions, [
            "first": nil,
            "second": "Another draft in this review is also for \(Self.saleLine). Only the first is included; check them in Orders."])
        // A placed order for the sale among the loaded orders, or among the review's read of recent orders.
        let placedReason = "An order for \(Self.saleLine) was already placed, so this draft may be a duplicate. Check it in its own review."
        let placedOrder = Record(values: Self.order("placed-1", status: "SUBMITTED", extra: Self.sale))
        let listed = reviewed(["d"], loaded: ["d": Self.draft("d", extra: Self.sale)], listed: [placedOrder])
        XCTAssertEqual(listed.exclusions, ["d": placedReason])
        let recent = reviewed(["d"], loaded: ["d": Self.draft("d", extra: Self.sale)], recentPlaced: [placedOrder])
        XCTAssertEqual(recent.exclusions, ["d": placedReason])
        // A draft left out for another reason still holds its sale.
        let leftOut = reviewed(["locked", "other"], loaded: ["locked": Self.draft("locked", extra: Self.sale),
                                                             "other": Self.draft("other", extra: Self.sale)],
                               locked: ["locked"])
        XCTAssertEqual(leftOut.exclusions["other"], "Another draft in this review is also for \(Self.saleLine) and was left out, so this one may be a duplicate. Check them in Orders.")
        // A draft hidden in Orders holds its sale, unless it is under the lock (then it isn't hidden).
        let hiddenDraft = Record(values: Self.draft("hidden-1", extra: Self.sale))
        let hidden = reviewed(["d"], loaded: ["d": Self.draft("d", extra: Self.sale)], listed: [hiddenDraft], hidden: ["hidden-1"])
        XCTAssertEqual(hidden.exclusions, ["d": "A draft you hid in Orders is also for \(Self.saleLine), so this one may be a duplicate. Check them in Orders (Status › Show Hidden Drafts)."])
        let hiddenButLocked = reviewed(["d"], loaded: ["d": Self.draft("d", extra: Self.sale)], locked: ["hidden-1"],
                                       listed: [hiddenDraft], hidden: ["hidden-1"])
        XCTAssertEqual(hiddenButLocked.exclusions, ["d": nil])
    }

    func testTheReviewLeavesOutUncheckedMarketplaceOrders() {
        let loaded = ["sale": Self.draft("sale", extra: Self.sale), "plain": Self.draft("plain")]
        let unchecked = "Not paid in this batch: Plinth couldn’t check whether \(Self.saleLine) already has a placed order. Review again in a minute, or pay it in its own review after checking."
        // The read wasn't made.
        let notRead = reviewed(["sale", "plain"], loaded: loaded, checkNeeded: true, recent: nil)
        XCTAssertEqual(notRead.exclusions, ["sale": unchecked, "plain": nil])
        XCTAssertEqual(notRead.uncheckedLeftOut, 1)
        // The read failed.
        let failed = reviewed(["sale", "plain"], loaded: loaded, checkNeeded: true,
                              recent: RecentOrdersRead(stop: .failed("Slant didn’t reply."), accountKey: "test-key"))
        XCTAssertEqual(failed.exclusions["sale"], unchecked)
        XCTAssertEqual(failed.uncheckedLeftOut, 1)
        // The read finished: nothing left out for it.
        let finished = reviewed(["sale", "plain"], loaded: loaded, checkNeeded: true,
                                recent: RecentOrdersRead(pagesRead: 1, complete: true, accountKey: "test-key"))
        XCTAssertEqual(finished.exclusions, ["sale": nil, "plain": nil])
        XCTAssertEqual(finished.uncheckedLeftOut, 0)
        // Not needed: no count, nothing left out.
        let notNeeded = reviewed(["sale", "plain"], loaded: loaded, checkNeeded: false, recent: nil)
        XCTAssertEqual(notNeeded.exclusions, ["sale": nil, "plain": nil])
        XCTAssertNil(notNeeded.uncheckedLeftOut)
        // A draft already left out keeps its first reason and isn't counted.
        let locked = reviewed(["sale"], loaded: loaded, locked: ["sale"], checkNeeded: true, recent: nil)
        XCTAssertEqual(locked.exclusions["sale"], "Its last payment or cancel request didn’t confirm. Refresh it in its own review first.")
        XCTAssertEqual(locked.uncheckedLeftOut, 0)
    }

    // MARK: The live environment and its callers

    /// Tests can't create a `StudioStore`, so the fake above can't reach `live(_:)` or the code that calls these paths:
    /// these source checks (SourceCheck.swift) pin the live closures to the store's lock, client and the quit guard, and
    /// pin both money paths, Pay Several Drafts' loop and its quit-guard token to their places.
    func testTheLiveEnvironmentAndBothCallersStayWired() throws {
        let live = try SourceCheck.body(of: "@MainActor static func live(", in: SourceCheck.file("SlantOrderWrite.swift"))
        for (closure, protects) in [
            ("request: { method, path in try await store.client.request(method, path: path) },", "requests go through the store's client"),
            ("isOutcomeUnknown: { store.isOutcomeUnknown(orderID: $0) },", "the money paths see the shared lock"),
            ("markOutcomeUnknown: { store.markOutcomeUnknown(orderID: $0, action: $1, reviewedStatus: $2) },", "the money paths record the shared lock"),
            ("clearOutcomeUnknown: { store.clearOutcomeUnknown(orderID: $0) },", "the money paths lift the shared lock"),
            ("beginWrite: { SlantWritesInFlight.shared.begin($0) },", "quit asks first while a write waits"),
            ("endWrite: { SlantWritesInFlight.shared.end($0) },", "the quit guard's record ends with the write"),
            ("noteRateLimit: noteRateLimit,", "the caller's pacing hooks reach the money paths"),
            ("noteRateLimitError: noteRateLimitError)", "the caller's pacing hooks reach the money paths")] {
            assertSourceContains(live, closure, "live(_:) must keep this closure, so \(protects)")
        }

        // The single review pays or cancels only through `orderReviewWrite` and shows what `orderReviewSheetResult` says.
        let confirm = try SourceCheck.body(of: "func confirmAction() {", in: SourceCheck.file("OrdersView.swift"))
        assertSourceCount(confirm, "try await orderReviewWrite(orderID: orderID, method: method, shown: shown, env: .live(store), record: record)", 1,
                          "the single review sends its pay or cancel only through orderReviewWrite with the live environment")
        assertSourceContains(confirm, """
            record.onWriteAttempted = { attempted in
                writeAttempted = attempted
                if attempted { capturedRefundOnly = successRefundOnly }
            }
            """, "the sheet's writeAttempted and refund wording follow the lock")
        assertSourceOrder(confirm, "try await orderReviewWrite(", before: """
            let result = orderReviewSheetResult(record: record, ran: ran, failure: failure, isPay: isPay,
                                                refundOnly: capturedRefundOnly, shown: shown)
            """, "the sheet shows what orderReviewSheetResult decides from the record")
        assertSourceContains(confirm, """
            if result.awaitingBusy { awaitingBusy = true; return }
            if let order = result.shownOrder { fresh = order; loadState = .loaded }
            if let succeeded = result.succeeded {
                writeSucceeded = true
                if succeeded.payNotPlaced { payNotPlaced = true }
                successMessage = succeeded.successMessage
                actionMessage = result.actionMessage
                onCompleted(orderID, succeeded.order)
            } else {
                actionMessage = result.actionMessage
            }
            """, "the sheet applies orderReviewSheetResult as it is")
        for bypass in ["store.client.request(", "markOutcomeUnknown(", "clearOutcomeUnknown(", "SlantWritesInFlight"] {
            assertSourceLacks(confirm, bypass, "confirmAction must not call \(bypass) itself: the sequence is orderReviewWrite's")
        }

        // Pay Several Drafts holds `busy` and its quit-guard token from before the first pay until the last answer.
        let batch = try SourceCheck.file("BatchPay.swift")
        let start = try SourceCheck.body(of: "func startPaying(expectedCount: Int,", in: batch)
        assertSourceOrder(start, "store.busy = true", before: "Task {", "the batch holds busy before it pays")
        assertSourceOrder(start, "let write = SlantWritesInFlight.shared.begin(.payDrafts)", before: "Task {",
                          "quit asks first from before the batch's first pay")
        assertSourceOrder(start, "await self.executePayments(queue, store: store, onCompleted: onCompleted)",
                          before: "SlantWritesInFlight.shared.end(write)", "the quit guard's record lasts until the last pay has its answer")
        // Each order: the stop checks before it, `batchPayOne` with the live environment and the batch's pacing, then
        // the stop decision after it.
        let loop = try SourceCheck.body(of: "private func executePayments(", in: batch)
        let pay = """
            let result = await batchPayOne(draft.id, reviewed: reviewedOrder, env: .live(
                store, noteRateLimit: { self.noteRateLimit($0, store: store) }, noteRateLimitError: { self.noteRateLimitError($0) }))
            """
        assertSourceCount(loop, pay, 1, "each draft is paid only through batchPayOne with the live environment and the batch's pacing")
        assertSourceOrder(loop, "guard accountUnchanged(store) else {", before: pay, "the batch stops before paying when the account or platform changed")
        assertSourceOrder(loop, "guard store.unknownOutcomeOrderIDs.isEmpty else {", before: pay, "the batch never pays while any order's outcome is unknown")
        assertSourceOrder(loop, pay, before: """
            if case .stop(let reason) = batchPayNextStep(after: result.outcome) {
                stopMessage = reason
                break
            }
            """, "the batch stops after a refusal, a change or an unclear outcome")
        assertSourceContains(loop, "case .placed, .notPlaced, .unclear, .unrecognised: placedIDs.insert(draft.id)",
                             "an order Slant accepted is never paid again from this batch")
        // The review's inputs: the live lock, every loaded order (never platform-checked), the recent read, hidden drafts.
        assertSourceContains(batch, """
            let review = batchPayReviewedDrafts(
                ids: ids, loaded: loaded, failures: failures, lockedIDs: store.unknownOutcomeOrderIDs, placedIDs: placedIDs,
                listed: store.orders, recentPlaced: recent?.orders(forKey: reviewedKey) ?? [],
                hiddenDraftIDs: store.hiddenDraftIDSet, checkNeeded: checkNeeded, recent: recent)
            reviewed = review.reviewed
            if let unchecked = review.uncheckedLeftOut { uncheckedLeftOut = unchecked }
            """, "the batch review gets the live lock, every loaded order, the recent read and hidden drafts")
        for bypass in ["request(\"POST\"", "markOutcomeUnknown("] {
            assertSourceLacks(batch, bypass, "BatchPay.swift must not call \(bypass) itself: paying is batchPayOne's")
        }
    }
}
