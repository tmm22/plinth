import XCTest
@testable import Plinth

/// Round 19: the shared read of recent orders (RecentOrders.swift) and the guards and sheets it widens.
@MainActor
final class RecentOrdersTests: XCTestCase {
    // MARK: Fixtures

    private func page(_ rows: [[String: Any]], page: Int, totalPages: Int? = nil) throws -> APIResponse {
        var root: [String: Any] = ["data": rows]
        if let totalPages { root["pagination"] = ["page": page, "totalPages": totalPages] }
        return APIResponse(data: try JSONSerialization.data(withJSONObject: root), statusCode: 200)
    }

    private func rows(_ range: Range<Int>, status: String = "SUBMITTED") -> [[String: Any]] {
        range.map { ["publicId": "O\($0)", "status": status, "createdAt": "2026-10-03T10:00:00.000Z"] }
    }

    private func sale(_ id: String, status: String, sale: String, platform: String? = nil) -> Record {
        var values: [String: Any] = ["publicId": id, "status": status, "metadata": ["source": "etsy", "sourceOrderId": sale]]
        if let platform { values["customer"] = ["platformId": platform] }
        return Record(values: values)
    }

    private func finishedRead(_ orders: [Record], complete: Bool = true, key: String = "key") -> RecentOrdersRead {
        RecentOrdersRead(orders: orders, pagesRead: 1, complete: complete, stop: complete ? nil : .pageLimit, accountKey: key)
    }

    private func http(_ status: Int) -> APIError { .http(status: status, body: "", retryAfter: nil, rateLimitReset: nil) }

    private let date: (Date) -> String = { _ in "3 Oct 2026" }

    // MARK: The read

    func testQueryAsksForEveryStatusAndPlatformNewestFirst() {
        let query = recentOrdersQuery(page: 2)
        XCTAssertEqual(query["page"], "2")
        XCTAssertEqual(query["limit"], "100")
        XCTAssertEqual(query["sortBy"], "createdAt")
        XCTAssertEqual(query["sortOrder"], "DESC")
        XCTAssertNil(query["status"], "every status")
        XCTAssertNil(query["platformId"], "never one platform: a duplicate guard must see every platform's orders")
        XCTAssertNil(query["startDate"])
        XCTAssertNil(query["endDate"])
    }

    func testReadsUntilSlantsRawPageSaysNoMoreAndDeduplicates() async throws {
        let first = try page(rows(0..<100), page: 1, totalPages: 2)
        // An order added meanwhile shifts the last row of page 1 onto page 2: it is kept once.
        let second = try page(rows(99..<120), page: 2, totalPages: 2)
        var requested: [Int] = []
        let read = await readRecentOrderPages(beforePage: { _ in nil }, fetch: { number in
            requested.append(number)
            return number == 1 ? first : second
        })
        XCTAssertEqual(requested, [1, 2])
        XCTAssertTrue(read.complete)
        XCTAssertTrue(read.finished)
        XCTAssertNil(read.stop)
        XCTAssertEqual(read.orders.count, 120)
        XCTAssertEqual(read.pagesRead, 2)
    }

    func testMoreThanThreeHundredOrdersStopsAtThePageCap() async throws {
        var requested: [Int] = []
        let read = await readRecentOrderPages(beforePage: { _ in nil }, fetch: { number in
            requested.append(number)
            return try self.page(self.rows((number - 1) * 100..<number * 100), page: number, totalPages: 9)
        })
        XCTAssertEqual(requested, [1, 2, 3])
        XCTAssertEqual(read.orders.count, 300)
        XCTAssertEqual(read.stop, .pageLimit)
        XCTAssertFalse(read.complete)
        XCTAssertTrue(read.finished, "the cap is a known limit, reported with how far back it reached")
        XCTAssertTrue(recentOrdersReachText(read, dateText: date).contains("your 300 newest orders on Slant, back to 3 Oct 2026"))
    }

