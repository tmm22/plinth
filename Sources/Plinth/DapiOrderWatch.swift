import Foundation
import UserNotifications

// The 3DAPI order watch: while 3DAPI is the print service and a key is saved (`setActive(true)`), a read-only check
// every 4 minutes learns which orders changed status, for the sidebar's Orders badge and, when the seller has turned
// order notifications on, a notification. Memory only: nothing about 3DAPI is saved on disk, so the first check of
// every session records the orders silently. It never sets a store's `busy`, never runs while a 3DAPI order write
// waits for its reply or anything modal is shown, and never touches the Dock badge (Slant's order watch owns it) or
// Activity.

/// Time between checks.
let dapiOrderWatchInterval: TimeInterval = 4 * 60
/// The first check after the watch starts waits a little, so it never races the Orders screen's own first load.
let dapiOrderWatchFirstCheckDelay: TimeInterval = 20
/// How soon a skipped check (busy, modal, no key) is looked at again; no request is made.
let dapiOrderWatchRecheckDelay: TimeInterval = 30
/// At most this many by-ID reads per check, for orders that left the open-orders list.
let dapiOrderWatchFetchLimit = 10
/// Time between those reads.
let dapiOrderWatchFetchSpacing: TimeInterval = 0.6
/// Wait after a 429 without a usable retry time, and the longest wait honoured.
let dapiOrderWatchMinimumBackoff: TimeInterval = 60
let dapiOrderWatchMaximumBackoff: TimeInterval = 3600
/// Orders remembered at most (final ones are forgotten first).
let dapiOrderWatchMaxEntries = 2000
/// The notification `userInfo` key for the 3DAPI order ID, the only thing a notification carries besides its text.
let dapiOrderWatchNotificationOrderIDKey = "dapiOrderID"

/// The statuses the check lists: every documented status that isn't final. `shipped` is included: completed or
/// returned may follow.
let dapiOrderWatchListedStatuses: [DapiOrderStatus] = DapiOrderStatus.known.filter { !$0.isFinal }

/// Changes worth the badge and a notification.
let dapiOrderWatchNotableStatuses: Set<DapiOrderStatus> = [.shipped, .onHold, .rejected, .returned, .cancelled]

/// The list query each check sends (page 1 only, no lines).
func dapiOrderWatchQuery() -> DapiOrderListQuery {
    DapiOrderListQuery(statuses: dapiOrderWatchListedStatuses, limit: 100, expandItems: false)
}

/// A status as compared between checks: 3DAPI's word, trimmed and lower-cased, so a repeated word in another case or
/// with spaces is no change.
func dapiOrderWatchStatusKey(_ status: DapiOrderStatus) -> String {
    status.raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
}

/// What the watch remembers about one order. Memory only.
struct DapiOrderWatchEntry: Equatable {
    var status: DapiOrderStatus
    /// For notification text only.
    var number: String
    /// When a by-ID read last looked at it (to share the reads fairly between orders).
    var lastFetched: Date?
}

struct DapiOrderWatchState: Equatable {
    var orders: [String: DapiOrderWatchEntry] = [:]
    /// Orders whose status changed to a notable one since the seller last viewed Orders, with that status.
    var unseen: [String: DapiOrderStatus] = [:]
}

/// A notable change found by a check.
struct DapiOrderWatchNotice: Equatable, Sendable {
    let orderID: String
    let number: String
    let status: DapiOrderStatus

    var title: String { "3DAPI order update" }
    var body: String { "3DAPI order \(number.isEmpty ? "" : number + " ")is now \(status.label.lowercased())." }
    /// One notification per order and status, so the same change is never shown twice.
    var identifier: String { "dapi-order-\(orderID)-\(dapiOrderWatchStatusKey(status))" }
}

/// A 3DAPI order ID fit for a notification's `userInfo`: `ord_` then letters and digits.
func dapiOrderIDIsSafe(_ id: String) -> Bool { dapiIDIsSafe(id, prefix: "ord_") }

