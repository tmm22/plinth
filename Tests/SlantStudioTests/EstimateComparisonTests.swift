import XCTest
@testable import SlantStudio

final class EstimateComparisonTests: XCTestCase {
    private func price(_ total: String, _ quantity: Int) -> ComparisonPrice {
        let decimal = Decimal(string: total)!
        return ComparisonPrice(total: decimal, quantity: quantity, perUnit: comparisonPerUnit(total: decimal, quantity: quantity)!)
    }
    private let pla = ComparisonMaterial(id: "pla", name: "PLA Black")
    private let petg = ComparisonMaterial(id: "petg", name: "PETG White")

    // MARK: Quantities

    func testDefaultQuantitiesParseSorted() {
        XCTAssertEqual(parseComparisonQuantities(comparisonDefaultQuantityText), ComparisonQuantityInput(values: [1, 5, 10, 25, 50], problem: nil))
    }

    func testQuantitiesAreDeduplicatedAndSortedAcrossSeparators() {
        XCTAssertEqual(parseComparisonQuantities("50 10;10, 1\n5,5").values, [1, 5, 10, 50])
        XCTAssertNil(parseComparisonQuantities("  3  ").problem)
        XCTAssertEqual(parseComparisonQuantities("1,5,10,25,50").values, [1, 5, 10, 25, 50])
    }

    func testInvalidQuantitiesAreRefusedNotGuessed() {
        for input in ["0", "abc", "1e3", "-2", "1.5", "10001", "5, x", "２"] {
            let result = parseComparisonQuantities(input)
            XCTAssertEqual(result.values, [], input)
            XCTAssertNotNil(result.problem, input)
        }
        XCTAssertEqual(parseComparisonQuantities("").problem, "Enter at least one quantity.")
        XCTAssertEqual(parseComparisonQuantities(" , ").problem, "Enter at least one quantity.")
    }

    func testThousandsSeparatorIsAmbiguousAndRefused() {
        XCTAssertNotNil(parseComparisonQuantities("1,500").problem)
        XCTAssertNotNil(parseComparisonQuantities("1, 1,000").problem)
        XCTAssertEqual(parseComparisonQuantities("1, 500").values, [1, 500])
    }

    func testAtMostFiveDistinctQuantities() {
        XCTAssertEqual(parseComparisonQuantities("1 2 3 4 5 5 5").values, [1, 2, 3, 4, 5])
        let tooMany = parseComparisonQuantities("1 2 3 4 5 6")
        XCTAssertEqual(tooMany.values, [])
        XCTAssertEqual(tooMany.problem, "Enter up to 5 different quantities.")
    }

    // MARK: Plan

    func testPlanIsMaterialMajorAndCapped() {
        let materials = (1...6).map { ComparisonMaterial(id: "m\($0)", name: "M\($0)") }
        let plan = comparisonPlan(fileID: "f", materials: materials, quantities: [50, 1, 5, 10, 25, 100])
        XCTAssertEqual(plan.materials.map(\.id), ["m1", "m2", "m3", "m4"])
        XCTAssertEqual(plan.quantities, [1, 5, 10, 25, 50])
        XCTAssertEqual(plan.cells.count, 20)
        XCTAssertLessThanOrEqual(plan.cells.count, comparisonMaxCalls)
        XCTAssertEqual(plan.cells.prefix(5).map(\.filamentID), Array(repeating: "m1", count: 5))
        XCTAssertEqual(plan.cells.prefix(5).map(\.quantity), [1, 5, 10, 25, 50])
    }

    func testPlanDropsDuplicatesEmptiesAndOutOfRangeQuantities() {
        let plan = comparisonPlan(fileID: "f", materials: [pla, pla, ComparisonMaterial(id: "", name: "?")], quantities: [0, 3, 3, 20000])
        XCTAssertEqual(plan.materials, [pla])
        XCTAssertEqual(plan.quantities, [3])
        XCTAssertEqual(plan.cells, [ComparisonCellKey(filamentID: "pla", quantity: 3)])
    }

    func testPlanRespectsSmallerCallCapByDroppingWholeMaterials() {
        let materials = (1...4).map { ComparisonMaterial(id: "m\($0)", name: "M\($0)") }
        let plan = comparisonPlan(fileID: "f", materials: materials, quantities: [1, 2, 3, 4, 5], maxCalls: 12)
        XCTAssertEqual(plan.materials.count, 2)
        XCTAssertEqual(plan.cells.count, 10)
    }