    func testA429StopsTheReadKeepsEarlierPagesAndIsNeverRetried() async throws {
        let first = try page(rows(0..<100), page: 1, totalPages: 3)
        var requested: [Int] = []
        var limitedUntil: Date?
        let now = Date(timeIntervalSince1970: 1_000_000)
        let read = await readRecentOrderPages(beforePage: { _ in nil }, fetch: { number in
            requested.append(number)
            if number == 2 { throw self.http(429) }
            return first
        }, onRateLimited: { limitedUntil = $0 }, now: { now })
        XCTAssertEqual(requested, [1, 2], "never re-sent")
        XCTAssertEqual(read.orders.count, 100)
        guard case .rateLimit = read.stop else { return XCTFail("\(String(describing: read.stop))") }
        XCTAssertFalse(read.finished)
        XCTAssertEqual(limitedUntil, now.addingTimeInterval(60), "comparisonRateLimitedUntil's one-minute floor")
    }

    func testFailuresUnreadableRepliesAndCancellationAreRecorded() async throws {
        let failed = await readRecentOrderPages(beforePage: { _ in nil }, fetch: { _ in throw self.http(500) })
        guard case .failed = failed.stop else { return XCTFail() }
        XCTAssertFalse(failed.finished)
        XCTAssertEqual(failed.pagesRead, 0)

        let unreadable = await readRecentOrderPages(beforePage: { _ in nil }, fetch: { _ in
            APIResponse(data: Data("{\"message\":\"ok\"}".utf8), statusCode: 200)
        })
        XCTAssertEqual(unreadable.stop, .failed("Slant’s reply didn’t list orders."))

        let cancelled = await readRecentOrderPages(beforePage: { _ in nil }, fetch: { _ in throw URLError(.cancelled) })
        XCTAssertEqual(cancelled.stop, .cancelled)

        var fetched = false
        let stopped = await readRecentOrderPages(beforePage: { _ in .accountChanged }, fetch: { _ in
            fetched = true
            return try self.page([], page: 1)
        })
        XCTAssertFalse(fetched, "a stop before the page sends nothing")
        XCTAssertEqual(stopped.stop, .accountChanged)
        XCTAssertEqual(recentOrdersActivityDetail(.failed("Slant said: order SLANT_1 for Jane")), "couldn’t read a page",
                       "Activity never carries Slant's words")
    }

    func testAnEmptyAccountIsComplete() async throws {
        let read = await readRecentOrderPages(beforePage: { _ in nil }, fetch: { _ in try self.page([], page: 1) })
        XCTAssertTrue(read.complete)
        XCTAssertEqual(recentOrdersReachText(read), "your orders on Slant (it listed none)")
    }

    func testOrdersBelongOnlyToTheKeyTheyWereReadWith() {
        let read = finishedRead([sale("A", status: "SUBMITTED", sale: "1")], key: "key-1")
        XCTAssertEqual(read.orders(forKey: "key-1").count, 1)
        XCTAssertTrue(read.orders(forKey: "key-2").isEmpty)
        var changed = read
        changed.stop = .accountChanged
        XCTAssertTrue(changed.orders(forKey: "key-1").isEmpty)
        XCTAssertTrue(RecentOrdersRead().orders(forKey: "").isEmpty)
    }

    // MARK: Pay Several Drafts

    func testAfterAnImportOnlyTheWiderReadFindsThePlacedOrder() {
        let draft = orderObject(sale("D1", status: "DRAFT", sale: "1001").values)
        // After an import the list holds drafts only.
        let loaded = [sale("D1", status: "DRAFT", sale: "1001")]
        XCTAssertTrue(batchPayDuplicateExclusions([(id: "D1", order: draft)],
                                                  placedKeys: batchPayPlacedKeys(loaded: loaded, recent: [])).isEmpty)
        let recent = [sale("P1", status: "SUBMITTED", sale: "1001")]
        let reasons = batchPayDuplicateExclusions([(id: "D1", order: draft)],
                                                  placedKeys: batchPayPlacedKeys(loaded: loaded, recent: recent))
        XCTAssertTrue(reasons["D1"]?.contains("already placed") == true)
    }