/// The order ID a clicked notification carries, validated; nil for anything else.
func dapiOrderWatchNotificationOrderID(_ userInfo: [AnyHashable: Any]) -> String? {
    guard let id = userInfo[dapiOrderWatchNotificationOrderIDKey] as? String, dapiOrderIDIsSafe(id) else { return nil }
    return id
}

/// Records what a check saw. An order seen for the first time is recorded silently; a change to a notable status is
/// added to `unseen` and returned as a notice (once: the same status again is no change); a change away from a
/// notable status removes it from `unseen`. Orders with unsafe IDs are ignored.
func dapiOrderWatchApply(_ observed: [DapiOrder], to state: inout DapiOrderWatchState) -> [DapiOrderWatchNotice] {
    var notices: [DapiOrderWatchNotice] = []
    for order in observed where dapiOrderIDIsSafe(order.id) {
        let number = String(order.number.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        guard var entry = state.orders[order.id] else {
            state.orders[order.id] = DapiOrderWatchEntry(status: order.status, number: number)
            continue
        }
        let changed = dapiOrderWatchStatusKey(entry.status) != dapiOrderWatchStatusKey(order.status)
        entry.status = order.status
        if !number.isEmpty { entry.number = number }
        state.orders[order.id] = entry
        guard changed else { continue }
        if dapiOrderWatchNotableStatuses.contains(order.status) {
            state.unseen[order.id] = order.status
            notices.append(DapiOrderWatchNotice(orderID: order.id, number: entry.number, status: order.status))
        } else {
            state.unseen[order.id] = nil
        }
    }
    return notices
}

/// Orders the watch knew as not final that aren't in this check's list, to read by ID: least recently read first
/// (never read first), then by ID, at most `limit`.
func dapiOrderWatchDropped(_ state: DapiOrderWatchState, listedIDs: Set<String>, limit: Int = dapiOrderWatchFetchLimit) -> [String] {
    let candidates = state.orders.filter { !$0.value.status.isFinal && !listedIDs.contains($0.key) }
    return candidates.sorted { lhs, rhs in
        let left = lhs.value.lastFetched ?? .distantPast, right = rhs.value.lastFetched ?? .distantPast
        return left != right ? left < right : lhs.key < rhs.key
    }
    .prefix(max(0, limit)).map(\.key)
}

/// Keeps the memory bounded: final orders go first (oldest-read first, then by ID), then the rest by ID.
func dapiOrderWatchPruned(_ state: DapiOrderWatchState, limit: Int = dapiOrderWatchMaxEntries) -> DapiOrderWatchState {
    guard state.orders.count > limit else { return state }
    var result = state
    let ordered = state.orders.sorted { lhs, rhs in
        if lhs.value.status.isFinal != rhs.value.status.isFinal { return lhs.value.status.isFinal }
        return lhs.key < rhs.key
    }
    for (id, _) in ordered.prefix(state.orders.count - limit) {
        result.orders[id] = nil
        result.unseen[id] = nil
    }
    return result
}

/// What a failed read means for the watch.
enum DapiOrderWatchFailure: Equatable {
    /// 429: wait until this time.
    case backOff(until: Date)
    /// 401/403: stop until `setActive` is called again (a new key, or 3DAPI chosen again).
    case pause
    /// 404 on a by-ID read: the order isn't this account's (any more); forget it.
    case forget
    /// No key or anything else: try at the next check.
    case skip
}

func dapiOrderWatchFailure(_ error: Error, now: Date) -> DapiOrderWatchFailure {
    guard let error = error as? DapiError else { return .skip }
    switch error {
    case .rateLimited(_, let retryAt):
        let wait = retryAt.map { $0.timeIntervalSince(now) } ?? dapiOrderWatchMinimumBackoff
        return .backOff(until: now.addingTimeInterval(min(max(wait, dapiOrderWatchMinimumBackoff), dapiOrderWatchMaximumBackoff)))
    case .refused(let status, _, _) where status == 401 || status == 403:
        return .pause
    case .refused(404, _, _):
        return .forget
    default:
        return .skip
    }
}

/// Everything the watch needs from the app, injected so tests can drive `tick()` with stubs.
struct DapiOrderWatchEnvironment {
    var makeClient: @MainActor () throws -> any DapiOrdering
    /// Whether a check may run now: no 3DAPI order write waiting, no order sheet open, nothing modal shown, and the
    /// seller hasn't turned order checks off in Settings › Advanced.
    var canCheck: @MainActor () -> Bool
    var now: () -> Date
    var sleep: @Sendable (TimeInterval) async throws -> Void
    /// Posts notices when the seller allowed notifications (never asks for permission).
    var notify: @MainActor ([DapiOrderWatchNotice]) -> Void

    @MainActor static var live: DapiOrderWatchEnvironment {
        DapiOrderWatchEnvironment(
            makeClient: { try DapiConnection.shared.currentOrderingClient() },
            canCheck: {
                let session = DapiOrderSession.shared
                let enabled = UserDefaults.standard.object(forKey: orderWatchEnabledDefaultsKey) as? Bool ?? true
                return enabled && session.writesInFlight == 0 && session.openSheets == 0 && !appIsPresentingModalUI()
            },
            now: Date.init,
            sleep: { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
            notify: { dapiOrderWatchPostNotifications($0) })
    }
}

/// Posts the notices only when order notifications are on in Settings (Slant's order-watch preference) and macOS
/// already allows them. Permission is never requested here. Number and status only; `userInfo` holds only the ID.
@MainActor func dapiOrderWatchPostNotifications(_ notices: [DapiOrderWatchNotice]) {
    guard !notices.isEmpty, UserDefaults.standard.bool(forKey: orderWatchNotifyDefaultsKey),
          orderWatchNotificationsAvailable() else { return }
    UNUserNotificationCenter.current().getNotificationSettings { settings in
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for notice in notices where dapiOrderIDIsSafe(notice.orderID) {
            let content = UNMutableNotificationContent()
            content.title = notice.title
            content.body = notice.body
            content.userInfo = [dapiOrderWatchNotificationOrderIDKey: notice.orderID]
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.identifier, content: content, trigger: nil))
        }
    }
}

