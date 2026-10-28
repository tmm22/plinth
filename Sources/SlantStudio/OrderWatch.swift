import Foundation
import AppKit
import Combine
import UserNotifications

// MARK: - Order watch: settings and limits

/// Settings › Advanced › Check orders while Slant Studio is open (on unless turned off).
let orderWatchEnabledDefaultsKey = "orderWatchEnabled"
/// Settings › Advanced › Notify me about order changes (off until turned on, which asks macOS for permission).
let orderWatchNotifyDefaultsKey = "orderWatchNotify"
/// Settings › Advanced › Show count on Dock icon (on unless turned off): the sidebar's Orders badge, on the Dock tile.
let orderWatchDockBadgeDefaultsKey = "orderWatchDockBadge"
/// Order IDs, statuses and times only, in Application Support/SlantStudio.
let orderWatchFileName = "order-watch.json"
/// Time between checks. Each check makes at most two reads (newest created, then most recently updated), so 30 reads
/// an hour: well inside Slant's 100 a minute, and each read first leaves `orderWatchRateLimitReserve` to the seller.
let orderWatchInterval: TimeInterval = 4 * 60
/// The first check after launch, a key change or turning the watch on waits a little, so it never races the launch refresh.
let orderWatchFirstCheckDelay: TimeInterval = 20
/// How soon a check skipped for a running request, open sheet or missing setup is looked at again (no request is made).
let orderWatchRecheckDelay: TimeInterval = 30
/// A check waits while fewer requests than this remain, leaving the allowance to the seller's own work.
let orderWatchRateLimitReserve = 20
/// After a 401/403, checks pause this long unless the key or platform changes first.
let orderWatchAccountPause: TimeInterval = 30 * 60
let orderWatchMaxEntries = 1000
let orderWatchMaxAge: TimeInterval = 180 * 24 * 3600
private let orderWatchMaxFileBytes = 4 * 1024 * 1024
private let orderWatchMaxIDLength = 128
private let orderWatchMaxStatusLength = 64
/// Show and a notification click read at most this many changed orders that aren't on the reloaded first page, one
/// read each (`orderWatchFetch`; older orders whose change the updated-first read found).
let orderWatchShowFetchLimit = 10
/// The notification `userInfo` key for the Slant order ID, the only thing a notification carries besides its text.
let orderWatchNotificationOrderIDKey = "orderID"

/// Changes worth a sidebar badge and a notification: the order needs attention, or it reached the customer's door.
/// Of Slant's live statuses (since 26 Oct 2026) only SHIPPED and CANCELLED are notable; the earlier ones stay for
/// saved snapshots and any old reply. DELIVERED can also come from the shipping record (`orderWatchObservations`).
let orderWatchNotableStatuses: Set<String> = ["PAYMENT_ERROR", "IN_REVIEW", "CANCELLED", "CANCELED", "SHIPPED", "DELIVERED"]
private let orderWatchAttentionOrder = ["PAYMENT_ERROR", "IN_REVIEW", "CANCELLED", "DELIVERED", "SHIPPED"]

// MARK: - Snapshot

/// What Studio remembers about one order between checks. Nothing else (no names, totals or metadata) is kept.
struct OrderWatchEntry: Equatable {
    /// The latest status a check returned.
    var status: String
    /// The status when the seller last looked (Show or Dismiss). Differs from `status` while a change is unseen.
    var seenStatus: String
    /// When a check last returned this order.
    var lastSeen: Date
    /// When `status` last changed.
    var changedAt: Date?
    var hasUnseenChange: Bool { status != seenStatus }
}

struct OrderWatchSnapshot: Equatable {
    var orders: [String: OrderWatchEntry] = [:]
    /// When the last successful check finished.
    var updatedAt: Date?
}

/// One order as a check saw it. `number` is only used for notification text and is never saved.
struct OrderWatchObservation: Equatable {
    var id: String
    var status: String
    var number: String
}

/// A status change found by a check (the previous check's status to the new one).
struct OrderWatchTransition: Equatable {
    var id: String
    var number: String
    var from: String
    var to: String
}

/// An order whose status changed since the seller last looked.
struct OrderWatchChange: Equatable, Identifiable {
    var id: String
    var from: String
    var to: String
    var changedAt: Date?
}

func normalizedOrderWatchStatus(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let status = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !status.isEmpty, status.count <= orderWatchMaxStatusLength else { return nil }
    return status
}

private func validOrderWatchID(_ id: String) -> Bool {
    !id.isEmpty && id.count <= orderWatchMaxIDLength && !id.contains(where: \.isNewline)
}

/// The order-level status of each listed order, as Studio shows it (`orderDisplayStatus`): Slant's order status, or
/// the shipping record's SHIPPED or DELIVERED while the order status still reads a production status (live on 29 Oct
/// 2026: PRINTING orders whose `fulfillment.status` was SHIPPED, with tracking and a printed label). So a parcel that
/// left Slant is reported once, when the shipping record says so, and the order status catching up later is no change.
/// Still a status word only, so the snapshot keeps IDs, statuses and times. Item statuses (a draft's items say
/// PROCESSING) are ignored, as are rows without an ID or a text status; the first row wins when an ID repeats.
func orderWatchObservations(_ records: [Record]) -> [OrderWatchObservation] {
    var seen = Set<String>()
    var result: [OrderWatchObservation] = []
    for record in records {
        let order = orderObject(record.values)
        let id = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validOrderWatchID(id), let status = normalizedOrderWatchStatus(orderDisplayStatus(order)),
              seen.insert(id).inserted else { continue }
        result.append(OrderWatchObservation(id: id, status: status, number: String(orderNumber(order).prefix(40))))
    }
    return result
}

/// The second read of each check: page 1 of the default platform's orders, most recently updated first, so a change to
/// an order older than the newest 100 is still seen. Slant's Orders docs list `sortBy=updatedAt`; the live API
/// answered it with 200 on 24 Oct 2026.
func orderWatchRecentlyUpdatedQuery(platformID: String) -> [String: String] {
    var query = orderFilterQueryItems(OrderFilter(), page: 1, limit: listPageSize, platformID: platformID)
    query["sortBy"] = "updatedAt"
    query["sortOrder"] = "DESC"
    return query
}

