import XCTest
@testable import Plinth

// The read-only 3DAPI order tools (DapiOrderInsights.swift): attention, cost and profit, Report a Problem, the CSV
// export, the spending report and its period loader (against a scripted `DapiOrdering`), and tracking. No network,
// no Keychain, no StudioStore.

func insightUSD(_ minor: Int) -> DapiMoney { DapiMoney(amountMinor: minor, currency: "usd") }

func insightOrder(id: String = "ord_1", number: String = "2AP0001", status: DapiOrderStatus = .paid,
                  reference: String? = nil, country: String? = "GB", charges: DapiOrderCharges? = nil,
                  carrier: String? = nil, tracking: String? = nil, items: [DapiOrderItem]? = nil,
                  refunds: [DapiRefund] = [], created: Date? = nil, updated: Date? = nil,
                  customerName: String? = nil, customerEmail: String? = nil, address: String? = nil) -> DapiOrder {
    DapiOrder(id: id, number: number, status: status, mode: "wallet", reference: reference, customerName: customerName,
              customerEmail: customerEmail, formattedAddress: address, city: nil, countryName: nil, countryCode: country,
              charges: charges, shipping: DapiOrderShipping(tier: nil, carrier: carrier, trackingNumber: tracking, shippedAt: nil),
              itemCount: items?.count ?? 0, items: items, refunds: refunds, createdAt: created, updatedAt: updated)
}

func insightCharges(items: Int = 1000, shipping: Int = 500, vat: Int = 0, credit: Int? = nil, total: Int? = nil,
                    paidBy: String = "you", currency: String = "usd") -> DapiOrderCharges {
    func money(_ minor: Int) -> DapiMoney { DapiMoney(amountMinor: minor, currency: currency) }
    return DapiOrderCharges(paidBy: paidBy, items: money(items), shipping: money(shipping), vat: money(vat), vatRate: 0,
                            vatIncluded: false, vatCountry: nil, sampleCredit: credit.map(money),
                            total: money(total ?? (items + shipping + vat)))
}

func insightItem(_ quantity: Int, name: String = "Plinth 0123456789abcdef", material: String? = "PLA Red") -> DapiOrderItem {
    DapiOrderItem(id: "itm_\(quantity)", quoteID: "qte_1", quoteName: name,
                  materials: material.map { [DapiMaterialSlot(slot: 1, materialID: "mat_1", materialName: $0)] } ?? [],
                  quantity: quantity, unitPrice: nil, productionUnitPrice: nil, total: nil)
}

/// A scripted ordering client for list and by-ID reads; every write fails the test.
final class InsightsScriptedDapiOrders: DapiOrdering, @unchecked Sendable {
    private let lock = NSLock()
    private var _pages: [Result<DapiOrderPage, DapiError>] = []
    private var _queries: [DapiOrderListQuery] = []
    private var _byID: [String: Result<DapiOrder, DapiError>] = [:]
    private var _idReads: [String] = []
    var queries: [DapiOrderListQuery] { lock.withLock { _queries } }
    var idReads: [String] { lock.withLock { _idReads } }
    /// List results in order; the last repeats.
    func scriptPages(_ pages: [Result<DapiOrderPage, DapiError>]) { lock.withLock { _pages = pages } }
    func scriptOrder(_ id: String, _ result: Result<DapiOrder, DapiError>) { lock.withLock { _byID[id] = result } }

