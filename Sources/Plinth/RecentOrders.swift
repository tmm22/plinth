import Foundation

// MARK: - Recent orders of every status and platform
//
// One shared, read-only read used to widen guards that would otherwise see only what the Orders list last loaded
// (after an import the list shows drafts only, and a Return in the search replaces it with one lookup):
//
// - Pay Several Drafts' "this sale already has a placed order" check (BatchPay.swift), read with its review;
// - Import Orders' duplicate check (OrderImport.swift), read when a file is shown while the list can't show every
//   earlier order;
// - Tracking for Your Shop (OrderFollowUp.swift), read when the list is filtered or searched, or on Load Recent Orders.
//
// `GET /orders?page=N&limit=100&sortBy=createdAt&sortOrder=DESC`, no status, no dates and no `platformId`: Slant can't
// be relied on to filter by platform, and seeing every platform's orders is the cautious direction for a duplicate
// guard, so the read never asks for one platform and its rows are never platform-checked. At most
// `recentOrdersMaxPages` pages, decided from Slant's raw page; never retried; a 429 stops it and sets
// `recentOrdersRateLimitedUntil` (`comparisonRateLimitedUntil`). The orders live in the memory of the sheet that asked
// for them (customer details included, never on disk, in preferences or Activity) and never replace or filter
// `store.orders`. A read that failed, stopped for the rate limit or reached the page cap says so, and is never
// treated as "no duplicates".

/// The most pages one read takes, and their size: the 300 newest orders, like Look for Draft on Slant.
let recentOrdersMaxPages = 3
let recentOrdersPageSize = 100

/// After a 429 on this read, when it may run again (session only).
@MainActor var recentOrdersRateLimitedUntil: Date?

/// One page of the read: newest first, every status, every platform.
func recentOrdersQuery(page: Int) -> [String: String] {
    orderFilterQueryItems(OrderFilter(), page: page, limit: recentOrdersPageSize, platformID: "")
}

/// Why a read stopped before Slant's pages ran out.
enum RecentOrdersStop: Equatable {
    /// It read `recentOrdersMaxPages` pages and Slant has older orders.
    case pageLimit
    /// Stopped before a page to stay within Slant's rate limit, or after a 429.
    case rateLimit(String)
    /// A page couldn't be read.
    case failed(String)
    /// The key changed (or was removed) during the read: nothing read may be used.
    case accountChanged
    /// The seller stopped it, or closed the sheet.
    case cancelled
}

/// What one read found.
struct RecentOrdersRead {
    /// Slant's rows in the order read, each order once (rows without an ID are kept: they can't be deduplicated).
    var orders: [Record] = []
    var pagesRead = 0
    /// Slant's raw pages showed that every order was read.
    var complete = false
    var stop: RecentOrdersStop?
    /// The key the read was made with, so a result for an earlier account is never used.
    var accountKey = ""

    /// The read did what it set out to: every order, or the page cap.
    var finished: Bool { complete || stop == .pageLimit }
    /// The oldest creation date among the orders read.
    var oldestCreated: Date? { orders.compactMap { orderCreatedDate(orderObject($0.values)) }.min() }
    /// The orders, only while they belong to `apiKey`.
    func orders(forKey apiKey: String) -> [Record] {
        guard stop != .accountChanged, !accountKey.isEmpty, accountKey == apiKey else { return [] }
        return orders
    }
}

/// Reads up to `maxPages` pages through `fetch`. `beforePage` runs before every request and may stop the read (pacing,
/// a changed account, Stop); `afterPage` sees every reply (rate-limit figures). Never throws and never retries: a
/// failure is recorded in `stop`, keeping the pages already read (they can only widen a guard).
@MainActor
func readRecentOrderPages(maxPages: Int = recentOrdersMaxPages,
                          beforePage: (_ page: Int) async -> RecentOrdersStop?,
                          fetch: (_ page: Int) async throws -> APIResponse,
                          afterPage: (APIResponse) -> Void = { _ in },
                          onRateLimited: (Date) -> Void = { _ in },
                          now: () -> Date = Date.init) async -> RecentOrdersRead {
    var read = RecentOrdersRead()
    var seen = Set<String>()
    var page = 1
    while true {
        if let stop = await beforePage(page) {
            read.stop = stop
            return read
        }
        let response: APIResponse
        do {
            response = try await fetch(page)
        } catch APIError.http(429, _, let retryAfter, let reset) {
            let until = comparisonRateLimitedUntil(retryAfter: retryAfter, rateLimitReset: reset, now: now())
            onRateLimited(until)
            read.stop = .rateLimit("Slant’s rate limit was reached. \(rateLimitResetWaitCopy(secondsFromNow: until.timeIntervalSince(now())))")
            return read
        } catch is CancellationError {
            read.stop = .cancelled
            return read
        } catch let error as URLError where error.code == .cancelled {
            read.stop = .cancelled
            return read
        } catch {
            read.stop = .failed(friendlyAPIMessage(error))
            return read
        }
        afterPage(response)
        guard spendReportPageIsReadable(response.json) else {
            read.stop = .failed("Slant’s reply didn’t list orders.")
            return read
        }
        let rows = responseRecords(response)
        read.pagesRead = page
        for row in rows where row.id.isEmpty || seen.insert(row.id).inserted { read.orders.append(row) }
        // From Slant's raw page, never from rows kept.
        guard listHasMorePages(pagination: responsePagination(response), recordCount: rows.count,
                               currentPage: page, pageSize: recentOrdersPageSize) else {
            read.complete = true
            return read
        }
        guard page < maxPages else {
            read.stop = .pageLimit
            return read
        }
        page += 1
    }
}

