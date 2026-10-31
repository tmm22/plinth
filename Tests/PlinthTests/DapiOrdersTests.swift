import XCTest
@testable import Plinth

// The 3DAPI Orders section (DapiOrderComposer.swift, DapiOrderList.swift): the pure helpers, and the place, cancel,
// lookup and list runners against a scripted stub. Nothing here reaches the network, the Keychain, `DapiConnection`
// or `DapiOrderSession`.

/// A scripted 3DAPI that quotes and orders: each method returns its configured result and records its calls.
final class ScriptedDapiOrders: DapiQuoting, DapiOrdering, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _quoteReads: [String: [Result<DapiQuote, DapiError>]] = [:]
    private var _shipping: [Result<DapiShippingEstimate, DapiError>] = []
    private var _orderReads: [Result<DapiOrder, DapiError>] = []
    private var _pages: [Result<DapiOrderPage, DapiError>] = []
    private var _queries: [DapiOrderListQuery] = []
    private var _placed: [(DapiOrderRequest, String)] = []
    private var _cancelKeys: [String] = []
    var listResult: Result<[DapiQuote], DapiError> = .success([])
    var materialsResult: Result<[DapiMaterial], DapiError> = .success([])
    var walletResult: Result<DapiWallet, DapiError> = .failure(.refused(status: 403, code: "missing_scope", message: nil))
    var placeResult: Result<DapiOrder, DapiError> = .success(DapiOrdersTests.order("ord_new", status: .paid))
    var cancelResult: Result<DapiOrder, DapiError> = .success(DapiOrdersTests.order("ord_1", status: .cancelled))

    var calls: [String] { lock.withLock { _calls } }
    var queries: [DapiOrderListQuery] { lock.withLock { _queries } }
    var placed: [(DapiOrderRequest, String)] { lock.withLock { _placed } }
    var cancelKeys: [String] { lock.withLock { _cancelKeys } }
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }

    /// Results for `quote(id:)` per ID, in order; the last one repeats.
    func scriptQuote(_ id: String, _ results: [Result<DapiQuote, DapiError>]) { lock.withLock { _quoteReads[id] = results } }
    func scriptShipping(_ results: [Result<DapiShippingEstimate, DapiError>]) { lock.withLock { _shipping = results } }
    func scriptOrderReads(_ results: [Result<DapiOrder, DapiError>]) { lock.withLock { _orderReads = results } }
    func scriptPages(_ results: [Result<DapiOrderPage, DapiError>]) { lock.withLock { _pages = results } }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }
    private func next<T>(_ list: inout [Result<T, DapiError>]) -> Result<T, DapiError> {
        guard let first = list.first else { return .failure(.readFailed("no script")) }
        if list.count > 1 { list.removeFirst() }
        return first
    }

    func account() async throws -> DapiAccount { record("account"); throw DapiError.notSent("unused") }
    func onboarding() async throws -> DapiOnboarding { record("onboarding"); throw DapiError.notSent("unused") }
    func quotes(named name: String, maxPages: Int) async throws -> [DapiQuote] { record("list"); return try listResult.get() }
    func createUpload(fileName: String, contentType: String, sizeBytes: Int64, idempotencyKey: String) async throws -> DapiUploadTarget {
        record("upload"); throw DapiError.notSent("never")
    }
    func sendUploadBytes(_ target: DapiUploadTarget, fileURL: URL) async throws { record("put") }
    func createQuote(uploadID: String, name: String, idempotencyKey: String) async throws -> DapiQuote {
        record("create"); throw DapiError.notSent("never")
    }
    func quote(id: String) async throws -> DapiQuote {
        record("read")
        let result: Result<DapiQuote, DapiError> = lock.withLock {
            var list = _quoteReads[id] ?? []
            let value = next(&list)
            _quoteReads[id] = list
            return value
        }
        return try result.get()
    }
    func shippingEstimate(quoteID: String, quantity: Int, countryCode: String) async throws -> DapiShippingEstimate {
        record("shipping1"); throw DapiError.notSent("unused")
    }
    func materials() async throws -> [DapiMaterial] { record("materials"); return try materialsResult.get() }
    func wallet() async throws -> DapiWallet { record("wallet"); return try walletResult.get() }
    func orders(_ query: DapiOrderListQuery) async throws -> DapiOrderPage {
        record("orders")
        let result: Result<DapiOrderPage, DapiError> = lock.withLock { _queries.append(query); return next(&_pages) }
        return try result.get()
    }
    func shippingEstimate(lines: [DapiOrderLineRequest], countryCode: String) async throws -> DapiShippingEstimate {
        record("shipping")
        let result: Result<DapiShippingEstimate, DapiError> = lock.withLock { next(&_shipping) }
        return try result.get()
    }
    func order(id: String) async throws -> DapiOrder {
        record("order")
        let result: Result<DapiOrder, DapiError> = lock.withLock { next(&_orderReads) }
        return try result.get()
    }
    func placeOrder(_ request: DapiOrderRequest, idempotencyKey: String) async throws -> DapiOrder {
        record("place")
        lock.withLock { _placed.append((request, idempotencyKey)) }
        return try placeResult.get()
    }
    func cancelOrder(id: String, idempotencyKey: String) async throws -> DapiOrder {
        record("cancel")
        lock.withLock { _cancelKeys.append(idempotencyKey) }
        return try cancelResult.get()
    }
}

