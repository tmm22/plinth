import XCTest
@testable import Plinth

// The 3DAPI Orders section (DapiOrderComposer.swift, DapiOrderList.swift): the pure helpers, and the place, cancel,
// lookup and list runners against a scripted stub. Nothing here reaches the network, the Keychain, `DapiConnection`
// or `DapiOrderSession`.

/// Holds every call that reaches it until the test releases it (then lets every later call through), so a test can act
/// at a known point of a request instead of sleeping.
final class DapiOrderTestGate: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var arrivals = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    /// How many calls have reached the gate.
    var reached: Int { lock.withLock { arrivals } }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let pass: Bool = lock.withLock {
                arrivals += 1
                if released { return true }
                waiting.append(continuation)
                return false
            }
            if pass { continuation.resume() }
        }
    }

    func release() {
        let held: [CheckedContinuation<Void, Never>] = lock.withLock {
            released = true
            defer { waiting = [] }
            return waiting
        }
        held.forEach { $0.resume() }
    }
}

/// A scripted 3DAPI that quotes and orders: each method returns its configured result and records its calls.
final class ScriptedDapiOrders: DapiQuoting, DapiOrdering, @unchecked Sendable {
    private let lock = NSLock()
    private var _gates: [String: DapiOrderTestGate] = [:]
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
    /// Holds `placeOrder` this long before answering (a request waiting for 3DAPI).
    var placeDelayNanoseconds: UInt64 = 0

    /// Records an event in `calls` (to check the order of things around the requests).
    func note(_ event: String) { record(event) }

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

    /// From now on, calls named `name` ("read", "orders", "order", …) wait at the returned gate after being recorded.
    func gate(_ name: String) -> DapiOrderTestGate {
        let gate = DapiOrderTestGate()
        lock.withLock { _gates[name] = gate }
        return gate
    }

