import SwiftUI
import AppKit

// MARK: - Pay Several Drafts
//
// One review covering several drafts, then paying them strictly one at a time. Choosing sends nothing. The review
// re-fetches each chosen draft (read-only, one at a time). Paying starts only after the Pay button and a confirmation
// whose default is Don't Pay, and each payment repeats the single review's steps (`OrderActionConfirmSheet`):
// re-fetch, `orderConfirmRecheck` against the reviewed copy, the shared unknown-outcome lock set before the write, the
// same `POST /orders/{id}`, and the lock lifted only by a confirmed success or a definite refusal. The batch stops at
// the first order that isn't placed, never retries anything, and never starts while any order's pay/cancel outcome is
// unknown. Reviewed orders (with their addresses) stay in the sheet's memory; Activity records counts only.

/// The most drafts one batch reviews and pays.
let batchPayMaxDrafts = 20
/// Between payments (each is a GET, the POST and a GET): at most one order a second.
let batchPayMinimumSpacing: TimeInterval = 1.0
/// Between the review's reads.
let batchPayReviewSpacing: TimeInterval = 0.6

/// Opens the Pay Several Drafts sheet (store-driven, so `isPresentingSheet` counts it).
struct BatchPayRequest: Identifiable {
    let id = UUID()
    /// The orders list's IDs, in the order shown, when the sheet opened.
    let listIDs: [String]
}

// MARK: Choosing

func batchPayIsDraft(_ order: [String: Any]) -> Bool {
    ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DRAFT"
}

/// The drafts the sheet offers: the list as it was when the sheet opened, keeping only orders still loaded as drafts
/// (so one paid meanwhile drops out), each once.
func batchPayDraftRecords(listIDs: [String], orders: [Record]) -> [Record] {
    var byID: [String: Record] = [:]
    for record in orders where !record.id.isEmpty && byID[record.id] == nil { byID[record.id] = record }
    var seen = Set<String>()
    return listIDs.compactMap { id in
        guard !id.isEmpty, seen.insert(id).inserted, let record = byID[id], batchPayIsDraft(orderObject(record.values)) else {
            return nil
        }
        return record
    }
}

/// Ticks or unticks one draft. A new tick is ignored once `cap` drafts are ticked.
func batchPayToggled(_ selection: Set<String>, id: String, cap: Int = batchPayMaxDrafts) -> Set<String> {
    var next = selection
    if next.contains(id) {
        next.remove(id)
    } else if next.count < cap {
        next.insert(id)
    }
    return next
}

/// Select All: the first `cap` drafts in the list's order.
func batchPaySelectAll(_ ids: [String], cap: Int = batchPayMaxDrafts) -> Set<String> {
    Set(ids.prefix(cap))
}

/// The ticked drafts that are still offered, in the list's order, at most `cap`.
func batchPayOrderedSelection(_ selection: Set<String>, available ids: [String], cap: Int = batchPayMaxDrafts) -> [String] {
    Array(ids.filter { selection.contains($0) }.prefix(cap))
}

func batchPaySelectionCaption(selected: Int, available: Int, cap: Int = batchPayMaxDrafts) -> String {
    let base = "\(selected) of \(available) \(available == 1 ? "draft" : "drafts") selected"
    return available > cap ? base + " · up to \(cap) at a time" : base
}

func batchPayReviewButtonTitle(_ count: Int) -> String {
    switch count {
    case 0: return "Review Drafts"
    case 1: return "Review 1 Draft"
    default: return "Review \(count) Drafts"
    }
}

/// "2 × Bracket, 1 × Packing slip and 3 more": a draft's items in one line for the choose list.
func batchPayItemSummary(_ items: [[String: Any]], modelNames: [String: String] = [:], shown: Int = 2) -> String {
    guard !items.isEmpty else { return "No items listed" }
    let lines = items.prefix(max(1, shown)).map { orderItemLineText($0, modelNames: modelNames) }
    let rest = items.count - lines.count
    return lines.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
}

/// Shown instead of the batch when any order this session has a pay/cancel request whose result is unknown: that
/// order may have been charged, so nothing else is paid in a batch until its result is clear.
func batchPayLockNotice(lockedOrderNumbers: [String]) -> String? {
    let numbers = lockedOrderNumbers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }.sorted()
    guard !numbers.isEmpty else { return nil }
    let named: String
    switch numbers.count {
    case 1: named = "order \(numbers[0])"
    case 2, 3: named = "orders " + numbers.joined(separator: ", ")
    default: named = "orders " + numbers.prefix(3).joined(separator: ", ") + " and \(numbers.count - 3) more"
    }
    return "A payment or cancel request for \(named) didn’t confirm this session, so Studio won’t pay several drafts at once. Open that order’s review and press Reload Order; until its result is clear, pay drafts one at a time."
}

// MARK: Review

/// One chosen draft as reviewed: the copy loaded fresh from Slant, or why it can't be paid.
struct BatchPayReviewedDraft: Identifiable {
    let id: String
    let order: [String: Any]?
    let exclusion: String?
    var payable: Bool { exclusion == nil && order != nil }
}

