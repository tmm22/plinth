import XCTest
@testable import SlantStudio

/// Slant's `GET /orders` didn't filter by `platformId` in Studio's tests, and every order seen names its platform in
/// `customer.platformId` (no top-level `platformId`). Studio scopes what it shows and sums locally, while duplicate,
/// draft-marker, lock and charge checks keep reading every loaded order. All IDs and values here are invented.
final class PlatformScopeTests: XCTestCase {
    private let own = "plat-own-0001"
    private let other = "plat-other-0002"

    /// Shaped like a live list row: the platform only in `customer.platformId`, next to the customer's details.
    private func order(_ id: String, platform: String?, status: String = "SUBMITTED", metadata: Any? = nil,
                       createdAt: String = "2026-01-05T10:00:00Z") -> Record {
        var customer: [String: Any] = ["details": ["email": "buyer@example.com",
                                                   "address": ["name": "Test Buyer", "line1": "1 Example Road", "city": "Exampleton",
                                                               "zip": "00000", "country": "US", "state": "CA"]]]
        if let platform { customer["platformId"] = platform }
        var values: [String: Any] = ["publicId": id, "status": status, "createdAt": createdAt, "customer": customer,
                                     "printingCost": "10.00", "deliveryCost": "5.00",
                                     "items": [["type": "PRINT", "price": "10.00", "currency": "USD", "quantity": 1]]]
        if let metadata { values["metadata"] = metadata }
        return Record(values: values)
    }

    // MARK: The predicate

    func testPlatformMatchReadsCustomerPlatformFirst() {
        XCTAssertEqual(orderPlatformMatch(["customer": ["platformId": own]], platformID: own), true)
        XCTAssertEqual(orderPlatformMatch(["customer": ["platformId": " \(own) "]], platformID: " \(own)"), true)
        // The live shape: only `customer.platformId` names the other platform.
        XCTAssertEqual(orderPlatformMatch(["customer": ["platformId": other]], platformID: own), false)
        // A top-level `platformId` is read only when the customer names none.
        XCTAssertEqual(orderPlatformMatch(["platformId": other], platformID: own), false)
        XCTAssertEqual(orderPlatformMatch(["platformId": own, "customer": ["details": [:]]], platformID: own), true)
        XCTAssertEqual(orderPlatformMatch(["platformId": own, "customer": ["platformId": other]], platformID: own), false)
        // Nothing to judge: no platform named, an odd shape, or no default platform.
        XCTAssertNil(orderPlatformMatch(["publicId": "SLANT_X"], platformID: own))
        XCTAssertNil(orderPlatformMatch(["customer": ["platformId": "  "], "platformId": NSNull()], platformID: own))
        XCTAssertNil(orderPlatformMatch(["customer": "odd", "platformId": 7], platformID: own))
        XCTAssertNil(orderPlatformMatch(["customer": ["platformId": other]], platformID: "  "))
        XCTAssertNil(orderNamedPlatformID(["platform": ["name": "Shop"]]))
        XCTAssertEqual(orderNamedPlatformID(["customer": ["platformId": other], "platformId": own]), other)
    }

    func testShownOrdersLeaveOutOnlyOtherPlatforms() {
        let rows = [order("SLANT_A", platform: own), order("SLANT_B", platform: other), order("SLANT_C", platform: nil),
                    Record(values: ["order": ["publicId": "SLANT_D", "customer": ["platformId": other]], "publicId": "SLANT_D"])]
        XCTAssertEqual(ordersShownOnPlatform(rows, platformID: own).map(\.id), ["SLANT_A", "SLANT_C"])
        // No default platform: nothing is left out.
        XCTAssertEqual(ordersShownOnPlatform(rows, platformID: "").map(\.id), ["SLANT_A", "SLANT_B", "SLANT_C", "SLANT_D"])
        // An order under the pay/cancel lock stays listed, so its Reload Order can lift the lock.
        XCTAssertEqual(ordersShownOnPlatform(rows, platformID: own, keeping: ["SLANT_B"]).map(\.id), ["SLANT_A", "SLANT_B", "SLANT_C"])
        // Matched by any of its IDs (the lock keeps every alias).
        let aliased = Record(values: ["publicId": "SLANT_E", "id": "internal-e", "customer": ["platformId": other]])
        XCTAssertEqual(ordersShownOnPlatform([aliased], platformID: own, keeping: ["internal-e"]).map(\.id), ["SLANT_E"])
        XCTAssertEqual(ordersShownOnPlatform([aliased], platformID: own, keeping: ["SLANT_Z"]).count, 0)
    }

    func testHiddenLineCountsOrders() {
        XCTAssertNil(orderOtherPlatformsHiddenLine(0))
        XCTAssertNil(orderOtherPlatformsHiddenLine(-1))
        XCTAssertEqual(orderOtherPlatformsHiddenLine(1),
                       "1 loaded order on another platform isn’t shown: Orders lists your default platform’s orders (Settings › Account).")
        XCTAssertTrue(orderOtherPlatformsHiddenLine(3)?.hasPrefix("3 loaded orders on other platforms aren’t shown") == true)
    }

