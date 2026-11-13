import Foundation

// The composer's Create Draft once its body is built: the Create Anyway decision, then the one `POST /orders`.
// Everything that reaches Slant or the session's unconfirmed-draft guard goes through `OrderDraftSendEnvironment`, so
// tests drive the real decision and send with a recording fake. The Workbench's `POST /orders` has its own path.

/// What reaches Slant and the session's records for one Create Draft press. `store(_:)` is the app's.
@MainActor
struct OrderDraftSendEnvironment {
    /// The session's unconfirmed Create Draft attempts (`StudioStore.unconfirmedDraftCreates`), read at the press.
    var unconfirmedAttempts: () -> [UnconfirmedDraftAttempt]
    /// Earlier attempts dropped off that list (`StudioStore.unconfirmedDraftCreatesOverflowed`), read at the press.
    var attemptsOverflowed: () -> Bool
    /// `StudioStore.run` with this title and error handler: false when it didn't run (another request was running).
    var run: (_ title: String, _ handlesError: (Error) -> Bool, _ operation: () async throws -> Void) async -> Bool
    /// The one `POST /orders` with this body. Never retried.
    var postOrder: (_ body: [String: Any]) async throws -> APIResponse
    /// `SlantWritesInFlight`'s `.draft` record, held while the request waits for Slant, so Quit asks first.
    var beginWrite: () -> UUID
    var endWrite: (UUID) -> Void
    /// `StudioStore.noteDraftCreateAttempt`.
    var noteAttempt: (_ attempt: DraftCreateAttempt, _ recipient: String, _ date: Date, _ marker: String?, _ platformID: String) -> Void
    var now: () -> Date = { Date() }

    static func store(_ store: StudioStore) -> OrderDraftSendEnvironment {
        OrderDraftSendEnvironment(
            unconfirmedAttempts: { store.unconfirmedDraftCreates },
            attemptsOverflowed: { store.unconfirmedDraftCreatesOverflowed },
            run: { title, handlesError, operation in await store.run(title, handlesError: handlesError, operation: operation) },
            postOrder: { body in try await store.client.request("POST", path: "/orders", body: body) },
            beginWrite: { SlantWritesInFlight.shared.begin(.draft) },
            endWrite: { SlantWritesInFlight.shared.end($0) },
            noteAttempt: { attempt, recipient, date, marker, platformID in
                store.noteDraftCreateAttempt(attempt, recipient: recipient, date: date, marker: marker, platformID: platformID)
            })
    }
}

/// How a Create Draft press began.
enum OrderDraftSendStart {
    /// This draft could repeat an unconfirmed attempt (`draftCreateNeedsCreateAnyway`) and the seller hasn't chosen
    /// Create Anyway: ask first. Nothing was started or sent.
    case needsCreateAnyway
    /// The send began in this task. `run` skips it while another request runs, and then nothing is sent or recorded.
    case started(Task<Void, Never>)
}

@MainActor
enum OrderDraftSender {
    /// After an unconfirmed create, a press that could repeat it needs Create Anyway: judged at once by the name the
    /// body sends (`orderDraftBodyRecipient`), before any task and outside `run`, so the question shows even while
    /// another request runs. Otherwise the send starts (`send`). `recipient` is the name recorded with the attempt (the
    /// composer's delivery name); `marker` and `platformID` go with it for Look for Draft on Slant. `created` runs inside
    /// the run once Slant returned the new order with its number; `finished` after the attempt is recorded, with the
    /// composer's note for a failure. Never retried.
    static func start(body: [String: Any], recipient: String, marker: String?, platformID: String,
                      confirmedDespiteUnknownOutcome: Bool, environment: OrderDraftSendEnvironment,
                      created: @escaping ([String: Any]) -> Void,
                      finished: @escaping (_ failure: String?) -> Void) -> OrderDraftSendStart {
        // Create Anyway only when this draft could be one of the unconfirmed attempts: judged by the name the body
        // sends (`draftCreateNeedsCreateAnyway`). The notice above shows whatever the name.
        let needsCreateAnyway = draftCreateNeedsCreateAnyway(
            attempts: environment.unconfirmedAttempts(), overflowed: environment.attemptsOverflowed(),
            recipient: orderDraftBodyRecipient(body))
        if draftCreateNeedsConfirmation(outcomeUnknown: needsCreateAnyway, confirmed: confirmedDespiteUnknownOutcome) {
            return .needsCreateAnyway
        }
        let attemptDate = environment.now()
        return .started(Task {
            await send(body: body, recipient: recipient, date: attemptDate, marker: marker, platformID: platformID,
                       environment: environment, created: created, finished: finished)
        })
    }

    /// The one `POST /orders`, inside `run` while `SlantWritesInFlight` holds a `.draft` record. A reply counts as a
    /// creation only with the order's `publicId` or `id` (`orderCreatedID`; a name alone isn't one): otherwise the
    /// outcome is unknown. Once `run` ran, the attempt is recorded (`noteAttempt`: an unknown outcome adds it, a
    /// confirmed creation clears only the same name's attempts), then `finished` gets the failure note, if any.
    static func send(body: [String: Any], recipient: String, date: Date, marker: String?, platformID: String,
                     environment: OrderDraftSendEnvironment,
                     created: ([String: Any]) -> Void, finished: (_ failure: String?) -> Void) async {
        var attempt = DraftCreateAttempt.notSent
        var failure: String?
        // Any failure is explained in the form (a window alert would wait behind the sheet). An unknown outcome also
        // gets the unconfirmed-draft notice.
        let ran = await environment.run("Create order draft", { error in
            attempt = .failed(error)
            failure = orderComposerCreateFailureMessage(error)
            return true
        }) {
            // Quit asks first until this create has its answer (PlinthApp.swift).
            let write = environment.beginWrite()
            defer { environment.endWrite(write) }
            let response = try await environment.postOrder(body)
            let data = responseObject(response)
            let order = mergeOrderDraftEnvelope(data)
            // The POST went through, so a draft may exist: a reply without the order's `publicId` or `id` (a name
            // alone isn't one) leaves the outcome unknown.
            guard orderCreatedID(order) != nil else { throw StudioError("Slant didn’t return an order number.") }
            attempt = .succeeded
            created(order)
        }
        if ran {
            environment.noteAttempt(attempt, recipient, date, marker, platformID)
            finished(failure)
        }
    }
}
