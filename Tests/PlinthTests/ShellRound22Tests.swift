import XCTest
@testable import Plinth

// Round 22: the main window's Try Again, Save & Test's Keychain copy, quiet cancelled reads, the activity held while
// writes wait, the Slant session's settings, the single-action 429 copy and Settings' service names.
final class ShellRound22Tests: XCTestCase {
    // MARK: Try Again

    func testTryAgainTakesTheActionWhicheverWayTheAlertCloses() {
        // The alert's binding closing it (`errorAlertClosed`) never touches the slot, so the queued retry finds it.
        var slot = ErrorRetrySlot()
        slot.set(.refresh)
        XCTAssertEqual(slot.take(), .refresh)
        XCTAssertNil(slot.action)
    }

    func testOKForgetsTheAction() {
        var slot = ErrorRetrySlot()
        slot.set(.loadMoreOrders)
        slot.clear()
        XCTAssertNil(slot.take())
    }

    func testAnActionRunsAtMostOnce() {
        var slot = ErrorRetrySlot()
        slot.set(.searchOrders("desk"))
        XCTAssertEqual(slot.take(), .searchOrders("desk"))
        XCTAssertNil(slot.take(), "a second Try Again must not run it again")
    }

    func testANewFailureReplacesTheAction() {
        var slot = ErrorRetrySlot()
        slot.set(.connect("sl_old"))
        slot.set(.loadUsage)
        XCTAssertEqual(slot.take(), .loadUsage)
    }