@MainActor final class DapiOrderWatch: ObservableObject {
    static let shared = DapiOrderWatch()

    /// Orders whose status changed to one worth a look since the seller last viewed Orders (the sidebar badge).
    @Published private(set) var badgeCount = 0
    /// Whether checks are paused after 3DAPI refused the key (401/403), until `setActive` is called again.
    @Published private(set) var paused = false

    private(set) var state = DapiOrderWatchState() {
        didSet { if badgeCount != state.unseen.count { badgeCount = state.unseen.count } }
    }
    private(set) var active = false
    private(set) var backoffUntil: Date?
    private var loop: Task<Void, Never>?
    private var generation = 0
    private var inFlight = false
    private let environment: DapiOrderWatchEnvironment?

    /// `environment` nil uses the app's (`DapiOrderWatchEnvironment.live`); `startsLoop` false lets tests call `tick()`.
    init(environment: DapiOrderWatchEnvironment? = nil, startsLoop: Bool = true) {
        self.environment = environment
        self.startsLoop = startsLoop
    }
    private let startsLoop: Bool

    private var env: DapiOrderWatchEnvironment { environment ?? .live }

    /// Starts (true) or stops (false) watching; called when 3DAPI becomes or stops being the print service, and
    /// when the key is saved or removed. Stopping forgets everything (the next start records orders silently again);
    /// starting again while active lifts a pause after a refused key.
    func setActive(_ active: Bool) {
        generation += 1
        loop?.cancel()
        loop = nil
        inFlight = false
        paused = false
        if active {
            if !self.active { backoffUntil = nil }
            self.active = true
            if startsLoop { startLoop() }
        } else {
            self.active = false
            backoffUntil = nil
            state = DapiOrderWatchState()
        }
    }