/// Why a reviewed draft is left out of the payment, or nil when it can be paid. Only a loaded draft of this ID, not
/// locked, with a numeric total, is paid.
func batchPayExclusionReason(orderID: String, order: [String: Any]?, loadFailure: String?, locked: Bool) -> String? {
    if locked { return "Its last payment or cancel request didn’t confirm. Reload it in its own review first." }
    if let loadFailure { return "Couldn’t load it. \(loadFailure)" }
    guard let order else { return "It wasn’t loaded." }
    guard orderBelongs(order, to: orderID) else { return "Slant returned a different order." }
    guard batchPayIsDraft(order) else {
        let status = (order["status"] as? String) ?? ""
        return status.isEmpty ? "Slant didn’t return its status." : "It’s no longer a draft (now \(orderStatusTitle(status)))."
    }
    guard workbenchOrderHasNumericTotal(order), let total = orderTotalAmount(order) else {
        return "Slant didn’t return a total for it."
    }
    guard total >= 0 else { return "Its total isn’t a valid amount." }
    return nil
}

/// The sum of the orders' totals in USD, or nil when any total is missing.
func batchPayGrandTotal(_ orders: [[String: Any]]) -> Decimal? {
    var sum = Decimal(0)
    for order in orders {
        guard let total = orderTotalAmount(order) else { return nil }
        sum += total
    }
    return sum
}

func batchPayMoneyText(_ amount: Decimal) -> String { money(NSDecimalNumber(decimal: amount)) }

/// The final button: "Pay 3 Orders (Total $45.10 USD)".
func batchPayButtonTitle(count: Int, total: Decimal) -> String {
    "Pay \(count) \(count == 1 ? "Order" : "Orders") (Total \(batchPayMoneyText(total)) USD)"
}

/// The confirmation's title: "Pay 3 orders for $45.10 USD?".
func batchPayConfirmTitle(count: Int, total: Decimal) -> String {
    "Pay \(count) \(count == 1 ? "order" : "orders") for \(batchPayMoneyText(total)) USD?"
}

let batchPayConfirmMessage = "Each order is charged to the payment method on your Slant account and sent to production, one at a time. Studio checks each one again just before paying it, and stops at the first that changed or wasn’t placed."

/// Why the Pay button is unavailable, or nil.
func batchPayPayBlockedReason(payableCount: Int, totalKnown: Bool, busy: Bool, locked: Bool, accountChanged: Bool) -> String? {
    if locked { return "An order’s payment or cancel result is unknown." }
    if accountChanged { return "The account or platform changed. Review the drafts again." }
    if payableCount == 0 { return "None of these drafts can be paid." }
    if !totalKnown { return "Couldn’t add up the total." }
    if busy { return "Wait for the current task to finish." }
    return nil
}

/// Under the review: how many orders have an item flagged for a large quantity, so a flag scrolled out of view isn't missed.
func batchPayLargeQuantityNotice(_ orders: [[String: Any]]) -> String? {
    let flagged = orders.filter { (($0["items"] as? [[String: Any]]) ?? []).contains { orderItemHasLargeQuantity($0) } }.count
    guard flagged > 0 else { return nil }
    return flagged == 1 ? "1 order has an item with a large quantity. Check it below." : "\(flagged) orders have an item with a large quantity. Check them below."
}

// MARK: Paying

/// What happened to one order's payment.
enum BatchPayOutcome: Equatable {
    case placed
    /// The re-fetch before paying didn't match the review (status, totals or order); nothing was sent.
    case changed(String)
    /// Slant definitely refused the payment (`orderMutationErrorProvesNoEffect`); nothing was charged.
    case refused(String)
    /// The payment was sent and its result is unknown: it may have been charged. The lock stays.
    case unknown(String)
    /// Nothing was sent for this order (its re-fetch failed, or a check before sending stopped it).
    case notSent(String)
}

/// A failed payment request: a definite refusal, or an outcome that is unknown (timeout, transport error, 5xx, 408/409).
func batchPayOutcome(forPayError error: Error) -> BatchPayOutcome {
    if orderMutationErrorProvesNoEffect(error) { return .refused(orderConfirmRefusalMessage(isPay: true, error: error)) }
    return .unknown(friendlyAPIMessage(error))
}

enum BatchPayNextStep: Equatable {
    case next
    case stop(String)
}

/// Payment is stricter than Import Orders: only a placed order lets the batch go on; anything else stops it.
func batchPayNextStep(after outcome: BatchPayOutcome) -> BatchPayNextStep {
    switch outcome {
    case .placed:
        return .next
    case .changed:
        return .stop("Stopped: a draft changed after your review, so it wasn’t paid and nothing after it was. Review the drafts again.")
    case .refused:
        return .stop("Stopped: Slant refused a payment, so nothing after it was paid.")
    case .unknown:
        return .stop("Stopped: Slant didn’t confirm a payment, so that order may have been charged. Reload it before paying anything else.")
    case .notSent:
        return .stop("Stopped before paying a draft, so nothing after it was paid.")
    }
}