    func testCancelledAndPaymentProblemOrdersAreNotPlacedButOtherPlatformsAndUnnamedOnesAre() {
        XCTAssertTrue(batchPayPlacedKeys(loaded: [], recent: [
            sale("C1", status: "CANCELLED", sale: "1"), sale("C2", status: "CANCELED", sale: "2"),
            sale("E1", status: "PAYMENT_ERROR", sale: "3"), sale("D1", status: "DRAFT", sale: "4")
        ]).isEmpty)
        let keys = batchPayPlacedKeys(loaded: [], recent: [
            sale("X", status: "PRINTING", sale: "5", platform: "another-platform"),
            sale("Y", status: "SHIPPED", sale: "6")
        ])
        XCTAssertEqual(keys.count, 2, "another platform's order, and one naming no platform, still hold their sale")
        // An unknown status past DRAFT counts, as for loaded orders: the cautious direction for this guard.
        XCTAssertEqual(batchPayPlacedKeys(loaded: [], recent: [sale("U", status: "ON_THE_MOON", sale: "7")]).count, 1)
    }

    func testHiddenAndLeftOutDraftsStillHoldTheirSaleWithTheWiderKeys() {
        let a = orderObject(sale("A", status: "DRAFT", sale: "1").values)
        let b = orderObject(sale("B", status: "DRAFT", sale: "1").values)
        let c = orderObject(sale("C", status: "DRAFT", sale: "2").values)
        let placed = batchPayPlacedKeys(loaded: [], recent: [sale("P", status: "SUBMITTED", sale: "9")])
        // A left out (a lock, say): B, for the same sale, is left out too.
        let leftOut = batchPayDuplicateExclusions([(id: "A", order: a), (id: "B", order: b), (id: "C", order: c)],
                                                  placedKeys: placed, excludedIDs: ["A"])
        XCTAssertNotNil(leftOut["B"])
        XCTAssertNil(leftOut["C"])
        // A hidden draft for sale 2 holds it.
        let hiddenKeys = batchPayHiddenDraftMarketplaceKeys([sale("H", status: "DRAFT", sale: "2")], hidden: ["H"], reviewedIDs: ["C"])
        XCTAssertNotNil(batchPayDuplicateExclusions([(id: "C", order: c)], placedKeys: placed, hiddenKeys: hiddenKeys)["C"])
    }

    func testAnUnfinishedReadLeavesOutDraftsForAMarketplaceOrderOnly() {
        let marketplace = orderObject(sale("M", status: "DRAFT", sale: "1").values)
        let plain: [String: Any] = ["publicId": "P", "status": "DRAFT"]
        let drafts = [(id: "M", order: marketplace), (id: "P", order: plain)]
        for recent in [nil, RecentOrdersRead(stop: .failed("x")), RecentOrdersRead(stop: .rateLimit("y")),
                       RecentOrdersRead(stop: .accountChanged)] as [RecentOrdersRead?] {
            let reasons = batchPayUncheckedExclusions(drafts, recent: recent)
            XCTAssertEqual(Set(reasons.keys), ["M"])
            XCTAssertTrue(reasons["M"]?.contains("Etsy order 1") == true)
            XCTAssertTrue(reasons["M"]?.contains("its own review") == true)
        }
        XCTAssertTrue(batchPayUncheckedExclusions(drafts, recent: finishedRead([])).isEmpty)
        XCTAssertTrue(batchPayUncheckedExclusions(drafts, recent: finishedRead([], complete: false)).isEmpty, "the page cap finished")
        XCTAssertTrue(batchPayPlacedCheckNeeded([plain, marketplace]))
        XCTAssertFalse(batchPayPlacedCheckNeeded([plain]))
    }

