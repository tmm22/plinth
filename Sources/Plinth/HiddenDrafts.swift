import Foundation

// MARK: - Hidden drafts (local only)
//
// Slant refuses to cancel or delete drafts, so test and abandoned drafts stay in Orders for good. Hide Draft keeps a
// draft out of the Orders list on this Mac only: nothing is sent to Slant, and the draft still exists there (it still
// costs nothing unless placed). Only order IDs are saved (`hidden-drafts.json` in the support folder, lenient and
// capped), and they are forgotten on Disconnect and when the key changes.
//
// A hidden ID hides a row only while Slant's raw status is DRAFT, so a draft paid elsewhere (or through the API
// Workbench) shows again. Like the platform check (`ordersShownOnPlatform`), hiding applies only where the Orders list
// shows rows: the rows themselves and what comes from them (Export Orders, Review Drafts One by One, Pay Several
// Drafts' candidates). It never filters `store.orders`, the review sheets, reloads that lift locks, the Workbench,
// Look for Draft's marker match, the import ledger or any duplicate check, and an order under the pay/cancel lock is
// never hidden. Pay Several Drafts counts a hidden draft's marketplace order as held (`batchPayDuplicateExclusions`'s
// `hiddenKeys`), so hiding one of two drafts for a sale never lets the batch pay the other unchecked.

let hiddenDraftsFileName = "hidden-drafts.json"
/// At most this many IDs are kept; the oldest hides drop off first (that draft shows again).
let hiddenDraftsMaxEntries = 500
private let hiddenDraftsMaxFileBytes = 256 * 1024
private let hiddenDraftsMaxIDLength = 128

/// An ID worth saving: non-empty, bounded, and printable without spaces (Slant's IDs are short tokens).
func hiddenDraftIDIsValid(_ id: String) -> Bool {
    guard !id.isEmpty, id.count <= hiddenDraftsMaxIDLength else { return false }
    return id.unicodeScalars.allSatisfy { scalar in
        !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
    }
}

/// The saved list with `id` added last (an existing entry moves to the end), capped by dropping the oldest.
func hiddenDraftsAdding(_ ids: [String], id: String, cap: Int = hiddenDraftsMaxEntries) -> [String] {
    guard hiddenDraftIDIsValid(id) else { return ids }
    let next = ids.filter { $0 != id } + [id]
    return Array(next.suffix(max(cap, 0)))
}

/// The saved list without any of `ids` (an order's IDs, so an alias saved earlier goes too).
func hiddenDraftsRemoving(_ ids: [String], ids removed: Set<String>) -> [String] {
    ids.filter { !removed.contains($0) }
}

func encodeHiddenDrafts(_ ids: [String]) -> Data? {
    try? JSONSerialization.data(withJSONObject: ["version": 1, "orderIDs": ids] as [String: Any], options: [.sortedKeys])
}

/// Lenient: unusable entries and repeats are dropped and the newest `cap` kept. Nil when the file is too large or isn't
/// a JSON object (it is then ignored and replaced on the next change).
func decodeHiddenDrafts(_ data: Data, cap: Int = hiddenDraftsMaxEntries) -> [String]? {
    guard data.count <= hiddenDraftsMaxFileBytes,
          let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    var seen = Set<String>()
    var ids: [String] = []
    // Later entries are newer: keep each ID's last position.
    for value in ((root["orderIDs"] as? [Any]) ?? []).reversed() {
        guard let id = value as? String, hiddenDraftIDIsValid(id), seen.insert(id).inserted else { continue }
        ids.append(id)
    }
    return Array(ids.reversed().suffix(max(cap, 0)))
}

/// Every ID the order goes by (the record's, `publicId` and `id`), without blanks.
func hiddenDraftOrderIDs(_ record: Record) -> Set<String> {
    let order = orderObject(record.values)
    return Set([record.id, orderNumber(order), (order["id"] as? String) ?? ""].filter { !$0.isEmpty })
}