enum BatchPayRowState: Equatable {
    case queued
    case paying
    case placed
    case refused(String)
    case unknown
    case notPaid(String)
    /// An unknown outcome resolved by reloading the order: its status now.
    case reloaded(String)
}

func batchPayRowState(for outcome: BatchPayOutcome) -> BatchPayRowState {
    switch outcome {
    case .placed: return .placed
    case .changed(let reason): return .notPaid(reason + " Review it again.")
    case .refused(let reason): return .refused(reason)
    case .unknown: return .unknown
    case .notSent(let reason): return .notPaid(reason)
    }
}

func batchPayStateText(_ state: BatchPayRowState) -> String {
    switch state {
    case .queued: return "Waiting"
    case .paying: return "Paying…"
    case .placed: return "Placed"
    case .refused(let reason): return "Refused: \(reason)"
    case .unknown: return "Not confirmed: this order may have been charged. Reload it before paying anything else."
    case .notPaid(let reason): return "Not paid: \(reason)"
    case .reloaded(let status): return "Reloaded: now \(orderStatusTitle(status))."
    }
}

struct BatchPayTally: Equatable {
    var placed = 0
    var refused = 0
    var unknown = 0
    var notPaid = 0
}

func batchPayTally(_ states: [BatchPayRowState]) -> BatchPayTally {
    var tally = BatchPayTally()
    for state in states {
        switch state {
        case .placed: tally.placed += 1
        case .refused: tally.refused += 1
        case .unknown: tally.unknown += 1
        case .queued, .paying, .notPaid: tally.notPaid += 1
        case .reloaded: break
        }
    }
    return tally
}

/// "2 placed · 1 refused · 1 not confirmed · 3 not paid": counts only (also Activity's detail).
func batchPaySummary(_ tally: BatchPayTally) -> String {
    var parts = ["\(tally.placed) placed"]
    if tally.refused > 0 { parts.append("\(tally.refused) refused") }
    if tally.unknown > 0 { parts.append("\(tally.unknown) not confirmed") }
    if tally.notPaid > 0 { parts.append("\(tally.notPaid) not paid") }
    return parts.joined(separator: " · ")
}

// MARK: - Runner

enum BatchPayPhase: Equatable { case choose, loading, review, paying, done }

/// Loads the review and pays strictly one order at a time. Stopping (or closing the sheet) takes effect before the
/// next request; a payment already sent always finishes so its outcome is recorded.
@MainActor final class BatchPayRunner: ObservableObject {
    @Published private(set) var phase: BatchPayPhase = .choose
    @Published private(set) var reviewed: [BatchPayReviewedDraft] = []
    @Published private(set) var states: [String: BatchPayRowState] = [:]
    /// True while one order's requests are being sent: the sheet can't be closed then.
    @Published private(set) var inFlight = false
    @Published private(set) var message: String?
    @Published private(set) var loadedCount = 0
    @Published private(set) var loadTotal = 0
    @Published private(set) var waitingUntil: Date?
    @Published private(set) var reloadingID: String?
    @Published private(set) var reloadMessages: [String: String] = [:]
    @Published private(set) var stopRequested = false
    /// Orders this sheet placed (or found placed on reload). They're never offered or paid again from this sheet, even
    /// if the list still shows them as drafts because their refresh failed.
    @Published private(set) var placedIDs: Set<String> = []
    /// The account and platform the review was loaded with; paying needs both unchanged.
    private var reviewedKey = ""
    private var reviewedPlatform = ""
    private var observedRateLimit: RateLimitInfo?
    private var rateLimitedUntil: Date?

    var payable: [BatchPayReviewedDraft] { reviewed.filter(\.payable) }
    var excluded: [BatchPayReviewedDraft] { reviewed.filter { !$0.payable } }
    var payableTotal: Decimal? { batchPayGrandTotal(payable.compactMap(\.order)) }

    func accountUnchanged(_ store: StudioStore) -> Bool {
        store.hasKey && store.apiKey == reviewedKey && store.platformID == reviewedPlatform
    }

    func requestStop() {
        if phase == .loading || phase == .paying { stopRequested = true }
    }

    /// Back to choosing; the reviewed copies are dropped.
    func backToChoose() {
        guard phase == .review || phase == .done else { return }
        reviewed = []
        states = [:]
        reloadMessages = [:]
        message = nil
        phase = .choose
    }

    // MARK: Review

    /// Re-fetches each chosen draft (`GET /orders/{id}`), one at a time, in one `store.run`.
    func loadReview(_ ids: [String], store: StudioStore) {
        guard phase == .choose, !ids.isEmpty, ids.count <= batchPayMaxDrafts else { return }
        guard !store.busy else { message = "Wait for the current task to finish, then try again."; return }
        guard store.unknownOutcomeOrderIDs.isEmpty else {
            message = "An order’s payment or cancel result is unknown, so nothing is loaded for a batch."
            return
        }
        stopRequested = false
        message = nil
        reviewed = []
        states = [:]
        reloadMessages = [:]
        loadedCount = 0
        loadTotal = ids.count
        reviewedKey = store.apiKey
        reviewedPlatform = store.platformID
        observedRateLimit = store.rateLimit
        phase = .loading
        Task { await self.executeReview(ids, store: store) }
    }

