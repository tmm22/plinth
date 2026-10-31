import Foundation

// MARK: - Tracking for Your Shop › remembered done marks
//
// The orders the seller ticked "done in your shop" are remembered across launches: Slant order IDs only, the newest
// `shopFollowUpDoneLimit`, in `shop-tracking-done.json` in the support folder (`AppSupportLocation`), read leniently.
// They are forgotten (and the file deleted) on Disconnect and on a key change, because a new key may belong to another
// account. Nothing else is saved: no numbers, tracking, names or times. 3DAPI's marks (`DapiOrderToolsState`) stay in
// memory, like everything 3DAPI.

let shopFollowUpDoneFileName = "shop-tracking-done.json"
/// Most marks kept; the oldest go first.
let shopFollowUpDoneLimit = 2_000
/// Longest order ID kept from the file.
let shopFollowUpDoneMaxIDLength = 200

/// The marks, in the order they were made (oldest first), with a set for lookups.
struct ShopFollowUpDoneRecord: Equatable {
    private(set) var order: [String] = []
    private(set) var ids: Set<String> = []

    init(order: [String] = []) {
        var seen = Set<String>()
        let kept = order.filter { seen.insert($0).inserted }
        self.order = Array(kept.suffix(shopFollowUpDoneLimit))
        self.ids = Set(self.order)
    }

    /// The record for a new set of marks: marks still present keep their place, new ones are added last (sorted, so
    /// several added at once land in a fixed order), and only the newest `shopFollowUpDoneLimit` stay.
    func updating(to newIDs: Set<String>) -> ShopFollowUpDoneRecord {
        guard newIDs != ids else { return self }
        let kept = order.filter { newIDs.contains($0) }
        let added = newIDs.subtracting(ids).sorted()
        return ShopFollowUpDoneRecord(order: kept + added)
    }
}

private struct ShopFollowUpDoneFile: Codable {
    var version = 1
    var orderIDs: [String]
}

/// The file's bytes: `{"version":1,"orderIDs":[…]}`, oldest first.
func encodeShopFollowUpDone(_ record: ShopFollowUpDoneRecord) -> Data? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try? encoder.encode(ShopFollowUpDoneFile(orderIDs: record.order))
}

/// The marks in a saved file, leniently: anything that isn't the expected object gives no marks; entries that aren't
/// strings, are blank, too long or hold control characters are skipped; repeats are dropped; only the newest
/// `shopFollowUpDoneLimit` are kept.
func decodeShopFollowUpDone(_ data: Data) -> ShopFollowUpDoneRecord {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let entries = object["orderIDs"] as? [Any] else { return ShopFollowUpDoneRecord() }
    let ids = entries.compactMap { entry -> String? in
        guard let text = entry as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= shopFollowUpDoneMaxIDLength,
              !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return trimmed
    }
    return ShopFollowUpDoneRecord(order: ids)
}

/// Reads the file at `url`; a missing or unreadable file gives no marks.
func loadShopFollowUpDone(from url: URL) -> ShopFollowUpDoneRecord {
    guard let data = try? Data(contentsOf: url) else { return ShopFollowUpDoneRecord() }
    return decodeShopFollowUpDone(data)
}

/// Writes the marks to `url` (creating its folder), or deletes the file when there are none. Failures are ignored:
/// the marks still work for the session.
func saveShopFollowUpDone(_ record: ShopFollowUpDoneRecord, to url: URL) {
    if record.order.isEmpty {
        try? FileManager.default.removeItem(at: url)
        return
    }
    guard let data = encodeShopFollowUpDone(record) else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? data.write(to: url, options: .atomic)
}

extension StudioStore {
    static var shopFollowUpDoneURL: URL { supportDirectory.appendingPathComponent(shopFollowUpDoneFileName) }

    /// Orders ticked "done in your shop" in Tracking for Your Shop. Setting it saves the marks.
    var shopFollowUpDoneIDs: Set<String> {
        get { shopFollowUpDone.ids }
        set {
            let next = shopFollowUpDone.updating(to: newValue)
            guard next != shopFollowUpDone else { return }
            shopFollowUpDone = next
            saveShopFollowUpDone(next, to: Self.shopFollowUpDoneURL)
        }
    }

    /// At launch, only with a saved key: marks are forgotten whenever the key goes, so a file without one is stale.
    func loadShopFollowUpDoneAtLaunch() {
        guard hasKey else { return }
        shopFollowUpDone = loadShopFollowUpDone(from: Self.shopFollowUpDoneURL)
    }

    /// Disconnect or a key change: the marks may belong to another account.
    func forgetShopFollowUpDone() {
        shopFollowUpDone = ShopFollowUpDoneRecord()
        try? FileManager.default.removeItem(at: Self.shopFollowUpDoneURL)
    }
}
