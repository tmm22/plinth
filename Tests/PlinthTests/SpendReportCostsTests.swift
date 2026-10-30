import XCTest
@testable import SlantStudio

/// Spending Report: printing cost per product, delivery per country, and Load the Whole Period's pure helpers.
final class SpendReportCostsTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    private func printItem(_ file: String, quantity: Any, price: Any?, sku: Any? = NSNull(), currency: String = "USD") -> [String: Any] {
        var item: [String: Any] = ["type": "PRINT", "status": "PROCESSING", "currency": currency, "quantity": quantity,
                                   "SKU": sku ?? NSNull(), "name": NSNull(),
                                   "printItem": ["publicFileServiceId": file, "name": NSNull(), "SKU": NSNull()],
                                   "publicFileServiceId": file]
        if let price { item["price"] = price }
        return item
    }

    /// Mirrors the live order list's shape with synthetic values: costs as strings, the item price is the whole line's price.
    private func order(_ id: String, status: String = "QUEUED", created: String = "2026-10-12T09:30:15.250Z",
                       printing: Any? = nil, delivery: Any? = nil, country: Any? = "AU",
                       items: [[String: Any]] = [], extra: [String: Any] = [:]) -> Record {
        var values: [String: Any] = ["publicId": id, "status": status, "createdAt": created, "items": items,
                                     "customer": ["details": ["address": ["country": country ?? NSNull(), "city": "Example City"]]]]
        if let printing { values["printingCost"] = printing }
        if let delivery { values["deliveryCost"] = delivery }
        for (key, value) in extra { values[key] = value }
        return Record(values: values)
    }

    // MARK: Printing cost per product

    func testItemPriceIsTheLineTotalAndAveragesPerUnit() {
        let orders = [
            order("A", printing: "16.90", delivery: "41.20", items: [printItem("f1", quantity: 2, price: "16.90")]),
            order("B", printing: "8.45", delivery: "41.20", items: [printItem("f1", quantity: 1, price: "8.45")]),
            order("C", printing: "6.15", delivery: "22.80", items: [printItem("f2", quantity: 1, price: "6.15")]),
        ]
        let report = spendReport(orders: orders, modelNames: ["f1": "Desk Tidy", "f2": "Bracket"])
        XCTAssertEqual(report.productCosts.map(\.name), ["Desk Tidy", "Bracket"])
        let tidy = report.productCosts[0]
        XCTAssertEqual(tidy.orders, 2)
        XCTAssertEqual(tidy.units, 3)
        XCTAssertEqual(tidy.total, Decimal(string: "25.35"))
        XCTAssertEqual(tidy.averagePerUnit, Decimal(string: "8.45"))
        XCTAssertEqual(report.ordersWithoutItemPrices, 0)
    }

    func testOrdersWhosePricesDontAddUpAreLeftOutNotSplit() {
        let orders = [
            // Two prints with one order-level cost that doesn't match the items: never split by guesswork.
            order("A", printing: "30.00", items: [printItem("f1", quantity: 1, price: "8.45"), printItem("f2", quantity: 1, price: "6.15")]),
            // No item price at all.
            order("B", printing: "8.45", items: [printItem("f1", quantity: 1, price: nil)]),
            // No order printing cost to check against.
            order("C", items: [printItem("f1", quantity: 1, price: "8.45")]),
            // A non-USD item price.
            order("D", printing: "8.45", items: [printItem("f1", quantity: 1, price: "8.45", currency: "EUR")]),
            // A fractional quantity.
            order("E", printing: "8.45", items: [printItem("f1", quantity: 1.5, price: "8.45")]),
            // Junk that a lenient parser would read as 8.
            order("F", printing: "8.45", items: [printItem("f1", quantity: 1, price: "8.45abc")]),
            // Order in another currency.
            order("G", printing: "8.45", items: [printItem("f1", quantity: 1, price: "8.45")], extra: ["currency": "GBP"]),
        ]
        let report = spendReport(orders: orders)
        XCTAssertTrue(report.productCosts.isEmpty)
        XCTAssertEqual(report.ordersWithoutItemPrices, 7)
        XCTAssertEqual(spendReportItemPriceExclusionLine(report),
                       "7 orders are left out because their item prices were missing or didn’t add up to the order’s printing cost.")
    }

    func testMultiItemOrderWithMatchingPricesCountsEachPrint() {
        let component: [String: Any] = ["type": "COMPONENT", "componentId": "c1", "quantity": 4, "price": "2.00", "currency": "USD"]
        let orders = [order("A", printing: "16.60", items: [printItem("f1", quantity: 1, price: "8.45"),
                                                            printItem("f2", quantity: 1, price: "6.15"), component])]
        let report = spendReport(orders: orders)
        XCTAssertEqual(report.productCosts.count, 2, "components aren't printing products")
        XCTAssertEqual(Set(report.productCosts.map(\.total)), [Decimal(string: "8.45")!, Decimal(string: "6.15")!])
    }

    func testSinglePrintSavedProductGroupsReuploadsBySKU() {
        let model = LocalModel(name: "Tidy", filePath: "/tmp/t.stl", remoteID: "f-new")
        var line = SavedProductLine()
        line.reference = "f-old"
        line.localModelID = model.id
        line.filamentID = "pla"
        let product = SavedProduct(name: "Desk Tidy", sku: "TIDY-1", lines: [line])
        let skus = spendReportProductSKUs([product], localModels: [model])
        let orders = [
            order("A", printing: "8.45", items: [printItem("f-old", quantity: 1, price: "8.45")]),
            order("B", printing: "21.00", items: [printItem("f-new", quantity: 2, price: "21.00")]),
            // The item's own SKU, as drafts from the saved product send it, in another case.
            order("C", printing: "10.50", items: [printItem("f-other", quantity: 1, price: "10.50", sku: "tidy-1")]),
        ]
        let report = spendReport(orders: orders, modelNames: ["f-new": "Tidy"], productSKUs: skus)
        XCTAssertEqual(report.productCosts.count, 1)
        XCTAssertEqual(report.productCosts[0].key, "sku:tidy-1")
        XCTAssertEqual(report.productCosts[0].orders, 3)
        XCTAssertEqual(report.productCosts[0].units, 4)
        XCTAssertEqual(report.productCosts[0].averagePerUnit, Decimal(string: "9.99"), "39.95 ÷ 4 = 9.9875, to the cent")
    }

    func testAnUnknownSKUDoesNotMergeDifferentFiles() {
        let orders = [
            order("A", printing: "8.45", items: [printItem("f1", quantity: 1, price: "8.45", sku: "KIT")]),
            order("B", printing: "6.15", items: [printItem("f2", quantity: 1, price: "6.15", sku: "KIT")]),
        ]
        let report = spendReport(orders: orders)
        XCTAssertEqual(report.productCosts.count, 2, "a multi-print product's parts keep their own rows")
    }

    func testDraftsAndCancelledOrdersAreNotCosted() {
        let orders = [
            order("A", status: "DRAFT", printing: "8.45", delivery: "41.20", items: [printItem("f1", quantity: 1, price: "8.45")]),
            order("B", status: "CANCELED", printing: "8.45", delivery: "41.20", items: [printItem("f1", quantity: 1, price: "8.45")]),
        ]
        let report = spendReport(orders: orders)
        XCTAssertTrue(report.productCosts.isEmpty)
        XCTAssertTrue(report.deliveryCosts.isEmpty)
        XCTAssertEqual(report.ordersWithoutDelivery, 0)
    }

    // MARK: Delivery per country

    func testDeliveryPerCountryWithAverageAndRange() {
        let orders = [
            order("A", delivery: "41.20", country: "AU"),
            order("B", delivery: "22.80", country: "Australia"),
            order("C", delivery: NSNumber(value: 30), country: "au"),
            order("D", delivery: "12.00", country: "GB"),
            order("E", delivery: "5.00", country: "Atlantis"),
            order("F", delivery: nil, country: "GB"),
            order("G", delivery: "not a number", country: "GB"),
        ]
        let report = spendReport(orders: orders)
        XCTAssertEqual(report.deliveryCosts.map(\.countryCode), ["AU", "GB", ""], "most orders first, unrecognised last")
        let au = report.deliveryCosts[0]
        XCTAssertEqual(au.orders, 3)
        XCTAssertEqual(au.total, Decimal(string: "94.00"))
        XCTAssertEqual(au.average, Decimal(string: "31.33"))
        XCTAssertEqual(au.lowest, Decimal(string: "22.80"))
        XCTAssertEqual(au.highest, Decimal(string: "41.20"))
        XCTAssertEqual(spendReportRangeText(au), "$22.80–$41.20")
        XCTAssertEqual(spendReportRangeText(report.deliveryCosts[1]), "$12.00")
        XCTAssertEqual(report.ordersWithoutDelivery, 2)
        XCTAssertEqual(spendReportCountryTitle("AU", locale: Locale(identifier: "en_GB")), "Australia (AU)")
        XCTAssertEqual(spendReportCountryTitle(""), "Country not recognised")
    }

    func testTextAndCSVIncludeCostsThroughCSVField() {
        let orders = [
            order("A", printing: "16.90", delivery: "41.20", items: [printItem("f1", quantity: 2, price: "16.90")]),
            order("B", printing: "6.15", delivery: "22.80", items: [printItem("f2", quantity: 1, price: "6.15")]),
        ]
        let report = spendReport(orders: orders, modelNames: ["f1": "=SUM(A1)", "f2": "Bracket"], calendar: calendar("UTC"))
        let csv = spendReportCSV(report)
        XCTAssertTrue(csv.contains("\r\n\r\nProduct,SKU,Orders,Units,Printing cost (USD),Average per unit (USD)\r\n"))
        XCTAssertTrue(csv.contains("'=SUM(A1),,1,2,16.90,8.45\r\n"), csv)
        XCTAssertTrue(csv.contains("Bracket,,1,1,6.15,6.15\r\n"))
        XCTAssertTrue(csv.contains("Destination country,Country code,Orders,Delivery (USD),Average (USD),Lowest (USD),Highest (USD)\r\n"))
        XCTAssertTrue(csv.contains("Australia (AU),AU,2,64.00,32.00,22.80,41.20\r\n"), csv)

        let text = spendReportText(report, notes: [], calendar: calendar("UTC"), source: "created 1 Aug – 24 Oct 2026, loaded for this report")
        XCTAssertTrue(text.contains("From 2 orders created 1 Aug – 24 Oct 2026, loaded for this report."))
        XCTAssertTrue(text.contains("Average printing cost per product\n"))
        XCTAssertTrue(text.contains("=SUM(A1) — 2 units in 1 order — $16.90 — $8.45 each\n"))
        XCTAssertTrue(text.contains("Delivery by destination country\n\(spendReportDeliveryCaption)\n"))
        XCTAssertTrue(text.contains(" — 2 orders — average $32.00 — $22.80–$41.20\n"))
    }

    func testExistingReportWithoutCostsIsUnchanged() {
        let report = spendReport(orders: [order("A", items: [])])
        XCTAssertFalse(spendReportCSV(report).contains("Product,"))
        XCTAssertFalse(spendReportText(report, notes: []).contains("Average printing cost"))
        XCTAssertTrue(spendReportText(report, notes: []).contains("in the loaded Orders list"))
    }

    // MARK: Load the whole period

    func testPeriodIntervalsUseWholeLocalMonths() {
        let cal = calendar("Australia/Sydney")
        let now = ISO8601DateFormatter().date(from: "2026-10-24T03:00:00Z")! // 14:00 on 24 Oct in Sydney
        func day(_ text: String) -> Date { cal.date(from: DateComponents(timeZone: cal.timeZone, year: Int(text.prefix(4)), month: Int(text.dropFirst(5).prefix(2)), day: Int(text.suffix(2))))! }
        XCTAssertEqual(spendReportPeriodInterval(.thisMonth, now: now, calendar: cal), SpendReportInterval(start: day("2026-10-01"), end: day("2026-10-25")))
        XCTAssertEqual(spendReportPeriodInterval(.last3Months, now: now, calendar: cal).start, day("2026-08-01"))
        XCTAssertEqual(spendReportPeriodInterval(.last12Months, now: now, calendar: cal).start, day("2025-11-01"))
        XCTAssertEqual(spendReportPeriodInterval(.thisYear, now: now, calendar: cal).start, day("2026-01-01"))
        XCTAssertEqual(spendReportPeriodInterval(.lastYear, now: now, calendar: cal), SpendReportInterval(start: day("2025-01-01"), end: day("2026-01-01")))
        // The formatter uses thin spaces around the dash, so compare without spacing.
        let title = spendReportIntervalTitle(spendReportPeriodInterval(.lastYear, now: now, calendar: cal), calendar: cal)
        XCTAssertEqual(title.unicodeScalars.filter { !CharacterSet.whitespaces.contains($0) }.map(String.init).joined(), "1Jan–31Dec2025")
    }

    func testPeriodQueryAsksForADayEitherSideOldestFirst() {
        let cal = calendar("Australia/Sydney")
        let interval = SpendReportInterval(start: cal.date(from: DateComponents(year: 2026, month: 8, day: 1))!,
                                           end: cal.date(from: DateComponents(year: 2026, month: 10, day: 25))!)
        let query = spendReportPeriodQuery(interval, page: 3, platformID: " plat-1 ", calendar: cal)
        XCTAssertEqual(query, ["page": "3", "limit": "100", "sortBy": "createdAt", "sortOrder": "ASC",
                               "startDate": "2026-07-31", "endDate": "2026-10-26", "platformId": "plat-1"])
        XCTAssertNil(spendReportPeriodQuery(interval, page: 1, platformID: "", calendar: cal)["platformId"])
        XCTAssertEqual(spendReportPeriodPageSize, listPageSize)
    }

    func testPagesAreTrimmedToThePeriodAndDeduplicated() {
        let interval = SpendReportInterval(start: ISO8601DateFormatter().date(from: "2026-10-01T00:00:00Z")!,
                                           end: ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!)
        let first = spendReportPeriodOrders([], adding: [
            order("A", created: "2026-09-30T23:59:59Z"),
            order("B", created: "2026-10-01T00:00:00Z"),
            order("C", created: "2026-10-31T23:59:59.999Z"),
        ], interval: interval)
        XCTAssertEqual(first.map { orderNumber($0.values) }, ["B", "C"])
        let second = spendReportPeriodOrders(first, adding: [
            order("C", created: "2026-10-31T23:59:59.999Z"),
            order("D", created: "2026-11-01T00:00:00Z"),
            Record(values: ["publicId": "E", "status": "PAID"]),
        ], interval: interval)
        XCTAssertEqual(second.map { orderNumber($0.values) }, ["B", "C", "E"], "repeats dropped; an undated order is kept to be counted")
    }

    func testPageStepsAndCap() {
        XCTAssertEqual(spendReportPageStep(pagesLoaded: 1, hasMore: true, pageWasEmpty: false), .next)
        XCTAssertEqual(spendReportPageStep(pagesLoaded: 1, hasMore: false, pageWasEmpty: false), .complete)
        XCTAssertEqual(spendReportPageStep(pagesLoaded: 7, hasMore: true, pageWasEmpty: true), .complete)
        XCTAssertEqual(spendReportPageStep(pagesLoaded: 50, hasMore: true, pageWasEmpty: false), .capReached)
        XCTAssertEqual(spendReportPageStep(pagesLoaded: 50, hasMore: false, pageWasEmpty: false), .complete)
        XCTAssertEqual(spendReportPeriodMaxPages, 50)
    }

    func testLoadBlockedReasonsAndProgress() {
        XCTAssertEqual(spendReportPeriodLoadBlockedReason(hasKey: false, connected: false, busy: false, running: false),
                       "Connect your account to load orders.")
        XCTAssertEqual(spendReportPeriodLoadBlockedReason(hasKey: true, connected: true, busy: true, running: false),
                       "Wait for the current task to finish.")
        XCTAssertNotNil(spendReportPeriodLoadBlockedReason(hasKey: true, connected: true, busy: true, running: true))
        XCTAssertNil(spendReportPeriodLoadBlockedReason(hasKey: true, connected: true, busy: false, running: false))
        XCTAssertEqual(spendReportLoadProgress(1), "Loaded 1 order…")
        XCTAssertTrue(spendReportLoadProgress(340).hasPrefix("Loaded 340 orders"))
    }

    func testPeriodNotesSayWhenItIsPartial() {
        let cal = calendar("UTC")
        let last = ISO8601DateFormatter().date(from: "2026-09-12T10:00:00Z")!
        let capped = spendReportPeriodNotes(platformName: "Shop", complete: false, capReached: true, loadedCount: 5000, lastCreated: last, calendar: cal)
        XCTAssertTrue(capped[0].contains("“Shop”"))
        XCTAssertTrue(capped[1].contains("at most 50 pages"))
        XCTAssertTrue(capped[1].contains("12 Sept 2026") || capped[1].contains("12 Sep 2026"), capped[1])
        let stopped = spendReportPeriodNotes(platformName: nil, complete: false, capReached: false, loadedCount: 340, lastCreated: nil, calendar: cal)
        XCTAssertTrue(stopped[0].contains("Continue Loading"))
        let done = spendReportPeriodNotes(platformName: nil, complete: true, capReached: false, loadedCount: 340, lastCreated: last, calendar: cal)
        XCTAssertEqual(done, ["These orders are only used here; the Orders list isn’t changed."])
    }

    func testOnlyReadablePagesCount() {
        XCTAssertTrue(spendReportPageIsReadable(["success": true, "data": [], "pagination": ["totalPages": 0]]))
        XCTAssertTrue(spendReportPageIsReadable(["data": ["orders": [["publicId": "A"]]]]))
        XCTAssertFalse(spendReportPageIsReadable(["success": false, "message": "Oops"]))
        XCTAssertFalse(spendReportPageIsReadable(["data": ["publicId": "A"]]))
        XCTAssertFalse(spendReportPageIsReadable(nil))
        XCTAssertFalse(spendReportPageIsReadable("text"))
    }

    func testCountryCacheGivesTheSameCodes() {
        var cache: [String: String] = [:]
        let named = order("A", country: "Australia").values
        XCTAssertEqual(spendReportCountryCode(named, cache: &cache), "AU")
        XCTAssertEqual(cache["Australia"], "AU")
        XCTAssertEqual(spendReportCountryCode(named, cache: &cache), "AU")
        XCTAssertEqual(spendReportCountryCode(order("B", country: NSNull()).values), "")
        XCTAssertEqual(spendReportCountryCode(order("C", country: "EU").values), "", "a region that isn't a country")
    }

    func testStopMessages() {
        XCTAssertEqual(spendReportLoadStopMessage(CancellationError()), "Stopped. Orders already loaded are kept.")
        XCTAssertEqual(spendReportLoadStopMessage(URLError(.cancelled)), "Stopped. Orders already loaded are kept.")
        XCTAssertEqual(spendReportLoadStopMessage(StudioError("Stopped because the default platform changed.")),
                       "Stopped because the default platform changed.")
        XCTAssertTrue(spendReportLoadStopMessage(APIError.http(status: 429, body: "", retryAfter: nil, rateLimitReset: nil)).hasPrefix("Stopped"))
        XCTAssertTrue(spendReportLoadStopMessage(APIError.http(status: 400, body: "{\"message\":\"Bad limit\"}", retryAfter: nil, rateLimitReset: nil)).hasPrefix("Stopped: "))
    }
}
