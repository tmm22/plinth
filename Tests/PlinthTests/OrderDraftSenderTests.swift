import XCTest
@testable import Plinth

/// The composer's Create Draft (`OrderDraftSender`) through a recording fake of the store: the Create Anyway decision,
/// the one `POST /orders`, the quit guard's record and the session's unconfirmed-draft guard. Invented names only.
@MainActor
final class OrderDraftSenderTests: XCTestCase {
    /// Stands in for `StudioStore`: `run` skips while `busy` as the store's does, and `noteAttempt` applies the store's
    /// own bookkeeping (`unconfirmedDraftAttempts`, `unconfirmedDraftAttemptsOverflowed`) to the recorded attempts.
    @MainActor
    private final class Recorder {
        var attempts: [UnconfirmedDraftAttempt] = []
        var overflowed = false
        var busy = false
        var reply: Result<APIResponse, Error> = .success(APIResponse(data: Data(#"{"data":{"publicId":"SL-1001","status":"DRAFT"}}"#.utf8), statusCode: 201))
        var runTitles: [String] = []
        var posted: [[String: Any]] = []
        var events: [String] = []
        var openWrites: Set<UUID> = []
        var writesOpenDuringPost: [Int] = []
        var noted: [(attempt: DraftCreateAttempt, recipient: String, marker: String?, platformID: String)] = []
        var created: [[String: Any]] = []
        var finished: [String?] = []
        let clock = Date(timeIntervalSince1970: 1_800_000_000)

        var environment: OrderDraftSendEnvironment {
            OrderDraftSendEnvironment(
                unconfirmedAttempts: { self.attempts },
                attemptsOverflowed: { self.overflowed },
                run: { title, handlesError, operation in
                    self.runTitles.append(title)
                    guard !self.busy else { return false }
                    self.events.append("run")
                    do { try await operation() } catch { XCTAssertTrue(handlesError(error), "the composer explains every failure") }
                    return true
                },
                postOrder: { body in
                    self.events.append("post")
                    self.posted.append(body)
                    self.writesOpenDuringPost.append(self.openWrites.count)
                    return try self.reply.get()
                },
                beginWrite: {
                    let token = UUID()
                    self.openWrites.insert(token)
                    self.events.append("beginWrite")
                    return token
                },
                endWrite: { token in
                    self.openWrites.remove(token)
                    self.events.append("endWrite")
                },
                noteAttempt: { attempt, recipient, date, marker, platformID in
                    self.events.append("note")
                    XCTAssertEqual(date, self.clock, "the attempt's time is taken at the press")
                    self.overflowed = unconfirmedDraftAttemptsOverflowed(previous: self.attempts, overflowed: self.overflowed, attempt: attempt)
                    self.attempts = unconfirmedDraftAttempts(previous: self.attempts, attempt: attempt, recipient: recipient, date: date,
                                                             marker: marker, platformID: platformID)
                    self.noted.append((attempt, recipient, marker, platformID))
                },
                now: { self.clock })
        }

        /// One press, as the composer makes it; the send's task is awaited.
        @discardableResult
        func press(recipient: String, confirmed: Bool = false, marker: String? = "marker-1") async -> Bool {
            let body: [String: Any] = ["customer": ["details": ["address": ["name": recipient]]], "items": [] as [Any]]
            let started = OrderDraftSender.start(
                body: body, recipient: recipient, marker: marker, platformID: "platform-1",
                confirmedDespiteUnknownOutcome: confirmed, environment: environment,
                created: { order in self.events.append("created"); self.created.append(order) },
                finished: { failure in self.events.append("finished"); self.finished.append(failure) })
            switch started {
            case .needsCreateAnyway: return false
            case .started(let task): await task.value; return true
            }
        }
    }

    private let earlier = Date(timeIntervalSince1970: 1_799_999_000)

    private func attempt(_ name: String) -> UnconfirmedDraftAttempt {
        UnconfirmedDraftAttempt(recipient: name, date: earlier, marker: "m-\(name)", platformID: "platform-1")
    }

    // MARK: Create Anyway

    func testAnUnconfirmedAttemptForTheSameNameAsksFirstAndSendsNothing() async {
        let recorder = Recorder()
        recorder.attempts = [attempt("Ada Lovelace")]
        let sent = await recorder.press(recipient: "  ada\tLOVELACE ")
        XCTAssertFalse(sent, "Create Anyway is asked")
        XCTAssertEqual(recorder.runTitles, [], "decided before any run")
        XCTAssertEqual(recorder.posted.count, 0)
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.noted.count, 0)
        XCTAssertEqual(recorder.attempts, [attempt("Ada Lovelace")], "the guard is unchanged")
    }

    /// The question shows even while another request runs: it is decided outside `run`, which would skip the press.
    func testCreateAnywayIsAskedEvenWhileAnotherRequestRuns() async {
        let recorder = Recorder()
        recorder.busy = true
        recorder.attempts = [attempt("Ada Lovelace")]
        let sent = await recorder.press(recipient: "Ada Lovelace")
        XCTAssertFalse(sent)
        XCTAssertEqual(recorder.runTitles, [])
    }

    func testABlankNameOnEitherSideAsksFirst() async {
        let recorder = Recorder()
        recorder.attempts = [attempt("Ada Lovelace")]
        let blankDraft = await recorder.press(recipient: " \n ")
        XCTAssertFalse(blankDraft, "a draft without a name could be any attempt")
        recorder.attempts = [attempt("")]
        let blankAttempt = await recorder.press(recipient: "Grace Hopper")
        XCTAssertFalse(blankAttempt, "an attempt without a name could be this draft")
        XCTAssertEqual(recorder.posted.count, 0)
        XCTAssertEqual(recorder.runTitles, [])
    }

    func testAttemptsThatDroppedOffTheListAskFirst() async {
        let recorder = Recorder()
        recorder.overflowed = true
        let sent = await recorder.press(recipient: "Grace Hopper")
        XCTAssertFalse(sent, "the dropped attempts' names are unknown")
        XCTAssertEqual(recorder.posted.count, 0)
    }

    func testAnotherNamesAttemptDoesntAsk() async {
        let recorder = Recorder()
        recorder.attempts = [attempt("Ada Lovelace")]
        let sent = await recorder.press(recipient: "Grace Hopper")
        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.posted.count, 1)
    }