    func testOneMaterialOnlyPlan() {
        let plan = comparisonPlan(fileID: "f", materials: [pla], quantities: [1, 10])
        XCTAssertEqual(plan.cells.count, 2)
    }

    func testMaterialChoicesExcludeOutOfStockAndDefaultToCurrentSelection() {
        let filaments = [
            Record(values: ["publicId": "a", "name": "PLA Black", "profile": "PLA", "available": true]),
            Record(values: ["publicId": "b", "name": "PLA Red", "profile": "PLA", "available": false]),
            Record(values: ["publicId": "c", "name": "PETG White", "profile": "PETG"])
        ]
        let choices = comparisonMaterialChoices(filaments)
        XCTAssertEqual(choices.map(\.id), ["c", "a"])
        XCTAssertEqual(comparisonDefaultMaterialIDs(selectedFilamentID: "a", choices: choices), ["a"])
        XCTAssertEqual(comparisonDefaultMaterialIDs(selectedFilamentID: "b", choices: choices), [], "out-of-stock selection isn't preselected")
        XCTAssertEqual(comparisonDefaultMaterialIDs(selectedFilamentID: "", choices: choices), [])
    }

    // MARK: Prices

    func testPerUnitIsTotalDividedByQuantityRoundedToCents() {
        XCTAssertEqual(comparisonPerUnit(total: Decimal(string: "10.00")!, quantity: 3), Decimal(string: "3.33"))
        XCTAssertEqual(comparisonPerUnit(total: Decimal(string: "12.18")!, quantity: 3), Decimal(string: "4.06"))
        XCTAssertNil(comparisonPerUnit(total: 5, quantity: 0))
    }

    func testPriceParsesNumbersAndStringsAndChecksQuantity() {
        XCTAssertEqual(comparisonPrice(from: ["total": 12.18, "quantity": 3], requestedQuantity: 3), .priced(price("12.18", 3)))
        XCTAssertEqual(comparisonPrice(from: ["total": "20.00"], requestedQuantity: 5), .priced(price("20.00", 5)))
        if case .priced = comparisonPrice(from: ["total": 9, "quantity": 4], requestedQuantity: 5) { XCTFail("mismatched quantity must not be shown as priced") }
        if case .priced = comparisonPrice(from: ["pricePerUnit": 2], requestedQuantity: 5) { XCTFail("missing total") }
        if case .priced = comparisonPrice(from: ["total": "abc"], requestedQuantity: 1) { XCTFail("non-numeric total") }
        if case .priced = comparisonPrice(from: ["total": true], requestedQuantity: 1) { XCTFail("boolean total") }
    }

    func testFlatPricingDetection() {
        XCTAssertTrue(isFlatPerUnitPricing([price("4.00", 1), price("20.00", 5), price("40.00", 10)].map(\.perUnit)))
        XCTAssertFalse(isFlatPerUnitPricing([price("4.00", 1), price("18.00", 5)].map(\.perUnit)))
        XCTAssertFalse(isFlatPerUnitPricing([price("4.00", 1)].map(\.perUnit)), "a single price says nothing about quantity")
        XCTAssertFalse(isFlatPerUnitPricing([]))
    }

    func testCheapestPerUnitIncludesTiesAndIsEmptyWhenFlatOrSingle() {
        XCTAssertEqual(cheapestPerUnitQuantities([price("5.00", 1), price("20.00", 5), price("40.00", 10)]), [5, 10])
        XCTAssertEqual(cheapestPerUnitQuantities([price("5.00", 1), price("22.00", 5)]), [5])
        XCTAssertEqual(cheapestPerUnitQuantities([price("4.00", 1), price("20.00", 5)]), [])
        XCTAssertEqual(cheapestPerUnitQuantities([price("4.00", 1)]), [])
    }

    // MARK: Table