    func testTheReviewAndTheConfirmationSayHowFarTheCheckReached() throws {
        XCTAssertNil(batchPayPlacedCheckNotice(needed: false, recent: nil, leftOut: 0))
        XCTAssertNil(batchPayPlacedCheckConfirmText(needed: false, recent: nil))

        let all = try XCTUnwrap(batchPayPlacedCheckNotice(needed: true, recent: finishedRead(Array(repeating: sale("A", status: "DRAFT", sale: "1"), count: 1)), leftOut: 0))
        XCTAssertFalse(all.warning)
        XCTAssertTrue(all.text.contains("your 1 order on Slant"))
        XCTAssertTrue(all.text.contains("every status and platform"))

        var capped = RecentOrdersRead(orders: [Record(values: ["publicId": "A", "createdAt": "2026-10-03T10:00:00.000Z"])],
                                      pagesRead: 3, complete: false, stop: .pageLimit, accountKey: "k")
        let cappedNotice = try XCTUnwrap(batchPayPlacedCheckNotice(needed: true, recent: capped, leftOut: 0, dateText: date))
        XCTAssertFalse(cappedNotice.warning)
        XCTAssertTrue(cappedNotice.text.contains("back to 3 Oct 2026"))
        XCTAssertTrue(cappedNotice.text.contains("wouldn’t be noticed"))
        // The confirmation stays short: a finished check is described in the review only.
        XCTAssertNil(batchPayPlacedCheckConfirmText(needed: true, recent: capped))
        XCTAssertNil(batchPayPlacedCheckConfirmText(needed: true, recent: finishedRead([sale("A", status: "DRAFT", sale: "1")])))
        XCTAssertTrue(try XCTUnwrap(batchPayPlacedCheckConfirmText(needed: true, recent: nil)).contains("were left out"),
                      "a check that was never made is never passed over in silence")

        capped.stop = .rateLimit("Stopped to wait for Slant’s rate limit.")
        let stopped = try XCTUnwrap(batchPayPlacedCheckNotice(needed: true, recent: capped, leftOut: 2, dateText: date))
        XCTAssertTrue(stopped.warning)
        XCTAssertTrue(stopped.text.hasPrefix("Couldn’t check"))
        XCTAssertTrue(stopped.text.contains("Stopped to wait for Slant’s rate limit."))
        XCTAssertTrue(stopped.text.contains("2 drafts for a marketplace order are left out"))
        XCTAssertFalse(stopped.text.contains("no duplicates"))
        XCTAssertTrue(try XCTUnwrap(batchPayPlacedCheckConfirmText(needed: true, recent: capped)).contains("were left out"))
        XCTAssertTrue(try XCTUnwrap(batchPayPlacedCheckNotice(needed: true, recent: nil, leftOut: 1)).text.contains("1 draft for a marketplace order is left out"))
    }

    // MARK: Import Orders

    func testImportFindsAnEarlierImportOnlyInTheRecentRead() {
        let order = OrderImportOrder(source: .etsy, sourceOrderID: "1001")
        let recentKeys = orderImportLoadedSourceKeys([sale("P", status: "CANCELLED", sale: "1001")])
        XCTAssertNil(orderImportDuplicateReason(order, ledger: OrderImportLedger(), loadedKeys: []))
        let reason = orderImportDuplicateReason(order, ledger: OrderImportLedger(), loadedKeys: [], recentKeys: recentKeys)
        XCTAssertEqual(reason, "One of your recent orders on Slant was already imported from this Etsy order.")
        // The loaded list's wording wins when both have it.
        XCTAssertTrue(orderImportDuplicateReason(order, ledger: OrderImportLedger(), loadedKeys: recentKeys, recentKeys: recentKeys)?
            .contains("loaded list") == true)
    }

    func testImportReadsOnlyWhileTheListCantShowEveryOrder() {
        XCTAssertTrue(orderImportShouldReadRecentOrders(coverageNotice: "x", hasKey: true, alreadyRead: false, reading: false))
        XCTAssertFalse(orderImportShouldReadRecentOrders(coverageNotice: nil, hasKey: true, alreadyRead: false, reading: false))
        XCTAssertFalse(orderImportShouldReadRecentOrders(coverageNotice: "x", hasKey: false, alreadyRead: false, reading: false))
        XCTAssertFalse(orderImportShouldReadRecentOrders(coverageNotice: "x", hasKey: true, alreadyRead: true, reading: false))
        XCTAssertFalse(orderImportShouldReadRecentOrders(coverageNotice: "x", hasKey: true, alreadyRead: false, reading: true))
    }