enum OrderWatchSortCheck: Equatable {
    case sorted, notSorted
    /// Fewer than two rows carry a readable `updatedAt`, so the order can't be judged.
    case inconclusive
}

/// Whether a reply to the updated-first read is in fact newest-updated first. One that isn't means Slant ignored the
/// sort (it then returns the newest created, which the first read already has), so Studio stops asking for it. Rows
/// without a readable `updatedAt` are skipped; a second of slack allows for rounding.
func orderWatchUpdatedSortCheck(_ records: [Record]) -> OrderWatchSortCheck {
    let dates = records.compactMap { record -> Date? in
        guard let text = orderObject(record.values)["updatedAt"] as? String else { return nil }
        return orderTimestamp(text)
    }
    guard dates.count >= 2 else { return .inconclusive }
    for (earlier, later) in zip(dates, dates.dropFirst()) where later.timeIntervalSince(earlier) > 1 { return .notSorted }
    return .sorted
}

/// A refusal of the updated-first read itself (400 or 422: Slant didn't accept the sort). That read then stops for
/// the session; the newest-created read carries on as before.
func orderWatchUpdatedReadRefused(_ error: Error) -> Bool {
    guard case .http(let status, _, _, _)? = error as? APIError else { return false }
    return status == 400 || status == 422
}

/// Both reads of one check as one list: each order once, in the order first seen. Where both returned an order, the
/// later read's status wins (it is the fresher), so one check never reports an order twice.
func orderWatchMergedObservations(_ first: [OrderWatchObservation], _ later: [OrderWatchObservation]) -> [OrderWatchObservation] {
    var result: [OrderWatchObservation] = []
    var index: [String: Int] = [:]
    for observation in first + later {
        if let position = index[observation.id] {
            result[position] = observation
        } else {
            index[observation.id] = result.count
            result.append(observation)
        }
    }
    return result
}

/// The orders Show (or a notification click) reads by ID after reloading the first page: those asked for that the
/// reload didn't bring, in the order given (newest change first), each once, at most `limit`.
func orderWatchIDsToFetch(wanted: [String], loaded: Set<String>, limit: Int = orderWatchShowFetchLimit) -> [String] {
    var seen = Set<String>()
    var result: [String] = []
    for id in wanted where result.count < limit {
        guard validOrderWatchID(id), id.trimmingCharacters(in: .whitespacesAndNewlines) == id,
              !loaded.contains(id), seen.insert(id).inserted else { continue }
        result.append(id)
    }
    return result
}

/// How Show and a notification click read one changed order that isn't on the reloaded page. With a default platform:
/// `GET /orders?publicId=<id>&platformId=<platform>` (answered live on 29 Oct 2026), so Slant itself says whether the
/// order is on the listed platform. Live orders name no platform ID (only a `platform` object without one), so the
/// order alone can't tell. Without a default platform every platform's orders are listed: `GET /orders/{id}`.
struct OrderWatchFetch: Equatable {
    var path: String
    var query: [String: String]
    /// A filtered list read (rows), not a read by ID (one order).
    var listed: Bool { path == "/orders" }
}

func orderWatchFetch(id: String, platformID: String) -> OrderWatchFetch {
    let platform = platformID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !platform.isEmpty else { return OrderWatchFetch(path: "/orders/\(encodedSegment(id))", query: [:]) }
    return OrderWatchFetch(path: "/orders", query: ["publicId": id, "platformId": platform, "page": "1", "limit": String(listPageSize)])
}

/// The order a `fetch` reply holds for `id`, or nil to skip it like one not found: an empty list (the order isn't on
/// the platform), a reply that ignored `publicId` (rows are matched to the exact ID, as before), or an order that names
/// another platform.
func orderWatchFetchedRecord(_ response: APIResponse, fetch: OrderWatchFetch, id: String, platformID: String) -> Record? {
    let candidates = fetch.listed ? responseRecords(response) : [Record(values: mergeOrderDraftEnvelope(responseObject(response)))]
    guard let match = candidates.first(where: { $0.id == id }),
          orderWatchFetchedOrderFitsPlatform(orderObject(match.values), platformID: platformID) else { return nil }
    return match
}

/// Whether an order read by ID may join the loaded list of `platformID`'s orders: one that names another platform (an
/// old notification from before the default platform changed, say) doesn't. Orders that name no platform are kept;
/// live orders name none (29 Oct 2026), so with a default platform `orderWatchFetch` asks Slant to filter by it.
func orderWatchFetchedOrderFitsPlatform(_ order: [String: Any], platformID: String) -> Bool {
    let current = platformID.trimmingCharacters(in: .whitespacesAndNewlines)
    let named = [order["platformId"], (order["customer"] as? [String: Any])?["platformId"]]
        .compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
    guard !current.isEmpty, !named.isEmpty else { return true }
    return named.contains(current)
}

/// Whether a saved status moving to a live one is only Slant's re-labelling of 26 Oct 2026, not news: an earlier
/// production stage (Paid, Queued, Processing, On the shelf, Finishing, Completed, In review, Awaiting shipment) now
/// reads Submitted or Printing (orders paid the week before read PRINTING on 28 Oct 2026), CANCELED is spelt
/// CANCELLED, and Delivered (no longer a status) reads Shipped. A payment problem that now reads Submitted or Printing
/// was resolved, which is news, and every other move from an earlier status (Queued → Shipped, say) is real, as is a
/// shipping record's Shipped on a Printing or Awaiting shipment order (`orderWatchObservations`). A shipping record's
/// Delivered later read as Shipped (the order status caught up) is the same re-labelling, so it stays quiet.
func orderWatchChangeIsSlantRelabel(from: String, to: String) -> Bool {
    guard orderLegacyStatuses.contains(from) else { return false }
    switch to {
    case "SUBMITTED", "PRINTING": return !["PAYMENT_ERROR", "CANCELED", "DELIVERED"].contains(from)
    case "CANCELLED": return from == "CANCELED"
    case "SHIPPED": return from == "DELIVERED"
    default: return false
    }
}