/// Slant's own status says DRAFT (trimmed, any case). Never the display status: a hidden draft must show again as soon
/// as Slant's status moves on.
func orderRawStatusIsDraft(_ order: [String: Any]) -> Bool {
    ((order["status"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "DRAFT"
}

/// Whether the list leaves this order out: it is a draft by Slant's raw status, one of its IDs was hidden, and none of
/// its IDs is under the pay/cancel lock (`keeping`), whose Refresh Order must stay reachable.
func orderIsHiddenDraft(_ record: Record, hidden: Set<String>, keeping: Set<String> = []) -> Bool {
    guard !hidden.isEmpty, orderRawStatusIsDraft(orderObject(record.values)) else { return false }
    let ids = hiddenDraftOrderIDs(record)
    guard !ids.isDisjoint(with: hidden) else { return false }
    return ids.isDisjoint(with: keeping)
}

/// The rows the Orders list starts from once hidden drafts are left out (all of them while Show Hidden Drafts is on).
/// Display only, like `ordersShownOnPlatform`.
func ordersShownWithoutHiddenDrafts(_ records: [Record], hidden: Set<String>, keeping: Set<String> = [],
                                    showHidden: Bool = false) -> [Record] {
    guard !showHidden, !hidden.isEmpty else { return records }
    return records.filter { !orderIsHiddenDraft($0, hidden: hidden, keeping: keeping) }
}

/// The list's IDs that a run of reviews or Pay Several Drafts may offer: hidden drafts are never offered, even while
/// Show Hidden Drafts lists them (the seller can still open one's own review from its detail).
func orderListIDsExcludingHiddenDrafts(_ ids: [String], orders: [Record], hidden: Set<String>, keeping: Set<String> = []) -> [String] {
    guard !hidden.isEmpty else { return ids }
    let hiddenIDs = Set(orders.filter { orderIsHiddenDraft($0, hidden: hidden, keeping: keeping) }.map(\.id))
    return ids.filter { !hiddenIDs.contains($0) }
}

/// Marketplace keys (`batchPayMarketplaceKey`) of loaded drafts that are hidden and not among `reviewedIDs`: Pay Several
/// Drafts treats each as a draft left out of its review, so another draft for that sale (`batchPayMarketplaceKeysMatch`,
/// which also matches a CSV draft and a fetched draft of one Shopify sale) isn't paid unchecked. Reads the raw loaded
/// orders, every platform's.
func batchPayHiddenDraftMarketplaceKeys(_ orders: [Record], hidden: Set<String>, keeping: Set<String> = [],
                                        reviewedIDs: Set<String>) -> Set<String> {
    guard !hidden.isEmpty else { return [] }
    var keys = Set<String>()
    for record in orders where !reviewedIDs.contains(record.id) && orderIsHiddenDraft(record, hidden: hidden, keeping: keeping) {
        if let key = batchPayMarketplaceKey(orderObject(record.values)) { keys.insert(key) }
    }
    return keys
}

/// Hide Draft is offered for a draft by Slant's raw status that isn't under the pay/cancel lock.
func orderCanHideDraft(_ order: [String: Any], locked: Bool) -> Bool {
    orderRawStatusIsDraft(order) && !locked
}

/// What the Orders list leaves out, in one short line: "Not shown: 3 hidden drafts, 2 orders on other platforms".
/// Nil when nothing is left out. The list puts a Show button for the drafts beside it.
func orderNotShownLine(hiddenDrafts: Int, otherPlatforms: Int) -> String? {
    var parts: [String] = []
    if hiddenDrafts > 0 { parts.append(hiddenDrafts == 1 ? "1 hidden draft" : "\(hiddenDrafts.formatted()) hidden drafts") }
    if otherPlatforms > 0 {
        parts.append(otherPlatforms == 1 ? "1 order on another platform" : "\(otherPlatforms.formatted()) orders on other platforms")
    }
    return parts.isEmpty ? nil : "Not shown: " + parts.joined(separator: ", ")
}

/// Hover text for that line: why each part is left out.
func orderNotShownHelp(hiddenDrafts: Int, otherPlatforms: Int) -> String {
    var parts: [String] = []
    if hiddenDrafts > 0 { parts.append("Drafts you hid on this Mac are listed again with Show Hidden Drafts in the Status menu.") }
    if otherPlatforms > 0 { parts.append("Orders lists your default platform’s orders (Settings › Account).") }
    return parts.joined(separator: " ")
}

/// The fuller line for the "Only hidden drafts" empty state.
func orderHiddenDraftsLine(_ hidden: Int) -> String? {
    guard hidden > 0 else { return nil }
    let count = hidden == 1 ? "1 hidden draft isn’t" : "\(hidden.formatted()) hidden drafts aren’t"
    return "\(count) shown. Turn on Show Hidden Drafts in the Status menu to see them."
}

/// Under a hidden draft's detail (shown while Show Hidden Drafts is on, or still selected after hiding it).
let orderHiddenDraftDetailNote = "Hidden on this Mac; Slant still has it, and it costs nothing unless you place it."

/// Help for Hide Draft.
let orderHideDraftHelp = "Leave this draft out of Orders on this Mac. Nothing is sent to Slant, which keeps the draft; it shows again if it is placed."

// MARK: - Copy Tracking Number

/// The context menu's tracking item: the title and what it copies. One number is copied as it is; several are all
/// copied, one per line, under "Copy Tracking Numbers". Nil when Slant returned no tracking number.
func orderCopyTrackingMenuItem(_ numbers: [String]) -> (title: String, value: String)? {
    guard let first = numbers.first else { return nil }
    if numbers.count == 1 { return ("Copy Tracking Number", first) }
    return ("Copy Tracking Numbers", numbers.joined(separator: "\n"))
}

// MARK: - Store hooks

extension StudioStore {
    var hiddenDraftsURL: URL { Self.supportDirectory.appendingPathComponent(hiddenDraftsFileName) }

    /// The saved IDs as a set, for the list's checks.
    var hiddenDraftIDSet: Set<String> { Set(hiddenDraftIDs) }

    /// Whether this loaded order is a hidden draft (whatever Show Hidden Drafts says).
    func isHiddenDraft(_ record: Record) -> Bool {
        orderIsHiddenDraft(record, hidden: hiddenDraftIDSet, keeping: unknownOutcomeOrderIDs)
    }
    func isHiddenDraft(orderID: String) -> Bool {
        guard let record = orders.first(where: { $0.id == orderID }) else { return false }
        return isHiddenDraft(record)
    }

    /// Hide Draft: local only. Refused for anything that isn't a draft by Slant's raw status, or is locked.
    func hideDraft(orderID: String) {
        guard let record = orders.first(where: { $0.id == orderID }),
              orderCanHideDraft(orderObject(record.values), locked: hiddenDraftOrderIDs(record).contains { isOutcomeUnknown(orderID: $0) })
        else { return }
        let next = hiddenDraftsAdding(hiddenDraftIDs, id: record.id)
        guard next != hiddenDraftIDs else { return }
        hiddenDraftIDs = next
        saveHiddenDrafts()
    }

    /// Unhide Draft: removes every ID the order goes by.
    func unhideDraft(orderID: String) {
        var ids: Set<String> = [orderID]
        if let record = orders.first(where: { $0.id == orderID }) { ids.formUnion(hiddenDraftOrderIDs(record)) }
        let next = hiddenDraftsRemoving(hiddenDraftIDs, ids: ids)
        guard next != hiddenDraftIDs else { return }
        hiddenDraftIDs = next
        saveHiddenDrafts()
    }

    /// Disconnect and a key change: the IDs may belong to another account, so the file goes.
    func forgetHiddenDrafts() {
        hiddenDraftIDs = []
        showHiddenDrafts = false
        try? FileManager.default.removeItem(at: hiddenDraftsURL)
    }

    func loadHiddenDrafts() -> [String] {
        guard let data = try? Data(contentsOf: hiddenDraftsURL) else { return [] }
        return decodeHiddenDrafts(data) ?? []
    }

    private func saveHiddenDrafts() {
        if hiddenDraftIDs.isEmpty {
            try? FileManager.default.removeItem(at: hiddenDraftsURL)
            return
        }
        guard let data = encodeHiddenDrafts(hiddenDraftIDs) else { return }
        try? FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        try? data.write(to: hiddenDraftsURL, options: .atomic)
    }
}