    func testCreateAnywaySendsOnceAndClearsOnlyThatNamesAttempts() async throws {
        let recorder = Recorder()
        recorder.attempts = [attempt("Ada Lovelace"), attempt("Grace Hopper"), attempt("ADA  lovelace")]
        let sent = await recorder.press(recipient: "Ada Lovelace", confirmed: true)
        XCTAssertTrue(sent)
        XCTAssertEqual(recorder.runTitles, ["Create order draft"])
        XCTAssertEqual(recorder.posted.count, 1, "one POST, never retried")
        XCTAssertEqual(recorder.events, ["run", "beginWrite", "post", "created", "endWrite", "note", "finished"])
        XCTAssertEqual(recorder.writesOpenDuringPost, [1], "Quit asks first while the create waits for Slant")
        XCTAssertTrue(recorder.openWrites.isEmpty)
        guard case .succeeded? = recorder.noted.first?.attempt else { return XCTFail("\(recorder.noted)") }
        XCTAssertEqual(recorder.noted.first?.recipient, "Ada Lovelace")
        XCTAssertEqual(recorder.attempts, [attempt("Grace Hopper")], "another customer's warning stays")
        XCTAssertEqual(try XCTUnwrap(recorder.created.first)["publicId"] as? String, "SL-1001")
        XCTAssertEqual(recorder.finished.count, 1)
        XCTAssertNil(recorder.finished[0])
    }

    // MARK: Outcomes

    func testAnUnclearOutcomeRecordsTheAttempt() async {
        let recorder = Recorder()
        let timeout = URLError(.timedOut)
        recorder.reply = .failure(timeout)
        await recorder.press(recipient: " Ada Lovelace ", marker: "marker-9")
        XCTAssertEqual(recorder.posted.count, 1, "never retried")
        XCTAssertEqual(recorder.events, ["run", "beginWrite", "post", "endWrite", "note", "finished"])
        XCTAssertEqual(recorder.attempts, [UnconfirmedDraftAttempt(recipient: "Ada Lovelace", date: recorder.clock, marker: "marker-9",
                                                                   platformID: "platform-1")])
        XCTAssertEqual(recorder.finished, [orderComposerCreateFailureMessage(timeout)])
        XCTAssertTrue(recorder.created.isEmpty)
        XCTAssertTrue(recorder.openWrites.isEmpty)
        // The next press for that name asks first.
        let again = await recorder.press(recipient: "Ada Lovelace")
        XCTAssertFalse(again)
        XCTAssertEqual(recorder.posted.count, 1)
    }

