import Foundation
import Combine

// MARK: - Saved products whose material is out of stock or gone (pure; tested in MaterialStockTests)

/// Why one of a saved product's materials can't be ordered now.
enum SavedProductMaterialProblemKind: Equatable {
    /// Slant lists the material with `available: false`.
    case outOfStock
    /// Slant's (non-empty) material list no longer holds the ID.
    case noLongerOffered
}

struct SavedProductMaterialProblem: Equatable {
    var materialID: String
    var kind: SavedProductMaterialProblemKind
    /// Slant's name for an out-of-stock material; nil when it is no longer listed.
    var materialName: String?
    /// The resolver's own wording (`savedProductOrderLines`), e.g. "PLA Black is out of stock."
    var reason: String
}

/// One saved product with at least one material problem.
struct SavedProductStockIssue: Equatable, Identifiable {
    var productID: UUID
    var productName: String
    /// In the product's item order, one per distinct material ID.
    var problems: [SavedProductMaterialProblem]
    var id: UUID { productID }
}

/// What Plinth knows about saved products' materials. Never "all well" without a list to check against.
enum SavedProductStockCheck: Equatable {
    /// No materials loaded, or Slant listed none: nothing was checked, so nothing is reported.
    case notChecked
    /// Checked against Slant's material list; empty when no saved product has a material problem.
    case checked([SavedProductStockIssue])

    var issues: [SavedProductStockIssue] {
        if case .checked(let issues) = self { return issues }
        return []
    }
}

/// Which saved products can't be ordered now because a material is out of stock or no longer offered. Uses the same
/// rule as `savedProductOrderLines` (the trimmed material ID against Slant's list; an empty list checks nothing), so it
/// never disagrees with the Saved Products list, the composer or Import Orders about materials. Other blockers (a model
/// not uploaded, a missing quantity) are left to those screens. Read-only.
func savedProductStockCheck(products: [SavedProduct], filaments: [Record]) -> SavedProductStockCheck {
    guard !filaments.isEmpty else { return .notChecked }
    var byID: [String: Record] = [:]
    for filament in filaments where byID[filament.id] == nil { byID[filament.id] = filament }
    var issues: [SavedProductStockIssue] = []
    for product in savedProductsSorted(products) {
        var problems: [SavedProductMaterialProblem] = []
        var seen: Set<String> = []
        for line in product.lines where line.type == "PRINT" {
            let materialID = line.filamentID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !materialID.isEmpty, !seen.contains(materialID) else { continue }
            if let filament = byID[materialID] {
                guard filamentAvailability(filament) == false else { continue }
                seen.insert(materialID)
                problems.append(SavedProductMaterialProblem(materialID: materialID, kind: .outOfStock, materialName: filament.name,
                                                            reason: "\(filament.name) is out of stock."))
            } else {
                seen.insert(materialID)
                let named = line.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = named.isEmpty ? "3D print" : named
                problems.append(SavedProductMaterialProblem(materialID: materialID, kind: .noLongerOffered, materialName: nil,
                                                            reason: "The material for “\(label)” is no longer offered."))
            }
        }
        if !problems.isEmpty {
            issues.append(SavedProductStockIssue(productID: product.id, productName: savedProductDisplayName(product), problems: problems))
        }
    }
    return .checked(issues)
}

