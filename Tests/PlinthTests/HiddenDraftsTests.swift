import XCTest
@testable import Plinth

/// Hide Draft (HiddenDrafts.swift), Copy Tracking Number, tracking search and the export's reference columns.
/// Fictional IDs only.
final class HiddenDraftsTests: XCTestCase {
    private func order(_ id: String, status: String = "DRAFT", platform: String? = nil, extra: [String: Any] = [:]) -> Record {
        var values: [String: Any] = ["publicId": id, "status": status]
        if let platform { values["customer"] = ["platformId": platform] }
        values.merge(extra) { _, new in new }
        return Record(values: values)
    }

    // MARK: Storage

    func testStorageRoundTripsAndIsLenient() throws {
        let data = try XCTUnwrap(encodeHiddenDrafts(["D1", "D2"]))
        XCTAssertEqual(decodeHiddenDrafts(data), ["D1", "D2"])
        // Only IDs are saved.
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["version", "orderIDs"])

        let messy = #"{"orderIDs": ["A", 7, "", "has space", "B", "A", null, {"x": 1}, "C"], "other": true}"#
        XCTAssertEqual(decodeHiddenDrafts(Data(messy.utf8)), ["B", "A", "C"])
        // Not an object, or no list: nothing usable, never a crash.
        XCTAssertNil(decodeHiddenDrafts(Data("[\"A\"]".utf8)))
        XCTAssertNil(decodeHiddenDrafts(Data("not json".utf8)))
        XCTAssertEqual(decodeHiddenDrafts(Data("{}".utf8)), [])
        // Too large: ignored.
        XCTAssertNil(decodeHiddenDrafts(Data(repeating: 0x20, count: 300 * 1024)))
        // Capped to the newest entries.
        let many = try XCTUnwrap(encodeHiddenDrafts((1...10).map { "D\($0)" }))
        XCTAssertEqual(decodeHiddenDrafts(many, cap: 3), ["D8", "D9", "D10"])
    }

    func testAddingAndRemovingKeepOrderAndCap() {
        XCTAssertEqual(hiddenDraftsAdding(["A", "B"], id: "A"), ["B", "A"])
        XCTAssertEqual(hiddenDraftsAdding(["A", "B"], id: "C", cap: 2), ["B", "C"])
        XCTAssertEqual(hiddenDraftsAdding(["A"], id: ""), ["A"])
        XCTAssertEqual(hiddenDraftsAdding(["A"], id: "bad\nid"), ["A"])
        XCTAssertEqual(hiddenDraftsAdding(["A"], id: String(repeating: "x", count: 129)), ["A"])
        XCTAssertEqual(hiddenDraftsRemoving(["A", "B", "C"], ids: ["B", "Z"]), ["A", "C"])
    }

    // MARK: Which rows are hidden

    func testOnlyRawDraftsAreHidden() {
        let hidden: Set<String> = ["D1", "P1"]
        XCTAssertTrue(orderIsHiddenDraft(order("D1"), hidden: hidden))
        XCTAssertTrue(orderIsHiddenDraft(order("D1", status: " draft "), hidden: hidden))
        // Paid elsewhere: it shows again, whatever the saved list says.
        XCTAssertFalse(orderIsHiddenDraft(order("P1", status: "SUBMITTED"), hidden: hidden))
        XCTAssertFalse(orderIsHiddenDraft(order("P1", status: "PAYMENT_ERROR"), hidden: hidden))
        XCTAssertFalse(orderIsHiddenDraft(order("P1", status: ""), hidden: hidden))
        XCTAssertFalse(orderIsHiddenDraft(order("D2"), hidden: hidden))
        XCTAssertFalse(orderIsHiddenDraft(order("D1"), hidden: []))
    }

    func testAHiddenDraftUnderTheLockIsNeverHidden() {
        let record = Record(values: ["publicId": "D1", "id": "internal-1", "status": "DRAFT"])
        XCTAssertTrue(orderIsHiddenDraft(record, hidden: ["D1"]))
        XCTAssertFalse(orderIsHiddenDraft(record, hidden: ["D1"], keeping: ["D1"]))
        // Locked under another of its IDs.
        XCTAssertFalse(orderIsHiddenDraft(record, hidden: ["D1"], keeping: ["internal-1"]))
        // Hidden under another of its IDs.
        XCTAssertTrue(orderIsHiddenDraft(record, hidden: ["internal-1"]))
        XCTAssertEqual(ordersShownWithoutHiddenDrafts([record], hidden: ["D1"], keeping: ["D1"]).map(\.id), ["D1"])
        XCTAssertFalse(orderCanHideDraft(orderObject(record.values), locked: true))
        XCTAssertTrue(orderCanHideDraft(orderObject(record.values), locked: false))
        XCTAssertFalse(orderCanHideDraft(["status": "SUBMITTED"], locked: false))
    }

    func testRowsLeaveOutHiddenDraftsUnlessShown() {
        let records = [order("D1"), order("D2"), order("S1", status: "SHIPPED")]
        XCTAssertEqual(ordersShownWithoutHiddenDrafts(records, hidden: ["D1", "S1"]).map(\.id), ["D2", "S1"])
        XCTAssertEqual(ordersShownWithoutHiddenDrafts(records, hidden: ["D1"], showHidden: true).map(\.id), ["D1", "D2", "S1"])
        XCTAssertEqual(ordersShownWithoutHiddenDrafts(records, hidden: []).map(\.id), ["D1", "D2", "S1"])
    }

    /// Hiding applies on top of the platform check and never brings back another platform's order.
    func testHidingComposesWithThePlatformCheck() {
        let records = [order("D1", platform: "p1"), order("D2", platform: "p2"), order("D3", platform: "p1")]
        let onPlatform = ordersShownOnPlatform(records, platformID: "p1")
        XCTAssertEqual(ordersShownWithoutHiddenDrafts(onPlatform, hidden: ["D1"]).map(\.id), ["D3"])
        XCTAssertEqual(ordersShownWithoutHiddenDrafts(onPlatform, hidden: ["D1"], showHidden: true).map(\.id), ["D1", "D3"])
    }

    /// Review Drafts One by One and Pay Several Drafts never offer a hidden draft, even while it is listed.
    func testReviewAndBatchCandidatesSkipHiddenDrafts() {
        let records = [order("D1"), order("D2"), order("D3"), order("S1", status: "SUBMITTED")]
        let ids = records.map(\.id)
        let reviewable = orderListIDsExcludingHiddenDrafts(ids, orders: records, hidden: ["D2", "S1"])
        XCTAssertEqual(reviewable, ["D1", "D3", "S1"])
        XCTAssertEqual(batchPayDraftRecords(listIDs: reviewable, orders: records).map(\.id), ["D1", "D3"])
        // A locked draft stays: the lock's own rules decide what the batch does with it.
        XCTAssertEqual(orderListIDsExcludingHiddenDrafts(ids, orders: records, hidden: ["D2"], keeping: ["D2"]), ids)
        // An ID that isn't loaded hides nothing.
        XCTAssertEqual(orderListIDsExcludingHiddenDrafts(ids, orders: records, hidden: ["GONE"]), ids)
    }

    // MARK: Pay Several Drafts' duplicate check

    private func marketplaceDraft(_ id: String, sale: String) -> Record {
        order(id, extra: ["metadata": ["source": "etsy", "sourceOrderId": sale]])
    }

    func testAHiddenDraftStillHoldsItsSaleInTheBatch() {
        let hiddenDraft = marketplaceDraft("H1", sale: "1001")
        let visible = marketplaceDraft("V1", sale: "1001")
        let other = marketplaceDraft("V2", sale: "2002")
        let loaded = [hiddenDraft, visible, other]
        let keys = batchPayHiddenDraftMarketplaceKeys(loaded, hidden: ["H1"], reviewedIDs: ["V1", "V2"])
        XCTAssertEqual(keys.count, 1)
        let reasons = batchPayDuplicateExclusions(
            [(id: "V1", order: orderObject(visible.values)), (id: "V2", order: orderObject(other.values))],
            placedKeys: [], hiddenKeys: keys)
        XCTAssertNotNil(reasons["V1"])
        XCTAssertTrue(reasons["V1"]?.contains("hid") == true)
        XCTAssertNil(reasons["V2"])
        // A hidden draft in the review itself, a locked one, or one paid since isn't counted here.
        XCTAssertTrue(batchPayHiddenDraftMarketplaceKeys(loaded, hidden: ["H1"], reviewedIDs: ["H1"]).isEmpty)
        XCTAssertTrue(batchPayHiddenDraftMarketplaceKeys(loaded, hidden: ["H1"], keeping: ["H1"], reviewedIDs: []).isEmpty)
        let paid = order("H1", status: "SUBMITTED", extra: ["metadata": ["source": "etsy", "sourceOrderId": "1001"]])
        XCTAssertTrue(batchPayHiddenDraftMarketplaceKeys([paid], hidden: ["H1"], reviewedIDs: []).isEmpty)
        // The placed-order check still reads every loaded order, hidden IDs or not.
        XCTAssertEqual(batchPayPlacedMarketplaceKeys([paid]).count, 1)
        // Without hidden drafts nothing changes.
        XCTAssertTrue(batchPayDuplicateExclusions([(id: "V1", order: orderObject(visible.values))], placedKeys: []).isEmpty)
    }

    /// Like the platform filter (PlatformScopeTests), the hidden-draft filter is used only where orders are listed; the
    /// files that pay, cancel, create drafts, confirm markers or guard duplicates never call it, and `orders` is never
    /// replaced by it.
    func testTheHiddenDraftFilterStaysOutOfGuardsAndWrites() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/Plinth")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        let allowed: Set<String> = ["HiddenDrafts.swift", "StudioStore.swift", "OrdersView.swift"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let uses = text.contains("ordersShownWithoutHiddenDrafts(") || text.contains("ordersShownInList")
                || text.contains("orderListIDsExcludingHiddenDrafts(")
            if uses { XCTAssertTrue(allowed.contains(file.lastPathComponent), "\(file.lastPathComponent) uses the hidden-draft filter") }
            XCTAssertFalse(text.contains("orders = ordersShownInList"), file.lastPathComponent)
            XCTAssertFalse(text.contains("orders = ordersShownWithoutHiddenDrafts"), file.lastPathComponent)
            if file.lastPathComponent == "HiddenDrafts.swift" {
                // The file with Pay Several Drafts' hidden-draft keys never reads the display lists.
                XCTAssertFalse(text.contains("ordersOnDefaultPlatform"))
                XCTAssertFalse(text.contains("ordersShownOnPlatform("))
            }
        }
    }

    // MARK: Copy

    func testHiddenDraftsLine() {
        XCTAssertNil(orderHiddenDraftsLine(0))
        XCTAssertEqual(orderHiddenDraftsLine(1), "1 hidden draft isn’t shown. Turn on Show Hidden Drafts in the Status menu to see them.")
        XCTAssertTrue(orderHiddenDraftsLine(2)?.hasPrefix("2 hidden drafts aren’t shown.") == true)
    }

    func testNotShownLineMergesHiddenDraftsAndOtherPlatforms() {
        XCTAssertNil(orderNotShownLine(hiddenDrafts: 0, otherPlatforms: 0))
        XCTAssertEqual(orderNotShownLine(hiddenDrafts: 3, otherPlatforms: 2), "Not shown: 3 hidden drafts, 2 orders on other platforms")
        XCTAssertEqual(orderNotShownLine(hiddenDrafts: 1, otherPlatforms: 0), "Not shown: 1 hidden draft")
        XCTAssertEqual(orderNotShownLine(hiddenDrafts: 0, otherPlatforms: 1), "Not shown: 1 order on another platform")
        XCTAssertTrue(orderNotShownHelp(hiddenDrafts: 1, otherPlatforms: 1).contains("Show Hidden Drafts"))
        XCTAssertTrue(orderNotShownHelp(hiddenDrafts: 0, otherPlatforms: 1).contains("default platform"))
        XCTAssertFalse(orderNotShownHelp(hiddenDrafts: 0, otherPlatforms: 1).contains("Hidden"))
        XCTAssertEqual(orderHiddenDraftDetailNote, "Hidden on this Mac; Slant still has it, and it costs nothing unless you place it.")
    }

    /// A hidden draft listed by Show Hidden Drafts never needs attention.
    func testHiddenRowsCarryNoAttention() {
        let old = Date(timeIntervalSinceNow: -10 * 86_400)
        let iso = ISO8601DateFormatter().string(from: old)
        let record = order("D1", extra: ["createdAt": iso])
        XCTAssertNotNil(OrderTableRow(record: record).attention)
        let hiddenRow = OrderTableRow(record: record, isHiddenDraft: true)
        XCTAssertNil(hiddenRow.attention)
        XCTAssertTrue(hiddenRow.isHiddenDraft)
    }

    // MARK: Tracking

    func testCopyTrackingMenuItem() {
        XCTAssertNil(orderCopyTrackingMenuItem([]))
        XCTAssertEqual(orderCopyTrackingMenuItem(["TRK1"])?.title, "Copy Tracking Number")
        XCTAssertEqual(orderCopyTrackingMenuItem(["TRK1"])?.value, "TRK1")
        let several = orderCopyTrackingMenuItem(["TRK1", "TRK2", "TRK3"])
        XCTAssertEqual(several?.title, "Copy Tracking Numbers")
        XCTAssertEqual(several?.value, "TRK1\nTRK2\nTRK3", "all of them, one per line")
    }

    func testSearchFindsTrackingNumbers() {
        let record = order("S1", status: "SHIPPED", extra: ["fulfillment": ["trackingNumbers": ["9400TESTTRACK01"]]])
        XCTAssertTrue(orderMatchesSearch(record, query: "testtrack01"))
        XCTAssertFalse(orderMatchesSearch(record, query: "OTHERTRACK"))
    }

    // MARK: Export columns

    func testExportReferenceColumns() throws {
        XCTAssertEqual(Array(ordersCSVBaseColumns.suffix(5)), ["Marketplace", "Marketplace order", "Paid", "Status in Plinth", "Shipping label created"])
        let record = Record(values: [
            "publicId": "S1", "status": "PRINTING",
            "processedAt": "2026-10-04T10:00:00.000Z",
            "metadata": ["source": "shopify", "sourceOrderId": "#1001"],
            "fulfillment": ["status": "SHIPPED", "createdAt": "2026-10-06T08:30:00Z", "trackingNumbers": ["T1"]]
        ])
        let values = ordersCSVReferenceValues(orderObject(record.values))
        XCTAssertEqual(values, ["Shopify", "#1001", "2026-10-04T10:00:00Z", "SHIPPED", "2026-10-06T08:30:00Z"])
        // Slant's own status column is unchanged.
        let row = ordersCSVRow(record, includeAddresses: false)
        XCTAssertEqual(row[2], "PRINTING")
        XCTAssertEqual(row.count, ordersCSVBaseColumns.count)

        XCTAssertEqual(orderMarketplaceName(source: "etsy"), "Etsy")
        XCTAssertEqual(orderMarketplaceName(source: "csv"), "CSV import")
        XCTAssertEqual(orderMarketplaceName(source: " MyShop "), "MyShop")
        XCTAssertEqual(orderMarketplaceName(source: nil), "")

        // Missing or unreadable values: blank, or as Slant sent them.
        XCTAssertEqual(ordersCSVReferenceValues(["status": "DRAFT", "processedAt": NSNull(), "fulfillment": NSNull()]),
                       ["", "", "", "DRAFT", ""])
        XCTAssertEqual(ordersCSVReferenceValues(["processedAt": "soon"])[2], "soon")
        XCTAssertEqual(ordersCSVReferenceValues([:]), ["", "", "", "", ""])
    }

    func testExportReferenceColumnsAreFormulaGuarded() throws {
        let record = Record(values: [
            "publicId": "S1", "status": "SHIPPED",
            "metadata": ["source": "=cmd|' /C calc'!A0", "sourceOrderId": "@SUM(A1)"],
            "processedAt": "+1 555"
        ])
        let csv = ordersCSV([record], includeAddresses: false)
        XCTAssertTrue(csv.contains("'=cmd|' /C calc'!A0"))
        XCTAssertTrue(csv.contains("'@SUM(A1)"))
        XCTAssertTrue(csv.contains("'+1 555"))
        XCTAssertFalse(csv.contains(",=cmd"))
        XCTAssertFalse(csv.contains(",@SUM"))
    }
}