    /// A 2xx reply naming the order only by `name` doesn't confirm a draft (`orderCreatedID`): the outcome is unknown.
    func testAReplyWithoutAnOrderNumberIsUnclear() async {
        let recorder = Recorder()
        recorder.reply = .success(APIResponse(data: Data(#"{"data":{"name":"Order for Ada","status":"DRAFT"}}"#.utf8), statusCode: 201))
        await recorder.press(recipient: "Ada Lovelace")
        guard case .failed? = recorder.noted.first?.attempt else { return XCTFail("\(recorder.noted)") }
        XCTAssertEqual(recorder.attempts.map(\.recipient), ["Ada Lovelace"])
        XCTAssertTrue(recorder.created.isEmpty)
        XCTAssertEqual(recorder.finished, [orderComposerCreateFailureMessage(StudioError("Slant didn’t return an order number."))])
        XCTAssertTrue(recorder.finished[0]?.contains("may have been created") == true)
        // An `id` alone (text or a number) does confirm it, and clears that name's attempt.
        recorder.reply = .success(APIResponse(data: Data(#"{"data":{"id":4242}}"#.utf8), statusCode: 201))
        await recorder.press(recipient: "Ada Lovelace", confirmed: true)
        XCTAssertEqual(recorder.attempts, [])
        XCTAssertEqual(recorder.created.count, 1)
    }

    func testADefiniteRefusalLeavesTheGuardAsItWas() async {
        let recorder = Recorder()
        recorder.attempts = [attempt("Grace Hopper")]
        let refusal = APIError.http(status: 422, body: #"{"message":"Invalid postcode"}"#, retryAfter: nil, rateLimitReset: nil)
        recorder.reply = .failure(refusal)
        await recorder.press(recipient: "Ada Lovelace")
        XCTAssertEqual(recorder.posted.count, 1)
        XCTAssertEqual(recorder.attempts, [attempt("Grace Hopper")])
        XCTAssertEqual(recorder.finished, [orderComposerCreateFailureMessage(refusal)])
        XCTAssertTrue(recorder.finished[0]?.hasPrefix("Slant didn’t create the draft.") == true)
    }

    func testAServerErrorIsUnclearAndNeverRetried() async {
        let recorder = Recorder()
        recorder.reply = .failure(APIError.http(status: 502, body: "", retryAfter: nil, rateLimitReset: nil))
        await recorder.press(recipient: "Ada Lovelace")
        XCTAssertEqual(recorder.posted.count, 1)
        XCTAssertEqual(recorder.attempts.map(\.recipient), ["Ada Lovelace"])
    }

    /// While another request runs, `run` skips the press: nothing is sent, held or recorded, and the form isn't touched.
    func testNothingIsSentOrRecordedWhileAnotherRequestRuns() async {
        let recorder = Recorder()
        recorder.busy = true
        let started = await recorder.press(recipient: "Ada Lovelace")
        XCTAssertTrue(started)
        XCTAssertEqual(recorder.runTitles, ["Create order draft"])
        XCTAssertEqual(recorder.posted.count, 0)
        XCTAssertEqual(recorder.events, [])
        XCTAssertEqual(recorder.noted.count, 0)
        XCTAssertEqual(recorder.finished.count, 0)
    }

    /// The app's environment goes to the store's own run, client, quit guard and bookkeeping (not run here: tests
    /// never create a `StudioStore`).
    func testTheAppsEnvironmentUsesTheStore() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth/OrderDraftSender.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        for line in ["run: { title, handlesError, operation in await store.run(title, handlesError: handlesError, operation: operation) }",
                     #"postOrder: { body in try await store.client.request("POST", path: "/orders", body: body) }"#,
                     "beginWrite: { SlantWritesInFlight.shared.begin(.draft) }",
                     "endWrite: { SlantWritesInFlight.shared.end($0) }",
                     "unconfirmedAttempts: { store.unconfirmedDraftCreates }",
                     "attemptsOverflowed: { store.unconfirmedDraftCreatesOverflowed }",
                     "store.noteDraftCreateAttempt(attempt, recipient: recipient, date: date, marker: marker, platformID: platformID)"] {
            XCTAssertTrue(source.contains(line), line)
        }
        // The composer sends only through it, with the store's environment, and never builds its own POST.
        let orders = try String(contentsOf: url.deletingLastPathComponent().appendingPathComponent("OrdersView.swift"), encoding: .utf8)
        XCTAssertTrue(orders.contains("let started = OrderDraftSender.start("))
        XCTAssertTrue(orders.contains("confirmedDespiteUnknownOutcome: confirmedDespiteUnknownOutcome, environment: .store(store),"))
        XCTAssertTrue(orders.contains("if case .needsCreateAnyway = started { confirmCreateAnyway = true }"))
        XCTAssertFalse(orders.contains(#"request("POST", path: "/orders""#))
        XCTAssertFalse(orders.contains("SlantWritesInFlight.shared.begin(.draft)"))
    }
}
