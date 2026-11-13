import Foundation

// MARK: - The Slant pay and cancel paths' environment

/// What the two Slant money paths (the single pay/cancel review, `orderReviewWrite`, and Pay Several Drafts' one order,
/// `batchPayOne`) talk to: Slant's API, the session's shared unknown-outcome lock and the quit guard's record of writes
/// in flight. Tests pass a recording fake, so the order of the re-fetch, the checks, the lock, the write and the lift
/// is asserted on the real code; the app passes `live(_:)`.
///
/// Only the environment is shared: each path keeps its own sequence (the single review registers its own write with
/// `beginWrite`, while Pay Several Drafts holds one `.payDrafts` token for the whole batch and never calls it per order;
/// the single review notes no rate limits, while Pay Several Drafts paces itself through `noteRateLimit` and
/// `noteRateLimitError`).
struct SlantOrderWriteEnvironment {
    /// A Slant API request (`GET`, `POST` or `DELETE` on `/orders/{id}`); the live one evaluates `store.client` at each
    /// call, as the paths always did.
    var request: @MainActor (_ method: String, _ path: String) async throws -> APIResponse
    var isOutcomeUnknown: @MainActor (_ orderID: String) -> Bool
    var markOutcomeUnknown: @MainActor (_ orderID: String, _ action: OutcomeAction, _ reviewedStatus: String?) -> Void
    var clearOutcomeUnknown: @MainActor (_ orderID: String) -> Void
    /// Quit asks first until `endWrite` (`SlantWritesInFlight`).
    var beginWrite: @MainActor (_ kind: SlantWriteKind) -> UUID
    var endWrite: @MainActor (_ token: UUID) -> Void
    var noteRateLimit: @MainActor (_ response: APIResponse) -> Void
    var noteRateLimitError: @MainActor (_ error: Error) -> Void

    /// The app's environment: the store's client and lock, and `SlantWritesInFlight.shared`. Rate-limit noting is the
    /// caller's (Pay Several Drafts' runner passes its pacing hooks; the single review passes none, as before).
    @MainActor static func live(_ store: StudioStore,
                                noteRateLimit: @escaping @MainActor (_ response: APIResponse) -> Void = { _ in },
                                noteRateLimitError: @escaping @MainActor (_ error: Error) -> Void = { _ in }) -> Self {
        SlantOrderWriteEnvironment(
            request: { method, path in try await store.client.request(method, path: path) },
            isOutcomeUnknown: { store.isOutcomeUnknown(orderID: $0) },
            markOutcomeUnknown: { store.markOutcomeUnknown(orderID: $0, action: $1, reviewedStatus: $2) },
            clearOutcomeUnknown: { store.clearOutcomeUnknown(orderID: $0) },
            beginWrite: { SlantWritesInFlight.shared.begin($0) },
            endWrite: { SlantWritesInFlight.shared.end($0) },
            noteRateLimit: noteRateLimit,
            noteRateLimitError: noteRateLimitError)
    }
}

// MARK: - The single pay/cancel review

/// What one Pay or Cancel press in the single review (`OrderActionConfirmSheet.confirmAction`) did, read by the sheet
/// once `store.run` returns. Memory only.
@MainActor final class OrderReviewWriteRecord {
    var outcome: OrderConfirmRecheckResult = .proceed
    /// The order as re-fetched just before the write.
    var latestOrder: [String: Any]?
    /// The order to judge a 2xx by (`orderPayAcceptedOrder`).
    var completedOrder: [String: Any]?
    var didWrite = false
    /// The lock was recorded and the request handed to Slant (false again after a definite refusal).
    var attemptedWrite = false
    var payAcceptedUnconfirmed = false
    var payOutcome: BatchPayOutcome?
    var rejected = false
    var refusal: String?
    /// The write's own error when its outcome is unknown, for the cause shown in the sheet.
    var unknownWriteError: Error?
    /// Called with true straight after the lock is recorded, before the request is sent, and with false when Slant's
    /// definite refusal lifted it: the sheet's `writeAttempted` and refund wording follow at these exact points.
    var onWriteAttempted: (_ attempted: Bool) -> Void = { _ in }

    init() {}
}