/// Whether a change is listed under "Since you last looked". Placing a draft is the seller's own action, so
/// Draft → Paid isn't reported (later progress, or a payment problem, is). Live Slant also returns SUBMITTED for a
/// just-placed order (26 Oct 2026), in an order not yet confirmed relative to PAID, so any move among Draft,
/// Submitted and Paid that ends in Submitted or Paid counts as placing too. Slant's re-labelling of a saved status
/// (`orderWatchChangeIsSlantRelabel`) isn't reported either. A shipping record withdrawn (Shipped back to Printing, say)
/// is listed but never notified or badged (production statuses aren't notable): the seller may have passed on the
/// tracking, so it is worth a look, not an alarm. If the seller hadn't yet seen the Shipped, the change simply goes.
func orderWatchChangeIsReported(from: String, to: String) -> Bool {
    guard from != to else { return false }
    if orderWatchChangeIsSlantRelabel(from: from, to: to) { return false }
    let placing: Set<String> = ["PAID", "SUBMITTED"]
    return !((from == "DRAFT" || placing.contains(from)) && placing.contains(to))
}

func orderWatchShouldNotify(_ transition: OrderWatchTransition) -> Bool {
    orderWatchChangeIsReported(from: transition.from, to: transition.to) && orderWatchNotableStatuses.contains(transition.to)
}

/// Folds a check into the snapshot. Orders Studio hasn't seen before (including every order on the first run, and
/// new drafts) are recorded silently; an order missing from this check is left as it was (it may be on a later page).
func orderWatchApplying(_ observations: [OrderWatchObservation], to snapshot: OrderWatchSnapshot, now: Date)
    -> (snapshot: OrderWatchSnapshot, transitions: [OrderWatchTransition]) {
    var next = snapshot
    var transitions: [OrderWatchTransition] = []
    for observation in observations {
        guard var entry = next.orders[observation.id] else {
            next.orders[observation.id] = OrderWatchEntry(status: observation.status, seenStatus: observation.status,
                                                          lastSeen: now, changedAt: nil)
            continue
        }
        entry.lastSeen = now
        if entry.status != observation.status {
            let previous = entry.status
            transitions.append(OrderWatchTransition(id: observation.id, number: observation.number, from: previous, to: observation.status))
            // An unreported change that is the only change since the seller looked is treated as seen.
            if !orderWatchChangeIsReported(from: previous, to: observation.status), entry.seenStatus == previous {
                entry.seenStatus = observation.status
            }
            entry.status = observation.status
            // A re-label isn't a change: an unseen change keeps its time (and its place in the banner's list).
            if !orderWatchChangeIsSlantRelabel(from: previous, to: observation.status) { entry.changedAt = now }
        }
        next.orders[observation.id] = entry
    }
    next.updatedAt = now
    return (next, transitions)
}

/// Drops orders no check has returned for `maxAge`, then keeps at most `maxEntries`: unseen changes first, then the
/// most recently seen.
func orderWatchPruned(_ snapshot: OrderWatchSnapshot, now: Date, maxEntries: Int = orderWatchMaxEntries,
                      maxAge: TimeInterval = orderWatchMaxAge) -> OrderWatchSnapshot {
    var kept = snapshot.orders.filter { now.timeIntervalSince($0.value.lastSeen) <= maxAge }
    if kept.count > maxEntries {
        let ranked = kept.sorted { lhs, rhs in
            if lhs.value.hasUnseenChange != rhs.value.hasUnseenChange { return lhs.value.hasUnseenChange }
            if lhs.value.lastSeen != rhs.value.lastSeen { return lhs.value.lastSeen > rhs.value.lastSeen }
            return lhs.key < rhs.key
        }
        kept = Dictionary(uniqueKeysWithValues: ranked.prefix(max(0, maxEntries)).map { ($0.key, $0.value) })
    }
    return OrderWatchSnapshot(orders: kept, updatedAt: snapshot.updatedAt)
}

/// Unseen changes, newest first (by when they changed, then order ID, so the list is stable).
func orderWatchUnseenChanges(_ snapshot: OrderWatchSnapshot) -> [OrderWatchChange] {
    snapshot.orders.compactMap { id, entry -> OrderWatchChange? in
        guard entry.hasUnseenChange, orderWatchChangeIsReported(from: entry.seenStatus, to: entry.status) else { return nil }
        return OrderWatchChange(id: id, from: entry.seenStatus, to: entry.status, changedAt: entry.changedAt)
    }
    .sorted { lhs, rhs in
        let l = lhs.changedAt ?? .distantPast, r = rhs.changedAt ?? .distantPast
        return l != r ? l > r : lhs.id < rhs.id
    }
}

/// Marks the given orders (or all) as seen.
func orderWatchAcknowledging(_ snapshot: OrderWatchSnapshot, ids: Set<String>? = nil) -> OrderWatchSnapshot {
    var next = snapshot
    for (id, entry) in snapshot.orders where entry.hasUnseenChange && (ids?.contains(id) ?? true) {
        next.orders[id]?.seenStatus = entry.status
    }
    return next
}

/// Statuses that badge the sidebar: the notable ones except Delivered, which needs nothing from the seller (it is
/// still listed in the banner and notified).
let orderWatchBadgeStatuses: Set<String> = orderWatchNotableStatuses.subtracting(["DELIVERED"])

/// The sidebar badge: unseen changes that need attention or shipped. Production progress and deliveries are listed
/// in Orders but don't badge, so a busy print queue or a run of deliveries doesn't keep a number on the sidebar.
func orderWatchBadgeCount(_ changes: [OrderWatchChange]) -> Int {
    changes.filter { orderWatchBadgeStatuses.contains($0.to) }.count
}

/// The banner offers Tracking for Your Shop… while a listed change is to Shipped.
func orderWatchChangesIncludeShipped(_ changes: [OrderWatchChange]) -> Bool {
    changes.contains { $0.to == "SHIPPED" }
}