    private func executeReview(_ ids: [String], store: StudioStore) async {
        var loaded: [String: [String: Any]] = [:]
        var failures: [String: String] = [:]
        var cancelled = false
        let ran = await store.run("Load drafts for payment review", handlesError: { _ in true }) {
            var lastStart: Date?
            loadLoop: for (index, id) in ids.enumerated() {
                if stopRequested { cancelled = true; return }
                switch orderImportPacing(lastRequestStart: lastStart, rateLimit: observedRateLimit, rateLimitedUntil: rateLimitedUntil,
                                         now: Date(), minimumSpacing: batchPayReviewSpacing) {
                case .stop(let reason):
                    for rest in ids[index...] { failures[rest] = reason }
                    break loadLoop
                case .wait(let seconds):
                    if seconds > 0 {
                        waitingUntil = Date().addingTimeInterval(seconds)
                        await sleepUnlessStopped(seconds)
                        waitingUntil = nil
                    }
                }
                if stopRequested { cancelled = true; return }
                guard accountUnchanged(store) else {
                    for rest in ids[index...] { failures[rest] = "The account or platform changed." }
                    break loadLoop
                }
                lastStart = Date()
                do {
                    let response = try await store.client.request("GET", path: "/orders/\(encodedSegment(id))")
                    noteRateLimit(response, store: store)
                    loaded[id] = mergeOrderDraftEnvelope(responseObject(response))
                } catch {
                    noteRateLimitError(error)
                    failures[id] = friendlyAPIMessage(error)
                    if case APIError.http(let status, _, _, _)? = error as? APIError, status == 401 || status == 403 {
                        for rest in ids[(index + 1)...] { failures[rest] = friendlyAPIMessage(error) }
                        break loadLoop
                    }
                }
                loadedCount = index + 1
            }
        }
        waitingUntil = nil
        guard ran else {
            phase = .choose
            message = "Wait for the current task to finish, then try again."
            return
        }
        if cancelled || stopRequested {
            phase = .choose
            message = "Stopped loading. Nothing was paid."
            return
        }
        reviewed = ids.map { id in
            let order = loaded[id]
            let reason = batchPayExclusionReason(orderID: id, order: order, loadFailure: failures[id],
                                                 locked: store.isOutcomeUnknown(orderID: id))
            let alreadyPaid = placedIDs.contains(id) ? "It was paid in this batch." : nil
            return BatchPayReviewedDraft(id: id, order: order, exclusion: alreadyPaid ?? reason)
        }
        phase = .review
    }

    // MARK: Paying

    /// Starts paying the reviewed drafts in order. `expectedCount` and `expectedTotal` are what the confirmation showed;
    /// if the payable set no longer matches them, nothing is sent.
    func startPaying(expectedCount: Int, expectedTotal: Decimal, store: StudioStore,
                     onCompleted: @escaping (_ orderID: String, _ order: [String: Any]) -> Void) {
        guard phase == .review else { return }
        let queue = payable
        guard !queue.isEmpty, queue.count == expectedCount, payableTotal == expectedTotal else {
            message = "The drafts to pay changed. Review them again."
            return
        }
        if let reason = batchPayPayBlockedReason(payableCount: queue.count, totalKnown: payableTotal != nil, busy: store.busy,
                                                 locked: !store.unknownOutcomeOrderIDs.isEmpty, accountChanged: !accountUnchanged(store)) {
            message = reason
            return
        }
        stopRequested = false
        message = nil
        for draft in queue { states[draft.id] = .queued }
        phase = .paying
        // The batch holds the app-wide busy flag, so no other Slant task runs between its payments.
        store.busy = true
        store.progress = "Paying orders"
        Task { await self.executePayments(queue, store: store, onCompleted: onCompleted) }
    }