    /// The seller viewed the 3DAPI Orders list: the badge clears (statuses stay remembered).
    func ordersViewed() {
        guard !state.unseen.isEmpty else { return }
        state.unseen = [:]
    }

    private func startLoop() {
        loop = Task { [weak self] in
            var delay = dapiOrderWatchFirstCheckDelay
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                delay = await self.tick()
            }
        }
    }

    /// One check. Returns the delay before the next. Read-only: page 1 of the open orders, then up to
    /// `dapiOrderWatchFetchLimit` by-ID reads of orders that left it, paced. A result that arrives after
    /// `setActive` was called again is dropped.
    @discardableResult
    func tick() async -> TimeInterval {
        let env = self.env
        guard active, !paused, !inFlight else { return dapiOrderWatchInterval }
        let now = env.now()
        if let until = backoffUntil, until > now { return min(dapiOrderWatchInterval, max(1, until.timeIntervalSince(now))) }
        backoffUntil = nil
        guard env.canCheck() else { return dapiOrderWatchRecheckDelay }
        guard let client = try? env.makeClient() else { return dapiOrderWatchRecheckDelay }
        let runGeneration = generation
        inFlight = true
        defer { if runGeneration == generation { inFlight = false } }

        let page: DapiOrderPage
        do {
            page = try await client.orders(dapiOrderWatchQuery())
        } catch {
            guard runGeneration == generation else { return dapiOrderWatchInterval }
            return handle(error, now: env.now())
        }
        guard runGeneration == generation else { return dapiOrderWatchInterval }
        var working = state
        var notices = dapiOrderWatchApply(page.orders, to: &working)
        state = working

        // Orders that were open and aren't listed any more changed status (or the list was longer than a page).
        let dropped = dapiOrderWatchDropped(state, listedIDs: Set(page.orders.map(\.id)))
        var next = dapiOrderWatchInterval
        for id in dropped {
            guard runGeneration == generation, env.canCheck() else { break }
            do {
                // Paced after the list read and between reads.
                try await env.sleep(dapiOrderWatchFetchSpacing)
                guard runGeneration == generation else { return dapiOrderWatchInterval }
                let order = try await client.order(id: id)
                guard runGeneration == generation else { return dapiOrderWatchInterval }
                var updated = state
                updated.orders[id]?.lastFetched = env.now()
                // Only the order asked for: a reply naming another ID is ignored.
                if order.id == id { notices += dapiOrderWatchApply([order], to: &updated) }
                state = updated
            } catch {
                guard runGeneration == generation else { return dapiOrderWatchInterval }
                if dapiIsCancellation(error) { return dapiOrderWatchInterval }
                if dapiOrderWatchFailure(error, now: env.now()) == .forget {
                    var updated = state
                    updated.orders[id] = nil
                    updated.unseen[id] = nil
                    state = updated
                    continue
                }
                var updated = state
                updated.orders[id]?.lastFetched = env.now()
                state = updated
                next = handle(error, now: env.now())
                break
            }
        }
        guard runGeneration == generation else { return dapiOrderWatchInterval }
        state = dapiOrderWatchPruned(state)
        if !notices.isEmpty { env.notify(notices) }
        return next
    }

    private func handle(_ error: Error, now: Date) -> TimeInterval {
        switch dapiOrderWatchFailure(error, now: now) {
        case .backOff(let until):
            backoffUntil = until
            return min(dapiOrderWatchInterval, max(1, until.timeIntervalSince(now)))
        case .pause:
            paused = true
            loop?.cancel()
            loop = nil
            return dapiOrderWatchInterval
        case .forget, .skip:
            return dapiOrderWatchInterval
        }
    }
}