/// Whether the platform the watch follows has changed, so the saved statuses (another platform's orders) are
/// forgotten. Only a change between two known platforms counts: the blank in between a key change (Studio clears the
/// platform, then the refresh picks one) is not a platform.
func orderWatchPlatformChanged(from previous: String?, to next: String) -> Bool {
    let old = (previous ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let new = next.trimmingCharacters(in: .whitespacesAndNewlines)
    return !old.isEmpty && !new.isEmpty && old != new
}

/// Whether a background check's rate-limit figures may replace the ones Studio already has. The check's reply can
/// arrive after a newer reply to the seller's own request, so stale figures must never win: within one window the
/// allowance only falls, so a higher `remaining` is older. Figures are applied when nothing is known (or the known
/// window has passed), when they belong to a later window, or when they show the same or less allowance. With no reset
/// time to tell windows apart, only the same or a lower `remaining` is applied: under-reporting the allowance is the
/// safe way to be wrong.
func orderWatchShouldApplyRateLimit(current: RateLimitInfo?, incoming: RateLimitInfo, now: Date) -> Bool {
    guard incoming.hasValues else { return false }
    guard let current, current.hasValues else { return true }
    if let reset = current.reset, reset <= now { return true }
    if let newReset = incoming.reset, let oldReset = current.reset, newReset.timeIntervalSince(oldReset) > 1 { return true }
    if let newReset = incoming.reset, let oldReset = current.reset, oldReset.timeIntervalSince(newReset) > 1 { return false }
    guard let remaining = incoming.remaining else { return false }
    guard let known = current.remaining else { return true }
    return remaining <= known
}

/// Slant's progress order, live statuses with the earlier ones (still read from saved snapshots) in their old place.
private let orderWatchProgressOrder = [
    "DRAFT", "PAID", "SUBMITTED", "QUEUED", "PROCESSING", "PRINTING", "ITEMS_ON_SHELF", "POST_PROCESSING",
    "COMPLETED", "IN_REVIEW", "AWAITING_SHIPMENT", "SHIPPED", "DELIVERED", "CANCELLED", "CANCELED", "PAYMENT_ERROR"
]

/// Unseen changes counted by new status: attention first, then shipped/delivered, then progress in Slant's order.
func orderWatchSummaryGroups(_ changes: [OrderWatchChange]) -> [(status: String, count: Int)] {
    var counts: [String: Int] = [:]
    // Both spellings of cancelled are one group, so the banner never reads "1 cancelled · 1 cancelled".
    for change in changes { counts[change.to == "CANCELED" ? "CANCELLED" : change.to, default: 0] += 1 }
    func rank(_ status: String) -> Int {
        if let index = orderWatchAttentionOrder.firstIndex(of: status) { return index }
        if let index = orderWatchProgressOrder.firstIndex(of: status) { return 100 + index }
        return 1000
    }
    return counts.map { (status: $0.key, count: $0.value) }.sorted { lhs, rhs in
        let l = rank(lhs.status), r = rank(rhs.status)
        return l != r ? l < r : lhs.status < rhs.status
    }
}

/// The Dock tile's badge: the sidebar's Orders count, or nothing when that is zero or the seller turned it off.
func orderWatchDockBadgeLabel(count: Int, showOnDock: Bool) -> String? {
    guard showOnDock, count > 0 else { return nil }
    return String(count)
}

/// "2 shipped · 1 payment problem · 1 printing".
func orderWatchSummaryText(_ changes: [OrderWatchChange]) -> String {
    orderWatchSummaryGroups(changes).map { "\($0.count) \(orderStatusTitle($0.status).lowercased())" }.joined(separator: " · ")
}

/// The orders a Show from the banner focuses the list on, in list order; nil (show everything) when none are loaded.
func orderWatchFocusedRecords(_ orders: [Record], focus: Set<String>?) -> [Record]? {
    guard let focus, !focus.isEmpty else { return nil }
    let matching = orders.filter { focus.contains($0.id) }
    return matching.isEmpty ? nil : matching
}

func orderWatchFocusCaption(count: Int) -> String {
    count == 1 ? "Showing 1 order that changed since you last looked." : "Showing \(count) orders that changed since you last looked."
}

// MARK: - Notifications

struct OrderWatchNotificationText: Equatable {
    var identifier: String
    var title: String
    var body: String
    /// The Slant order ID a click opens, sent as the notification's only `userInfo`; nil for the summary (opens Orders).
    var orderID: String? = nil
}

/// The order a clicked notification names, or nil (just open Orders) when its `userInfo` has no plausible order ID.
func orderWatchNotificationOrderID(_ userInfo: [AnyHashable: Any]) -> String? {
    guard let id = userInfo[orderWatchNotificationOrderIDKey] as? String, validOrderWatchID(id),
          id.trimmingCharacters(in: .whitespacesAndNewlines) == id else { return nil }
    return id
}

/// A notification click's request to select an order, taken once by the Orders screen (`consumeSelection`).
struct OrderWatchSelectionRequest: Equatable {
    let orderID: String
    let token = UUID()
}

private func orderWatchNotificationPhrase(_ status: String) -> String {
    switch status {
    case "SHIPPED": "has shipped"
    case "DELIVERED": "was delivered"
    case "CANCELED", "CANCELLED": "was cancelled"
    case "PAYMENT_ERROR": "has a payment problem"
    case "IN_REVIEW": "is in review"
    default: "is now \(orderStatusTitle(status).lowercased())"
    }
}

/// Order numbers and statuses only, never a customer's name or address. More than three changes at once become one
/// summary notification.
func orderWatchNotificationTexts(_ transitions: [OrderWatchTransition]) -> [OrderWatchNotificationText] {
    let notable = transitions.filter(orderWatchShouldNotify)
    guard !notable.isEmpty else { return [] }
    if notable.count > 3 {
        let changes = notable.map { OrderWatchChange(id: $0.id, from: $0.from, to: $0.to) }
        return [OrderWatchNotificationText(identifier: "order-watch-summary", title: "\(notable.count) orders changed",
                                           body: orderWatchSummaryText(changes))]
    }
    return notable.map { transition in
        let number = transition.number.isEmpty ? transition.id : transition.number
        return OrderWatchNotificationText(
            identifier: "order-watch-\(transition.id)",
            title: "Order \(number) \(orderWatchNotificationPhrase(transition.to))",
            body: "\(orderStatusTitle(transition.from)) → \(orderStatusTitle(transition.to))",
            orderID: transition.id
        )
    }
}

// MARK: - When to check

enum OrderWatchSkip: Equatable {
    case disabled, noKey, noPlatform, busy, modalUI, inFlight, accountPaused
    /// Wait until this time (nil: until the next scheduled check).
    case rateLimited(until: Date?)
}

struct OrderWatchConditions {
    var enabled = true
    var hasKey = true
    var hasPlatform = true
    var busy = false
    var modalUIShown = false
    var inFlight = false
    var accountPaused = false
    var rateLimit: RateLimitInfo?
    /// The low allowance an earlier check already waited a full interval for (no request has updated it since).
    var rateLimitAlreadyWaitedFor: RateLimitInfo?
    var backoffUntil: Date?
    var now = Date()
}

/// Why a scheduled check doesn't run now, or nil to run it. Checks never run while a request is running (`busy`) or a
/// sheet, alert or dialog is shown in any window (the review, import and estimate sheets send their own requests), and
/// they leave the rate-limit allowance to the seller.
func orderWatchSkipReason(_ c: OrderWatchConditions) -> OrderWatchSkip? {
    if !c.enabled { return .disabled }
    if !c.hasKey { return .noKey }
    if !c.hasPlatform { return .noPlatform }
    if c.accountPaused { return .accountPaused }
    if c.inFlight { return .inFlight }
    if c.busy { return .busy }
    if c.modalUIShown { return .modalUI }
    if let until = c.backoffUntil, until > c.now { return .rateLimited(until: until) }
    if let rate = c.rateLimit, let remaining = rate.remaining, remaining <= orderWatchRateLimitReserve {
        if let reset = rate.reset {
            if reset > c.now { return .rateLimited(until: reset) }
        } else if rate != c.rateLimitAlreadyWaitedFor {
            // No reset time: wait one interval. Slant's window is a minute, so by then the allowance has refilled.
            return .rateLimited(until: nil)
        }
    }
    return nil
}

/// Seconds until the loop looks again.
func orderWatchNextDelay(after skip: OrderWatchSkip?, now: Date) -> TimeInterval {
    switch skip {
    case nil: return orderWatchInterval
    case .rateLimited(let until?):
        return min(orderWatchInterval, max(5, until.timeIntervalSince(now) + 2))
    case .rateLimited(nil): return orderWatchInterval
    default: return orderWatchRecheckDelay
    }
}

/// What a failed check means for the next one. 429 waits for Slant's reset (or Retry-After, or a minute); 401/403
/// pause checks until the key or platform changes (at most `orderWatchAccountPause`); anything else simply waits for
/// the next scheduled check.
func orderWatchFailureEffect(_ error: Error, now: Date) -> (backoffUntil: Date?, pauseAccount: Bool) {
    guard case .http(let status, _, let retryAfter, let reset)? = error as? APIError else { return (nil, false) }
    switch status {
    case 429:
        if let date = rateLimitResetDate(reset, now: now), date > now { return (date, false) }
        if let text = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), let seconds = Double(text), seconds.isFinite, seconds > 0 {
            return (now.addingTimeInterval(min(seconds, 3600)), false)
        }
        return (now.addingTimeInterval(60), false)
    case 401, 403: return (nil, true)
    default: return (nil, false)
    }
}