    func testTableFromPartialResultsHighlightsPerMaterial() {
        let plan = comparisonPlan(fileID: "f", materials: [pla, petg], quantities: [1, 5, 10])
        let states: [ComparisonCellKey: ComparisonCellState] = [
            ComparisonCellKey(filamentID: "pla", quantity: 1): .priced(price("5.00", 1)),
            ComparisonCellKey(filamentID: "pla", quantity: 5): .priced(price("22.50", 5)),
            ComparisonCellKey(filamentID: "pla", quantity: 10): .failed("nope"),
            ComparisonCellKey(filamentID: "petg", quantity: 1): .requesting
        ]
        let table = comparisonTable(plan: plan, states: states)
        XCTAssertEqual(table.pricedCount, 2)
        XCTAssertEqual(table.totalCount, 6)
        XCTAssertEqual(table.rows.map(\.quantity), [1, 5, 10])
        XCTAssertEqual(table.rows[1].cells[0].isCheapest, true)
        XCTAssertEqual(table.rows[0].cells[0].isCheapest, false)
        XCTAssertEqual(table.rows[0].cells[1].state, .requesting)
        XCTAssertEqual(table.rows[2].cells[1].state, .notRequested, "missing states read as not requested")
        XCTAssertNil(table.flatPricingNote)
    }

    func testFlatNoteSaysSoPlainlyWithoutHighlight() {
        let plan = comparisonPlan(fileID: "f", materials: [pla], quantities: [1, 10])
        let table = comparisonTable(plan: plan, states: [
            ComparisonCellKey(filamentID: "pla", quantity: 1): .priced(price("3.10", 1)),
            ComparisonCellKey(filamentID: "pla", quantity: 10): .priced(price("31.00", 10))
        ])
        XCTAssertEqual(table.flatPricingNote, "Slant’s price per unit doesn’t change with quantity for this model.")
        XCTAssertFalse(table.rows.flatMap(\.cells).contains { $0.isCheapest })
        XCTAssertEqual(table.flatMaterialIDs, ["pla"])
    }

    func testFlatNoteNamesMaterialsWhenOnlySomeAreFlat() {
        let plan = comparisonPlan(fileID: "f", materials: [pla, petg], quantities: [1, 10])
        let table = comparisonTable(plan: plan, states: [
            ComparisonCellKey(filamentID: "pla", quantity: 1): .priced(price("3.10", 1)),
            ComparisonCellKey(filamentID: "pla", quantity: 10): .priced(price("31.00", 10)),
            ComparisonCellKey(filamentID: "petg", quantity: 1): .priced(price("4.00", 1)),
            ComparisonCellKey(filamentID: "petg", quantity: 10): .priced(price("35.00", 10))
        ])
        XCTAssertEqual(table.flatPricingNote, "In PLA Black, Slant’s price per unit doesn’t change with quantity for this model.")
        XCTAssertTrue(table.rows[1].cells[1].isCheapest)
    }

    func testAllFailedTableHasNoPricesOrNotes() {
        let plan = comparisonPlan(fileID: "f", materials: [pla], quantities: [1, 5])
        let table = comparisonTable(plan: plan, states: [
            ComparisonCellKey(filamentID: "pla", quantity: 1): .failed("x"),
            ComparisonCellKey(filamentID: "pla", quantity: 5): .failed("x")
        ])
        XCTAssertEqual(table.pricedCount, 0)
        XCTAssertNil(table.flatPricingNote)
        XCTAssertFalse(table.rows.flatMap(\.cells).contains { $0.isCheapest })
    }

    // MARK: Run rules

    func testCompareButtonBlockedReasons() {
        let stock = [Record(values: ["publicId": "a", "name": "PLA", "available": true])]
        let none = [Record(values: ["publicId": "a", "name": "PLA", "available": false])]
        XCTAssertEqual(compareEstimatesBlockedReason(hasKey: false, connected: false, fileID: "f", filaments: stock, busy: false), "Connect your account to compare estimates.")
        XCTAssertEqual(compareEstimatesBlockedReason(hasKey: true, connected: false, fileID: "f", filaments: stock, busy: false), "Connect your account to compare estimates.")
        XCTAssertEqual(compareEstimatesBlockedReason(hasKey: true, connected: true, fileID: "", filaments: stock, busy: false), "Upload this model to compare estimates.")
        XCTAssertEqual(compareEstimatesBlockedReason(hasKey: true, connected: true, fileID: "f", filaments: [], busy: false), "Load materials to compare estimates.")
        XCTAssertEqual(compareEstimatesBlockedReason(hasKey: true, connected: true, fileID: "f", filaments: none, busy: false), "No materials are in stock right now.")
        XCTAssertEqual(compareEstimatesBlockedReason(hasKey: true, connected: true, fileID: "f", filaments: stock, busy: true), "Wait for the current task to finish.")
        XCTAssertNil(compareEstimatesBlockedReason(hasKey: true, connected: true, fileID: "f", filaments: stock, busy: false))
    }