    func orders(_ query: DapiOrderListQuery) async throws -> DapiOrderPage {
        let result: Result<DapiOrderPage, DapiError> = lock.withLock {
            _queries.append(query)
            guard !_pages.isEmpty else { return .success(DapiOrderPage(orders: [], hasMore: false, nextCursor: nil)) }
            return _pages.count > 1 ? _pages.removeFirst() : _pages[0]
        }
        return try result.get()
    }
    func order(id: String) async throws -> DapiOrder {
        let result: Result<DapiOrder, DapiError>? = lock.withLock {
            _idReads.append(id)
            return _byID[id]
        }
        guard let result else { throw DapiError.refused(status: 404, code: "order_not_found", message: nil) }
        return try result.get()
    }
    func materials() async throws -> [DapiMaterial] { XCTFail("materials"); return [] }
    func wallet() async throws -> DapiWallet { XCTFail("wallet"); throw DapiError.notSent("unused") }
    func shippingEstimate(lines: [DapiOrderLineRequest], countryCode: String) async throws -> DapiShippingEstimate {
        XCTFail("shipping estimate"); throw DapiError.notSent("unused")
    }
    func placeOrder(_ request: DapiOrderRequest, idempotencyKey: String) async throws -> DapiOrder {
        XCTFail("place order must never be sent"); throw DapiError.notSent("unused")
    }
    func cancelOrder(id: String, idempotencyKey: String) async throws -> DapiOrder {
        XCTFail("cancel must never be sent"); throw DapiError.notSent("unused")
    }
}