/// Why the background checks are holding back after a failure, for Settings › Advanced (Activity is hidden unless
/// developer tools are on). Memory only.
enum OrderWatchHold: Equatable {
    /// Slant refused the key or platform (401/403).
    case accountRefused
    /// Slant's rate limit (429): the next check waits until this time.
    case rateLimited(until: Date)
}

/// The hold a failure leads to, or nil when the next check simply runs as scheduled.
func orderWatchHold(after effect: (backoffUntil: Date?, pauseAccount: Bool)) -> OrderWatchHold? {
    if effect.pauseAccount { return .accountRefused }
    if let until = effect.backoffUntil { return .rateLimited(until: until) }
    return nil
}

/// The line under Last checked while checks are held back, or nil (a rate-limit wait that has passed says nothing).
func orderWatchHoldCaption(_ hold: OrderWatchHold?, now: Date) -> String? {
    switch hold {
    case .accountRefused?:
        return "Paused: Slant refused the API key or platform. Checks start again when you change either, or after \(Int(orderWatchAccountPause / 60)) minutes."
    case .rateLimited(let until)?:
        guard until > now else { return nil }
        return "Waiting for Slant’s rate limit: the next check is after \(until.formatted(date: .omitted, time: .shortened))."
    case nil:
        return nil
    }
}

// MARK: - Storage