/// The single review's Pay (`POST`) or Cancel (`DELETE`) of one order, run inside the sheet's `store.run`: re-fetch the
/// order, check it is this one and unchanged since `shown` (`orderConfirmRecheck`: pay needs DRAFT, cancel an unchanged,
/// cancellable status and unchanged shipping details), refuse while it is under the shared lock, record the lock (with
/// the action and Slant's status it was sent from) before sending, send once, then read the order again and decide.
/// The lock lifts only for a confirmed outcome or a definite refusal (`orderMutationErrorProvesNoEffect`); a 2xx Pay
/// whose order still shows DRAFT, or no readable status, keeps it. The write is registered with the quit guard from
/// just after the lock until the refresh and the decision are done. Throws the same errors, with the same text, that
/// the sheet's Activity line and note depend on. Never retries.
@MainActor
func orderReviewWrite(orderID: String, method: String, shown: [String: Any],
                      env: SlantOrderWriteEnvironment, record: OrderReviewWriteRecord) async throws {
    let isPay = method == "POST"
    let preview = try await env.request("GET", "/orders/\(encodedSegment(orderID))")
    let latest = mergeOrderDraftEnvelope(responseObject(preview))
    // Only this order may be paid or cancelled (as Pay Several Drafts checks).
    guard orderBelongs(latest, to: orderID) else { throw StudioError(orderReviewDifferentOrderMessage) }
    record.latestOrder = latest
    record.outcome = orderConfirmRecheck(method: method, shown: shown, latest: latest)
    if let abort = orderConfirmRecheckAbortError(record.outcome) { throw abort }
    if env.isOutcomeUnknown(orderID) { throw StudioError(unknownOutcomeBlockMessage) }
    // Shared lock before the write: a timeout or 5xx leaves the charge/cancel outcome unknown.
    env.markOutcomeUnknown(orderID, isPay ? .pay : .cancel, latest["status"] as? String)
    record.attemptedWrite = true
    record.onWriteAttempted(true)
    // Quit asks first until this write has its answer (PlinthApp.swift).
    let write = env.beginWrite(isPay ? .payment : .cancellation)
    defer { env.endWrite(write) }
    let mutateResponse: APIResponse
    do {
        mutateResponse = try await env.request(method, "/orders/\(encodedSegment(orderID))")
    } catch {
        if orderMutationErrorProvesNoEffect(error, method: method) {
            // Slant refused it (or it was never sent), so nothing is pending: lift the lock and return to the review.
            env.clearOutcomeUnknown(orderID)
            record.attemptedWrite = false
            record.onWriteAttempted(false)
            record.rejected = true
            record.refusal = orderConfirmRefusalMessage(isPay: isPay, error: error)
            throw error
        }
        record.unknownWriteError = error
        // Activity records the cause without the error's own "try again" advice: the lock stops a second send, and the
        // sheet's note comes from `unknownWriteError`.
        throw StudioError(slantUnclearReplyCause(error) + ", so the result is unknown.")
    }
    let mutateOrder = mergeOrderDraftEnvelope(responseObject(mutateResponse))
    var refreshedOrder: [String: Any]?
    if let refreshed = try? await env.request("GET", "/orders/\(encodedSegment(orderID))") {
        refreshedOrder = mergeOrderDraftEnvelope(responseObject(refreshed))
    }
    // Only an order that is this one counts: the refresh, else the reply.
    record.completedOrder = orderPayAcceptedOrder(replied: mutateOrder, refreshed: refreshedOrder, orderID: orderID)
    if isPay {
        // A 2xx to a pay whose order still shows DRAFT, or no readable status, isn't a confirmed charge: the lock stays
        // until a reload shows the outcome (as Pay Several Drafts does). Any other status is past DRAFT, a definite
        // outcome, so the lock lifts, but only a placed one is reported as placed.
        let result = batchPayOutcomeAfterSuccess(record.completedOrder)
        record.payOutcome = result
        if batchPayAcceptedOutcomeStaysLocked(record.completedOrder) {
            record.payAcceptedUnconfirmed = true
        } else {
            record.didWrite = true
            env.clearOutcomeUnknown(orderID)
        }
        // Activity records "Completed" only for a placed order.
        if result != .placed { throw StudioError(orderPayActivityDetail(result)) }
    } else {
        record.didWrite = true
        env.clearOutcomeUnknown(orderID)
    }
}

// MARK: - Pay Several Drafts: one order