    func testRunYieldsToOtherWorkAndStopsWhenModelChanges() {
        XCTAssertNil(comparisonRunInterruption(hasKey: true, connected: true, busy: false, currentFileID: "f", planFileID: "f"))
        XCTAssertNotNil(comparisonRunInterruption(hasKey: true, connected: true, busy: true, currentFileID: "f", planFileID: "f"))
        XCTAssertNotNil(comparisonRunInterruption(hasKey: true, connected: true, busy: false, currentFileID: "g", planFileID: "f"), "re-upload or new selection")
        XCTAssertNotNil(comparisonRunInterruption(hasKey: true, connected: false, busy: false, currentFileID: "f", planFileID: "f"))
    }

    func testPacingStopsWhenRemainingIsLowUntilReset() {
        let now = Date(timeIntervalSince1970: 1_000)
        let low = RateLimitInfo(limit: 100, remaining: 8, reset: now.addingTimeInterval(30), role: nil)
        guard case .stop(let message) = comparisonPacing(rateLimit: low, observedAt: nil, now: now) else { return XCTFail("should stop") }
        XCTAssertTrue(message.contains("8 are left"), message)
        XCTAssertTrue(message.contains("30 seconds"), message)
        XCTAssertEqual(comparisonPacing(rateLimit: low, observedAt: nil, now: now.addingTimeInterval(31)), .proceed, "reset passed")
        XCTAssertEqual(comparisonPacing(rateLimit: RateLimitInfo(limit: 100, remaining: 50, reset: now.addingTimeInterval(30)), observedAt: nil, now: now), .proceed)
        XCTAssertEqual(comparisonPacing(rateLimit: nil, observedAt: nil, now: now), .proceed)
        XCTAssertEqual(comparisonPacing(rateLimit: RateLimitInfo(), observedAt: now, now: now), .proceed, "no headers")
    }

    func testPacingWithoutResetTrustsOnlyFreshObservations() {
        let now = Date(timeIntervalSince1970: 1_000)
        let low = RateLimitInfo(limit: nil, remaining: 2, reset: nil, role: nil)
        if case .proceed = comparisonPacing(rateLimit: low, observedAt: now.addingTimeInterval(-5), now: now) { XCTFail("fresh low count should stop") }
        XCTAssertEqual(comparisonPacing(rateLimit: low, observedAt: now.addingTimeInterval(-61), now: now), .proceed)
        XCTAssertEqual(comparisonPacing(rateLimit: low, observedAt: nil, now: now), .proceed, "unknown age, no reset")
    }

    func testErrorDispositionStopsOnRateLimitAndAccountErrorsWithoutRetrying() {
        func http(_ status: Int) -> APIError { .http(status: status, body: "", retryAfter: status == 429 ? "20 seconds" : nil, rateLimitReset: nil) }
        guard case .stopRun(let limited) = comparisonErrorDisposition(http(429)) else { return XCTFail("429 stops") }
        XCTAssertTrue(limited.contains("rate limit"), limited)
        for status in [401, 403, 404, 408, 409, 500, 503] {
            guard case .stopRun = comparisonErrorDisposition(http(status)) else { return XCTFail("\(status) stops the run") }
        }
        for status in [400, 422] {
            guard case .failCell = comparisonErrorDisposition(http(status)) else { return XCTFail("\(status) fails only the cell") }
        }
        guard case .failCell = comparisonErrorDisposition(APIError.invalidResponse("x")) else { return XCTFail() }
        XCTAssertEqual(comparisonErrorDisposition(CancellationError()), .cancelled)
        XCTAssertEqual(comparisonErrorDisposition(URLError(.cancelled)), .cancelled)
        guard case .stopRun = comparisonErrorDisposition(URLError(.timedOut)) else { return XCTFail("network stops") }
    }