func encodeOrderWatchSnapshot(_ snapshot: OrderWatchSnapshot) -> Data? {
    var orders: [String: Any] = [:]
    for (id, entry) in snapshot.orders {
        var row: [String: Any] = ["status": entry.status, "seenStatus": entry.seenStatus,
                                  "lastSeen": entry.lastSeen.timeIntervalSince1970]
        if let changed = entry.changedAt { row["changedAt"] = changed.timeIntervalSince1970 }
        orders[id] = row
    }
    var root: [String: Any] = ["version": 1, "orders": orders]
    if let updated = snapshot.updatedAt { root["updatedAt"] = updated.timeIntervalSince1970 }
    return try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

/// Lenient: unusable rows are dropped and missing optional fields defaulted. Nil when the file isn't a JSON object
/// (it is then ignored and replaced on the next check).
func decodeOrderWatchSnapshot(_ data: Data, now: Date = Date()) -> OrderWatchSnapshot? {
    guard data.count <= orderWatchMaxFileBytes,
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    func date(_ value: Any?) -> Date? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0, seconds < 1e11 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    var snapshot = OrderWatchSnapshot()
    snapshot.updatedAt = date(root["updatedAt"])
    for (id, value) in (root["orders"] as? [String: Any]) ?? [:] {
        guard validOrderWatchID(id), let row = value as? [String: Any], let status = normalizedOrderWatchStatus(row["status"]) else { continue }
        snapshot.orders[id] = OrderWatchEntry(
            status: status,
            seenStatus: normalizedOrderWatchStatus(row["seenStatus"]) ?? status,
            lastSeen: date(row["lastSeen"]) ?? snapshot.updatedAt ?? now,
            changedAt: date(row["changedAt"])
        )
    }
    return snapshot
}

/// Notifications need the packaged app (a bundle identifier); `swift run` and tests skip them.
func orderWatchNotificationsAvailable(bundle: Bundle = .main) -> Bool {
    bundle.bundleIdentifier != nil && bundle.bundleURL.pathExtension.lowercased() == "app"
}

// MARK: - The watcher

private struct PendingNotificationOpen {
    let orderID: String?
}

/// Checks the newest and the most recently updated orders on the default platform every few minutes while the app is
/// open, and remembers each order's status so changes can be listed in Orders, badged in the sidebar and on the Dock
/// and, if asked for, notified.
/// Read-only: at most two GET /orders per check through the shared client, never `store.run` (it never sets `busy`),
/// never the unknown-outcome lock, never retried before the next scheduled check, and it never replaces `store.orders`.
@MainActor final class OrderWatch: ObservableObject {
    static let shared = OrderWatch()

    @Published private(set) var snapshot = OrderWatchSnapshot() {
        didSet { updateDockBadge() }
    }
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: orderWatchEnabledDefaultsKey) as? Bool ?? true {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: orderWatchEnabledDefaultsKey)
            generation += 1
            if enabled { startLoop() } else { loop?.cancel(); loop = nil }
            updateDockBadge()
        }
    }
    /// Settings › Advanced › Show count on Dock icon.
    @Published var dockBadge: Bool = UserDefaults.standard.object(forKey: orderWatchDockBadgeDefaultsKey) as? Bool ?? true {
        didSet {
            guard dockBadge != oldValue else { return }
            UserDefaults.standard.set(dockBadge, forKey: orderWatchDockBadgeDefaultsKey)
            updateDockBadge()
        }
    }
    /// A clicked notification's order for the Orders screen to select (see `openFromNotification`).
    @Published private(set) var selectionRequest: OrderWatchSelectionRequest?
    @Published private(set) var notify: Bool = UserDefaults.standard.bool(forKey: orderWatchNotifyDefaultsKey) {
        didSet { UserDefaults.standard.set(notify, forKey: orderWatchNotifyDefaultsKey) }
    }
    /// macOS has notifications for Slant Studio turned off (or permission was refused).
    @Published private(set) var notificationsDenied = false
    @Published private(set) var requestingPermission = false
    /// Shown in Settings › Advanced while checks are paused (401/403) or waiting after a 429; memory only.
    @Published private(set) var hold: OrderWatchHold?

    private weak var store: StudioStore?
    private var loop: Task<Void, Never>?
    private var loaded = false
    private var inFlight = false
    private var generation = 0
    private var backoffUntil: Date?
    private var rateLimitWaitedFor: RateLimitInfo?
    private var pausedAccount: String?
    private var pausedAt: Date?
    private var failureLogged = false
    /// The last known default platform. The saved statuses belong to it (only order IDs, statuses and times are saved,
    /// never the platform), so they are forgotten when it changes.
    private var watchedPlatformID: String?
    private var accountObservers: Set<AnyCancellable> = []
    /// False once Slant refused `sortBy=updatedAt` or answered it unsorted; the second read then stops for the session.
    private var updatedReadAvailable = true
    /// A clicked notification waiting until no sheet, alert or request is shown: the order to select (nil: just Orders).
    private var pendingOpen: PendingNotificationOpen?
    private var openDrainScheduled = false

    var unseenChanges: [OrderWatchChange] { enabled ? orderWatchUnseenChanges(snapshot) : [] }
    var badgeCount: Int { orderWatchBadgeCount(unseenChanges) }

    private var fileURL: URL { StudioStore.supportDirectory.appendingPathComponent(orderWatchFileName) }

    func attach(_ store: StudioStore) {
        guard self.store !== store else { return }
        self.store = store
        if !loaded {
            loaded = true
            if let data = try? Data(contentsOf: fileURL), let saved = decodeOrderWatchSnapshot(data) {
                snapshot = orderWatchPruned(saved, now: Date())
            }
        }
        observeAccount(store)
        if orderWatchNotificationsAvailable() {
            UNUserNotificationCenter.current().delegate = OrderWatchNotificationDelegate.shared
            if notify { refreshNotificationPermission() }
        }
        if enabled { startLoop() }
        updateDockBadge()
        scheduleOpenDrain()
    }

    private func startLoop() {
        loop?.cancel()
        loop = Task { [weak self] in
            var delay = orderWatchFirstCheckDelay
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                delay = await self.tick()
            }
        }
    }

    /// Another default platform (or another account's) forgets the saved statuses, so the banner, badge and Show only
    /// ever refer to the platform being watched; the next check records its orders silently. Disconnect forgets them
    /// too, so nothing about the account's orders stays on this Mac after it is disconnected.
    private func observeAccount(_ store: StudioStore) {
        accountObservers = []
        let current = store.platformID.trimmingCharacters(in: .whitespacesAndNewlines)
        watchedPlatformID = current.isEmpty ? nil : current
        // @Published sends the new value as it is set, on the main actor.
        store.$platformID
            .sink { [weak self] id in
                MainActor.assumeIsolated { self?.platformDidChange(to: id) }
            }
            .store(in: &accountObservers)
        store.$apiKey
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] hasKey in
                MainActor.assumeIsolated { if !hasKey { self?.forgetSavedStatuses() } }
            }
            .store(in: &accountObservers)
    }

    private func platformDidChange(to id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if orderWatchPlatformChanged(from: watchedPlatformID, to: trimmed) { forgetSavedStatuses() }
        watchedPlatformID = trimmed
    }

    private func accountToken(_ store: StudioStore) -> String {
        "\(store.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).hashValue)|\(store.platformID)"
    }

    /// One scheduled check; returns the delay until the next.
    private func tick() async -> TimeInterval {
        guard let store else { return orderWatchRecheckDelay }
        let now = Date()
        let token = accountToken(store)
        // A refused key or platform pauses checks until it changes, or for half an hour (it may have been fixed on Slant).
        if let paused = pausedAccount, paused != token || now.timeIntervalSince(pausedAt ?? now) >= orderWatchAccountPause {
            pausedAccount = nil
            if hold == .accountRefused { hold = nil }
        }
        if let skip = orderWatchSkipReason(conditions(store, token: token, now: now)) {
            if skip == .rateLimited(until: nil) { rateLimitWaitedFor = store.rateLimit }
            return orderWatchNextDelay(after: skip, now: now)
        }
        rateLimitWaitedFor = nil
        backoffUntil = nil
        let runGeneration = generation
        let platformID = store.platformID
        let client = store.client
        inFlight = true
        defer { inFlight = false }
        // A key or platform change, Forget or turning the watch off while a read was in flight discards it.
        func stillCurrent() -> Bool { runGeneration == generation && enabled && accountToken(store) == token }
        // 1. The newest created orders, as before.
        let newest: [OrderWatchObservation]
        do {
            let response = try await client.request("GET", path: "/orders",
                                                    query: orderFilterQueryItems(OrderFilter(), page: 1, limit: listPageSize, platformID: platformID))
            guard stillCurrent() else { return orderWatchRecheckDelay }
            applyRateLimit(from: response, to: store)
            SlantAPIWatch.shared.noteOrderList(response, firstPage: true)
            newest = orderWatchObservations(responseRecords(response))
            hold = nil
        } catch {
            guard stillCurrent() else { return orderWatchRecheckDelay }
            noteFailure(error, store: store, token: token)
            return orderWatchInterval
        }
        // 2. The most recently updated, so older orders' changes are seen too. Only when every condition for a check
        // still holds after the first read (no request started, nothing modal opened, the allowance is still there);
        // otherwise this check keeps the first read alone.
        var observations = newest
        var updatedReadFailed = false
        if updatedReadAvailable, orderWatchSkipReason(conditions(store, token: token, now: Date(), countInFlight: false)) == nil {
            do {
                let response = try await client.request("GET", path: "/orders", query: orderWatchRecentlyUpdatedQuery(platformID: platformID))
                guard stillCurrent() else { return orderWatchRecheckDelay }
                applyRateLimit(from: response, to: store)
                SlantAPIWatch.shared.noteOrderList(response, firstPage: true)
                let records = responseRecords(response)
                // A reply that ignored the sort is still a true list of statuses, so it is used once; the read stops.
                if orderWatchUpdatedSortCheck(records) == .notSorted { updatedReadAvailable = false }
                observations = orderWatchMergedObservations(newest, orderWatchObservations(records))
            } catch {
                guard stillCurrent() else { return orderWatchRecheckDelay }
                if orderWatchUpdatedReadRefused(error) {
                    updatedReadAvailable = false
                } else {
                    updatedReadFailed = true
                    noteFailure(error, store: store, token: token)
                }
            }
        }
        if !updatedReadFailed { failureLogged = false }
        record(observations, now: Date())
        return orderWatchInterval
    }

    private func conditions(_ store: StudioStore, token: String, now: Date, countInFlight: Bool = true) -> OrderWatchConditions {
        OrderWatchConditions(
            enabled: enabled, hasKey: store.hasKey, hasPlatform: !store.platformID.isEmpty, busy: store.busy,
            modalUIShown: store.menuCommandsBlockedByModalUI, inFlight: countInFlight && inFlight, accountPaused: pausedAccount == token,
            rateLimit: store.rateLimit, rateLimitAlreadyWaitedFor: rateLimitWaitedFor, backoffUntil: backoffUntil, now: now
        )
    }

    /// Only figures at least as new as Studio's: a reply may land after a newer one to the seller's own request.
    private func applyRateLimit(from response: APIResponse, to store: StudioStore) {
        if orderWatchShouldApplyRateLimit(current: store.rateLimit, incoming: response.rateLimit, now: Date()) {
            store.noteBackgroundRateLimit(from: response)
        }
    }

    private func noteFailure(_ error: Error, store: StudioStore, token: String) {
        let effect = orderWatchFailureEffect(error, now: Date())
        backoffUntil = effect.backoffUntil
        if effect.pauseAccount { pausedAccount = token; pausedAt = Date() }
        hold = orderWatchHold(after: effect)
        // One Activity line per run of failures (no order details), so a long outage doesn't fill Activity.
        if !failureLogged {
            failureLogged = true
            store.activities.insert(Activity(title: "Check orders for changes", detail: activityDetail(for: error), success: false), at: 0)
            store.activities = Array(store.activities.prefix(100))
        }
    }

    private func record(_ observations: [OrderWatchObservation], now: Date) {
        let applied = orderWatchApplying(observations, to: snapshot, now: now)
        snapshot = orderWatchPruned(applied.snapshot, now: now)
        save()
        if notify { post(orderWatchNotificationTexts(applied.transitions)) }
    }

    private func save() {
        guard let data = encodeOrderWatchSnapshot(snapshot) else { return }
        try? FileManager.default.createDirectory(at: StudioStore.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Show or Dismiss in Orders: the listed changes (or the given orders') count as seen.
    func acknowledge(ids: Set<String>? = nil) {
        let next = orderWatchAcknowledging(snapshot, ids: ids)
        guard next != snapshot else { return }
        snapshot = next
        save()
    }

    /// Settings › Forget Saved Statuses: deletes the file. The next check records statuses again without reporting them.
    func forgetSavedStatuses() {
        generation += 1
        snapshot = OrderWatchSnapshot()
        try? FileManager.default.removeItem(at: fileURL)
        // A waiting notification click named an order of the platform (or account) just forgotten.
        pendingOpen = nil
        selectionRequest = nil
    }

    // MARK: Dock

    private func updateDockBadge() {
        // Tests and other hosts without an application object have no Dock tile.
        guard let app = NSApp else { return }
        let label = orderWatchDockBadgeLabel(count: badgeCount, showOnDock: dockBadge)
        if app.dockTile.badgeLabel != label { app.dockTile.badgeLabel = label }
    }

    // MARK: Notifications

    /// Turning notifications on asks macOS for permission (only then, never at launch); turning them off never does.
    func setNotify(_ on: Bool) {
        guard on else { notify = false; return }
        guard orderWatchNotificationsAvailable(), !requestingPermission else { return }
        requestingPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                let watch = OrderWatch.shared
                watch.requestingPermission = false
                watch.notificationsDenied = !granted
                watch.notify = granted
            }
        }
    }

    private func refreshNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let denied = settings.authorizationStatus == .denied
            Task { @MainActor in OrderWatch.shared.notificationsDenied = denied }
        }
    }

    private func post(_ texts: [OrderWatchNotificationText]) {
        guard !texts.isEmpty, orderWatchNotificationsAvailable() else { return }
        let center = UNUserNotificationCenter.current()
        for text in texts {
            let content = UNMutableNotificationContent()
            content.title = text.title
            content.body = text.body
            // The order ID only, so a click can open the order; never a name, address or amount.
            if let id = text.orderID { content.userInfo = [orderWatchNotificationOrderIDKey: id] }
            center.add(UNNotificationRequest(identifier: text.identifier, content: content, trigger: nil))
        }
    }

    // MARK: Opening from a notification

    /// A click on a notification raises the main window at once, then opens Orders and selects the order it names. While
    /// a sheet, alert or dialog is shown in any window, or a request is running, only the window is raised: the click
    /// waits and is applied once they have closed, so it never replaces a review behind it. A later click replaces it.
    func openFromNotification(orderID: String?) {
        NSApp.activate()
        ExternalModelOpenQueue.shared.revealMainWindow()
        pendingOpen = PendingNotificationOpen(orderID: orderID)
        scheduleOpenDrain()
    }

    /// The Orders screen takes a selection request once; false when another has replaced it (or it was taken).
    func consumeSelection(_ request: OrderWatchSelectionRequest) -> Bool {
        guard selectionRequest == request else { return false }
        selectionRequest = nil
        return true
    }

    private func scheduleOpenDrain() {
        guard pendingOpen != nil, !openDrainScheduled else { return }
        openDrainScheduled = true
        Task { @MainActor in
            // Like Finder opens: a sheet closing while another opens is not mistaken for an idle window.
            try? await Task.sleep(nanoseconds: 400_000_000)
            openDrainScheduled = false
            drainPendingOpen()
        }
    }

    private func drainPendingOpen() {
        // Before a window (and so the store) exists, `attach` drains it.
        guard let pending = pendingOpen, let store else { return }
        guard externalOpenCanImport(storeSheetPresented: store.isPresentingSheet, appModalUIPresented: appIsPresentingModalUI(),
                                    errorShown: store.error != nil, busy: store.busy) else {
            scheduleOpenDrain()
            return
        }
        pendingOpen = nil
        store.destination = .orders
        guard let id = pending.orderID, store.hasKey else { return }
        if store.orders.contains(where: { $0.id == id }) {
            requestSelection(id)
            return
        }
        // Not loaded: reload the newest orders like Show, reading this one by ID if it isn't among them.
        let runGeneration = generation
        Task { [weak self] in
            guard await store.reloadOrdersIncludingWatched([id]), let self, runGeneration == self.generation,
                  store.orders.contains(where: { $0.id == id }) else { return }
            self.requestSelection(id)
        }
    }

    /// Selects the order in Orders; its change counts as seen, as after Show.
    private func requestSelection(_ id: String) {
        selectionRequest = OrderWatchSelectionRequest(orderID: id)
        acknowledge(ids: [id])
    }
}