    // MARK: Where it applies

    func testSpendingReportLeavesOutAnotherPlatformsOrder() {
        let rows = [order("SLANT_A", platform: own), order("SLANT_B", platform: other), order("SLANT_C", platform: nil)]
        let all = spendReport(orders: rows)
        let scoped = spendReport(orders: ordersShownOnPlatform(rows, platformID: own))
        XCTAssertEqual(all.countedOrders, 3)
        XCTAssertEqual(scoped.countedOrders, 2)
        XCTAssertEqual(spendReportOtherPlatformsNote(0), nil)
        XCTAssertEqual(spendReportOtherPlatformsNote(1), "1 order on another platform isn’t included.")
        XCTAssertEqual(spendReportOtherPlatformsNote(2), "2 orders on other platforms aren’t included.")
        XCTAssertEqual(spendReportScopeNotes(searchActive: false, statusFilter: nil, hasDateRange: false, moreOnServer: false,
                                             otherPlatformOrders: 2), ["2 orders on other platforms aren’t included."])
        XCTAssertEqual(spendReportScopeNotes(searchActive: false, statusFilter: nil, hasDateRange: false, moreOnServer: false), [])
        let named = spendReportPeriodNotes(platformName: "Shop", complete: true, capReached: false, loadedCount: 3, lastCreated: nil,
                                           otherPlatformOrders: 1)
        XCTAssertEqual(named.first, "Only orders on the platform “Shop” are included. 1 order on another platform isn’t included.")
        XCTAssertFalse(named.joined().contains("like the Orders list"))
        let unnamed = spendReportPeriodNotes(platformName: nil, complete: true, capReached: false, loadedCount: 3, lastCreated: nil,
                                             otherPlatformOrders: 1)
        XCTAssertEqual(unnamed.first, "1 order on another platform isn’t included.")
    }

    func testOrderWatchRecordsOnlyTheDefaultPlatformsOrders() {
        let rows = [order("SLANT_A", platform: own, status: "SHIPPED"), order("SLANT_B", platform: other, status: "SHIPPED")]
        XCTAssertEqual(orderWatchObservations(ordersShownOnPlatform(rows, platformID: own)).map(\.id), ["SLANT_A"])
    }

    /// The checks that guard against a duplicate sale or a repeated draft see every loaded order, whatever platform
    /// it names: they take the raw list, so a re-import or a batch never misses an order on the old default platform.
    func testDuplicateAndMarkerChecksStillSeeOtherPlatformsOrders() {
        let marker = "6f1c2a9e-0000-4000-8000-000000000001"
        let placed = order("SLANT_B", platform: other, status: "SUBMITTED",
                           metadata: ["source": "etsy", "sourceOrderId": "9000001", studioDraftMarkerKey: marker])
        let raw = [order("SLANT_A", platform: own), placed]
        XCTAssertEqual(batchPayPlacedMarketplaceKeys(raw).count, 1)
        XCTAssertFalse(orderImportLoadedSourceKeys(raw).isEmpty)
        XCTAssertEqual(ordersCarryingDraftMarkers(raw, markers: [marker])[marker]?.id, "SLANT_B")
        // The display list alone would miss it, which is why those checks never read it.
        let shown = ordersShownOnPlatform(raw, platformID: own)
        XCTAssertTrue(batchPayPlacedMarketplaceKeys(shown).isEmpty)
    }

    /// The display filter is used only where orders are shown or summed; the files that pay, cancel, create drafts,
    /// confirm markers or guard duplicates never call it.
    func testTheDisplayFilterStaysOutOfGuardsAndWrites() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/SlantStudio")
        let files = try FileManager.default.contentsOfDirectory(at: sources, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(files.count, 20)
        let allowed: Set<String> = ["OrderTools.swift", "StudioStore.swift", "OrdersView.swift", "SpendReport.swift", "OrderWatch.swift"]
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let uses = text.contains("ordersShownOnPlatform(") || text.contains("ordersOnDefaultPlatform")
            if uses { XCTAssertTrue(allowed.contains(file.lastPathComponent), "\(file.lastPathComponent) uses the platform display filter") }
            if file.lastPathComponent == "OrdersView.swift" {
                // The selected order and the review's marketplace-duplicate notice read every loaded order.
                XCTAssertTrue(text.contains("var selected: Record? { store.orders.first { $0.id == selection } }"))
                XCTAssertTrue(text.contains("orderReviewMarketplaceDuplicateNotice(order, orderID: orderID, loaded: store.orders)"))
            }
            if file.lastPathComponent == "StudioStore.swift" {
                // Loads and reloads keep writing Slant's rows (date-trimmed) into `orders`, never the display list.
                XCTAssertFalse(text.contains("orders = ordersShownOnPlatform"))
                XCTAssertFalse(text.contains("orders = ordersOnDefaultPlatform"))
            }
        }
    }
}