    private func executePayments(_ queue: [BatchPayReviewedDraft], store: StudioStore,
                                 onCompleted: (_ orderID: String, _ order: [String: Any]) -> Void) async {
        var lastStart: Date?
        var stopMessage: String?
        var stopDetail: String?
        payLoop: for draft in queue {
            guard let reviewedOrder = draft.order else { continue }
            if stopRequested { stopMessage = "Stopped. The rest weren’t paid."; break }
            switch orderImportPacing(lastRequestStart: lastStart, rateLimit: observedRateLimit, rateLimitedUntil: rateLimitedUntil,
                                     now: Date(), minimumSpacing: batchPayMinimumSpacing) {
            case .stop(let reason):
                stopMessage = "\(reason) The rest weren’t paid."
                break payLoop
            case .wait(let seconds):
                if seconds > 0 {
                    waitingUntil = Date().addingTimeInterval(seconds)
                    await sleepUnlessStopped(seconds)
                    waitingUntil = nil
                }
            }
            if stopRequested { stopMessage = "Stopped. The rest weren’t paid."; break }
            guard accountUnchanged(store) else {
                stopMessage = "Stopped because the account or platform changed. The rest weren’t paid."
                break
            }
            guard store.unknownOutcomeOrderIDs.isEmpty else {
                stopMessage = "Stopped because an order’s payment or cancel result is unknown. The rest weren’t paid."
                break
            }
            states[draft.id] = .paying
            inFlight = true
            lastStart = Date()
            let result = await payOne(draft.id, reviewed: reviewedOrder, store: store)
            inFlight = false
            states[draft.id] = batchPayRowState(for: result.outcome)
            if result.outcome == .placed { placedIDs.insert(draft.id) }
            if let completed = result.completed { onCompleted(draft.id, completed) }
            if let error = result.error { stopDetail = activityDetail(for: error) }
            if case .stop(let reason) = batchPayNextStep(after: result.outcome) {
                stopMessage = reason
                break
            }
        }
        for draft in queue where states[draft.id] == .queued {
            states[draft.id] = .notPaid("Not sent, because the batch stopped first.")
        }
        waitingUntil = nil
        inFlight = false
        store.busy = false
        store.progress = ""
        let tally = batchPayTally(queue.compactMap { states[$0.id] })
        let summary = batchPaySummary(tally)
        message = stopMessage.map { "\($0) \(summary)." } ?? "Done: \(summary)."
        // Counts only, and the stopping error's status: never names, addresses or order IDs.
        let detail = stopDetail.map { "\(summary) · \($0)" } ?? summary
        store.activities.insert(Activity(title: "Pay drafts", detail: detail,
                                         success: tally.placed == queue.count), at: 0)
        store.activities = Array(store.activities.prefix(100))
        phase = .done
    }

    /// One order, exactly as the single review's `confirmAction`: re-fetch, recheck against the reviewed copy, lock,
    /// pay, then lift the lock only on success or a definite refusal.
    private func payOne(_ id: String, reviewed: [String: Any], store: StudioStore)
        async -> (outcome: BatchPayOutcome, completed: [String: Any]?, error: Error?) {
        let path = "/orders/\(encodedSegment(id))"
        let latest: [String: Any]
        do {
            let response = try await store.client.request("GET", path: path)
            noteRateLimit(response, store: store)
            latest = mergeOrderDraftEnvelope(responseObject(response))
        } catch {
            noteRateLimitError(error)
            return (.notSent("Couldn’t reload it before paying. \(friendlyAPIMessage(error))"), nil, error)
        }
        guard orderBelongs(latest, to: id) else { return (.changed("Slant returned a different order."), nil, nil) }
        if let abort = orderConfirmRecheckAbortError(orderConfirmRecheck(method: "POST", shown: reviewed, latest: latest)) {
            return (.changed(abort.message), nil, nil)
        }
        if store.isOutcomeUnknown(orderID: id) { return (.notSent(unknownOutcomeBlockMessage), nil, nil) }
        // Shared lock before the write: a timeout or 5xx leaves the charge outcome unknown.
        store.markOutcomeUnknown(orderID: id, action: .pay, reviewedStatus: latest["status"] as? String)
        let payResponse: APIResponse
        do {
            payResponse = try await store.client.request("POST", path: path)
        } catch {
            noteRateLimitError(error)
            let outcome = batchPayOutcome(forPayError: error)
            // Slant refused it, so nothing is pending: lift the lock. Any other failure keeps it.
            if case .refused = outcome { store.clearOutcomeUnknown(orderID: id) }
            return (outcome, nil, error)
        }
        noteRateLimit(payResponse, store: store)
        store.clearOutcomeUnknown(orderID: id)
        let paid = mergeOrderDraftEnvelope(responseObject(payResponse))
        var completed: [String: Any]? = orderBelongs(paid, to: id) ? paid : nil
        if let refreshed = try? await store.client.request("GET", path: path) {
            noteRateLimit(refreshed, store: store)
            let order = mergeOrderDraftEnvelope(responseObject(refreshed))
            if orderBelongs(order, to: id) { completed = order }
        }
        return (.placed, completed, nil)
    }

    // MARK: After the run

    /// Reloads an order whose payment wasn't confirmed (read-only). The lock lifts only when the reload shows the
    /// payment's outcome (`unknownOutcomeResolvedByReload`), as the single review's Reload Order does.
    func reloadUnknown(_ id: String, store: StudioStore, onCompleted: @escaping (_ orderID: String, _ order: [String: Any]) -> Void) {
        guard phase == .done, reloadingID == nil, !store.busy, store.isOutcomeUnknown(orderID: id) else { return }
        reloadingID = id
        reloadMessages[id] = nil
        Task {
            var loaded: [String: Any]?
            var failure: String?
            let ran = await store.run("Load order for review", handlesError: { error in
                failure = friendlyAPIMessage(error)
                return true
            }) {
                let response = try await store.client.request("GET", path: "/orders/\(encodedSegment(id))")
                let order = mergeOrderDraftEnvelope(responseObject(response))
                guard orderBelongs(order, to: id) else { throw StudioError("Slant returned a different order.") }
                loaded = order
                if store.isOutcomeUnknown(orderID: id),
                   unknownOutcomeResolvedByReload(context: store.unknownOutcomeContext(orderID: id),
                                                  reloadedStatus: (order["status"] as? String) ?? "") {
                    store.clearOutcomeUnknown(orderID: id)
                }
            }
            reloadingID = nil
            guard ran else { reloadMessages[id] = "Wait for the current task to finish, then reload it."; return }
            if let failure { reloadMessages[id] = "Couldn’t reload it. \(failure)"; return }
            guard let order = loaded else { return }
            onCompleted(id, order)
            if store.isOutcomeUnknown(orderID: id) {
                reloadMessages[id] = batchPayIsDraft(order)
                    ? "It’s still a draft. Check it in your Slant dashboard before paying it again."
                    : "Its result still isn’t clear. Check it in your Slant dashboard before paying it again."
            } else {
                if !batchPayIsDraft(order) { placedIDs.insert(id) }
                states[id] = .reloaded((order["status"] as? String) ?? "")
            }
        }
    }