/// One order of Pay Several Drafts, as the single review's `orderReviewWrite` pays one: re-fetch, check it is this
/// order and still the reviewed draft (`orderConfirmRecheck`), refuse while it is under the shared lock, lock, pay, then
/// lift the lock only for a definite outcome or a definite refusal. The batch's own `.payDrafts` write token covers it
/// (no per-order `beginWrite`); every reply and 429 goes to the batch's pacing through `noteRateLimit` and
/// `noteRateLimitError`. Never retries.
@MainActor
func batchPayOne(_ id: String, reviewed: [String: Any], env: SlantOrderWriteEnvironment)
    async -> (outcome: BatchPayOutcome, completed: [String: Any]?, error: Error?) {
    let path = "/orders/\(encodedSegment(id))"
    let latest: [String: Any]
    do {
        let response = try await env.request("GET", path)
        env.noteRateLimit(response)
        latest = mergeOrderDraftEnvelope(responseObject(response))
    } catch {
        env.noteRateLimitError(error)
        return (.notSent("Couldn’t refresh it before paying. \(friendlyAPIMessage(error))"), nil, error)
    }
    guard orderBelongs(latest, to: id) else { return (.changed("Slant returned a different order."), nil, nil) }
    if let abort = orderConfirmRecheckAbortError(orderConfirmRecheck(method: "POST", shown: reviewed, latest: latest)) {
        return (.changed(abort.message), nil, nil)
    }
    if env.isOutcomeUnknown(id) { return (.notSent(unknownOutcomeBlockMessage), nil, nil) }
    // Shared lock before the write: a timeout or 5xx leaves the charge outcome unknown.
    env.markOutcomeUnknown(id, .pay, latest["status"] as? String)
    let payResponse: APIResponse
    do {
        payResponse = try await env.request("POST", path)
    } catch {
        env.noteRateLimitError(error)
        let outcome = batchPayOutcome(forPayError: error)
        // Slant refused it, so nothing is pending: lift the lock. Any other failure keeps it.
        if case .refused = outcome { env.clearOutcomeUnknown(id) }
        return (outcome, nil, error)
    }
    env.noteRateLimit(payResponse)
    // The lock stays held while the order is re-read; it is decided once, from what Slant then shows.
    let paid = mergeOrderDraftEnvelope(responseObject(payResponse))
    var refreshedOrder: [String: Any]?
    if let refreshed = try? await env.request("GET", path) {
        env.noteRateLimit(refreshed)
        refreshedOrder = mergeOrderDraftEnvelope(responseObject(refreshed))
    }
    let completed = orderPayAcceptedOrder(replied: paid, refreshed: refreshedOrder, orderID: id)
    // The batch goes on only when the order Slant returned is actually placed. Accepted but still a draft (or no
    // readable status) means the charge may still happen: the lock stays until a reload shows the outcome. Any other
    // status is past DRAFT, a definite outcome, so the lock lifts (an unrecognised one still stops the batch).
    let outcome = batchPayOutcomeAfterSuccess(completed)
    if !batchPayAcceptedOutcomeStaysLocked(completed) {
        env.clearOutcomeUnknown(id)
    }
    return (outcome, completed, nil)
}

// MARK: - Pay Several Drafts: the review

/// The reviewed drafts, in the chosen order, with why each is left out (`batchPayExclusionReason`: the lock, a failed
/// load, another order, not a draft, no total, an unlisted cost; or already sent in this batch), then the marketplace
/// duplicates (`batchPayDuplicateExclusions`: a placed order for the sale among `listed` and `recentPlaced`, another
/// draft left out, a hidden draft, or an earlier draft in this review) and, when the placed-order check was needed and
/// `recent` didn't finish, every draft naming a marketplace order (`batchPayUncheckedExclusions`). Each step only leaves
/// more out. `uncheckedLeftOut` is nil when the check wasn't needed (the runner's count is then left as it is).
func batchPayReviewedDrafts(ids: [String], loaded: [String: [String: Any]], failures: [String: String],
                            lockedIDs: Set<String>, placedIDs: Set<String>, listed: [Record],
                            recentPlaced: [Record], hiddenDraftIDs: Set<String>,
                            checkNeeded: Bool, recent: RecentOrdersRead?)
    -> (reviewed: [BatchPayReviewedDraft], uncheckedLeftOut: Int?) {
    var reviewed = ids.map { id in
        let order = loaded[id]
        let reason = batchPayExclusionReason(orderID: id, order: order, loadFailure: failures[id],
                                             locked: lockedIDs.contains(id))
        let alreadyPaid = placedIDs.contains(id) ? "It was sent for payment in this batch." : nil
        return BatchPayReviewedDraft(id: id, order: order, exclusion: alreadyPaid ?? reason)
    }
    // Every reviewed draft holds its marketplace order, whatever else left it out (a lock, a failed load, an unlisted
    // cost), so a later draft for the same sale is never paid here while the earlier one waits to be paid on its own.
    let duplicates = batchPayDuplicateExclusions(
        reviewed.compactMap { draft in
            batchPayDuplicateCheckOrder(id: draft.id, fresh: draft.order, listed: listed).map { (id: draft.id, order: $0) }
        },
        placedKeys: batchPayPlacedKeys(loaded: listed, recent: recentPlaced),
        excludedIDs: Set(reviewed.filter { !$0.payable }.map(\.id)),
        hiddenKeys: batchPayHiddenDraftMarketplaceKeys(listed, hidden: hiddenDraftIDs,
                                                       keeping: lockedIDs, reviewedIDs: Set(reviewed.map(\.id))))
    reviewed = reviewed.map { draft in
        guard draft.payable, let reason = duplicates[draft.id] else { return draft }
        return BatchPayReviewedDraft(id: draft.id, order: draft.order, exclusion: reason)
    }
    // When the wider check couldn't be done, drafts for a marketplace order are left out too (never fewer).
    var uncheckedLeftOut: Int?
    if checkNeeded {
        let unchecked = batchPayUncheckedExclusions(
            reviewed.filter(\.payable).compactMap { draft in draft.order.map { (id: draft.id, order: $0) } }, recent: recent)
        reviewed = reviewed.map { draft in
            guard draft.payable, let reason = unchecked[draft.id] else { return draft }
            return BatchPayReviewedDraft(id: draft.id, order: draft.order, exclusion: reason)
        }
        uncheckedLeftOut = unchecked.count
    }
    return (reviewed, uncheckedLeftOut)
}
