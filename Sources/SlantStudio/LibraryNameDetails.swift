import Foundation

// MARK: - Telling same-named models apart

/// For each entry whose name is shared with another (ignoring case and surrounding spaces), a short detail that tells
/// it apart; nil for names that are unique. `parts[i]` lists entry i's distinguishing facts, most useful first (such as
/// format, then date, then time). Each group uses the fewest leading facts that make its entries differ; entries
/// still alike after every fact are numbered in list order ("2 of 3"). Display only.
func duplicateNameDetails(names: [String], parts: [[String]]) -> [String?] {
    guard names.count == parts.count else { return [String?](repeating: nil, count: names.count) }
    return duplicateNameDetails(names: names) { parts[$0] }
}

/// As above, asking for an entry's facts only when its name is shared, so a library of unique names formats no dates.
func duplicateNameDetails(names: [String], parts: (Int) -> [String]) -> [String?] {
    var groups: [String: [Int]] = [:]
    var order: [String] = []
    for (index, name) in names.enumerated() {
        let key = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if groups[key] == nil { order.append(key) }
        groups[key, default: []].append(index)
    }
    var result = [String?](repeating: nil, count: names.count)
    for key in order {
        guard let members = groups[key], members.count > 1 else { continue }
        let cleaned = members.map { index in parts(index).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
        let longest = cleaned.map(\.count).max() ?? 0
        var chosen: [String]?
        if longest > 0 {
            for depth in 1...longest {
                let labels = cleaned.map { $0.prefix(depth).joined(separator: " · ") }
                if Set(labels).count == labels.count { chosen = labels; break }
            }
        }
        if let chosen {
            for (offset, index) in members.enumerated() { result[index] = chosen[offset] }
            continue
        }
        // Even every fact leaves some alike: number those within their alike set.
        let labels = cleaned.map { $0.joined(separator: " · ") }
        var totals: [String: Int] = [:]
        for label in labels { totals[label, default: 0] += 1 }
        var seen: [String: Int] = [:]
        for (offset, index) in members.enumerated() {
            let label = labels[offset]
            guard let total = totals[label], total > 1 else { result[index] = label; continue }
            seen[label, default: 0] += 1
            let number = "\(seen[label] ?? 1) of \(total)"
            result[index] = label.isEmpty ? number : "\(label) · \(number)"
        }
    }
    return result
}

/// Details for same-named models on this Mac, keyed by model ID: format, then the day and time each was added.
func localModelDuplicateNameDetails(
    _ models: [LocalModel],
    day: (Date) -> String = { $0.formatted(date: .abbreviated, time: .omitted) },
    time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
) -> [UUID: String] {
    let details = duplicateNameDetails(names: models.map(\.name)) { index in
        let model = models[index]
        return [ModelFileFormat(url: model.url)?.displayName ?? model.url.pathExtension.uppercased(), day(model.added), time(model.added)]
    }
    var result: [UUID: String] = [:]
    for (model, detail) in zip(models, details) {
        if let detail { result[model.id] = detail }
    }
    return result
}

/// Details for same-named Slant records (uploaded models in the library and the composer's pickers), in list order:
/// the file `type`, the upload day and time from `createdAt`, then the end of the ID, which is always present.
func recordDuplicateNameDetails(
    _ records: [Record],
    fallback: String = "Untitled",
    day: (Date) -> String = { $0.formatted(date: .abbreviated, time: .omitted) },
    time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
) -> [String?] {
    duplicateNameDetails(names: records.map { displayName(for: $0, fallback: fallback) }) { index in
        let record = records[index]
        let type = (record.values["type"] as? String)?.uppercased() ?? ""
        let created = recordCreatedDate(record)
        let id = record.id
        return [type, created.map(day) ?? "", created.map(time) ?? "", id.isEmpty ? "" : "ID …\(id.suffix(6))"]
    }
}

/// `recordDuplicateNameDetails` keyed by record ID (the first wins if an ID repeats).
func recordDuplicateNameDetailsByID(_ records: [Record], fallback: String = "Untitled") -> [String: String] {
    var result: [String: String] = [:]
    for (record, detail) in zip(records, recordDuplicateNameDetails(records, fallback: fallback)) {
        if let detail, result[record.id] == nil { result[record.id] = detail }
    }
    return result
}

private func recordCreatedDate(_ record: Record) -> Date? {
    guard let text = record.values["createdAt"] as? String else { return nil }
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
}

/// A picker or list title with its detail, such as "sample-cube — STL · 23 Oct 2026".
func nameWithDetail(_ name: String, _ detail: String?) -> String {
    guard let detail, !detail.isEmpty else { return name }
    return "\(name) — \(detail)"
}