@MainActor final class DapiOrdersTests: XCTestCase {
    nonisolated static func usd(_ cents: Int) -> DapiMoney { DapiMoney(amountMinor: cents, currency: "usd") }

    nonisolated static func order(_ id: String, status: DapiOrderStatus, reference: String? = nil,
                                  items: [DapiOrderItem]? = []) -> DapiOrder {
        DapiOrder(id: id, number: "2AP" + id, status: status, mode: "wallet", reference: reference, customerName: nil,
                  customerEmail: nil, formattedAddress: nil, city: nil, countryName: nil, countryCode: "GB", charges: nil,
                  shipping: DapiOrderShipping(tier: nil, carrier: nil, trackingNumber: nil, shippedAt: nil),
                  itemCount: items?.count ?? 0, items: items, refunds: [], createdAt: nil, updatedAt: nil)
    }

    nonisolated static func quote(_ id: String, cents: Int? = 500, status: String = "ready", approval: String? = nil,
                                  suggestions: [DapiSuggestedMaterial] = [
                                    DapiSuggestedMaterial(slot: 1, materialName: "PLA Red", fileFilamentType: "PLA", match: "exact")
                                  ]) -> DapiQuote {
        DapiQuote(id: id, name: "Plinth 0123456789abcdef", status: status, price: cents.map(usd), failureReason: nil,
                  suggestedMaterials: suggestions, createdAt: nil, approvalStatus: approval)
    }

    nonisolated static func shipping(_ cents: Int, country: String = "GB") -> DapiShippingEstimate {
        DapiShippingEstimate(countryCode: country, zoneName: "UK", tier: "small", total: usd(cents))
    }

    func recipient() -> DapiOrderRecipient {
        DapiOrderRecipient(name: "Ada Lovelace", email: "ada@example.com", phone: nil, line1: "1 Street", line2: nil,
                           city: "London", state: nil, postalCode: "N1 1AA", countryCode: "GB")
    }

    func draft(quantity: Int = 2) -> DapiOrderDraft {
        DapiOrderDraft(lines: [.init(request: DapiOrderLineRequest(quoteID: "qte_1", quantity: quantity, materials: .suggested),
                                     name: "Bracket")],
                       recipient: recipient(), sellerReference: "ETSY 123", notes: nil)
    }

    /// Records what the place runner did with the session.
    final class PlaceHarness {
        var problem: String?
        var unconfirmed: [DapiUnconfirmedOrder] = []
        var begun = 0
        var ended = 0
        var keys = 0
        var activity: [(String, String, Bool)] = []
    }

    func placeEnvironment(_ stub: ScriptedDapiOrders, _ harness: PlaceHarness) -> DapiPlaceEnvironment {
        DapiPlaceEnvironment(
            client: { stub },
            orderingProblem: { harness.problem },
            unconfirmedOrders: { harness.unconfirmed },
            beginWrite: { harness.begun += 1; return UUID() },
            endWrite: { _ in harness.ended += 1 },
            noteUnconfirmed: { harness.unconfirmed.append($0) },
            newIdempotencyKey: { harness.keys += 1; return "key-\(harness.keys)" },
            newReferenceToken: { "deadbeef" },
            now: { Date(timeIntervalSince1970: 1_793_000_000) })
    }

