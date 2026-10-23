import Foundation
import AppKit
import UserNotifications

// MARK: - Order watch: settings and limits

/// Settings › Advanced › Check orders while Slant Studio is open (on unless turned off).
let orderWatchEnabledDefaultsKey = "orderWatchEnabled"
/// Settings › Advanced › Notify me about order changes (off until turned on, which asks macOS for permission).
let orderWatchNotifyDefaultsKey = "orderWatchNotify"
/// Order IDs, statuses and times only, in Application Support/SlantStudio.
let orderWatchFileName = "order-watch.json"
/// Time between checks: 15 reads an hour, well inside Slant's 100 a minute.
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

/// Changes worth a sidebar badge and a notification: the order needs attention, or it reached the customer's door.
let orderWatchNotableStatuses: Set<String> = ["PAYMENT_ERROR", "IN_REVIEW", "CANCELED", "SHIPPED", "DELIVERED"]
private let orderWatchAttentionOrder = ["PAYMENT_ERROR", "IN_REVIEW", "CANCELED", "DELIVERED", "SHIPPED"]

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

/// The order-level status of each listed order. Item statuses (a draft's items say PROCESSING) are ignored, as are
/// rows without an ID or a text status; the first row wins when an ID repeats.
func orderWatchObservations(_ records: [Record]) -> [OrderWatchObservation] {
    var seen = Set<String>()
    var result: [OrderWatchObservation] = []
    for record in records {
        let order = orderObject(record.values)
        let id = record.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validOrderWatchID(id), let status = normalizedOrderWatchStatus(order["status"]), seen.insert(id).inserted else { continue }
        result.append(OrderWatchObservation(id: id, status: status, number: String(orderNumber(order).prefix(40))))
    }
    return result
}

/// Whether a change is listed under "Since you last looked". Placing a draft is the seller's own action, so
/// Draft → Paid isn't reported (later progress, or a payment problem, is).
func orderWatchChangeIsReported(from: String, to: String) -> Bool {
    guard from != to else { return false }
    return !(from == "DRAFT" && to == "PAID")
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
            entry.changedAt = now
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

/// The sidebar badge: unseen changes that need attention or reached the customer. Production progress is listed in
/// Orders but doesn't badge, so a busy print queue doesn't keep a number on the sidebar.
func orderWatchBadgeCount(_ changes: [OrderWatchChange]) -> Int {
    changes.filter { orderWatchNotableStatuses.contains($0.to) }.count
}

/// Unseen changes counted by new status: attention first, then shipped/delivered, then progress in Slant's order.
func orderWatchSummaryGroups(_ changes: [OrderWatchChange]) -> [(status: String, count: Int)] {
    var counts: [String: Int] = [:]
    for change in changes { counts[change.to, default: 0] += 1 }
    func rank(_ status: String) -> Int {
        if let index = orderWatchAttentionOrder.firstIndex(of: status) { return index }
        if let index = orderStatusFilterOptions.firstIndex(of: status) { return 100 + index }
        return 1000
    }
    return counts.map { (status: $0.key, count: $0.value) }.sorted { lhs, rhs in
        let l = rank(lhs.status), r = rank(rhs.status)
        return l != r ? l < r : lhs.status < rhs.status
    }
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
}

private func orderWatchNotificationPhrase(_ status: String) -> String {
    switch status {
    case "SHIPPED": "has shipped"
    case "DELIVERED": "was delivered"
    case "CANCELED": "was cancelled"
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
            body: "\(orderStatusTitle(transition.from)) → \(orderStatusTitle(transition.to))"
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

/// Checks the newest orders on the default platform every few minutes while the app is open, and remembers each
/// order's status so changes can be listed in Orders, badged in the sidebar and, if asked for, notified.
/// Read-only: one GET /orders per check through the shared client, never `store.run` (it never sets `busy`), never the
/// unknown-outcome lock, never retried before the next scheduled check, and it never replaces `store.orders`.
@MainActor final class OrderWatch: ObservableObject {
    static let shared = OrderWatch()

    @Published private(set) var snapshot = OrderWatchSnapshot()
    @Published var enabled: Bool = UserDefaults.standard.object(forKey: orderWatchEnabledDefaultsKey) as? Bool ?? true {
        didSet {
            guard enabled != oldValue else { return }
            UserDefaults.standard.set(enabled, forKey: orderWatchEnabledDefaultsKey)
            generation += 1
            if enabled { startLoop() } else { loop?.cancel(); loop = nil }
        }
    }
    @Published private(set) var notify: Bool = UserDefaults.standard.bool(forKey: orderWatchNotifyDefaultsKey) {
        didSet { UserDefaults.standard.set(notify, forKey: orderWatchNotifyDefaultsKey) }
    }
    /// macOS has notifications for Slant Studio turned off (or permission was refused).
    @Published private(set) var notificationsDenied = false
    @Published private(set) var requestingPermission = false

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
        if orderWatchNotificationsAvailable() {
            UNUserNotificationCenter.current().delegate = OrderWatchNotificationDelegate.shared
            if notify { refreshNotificationPermission() }
        }
        if enabled { startLoop() }
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
        }
        let conditions = OrderWatchConditions(
            enabled: enabled, hasKey: store.hasKey, hasPlatform: !store.platformID.isEmpty, busy: store.busy,
            modalUIShown: store.menuCommandsBlockedByModalUI, inFlight: inFlight, accountPaused: pausedAccount == token,
            rateLimit: store.rateLimit, rateLimitAlreadyWaitedFor: rateLimitWaitedFor, backoffUntil: backoffUntil, now: now
        )
        if let skip = orderWatchSkipReason(conditions) {
            if skip == .rateLimited(until: nil) { rateLimitWaitedFor = store.rateLimit }
            return orderWatchNextDelay(after: skip, now: now)
        }
        rateLimitWaitedFor = nil
        backoffUntil = nil
        let runGeneration = generation
        let query = orderFilterQueryItems(OrderFilter(), page: 1, limit: listPageSize, platformID: store.platformID)
        let client = store.client
        inFlight = true
        defer { inFlight = false }
        do {
            let response = try await client.request("GET", path: "/orders", query: query)
            // A key or platform change, Forget or turning the watch off while this was in flight discards it.
            guard runGeneration == generation, enabled, accountToken(store) == token else { return orderWatchRecheckDelay }
            store.noteBackgroundRateLimit(from: response)
            failureLogged = false
            record(orderWatchObservations(responseRecords(response)), now: Date())
        } catch {
            guard runGeneration == generation, enabled, accountToken(store) == token else { return orderWatchRecheckDelay }
            let effect = orderWatchFailureEffect(error, now: Date())
            backoffUntil = effect.backoffUntil
            if effect.pauseAccount { pausedAccount = token; pausedAt = Date() }
            // One Activity line per run of failures (no order details), so a long outage doesn't fill Activity.
            if !failureLogged {
                failureLogged = true
                store.activities.insert(Activity(title: "Check orders for changes", detail: activityDetail(for: error), success: false), at: 0)
                store.activities = Array(store.activities.prefix(100))
            }
        }
        return orderWatchInterval
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
            center.add(UNNotificationRequest(identifier: text.identifier, content: content, trigger: nil))
        }
    }

    /// Clicking a notification opens Orders, unless a sheet, alert or dialog is up (then the app is only brought forward).
    fileprivate func openOrdersFromNotification() {
        NSApp.activate()
        guard let store, !store.menuCommandsBlockedByModalUI else { return }
        store.destination = .orders
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
        Task { @MainActor in OrderWatch.shared.openOrdersFromNotification() }
        completionHandler()
    }
}