    // MARK: Helpers

    private func noteRateLimit(_ response: APIResponse, store: StudioStore) {
        guard response.rateLimit.hasValues else { return }
        observedRateLimit = response.rateLimit
        store.rateLimit = response.rateLimit
    }

    private func noteRateLimitError(_ error: Error) {
        if case APIError.http(429, _, let retryAfter, let reset)? = error as? APIError {
            rateLimitedUntil = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: Date())
        }
    }

    private func sleepUnlessStopped(_ seconds: TimeInterval) async {
        let end = Date().addingTimeInterval(seconds)
        while !stopRequested {
            let remaining = end.timeIntervalSinceNow
            if remaining <= 0 { break }
            try? await Task.sleep(nanoseconds: UInt64(min(0.25, remaining) * 1_000_000_000))
        }
    }
}

// MARK: - Store hooks

extension StudioStore {
    /// Pay Several Drafts… in the Orders toolbar's More menu: only opens the sheet, and only when nothing modal is
    /// shown, no request is running and the list has a draft. Nothing is sent until the sheet's Review button.
    func openBatchPay(listIDs: [String]) {
        guard !menuCommandsBlockedByModalUI, !busy, batchPayRequest == nil,
              !batchPayDraftRecords(listIDs: listIDs, orders: orders).isEmpty else { return }
        batchPayRequest = BatchPayRequest(listIDs: listIDs)
    }
}

// MARK: - Sheet

struct BatchPaySheet: View {
    @EnvironmentObject var store: StudioStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var runner = BatchPayRunner()
    let request: BatchPayRequest
    let onCompleted: (_ orderID: String, _ order: [String: Any]) -> Void
    /// Ticked drafts: order IDs, for this sheet only.
    @State private var selection: Set<String> = []
    @State private var confirmPay = false
    /// The count and total the confirmation showed; paying starts only if the reviewed set still matches them.
    @State private var confirmedFigures: (count: Int, total: Decimal)?

