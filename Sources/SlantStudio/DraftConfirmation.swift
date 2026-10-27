import SwiftUI

// MARK: - Confirming a draft after a timeout
//
// Every Create Draft (`POST /orders`) from the composer and from Import Orders carries a fresh random marker in
// `metadata.studioDraftId`. When Slant doesn't confirm a create, the marker is kept with the in-memory record of
// that attempt, and Check Slant looks for it with read-only `GET /orders` requests (newest first, up to 3 pages of
// 100). A found marker confirms that the draft was created (owner decision, 24 Oct 2026); not finding one proves
// nothing — the order may be older than the pages read, or not listed yet — so the attempt stays unconfirmed.
// Nothing here ever creates, retries or changes an order.

/// The metadata key that carries a draft's marker.
let studioDraftMarkerKey = "studioDraftId"
/// Slant accepts at most this many metadata fields.
let orderMetadataFieldLimit = 10
/// Check Slant reads at most this many pages of this many orders per platform.
let draftMarkerCheckMaxPages = 3
let draftMarkerCheckPageSize = 100
/// Check Slant stops paging when Slant's figures show this many requests or fewer left in the current window.
let draftMarkerCheckRateLimitReserve = 10

/// A fresh marker for one Create Draft press. Random, so it says nothing about the order or the customer.
func newStudioDraftMarker() -> String {
    UUID().uuidString.lowercased()
}

/// The draft's metadata with the marker added, when there is room for one more field and the seller hasn't used the
/// key themselves; otherwise unchanged (that draft is sent without a marker and can't be checked).
func orderMetadataAddingDraftMarker(_ metadata: [String: Any], marker: String) -> [String: Any] {
    let trimmed = marker.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, metadata[studioDraftMarkerKey] == nil, metadata.count < orderMetadataFieldLimit else { return metadata }
    var result = metadata
    result[studioDraftMarkerKey] = trimmed
    return result
}

/// The marker to remember for a draft body: Studio's generated one only. Nil when the body went without it, including
/// when the seller typed their own value under the key, which could match another order.
func orderDraftMarkerSent(_ body: [String: Any], generated: String) -> String? {
    let marker = generated.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return !marker.isEmpty && orderDraftMarker(body) == marker ? marker : nil
}

/// The marker on an order (as listed by `GET /orders`, or a draft body), or nil. Metadata that is null, isn't an
/// object, or holds the key with a non-text or empty value has none.
func orderDraftMarker(_ order: [String: Any]) -> String? {
    guard let metadata = orderObject(order)["metadata"] as? [String: Any],
          let value = metadata[studioDraftMarkerKey] as? String else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    return trimmed.isEmpty ? nil : trimmed
}

/// The created order's number from a 2xx `POST /orders` reply: its `publicId`, else its `id` (text, or a number).
/// A reply naming only a `name` doesn't confirm a draft, although `Record.id` would fall back to it.
func orderCreatedID(_ order: [String: Any]) -> String? {
    for key in ["publicId", "id"] {
        if let text = order[key] as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        } else if let number = order[key] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.stringValue
        }
    }
    return nil
}

/// The API Workbench's `POST /orders` body with a fresh marker added the way the composer adds it, and the marker to
/// remember for Look for Draft on Slant. The body is unchanged (and the marker nil) when it isn't an object, when its
/// `metadata` is something other than an object, or when the metadata has no room or already uses the key.
func workbenchDraftBodyAddingMarker(_ body: Any?, marker: String) -> (body: Any?, marker: String?) {
    guard var object = body as? [String: Any] else { return (body, nil) }
    let existing = object["metadata"]
    if let existing, !(existing is NSNull), !(existing is [String: Any]) { return (body, nil) }
    let marked = orderMetadataAddingDraftMarker(existing as? [String: Any] ?? [:], marker: marker)
    guard marked[studioDraftMarkerKey] != nil else { return (body, nil) }
    object["metadata"] = marked
    return (object, orderDraftMarkerSent(object, generated: marker))
}