    func testImportCoverageTextNeverClaimsMoreThanWasRead() throws {
        let list = orderImportDuplicateCoverageNotice(ordersLoaded: true, ordersHasMore: false, listIsPartial: true)
        XCTAssertEqual(orderImportDuplicateCoverageText(listNotice: list, reading: false, recent: nil), list)
        XCTAssertNil(orderImportDuplicateCoverageText(listNotice: nil, reading: false, recent: nil))
        XCTAssertTrue(try XCTUnwrap(orderImportDuplicateCoverageText(listNotice: list, reading: true, recent: nil)).hasPrefix("Checking"))
        let complete = try XCTUnwrap(orderImportDuplicateCoverageText(listNotice: list, reading: false,
                                                                        recent: finishedRead([sale("A", status: "SHIPPED", sale: "1"), sale("B", status: "DRAFT", sale: "2")])))
        XCTAssertEqual(complete, "Checked all 2 of your orders on Slant and this session’s imports for earlier imports of these orders.")
        let capped = try XCTUnwrap(orderImportDuplicateCoverageText(listNotice: list, reading: false, recent: finishedRead([], complete: false)))
        XCTAssertTrue(capped.contains("Older orders aren’t checked."))
        var failed = RecentOrdersRead(stop: .failed("Slant’s reply didn’t list orders."))
        let failedText = try XCTUnwrap(orderImportDuplicateCoverageText(listNotice: list, reading: false, recent: failed))
        XCTAssertTrue(failedText.hasPrefix("Couldn’t read your recent orders on Slant."))
        XCTAssertTrue(failedText.contains(list ?? "-"), "the list's own limit is still named")
        failed.pagesRead = 1
        failed.orders = [Record(values: ["publicId": "A", "createdAt": "2026-10-03T10:00:00.000Z"])]
        XCTAssertTrue(try XCTUnwrap(orderImportDuplicateCoverageText(listNotice: nil, reading: false, recent: failed, dateText: date))
            .contains("Checked your newest order on Slant, back to 3 Oct 2026 only."))
    }

    func testOrdersNewlyWarnedAreUnticked() {
        var warned = OrderImportCheck()
        warned.warnings = ["One of your recent orders on Slant was already imported from this Etsy order."]
        let clean = OrderImportCheck()
        XCTAssertEqual(orderImportNewlyWarned(before: ["a": clean, "b": warned, "c": clean], after: ["a": warned, "b": warned, "c": clean]), ["a"])
    }

    // MARK: Email for orders without one

    func testEmailSuggestionsAreOfferedNeverFilledIn() {
        XCTAssertTrue(orderImportFallbackEmailSuggestions(current: "", sellerEmail: nil).isEmpty)
        let mine = orderImportFallbackEmailSuggestions(current: "", sellerEmail: " me@shop.com ")
        XCTAssertEqual(mine.map(\.title), ["Use My Email"])
        XCTAssertEqual(mine.first?.email, "me@shop.com")
        XCTAssertTrue(orderImportFallbackEmailSuggestions(current: "ME@shop.com", sellerEmail: "me@shop.com").isEmpty,
                      "nothing to offer when the field already holds it")
        XCTAssertTrue(orderImportFallbackEmailSuggestions(current: "", sellerEmail: "not an email").isEmpty)
    }

    // MARK: Tracking for Your Shop and Needs Attention

    private func shipped(_ id: String, tracking: [String]?) -> Record {
        var values: [String: Any] = ["publicId": id, "status": "SHIPPED", "createdAt": "2026-10-20T10:00:00.000Z"]
        if let tracking { values["fulfillment"] = ["trackingNumbers": tracking] }
        return Record(values: values)
    }

    func testTrackingListsShippedOrdersFoundByTheReadWithoutAddingThemToTheList() {
        // The loaded copy is older and has no tracking yet; the read's copy has it.
        let loaded = [shipped("S1", tracking: nil), Record(values: ["publicId": "D1", "status": "DRAFT"])]
        let recent = [shipped("S1", tracking: ["1Z999"]), shipped("S2", tracking: ["LONE2"])]
        let groups = shopFollowUpGroups(loaded + recent, done: [])
        XCTAssertEqual(Set((groups.imported + groups.notImported).map(\.id)), ["S1", "S2"])
        XCTAssertEqual(shopFollowUpGroups(loaded + recent, done: ["S2"]).doneCount, 1, "done ticks by order ID still apply")
    }