    private func passGate(_ name: String) async {
        let gate: DapiOrderTestGate? = lock.withLock { _gates[name] }
        await gate?.wait()
    }

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
        await passGate("read")
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
    func materials() async throws -> [DapiMaterial] {
        record("materials")
        await passGate("materials")
        return try materialsResult.get()
    }
    func wallet() async throws -> DapiWallet { record("wallet"); return try walletResult.get() }
    func orders(_ query: DapiOrderListQuery) async throws -> DapiOrderPage {
        record("orders")
        let result: Result<DapiOrderPage, DapiError> = lock.withLock { _queries.append(query); return next(&_pages) }
        await passGate("orders")
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
        await passGate("order")
        return try result.get()
    }
    func placeOrder(_ request: DapiOrderRequest, idempotencyKey: String) async throws -> DapiOrder {
        record("place")
        lock.withLock { _placed.append((request, idempotencyKey)) }
        if placeDelayNanoseconds > 0 { try? await Task.sleep(nanoseconds: placeDelayNanoseconds) }
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
            noteUnconfirmed: { harness.unconfirmed.append($0); stub.note("noted \($0.reference)") },
            confirmUnconfirmed: { reference in
                harness.unconfirmed.removeAll { $0.reference == reference }
                stub.note("confirmed \(reference)")
            },
            newIdempotencyKey: { harness.keys += 1; return "key-\(harness.keys)" },
            newReferenceToken: { "deadbeef" },
            now: { Date(timeIntervalSince1970: 1_793_000_000) })
    }

    /// Waits for something that must happen (up to 10 s, so a loaded machine doesn't fail it); never used to show that
    /// something didn't happen.
    func waitUntil(_ condition: @MainActor () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
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

    func testComposerChecksMatchTheClientsPreSendCheck() {
        // Lengths count Unicode scalars, as the client and 3DAPI's schema do: "é" written as e + U+0301 is two.
        var decomposed = validAddress()
        decomposed.delivery.name = String(repeating: "e\u{301}", count: 150)
        XCTAssertEqual(decomposed.delivery.name.count, 150)
        XCTAssertNotNil(dapiRecipientProblems(decomposed)[.name])
        // The client's email rule: a dotted domain.
        var email = validAddress()
        email.delivery.email = "ada@localhost"
        XCTAssertNotNil(dapiRecipientProblems(email)[.email])
        XCTAssertFalse(dapiEmailLooksValid("ada@localhost"))
        // Control characters in notes (other than line breaks and tabs) are refused here, as by the client.
        XCTAssertNotNil(dapiRecipientProblems(validAddress(), notes: "Hi\u{7}")[.notes])
        XCTAssertNil(dapiRecipientProblems(validAddress(), notes: "Line one\nLine two")[.notes])
        // Whatever passes the composer passes the client's own check.
        for address in [validAddress()] {
            let draft = dapiOrderDraft(lines: [readyLine()], address: address, reference: "ETSY 1", notes: "Gift\nwrap",
                                       catalogue: [])
            XCTAssertNotNil(draft)
            if let draft {
                XCTAssertNil(dapiOrderRequestProblem(DapiOrderRequest(
                    lines: draft.lines.map(\.request), recipient: draft.recipient,
                    reference: dapiOrderReference(sellerReference: draft.sellerReference, token: "deadbeef"),
                    customerNotes: draft.notes)))
            }
        }
        // A line the client would refuse (a quote ID 3DAPI doesn't issue) never makes a draft.
        let badQuote = readyLine(quote: DapiOrdersTests.quote("q-1"))
        XCTAssertNil(dapiOrderDraft(lines: [badQuote], address: validAddress(), reference: "", notes: "", catalogue: []))
        XCTAssertNotNil(dapiComposerRequestProblem(lines: [DapiOrderLineRequest(quoteID: "q-1", quantity: 1, materials: .suggested)],
                                                   recipient: recipient(), notes: nil))
    }

    func testUnservedCountriesAreLeftOut() {
        for code in ["RU", "BY", "IR", "SY", "ru"] {
            XCTAssertFalse(dapiIsDeliveryCountry(code), code)
            var address = validAddress()
            address.delivery = deliveryApplyingCountryPick(code.uppercased(), to: address.delivery)
            XCTAssertNotNil(dapiRecipientProblems(address)[.country])
        }
        XCTAssertTrue(dapiIsDeliveryCountry("GB"))
        XCTAssertTrue(dapiIsDeliveryCountry("UA"))
        XCTAssertTrue(dapiUnservedCountriesNote.contains("Russia"))
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

    func testSuggestedMaterialPrefersItsIDThenTheName() {
        let materials = [
            DapiMaterial(id: "mat_red1", name: "PLA Red", color: nil, colorHex: nil, filamentType: "pla"),
            DapiMaterial(id: "mat_red2", name: "PLA Red Matte", color: nil, colorHex: nil, filamentType: "pla"),
        ]
        func quote(name: String?, id: String?) -> DapiQuote {
            DapiOrdersTests.quote("qte_1", suggestions: [
                DapiSuggestedMaterial(slot: 1, materialName: name, fileFilamentType: nil, match: nil, materialID: id)
            ])
        }
        XCTAssertEqual(dapiSuggestedMaterialID(slot: 1, quote: quote(name: "PLA Red", id: "mat_red2"), catalogue: materials),
                       "mat_red2", "The ID wins over the name")
        XCTAssertEqual(dapiSuggestedMaterialID(slot: 1, quote: quote(name: "PLA Red", id: "mat_gone"), catalogue: materials),
                       "mat_red1", "An ID not in the catalogue falls back to the name")
        XCTAssertEqual(dapiSuggestedMaterialID(slot: 1, quote: quote(name: nil, id: "mat_red1"), catalogue: materials), "mat_red1")
        XCTAssertNil(dapiSuggestedMaterialID(slot: 2, quote: quote(name: "PLA Red", id: nil), catalogue: materials))
        XCTAssertTrue(dapiQuoteHasSuggestions(quote(name: nil, id: "mat_red1")))
        XCTAssertFalse(dapiQuoteHasSuggestions(quote(name: nil, id: nil)))
    }

    func testMaterialsReadFailureWaitsForTryAgain() async {
        let stub = ScriptedDapiOrders()
        stub.materialsResult = .failure(.readFailed("down"))
        let state = DapiComposerState(environment: DapiComposerEnvironment(
            client: { stub }, readyQuoteID: { _ in nil }, rememberReadyQuote: { _, _ in },
            hashFile: { _ in "" }, noteHash: { _, _ in }))
        state.loadMaterialsIfNeeded()
        await waitUntil { !state.materialsLoading && state.materialsProblem != nil }
        // Later changes in the form ask again; nothing is read by itself. A read would start at once (it sets
        // `materialsLoading` before it reaches 3DAPI), so this needs no waiting.
        state.loadMaterialsIfNeeded()
        state.loadMaterialsIfNeeded()
        XCTAssertFalse(state.materialsLoading, "No read started")
        XCTAssertNotNil(state.materialsProblem)
        XCTAssertEqual(stub.count("materials"), 1)
        stub.materialsResult = .success([DapiMaterial(id: "mat_a", name: "PLA Red", color: nil, colorHex: nil, filamentType: "pla")])
        state.retryMaterials()
        await waitUntil { !state.materialsLoading }
        XCTAssertEqual(stub.count("materials"), 2)
        XCTAssertEqual(state.materials.map(\.id), ["mat_a"])
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
        // A line sent with 3DAPI's suggestions gets what the quote suggests when it is placed: a change counts.
        var suggested = reviewed
        suggested.suggestedMaterials = ["qte_1": ["1|mat_red|PLA Red"]]
        var otherSuggestion = suggested
        otherSuggestion.suggestedMaterials = ["qte_1": ["1|mat_blue|PLA Blue"]]
        XCTAssertEqual(dapiReviewChanges(reviewed: suggested, current: suggested), [])
        XCTAssertEqual(dapiReviewChanges(reviewed: suggested, current: otherSuggestion, names: ["qte_1": "Bracket"]),
                       ["Bracket: 3DAPI’s suggested materials changed."])
        XCTAssertEqual(dapiReviewChanges(reviewed: suggested, current: reviewed).count, 1, "Suggestions gone")
    }

    func testSuggestionSignatureIsSortedAndNamesIDAndName() {
        let quote = DapiOrdersTests.quote("qte_1", suggestions: [
            DapiSuggestedMaterial(slot: 2, materialName: "PLA White", fileFilamentType: "PLA", match: "exact", materialID: "mat_w"),
            DapiSuggestedMaterial(slot: 1, materialName: " PLA Red ", fileFilamentType: "PLA", match: "close"),
        ])
        XCTAssertEqual(dapiSuggestionSignature(quote), ["1||PLA Red", "2|mat_w|PLA White"])
        let fresh = DapiOrdersTests.quote("qte_1", suggestions: [
            DapiSuggestedMaterial(slot: 2, materialName: "PLA White", fileFilamentType: "PLA", match: "exact"),
            DapiSuggestedMaterial(slot: 1, materialName: "PLA Red", fileFilamentType: "PLA", match: "exact"),
        ])
        let line = DapiOrderDraft.Line(request: DapiOrderLineRequest(quoteID: "qte_1", quantity: 1, materials: .suggested),
                                       name: "Bracket", materialsText: "3DAPI’s suggestion: PLA Old")
        XCTAssertEqual(dapiReviewMaterialsText(line, quotes: ["qte_1": fresh]), "3DAPI’s suggestion: PLA Red, PLA White",
                       "The review names the fresh quote's suggestions")
        XCTAssertEqual(dapiReviewMaterialsText(line, quotes: [:]), "3DAPI’s suggestion: PLA Old")
        let chosen = DapiOrderDraft.Line(request: DapiOrderLineRequest(quoteID: "qte_1", quantity: 1,
                                                                       materials: .slots([DapiMaterialSlot(slot: 1, materialID: "mat_a")])),
                                         name: "Bracket", materialsText: "PLA Black")
        XCTAssertEqual(dapiReviewMaterialsText(chosen, quotes: ["qte_1": quote]), "PLA Black")
    }

    func testChangedSuggestionsStopBeforeSending() async {
        let stub = ScriptedDapiOrders()
        let red = [DapiSuggestedMaterial(slot: 1, materialName: "PLA Red", fileFilamentType: "PLA", match: "exact")]
        let blue = [DapiSuggestedMaterial(slot: 1, materialName: "PLA Blue", fileFilamentType: "PLA", match: "exact")]
        stub.scriptQuote("qte_1", [.success(DapiOrdersTests.quote("qte_1", suggestions: red)),
                                   .success(DapiOrdersTests.quote("qte_1", suggestions: blue))])
        stub.scriptShipping([.success(DapiOrdersTests.shipping(699))])
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(runner.changes, ["Bracket: 3DAPI’s suggested materials changed."])
        XCTAssertEqual(runner.figures?.quotes["qte_1"]?.suggestedMaterials.first?.materialName, "PLA Blue")
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertEqual(harness.begun, 0)
    }

    func testSuggestionsGoneBlocksTheReview() async {
        let stub = ScriptedDapiOrders()
        stub.scriptQuote("qte_1", [.success(DapiOrdersTests.quote("qte_1", suggestions: []))])
        stub.scriptShipping([.success(DapiOrdersTests.shipping(699))])
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        guard case .blocked(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("no longer suggests materials"))
        XCTAssertFalse(runner.canPlace)
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
        let gate = stub.gate("read")
        runner.placeOrder()
        // The re-check is inside its quote read when Go Back closes the review; then 3DAPI answers.
        await waitUntil { gate.reached == 1 }
        runner.close()
        gate.release()
        await runner.lastCheckTask?.value
        // `send` records the attempt and begins the write synchronously, so had the re-check gone on to send, both
        // would show by now.
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertEqual(harness.begun, 0)
        XCTAssertTrue(harness.unconfirmed.isEmpty)
        XCTAssertEqual(runner.phase, .rechecking, "Nothing ran after the close")
    }

    func testReappearingDuringTheRecheckStartsTheChecksOverWithoutSending() async {
        let stub = scriptedReady()
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        let gate = stub.gate("read")
        runner.placeOrder()
        await waitUntil { gate.reached == 1 }
        // The sheet goes away and comes back while the re-check waits.
        runner.close()
        runner.start()
        XCTAssertEqual(runner.phase, .checking, "Back to the first checks, not stuck re-checking")
        gate.release()
        await runner.lastCheckTask?.value
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.count("place"), 0, "The earlier press never sends")
        XCTAssertEqual(harness.begun, 0)
        // Only a new press sends.
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(stub.count("place"), 1)
    }

    func testTheAttemptIsRecordedBeforeSendingAndRemovedOnSuccess() async {
        let stub = scriptedReady()
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        var sending: [String] = []
        runner.onSending = { sending.append($0.reference) }
        runner.placeOrder()
        await settled(runner)
        let events = stub.calls.filter { $0 != "read" && $0 != "shipping" && $0 != "wallet" }
        XCTAssertEqual(events, ["noted ETSY-123_pldeadbeef", "place", "confirmed ETSY-123_pldeadbeef"])
        XCTAssertEqual(sending, ["ETSY-123_pldeadbeef"])
        XCTAssertTrue(harness.unconfirmed.isEmpty)
    }

    func testARefusalRemovesTheAttemptAfterTellingTheComposer() async {
        let stub = scriptedReady()
        stub.placeResult = .failure(.refused(status: 402, code: "insufficient_balance", message: nil))
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        var notCharged: [String] = []
        runner.onNotCharged = { reference in
            // Told before the record goes, so a composer never mistakes the removal for a found order.
            XCTAssertEqual(harness.unconfirmed.map(\.reference), [reference])
            notCharged.append(reference)
        }
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(notCharged, ["ETSY-123_pldeadbeef"])
        XCTAssertTrue(harness.unconfirmed.isEmpty)
        guard case .notCharged(let text) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertEqual(text, dapiRefusalMessage(status: 402, code: "insufficient_balance", message: nil, placingOrder: true),
                       "The client's copy is the single source")
        XCTAssertEqual(text.components(separatedBy: "charged").count - 1, 1, "Says nothing was charged exactly once: \(text)")
    }

    func testPlaceRefusalSaysNothingWasChargedExactlyOnce() {
        let codes: [String?] = ["insufficient_balance", "payment_failed", "quote_rejected", "production_unavailable",
                                "material_not_allowed", "validation_failed", nil]
        for code in codes {
            let text = dapiPlaceRefusalMessage(DapiError.refused(status: 422, code: code, message: "Something"))
            XCTAssertEqual(text.lowercased().components(separatedBy: "nothing was charged").count - 1, 1,
                           "\(code ?? "no code"): \(text)")
        }
        guard case .notCharged(let limited) = dapiPlaceFailure(DapiError.rateLimited(code: "rate_limited", retryAt: nil)) else {
            return XCTFail()
        }
        XCTAssertEqual(limited.components(separatedBy: "charged").count - 1, 1, limited)
    }

    func testAnOrderInFlightMakesAnotherPlaceAskButNotItself() async {
        let stub = scriptedReady()
        stub.placeDelayNanoseconds = 300_000_000
        let harness = PlaceHarness()
        let first = await readyRunner(stub, harness)
        let second = await readyRunner(stub, harness)
        first.placeOrder()
        await waitUntil { first.phase == .placing }
        XCTAssertEqual(harness.unconfirmed.count, 1, "Recorded while 3DAPI hasn't answered")
        first.placeOrder() // A second press while placing does nothing and asks nothing.
        XCTAssertFalse(first.askPlaceAnyway)
        second.placeOrder()
        XCTAssertTrue(second.askPlaceAnyway, "Another composer's Place asks Place Anyway while an order is in flight")
        second.declinePlaceAnyway()
        await settled(first)
        XCTAssertEqual(stub.count("place"), 1)
        XCTAssertTrue(harness.unconfirmed.isEmpty)
        XCTAssertEqual(harness.begun, harness.ended)
    }

    func testOwnAttemptSettledOnlyWhenItLeavesTheUnconfirmedList() {
        XCTAssertFalse(dapiComposerOwnOrderSettled(sent: [], unconfirmed: []))
        XCTAssertFalse(dapiComposerOwnOrderSettled(sent: ["a"], unconfirmed: ["a", "b"]))
        XCTAssertTrue(dapiComposerOwnOrderSettled(sent: ["a"], unconfirmed: ["b"]), "Found by Look for Order, or placed")
        let state = DapiComposerState(environment: DapiComposerEnvironment(
            client: { ScriptedDapiOrders() }, readyQuoteID: { _ in nil }, rememberReadyQuote: { _, _ in },
            hashFile: { _ in "" }, noteHash: { _, _ in }))
        state.noteSending(reference: "ref_1")
        XCTAssertFalse(state.ownOrderSettled(unconfirmedReferences: ["ref_1"]))
        state.noteNotCharged(reference: "ref_1")
        XCTAssertFalse(state.ownOrderSettled(unconfirmedReferences: []), "A refused attempt isn't a found order")
        state.noteSending(reference: "ref_2")
        XCTAssertTrue(state.ownOrderSettled(unconfirmedReferences: []))
    }

    func testDiscardSaysNothingWasSentOnlyWithoutAnUnconfirmedAttempt() {
        XCTAssertTrue(dapiComposerDiscardMessage(hasUnconfirmedAttempt: false).hasPrefix("Nothing was sent to 3DAPI."))
        let sent = dapiComposerDiscardMessage(hasUnconfirmedAttempt: true)
        XCTAssertFalse(sent.contains("Nothing was sent"))
        XCTAssertTrue(sent.contains("may have been placed and charged"))
        XCTAssertTrue(sent.contains("Look for Order on 3DAPI"))
    }

    func sampleCreditWallet(_ cents: Int) -> DapiWallet {
        DapiWallet(balance: DapiOrdersTests.usd(10_000), sampleCredit: DapiOrdersTests.usd(cents), sampleCreditExpiresAt: nil)
    }

    func testSampleCreditIsSentOnlyWhenTicked() async {
        let stub = scriptedReady()
        stub.walletResult = .success(sampleCreditWallet(2_000))
        let harness = PlaceHarness()
        let off = await readyRunner(stub, harness)
        XCTAssertFalse(off.useSampleCredit, "Off by default")
        off.placeOrder()
        await settled(off)
        XCTAssertEqual(stub.placed.last?.0.useSampleCredit, false)
        let on = await readyRunner(stub, harness)
        on.useSampleCredit = true
        on.placeOrder()
        await settled(on)
        XCTAssertEqual(stub.placed.last?.0.useSampleCredit, true)
        XCTAssertEqual(stub.count("place"), 2)
    }

    func testSampleCreditChangedOrGoneStopsBeforeSending() async {
        let stub = scriptedReady()
        stub.walletResult = .success(sampleCreditWallet(2_000))
        let harness = PlaceHarness()
        let runner = await readyRunner(stub, harness)
        runner.useSampleCredit = true
        runner.placeOrder()
        runner.useSampleCredit = false // Changed while the figures are checked again.
        await settled(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertFalse(runner.changes.isEmpty)
        XCTAssertEqual(stub.count("place"), 0)
        // Ticked, but the fresh wallet shows no sample credit any more.
        stub.walletResult = .success(sampleCreditWallet(0))
        runner.useSampleCredit = true
        runner.placeOrder()
        await settled(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertFalse(runner.useSampleCredit)
        XCTAssertEqual(stub.count("place"), 0)
        XCTAssertNil(dapiSampleCreditChange(pressed: false, current: false, available: false))
        XCTAssertNil(dapiSampleCreditChange(pressed: true, current: true, available: true))
        XCTAssertNotNil(dapiSampleCreditChange(pressed: true, current: false, available: true))
        XCTAssertNotNil(dapiSampleCreditChange(pressed: true, current: true, available: false))
    }

    func testWalletShortfallAndNotes() {
        let wallet = DapiWallet(balance: DapiOrdersTests.usd(1_000), sampleCredit: nil, sampleCreditExpiresAt: nil)
        XCTAssertEqual(dapiWalletShortfall(upTo: DapiOrdersTests.usd(1_500), wallet: wallet), DapiOrdersTests.usd(500))
        XCTAssertNil(dapiWalletShortfall(upTo: DapiOrdersTests.usd(1_000), wallet: wallet))
        XCTAssertNil(dapiWalletShortfall(upTo: DapiOrdersTests.usd(1_500), wallet: nil))
        XCTAssertNil(dapiWalletShortfall(upTo: DapiMoney(amountMinor: 1_500, currency: "eur"), wallet: wallet))
        XCTAssertTrue(dapiWalletShortfallText(DapiOrdersTests.usd(500)).contains("without a confirmed VAT number"))
        XCTAssertTrue(dapiWalletNote.contains("without a confirmed VAT number"))
        XCTAssertTrue(dapiLineUsesChosenMaterials(DapiOrderLineRequest(quoteID: "qte_1", quantity: 1,
                                                                      materials: .slots([DapiMaterialSlot(slot: 1, materialID: "mat_a")]))))
        XCTAssertFalse(dapiLineUsesChosenMaterials(DapiOrderLineRequest(quoteID: "qte_1", quantity: 1, materials: .suggested)))
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
        var sentFrom: [String: DapiOrderStatus] = [:]
        var cancelled: Set<String> = []
        var begun = 0
        var ended = 0
    }

    func cancelRunner(_ stub: ScriptedDapiOrders, _ harness: CancelHarness, shown: DapiOrderStatus = .paid) -> DapiCancelOrderRunner {
        DapiCancelOrderRunner(orderID: "ord_1", shownStatus: shown, environment: DapiCancelEnvironment(
            client: { stub },
            beginWrite: { harness.begun += 1; return UUID() },
            endWrite: { _ in harness.ended += 1 },
            outcomeUnknown: { harness.unknown.contains($0) },
            sentFrom: { harness.sentFrom[$0] },
            noteUnknown: { harness.unknown.insert($0); harness.sentFrom[$0] = $1 },
            clearUnknown: { harness.unknown.remove($0); harness.sentFrom[$0] = nil },
            noteCancelled: { harness.cancelled.insert($0) },
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
        XCTAssertEqual(harness.cancelled, ["ord_1"], "The order watch stays quiet about the seller's own cancellation")
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
        XCTAssertEqual(harness.sentFrom, ["ord_1": .paid], "The status the cancel was sent from is recorded")
        XCTAssertTrue(harness.cancelled.isEmpty)
        // A second review refuses to send while the outcome is unknown (the order still shows Paid).
        let second = cancelRunner(stub, harness)
        second.start()
        await waitUntil { second.phase != .loading }
        XCTAssertFalse(second.canCancel)
        XCTAssertEqual(stub.count("cancel"), 1)
        XCTAssertEqual(harness.unknown, ["ord_1"], "A reload still showing the sent-from status keeps the lock")
        // A reload showing another status lifts it.
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .assigned))])
        let third = cancelRunner(stub, harness, shown: .assigned)
        third.start()
        await waitUntil { third.phase != .loading }
        XCTAssertTrue(harness.unknown.isEmpty)
        XCTAssertFalse(third.canCancel, "Assigned can't be cancelled anyway")
    }

    func testCancelLockLiftsOnCancelledOrAnotherStatusOnly() {
        let paid = DapiOrdersTests.order("ord_1", status: .paid)
        XCTAssertFalse(dapiCancelLockLifted(order: paid, sentFrom: .paid))
        XCTAssertFalse(dapiCancelLockLifted(order: DapiOrdersTests.order("ord_1", status: DapiOrderStatus(raw: " PAID ")), sentFrom: .paid))
        XCTAssertTrue(dapiCancelLockLifted(order: DapiOrdersTests.order("ord_1", status: .cancelled), sentFrom: .paid))
        XCTAssertTrue(dapiCancelLockLifted(order: DapiOrdersTests.order("ord_1", status: .assigned), sentFrom: .paid))
        XCTAssertTrue(dapiCancelLockLifted(order: DapiOrdersTests.order("ord_1", status: .cancelled), sentFrom: nil))
        XCTAssertFalse(dapiCancelLockLifted(order: DapiOrdersTests.order("ord_1", status: .assigned), sentFrom: nil),
                       "Without a recorded status only cancelled lifts it")
        let orders = [DapiOrdersTests.order("ord_1", status: .paid), DapiOrdersTests.order("ord_2", status: .inProduction),
                      DapiOrdersTests.order("ord_3", status: .cancelled)]
        let settled = dapiSessionSettlements(orders, unconfirmed: [], cancelUnknown: ["ord_1", "ord_2", "ord_3"],
                                             cancelSentFrom: ["ord_1": .paid, "ord_2": .paid])
        XCTAssertEqual(settled.clearCancelIDs, ["ord_2", "ord_3"])
    }

    func testCancelRefusalUsesTheClientsCopyAndRecordsNothing() async {
        let stub = ScriptedDapiOrders()
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .paid))])
        stub.cancelResult = .failure(.refused(status: 409, code: "order_not_cancellable", message: nil))
        let harness = CancelHarness()
        let runner = cancelRunner(stub, harness)
        runner.start()
        await waitUntil { runner.phase != .loading }
        runner.cancelOrder()
        await waitUntil { if case .done = runner.phase { true } else { false } }
        guard case .done(.refused(let text)) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertEqual(text, DapiError.refused(status: 409, code: "order_not_cancellable", message: nil).userMessage)
        XCTAssertTrue(harness.unknown.isEmpty)
        XCTAssertEqual(harness.ended, 1)
    }

    func testClosingTheCancelReviewDuringTheRecheckSendsNothing() async {
        let stub = ScriptedDapiOrders()
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .paid))])
        let harness = CancelHarness()
        let runner = cancelRunner(stub, harness)
        runner.start()
        await waitUntil { runner.phase != .loading }
        let gate = stub.gate("order")
        runner.cancelOrder()
        // Go Back during the re-read, then 3DAPI answers it.
        await waitUntil { gate.reached == 1 }
        runner.close()
        gate.release()
        await runner.lastReadTask?.value
        // `send` locks the order and begins the write synchronously, so had the re-read gone on to send, both would
        // show by now.
        XCTAssertEqual(stub.count("cancel"), 0)
        XCTAssertEqual(harness.begun, 0)
        XCTAssertTrue(harness.unknown.isEmpty)
    }

    func testReappearingDuringTheCancelRecheckReadsAgainWithoutSending() async {
        let stub = ScriptedDapiOrders()
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .paid))])
        let harness = CancelHarness()
        let runner = cancelRunner(stub, harness)
        runner.start()
        await waitUntil { runner.phase != .loading }
        let gate = stub.gate("order")
        runner.cancelOrder()
        await waitUntil { gate.reached == 1 }
        runner.close()
        runner.start()
        gate.release()
        await runner.lastReadTask?.value
        XCTAssertTrue(runner.canCancel, "Back to the opening read, not stuck loading")
        XCTAssertEqual(stub.count("cancel"), 0, "The earlier press never sends")
        XCTAssertEqual(harness.begun, 0)
    }

    func testTheCancelLockIsRecordedBeforeSending() async {
        let stub = ScriptedDapiOrders()
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .paid))])
        let harness = CancelHarness()
        let runner = DapiCancelOrderRunner(orderID: "ord_1", shownStatus: .paid, environment: DapiCancelEnvironment(
            client: { stub },
            beginWrite: { harness.begun += 1; return UUID() },
            endWrite: { _ in harness.ended += 1 },
            outcomeUnknown: { harness.unknown.contains($0) },
            sentFrom: { harness.sentFrom[$0] },
            noteUnknown: { harness.unknown.insert($0); harness.sentFrom[$0] = $1; stub.note("locked \($0)") },
            clearUnknown: { harness.unknown.remove($0); harness.sentFrom[$0] = nil; stub.note("unlocked \($0)") },
            noteCancelled: { harness.cancelled.insert($0) },
            newIdempotencyKey: { "cancel-key" }))
        runner.start()
        await waitUntil { runner.phase != .loading }
        runner.cancelOrder()
        await waitUntil { if case .done = runner.phase { true } else { false } }
        XCTAssertEqual(stub.calls.filter { $0 != "order" }, ["locked ord_1", "cancel", "unlocked ord_1"],
                       "Locked before the request, lifted by the returned cancelled order")
        XCTAssertTrue(harness.unknown.isEmpty)
        // An unclear outcome keeps the lock made before sending.
        let unclear = ScriptedDapiOrders()
        unclear.scriptOrderReads([.success(DapiOrdersTests.order("ord_1", status: .paid))])
        unclear.cancelResult = .failure(.outcomeUnknown("timeout"))
        let unclearHarness = CancelHarness()
        let second = cancelRunner(unclear, unclearHarness)
        second.start()
        await waitUntil { second.phase != .loading }
        second.cancelOrder()
        await waitUntil { if case .done = second.phase { true } else { false } }
        XCTAssertEqual(unclearHarness.unknown, ["ord_1"])
        XCTAssertEqual(unclearHarness.sentFrom, ["ord_1": .paid])
    }

    func testCancelCopyFollowsTheModeAndStatus() {
        XCTAssertTrue(dapiCancelExplanation(mode: "wallet", status: .paid).contains("your 3DAPI wallet"))
        XCTAssertTrue(dapiCancelExplanation(mode: "checkout", status: .paid).contains("your customer’s card"))
        XCTAssertTrue(dapiCancelExplanation(mode: "checkout", status: .paid).contains("5–10 business days"))
        XCTAssertTrue(dapiCancelExplanation(mode: "checkout", status: .awaitingPayment).contains("checkout link"))
        for mode in ["wallet", "checkout"] {
            XCTAssertTrue(dapiCancelExplanation(mode: mode, status: .paid).contains("once a production partner has it"))
        }
        XCTAssertNil(dapiCancelUnavailableNote(DapiOrdersTests.order("o", status: .paid), cancelUnknown: false))
        XCTAssertNil(dapiCancelUnavailableNote(DapiOrdersTests.order("o", status: .assigned), cancelUnknown: true))
        XCTAssertTrue(dapiCancelUnavailableNote(DapiOrdersTests.order("o", status: .assigned), cancelUnknown: false)!
            .contains("only while an order is Paid"))
        XCTAssertNotNil(dapiCancelUnavailableNote(DapiOrdersTests.order("o", status: .cancelled), cancelUnknown: false))
        XCTAssertNotNil(dapiCancelUnavailableNote(DapiOrdersTests.order("o", status: .shipped), cancelUnknown: false))
        XCTAssertNotNil(dapiCancelUnavailableNote(DapiOrdersTests.order("o", status: .unknown("x")), cancelUnknown: false))
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
        // The Orders screen appears: the first page is read.
        list.keyChanged(generation: 0, configured: true)
        let firstRead = list.lastLoadTask
        XCTAssertNotNil(firstRead)
        await firstRead?.value
        XCTAssertNotNil(list.loadError)
        XCTAssertFalse(list.loading, "No other read started after the failure")
        XCTAssertTrue(list.lastLoadTask == firstRead, "No read was started after the failure")
        XCTAssertEqual(stub.count("orders"), 1)
        XCTAssertEqual(activity, ["Read failed"])
        // The screen appearing again doesn't retry a failed read by itself either.
        list.keyChanged(generation: 0, configured: true)
        XCTAssertFalse(list.loading)
        XCTAssertEqual(stub.count("orders"), 1)
    }

    func testInsertAndSelectPutsAPlacedOrderFirst() {
        let list = DapiOrderListState(environment: DapiOrderListEnvironment(
            client: { ScriptedDapiOrders() }, unconfirmedOrders: { [] }, cancelOutcomeUnknown: { [] },
            confirmUnconfirmed: { _ in }, clearCancelUnknown: { _ in }))
        list.insertAndSelect(DapiOrdersTests.order("new", status: .paid))
        XCTAssertEqual(list.selection, "new")
        XCTAssertEqual(list.selectedOrder?.id, "new")
    }

    func listState(_ stub: ScriptedDapiOrders) -> DapiOrderListState {
        DapiOrderListState(environment: DapiOrderListEnvironment(
            client: { stub }, unconfirmedOrders: { [] }, cancelOutcomeUnknown: { [] },
            confirmUnconfirmed: { _ in }, clearCancelUnknown: { _ in }))
    }

    func item(_ id: String, quantity: Int = 1) -> DapiOrderItem {
        DapiOrderItem(id: id, quoteID: "qte_1", quoteName: nil, materials: [], quantity: quantity, unitPrice: nil,
                      productionUnitPrice: nil, total: nil)
    }

    func testANewerCopyWithoutLinesKeepsTheLoadedLines() {
        let withLines = DapiOrdersTests.order("ord_a", status: .paid, items: [item("itm_1", quantity: 3)])
        let cancelReply = DapiOrdersTests.order("ord_a", status: .cancelled, items: nil)
        let merged = dapiMergeOrders([withLines], with: [cancelReply])
        XCTAssertEqual(merged[0].status, .cancelled)
        XCTAssertEqual(merged[0].items?.map(\.id), ["itm_1"])
        XCTAssertEqual(dapiReplacingOrder(cancelReply, in: [withLines])[0].items?.count, 1)
        XCTAssertEqual(dapiInsertingOrder(cancelReply, into: [withLines])[0].items?.count, 1)
        // A newer copy with lines (even none) replaces them.
        let emptyLines = DapiOrdersTests.order("ord_a", status: .paid, items: [])
        XCTAssertEqual(dapiMergeOrders([withLines], with: [emptyLines])[0].items?.count, 0)
    }

    func testAKeyChangeForgetsTheOrdersAndDropsLateReplies() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_old", status: .paid)], hasMore: true, nextCursor: "c2"))])
        let list = listState(stub)
        list.keyChanged(generation: 1, configured: true)
        await waitUntil { list.loaded && !list.loading }
        XCTAssertEqual(list.orders.map(\.id), ["ord_old"])
        list.selection = "ord_old"
        // The same generation again does nothing.
        list.keyChanged(generation: 1, configured: true)
        XCTAssertEqual(list.orders.map(\.id), ["ord_old"])
        XCTAssertEqual(stub.count("orders"), 1)
        // A read for the earlier key is on its way when the key changes: its reply is dropped.
        let gate = stub.gate("orders")
        list.reload()
        let lateRead = list.lastLoadTask
        await waitUntil { gate.reached == 1 }
        list.keyChanged(generation: 2, configured: false)
        XCTAssertTrue(list.orders.isEmpty)
        XCTAssertNil(list.selection)
        XCTAssertFalse(list.hasMore)
        gate.release() // 3DAPI answers for the earlier key.
        await lateRead?.value
        XCTAssertTrue(list.orders.isEmpty)
        XCTAssertFalse(list.loaded)
        XCTAssertEqual(stub.count("orders"), 2)
        // A new key reads again.
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_new", status: .paid)], hasMore: false, nextCursor: nil))])
        list.keyChanged(generation: 3, configured: true)
        await waitUntil { list.loaded && !list.loading }
        XCTAssertEqual(list.orders.map(\.id), ["ord_new"])
    }

    func testTheRefreshSpinnerClearsWhenAReloadOverlaps() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_a", status: .paid)], hasMore: false, nextCursor: nil))])
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_a", status: .shipped))])
        let list = listState(stub)
        list.reload()
        await waitUntil { list.loaded && !list.loading }
        list.refreshOrder(id: "ord_a")
        XCTAssertEqual(list.refreshingOrderID, "ord_a")
        list.reload() // Bumps the list's generation while the refresh waits.
        await waitUntil { list.refreshingOrderID == nil && !list.loading }
        XCTAssertNil(list.refreshingOrderID)
    }

    func testARefreshFailureBelongsToItsOrder() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_a", status: .paid),
                                                          DapiOrdersTests.order("ord_b", status: .paid)], hasMore: false, nextCursor: nil))])
        stub.scriptOrderReads([.failure(.readFailed("down"))])
        let list = listState(stub)
        list.reload()
        await waitUntil { list.loaded && !list.loading }
        list.refreshOrder(id: "ord_a")
        await waitUntil { list.refreshingOrderID == nil }
        XCTAssertNotNil(list.orderRefreshError(for: "ord_a"))
        XCTAssertNil(list.orderRefreshError(for: "ord_b"))
    }

    func testAFilterChangeNeverLeavesTheEarlierFiltersRows() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([
            .success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_a", status: .paid)], hasMore: true, nextCursor: "c2")),
            .failure(.readFailed("down")),
        ])
        let list = listState(stub)
        list.reload()
        await waitUntil { list.loaded && !list.loading }
        XCTAssertTrue(list.canUseRowsForTools)
        // Refresh with the same filter fails: the rows and their Load More stay usable.
        list.reload()
        await waitUntil { !list.loading && list.loadError != nil }
        XCTAssertEqual(list.orders.map(\.id), ["ord_a"])
        XCTAssertTrue(list.hasMore)
        XCTAssertTrue(list.canUseRowsForTools)
        // Another status whose read fails: the earlier rows are gone, with no dead Load More.
        list.applyStatus(.shipped)
        XCTAssertTrue(list.orders.isEmpty)
        XCTAssertFalse(list.hasMore)
        await waitUntil { !list.loading }
        XCTAssertTrue(list.orders.isEmpty)
        XCTAssertFalse(list.hasMore)
        XCTAssertTrue(list.canUseRowsForTools)
    }

    func testShowingAnOrderReadsItByIDAndSelectsIt() async {
        let stub = ScriptedDapiOrders()
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_z", status: .shipped))])
        let list = listState(stub)
        list.show(orderID: "ord_z")
        await waitUntil { list.refreshingOrderID == nil }
        XCTAssertEqual(list.selection, "ord_z")
        XCTAssertEqual(list.orders.map(\.id), ["ord_z"])
        XCTAssertEqual(stub.count("order"), 1)
        XCTAssertEqual(stub.count("orders"), 0)
    }

    func testAShownOrderSurvivesAPageThatArrivesAfterIt() async {
        // A notification click while Orders is first read: the by-ID read answers before the page.
        let stub = ScriptedDapiOrders()
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_a", status: .paid)], hasMore: false, nextCursor: nil))])
        stub.scriptOrderReads([.success(DapiOrdersTests.order("ord_old", status: .shipped))])
        let list = listState(stub)
        let pageGate = stub.gate("orders")
        list.keyChanged(generation: 1, configured: true)
        let pageRead = list.lastLoadTask
        await waitUntil { pageGate.reached == 1 }
        list.show(orderID: "ord_old")
        await waitUntil { list.refreshingOrderID == nil }
        XCTAssertEqual(list.selection, "ord_old")
        pageGate.release()
        await pageRead?.value
        XCTAssertEqual(list.orders.map(\.id), ["ord_old", "ord_a"], "The page doesn't drop the order shown on its own")
        XCTAssertEqual(list.selectedOrder?.id, "ord_old")
        XCTAssertTrue(list.hasRowsForTools)
        // A later Refresh keeps it too, with a single row per ID.
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_b", status: .paid),
                                                          DapiOrdersTests.order("ord_a", status: .paid)], hasMore: false, nextCursor: nil))])
        list.reload()
        await list.lastLoadTask?.value
        XCTAssertEqual(list.orders.map(\.id), ["ord_old", "ord_b", "ord_a"])
        XCTAssertEqual(list.selectedOrder?.id, "ord_old")
        // A new key forgets it.
        list.keyChanged(generation: 2, configured: false)
        XCTAssertTrue(list.orders.isEmpty)
        XCTAssertTrue(list.pinned.isEmpty)
    }

    func testAShownOrderOutsideTheFilterClearsTheFilter() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_s", status: .shipped)], hasMore: false, nextCursor: nil))])
        let list = listState(stub)
        list.applyStatus(.shipped)
        list.applySearch("2AP")
        await list.lastLoadTask?.value
        XCTAssertEqual(list.orders.map(\.id), ["ord_s"])
        // A placed order (Paid) isn't a Shipped row: the list shows every order again rather than mixing it in.
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_s", status: .shipped)], hasMore: false, nextCursor: nil))])
        list.insertAndSelect(DapiOrdersTests.order("ord_new", status: .paid))
        XCTAssertNil(list.status)
        XCTAssertEqual(list.appliedSearch, "")
        XCTAssertEqual(list.selection, "ord_new")
        XCTAssertFalse(list.canUseRowsForTools, "No page for the cleared filter yet")
        await list.lastLoadTask?.value
        XCTAssertEqual(stub.queries.last?.statuses, [])
        XCTAssertNil(stub.queries.last?.search)
        XCTAssertEqual(list.orders.map(\.id), ["ord_new", "ord_s"])
        XCTAssertTrue(list.canUseRowsForTools)
        // An order that matches the filter shown keeps it.
        stub.scriptPages([.success(DapiOrderPage(orders: [], hasMore: false, nextCursor: nil))])
        list.applyStatus(.paid)
        await list.lastLoadTask?.value
        XCTAssertEqual(list.orders.map(\.id), ["ord_new"], "Only pinned rows that match the filter come back")
        list.insertAndSelect(DapiOrdersTests.order("ord_paid", status: .paid))
        XCTAssertEqual(list.status, .paid)
        // Pure rule.
        let order = DapiOrdersTests.order("ord_1", status: .paid, reference: "ETSY-123_pldeadbeef")
        XCTAssertTrue(dapiOrderMatchesFilter(order, DapiOrderListFilter(status: nil, search: "")))
        XCTAssertTrue(dapiOrderMatchesFilter(order, DapiOrderListFilter(status: .paid, search: "etsy")))
        XCTAssertTrue(dapiOrderMatchesFilter(order, DapiOrderListFilter(status: nil, search: "2apord")))
        XCTAssertFalse(dapiOrderMatchesFilter(order, DapiOrderListFilter(status: .shipped, search: "")))
        XCTAssertFalse(dapiOrderMatchesFilter(order, DapiOrderListFilter(status: nil, search: "shopify")))
    }

    func testTheSameKeyGenerationKeepsLoadedOrders() async {
        let stub = ScriptedDapiOrders()
        stub.scriptPages([.success(DapiOrderPage(orders: [DapiOrdersTests.order("ord_a", status: .paid)], hasMore: false, nextCursor: nil))])
        let list = listState(stub)
        list.keyChanged(generation: 4, configured: true)
        await list.lastLoadTask?.value
        list.selection = "ord_a"
        // The screen goes away and comes back with the same key.
        list.cancel()
        list.keyChanged(generation: 4, configured: true)
        XCTAssertEqual(list.orders.map(\.id), ["ord_a"])
        XCTAssertEqual(list.selection, "ord_a")
        XCTAssertFalse(list.loading)
        XCTAssertEqual(stub.count("orders"), 1)
        // A read stopped by the screen going away is read again when it comes back.
        let gate = stub.gate("orders")
        list.forgetIfKeyChanged(generation: 5)
        list.keyChanged(generation: 5, configured: true)
        await waitUntil { gate.reached == 1 }
        list.cancel()
        XCTAssertFalse(list.loading)
        gate.release()
        list.keyChanged(generation: 5, configured: true)
        XCTAssertTrue(list.loading)
        await list.lastLoadTask?.value
        XCTAssertEqual(list.orders.map(\.id), ["ord_a"])
    }

    func testEmptyStateOffersEveryWayBack() {
        XCTAssertNil(dapiOrdersEmptyText(status: nil, search: "2AP"))
        XCTAssertEqual(dapiOrdersEmptyActions(status: nil, search: "2AP"), [.clearSearch])
        XCTAssertNotNil(dapiOrdersEmptyText(status: .shipped, search: "2AP"))
        XCTAssertEqual(dapiOrdersEmptyActions(status: .shipped, search: "2AP"), [.clearSearch, .showAll])
        XCTAssertEqual(dapiOrdersEmptyActions(status: .shipped, search: " "), [.showAll])
        XCTAssertEqual(dapiOrdersEmptyActions(status: nil, search: ""), [])
    }

    func testSellerReferenceIsShownWithoutPlinthsCode() {
        XCTAssertEqual(dapiOrderSellerReference("ETSY-123_pldeadbeef"), "ETSY-123")
        XCTAssertNil(dapiOrderSellerReference("plinth_deadbeef"))
        XCTAssertEqual(dapiOrderSellerReference("SHOP-9"), "SHOP-9")
        XCTAssertNil(dapiOrderSellerReference(nil))
        // The full reference stays for lookups.
        let order = DapiOrdersTests.order("ord_1", status: .paid, reference: "ETSY-123_pldeadbeef")
        XCTAssertEqual(dapiOrderMatching(reference: "ETSY-123_pldeadbeef", in: [order])?.id, "ord_1")
        XCTAssertNil(dapiOrderMatching(reference: "ETSY-123", in: [order]))
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