    func testTheAlertBindingKeepsTheRetryAndOKClearsIt() throws {
        let source = try String(contentsOf: sourceURL("StudioView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("set: { if !$0 { store.errorAlertClosed() } }"),
                      "Closing the alert must keep Try Again's action for the queued retry")
        XCTAssertFalse(source.contains("set: { if !$0 { store.dismissError() } }"),
                       "dismissError() in the binding clears the action before Try Again's Task runs")
        XCTAssertTrue(source.contains("Button(\"OK\", role: .cancel) { store.dismissError() }"))
        XCTAssertTrue(source.contains("Button(\"Try Again\") { Task { await store.retryLast() } }"))
    }

    // MARK: Save & Test's Keychain save

    func testAKeychainSaveFailureSaysSaveNotRead() {
        XCTAssertLessThanOrEqual(slantKeySaveFailedMessage.count, 180, "friendlyAPIMessage would replace it")
        XCTAssertEqual(friendlyAPIMessage(StudioError(slantKeySaveFailedMessage)), slantKeySaveFailedMessage)
        XCTAssertFalse(slantKeySaveFailedMessage.lowercased().contains("read"))
        XCTAssertTrue(slantKeySaveFailedMessage.contains("Save & Test"))
        XCTAssertNotEqual(slantKeySaveFailedMessage, APIError.keychain(-25308).userMessage)
    }

    // MARK: Cancelled reads

    func testOnlyACancelledReadIsQuiet() {
        let cancelled = URLError(.cancelled)
        XCTAssertTrue(runFailureIsQuietCancellation(cancelled, taskCancelled: true, retryable: true))
        XCTAssertTrue(runFailureIsQuietCancellation(CancellationError(), taskCancelled: true, retryable: true))
        // `invalidate()` (a key change) cancels requests, not the task: still reported.
        XCTAssertFalse(runFailureIsQuietCancellation(cancelled, taskCancelled: false, retryable: true))
        // Writes (`retryable: false`) always keep their own outcome handling.
        XCTAssertFalse(runFailureIsQuietCancellation(cancelled, taskCancelled: true, retryable: false))
        XCTAssertFalse(runFailureIsQuietCancellation(CancellationError(), taskCancelled: true, retryable: false))
        // Other failures are failures, cancelled task or not.
        XCTAssertFalse(runFailureIsQuietCancellation(URLError(.timedOut), taskCancelled: true, retryable: true))
        XCTAssertFalse(runFailureIsQuietCancellation(URLError(.notConnectedToInternet), taskCancelled: true, retryable: true))
        XCTAssertFalse(runFailureIsQuietCancellation(StudioError("x"), taskCancelled: true, retryable: true))
        XCTAssertFalse(runFailureIsQuietCancellation(APIError.http(status: 500, body: "", retryAfter: nil, rateLimitReset: nil),
                                                     taskCancelled: true, retryable: true))
    }

    // MARK: Keeping the Mac awake while writes wait

    func testOneActivityFromTheFirstWriteToTheLast() {
        XCTAssertEqual(slantWritesActivityChange(holding: false, writesInFlight: true), .begin)
        XCTAssertEqual(slantWritesActivityChange(holding: true, writesInFlight: false), .end)
        XCTAssertEqual(slantWritesActivityChange(holding: true, writesInFlight: true), .none, "never a second activity")
        XCTAssertEqual(slantWritesActivityChange(holding: false, writesInFlight: false), .none)
    }

    // MARK: The Slant session

    func testTheSlantSessionKeepsNoCacheCookiesOrCredentials() {
        let passed = URLSessionConfiguration.ephemeral
        passed.protocolClasses = [StubURLProtocol22.self]
        let configuration = slantSessionConfiguration(passed)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(configuration.waitsForConnectivity)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 120)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 1800)
        XCTAssertTrue(configuration.protocolClasses?.first == StubURLProtocol22.self, "tests' transport is kept")
    }

    // MARK: 429 copy

    func testTheSingleActionWaitMatchesTheBatches() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // The batches' 60 s floor, whatever the headers say.
        for (retryAfter, reset) in [(nil, nil), ("3", nil), (nil, "1800000003000"), ("abc", "garbage"), (nil, "1799999990000")]
            as [(String?, String?)] {
            XCTAssertEqual(rateLimitUserMessage(retryAfter: retryAfter, rateLimitReset: reset, now: now),
                           "Too many requests. Try again in about 60 seconds.", "\(String(describing: retryAfter)) \(String(describing: reset))")
            let batchesWait = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: now)
            XCTAssertEqual(batchesWait.timeIntervalSince(now), comparisonRateLimitMinimumWait)
        }
        // Longer waits are kept: the later of Retry-After and the reset.
        XCTAssertEqual(rateLimitUserMessage(retryAfter: "75", rateLimitReset: "1800000070000", now: now),
                       "Too many requests. Try again in about 75 seconds.")
        XCTAssertEqual(rateLimitUserMessage(retryAfter: "20", rateLimitReset: "1800000300000", now: now),
                       "Too many requests. Try again in about 5 minutes.")
        // Never shorter than Slant's own Retry-After, even past the batches' one-hour cap.
        XCTAssertEqual(rateLimitUserMessage(retryAfter: "7200", rateLimitReset: nil, now: now),
                       "Too many requests. Try again in about 120 minutes.")
        XCTAssertEqual(rateLimitUserMessage(retryAfter: nil, rateLimitReset: "1800007200000", now: now),
                       "Too many requests. Try again in about 120 minutes.")
    }

    // MARK: Service status

    func testSlantsInternalServiceNamesSayWhatTheyDo() {
        XCTAssertEqual(healthServiceDisplayName("KRAKEN"), "Print farm (Kraken)")
        XCTAssertEqual(healthServiceDisplayName("TELEPORT"), "Order intake (Teleport)")
        XCTAssertEqual(healthServiceDisplayName("kraken"), "Print farm (Kraken)")
        // Others keep the generic sentence case.
        XCTAssertEqual(healthServiceDisplayName("ORDER-SERVICE"), "Order service")
        XCTAssertEqual(healthServiceDisplayName("KRAKEN-QUEUE"), "Kraken queue")
    }

    private func sourceURL(_ name: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth").appendingPathComponent(name)
    }
}

/// Only its type is used: `slantSessionConfiguration` must keep a passed `protocolClasses`.
private final class StubURLProtocol22: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { false }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {}
    override func stopLoading() {}
}