    func testTrackingReadsOnOpenOnlyWhenTheListIsFilteredOrSearched() {
        XCTAssertTrue(shopFollowUpShouldReadOnOpen(filterActive: true, searchActive: false, hasKey: true))
        XCTAssertTrue(shopFollowUpShouldReadOnOpen(filterActive: false, searchActive: true, hasKey: true))
        XCTAssertFalse(shopFollowUpShouldReadOnOpen(filterActive: false, searchActive: false, hasKey: true))
        XCTAssertFalse(shopFollowUpShouldReadOnOpen(filterActive: true, searchActive: false, hasKey: false))
    }

    func testTheEmptyStateNamesTheFilterInsteadOfBlamingSlant() {
        let limit = shopFollowUpListLimitText(statusFilter: "DRAFT", datesFiltered: false, searchActive: false)
        XCTAssertEqual(limit, "The Orders list shows only Draft orders, so shipped orders may not be loaded.")
        let text = shopFollowUpEmptyText(doneCount: 0, listLimit: limit, reading: false, recent: nil)
        XCTAssertTrue(text.contains("only Draft orders"))
        XCTAssertTrue(text.contains("Load Recent Orders"))
        XCTAssertFalse(text.contains("has tracking from Slant yet"))
        XCTAssertTrue(shopFollowUpListLimitText(statusFilter: nil, datesFiltered: false, searchActive: true)?.contains("search") == true)
        XCTAssertNil(shopFollowUpListLimitText(statusFilter: nil, datesFiltered: false, searchActive: false))
        XCTAssertTrue(shopFollowUpEmptyText(doneCount: 0, listLimit: nil, reading: false, recent: nil).contains("Refresh Orders later"))
        let read = shopFollowUpEmptyText(doneCount: 0, listLimit: limit, reading: false, recent: finishedRead([], complete: false))
        XCTAssertTrue(read.hasPrefix("No order in your Orders list, or in "))
        let failed = shopFollowUpEmptyText(doneCount: 0, listLimit: limit, reading: false, recent: RecentOrdersRead(stop: .failed("Offline.")))
        XCTAssertTrue(failed.hasPrefix("Couldn’t load your recent orders from Slant. Offline."))
        XCTAssertTrue(failed.contains("only Draft orders"))
        XCTAssertTrue(shopFollowUpSourceText(reading: false, recent: nil, ordersHasMore: true).contains("hasn’t loaded your older orders"))
        XCTAssertTrue(shopFollowUpSourceText(reading: false, recent: finishedRead([shipped("S", tracking: ["1"])]), ordersHasMore: true)
            .hasPrefix("Shows your Orders list and your 1 order on Slant"))
    }

    func testNeedsAttentionSaysWhatTheLoadedListLeavesOut() {
        XCTAssertTrue(orderAttentionFilterHint(moreOnServer: false, statusFilter: "DRAFT").hasSuffix("Only Draft orders are loaded."))
        XCTAssertTrue(orderAttentionFilterHint(moreOnServer: true, statusFilter: "SUBMITTED", datesFiltered: true)
            .hasSuffix("Only Submitted orders from the chosen dates are loaded. Load more to check older orders."))
        XCTAssertTrue(orderAttentionFilterHint(moreOnServer: false, datesFiltered: true)
            .hasSuffix("Only orders from the chosen dates are loaded."))
        let search = orderAttentionFilterHint(moreOnServer: false, searchActive: true)
        XCTAssertTrue(search.contains("Only the order found by your search is checked"))
        XCTAssertFalse(search.contains("Load more"))
        XCTAssertFalse(orderAttentionFilterHint(moreOnServer: false).contains("Only"))
    }

    // MARK: Clearing the search

    func testClearingTheSearchReloadsOnlyOrdersOnceTheAccountHasLoaded() {
        XCTAssertTrue(orderSearchClearReloadsOnlyOrders(connected: true, hasKey: true))
        XCTAssertFalse(orderSearchClearReloadsOnlyOrders(connected: false, hasKey: true), "first load still refreshes everything")
        XCTAssertFalse(orderSearchClearReloadsOnlyOrders(connected: true, hasKey: false))
    }
}
