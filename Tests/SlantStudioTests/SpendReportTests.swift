import XCTest
@testable import SlantStudio

final class SpendReportTests: XCTestCase {
    private func order(_ id: String, status: String?, created: String?, total: Any? = nil,
                       items: [[String: Any]] = [], extra: [String: Any] = [:]) -> Record {
        var values: [String: Any] = ["publicId": id, "items": items]
        if let status { values["status"] = status }
        if let created { values["createdAt"] = created }
        if let total { values["total"] = total }
        for (key, value) in extra { values[key] = value }
        return Record(values: values)
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    func testMonthsUseTheSellersTimeZoneAndDecimalTotals() {
        let orders = [
            order("A", status: "SHIPPED", created: "2026-10-31T23:30:00Z", total: "10.10"),
            order("B", status: "PAID", created: "2026-10-15T12:00:00.000Z", total: 0.2),
            order("C", status: "DELIVERED", created: "2026-09-30T10:00:00Z", total: NSNumber(value: 5)),
        ]
        let utc = spendReport(orders: orders, calendar: calendar("UTC"))
        XCTAssertEqual(utc.months.map(\.id), ["2026-10", "2026-09"])
        XCTAssertEqual(utc.months[0].orders, 2)
        XCTAssertEqual(utc.months[0].spend, Decimal(string: "10.3"), "Decimal, so 10.10 + 0.2 is exactly 10.30")
        XCTAssertEqual(utc.totalSpend, Decimal(string: "15.3"))
        XCTAssertEqual(utc.countedOrders, 3)

        // Late on 31 October in UTC is already November in Sydney.
        let sydney = spendReport(orders: orders, calendar: calendar("Australia/Sydney"))
        XCTAssertEqual(sydney.months.map(\.id), ["2026-11", "2026-10", "2026-09"])
        // And 30 September 10:00 UTC is still 29/30 September in Los Angeles.
        let la = spendReport(orders: orders, calendar: calendar("America/Los_Angeles"))
        XCTAssertEqual(la.months.map(\.id), ["2026-10", "2026-09"])
    }

    func testDraftsCancelledAndUnknownStatusesAreLeftOutAndCounted() {
        let orders = [
            order("D", status: "DRAFT", created: "2026-10-01T00:00:00Z", total: 99),
            order("X", status: "CANCELED", created: "2026-10-01T00:00:00Z", total: 99),
            order("E", status: "PAYMENT_ERROR", created: "2026-10-01T00:00:00Z", total: 99),
            order("F", status: "REFUNDED", created: "2026-10-01T00:00:00Z", total: 99),
            order("G", status: nil, created: "2026-10-01T00:00:00Z", total: 99),
            order("H", status: "shipped", created: "2026-10-01T00:00:00Z", total: 1),
            order("I", status: "PRINTING", created: nil, total: 99),
            order("J", status: "PRINTING", created: "not a date", total: 99),
        ]
        let report = spendReport(orders: orders, calendar: calendar("UTC"))
        XCTAssertEqual(report.countedOrders, 1)
        XCTAssertEqual(report.totalSpend, 1)
        XCTAssertEqual(report.excludedDrafts, 1)
        XCTAssertEqual(report.excludedCancelled, 1)
        XCTAssertEqual(report.excludedOther, 3)
        XCTAssertEqual(report.undated, 2)
        XCTAssertEqual(spendReportExclusionLine(report),
                       "Left out: 1 draft, 1 cancelled order, 3 orders with a payment error or another status, 2 orders without a date.")
        XCTAssertNil(spendReportExclusionLine(SpendReport()))
    }

    func testMissingTotalsAndOtherCurrenciesAreCountedButNotSummed() {
        let orders = [
            order("A", status: "PAID", created: "2026-10-02T00:00:00Z"),
            order("B", status: "PAID", created: "2026-10-03T00:00:00Z", total: "n/a"),
            order("C", status: "PAID", created: "2026-10-04T00:00:00Z", total: 7, extra: ["currency": "EUR"]),
            order("D", status: "PAID", created: "2026-10-05T00:00:00Z", extra: ["printingCost": "3.50", "deliveryCost": "4.25"]),
            order("E", status: "PAID", created: "2026-10-06T00:00:00Z", total: 2, extra: ["currency": "usd"]),
        ]
        let report = spendReport(orders: orders, calendar: calendar("UTC"))
        XCTAssertEqual(report.countedOrders, 5)
        XCTAssertEqual(report.months.first?.orders, 5)
        XCTAssertEqual(report.ordersWithoutTotal, 3)
        XCTAssertEqual(report.months.first?.ordersWithoutTotal, 3)
        XCTAssertEqual(report.totalSpend, Decimal(string: "9.75"), "the list's total precedence: printing + delivery")
    }

    func testRepeatedOrdersAreCountedOnce() {
        let a = order("A", status: "PAID", created: "2026-10-02T00:00:00Z", total: 5)
        let report = spendReport(orders: [a, a, Record(values: ["order": a.values])], calendar: calendar("UTC"))
        XCTAssertEqual(report.countedOrders, 1)
        XCTAssertEqual(report.totalSpend, 5)
    }

    func testUnitsPerItemAreNamedAndRanked() {
        let tidy: [String: Any] = ["type": "PRINT", "publicFileServiceId": "file-tidy", "quantity": 3, "name": NSNull()]
        let tidyNested: [String: Any] = ["type": "PRINT", "printItem": ["publicFileServiceId": "file-tidy"], "quantity": "2"]
        let mystery: [String: Any] = ["type": "PRINT", "publicFileServiceId": "abcdef1234567890", "quantity": 4]
        let card: [String: Any] = ["type": "STATIONERY", "stationeryId": "st-1", "stationeryName": "Thank-you card", "quantity": 1]
        let hook: [String: Any] = ["type": "PRINT", "publicFileServiceId": "file-hook", "quantity": 4, "SKU": "HK-1"]
        let odd: [String: Any] = ["type": "PRINT", "publicFileServiceId": "file-hook", "quantity": 1.5]
        let orders = [
            order("A", status: "PAID", created: "2026-10-02T00:00:00Z", total: 1, items: [tidy, card, tidyNested]),
            order("B", status: "SHIPPED", created: "2026-09-02T00:00:00Z", total: 1, items: [mystery, card, hook, odd]),
            order("D", status: "DRAFT", created: "2026-09-02T00:00:00Z", total: 1, items: [tidy, tidy, tidy]),
        ]
        let report = spendReport(orders: orders, modelNames: ["file-tidy": "Desk Tidy", "file-hook": "Wall Hook"],
                                 productSKUs: ["file-tidy": "DT-1", "file-hook": "PRODUCT-SKU"], calendar: calendar("UTC"))
        XCTAssertEqual(report.items.map(\.name), ["Desk Tidy", "3D print (abcdef12…)", "Wall Hook", "Thank-you card"])
        XCTAssertEqual(report.items.map(\.units), [5, 4, 4, 2])
        XCTAssertEqual(report.items.map(\.orders), [1, 1, 1, 2])
        XCTAssertEqual(report.items.map(\.sku), ["DT-1", nil, "HK-1", nil], "the item's own SKU wins over the saved product's")
        XCTAssertEqual(report.itemsWithoutQuantity, 1)
        XCTAssertEqual(spendReportItemTitle(report.items[0]), "Desk Tidy (SKU DT-1)")
    }

    func testProductSKUsOnlyWhenUnambiguous() {
        let model = LocalModel(name: "Tidy", filePath: "/tmp/tidy.stl", remoteID: "file-new")
        func product(_ sku: String, _ lines: [SavedProductLine]) -> SavedProduct {
            var product = SavedProduct()
            product.sku = sku
            product.lines = lines
            return product
        }
        var linked = SavedProductLine()
        linked.reference = "file-old"
        linked.localModelID = model.id
        var hook = SavedProductLine()
        hook.reference = "file-hook"
        var card = SavedProductLine()
        card.type = "STATIONERY"
        card.reference = "st-1"
        var shared = SavedProductLine()
        shared.reference = "file-shared"
        let map = spendReportProductSKUs([
            product("DT-1", [linked, card]),          // one print line plus stationery: fine
            product(" ", [hook]),                     // no SKU
            product("A", [shared]), product("B", [shared]),  // two SKUs for one file: ambiguous
            product("BUNDLE", [hook, shared]),        // several print lines: not credited
        ], localModels: [model])
        XCTAssertEqual(map, ["file-old": "DT-1", "file-new": "DT-1"])
    }

    func testScopeNotesSayWhatTheListCovers() {
        XCTAssertEqual(spendReportScopeNotes(searchActive: false, statusFilter: nil, hasDateRange: false, moreOnServer: false), [])
        let notes = spendReportScopeNotes(searchActive: true, statusFilter: "SHIPPED", hasDateRange: true, moreOnServer: true)
        XCTAssertEqual(notes.count, 4)
        XCTAssertTrue(notes[1].contains("Shipped"))
        XCTAssertTrue(notes[3].contains("Load More"))
    }

    func testTextAndCSV() {
        var cal = calendar("UTC")
        cal.locale = Locale(identifier: "en_GB")
        let orders = [
            order("A", status: "PAID", created: "2026-10-02T00:00:00Z", total: "1234.5",
                  items: [["type": "PRINT", "publicFileServiceId": "f1", "name": "=HYPERLINK(\"x\")", "quantity": 2]]),
            order("B", status: "PAID", created: "2026-09-02T00:00:00Z"),
        ]
        let report = spendReport(orders: orders, calendar: cal)
        let csv = spendReportCSV(report)
        XCTAssertEqual(csv, [
            "Month,Orders,Spend (USD),Orders without a total",
            "2026-10,1,1234.50,0",
            "2026-09,1,0.00,1",
            "Total,2,1234.50,1",
            "",
            "Item,SKU,Units,Orders",
            "\"'=HYPERLINK(\"\"x\"\")\",,2,1",
        ].joined(separator: "\r\n") + "\r\n")
        let text = spendReportText(report, notes: ["Note."], calendar: cal)
        XCTAssertTrue(text.hasPrefix("Slant spending report\nFrom 2 orders in the loaded Orders list."))
        XCTAssertTrue(text.contains("Note.\n"))
        XCTAssertTrue(text.contains("October 2026 — 1 — $1234.50\n"))
        XCTAssertTrue(text.contains("September 2026 — 1 — $0.00 (1 without a total)\n"))
        XCTAssertTrue(text.contains("Total — 2 — $1234.50\n"))
        XCTAssertTrue(text.contains("— 2 units in 1 order\n"))
        XCTAssertEqual(spendReportDefaultFileName(date: Date(timeIntervalSince1970: 0)).hasPrefix("Slant spending 19"), true)
    }

    func testEmptyReport() {
        let report = spendReport(orders: [])
        XCTAssertEqual(report, SpendReport())
        XCTAssertTrue(spendReportCSV(report).contains("Total,0,0.00,0"))
    }

    func testOrdersPhrase() {
        XCTAssertEqual(spendReportOrdersPhrase(0), "the orders")
        XCTAssertEqual(spendReportOrdersPhrase(1), "the 1 order")
        XCTAssertEqual(spendReportOrdersPhrase(12), "the 12 orders")
    }
}