final class DapiOrderInsightsTests: XCTestCase {
    /// Gregorian in London, so DST changes are inside the tests.
    var london: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/London")!
        calendar.locale = Locale(identifier: "en_GB")
        return calendar
    }

    func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    // MARK: Attention

    func testBusinessDaysSkipWeekends() {
        // Monday 2 Nov 2026 10:00 UTC.
        let monday = date("2026-11-02T10:00:00Z")
        XCTAssertEqual(dapiBusinessDays(from: monday, to: date("2026-11-02T18:00:00Z"), calendar: london), 0)
        XCTAssertEqual(dapiBusinessDays(from: monday, to: date("2026-11-05T09:00:00Z"), calendar: london), 3)
        // Friday to the next Monday is one business day.
        XCTAssertEqual(dapiBusinessDays(from: date("2026-11-06T10:00:00Z"), to: date("2026-11-09T10:00:00Z"), calendar: london), 1)
        XCTAssertEqual(dapiBusinessDays(from: monday, to: date("2026-11-16T10:00:00Z"), calendar: london), 10)
        XCTAssertEqual(dapiBusinessDays(from: monday, to: date("2026-10-01T10:00:00Z"), calendar: london), 0)
        // Bounded for very old orders.
        XCTAssertEqual(dapiBusinessDays(from: date("2000-01-03T10:00:00Z"), to: monday, calendar: london),
                       dapiAttentionBusinessDayCountLimit)
    }

    func testAttentionStatusesAndThresholds() {
        let monday = date("2026-11-02T10:00:00Z")
        func reason(_ status: DapiOrderStatus, now: String, created: Date? = monday) -> DapiOrderAttention? {
            dapiOrderAttentionReason(insightOrder(status: status, created: created), now: date(now), calendar: london)
        }
        XCTAssertEqual(reason(.onHold, now: "2026-11-02T11:00:00Z"), .onHold)
        XCTAssertEqual(reason(.rejected, now: "2026-11-02T11:00:00Z"), .rejected)
        XCTAssertEqual(reason(.returned, now: "2026-11-02T11:00:00Z"), .returned)
        XCTAssertEqual(reason(.unknown("weird"), now: "2026-11-02T11:00:00Z"), .unrecognisedStatus("weird"))
        // Never for cancelled, completed, shipped or awaiting payment, however old.
        for status in [DapiOrderStatus.cancelled, .completed, .shipped, .awaitingPayment] {
            XCTAssertNil(reason(status, now: "2027-01-01T00:00:00Z"), status.raw)
        }
        // Paid: fine for 3 business days, flagged on the 4th (Friday).
        XCTAssertNil(reason(.paid, now: "2026-11-05T12:00:00Z"))
        XCTAssertEqual(reason(.assigned, now: "2026-11-06T12:00:00Z"), .notStarted(businessDays: 4))
        // In production isn't "not started"; it's late after 7 business days.
        XCTAssertNil(reason(.inProduction, now: "2026-11-11T12:00:00Z"))
        XCTAssertEqual(reason(.inProduction, now: "2026-11-12T12:00:00Z"), .notShipped(businessDays: 8))
        XCTAssertEqual(reason(.paid, now: "2026-11-12T12:00:00Z"), .notShipped(businessDays: 8))
        // No date, or a date in the future: no time rule.
        XCTAssertNil(reason(.paid, now: "2027-01-01T00:00:00Z", created: nil))
        XCTAssertNil(reason(.paid, now: "2026-11-01T00:00:00Z"))
        XCTAssertEqual(dapiOrderAttention(insightOrder(status: .onHold)), DapiOrderAttention.onHold.detail)
        XCTAssertNil(dapiOrderAttention(insightOrder(status: .completed)))
    }

    func testUnrecognisedStatusWordIsCleanedForDisplay() {
        XCTAssertEqual(dapiOrderStatusWordForDisplay("  odd<script>  "), "oddscript")
        XCTAssertEqual(dapiOrderStatusWordForDisplay("   "), "blank")
        XCTAssertEqual(dapiOrderStatusWordForDisplay(String(repeating: "a", count: 100)).count, 40)
    }

    // MARK: Cost and profit

    func testCostIsTotalLessCreditAndRefunds() {
        let order = insightOrder(status: .shipped, charges: insightCharges(items: 2000, shipping: 700, vat: 100, credit: 500),
                                 refunds: [DapiRefund(id: "ref_1", amount: insightUSD(300), createdAt: nil)])
        XCTAssertEqual(dapiOrderCost(order), .amount(Decimal(string: "20")!))
        XCTAssertEqual(dapiOrderCost(insightOrder(status: .paid, charges: insightCharges())), .amount(15))
    }

    func testCostUnavailableWithReasons() {
        func reason(_ order: DapiOrder) -> String? {
            if case .unavailable(let text) = dapiOrderCost(order) { return text }
            return nil
        }
        XCTAssertNotNil(reason(insightOrder(status: .cancelled, charges: insightCharges())))
        XCTAssertNotNil(reason(insightOrder(status: .awaitingPayment, charges: insightCharges())))
        XCTAssertNotNil(reason(insightOrder(status: .unknown("x"), charges: insightCharges())))
        XCTAssertTrue(reason(insightOrder(status: .paid, charges: nil))!.contains("charges"))
        XCTAssertTrue(reason(insightOrder(status: .paid, charges: insightCharges(paidBy: "buyer")))!.contains("wasn’t paid from your 3DAPI balance"))
        XCTAssertTrue(reason(insightOrder(status: .paid, charges: insightCharges(currency: "eur")))!.contains("EUR"))
        // A refund in another currency is never added.
        XCTAssertTrue(reason(insightOrder(status: .paid, charges: insightCharges(),
                                          refunds: [DapiRefund(id: "ref_1", amount: DapiMoney(amountMinor: 1, currency: "gbp"), createdAt: nil)]))!.contains("GBP"))
        // Refunds larger than the total.
        XCTAssertTrue(reason(insightOrder(status: .returned, charges: insightCharges(),
                                          refunds: [DapiRefund(id: "ref_1", amount: insightUSD(2000), createdAt: nil)]))!.contains("more than 3DAPI charged"))
        // Negative amounts are unreadable.
        XCTAssertNotNil(reason(insightOrder(status: .paid, charges: insightCharges(credit: -5))))
    }

    func testProfitCheckRenamesTheCostLineOnly() {
        let result = dapiProfitCheck(itemTotal: 30, shippingCharged: 5, preset: .none, rates: ProfitFeeRates(), offsiteAds: false,
                                     unitsSold: 1, orderCost: Decimal(string: "15.004")!)
        XCTAssertEqual(result.lines.last?.label, dapiProfitCostLineLabel)
        XCTAssertEqual(result.lines.last?.amount, -15)
        XCTAssertEqual(result.profit, 20)
        XCTAssertFalse(result.lines.contains { $0.label.contains("Slant") })
        let slant = profitCheck(itemTotal: 30, shippingCharged: 5, preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates,
                                offsiteAds: false, unitsSold: 2, slantTotal: 15)
        let dapi = dapiProfitCheck(itemTotal: 30, shippingCharged: 5, preset: .etsyUS, rates: ProfitFeePreset.etsyUS.defaultRates,
                                   offsiteAds: false, unitsSold: 2, orderCost: 15)
        XCTAssertEqual(slant.profit, dapi.profit)
        XCTAssertEqual(slant.marginPercent, dapi.marginPercent)
        XCTAssertEqual(slant.lines.dropLast().map(\.label), dapi.lines.dropLast().map(\.label))
        XCTAssertNotNil(dapiProfitCostNote(insightOrder(status: .rejected)))
        XCTAssertNil(dapiProfitCostNote(insightOrder(status: .shipped)))
    }

    // MARK: Report a problem

    func testProblemKindsFollowTheStatus() {
        XCTAssertEqual(dapiProblemKinds(status: .shipped), [.lostParcel, .damaged, .printDefect, .wrongItem, .missingItem, .late, .other])
        XCTAssertEqual(dapiProblemKinds(status: .completed).last, .other)
        XCTAssertFalse(dapiProblemKinds(status: .completed).contains(.late))
        XCTAssertEqual(dapiProblemKinds(status: .paid), [.late, .other])
        XCTAssertTrue(dapiProblemKinds(status: .inProduction).contains(.cancel))
        XCTAssertEqual(dapiProblemKinds(status: .cancelled), [.refund, .other])
        XCTAssertEqual(dapiProblemKinds(status: .unknown("x")), [.other])
        XCTAssertFalse(dapiOffersProblemReport(status: .awaitingPayment))
        XCTAssertTrue(dapiOffersProblemReport(status: .paid))
        XCTAssertNotNil(dapiProblemGuidance(.lostParcel))
        XCTAssertTrue(dapiProblemGuidance(.printDefect)!.contains("photos"))
        XCTAssertTrue(dapiProblemReportCaption.contains("contact@dapi.digital"))
    }

    func testProblemMessageCarriesNoCustomerDetails() {
        let order = insightOrder(status: .shipped, reference: "ETSY-123", carrier: "DHL", tracking: "JD0001",
                                 items: [insightItem(2)], created: date("2026-10-20T10:00:00Z"),
                                 customerName: "Ada Lovelace", customerEmail: "ada@example.com", address: "1 Secret Street, London")
        let message = dapiProblemMessage(order: order, problem: .printDefect, details: "Layer lines split.",
                                         timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(message.contains("Order number: 2AP0001"))
        XCTAssertTrue(message.contains("Status: Shipped"))
        XCTAssertTrue(message.contains("Created: 20 October 2026"))
        XCTAssertTrue(message.contains("Carrier: DHL"))
        XCTAssertTrue(message.contains("Tracking number: JD0001"))
        XCTAssertTrue(message.contains("- 2 × Plinth 0123456789abcdef (PLA Red)"))
        XCTAssertTrue(message.contains("Layer lines split."))
        XCTAssertTrue(message.contains("photos"))
        for secret in ["Ada", "ada@example.com", "Secret Street", "ETSY-123"] {
            XCTAssertFalse(message.contains(secret), secret)
        }
    }

    // MARK: CSV

    func testOrdersCSVColumnsAndCustomerToggle() {
        let order = insightOrder(status: .shipped, reference: "=HYPERLINK(\"x\")", country: "de",
                                 charges: insightCharges(items: 1234, shipping: 567, vat: 89, credit: 100),
                                 carrier: "DHL", tracking: "123", items: [insightItem(2), insightItem(3)],
                                 refunds: [DapiRefund(id: "ref_1", amount: insightUSD(50), createdAt: nil)],
                                 created: date("2026-10-01T12:00:00Z"), updated: date("2026-10-03T12:00:00Z"),
                                 customerName: "Ada", customerEmail: "ada@example.com", address: "1 Road, Berlin")
        let row = dapiOrdersCSVRow(order, includeCustomer: false)
        XCTAssertEqual(row.count, dapiOrdersCSVBaseColumns.count)
        XCTAssertEqual(row, ["2AP0001", "shipped", "2026-10-01T12:00:00Z", "2026-10-03T12:00:00Z", "=HYPERLINK(\"x\")", "DE", "5",
                             "12.34", "5.67", "0.89", "1.00", "0.50", "18.90", "USD", "DHL", "123"])
        let csv = dapiOrdersCSV([order], includeCustomer: false)
        XCTAssertFalse(csv.contains("Ada"))
        XCTAssertFalse(csv.contains("Berlin"))
        // Formula guard from csvField.
        XCTAssertTrue(csv.contains("\"'=HYPERLINK(\"\"x\"\")\""))
        XCTAssertTrue(csv.hasPrefix(dapiOrdersCSVBaseColumns.joined(separator: ",") + "\r\n"))
        let withCustomer = dapiOrdersCSV([order], includeCustomer: true)
        XCTAssertTrue(withCustomer.contains("Customer name"))
        XCTAssertTrue(withCustomer.contains("ada@example.com"))
        XCTAssertTrue(withCustomer.contains("\"1 Road, Berlin\""))
    }

    func testOrdersCSVLeavesUnknownsBlank() {
        let bare = dapiOrdersCSVRow(insightOrder(country: nil), includeCustomer: false)
        XCTAssertEqual(bare[6], "") // units unknown without lines
        XCTAssertEqual(Array(bare[7...13]), ["", "", "", "", "", "", ""])
        // A refund in another currency isn't mixed into the total's currency.
        let mixed = insightOrder(charges: insightCharges(), refunds: [DapiRefund(id: "r", amount: DapiMoney(amountMinor: 5, currency: "eur"), createdAt: nil)])
        XCTAssertEqual(dapiOrdersCSVRow(mixed, includeCustomer: false)[11], "")
        XCTAssertEqual(dapiCSVAmount(DapiMoney(amountMinor: 1234, currency: "jpy")), "1234")
        XCTAssertEqual(dapiCSVAmount(DapiMoney(amountMinor: 1234, currency: "eur")), "12.34")
        XCTAssertEqual(dapiCSVAmount(DapiMoney(amountMinor: 1234, currency: "??")), "")
    }

    // MARK: Spending report

    func testMonthBucketingFollowsTheCalendarTimeZone() {
        // 23:30 UTC on 31 Oct is still October in London (GMT after the 25 Oct change) but November in Sydney.
        let instant = date("2026-10-31T23:30:00Z")
        XCTAssertEqual(dapiSpendMonthKey(instant, calendar: london).month, 10)
        var sydney = Calendar(identifier: .gregorian)
        sydney.timeZone = TimeZone(identifier: "Australia/Sydney")!
        XCTAssertEqual(dapiSpendMonthKey(instant, calendar: sydney).month, 11)
        // 23:30 UTC on 31 Mar 2026 is 00:30 BST on 1 April (after the DST change).
        XCTAssertEqual(dapiSpendMonthKey(date("2026-03-31T23:30:00Z"), calendar: london).month, 4)
    }

    func testSpendReportCountsOnlyPlacedOrdersPaidByYou() {
        let october = date("2026-10-10T12:00:00Z")
        let november = date("2026-11-03T12:00:00Z")
        let orders = [
            insightOrder(id: "ord_a", status: .shipped, country: "GB", charges: insightCharges(items: 1000, shipping: 500, credit: 200),
                         items: [insightItem(2)], created: october),
            insightOrder(id: "ord_b", status: .completed, country: "gb", charges: insightCharges(items: 2000, shipping: 900, vat: 100),
                         items: [insightItem(1)], refunds: [DapiRefund(id: "r", amount: insightUSD(500), createdAt: nil)], created: october),
            insightOrder(id: "ord_c", status: .paid, country: "DE", charges: insightCharges(items: 500, shipping: 300), created: november),
            insightOrder(id: "ord_a", status: .shipped, charges: insightCharges(), created: october), // duplicate ID
            insightOrder(id: "ord_d", status: .cancelled, charges: insightCharges(), created: october),
            insightOrder(id: "ord_e", status: .unknown("new"), charges: insightCharges(), created: october),
            insightOrder(id: "ord_f", status: .shipped, charges: insightCharges(paidBy: "buyer"), created: october),
            insightOrder(id: "ord_g", status: .shipped, charges: nil, created: october),
            insightOrder(id: "ord_h", status: .shipped, charges: insightCharges(currency: "eur"), created: october),
            insightOrder(id: "ord_i", status: .shipped, charges: insightCharges(), created: nil),
            insightOrder(id: "ord_j", status: .shipped, country: nil, charges: insightCharges(items: 100, shipping: 100), created: november),
            insightOrder(id: "ord_k", status: .shipped, charges: insightCharges(),
                         refunds: [DapiRefund(id: "r", amount: insightUSD(99_999), createdAt: nil)], created: october)
        ]
        let report = dapiSpendReport(orders, calendar: london)
        XCTAssertEqual(report.months.map(\.id), ["2026-11", "2026-10"])
        let oct = report.months[1]
        XCTAssertEqual(oct.orders, 2)
        XCTAssertEqual(oct.units, 3)
        XCTAssertEqual(oct.items, 30)
        XCTAssertEqual(oct.shipping, 14)
        XCTAssertEqual(oct.vat, 1)
        XCTAssertEqual(oct.sampleCredit, 2)
        XCTAssertEqual(oct.refunds, 5)
        XCTAssertEqual(oct.totalPaid, 38) // 15 − 2 + 30 − 5
        let nov = report.months[0]
        XCTAssertEqual(nov.orders, 2)
        XCTAssertEqual(nov.ordersWithoutUnits, 2)
        XCTAssertEqual(report.countedOrders, 4)
        XCTAssertEqual(report.totalPaid, 38 + 8 + 2)
        XCTAssertEqual(report.notPlaced, 2)
        XCTAssertEqual(report.notPaidByYou, 1)
        XCTAssertEqual(report.withoutCharges, 1)
        XCTAssertEqual(report.unreadableAmounts, 1)
        XCTAssertEqual(report.withoutDate, 1)
        XCTAssertEqual(report.withoutCountry, 1)
        XCTAssertEqual(report.otherCurrencies, [DapiSpendOtherCurrency(currency: "EUR", orders: 1, totalPaidMinor: 1500)])
        let gb = report.countries.first { $0.countryCode == "GB" }!
        XCTAssertEqual(gb.orders, 2)
        XCTAssertEqual(gb.lowest, 5)
        XCTAssertEqual(gb.highest, 9)
        XCTAssertEqual(gb.average, 7)
        XCTAssertEqual(report.countries.map(\.countryCode), ["GB", "DE"])
        XCTAssertNotNil(dapiSpendExclusionLine(report))
        let text = dapiSpendReportText(report, notes: ["Note"], calendar: london)
        XCTAssertTrue(text.contains("EUR"))
        XCTAssertTrue(text.contains("not added to the USD figures"))
        let csv = dapiSpendReportCSV(report)
        XCTAssertTrue(csv.contains("2026-10,2,3,0,30.00,14.00,1.00,2.00,5.00,38.00"))
        XCTAssertTrue(csv.contains("EUR,1,15.00"))
    }

    func testCountryAverageRoundsToCents() {
        var entry = DapiSpendCountry(countryCode: "US", orders: 3, totalShipping: 10, lowest: 3, highest: 4)
        XCTAssertEqual(entry.average, Decimal(string: "3.33"))
        entry.orders = 0
        XCTAssertNil(entry.average)
        XCTAssertNil(dapiSpendCountryCode(insightOrder(country: "United Kingdom")))
        XCTAssertEqual(dapiSpendCountryCode(insightOrder(country: " us ")), "US")
    }

    // MARK: Period loading

    func testPeriodQueryHasADayMarginAndLines() {
        let interval = SpendReportInterval(start: date("2026-10-01T00:00:00Z"), end: date("2026-11-01T00:00:00Z"))
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let query = dapiSpendPeriodQuery(interval, cursor: "c2", calendar: utc)
        XCTAssertEqual(query.createdAfter, date("2026-09-30T00:00:00Z"))
        XCTAssertEqual(query.createdBefore, date("2026-11-02T00:00:00Z"))
        XCTAssertEqual(query.cursor, "c2")
        XCTAssertEqual(query.limit, 100)
        XCTAssertTrue(query.expandItems)
        let inside = insightOrder(id: "ord_in", created: date("2026-10-31T23:59:59Z"))
        let outside = insightOrder(id: "ord_out", created: date("2026-11-01T00:00:00Z"))
        let undated = insightOrder(id: "ord_nd", created: nil)
        XCTAssertEqual(dapiSpendPeriodOrders([inside], adding: [inside, outside, undated], interval: interval).map(\.id), ["ord_in", "ord_nd"])
    }

    func testPageSteps() {
        let order = insightOrder()
        XCTAssertEqual(dapiSpendPageStep(pagesLoaded: 1, page: DapiOrderPage(orders: [order], hasMore: false, nextCursor: "x")), .complete)
        XCTAssertEqual(dapiSpendPageStep(pagesLoaded: 1, page: DapiOrderPage(orders: [], hasMore: true, nextCursor: "x")), .complete)
        XCTAssertEqual(dapiSpendPageStep(pagesLoaded: 1, page: DapiOrderPage(orders: [order], hasMore: true, nextCursor: nil)), .noCursor)
        XCTAssertEqual(dapiSpendPageStep(pagesLoaded: 1, page: DapiOrderPage(orders: [order], hasMore: true, nextCursor: "c")), .next("c"))
        XCTAssertEqual(dapiSpendPageStep(pagesLoaded: 50, page: DapiOrderPage(orders: [order], hasMore: true, nextCursor: "c")), .capReached)
    }

    @MainActor
    func testLoaderReadsPagesThenKeepsPartialResultsOnFailure() async {
        let client = InsightsScriptedDapiOrders()
        let now = date("2026-10-31T12:00:00Z")
        client.scriptPages([
            .success(DapiOrderPage(orders: [insightOrder(id: "ord_1", created: date("2026-10-30T12:00:00Z"))], hasMore: true, nextCursor: "c2")),
            .failure(.rateLimited(code: "rate_limited", retryAt: now.addingTimeInterval(120))),
            .success(DapiOrderPage(orders: [insightOrder(id: "ord_2", created: date("2026-10-29T12:00:00Z"))], hasMore: false, nextCursor: nil))
        ])
        var requests = 0
        let loader = DapiSpendPeriodLoader(makeClient: { client }, sleep: { _ in }, beginRequest: { requests += 1 },
                                           endRequest: { requests -= 1 }, calendar: london, now: { now })
        loader.start(.thisMonth)
        XCTAssertEqual(requests, 1)
        await loader.waitForCompletion()
        XCTAssertFalse(loader.running)
        XCTAssertEqual(requests, 0)
        XCTAssertEqual(loader.load?.orders.map(\.id), ["ord_1"])
        XCTAssertTrue(loader.message!.contains("limiting requests"))
        XCTAssertTrue(loader.message!.contains("2 minutes"))
        XCTAssertTrue(loader.canContinue)
        XCTAssertEqual(client.queries.count, 2)
        XCTAssertEqual(client.queries[1].cursor, "c2")
        // Never retried by itself: Continue Loading reads the same cursor once more.
        loader.continueLoading()
        await loader.waitForCompletion()
        XCTAssertEqual(client.queries.count, 3)
        XCTAssertEqual(client.queries[2].cursor, "c2")
        XCTAssertEqual(loader.load?.orders.map(\.id), ["ord_1", "ord_2"])
        XCTAssertEqual(loader.load?.complete, true)
        XCTAssertFalse(loader.canContinue)
        XCTAssertNil(loader.message)
    }

    @MainActor
    func testLoaderStopsAtThePageCap() async {
        let client = InsightsScriptedDapiOrders()
        let now = date("2026-10-31T12:00:00Z")
        var counter = 0
        client.scriptPages([.success(DapiOrderPage(orders: [insightOrder(id: "ord_x", created: now)], hasMore: true, nextCursor: "next"))])
        let loader = DapiSpendPeriodLoader(makeClient: { client }, sleep: { _ in }, beginRequest: { counter += 1 },
                                           endRequest: { counter -= 1 }, calendar: london, now: { now })
        loader.start(.thisMonth)
        await loader.waitForCompletion()
        XCTAssertEqual(client.queries.count, dapiSpendPeriodMaxPages)
        XCTAssertEqual(loader.load?.capReached, true)
        XCTAssertFalse(loader.canContinue)
        XCTAssertEqual(counter, 0)
    }

    @MainActor
    func testLoaderWithoutAClientSaysWhy() {
        let loader = DapiSpendPeriodLoader(makeClient: { throw DapiError.missingKey }, sleep: { _ in }, beginRequest: { XCTFail("no request") },
                                           endRequest: {}, calendar: london)
        loader.start(.thisMonth)
        XCTAssertFalse(loader.running)
        XCTAssertEqual(loader.message, DapiError.missingKey.userMessage)
    }

    @MainActor
    func testStopEndsTheRequestOnceAndDropsLateResults() async {
        let client = InsightsScriptedDapiOrders()
        client.scriptPages([.success(DapiOrderPage(orders: [insightOrder(id: "ord_1", created: Date())], hasMore: true, nextCursor: "c"))])
        var counter = 0
        let loader = DapiSpendPeriodLoader(makeClient: { client }, sleep: { _ in try await Task.sleep(nanoseconds: 50_000_000) },
                                           beginRequest: { counter += 1 }, endRequest: { counter -= 1 }, calendar: london)
        loader.start(.thisMonth)
        try? await Task.sleep(nanoseconds: 10_000_000)
        loader.stop()
        XCTAssertEqual(counter, 0)
        XCTAssertFalse(loader.running)
        await loader.waitForCompletion()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(counter, 0)
        XCTAssertEqual(loader.message, "Stopped. Orders already loaded are kept.")
        XCTAssertTrue(loader.canContinue)
    }

    // MARK: Tracking

    func testTrackingGroupsAndCopyText() {
        let orders = [
            insightOrder(id: "ord_1", number: "2AP1", reference: "ETSY-1", carrier: "DHL", tracking: " JD1 ", created: date("2026-10-01T00:00:00Z")),
            insightOrder(id: "ord_2", number: "2AP2", reference: nil, carrier: nil, tracking: "T2", created: date("2026-10-05T00:00:00Z")),
            insightOrder(id: "ord_3", number: "2AP3", reference: "ETSY-3", tracking: nil),
            insightOrder(id: "ord_4", number: "2AP4", reference: "  ", tracking: "T4", created: nil),
            insightOrder(id: "ord_5", number: "2AP5", reference: "ETSY-5", carrier: "UPS", tracking: "U5", created: date("2026-10-09T00:00:00Z"))
        ]
        let groups = dapiTrackingGroups(orders, done: ["ord_5"])
        XCTAssertEqual(groups.withReference.map(\.id), ["ord_1"])
        XCTAssertEqual(groups.withoutReference.map(\.id), ["ord_2", "ord_4"])
        XCTAssertEqual(groups.doneCount, 1)
        XCTAssertEqual(dapiTrackingGroups(orders, done: ["ord_5"], showDone: true).withReference.map(\.id), ["ord_5", "ord_1"])
        XCTAssertEqual(dapiTrackingCopyText(groups.withReference[0]), "ETSY-1 — DHL JD1")
        XCTAssertEqual(dapiTrackingCopyText(groups.withoutReference[0]), "2AP2 — T2")
        XCTAssertEqual(dapiTrackingCopyAllText(groups.listed), "ETSY-1 — DHL JD1\n2AP2 — T2\n2AP4 — T4")
        XCTAssertEqual(dapiTrackingTitle(groups.withoutReference[0]), "3DAPI order 2AP2")
    }
}