    func testRateLimitedUntilPrefersResetThenRetryAfterThenAMinute() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(comparisonRateLimitedUntil(retryAfter: "5", rateLimitReset: "1030", now: now), Date(timeIntervalSince1970: 1_030))
        XCTAssertEqual(comparisonRateLimitedUntil(retryAfter: "5", rateLimitReset: "900", now: now), now.addingTimeInterval(5), "past reset ignored")
        XCTAssertEqual(comparisonRateLimitedUntil(retryAfter: "Wed, 21 Oct 2026 07:28:00 GMT", rateLimitReset: nil, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(comparisonRateLimitedUntil(retryAfter: nil, rateLimitReset: nil, now: now), now.addingTimeInterval(60))
        XCTAssertEqual(comparisonRateLimitedUntil(retryAfter: "999999", rateLimitReset: nil, now: now), now.addingTimeInterval(3600), "capped")
    }

    func testEstimatesAreTheSafeRetryableReadAndNothingElse() {
        XCTAssertTrue(isRetryableAPICall(method: "POST", path: "/files/abc/estimate"))
        XCTAssertFalse(isRetryableAPICall(method: "POST", path: "/orders"))
    }

    func testReusedEstimateUsesTheStoreContextFormat() {
        XCTAssertEqual(comparisonEstimateContext(fileID: "f", filamentID: "m", quantity: 25), "f|m|25")
    }

    func testUseIsBlockedForStaleUploadOrUnavailableMaterial() {
        let filaments = [
            Record(values: ["publicId": "a", "name": "PLA", "available": true]),
            Record(values: ["publicId": "b", "name": "PLA Red", "available": false])
        ]
        XCTAssertNil(comparisonUseBlockedReason(planFileID: "f", currentFileID: "f", filamentID: "a", filaments: filaments, busy: false))
        XCTAssertEqual(comparisonUseBlockedReason(planFileID: "f", currentFileID: "g", filamentID: "a", filaments: filaments, busy: false),
                       "These estimates are for a different model or upload.")
        XCTAssertEqual(comparisonUseBlockedReason(planFileID: "f", currentFileID: "f", filamentID: "b", filaments: filaments, busy: false),
                       "This material is now out of stock.")
        XCTAssertEqual(comparisonUseBlockedReason(planFileID: "f", currentFileID: "f", filamentID: "z", filaments: filaments, busy: false),
                       "This material is no longer offered.")
        XCTAssertNotNil(comparisonUseBlockedReason(planFileID: "f", currentFileID: "f", filamentID: "a", filaments: filaments, busy: true))
    }

    func testCopyLabelsPrintCostOnly() {
        XCTAssertTrue(comparisonPrintOnlyNotice.contains("Print cost estimate only"))
        XCTAssertTrue(comparisonPrintOnlyNotice.contains("delivery is priced when you create an order draft"))
        XCTAssertEqual(comparisonCompletionSummary(priced: 3, total: 5, failed: 1), "3 of 5 estimates in · 1 couldn’t be priced")
    }
}

extension EstimateComparisonTests {
    func testCompareIsOfferedOnlyOnceUploadedWithMaterials() {
        let stock = [Record(values: ["id": "a", "profile": "PLA"])]
        XCTAssertTrue(compareEstimatesIsOffered(hasKey: true, connected: true, fileID: "f", filaments: stock))
        XCTAssertFalse(compareEstimatesIsOffered(hasKey: true, connected: true, fileID: "", filaments: stock))
        XCTAssertFalse(compareEstimatesIsOffered(hasKey: true, connected: true, fileID: "f", filaments: []))
        XCTAssertFalse(compareEstimatesIsOffered(hasKey: false, connected: false, fileID: "f", filaments: stock))
        XCTAssertFalse(compareEstimatesIsOffered(hasKey: true, connected: false, fileID: "f", filaments: stock))
    }

    func testMaterialPickerIsGroupedByType() {
        let filaments = [
            Record(values: ["id": "p1", "name": "PLA Black", "profile": "PLA"]),
            Record(values: ["id": "g1", "name": "PETG White", "profile": "PETG"]),
            Record(values: ["id": "p2", "name": "PLA Red", "profile": "pla"]),
            Record(values: ["id": "x", "name": "Mystery"])
        ]
        let sections = comparisonMaterialSections(comparisonMaterialChoices(filaments))
        XCTAssertEqual(sections.map(\.type), ["PETG", "PLA", otherFilamentType])
        XCTAssertEqual(sections[1].materials.map(\.id), ["p1", "p2"])
        XCTAssertTrue(comparisonMaterialSections([]).isEmpty)
    }

    func testFootnoteAndRateLimitHeaderPresence() {
        XCTAssertEqual(comparisonPerUnitFootnote, "Each = total ÷ quantity, including any surcharges. Lowest per unit is marked in each column.")
        XCTAssertFalse(rateLimitInfo(from: [:]).hasValues)
        XCTAssertFalse(rateLimitInfo(from: ["Content-Type": "application/json"]).hasValues)
        XCTAssertTrue(rateLimitInfo(from: ["x-ratelimit-remaining": "40"]).hasValues)
    }
}