/// Whether any saved product names a material, so there is something for the daily read to check.
func savedProductsNeedMaterials(_ products: [SavedProduct]) -> Bool {
    products.contains { product in
        product.lines.contains { $0.type == "PRINT" && !$0.filamentID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

// MARK: Notice text

/// Product names in the notice are the seller's own; very long ones are shortened so the notice stays a few lines.
let savedProductStockNameLimit = 60

private func stockNoticeName(_ name: String) -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count > savedProductStockNameLimit else { return "“\(trimmed)”" }
    return "“\(trimmed.prefix(savedProductStockNameLimit - 1))…”"
}

private func stockNoticeList(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items.last!
}

/// The notice's first line, or nil with nothing to report. One product names its reason in the resolver's words
/// ("(+1 more)" as in `savedProductCantOrderText`); up to `nameLimit` products are named; more are counted.
func savedProductStockNoticeHeadline(_ issues: [SavedProductStockIssue], nameLimit: Int = 3) -> String? {
    guard let first = issues.first else { return nil }
    if issues.count == 1 {
        let more = first.problems.count - 1
        let reason = first.problems.first?.reason ?? "a material is out of stock or no longer offered."
        return "Saved product \(stockNoticeName(first.productName)) can’t be ordered: \(reason)" + (more > 0 ? " (+\(more) more)" : "")
    }
    let because = "because a material is out of stock or no longer offered"
    let names = issues.prefix(nameLimit).map { stockNoticeName($0.productName) }
    if issues.count <= nameLimit {
        return "\(issues.count) saved products can’t be ordered \(because): \(stockNoticeList(names))."
    }
    return "\(issues.count) saved products can’t be ordered \(because), including \(stockNoticeList(names))."
}

/// The materials behind several products' problems: "Out of stock: PLA Black and PETG Red. 1 material is no longer
/// offered." Nil for a single product, whose headline already names its reason.
func savedProductStockNoticeMaterialsLine(_ issues: [SavedProductStockIssue], nameLimit: Int = 4) -> String? {
    guard issues.count > 1 else { return nil }
    var outOfStock: [String] = []
    var outOfStockIDs: Set<String> = []
    var goneIDs: Set<String> = []
    for problem in issues.flatMap(\.problems) {
        switch problem.kind {
        case .outOfStock:
            if outOfStockIDs.insert(problem.materialID).inserted { outOfStock.append(problem.materialName ?? problem.materialID) }
        case .noLongerOffered:
            goneIDs.insert(problem.materialID)
        }
    }
    var sentences: [String] = []
    if !outOfStock.isEmpty {
        let sorted = outOfStock.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let shown = Array(sorted.prefix(nameLimit))
        let others = sorted.count - shown.count
        let list = others > 0 ? shown.joined(separator: ", ") + " and \(others) " + (others == 1 ? "other" : "others") : stockNoticeList(shown)
        sentences.append("Out of stock: \(list).")
    }
    if !goneIDs.isEmpty {
        sentences.append(goneIDs.count == 1 ? "1 material is no longer offered." : "\(goneIDs.count) materials are no longer offered.")
    }
    return sentences.isEmpty ? nil : sentences.joined(separator: " ")
}

/// What the seller can do, and how old the materials are. Never a promise about when stock returns.
func savedProductStockNoticeAdvice(count: Int, materialsAt: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
    let products = count == 1 ? "this product" : "these products"
    var text = "To order \(products) from Slant, choose another material in Saved Products."
    if let materialsAt {
        let time = materialsAt.formatted(date: .omitted, time: .shortened)
        let when = calendar.isDate(materialsAt, inSameDayAs: now)
            ? "today at \(time)"
            : "\(materialsAt.formatted(.dateTime.day().month())) at \(time)"
        text += " Slant’s materials were read \(when)."
    }
    return text
}

// MARK: Dismissal

/// The product and material IDs behind the notice, as "<product UUID>|<material ID>". Only these are saved, so the
/// dismissal never holds a product's or material's name.
func savedProductStockPairs(_ issues: [SavedProductStockIssue]) -> Set<String> {
    Set(issues.flatMap { issue in issue.problems.map { "\(issue.productID.uuidString)|\($0.materialID)" } })
}

/// Shown unless every current pair was dismissed. A pair that wasn't (a new product, or another material) shows it
/// again; nothing to report shows nothing.
func savedProductStockNoticeVisible(current: Set<String>, dismissed: Set<String>) -> Bool {
    !current.isEmpty && !current.isSubset(of: dismissed)
}

/// The dismissal after a check: only pairs still affected are kept, so a material back in stock is forgotten and
/// shows the notice again if it runs out later, and nothing to report forgets the dismissal. Unchanged when nothing
/// was checked (materials not loaded yet, as at launch), so a relaunch keeps it.
func savedProductStockDismissalAfterCheck(_ check: SavedProductStockCheck, dismissed: Set<String>) -> Set<String> {
    guard case .checked(let issues) = check else { return dismissed }
    return dismissed.intersection(savedProductStockPairs(issues))
}

let savedProductStockDismissedDefaultsKey = "savedProductStockNoticeDismissed"
/// More pairs than this are kept for the session only (the saved list would be unreasonably large).
let savedProductStockDismissedMaxEntries = 5_000
private let savedProductStockPairMaxLength = 300

/// The saved dismissal, read leniently: only well-formed "<UUID>|<ID>" strings.
func decodeSavedProductStockDismissal(_ value: Any?) -> Set<String> {
    guard let strings = value as? [Any] else { return [] }
    var pairs: Set<String> = []
    for case let pair as String in strings.prefix(savedProductStockDismissedMaxEntries) {
        guard pair.count <= savedProductStockPairMaxLength, let bar = pair.firstIndex(of: "|"),
              UUID(uuidString: String(pair[..<bar])) != nil, pair.index(after: bar) < pair.endIndex,
              !pair.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { continue }
        pairs.insert(pair)
    }
    return pairs
}

/// What to write to preferences: the sorted pairs, nil to remove the key (nothing dismissed, or too many to save).
func encodeSavedProductStockDismissal(_ pairs: Set<String>) -> [String]? {
    guard !pairs.isEmpty, pairs.count <= savedProductStockDismissedMaxEntries else { return nil }
    return pairs.sorted()
}

// MARK: Which materials to judge by

/// The newer of the store's materials (launch, Refresh, Models and the composers) and the daily read's own snapshot.
/// The snapshot never replaces the store's list, so an open composer, picker or estimate keeps the list it was using.
enum MaterialStockSource: Equatable { case store, snapshot }

func materialStockSource(storeLoadedAt: Date?, storeHasMaterials: Bool, snapshotAt: Date?) -> MaterialStockSource {
    guard let snapshotAt else { return .store }
    guard storeHasMaterials, let storeLoadedAt else { return .snapshot }
    return snapshotAt > storeLoadedAt ? .snapshot : .store
}

// MARK: - The daily materials read

/// Seconds between the read's local checks of whether a read is due (no request unless one is).
let materialStockWatchTickInterval: TimeInterval = 15 * 60
/// Never in the first minute after launch, when the main window's own refresh reads materials anyway.
let materialStockWatchFirstCheckDelay: TimeInterval = 60
/// At most one read per this long, and none while Plinth has materials at least this new.
let materialStockWatchMinimumInterval: TimeInterval = 24 * 3600

enum MaterialStockWatchSkip: Equatable {
    case noKey, otherService, nothingToCheck, tooSoonAfterLaunch, notDue
    /// One of the order watch's reasons: busy, modal UI, in flight, paused after 401/403, or the rate limit.
    case order(OrderWatchSkip)
}

struct MaterialStockWatchConditions {
    var hasKey = true
    var slantIsPrintService = true
    var productsNeedMaterials = true
    var launchedAt = Date.distantPast
    var lastAttemptAt: Date?
    /// The newest materials Plinth holds, from the store or an earlier read.
    var newestMaterialsAt: Date?
    var busy = false
    var modalUIShown = false
    var inFlight = false
    var accountPaused = false
    var rateLimit: RateLimitInfo?
    var rateLimitAlreadyWaitedFor: RateLimitInfo?
    var backoffUntil: Date?
    var now = Date()
}

/// Why the daily read doesn't run now, or nil to send it. Due only once a day: 24 hours after the last attempt
/// (successful or not, so nothing is retried before then) and while Plinth's newest materials are 24 hours old. Then the
/// order watch's rules: never while a request runs or anything modal is shown, paused after a 401/403, waiting after a
/// 429, and leaving a low allowance to the seller.
func materialStockWatchSkipReason(_ c: MaterialStockWatchConditions) -> MaterialStockWatchSkip? {
    if !c.hasKey { return .noKey }
    if !c.slantIsPrintService { return .otherService }
    if !c.productsNeedMaterials { return .nothingToCheck }
    if c.now.timeIntervalSince(c.launchedAt) < materialStockWatchFirstCheckDelay { return .tooSoonAfterLaunch }
    if let last = c.lastAttemptAt, c.now.timeIntervalSince(last) < materialStockWatchMinimumInterval { return .notDue }
    if let newest = c.newestMaterialsAt, c.now.timeIntervalSince(newest) < materialStockWatchMinimumInterval { return .notDue }
    let order = OrderWatchConditions(
        enabled: true, hasKey: true, hasPlatform: true, busy: c.busy, modalUIShown: c.modalUIShown, inFlight: c.inFlight,
        accountPaused: c.accountPaused, rateLimit: c.rateLimit, rateLimitAlreadyWaitedFor: c.rateLimitAlreadyWaitedFor,
        backoffUntil: c.backoffUntil, now: c.now)
    return orderWatchSkipReason(order).map(MaterialStockWatchSkip.order)
}

/// Seconds until the read looks again: soon after a rate-limit reset, else the next tick.
func materialStockWatchNextDelay(after skip: MaterialStockWatchSkip?, now: Date) -> TimeInterval {
    if case .order(.rateLimited(let until?))? = skip {
        return min(materialStockWatchTickInterval, max(5, until.timeIntervalSince(now) + 2))
    }
    return materialStockWatchTickInterval
}

/// Activity's line for a read: counts only, never a product or material name.
func materialStockWatchActivityDetail(_ check: SavedProductStockCheck) -> String {
    switch check {
    case .notChecked: return "Slant listed no materials; nothing checked"
    case .checked(let issues):
        if issues.isEmpty { return "No saved product affected" }
        return issues.count == 1 ? "1 saved product can’t be ordered" : "\(issues.count) saved products can’t be ordered"
    }
}

/// Saved products' material stock: the notice's dismissal and an optional quiet daily re-read of Slant's materials for
/// a seller who leaves Plinth open for days. The read is `GET /filaments` only, read-only, through the shared client and
/// never `store.run`: it never sets `busy`, never runs while a request runs or anything modal is shown, stops at a low
/// rate limit, waits after a 429, pauses after a 401/403, is never retried before its next scheduled time, applies
/// rate-limit figures only when not older than Plinth's, and keeps its own snapshot (memory only) rather than replacing
/// the store's materials. No notifications, badges or alerts; Activity gets counts only.
@MainActor final class MaterialStockWatch: ObservableObject {
    static let shared = MaterialStockWatch()

    /// The daily read's materials and when they were read; memory only, forgotten with the key.
    @Published private(set) var snapshot: (records: [Record], at: Date)?
    /// Product and material ID pairs the seller dismissed (`savedProductStockPairs`).
    @Published private(set) var dismissed: Set<String> = decodeSavedProductStockDismissal(
        UserDefaults.standard.array(forKey: savedProductStockDismissedDefaultsKey))

    private weak var store: StudioStore?
    private var loop: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []
    private let launchedAt = Date()
    private var lastAttemptAt: Date?
    private var inFlight = false
    private var backoffUntil: Date?
    private var rateLimitWaitedFor: RateLimitInfo?
    private var pausedAccount: String?
    private var pausedAt: Date?

    func attach(_ store: StudioStore) {
        guard self.store !== store else { return }
        self.store = store
        observers = []
        // Another key, or Disconnect, may be another account: the snapshot, the dismissal and any pause are forgotten.
        store.$apiKey
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.forgetAccount() } }
            .store(in: &observers)
        loop?.cancel()
        loop = Task { [weak self] in
            var delay = materialStockWatchFirstCheckDelay
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                delay = await self.tick()
            }
        }
    }

    /// The materials the notice judges by: the newer of the store's and the snapshot.
    func materials(for store: StudioStore) -> (records: [Record], at: Date?) {
        switch materialStockSource(storeLoadedAt: store.filamentsLoadedAt, storeHasMaterials: !store.filaments.isEmpty,
                                   snapshotAt: snapshot?.at) {
        case .store: return (store.filaments, store.filamentsLoadedAt)
        case .snapshot: return (snapshot?.records ?? [], snapshot?.at)
        }
    }

    /// Dismiss: hidden until a product or material not in `pairs` is affected.
    func dismiss(_ pairs: Set<String>) {
        setDismissed(dismissed.union(pairs))
    }

    /// Keeps only pairs still affected, after a real check (`savedProductStockDismissalAfterCheck`).
    func noteCheck(_ check: SavedProductStockCheck) {
        let next = savedProductStockDismissalAfterCheck(check, dismissed: dismissed)
        if next != dismissed { setDismissed(next) }
    }

    private func setDismissed(_ pairs: Set<String>) {
        dismissed = pairs
        if let saved = encodeSavedProductStockDismissal(pairs) {
            UserDefaults.standard.set(saved, forKey: savedProductStockDismissedDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: savedProductStockDismissedDefaultsKey)
        }
    }

    private func forgetAccount() {
        snapshot = nil
        lastAttemptAt = nil
        backoffUntil = nil
        rateLimitWaitedFor = nil
        pausedAccount = nil
        setDismissed([])
    }

    private func accountToken(_ store: StudioStore) -> String {
        "\(store.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).hashValue)"
    }

    private func conditions(_ store: StudioStore, token: String, now: Date) -> MaterialStockWatchConditions {
        let newest = [store.filaments.isEmpty ? nil : store.filamentsLoadedAt, snapshot?.at].compactMap { $0 }.max()
        return MaterialStockWatchConditions(
            hasKey: store.hasKey, slantIsPrintService: PrintServiceChoice.shared.service == .slant,
            productsNeedMaterials: savedProductsNeedMaterials(store.savedProducts), launchedAt: launchedAt,
            lastAttemptAt: lastAttemptAt, newestMaterialsAt: newest, busy: store.busy,
            modalUIShown: store.menuCommandsBlockedByModalUI, inFlight: inFlight, accountPaused: pausedAccount == token,
            rateLimit: store.rateLimit, rateLimitAlreadyWaitedFor: rateLimitWaitedFor, backoffUntil: backoffUntil, now: now)
    }

    /// One look; returns the delay until the next.
    private func tick() async -> TimeInterval {
        guard let store else { return materialStockWatchTickInterval }
        let now = Date()
        let token = accountToken(store)
        if let paused = pausedAccount, paused != token || now.timeIntervalSince(pausedAt ?? now) >= orderWatchAccountPause {
            pausedAccount = nil
        }
        if let skip = materialStockWatchSkipReason(conditions(store, token: token, now: now)) {
            if skip == .order(.rateLimited(until: nil)) { rateLimitWaitedFor = store.rateLimit }
            return materialStockWatchNextDelay(after: skip, now: now)
        }
        rateLimitWaitedFor = nil
        backoffUntil = nil
        lastAttemptAt = now
        inFlight = true
        defer { inFlight = false }
        let client = store.client
        do {
            let response = try await client.request("GET", path: "/filaments")
            // A key change while the read was out discards it.
            guard accountToken(store) == token else { return materialStockWatchTickInterval }
            if orderWatchShouldApplyRateLimit(current: store.rateLimit, incoming: response.rateLimit, now: Date()) {
                store.noteBackgroundRateLimit(from: response)
            }
            let records = responseRecords(response)
            snapshot = (records, Date())
            let check = savedProductStockCheck(products: store.savedProducts, filaments: records)
            log(store, detail: materialStockWatchActivityDetail(check), success: true)
        } catch {
            guard accountToken(store) == token else { return materialStockWatchTickInterval }
            let effect = orderWatchFailureEffect(error, now: Date())
            backoffUntil = effect.backoffUntil
            if effect.pauseAccount { pausedAccount = token; pausedAt = Date() }
            log(store, detail: activityDetail(for: error), success: false)
        }
        return materialStockWatchTickInterval
    }

    private func log(_ store: StudioStore, detail: String, success: Bool) {
        store.activities.insert(Activity(title: "Check saved products’ materials", detail: detail, success: success), at: 0)
        store.activities = Array(store.activities.prefix(100))
    }
}