// MARK: Wording

func recentOrdersDateText(_ date: Date) -> String { date.formatted(date: .abbreviated, time: .omitted) }

/// "all 57 of your orders on Slant", "your 300 newest orders on Slant, back to 3 Oct 2026", "your newest order on
/// Slant": how far the read reached, whatever stopped it.
func recentOrdersReachText(_ read: RecentOrdersRead, dateText: (Date) -> String = recentOrdersDateText) -> String {
    let count = read.orders.count
    if read.complete {
        switch count {
        case 0: return "your orders on Slant (it listed none)"
        case 1: return "your 1 order on Slant"
        default: return "all \(count) of your orders on Slant"
        }
    }
    let newest = count == 1 ? "your newest order on Slant" : "your \(count) newest orders on Slant"
    guard let oldest = read.oldestCreated else { return newest }
    return "\(newest), back to \(dateText(oldest))"
}

/// Why a read didn't finish, in a few words for the sheets ("" for one that finished).
func recentOrdersStopReason(_ read: RecentOrdersRead) -> String {
    switch read.stop {
    case .rateLimit(let message), .failed(let message): return message
    case .accountChanged: return "The Slant account changed while reading."
    case .cancelled: return "Stopped."
    case .pageLimit, nil: return ""
    }
}

/// Activity's detail for an unfinished read: the kind of stop only, never Slant's words.
func recentOrdersActivityDetail(_ stop: RecentOrdersStop?) -> String? {
    switch stop {
    case .rateLimit: return "stopped at the rate limit"
    case .failed: return "couldn’t read a page"
    case .accountChanged: return "stopped: the account changed"
    case .cancelled: return "stopped"
    case .pageLimit, nil: return nil
    }
}

// MARK: - Store hook

extension StudioStore {
    /// Import Orders and Tracking for Your Shop: the read inside `run` (so never while busy, a batch runs or another
    /// request is waiting), following Look for Draft on Slant's rules: pages at least 0.6 s apart
    /// (`comparisonMinimumSpacing`), stopping instead of waiting when Slant's figures run low
    /// (`draftMarkerCheckRateLimitLow`) or a 429's wait hasn't passed, and stopping when the key changes. Nil when it
    /// didn't run (no key, or busy). Never retried; failures are returned, never shown in the window's alert, which
    /// would wait behind the asking sheet. Cancelling the calling task stops it before the next page.
    func readRecentOrders(title: String = "Read recent orders") async -> RecentOrdersRead? {
        guard hasKey, !busy else { return nil }
        let key = apiKey
        var result: RecentOrdersRead?
        let ran = await run(title, handlesError: { _ in true }) {
            var lastStart: Date?
            var read = await readRecentOrderPages(
                beforePage: { _ in
                    if Task.isCancelled { return .cancelled }
                    guard self.hasKey, self.apiKey == key else { return .accountChanged }
                    if let until = recentOrdersRateLimitedUntil, until > Date() {
                        return .rateLimit("Slant’s rate limit was reached. \(rateLimitResetWaitCopy(secondsFromNow: until.timeIntervalSinceNow))")
                    }
                    if draftMarkerCheckRateLimitLow(self.rateLimit, now: Date()) {
                        return .rateLimit("Paused to keep Slant’s remaining requests for your orders and uploads. Try again in about a minute.")
                    }
                    if let lastStart {
                        let wait = comparisonMinimumSpacing - Date().timeIntervalSince(lastStart)
                        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
                    }
                    if Task.isCancelled { return .cancelled }
                    guard self.hasKey, self.apiKey == key else { return .accountChanged }
                    lastStart = Date()
                    return nil
                },
                fetch: { page in try await self.client.request("GET", path: "/orders", query: recentOrdersQuery(page: page)) },
                afterPage: { self.noteBackgroundRateLimit(from: $0) },
                onRateLimited: { recentOrdersRateLimitedUntil = $0 })
            // A reply that arrived after the key changed belongs to the earlier account.
            if !(self.hasKey && self.apiKey == key) { read.stop = .accountChanged; read.orders = [] }
            read.accountKey = key
            result = read
            // Activity records the kind of stop only (counts and no order details either way).
            if let detail = recentOrdersActivityDetail(read.stop) { throw StudioError(detail) }
        }
        return ran ? result : nil
    }
}