    private var drafts: [Record] {
        batchPayDraftRecords(listIDs: request.listIDs, orders: store.orders).filter { !runner.placedIDs.contains($0.id) }
    }
    private var draftIDs: [String] { drafts.map(\.id) }
    private var chosen: [String] { batchPayOrderedSelection(selection, available: draftIDs) }
    private var modelNames: [String: String] { orderItemModelNames(localModels: store.localModels, files: store.files) }
    private var lockNotice: String? {
        let numbers = store.unknownOutcomeOrderIDs.map { id -> String in
            guard let record = store.orders.first(where: { $0.id == id }) else { return id }
            let number = orderNumber(orderObject(record.values))
            return number.isEmpty ? id : number
        }
        return batchPayLockNotice(lockedOrderNumbers: numbers)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(heading).font(.title2.weight(.bold))
                Text(subheading).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if let lockNotice, runner.phase != .paying {
                Label(lockNotice, systemImage: "lock.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            switch runner.phase {
            case .choose: chooseList
            case .loading: loadingView
            case .review, .paying, .done: reviewList
            }
            if let message = runner.message {
                Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(22)
        .frame(width: 660, height: 640)
        // A payment request in flight always finishes in view, so its outcome is seen; between orders, closing stops.
        .interactiveDismissDisabled(runner.inFlight)
        .confirmationDialog(confirmTitle, isPresented: $confirmPay, titleVisibility: .visible) {
            if let figures = confirmedFigures {
                Button("Pay \(figures.count) \(figures.count == 1 ? "Order" : "Orders")") {
                    runner.startPaying(expectedCount: figures.count, expectedTotal: figures.total, store: store, onCompleted: onCompleted)
                }
            }
            // Return chooses Don't Pay, so pressing it twice can't start a payment.
            Button("Don’t Pay", role: .cancel) {}
                .keyboardShortcut(.defaultAction)
        } message: {
            Text(batchPayConfirmMessage)
        }
        .onDisappear {
            // Closing stops the batch before its next order and drops the reviewed copies.
            runner.requestStop()
            selection = []
        }
    }

    private var heading: String {
        switch runner.phase {
        case .choose, .loading: return "Pay Several Drafts"
        case .review: return "Review drafts to pay"
        case .paying: return "Paying orders"
        case .done: return "Payment results"
        }
    }

    private var subheading: String {
        switch runner.phase {
        case .choose, .loading:
            return "Choose up to \(batchPayMaxDrafts) drafts. Studio loads each one fresh from Slant for you to review; nothing is paid until you confirm the total."
        case .review, .paying, .done:
            return "Paying charges the payment method associated with your Slant account and sends each order to production, one at a time. Costs below were loaded fresh from Slant."
        }
    }

    private var confirmTitle: String {
        guard let figures = confirmedFigures else { return "Pay these orders?" }
        return batchPayConfirmTitle(count: figures.count, total: figures.total)
    }

    // MARK: Choose

    @ViewBuilder
    private var chooseList: some View {
        if drafts.isEmpty {
            ContentUnavailableView {
                Label("No drafts in the list", systemImage: "doc.text")
            } description: {
                Text("Drafts shown in the orders list appear here. Show drafts with the toolbar’s Status menu.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack {
                Text(batchPaySelectionCaption(selected: chosen.count, available: drafts.count)).font(.callout)
                Spacer()
                Button("Select All") { selection = batchPaySelectAll(draftIDs) }
                Button("Select None") { selection = [] }.disabled(chosen.isEmpty)
            }
            List(drafts, id: \.id) { record in
                draftRow(record)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .frame(maxHeight: .infinity)
        }
    }

    private func draftRow(_ record: Record) -> some View {
        let order = orderObject(record.values)
        let row = OrderTableRow(record: record)
        let id = record.id
        let ticked = chosen.contains(id)
        let details = [row.number, row.marketplaceReference ?? ""].filter { !$0.isEmpty }.joined(separator: " · ")
        return Toggle(isOn: Binding(
            get: { ticked },
            set: { _ in selection = batchPayToggled(selection.intersection(draftIDs), id: id) }
        )) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(row.recipient).fontWeight(.medium).lineLimit(1)
                    Spacer()
                    Text(row.total == "—" ? "—" : "\(row.total) USD").monospacedDigit()
                }
                Text(batchPayItemSummary((order["items"] as? [[String: Any]]) ?? [], modelNames: modelNames))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                if !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(!ticked && chosen.count >= batchPayMaxDrafts)
        .padding(.vertical, 2)
    }

    // MARK: Loading

    private var loadingView: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let until = runner.waitingUntil, until.timeIntervalSinceNow > 2 {
                ProgressView("Waiting for Slant’s rate limit… \(runner.loadedCount) of \(runner.loadTotal) loaded.")
            } else {
                ProgressView("Loading drafts from Slant… \(runner.loadedCount) of \(runner.loadTotal) loaded.")
            }
            Text("Nothing is paid while drafts load.").font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Review and results

    private var reviewList: some View {
        let payable = runner.payable
        let excluded = runner.excluded
        let filaments = store.filaments
        let names = modelNames
        return VStack(alignment: .leading, spacing: 10) {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if let notice = batchPayLargeQuantityNotice(payable.compactMap(\.order)) {
                        Label(notice, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.callout)
                    }
                    ForEach(payable) { draft in
                        if let order = draft.order {
                            BatchPayDraftCard(order: order, state: runner.states[draft.id], modelNames: names, filaments: filaments) {
                                if runner.phase == .done, store.isOutcomeUnknown(orderID: draft.id) {
                                    HStack(spacing: 8) {
                                        Button("Reload Order") { runner.reloadUnknown(draft.id, store: store, onCompleted: onCompleted) }
                                            .disabled(store.busy || runner.reloadingID != nil)
                                        if runner.reloadingID == draft.id { ProgressView().controlSize(.small) }
                                    }
                                }
                                if let note = runner.reloadMessages[draft.id] {
                                    Text(note).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                        }
                    }
                    if !excluded.isEmpty {
                        Text(excluded.count == 1 ? "Not included (1)" : "Not included (\(excluded.count))").font(.headline).padding(.top, 4)
                        ForEach(excluded) { draft in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(excludedTitle(draft)).lineLimit(1).truncationMode(.middle)
                                Text(draft.exclusion ?? "").font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                .padding(.trailing, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.visible)
            .frame(maxHeight: .infinity)
            Divider()
            if let total = runner.payableTotal, !payable.isEmpty {
                LabeledContent(payable.count == 1 ? "Total for 1 order" : "Total for \(payable.count) orders") {
                    Text("\(batchPayMoneyText(total)) USD").monospacedDigit().fontWeight(.semibold)
                }
                .labeledContentStyle(.receipt)
                .font(.callout)
            }
            if runner.phase == .paying {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    if let until = runner.waitingUntil, until.timeIntervalSinceNow > 2 {
                        Text("Waiting for Slant’s rate limit before the next order…").font(.callout)
                    } else {
                        Text("Paying one order at a time…").font(.callout)
                    }
                }
            }
        }
    }

    private func excludedTitle(_ draft: BatchPayReviewedDraft) -> String {
        let order = draft.order ?? store.orders.first(where: { $0.id == draft.id }).map { orderObject($0.values) } ?? [:]
        let name = orderListTitle(order)
        let number = orderNumber(order)
        return [name, number.isEmpty ? draft.id : number].joined(separator: " · ")
    }

    // MARK: Footer

    @ViewBuilder
    private var footer: some View {
        HStack {
            switch runner.phase {
            case .choose:
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button(batchPayReviewButtonTitle(chosen.count)) { runner.loadReview(chosen, store: store) }
                    .disabled(chosen.isEmpty || store.busy || !store.hasKey || lockNotice != nil)
                    .help("Load the ticked drafts from Slant to review. Nothing is paid.")
            case .loading:
                Button("Close", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Stop") { runner.requestStop() }
                    .help("Stop loading before the next draft. Nothing is paid.")
            case .review:
                Button("Go Back", role: .cancel) { runner.backToChoose() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                payButton
            case .paying:
                Button("Close and Stop", role: .cancel) { dismiss() }
                    .disabled(runner.inFlight)
                    .help("Stop before the next order. An order being paid finishes first.")
                Spacer()
                Button("Stop") { runner.requestStop() }
                    .disabled(runner.stopRequested)
                    .help("Stop before the next order. An order being paid finishes first.")
            case .done:
                Button("Choose Again") { runner.backToChoose() }
                    .disabled(store.busy)
                    .help("Back to the list of drafts. Nothing is paid until you review and confirm again.")
                Spacer()
                Button("Reload Orders") {
                    dismiss()
                    Task { await store.applyOrderFilter(store.orderFilter) }
                }
                .disabled(store.busy)
                .help("Close and reload the orders list from Slant")
                Button("Done", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(runner.reloadingID != nil)
            }
        }
    }

    /// Never the default button and no keyboard shortcut: paying always takes a click and the confirmation.
    private var payButton: some View {
        let payable = runner.payable
        let total = runner.payableTotal
        let reason = batchPayPayBlockedReason(payableCount: payable.count, totalKnown: total != nil, busy: store.busy,
                                              locked: lockNotice != nil, accountChanged: !runner.accountUnchanged(store))
        return VStack(alignment: .trailing, spacing: 6) {
            if let reason { Text(reason).font(.caption).foregroundStyle(.secondary) }
            Button(total.map { batchPayButtonTitle(count: payable.count, total: $0) } ?? "Pay Orders") {
                guard let total, reason == nil else { return }
                confirmedFigures = (payable.count, total)
                confirmPay = true
            }
            .buttonStyle(.borderedProminent)
            .disabled(reason != nil)
        }
    }
}

/// One reviewed draft: items one line each (large quantities flagged), costs, recipient and marketplace reference,
/// and its payment state once the batch has started.
struct BatchPayDraftCard<Extra: View>: View {
    let order: [String: Any]
    let state: BatchPayRowState?
    let modelNames: [String: String]
    let filaments: [Record]
    @ViewBuilder let extra: () -> Extra

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(orderListTitle(order)).font(.headline).lineLimit(1)
                Text(orderNumber(order)).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            if let reference = orderMarketplaceReferenceLine(order) {
                Text(reference).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            if let state { stateLine(state) }
            let items = (order["items"] as? [[String: Any]]) ?? []
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    let text = itemText(item)
                    if orderItemHasLargeQuantity(item) {
                        Label(text, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange).fontWeight(.semibold)
                            .lineLimit(1).truncationMode(.middle)
                            .accessibilityLabel("Large quantity: \(text)")
                            .help(text)
                    } else {
                        Text(text).lineLimit(1).truncationMode(.middle).help(text)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Printing") { Text("\(money(order["printingCost"])) USD").monospacedDigit() }
                LabeledContent("Delivery") { Text("\(money(order["deliveryCost"])) USD").monospacedDigit() }
                LabeledContent("Total") { Text("\(orderTotalMoney(order)) USD").monospacedDigit().fontWeight(.semibold) }
                LabeledContent("Recipient") { Text(orderRecipientDisplay(order)).lineLimit(2) }
            }
            .labeledContentStyle(.receipt)
            extra()
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    /// "2 × Bracket · PLA Black": one line, with the material when known.
    private func itemText(_ item: [String: Any]) -> String {
        let line = orderItemLineText(item, modelNames: modelNames)
        guard let material = orderItemMaterialName(item, filaments: filaments) else { return line }
        return "\(line) · \(materialDisplayName(material))"
    }

    @ViewBuilder
    private func stateLine(_ state: BatchPayRowState) -> some View {
        let text = batchPayStateText(state)
        switch state {
        case .placed:
            Label(text, systemImage: "checkmark.circle.fill").foregroundStyle(.green).fontWeight(.semibold)
        case .paying:
            HStack(spacing: 6) { ProgressView().controlSize(.small); Text(text) }
        case .queued:
            Text(text).foregroundStyle(.secondary)
        case .unknown:
            Label(text, systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
        case .refused, .notPaid:
            Label(text, systemImage: "xmark.circle").foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .reloaded:
            Label(text, systemImage: "arrow.clockwise.circle").foregroundStyle(.secondary)
        }
    }
}