    func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out", file: file, line: line)
    }

    func readyRunner(_ stub: ScriptedDapiOrders, _ harness: PlaceHarness, draft: DapiOrderDraft? = nil) async -> DapiPlaceOrderRunner {
        let runner = DapiPlaceOrderRunner(draft: draft ?? self.draft(), environment: placeEnvironment(stub, harness))
        runner.log = { harness.activity.append(($0, $1, $2)) }
        runner.start()
        await waitUntil { runner.phase != .checking }
        return runner
    }

    func settled(_ runner: DapiPlaceOrderRunner) async {
        await waitUntil { runner.phase != .rechecking && runner.phase != .placing }
    }

    // MARK: Reference

    func testReferenceKeepsSafeCharactersAndAddsTheMarker() {
        XCTAssertEqual(dapiOrderReference(sellerReference: "ETSY-3141592653", token: "deadbeef"), "ETSY-3141592653_pldeadbeef")
        XCTAssertEqual(dapiOrderReference(sellerReference: "Etsy #3141 59", token: "deadbeef"), "Etsy-3141-59_pldeadbeef")
        XCTAssertEqual(dapiOrderReference(sellerReference: "  #12__3 ", token: "deadbeef"), "12__3_pldeadbeef")
        XCTAssertEqual(dapiOrderReference(sellerReference: "Café — Nº 7", token: "deadbeef"), "Caf-N-7_pldeadbeef")
    }

    func testReferenceWithoutSellerTextIsPlinthAndTheToken() {
        XCTAssertEqual(dapiOrderReference(sellerReference: nil, token: "deadbeef"), "plinth_deadbeef")
        XCTAssertEqual(dapiOrderReference(sellerReference: "   ", token: "deadbeef"), "plinth_deadbeef")
        XCTAssertEqual(dapiOrderReference(sellerReference: "#@!", token: "deadbeef"), "plinth_deadbeef")
    }

    func testReferenceIsAtMostOneHundredCharactersAndMatchesThePattern() {
        let long = String(repeating: "a", count: 88) + " " + String(repeating: "b", count: 50)
        let reference = dapiOrderReference(sellerReference: long, token: "0123abcd")
        XCTAssertLessThanOrEqual(reference.count, 100)
        XCTAssertTrue(reference.hasSuffix("_pl0123abcd"))
        // The cut lands just after a dash: the dash is trimmed.
        XCTAssertFalse(reference.contains("-_pl"))
        XCTAssertNotNil(reference.range(of: "^[A-Za-z0-9_-]{1,100}$", options: .regularExpression))
        let hundred = dapiOrderReference(sellerReference: String(repeating: "x", count: 300), token: "deadbeef")
        XCTAssertEqual(hundred.count, 100)
    }

    func testReferenceTokenIsEightLowerHexAndFresh() {
        let tokens = (0..<20).map { _ in dapiOrderReferenceToken() }
        XCTAssertTrue(tokens.allSatisfy { $0.count == 8 && $0.allSatisfy { $0.isHexDigit && !$0.isUppercase } })
        XCTAssertGreaterThan(Set(tokens).count, 15)
    }

    // MARK: Validation

    func validAddress() -> DapiComposerAddress {
        var address = DapiComposerAddress()
        address.delivery.name = "Ada Lovelace"
        address.delivery.email = "ada@example.com"
        address.delivery.line1 = "1 Street"
        address.delivery.city = "London"
        address.delivery = deliveryApplyingCountryPick("GB", to: address.delivery)
        return address
    }

    func testAValidRecipientHasNoProblems() {
        XCTAssertEqual(dapiRecipientProblems(validAddress()), [:])
    }

    func testEmailIsRequiredAndNeverInvented() {
        var address = validAddress()
        address.delivery.email = "  "
        XCTAssertNotNil(dapiRecipientProblems(address)[.email])
        address.delivery.email = "not-an-email"
        XCTAssertNotNil(dapiRecipientProblems(address)[.email])
        address.delivery.email = ""
        XCTAssertEqual(dapiOrderRecipient(address).email, "")
    }

    func testRequiredFieldsLengthsAndCountry() {
        var address = validAddress()
        address.delivery.name = String(repeating: "n", count: 201)
        address.delivery.line1 = ""
        address.delivery.city = ""
        address.delivery = deliveryApplyingCountryPick("", to: address.delivery)
        let problems = dapiRecipientProblems(address, notes: String(repeating: "x", count: 2001))
        XCTAssertNotNil(problems[.name])
        XCTAssertNotNil(problems[.line1])
        XCTAssertNotNil(problems[.city])
        XCTAssertNotNil(problems[.country])
        XCTAssertNotNil(problems[.notes])
        var region = validAddress()
        region.delivery = deliveryApplyingCountryPick("EU", to: region.delivery)
        XCTAssertNotNil(dapiRecipientProblems(region)[.country])
        var lineBreak = validAddress()
        lineBreak.delivery.line2 = "Flat 2\nBack"
        XCTAssertNotNil(dapiRecipientProblems(lineBreak)[.line2])
    }

    func testRecipientIsTrimmedWithEmptyOptionalsAsNil() {
        var address = validAddress()
        address.delivery.name = "  Ada Lovelace "
        address.phone = "   "
        address.delivery.line2 = ""
        address.delivery.zip = " N1 1AA "
        let recipient = dapiOrderRecipient(address)
        XCTAssertEqual(recipient.name, "Ada Lovelace")
        XCTAssertNil(recipient.phone)
        XCTAssertNil(recipient.line2)
        XCTAssertEqual(recipient.postalCode, "N1 1AA")
        XCTAssertEqual(recipient.countryCode, "GB")
    }

    // MARK: Lines

    func readyLine(quantity: Int = 2, useSuggested: Bool = true, quote: DapiQuote? = DapiOrdersTests.quote("qte_1")) -> DapiComposerLine {
        DapiComposerLine(name: "Bracket", quoteID: quote?.id, quote: quote, quantity: quantity, useSuggested: useSuggested, state: .ready)
    }

    func testLineRequestUsesSuggestionsOrEverySlot() {
        XCTAssertEqual(dapiLineRequest(readyLine())?.materials, .suggested)
        var chosen = readyLine(useSuggested: false)
        XCTAssertNil(dapiLineRequest(chosen), "A slot without a material blocks the line")
        chosen.slotMaterials[1] = "mat_red"
        XCTAssertEqual(dapiLineRequest(chosen)?.materials, .slots([DapiMaterialSlot(slot: 1, materialID: "mat_red")]))
        // No suggestions: the slots are required even with the toggle on.
        let bare = readyLine(quote: DapiOrdersTests.quote("qte_2", suggestions: []))
        XCTAssertNil(dapiLineRequest(bare))
    }

    func testLineProblemsBlockTheOrder() {
        var line = readyLine()
        line.quantityText = "0"
        XCTAssertNotNil(dapiLineProblem(line))
        line.quantityText = "10001"
        XCTAssertNotNil(dapiLineProblem(line))
        line.quantityText = "10000"
        XCTAssertNil(dapiLineProblem(line))
        XCTAssertNotNil(dapiLineProblem(readyLine(quote: DapiOrdersTests.quote("q", approval: "rejected"))))
        XCTAssertNotNil(dapiComposerLinesProblem([]))
        XCTAssertNotNil(dapiComposerLinesProblem(Array(repeating: readyLine(), count: 101)))
        XCTAssertNil(dapiComposerLinesProblem([readyLine()]))
        XCTAssertNotNil(dapiComposerLinesProblem([readyLine(), DapiComposerLine(name: "x", state: .problem(dapiNoQuoteForModelText))]))
    }

    func testDraftNeedsEveryLineAndAValidRecipient() {
        XCTAssertNotNil(dapiOrderDraft(lines: [readyLine()], address: validAddress(), reference: " ETSY ", notes: "", catalogue: []))
        XCTAssertNil(dapiOrderDraft(lines: [readyLine()], address: DapiComposerAddress(), reference: "", notes: "", catalogue: []))
        let draft = dapiOrderDraft(lines: [readyLine()], address: validAddress(), reference: " ETSY ", notes: "  ", catalogue: [])
        XCTAssertEqual(draft?.sellerReference, "ETSY")
        XCTAssertNil(draft?.notes)
        XCTAssertEqual(draft?.units, 2)
    }

    func testMaterialGroupsPutPLAThenPETG() {
        let materials = [
            DapiMaterial(id: "3", name: "TPU Black", color: nil, colorHex: nil, filamentType: "tpu"),
            DapiMaterial(id: "2", name: "PETG White", color: nil, colorHex: nil, filamentType: "petg"),
            DapiMaterial(id: "1", name: "PLA Red", color: nil, colorHex: nil, filamentType: "pla"),
            DapiMaterial(id: "4", name: "Mystery", color: nil, colorHex: nil, filamentType: nil),
        ]
        XCTAssertEqual(dapiMaterialGroups(materials).map(\.title), ["PLA", "PETG", "TPU", "Other"])
        XCTAssertEqual(dapiSuggestedMaterialID(slot: 1, quote: DapiOrdersTests.quote("q"), catalogue: materials), "1")
    }

    func testDuplicateCopiesQuotesQuantitiesAndSlotsButNoAddress() {
        let item = DapiOrderItem(id: "itm_1", quoteID: "qte_9", quoteName: "Plinth 0123456789abcdef",
                                 materials: [DapiMaterialSlot(slot: 1, materialID: "mat_red", materialName: "PLA Red")],
                                 quantity: 4, unitPrice: nil, productionUnitPrice: nil, total: nil)
        let lines = dapiComposerLines(duplicating: DapiOrdersTests.order("ord_1", status: .shipped, items: [item]))
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].quoteID, "qte_9")
        XCTAssertEqual(lines[0].quantity, 4)
        XCTAssertFalse(lines[0].useSuggested)
        XCTAssertEqual(lines[0].slotMaterials, [1: "mat_red"])
        XCTAssertEqual(lines[0].state, .resolving, "The quote is read again before it can be ordered")
        XCTAssertTrue(dapiComposerLines(duplicating: DapiOrdersTests.order("ord_2", status: .paid, items: nil)).isEmpty)
    }

    // MARK: Line names

    func testNeutralQuoteNamesResolveToTheLibraryModel() {
        XCTAssertTrue(dapiIsNeutralQuoteName("Plinth 0123456789abcdef"))
        XCTAssertFalse(dapiIsNeutralQuoteName("Plinth 0123456789ABCDEF"))
        XCTAssertFalse(dapiIsNeutralQuoteName("Plinth 0123"))
        XCTAssertFalse(dapiIsNeutralQuoteName("My bracket"))
        let names = ["Plinth 0123456789abcdef": "Wall bracket"]
        XCTAssertEqual(dapiLineDisplayName(quoteName: "Plinth 0123456789abcdef", modelNames: names), "Wall bracket")
        XCTAssertEqual(dapiLineDisplayName(quoteName: "Plinth fedcba9876543210", modelNames: names), "Plinth fedcba9876543210")
        XCTAssertEqual(dapiLineDisplayName(quoteName: "Seller's name", modelNames: names), "Seller's name")
        XCTAssertEqual(dapiLineDisplayName(quoteName: nil, modelNames: names), "Unnamed quote")
        XCTAssertEqual(dapiQuoteName(fileHash: "0123456789abcdef" + String(repeating: "0", count: 48)), "Plinth 0123456789abcdef")
    }

    // MARK: Totals and the pre-send comparison

    func testUpToTotalNeverAddsAcrossCurrencies() {
        XCTAssertEqual(dapiOrderUpToTotal(lines: [(DapiOrdersTests.usd(500), 3)], shipping: DapiOrdersTests.usd(699)),
                       DapiOrdersTests.usd(2199))
        XCTAssertNil(dapiOrderUpToTotal(lines: [(DapiMoney(amountMinor: 500, currency: "eur"), 1)], shipping: DapiOrdersTests.usd(699)))
        XCTAssertNil(dapiOrderUpToTotal(lines: [(DapiOrdersTests.usd(Int.max / 2), 10_000)], shipping: DapiOrdersTests.usd(1)))
    }

    func testReviewChangesNamePriceShippingCountryAndLines() {
        let lines = [DapiOrderLineRequest(quoteID: "qte_1", quantity: 2, materials: .suggested)]
        let reviewed = DapiOrderReviewSnapshot(countryCode: "GB", lines: lines, unitPrices: ["qte_1": DapiOrdersTests.usd(500)],
                                               shippingTotal: DapiOrdersTests.usd(699), orderingProblem: nil)
        XCTAssertEqual(dapiReviewChanges(reviewed: reviewed, current: reviewed), [])
        var price = reviewed
        price.unitPrices["qte_1"] = DapiOrdersTests.usd(450)
        XCTAssertEqual(dapiReviewChanges(reviewed: reviewed, current: price, names: ["qte_1": "Bracket"]),
                       ["Bracket: $5.00 → $4.50 per unit."])
        var shipping = reviewed
        shipping.shippingTotal = DapiOrdersTests.usd(799)
        XCTAssertEqual(dapiReviewChanges(reviewed: reviewed, current: shipping).count, 1)
        var country = reviewed
        country.countryCode = "DE"
        XCTAssertEqual(dapiReviewChanges(reviewed: reviewed, current: country), ["The delivery country changed."])
        var changedLines = reviewed
        changedLines.lines = [DapiOrderLineRequest(quoteID: "qte_1", quantity: 3, materials: .suggested)]
        XCTAssertEqual(dapiReviewChanges(reviewed: reviewed, current: changedLines), ["The order’s lines changed."])
        var account = reviewed
        account.orderingProblem = "Not approved"
        XCTAssertEqual(dapiReviewChanges(reviewed: reviewed, current: account), ["Not approved"])
    }

    // MARK: Place outcomes

    func testPlaceFailureClassification() {
        XCTAssertEqual(dapiPlaceFailure(DapiError.outcomeUnknown("timeout")), .unknown(dapiPlaceUnknownText))
        XCTAssertEqual(dapiPlaceFailure(DapiError.readFailed("x")), .unknown(dapiPlaceUnknownText))
        XCTAssertEqual(dapiPlaceFailure(CancellationError()), .unknown(dapiPlaceUnknownText))
        guard case .notCharged = dapiPlaceFailure(DapiError.refused(status: 402, code: "insufficient_balance", message: nil)) else {
            return XCTFail("A refusal charged nothing")
        }
        guard case .notCharged = dapiPlaceFailure(DapiError.rateLimited(code: "rate_limited", retryAt: nil)) else {
            return XCTFail("A 429 charged nothing")
        }
        guard case .notCharged = dapiPlaceFailure(DapiError.notSent("offline")) else { return XCTFail() }
        guard case .notCharged = dapiPlaceFailure(DapiError.missingKey) else { return XCTFail() }
    }

    func scriptedReady() -> ScriptedDapiOrders {
        let stub = ScriptedDapiOrders()
        stub.scriptQuote("qte_1", [.success(DapiOrdersTests.quote("qte_1"))])
        stub.scriptShipping([.success(DapiOrdersTests.shipping(699))])
        return stub
    }

    func testPlaceSendsOnceAndReportsSuccess() async {
        let stub = scriptedReady()
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertNil(runner.figures?.wallet, "A missing_scope wallet read just hides the balance")
        var placed: [DapiOrder] = []
        runner.onPlaced = { placed.append($0) }
        runner.placeOrder()
        runner.placeOrder() // A double click does nothing more.
        await settled(runner)
        XCTAssertEqual(stub.count("place"), 1)
        XCTAssertEqual(stub.placed.first?.0.reference, "ETSY-123_pldeadbeef")
        XCTAssertEqual(stub.placed.first?.1, "key-1")
        XCTAssertEqual(placed.map(\.id), ["ord_new"])
        XCTAssertEqual(harness.begun, 1)
        XCTAssertEqual(harness.ended, 1)
        XCTAssertTrue(harness.unconfirmed.isEmpty)
        XCTAssertEqual(harness.activity.map(\.1), ["Placed"])
        guard case .placed = runner.phase else { return XCTFail("\(runner.phase)") }
    }

    func testRefusalExplainsAndChargesNothing() async {
        let stub = scriptedReady()
        stub.placeResult = .failure(.refused(status: 402, code: "insufficient_balance", message: "balance"))
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        runner.placeOrder()
        await settled(runner)
        guard case .notCharged(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("wallet"))
        XCTAssertTrue(harness.unconfirmed.isEmpty)
        XCTAssertEqual(harness.ended, 1)
        XCTAssertFalse(runner.canPlace, "No Try Again that resends")
        XCTAssertEqual(stub.count("place"), 1)
    }

    func testRateLimitedChargesNothingAndIsNotRetried() async {
        let stub = scriptedReady()
        stub.placeResult = .failure(.rateLimited(code: "rate_limited", retryAt: nil))
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        runner.placeOrder()
        await settled(runner)
        guard case .notCharged = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertEqual(stub.count("place"), 1)
        XCTAssertTrue(harness.unconfirmed.isEmpty)
    }

    func testUnknownOutcomeRecordsAnUnconfirmedOrder() async {
        let stub = scriptedReady()
        stub.placeResult = .failure(.outcomeUnknown("timed out"))
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        runner.placeOrder()
        await settled(runner)
        guard case .unknown = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertEqual(harness.unconfirmed.count, 1)
        XCTAssertEqual(harness.unconfirmed.first?.reference, "ETSY-123_pldeadbeef")
        XCTAssertEqual(harness.unconfirmed.first?.recipientName, "Ada Lovelace")
        XCTAssertEqual(harness.unconfirmed.first?.units, 2)
        XCTAssertEqual(harness.unconfirmed.first?.countryCode, "GB")
        XCTAssertEqual(runner.unconfirmed, harness.unconfirmed.first)
        XCTAssertEqual(harness.ended, 1)
        XCTAssertEqual(harness.activity.map(\.1), ["Outcome unknown"])
        XCTAssertEqual(stub.count("place"), 1)
    }

    func testUnconfirmedOrdersAskBeforePlacing() async {
        let stub = scriptedReady()
        let harness = PlaceHarness()
        harness.unconfirmed = [DapiUnconfirmedOrder(id: UUID(), reference: "r", recipientName: "Bob", countryCode: "US",
                                                    units: 1, sentAt: Date())]
        let runner = await readyRunner(stub, harness)
        runner.placeOrder()
        XCTAssertTrue(runner.askPlaceAnyway)
        XCTAssertEqual(runner.phase, .ready)
        runner.declinePlaceAnyway()
        XCTAssertEqual(stub.count("place"), 0)
        runner.placeOrder(confirmedAnyway: true)
        await settled(runner)
        XCTAssertEqual(stub.count("place"), 1)
        XCTAssertTrue(dapiPlaceAnywayMessage(harness.unconfirmed).contains("Bob · 1 unit · US"))
    }

    func testChangedFiguresStopBeforeSending() async {
        let stub = ScriptedDapiOrders()
        stub.scriptQuote("qte_1", [.success(DapiOrdersTests.quote("qte_1"))])
        stub.scriptShipping([.success(DapiOrdersTests.shipping(699)), .success(DapiOrdersTests.shipping(899))])
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(runner.changes.count, 1)
        XCTAssertEqual(runner.figures?.shipping.total, DapiOrdersTests.usd(899))
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertEqual(harness.begun, 0)
        // Pressed again with the new figures shown, it sends.
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(stub.count("place"), 1)
    }

    func testQuoteRejectedBetweenReviewAndPlaceBlocks() async {
        let stub = ScriptedDapiOrders()
        stub.scriptQuote("qte_1", [.success(DapiOrdersTests.quote("qte_1")), .success(DapiOrdersTests.quote("qte_1", approval: "rejected"))])
        stub.scriptShipping([.success(DapiOrdersTests.shipping(699))])
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        runner.placeOrder()
        await settled(runner)
        guard case .blocked = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertFalse(runner.canPlace)
    }

    func testAccountThatCantOrderBlocksTheReview() async {
        let stub = scriptedReady()
        let harness = PlaceHarness()
        harness.problem = "Not approved"
        let runner = await readyRunner(stub, harness)
        XCTAssertEqual(runner.phase, .blocked("Not approved"))
        XCTAssertFalse(runner.canPlace)
        runner.placeOrder()
        XCTAssertEqual(stub.count("place"), 0)
    }

    func testClosingDuringTheRecheckSendsNothing() async {
        let stub = scriptedReady()
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        runner.placeOrder()
        runner.close()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertEqual(harness.begun, 0)
    }

    // MARK: Look for Order on 3DAPI

    func attempt(_ reference: String) -> DapiUnconfirmedOrder {
        DapiUnconfirmedOrder(id: UUID(), reference: reference, recipientName: "Ada", countryCode: "GB", units: 1, sentAt: Date())
    }

    func testLookForOrderConfirmsFoundAndKeepsNotFound() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([
            .success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_a", status: .paid, reference: "ref_a")], hasMore: false, nextCursor: nil)),
            .success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_x", status: .paid, reference: "ref_b_other")], hasMore: false, nextCursor: nil)),
        ])
        let a = attempt("ref_a"), b = attempt("ref_b")
        var confirmed: [String] = []
        let results = await dapiLookForOrders([a, b], client: stub, pause: { _ in }, confirm: { confirmed.append($0) })
        XCTAssertEqual(confirmed, ["ref_a"])
        guard case .found(let order) = results[a.id] else { return XCTFail() }
        XCTAssertEqual(order.id, "ord_a")
        XCTAssertEqual(results[b.id], .notFound, "Only an exact reference counts; a near match never clears the warning")
        XCTAssertEqual(stub.queries.map(\.reference), ["ref_a", "ref_b"])
        XCTAssertTrue(dapiOrderLookupSummary([.notFound]).contains("keeps the warning"))
    }

    func testLookForOrderStopsAtARateLimit() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([.failure(.rateLimited(code: "rate_limited", retryAt: nil))])
        let a = attempt("ref_a"), b = attempt("ref_b")
        var confirmed: [String] = []
        let results = await dapiLookForOrders([a, b], client: stub, pause: { _ in }, confirm: { confirmed.append($0) })
        XCTAssertEqual(stub.count("orders"), 1)
        XCTAssertEqual(results[b.id], .skipped)
        XCTAssertTrue(confirmed.isEmpty)
    }

    func testSessionSettlementsConfirmByReferenceAndClearOnlyCancelled() {
        let orders = [DapiOrdersTests.order("ord_1", status: .cancelled, reference: "ref_1"),
                      DapiOrdersTests.order("ord_2", status: .paid, reference: "ref_2")]
        let settled = dapiSessionSettlements(orders, unconfirmed: [attempt("ref_2"), attempt("ref_9")],
                                             cancelUnknown: ["ord_1", "ord_2"])
        XCTAssertEqual(settled.confirmReferences, ["ref_2"])
        XCTAssertEqual(settled.clearCancelIDs, ["ord_1"])
    }

    // MARK: Cancel

    func testCancelGating() {
        let paid = DapiOrdersTests.order("ord_1", status: .paid)
        XCTAssertNil(dapiCancelBlockedReason(order: paid, shownStatus: .paid, outcomeUnknown: false))
        XCTAssertNotNil(dapiCancelBlockedReason(order: paid, shownStatus: .paid, outcomeUnknown: true))
        XCTAssertNotNil(dapiCancelBlockedReason(order: DapiOrdersTests.order("o", status: .assigned), shownStatus: .paid, outcomeUnknown: false))
        XCTAssertNotNil(dapiCancelBlockedReason(order: DapiOrdersTests.order("o", status: .inProduction), shownStatus: .inProduction, outcomeUnknown: false))
        XCTAssertNotNil(dapiCancelBlockedReason(order: DapiOrdersTests.order("o", status: .unknown("weird")), shownStatus: .unknown("weird"), outcomeUnknown: false))
    }

    func testCancelOutcomeRules() {
        XCTAssertEqual(dapiCancelOutcome(.success(DapiOrdersTests.order("o", status: .cancelled))), .cancelled(DapiOrdersTests.order("o", status: .cancelled)))
        XCTAssertTrue(dapiCancelOutcome(.success(DapiOrdersTests.order("o", status: .paid))).recordsUnknown)
        XCTAssertTrue(dapiCancelOutcome(.failure(DapiError.outcomeUnknown("x"))).recordsUnknown)
        XCTAssertTrue(dapiCancelOutcome(.failure(CancellationError())).recordsUnknown)
        let refused = dapiCancelOutcome(.failure(DapiError.refused(status: 409, code: "order_not_cancellable", message: nil)))
        XCTAssertFalse(refused.recordsUnknown)
        guard case .refused(let text) = refused else { return XCTFail() }
        XCTAssertTrue(text.contains("contact@dapi.digital"))
    }

    final class CancelHarness {
        var unknown: Set<String> = []
        var begun = 0
        var ended = 0
    }

    func cancelRunner(_ stub: ScriptedDapiOrders, _ harness: CancelHarness, shown: DapiOrderStatus = .paid) -> DapiCancelOrderRunner {
        DapiCancelOrderRunner(orderID: "ord_1", shownStatus: shown, environment: DapiCancelEnvironment(
            client: { stub },
            beginWrite: { harness.begun += 1; return UUID() },
            endWrite: { _ in harness.ended += 1 },
            outcomeUnknown: { harness.unknown.contains($0) },
            noteUnknown: { harness.unknown.insert($0) },
            clearUnknown: { harness.unknown.remove($0) },
            newIdempotencyKey: { "cancel-key" }))
    }

    func testCancelRunnerSendsOnceAfterARecheck() async {
        let stub = ScriptedDapiOrders()
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .paid))])
        let harness = CancelHarness()
        let runner = cancelRunner(stub, harness)
        var updates: [DapiOrderStatus] = []
        runner.onOrder = { updates.append($0.status) }
        runner.start()
        await waitUntil { runner.phase != .loading }
        XCTAssertTrue(runner.canCancel)
        runner.cancelOrder()
        runner.cancelOrder()
        await waitUntil { if case .done = runner.phase { true } else { false } }
        XCTAssertEqual(stub.count("order"), 2, "Read on opening and again just before sending")
        XCTAssertEqual(stub.count("cancel"), 1)
        XCTAssertEqual(harness.begun, 1)
        XCTAssertEqual(harness.ended, 1)
        XCTAssertEqual(updates.last, .cancelled)
        XCTAssertTrue(harness.unknown.isEmpty)
    }

    func testCancelRunnerStopsWhenTheStatusMoved() async {
        let stub = ScriptedDapiOrders()
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .paid)), .success(DapiOrdersTests.order("ord_1", status: .assigned))])
        let harness = CancelHarness()
        let runner = cancelRunner(stub, harness)
        runner.start()
        await waitUntil { runner.phase != .loading }
        runner.cancelOrder()
        await waitUntil { if case .blocked = runner.phase { true } else { false } }
        XCTAssertEqual(stub.count("cancel"), 0)
    }

    func testCancelRunnerRecordsAnUnknownOutcome() async {
        let stub = ScriptedDapiOrders()
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .paid))])
        stub.cancelResult = .failure(.outcomeUnknown("timeout"))
        let harness = CancelHarness()
        let runner = cancelRunner(stub, harness)
        runner.start()
        await waitUntil { runner.phase != .loading }
        runner.cancelOrder()
        await waitUntil { if case .done = runner.phase { true } else { false } }
        XCTAssertEqual(harness.unknown, ["ord_1"])
        // A second review refuses to send while the outcome is unknown.
        let second = cancelRunner(stub, harness)
        second.start()
        await waitUntil { second.phase != .loading }
        XCTAssertFalse(second.canCancel)
        XCTAssertEqual(stub.count("cancel"), 1)
    }

    // MARK: List

    func testStatusFilterAndSearchQuery() {
        let all = dapiOrderListQuery(status: nil, search: "  ", cursor: nil)
        XCTAssertEqual(all.statuses, [])
        XCTAssertNil(all.search)
        XCTAssertNil(all.cursor)
        XCTAssertTrue(all.expandItems)
        let filtered = dapiOrderListQuery(status: .inProduction, search: " 2AP12 ", cursor: "c2")
        XCTAssertEqual(filtered.statuses, [.inProduction])
        XCTAssertEqual(filtered.search, "2AP12")
        XCTAssertEqual(filtered.cursor, "c2")
        XCTAssertEqual(dapiOrderListQuery(status: nil, search: String(repeating: "x", count: 150), cursor: nil).search?.count, 100)
        XCTAssertNotNil(dapiOrdersEmptyText(status: .shipped, search: ""))
        XCTAssertNil(dapiOrdersEmptyText(status: nil, search: "abc"))
    }

    func testMergeDedupesByIDAndReplacesInPlace() {
        let a = DapiOrdersTests.order("a", status: .paid), b = DapiOrdersTests.order("b", status: .paid)
        let bShipped = DapiOrdersTests.order("b", status: .shipped), c = DapiOrdersTests.order("c", status: .paid)
        let merged = dapiMergeOrders([a, b], with: [bShipped, c])
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(merged[1].status, .shipped)
        XCTAssertEqual(dapiInsertingOrder(c, into: [a, c]).map(\.id), ["c", "a"])
        XCTAssertEqual(dapiReplacingOrder(bShipped, in: [a, b]).map(\.status), [.paid, .shipped])
        XCTAssertEqual(dapiReplacingOrder(c, in: [a]).map(\.id), ["c", "a"])
    }

    func testListPagesByCursorAndSettlesTheSession() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([
            .success(DapiOrderPage(orders: [DapiOrdersTests.order("a", status: .paid, reference: "ref_a"),
                                            DapiOrdersTests.order("b", status: .cancelled)], hasMore: true, nextCursor: "c2")),
            .success(DapiOrderPage(orders: [DapiOrdersTests.order("b", status: .cancelled), DapiOrdersTests.order("c", status: .shipped)],
                                   hasMore: false, nextCursor: nil)),
        ])
        var confirmed: [String] = []
        var cleared: [String] = []
        let list = DapiOrderListState(environment: DapiOrderListEnvironment(
            client: { stub },
            unconfirmedOrders: { [self.attempt("ref_a")] },
            cancelOutcomeUnknown: { ["b"] },
            confirmUnconfirmed: { confirmed.append($0) },
            clearCancelUnknown: { cleared.append($0) }))
        list.reload()
        await waitUntil { list.loaded && !list.loading }
        XCTAssertEqual(list.orders.map(\.id), ["a", "b"])
        XCTAssertTrue(list.hasMore)
        XCTAssertEqual(confirmed, ["ref_a"])
        XCTAssertEqual(cleared, ["b"])
        list.loadMore()
        await waitUntil { !list.loading }
        XCTAssertEqual(list.orders.map(\.id), ["a", "b", "c"])
        XCTAssertFalse(list.hasMore)
        XCTAssertEqual(stub.queries.map(\.cursor), [nil, "c2"])
        list.applyStatus(.shipped)
        await waitUntil { !list.loading }
        XCTAssertEqual(stub.queries.last?.statuses, [.shipped])
        XCTAssertNil(stub.queries.last?.cursor)
    }

    func testListReadFailureIsShownAndNotRetried() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([.failure(.readFailed("3DAPI is unavailable"))])
        var activity: [String] = []
        let list = DapiOrderListState(environment: DapiOrderListEnvironment(
            client: { stub }, unconfirmedOrders: { [] }, cancelOutcomeUnknown: { [] },
            confirmUnconfirmed: { _ in }, clearCancelUnknown: { _ in }))
        list.log = { _, detail, _ in activity.append(detail) }
        list.reload()
        await waitUntil { !list.loading && list.loadError != nil }
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(stub.count("orders"), 1)
        XCTAssertEqual(activity, ["Read failed"])
    }

    func testInsertAndSelectPutsAPlacedOrderFirst() {
        let list = DapiOrderListState(environment: DapiOrderListEnvironment(
            client: { ScriptedDapiOrders() }, unconfirmedOrders: { [] }, cancelOutcomeUnknown: { [] },
            confirmUnconfirmed: { _ in }, clearCancelUnknown: { _ in }))
        list.insertAndSelect(DapiOrdersTests.order("new", status: .paid))
        XCTAssertEqual(list.selection, "new")
        XCTAssertEqual(list.selectedOrder?.id, "new")
    }

    func testAccountNotice() {
        XCTAssertNotNil(dapiOrdersAccountNotice(configured: false, checked: false, account: nil, onboarding: nil, checkFailure: nil))
        XCTAssertNil(dapiOrdersAccountNotice(configured: true, checked: false, account: nil, onboarding: nil, checkFailure: nil))
        let ready = DapiAccount(kind: "integrator", approval: "approved", effectiveScopes: ["orders:write", "orders:read"])
        XCTAssertNil(dapiOrdersAccountNotice(configured: true, checked: true, account: ready, onboarding: nil, checkFailure: nil))
        let readOnly = DapiAccount(kind: "integrator", approval: "approved", effectiveScopes: ["orders:read"])
        XCTAssertNotNil(dapiOrdersAccountNotice(configured: true, checked: true, account: readOnly, onboarding: nil, checkFailure: nil))
    }
}