// MARK: - Show and notification reloads

extension StudioStore {
    /// The banner's Show and a notification click: reloads the newest orders like Show All Orders (clearing any search
    /// and filter), then reads, one at a time, up to `orderWatchShowFetchLimit` of `ids` that aren't on that page
    /// (`orderWatchFetch`, read-only, never retried) and adds them to the loaded orders. The updated-first check finds
    /// changes to orders older than the newest 100, so they aren't always on the reloaded page. An order Slant says
    /// doesn't exist (404, or live Slant's 400 "Order not found.": `orderNotFoundError`) or that isn't on the default
    /// platform (an empty filtered list) is skipped; any other failure stops the reads and is shown as usual. True when
    /// the reload succeeded.
    func reloadOrdersIncludingWatched(_ ids: [String]) async -> Bool {
        guard await applyOrderFilter(OrderFilter()) else { return false }
        let missing = orderWatchIDsToFetch(wanted: ids, loaded: Set(orders.map(\.id)))
        guard !missing.isEmpty else { return true }
        // The platform the reloaded list belongs to; the reads stop if it changes.
        let platform = platformID
        _ = await run(missing.count == 1 ? "Get changed order" : "Get changed orders") {
            for id in missing {
                guard platformID == platform else { break }
                // With a default platform, a list read filtered by it (`orderWatchFetch`): an order on another
                // platform comes back as an empty list and is skipped, like one that doesn't exist.
                let fetch = orderWatchFetch(id: id, platformID: platform)
                let response: APIResponse
                do {
                    response = try await client.request("GET", path: fetch.path, query: fetch.query)
                } catch where orderNotFoundError(error) {
                    continue
                }
                noteBackgroundRateLimit(from: response)
                if fetch.listed {
                    SlantAPIWatch.shared.noteOrderList(response, firstPage: false)
                } else {
                    SlantAPIWatch.shared.noteOrder(mergeOrderDraftEnvelope(responseObject(response)))
                }
                // Only the order asked for, once, and only if it is on the platform listed (this holds `busy`, so no
                // reload can add it meanwhile).
                guard platformID == platform,
                      let record = orderWatchFetchedRecord(response, fetch: fetch, id: id, platformID: platform),
                      !orders.contains(where: { $0.id == id }) else { continue }
                orders.append(record)
            }
        }
        return true
    }
}

final class OrderWatchNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = OrderWatchNotificationDelegate()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        // Only a click on the notification itself opens anything.
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { completionHandler(); return }
        let orderID = orderWatchNotificationOrderID(response.notification.request.content.userInfo)
        Task { @MainActor in OrderWatch.shared.openFromNotification(orderID: orderID) }
        completionHandler()
    }
}