/// The recipient's name in a draft body (`customer.details.address.name`), for the unconfirmed-draft notice; "" when
/// there is none. Memory only, like the rest of that notice.
func orderDraftBodyRecipient(_ body: Any?) -> String {
    let customer = (body as? [String: Any])?["customer"] as? [String: Any]
    let address = (customer?["details"] as? [String: Any])?["address"] as? [String: Any]
    return ((address?["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Marker → the first order carrying it, among `records`, for the markers being looked for.
func ordersCarryingDraftMarkers(_ records: [Record], markers: Set<String>) -> [String: Record] {
    let wanted = Set(markers.map { $0.lowercased() })
    var found: [String: Record] = [:]
    for record in records {
        guard let marker = orderDraftMarker(record.values), wanted.contains(marker), found[marker] == nil,
              !record.id.isEmpty else { continue }
        found[marker] = record
    }
    return found
}

/// The unconfirmed attempts left once those whose markers were found are confirmed. Attempts without a marker stay.
func unconfirmedDraftAttempts(_ attempts: [UnconfirmedDraftAttempt], confirmedMarkers: Set<String>) -> [UnconfirmedDraftAttempt] {
    let confirmed = Set(confirmedMarkers.map { $0.lowercased() })
    return attempts.filter { attempt in
        guard let marker = attempt.marker?.lowercased() else { return true }
        return !confirmed.contains(marker)
    }
}

/// Whether Check Slant reads the next page: only while markers are still missing, within the page cap, while the
/// list has more, and while Slant's rate limit leaves more than the reserve (or its window has already reset).
func draftMarkerCheckShouldReadNextPage(page: Int, recordCount: Int, pagination: [String: Any]?, markersStillMissing: Int,
                                        rateLimit: RateLimitInfo?, now: Date) -> Bool {
    guard markersStillMissing > 0, page < draftMarkerCheckMaxPages,
          listHasMorePages(pagination: pagination, recordCount: recordCount, currentPage: page, pageSize: draftMarkerCheckPageSize) else { return false }
    return !draftMarkerCheckRateLimitLow(rateLimit, now: now)
}

func draftMarkerCheckRateLimitLow(_ rateLimit: RateLimitInfo?, now: Date) -> Bool {
    guard let remaining = rateLimit?.remaining, remaining <= draftMarkerCheckRateLimitReserve else { return false }
    if let reset = rateLimit?.reset, reset <= now { return false }
    return true
}

/// What one Check Slant found.
struct DraftMarkerSearchResult {
    /// Marker → the order carrying it.
    var found: [String: Record] = [:]
    /// Orders read from Slant (not counting the loaded list, which is checked first).
    var ordersRead = 0
    /// Paging stopped early to keep within Slant's rate limit.
    var stoppedForRateLimit = false
}

/// The composer's Look for Draft on Slant result: the text to show, and the found orders it offers to show.
struct DraftCreateCheckOutcome: Equatable {
    var message: String
    var foundOrderIDs: [String]
    var allConfirmed: Bool
    /// Parallel to `foundOrderIDs`: the order number the seller sees (`orderNumber`), for the Show Order buttons.
    var foundOrderNumbers: [String] = []
}

/// What a search that found nothing says, never as proof that no draft exists: "Slant has no matching draft among your
/// 300 newest orders." `subject` names what was looked for, such as " for the unconfirmed import" (or "").
func draftCheckNotFoundText(plural: Bool, subject: String = "", result: DraftMarkerSearchResult) -> String {
    let draft = plural ? "drafts" : "draft"
    var text: String
    switch result.ordersRead {
    case 0: text = "Slant has no matching \(draft)\(subject): it listed no orders."
    case 1: text = "Slant has no matching \(draft)\(subject) in your newest order."
    default: text = "Slant has no matching \(draft)\(subject) among your \(result.ordersRead) newest orders."
    }
    if result.stoppedForRateLimit { text += " Studio stopped early to stay within Slant’s rate limit." }
    return text
}

/// The Look for Draft on Slant message. Found attempts are named with the order number; a draft not found is reported
/// honestly, never as proof that none exists; attempts sent without Studio's reference (or no longer listed,
/// `earlierUnlisted`) can't be looked for.
func draftCreateCheckOutcome(attempts: [UnconfirmedDraftAttempt], result: DraftMarkerSearchResult, earlierUnlisted: Bool = false,
                             time: (Date) -> String = draftAttemptTimeText) -> DraftCreateCheckOutcome {
    func who(_ attempt: UnconfirmedDraftAttempt) -> String {
        attempt.recipient.isEmpty ? "at \(time(attempt.date))" : "for \(attempt.recipient) at \(time(attempt.date))"
    }
    var parts: [String] = []
    var foundIDs: [String] = []
    var foundNumbers: [String] = []
    let found = attempts.filter { attempt in attempt.marker.map { result.found[$0.lowercased()] != nil } ?? false }
    for attempt in found {
        guard let marker = attempt.marker?.lowercased(), let record = result.found[marker] else { continue }
        let number = orderNumber(orderObject(record.values))
        foundIDs.append(record.id)
        foundNumbers.append(number)
        parts.append("Found: Slant created the draft \(who(attempt)) (order \(number)).")
    }
    let missing = attempts.filter { attempt in attempt.marker.map { result.found[$0.lowercased()] == nil } ?? false }
    if !missing.isEmpty {
        var text = draftCheckNotFoundText(plural: missing.count > 1, result: result)
        text += missing.count == 1
            ? " It probably wasn’t created; if you create it again, check the list afterwards."
            : " They probably weren’t created; if you create them again, check the list afterwards."
        parts.append(text)
    }
    let unmarked = attempts.filter { $0.marker == nil }
    if !unmarked.isEmpty {
        let list = unmarked.map(who).joined(separator: "; ")
        parts.append("The attempt\(unmarked.count == 1 ? "" : "s") \(list) went without Studio’s reference (all 10 reference fields were in use, or one was named studioDraftId), so Studio can’t look for \(unmarked.count == 1 ? "it" : "them"). Check your drafts (\(draftCreateCheckDraftsPath)).")
    }
    if earlierUnlisted {
        parts.append("Earlier attempts that are no longer listed can’t be looked for. Check your drafts (\(draftCreateCheckDraftsPath)).")
    }
    return DraftCreateCheckOutcome(message: parts.joined(separator: " "), foundOrderIDs: foundIDs,
                                   allConfirmed: missing.isEmpty && unmarked.isEmpty && !earlierUnlisted,
                                   foundOrderNumbers: foundNumbers)
}

/// Import Orders' Look for Drafts on Slant message: counts only, never names or addresses from the file.
func orderImportDraftCheckMessage(confirmed: Int, stillUnconfirmed: Int, result: DraftMarkerSearchResult) -> String {
    var parts: [String] = []
    if confirmed > 0 {
        parts.append(confirmed == 1
            ? "Found 1 draft that didn’t confirm: Slant did create it, and it’s marked as imported."
            : "Found \(confirmed) drafts that didn’t confirm: Slant did create them, and they’re marked as imported.")
    }
    if stillUnconfirmed > 0 {
        let subject = stillUnconfirmed == 1 ? " for the unconfirmed import" : " for the \(stillUnconfirmed) unconfirmed imports"
        var text = draftCheckNotFoundText(plural: stillUnconfirmed > 1, subject: subject, result: result)
        text += stillUnconfirmed == 1
            ? " It probably wasn’t created; if you import it again, check Show Drafts afterwards."
            : " They probably weren’t created; if you import them again, check Show Drafts afterwards."
        parts.append(text)
    }
    return parts.joined(separator: " ")
}

/// The button that looks for unconfirmed drafts on Slant (composer and Import Orders).
func draftCheckButtonTitle(count: Int) -> String {
    count > 1 ? "Look for Drafts on Slant" : "Look for Draft on Slant"
}

/// Shown in the composer or Import Orders when Look for Draft on Slant couldn't read the orders. Nothing changes:
/// every attempt stays unconfirmed.
func draftMarkerSearchFailureText(_ message: String) -> String {
    let detail = message.trimmingCharacters(in: .whitespacesAndNewlines)
    let lead = "Couldn’t look on Slant, so nothing was confirmed."
    return detail.isEmpty ? lead : lead + " " + detail
}

// MARK: - Store hook

extension StudioStore {
    /// Looks for orders carrying `markers` (marker → the platform its draft was sent to). The loaded list is checked
    /// first, without a request; then, through `run` (so never while busy), read-only `GET /orders` newest first, up to
    /// 3 pages of 100 per platform, stopping as soon as every marker is found or the rate limit runs low. Nil when it
    /// didn't run or a request failed. A failure goes to `onFailure` (the sheet that asked shows it) instead of the
    /// window's alert, which would wait behind that sheet. Never retried, never writes an order.
    func searchOrdersForDraftMarkers(_ markers: [String: String],
                                     onFailure: (String) -> Void = { _ in }) async -> DraftMarkerSearchResult? {
        guard !busy else { return nil }
        var result = DraftMarkerSearchResult()
        let wanted = Set(markers.keys.map { $0.lowercased() })
        result.found = ordersCarryingDraftMarkers(orders, markers: wanted)
        var missing = wanted.subtracting(result.found.keys)
        guard !missing.isEmpty else { return result }
        // Platforms in a stable order, so the requests sent don't depend on dictionary order.
        var platforms: [String: Set<String>] = [:]
        for (marker, platform) in markers where missing.contains(marker.lowercased()) {
            platforms[platform.trimmingCharacters(in: .whitespacesAndNewlines), default: []].insert(marker.lowercased())
        }
        var completed = false
        let ran = await run("Look for unconfirmed drafts on Slant", handlesError: { error in
            onFailure(friendlyAPIMessage(error))
            return true
        }) {
            for platform in platforms.keys.sorted() {
                guard let platformMarkers = platforms[platform] else { continue }
                var page = 1
                while true {
                    let query = orderFilterQueryItems(OrderFilter(), page: page, limit: draftMarkerCheckPageSize, platformID: platform)
                    let response = try await client.request("GET", path: "/orders", query: query)
                    noteBackgroundRateLimit(from: response)
                    let records = responseRecords(response)
                    result.ordersRead += records.count
                    for (marker, record) in ordersCarryingDraftMarkers(records, markers: missing) where result.found[marker] == nil {
                        result.found[marker] = record
                    }
                    missing.subtract(result.found.keys)
                    let stillMissingHere = platformMarkers.intersection(missing).count
                    guard draftMarkerCheckShouldReadNextPage(page: page, recordCount: records.count, pagination: responsePagination(response),
                                                            markersStillMissing: stillMissingHere, rateLimit: rateLimit, now: Date()) else {
                        if stillMissingHere > 0, page < draftMarkerCheckMaxPages,
                           listHasMorePages(pagination: responsePagination(response), recordCount: records.count, currentPage: page, pageSize: draftMarkerCheckPageSize),
                           draftMarkerCheckRateLimitLow(rateLimit, now: Date()) {
                            result.stoppedForRateLimit = true
                        }
                        break
                    }
                    page += 1
                }
                if missing.isEmpty || result.stoppedForRateLimit { break }
            }
            completed = true
        }
        return ran && completed ? result : nil
    }
}

// MARK: - Composer notice

/// The composer's unconfirmed-draft notice with Look for Draft on Slant. `outcome` belongs to the composer, so the
/// result (and Show Order) stays visible after the last attempt is confirmed and the notice itself goes.
struct UnconfirmedDraftNotice: View {
    @EnvironmentObject var store: StudioStore
    @Binding var outcome: DraftCreateCheckOutcome?
    @State private var checking = false
    /// Why the last look couldn't read Slant's orders (shown here, not in the window's alert behind the composer).
    @State private var failure: String?
    /// Found orders not in the loaded list, kept for Show Order while the composer is open.
    @State private var foundRecords: [String: Record] = [:]
    let onShowOrder: (Record) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.draftCreateOutcomeUnknown {
                Label(draftCreateUnknownNotice(store.unconfirmedDraftCreates, earlierUnlisted: store.unconfirmedDraftCreatesOverflowed),
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let outcome {
                Label(outcome.message, systemImage: outcome.allConfirmed ? "checkmark.circle" : "info.circle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let failure {
                Label(draftMarkerSearchFailureText(failure), systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if store.draftCreateOutcomeUnknown, store.unconfirmedDraftCreates.contains(where: { $0.marker != nil }) {
                    Button(draftCheckButtonTitle(count: store.unconfirmedDraftCreates.filter { $0.marker != nil }.count)) { check() }
                        .disabled(store.busy || checking)
                        .help("Look for these drafts in your newest orders on Slant. Read-only: nothing is created or changed.")
                }
                if let outcome {
                    ForEach(Array(outcome.foundOrderIDs.enumerated()), id: \.element) { pair in
                        let id = pair.element
                        let number = pair.offset < outcome.foundOrderNumbers.count ? outcome.foundOrderNumbers[pair.offset] : id
                        Button(outcome.foundOrderIDs.count == 1 ? "Show Order" : "Show Order \(number)") {
                            if let record = store.orders.first(where: { $0.id == id }) ?? foundRecords[id] { onShowOrder(record) }
                        }
                        .disabled(store.busy)
                    }
                }
                if checking { ProgressView().controlSize(.small).accessibilityLabel("Looking on Slant") }
            }
        }
    }

    func check() {
        let attempts = store.unconfirmedDraftCreates
        var markers: [String: String] = [:]
        for attempt in attempts { if let marker = attempt.marker { markers[marker] = attempt.platformID } }
        guard !markers.isEmpty, !store.busy else { return }
        checking = true
        failure = nil
        Task {
            defer { checking = false }
            var failed: String?
            guard let result = await store.searchOrdersForDraftMarkers(markers, onFailure: { failed = $0 }) else {
                failure = failed
                return
            }
            for record in result.found.values { foundRecords[record.id] = record }
            outcome = draftCreateCheckOutcome(attempts: attempts, result: result, earlierUnlisted: store.unconfirmedDraftCreatesOverflowed)
            // Found markers confirm those drafts; the rest stay unconfirmed (not finding one proves nothing).
            store.unconfirmedDraftCreates = unconfirmedDraftAttempts(store.unconfirmedDraftCreates, confirmedMarkers: Set(result.found.keys))
        }
    }
}
