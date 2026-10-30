import XCTest
@testable import Plinth

// Get 3DAPI Quote… (DapiQuote.swift): the pure helpers and the runner against a scripted `DapiQuoting` stub. Nothing
// here reaches the network, the Keychain or `DapiConnection`.

/// A scripted 3DAPI: each method returns its configured result and counts its calls.
final class ScriptedDapi: DapiQuoting, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [String] = []
    private var _quoteReads: [Result<DapiQuote, DapiError>] = []
    private var _uploadKeys: [String] = []
    private var _uploadNames: [String] = []
    private var _createNames: [String] = []
    private var _shippingRequests: [DapiShippingKey] = []
    var listResult: Result<[DapiQuote], DapiError> = .success([])
    var uploadResult: Result<String, DapiError> = .success("upl_1")
    var createResult: Result<DapiQuote, DapiError> = .success(DapiQuoteTests.quote("qte_new", status: "processing"))
    var shippingResult: Result<DapiShippingEstimate, DapiError> = .success(
        DapiShippingEstimate(countryCode: "GB", zoneName: "UK", tier: "small", total: DapiMoney(amountMinor: 699, currency: "usd")))
    /// Called from inside `uploadQuoteFile`, before it returns (to press Stop or close mid-upload).
    var duringUpload: (@Sendable () async -> Void)?

    var calls: [String] { lock.withLock { _calls } }
    var uploadKeys: [String] { lock.withLock { _uploadKeys } }
    var uploadNames: [String] { lock.withLock { _uploadNames } }
    var createNames: [String] { lock.withLock { _createNames } }
    var shippingRequests: [DapiShippingKey] { lock.withLock { _shippingRequests } }
    func count(_ name: String) -> Int { calls.filter { $0 == name }.count }
    /// Results for `quote(id:)` in order; the last one repeats.
    func scriptQuoteReads(_ results: [Result<DapiQuote, DapiError>]) { lock.withLock { _quoteReads = results } }

    private func record(_ call: String) { lock.withLock { _calls.append(call) } }

    func account() async throws -> DapiAccount { record("account"); throw DapiError.notSent("unused") }
    func onboarding() async throws -> DapiOnboarding { record("onboarding"); throw DapiError.notSent("unused") }
    func quotes(named name: String, maxPages: Int) async throws -> [DapiQuote] {
        record("list")
        return try listResult.get()
    }
    func uploadQuoteFile(at fileURL: URL, fileName: String, contentType: String, idempotencyKey: String) async throws -> String {
        record("upload")
        lock.withLock { _uploadKeys.append(idempotencyKey); _uploadNames.append(fileName) }
        if let duringUpload { await duringUpload() }
        return try uploadResult.get()
    }
    func createQuote(uploadID: String, name: String, idempotencyKey: String) async throws -> DapiQuote {
        record("create")
        lock.withLock { _createNames.append(name) }
        return try createResult.get()
    }
    func quote(id: String) async throws -> DapiQuote {
        record("read")
        let next: Result<DapiQuote, DapiError> = lock.withLock {
            guard let first = _quoteReads.first else { return .failure(.readFailed("no script")) }
            if _quoteReads.count > 1 { _quoteReads.removeFirst() }
            return first
        }
        return try next.get()
    }
    func shippingEstimate(quoteID: String, quantity: Int, countryCode: String) async throws -> DapiShippingEstimate {
        record("shipping")
        lock.withLock { _shippingRequests.append(DapiShippingKey(countryCode: countryCode, quantity: quantity)) }
        return try shippingResult.get()
    }
}

@MainActor final class DapiTestHarness {
    var now = Date(timeIntervalSince1970: 1_793_000_000)
    var sleeps: [TimeInterval] = []
    var cache: [String: String] = [:]
    var begun = 0
    var ended = 0
    var activity: [(title: String, detail: String, success: Bool)] = []
    var keyCounter = 0
    var hasKey = true
    /// Called before each sleep returns, with the sleep's number (1-based).
    var onSleep: ((Int) -> Void)?
    weak var runner: DapiQuoteRunner?

    func environment(_ stub: ScriptedDapi) -> DapiQuoteEnvironment {
        DapiQuoteEnvironment(
            client: { [unowned self] in
                guard self.hasKey else { throw DapiError.missingKey }
                return stub
            },
            readyQuoteID: { [unowned self] in self.cache[$0] },
            rememberReadyQuote: { [unowned self] id, hash in self.cache[hash] = id },
            beginRequest: { [unowned self] in self.begun += 1 },
            endRequest: { [unowned self] in self.ended += 1 },
            refreshAllowance: {},
            sleep: { [weak self] seconds in
                await self?.recordSleep(seconds)
                try Task.checkCancellation()
            },
            now: { [unowned self] in self.now },
            newIdempotencyKey: { [unowned self] in self.keyCounter += 1; return "key-\(self.keyCounter)" },
            fileSize: { dapiRegularFileSize(at: $0) },
            hashFile: { try dapiFileSHA256(at: $0) }
        )
    }

    func recordSleep(_ seconds: TimeInterval) {
        sleeps.append(seconds)
        now = now.addingTimeInterval(seconds)
        onSleep?(sleeps.count)
    }

    func makeRunner(_ stub: ScriptedDapi) -> DapiQuoteRunner {
        let runner = DapiQuoteRunner(environment: environment(stub))
        runner.log = { [unowned self] title, detail, success in self.activity.append((title, detail, success)) }
        self.runner = runner
        return runner
    }
}

@MainActor final class DapiQuoteTests: XCTestCase {
    nonisolated static func quote(_ id: String, status: String, cents: Int? = nil, name: String? = nil, createdAt: Date? = nil,
                                  failure: String? = nil, materials: [DapiSuggestedMaterial] = []) -> DapiQuote {
        DapiQuote(id: id, name: name, status: status, price: cents.map { DapiMoney(amountMinor: $0, currency: "usd") },
                  failureReason: failure, suggestedMaterials: materials, createdAt: createdAt)
    }

    private var tempDirectory: URL!
    private var fileURL: URL!
    private let fileBytes = Data("solid plinth\nendsolid plinth\n".utf8)

    override func setUp() async throws {
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("DapiQuoteTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        fileURL = tempDirectory.appendingPathComponent("Secret Customer Model.stl")
        try fileBytes.write(to: fileURL)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private var fileHash: String { try! dapiFileSHA256(at: fileURL) }
    private var quoteName: String { dapiQuoteName(fileHash: fileHash) }

    private func run(_ runner: DapiQuoteRunner) async {
        runner.getQuote(fileURL: fileURL, format: .stl)
        await runner.runTask?.value
        await runner.shippingTask?.value
    }

    // MARK: Names and hashing

    func testNamesAreNeutralAndNeverCarryTheModelName() {
        let hash = String(repeating: "AB", count: 32)
        XCTAssertEqual(dapiQuoteName(fileHash: hash), "Plinth abababababababab")
        XCTAssertEqual(dapiUploadFileName(fileHash: hash, format: .stl), "plinth-abababababababab.stl")
        XCTAssertEqual(dapiUploadFileName(fileHash: hash, format: .threeMF), "plinth-abababababababab.3mf")
        XCTAssertEqual(dapiUploadFileName(fileHash: hash, format: .obj), "plinth-abababababababab.obj")
        let real = fileHash
        XCTAssertFalse(dapiQuoteName(fileHash: real).contains("Secret"))
        XCTAssertFalse(dapiUploadFileName(fileHash: real, format: .stl).contains("Customer"))
    }

    func testContentTypes() {
        XCTAssertEqual(dapiContentType(.stl), "model/stl")
        XCTAssertEqual(dapiContentType(.obj), "model/obj")
        XCTAssertEqual(dapiContentType(.threeMF), "model/3mf")
    }

    func testHashIsStreamedSHA256InLowerCaseHex() throws {
        let empty = tempDirectory.appendingPathComponent("empty.stl")
        try Data().write(to: empty)
        XCTAssertEqual(try dapiFileSHA256(at: empty), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        let abc = tempDirectory.appendingPathComponent("abc.stl")
        try Data("abc".utf8).write(to: abc)
        XCTAssertEqual(try dapiFileSHA256(at: abc), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        // Small chunks give the same answer as one read, every time.
        XCTAssertEqual(try dapiFileSHA256(at: fileURL, chunkSize: 3), try dapiFileSHA256(at: fileURL))
        XCTAssertEqual(try dapiFileSHA256(at: fileURL), try dapiFileSHA256(at: fileURL))
        XCTAssertThrowsError(try dapiFileSHA256(at: tempDirectory.appendingPathComponent("missing.stl")))
    }

    func testFileProblems() {
        XCTAssertNil(dapiQuoteFileProblem(size: 10, format: .stl))
        XCTAssertNotNil(dapiQuoteFileProblem(size: nil, format: .stl))
        XCTAssertEqual(dapiQuoteFileProblem(size: 0, format: .stl), "The model’s file is empty.")
        XCTAssertNil(dapiQuoteFileProblem(size: dapiMaxQuoteFileBytes, format: .threeMF))
        XCTAssertNotNil(dapiQuoteFileProblem(size: dapiMaxQuoteFileBytes + 1, format: .threeMF))
        XCTAssertNotNil(dapiQuoteFileProblem(size: 10, format: nil))
        XCTAssertNil(dapiRegularFileSize(at: tempDirectory), "a folder isn't a file")
        XCTAssertEqual(dapiRegularFileSize(at: fileURL), Int64(fileBytes.count))
    }

    // MARK: Picking an earlier quote

    func testPickPrefersNewestReadyThenNewestProcessingAndIgnoresFailed() {
        let old = Date(timeIntervalSince1970: 1_000), new = Date(timeIntervalSince1970: 2_000)
        let quotes = [
            Self.quote("qte_failed", status: "failed", name: "Plinth a", createdAt: Date(timeIntervalSince1970: 3_000)),
            Self.quote("qte_proc", status: "processing", name: "Plinth a", createdAt: new),
            Self.quote("qte_ready_old", status: "ready", cents: 100, name: "Plinth a", createdAt: old),
            Self.quote("qte_ready_new", status: "ready", cents: 120, name: "Plinth a", createdAt: new),
            Self.quote("qte_other", status: "ready", cents: 1, name: "Plinth b", createdAt: Date(timeIntervalSince1970: 9_000)),
        ]
        XCTAssertEqual(dapiPickExistingQuote(quotes, name: "Plinth a"), .ready(quotes[3]))
        XCTAssertEqual(dapiPickExistingQuote(Array(quotes.prefix(2)), name: "Plinth a"), .processing(quotes[1]))
        XCTAssertEqual(dapiPickExistingQuote([quotes[0]], name: "Plinth a"), .none)
        XCTAssertEqual(dapiPickExistingQuote([quotes[4]], name: "Plinth a"), .none, "another file's quote is never used")
        // Without dates, 3DAPI's newest-first order decides.
        let undated = [Self.quote("q1", status: "processing", name: "n"), Self.quote("q2", status: "processing", name: "n")]
        XCTAssertEqual(dapiPickExistingQuote(undated, name: "n"), .processing(undated[0]))
    }

    // MARK: Polling schedule

    func testPollDelaysAndGiveUp() {
        XCTAssertEqual(dapiQuotePollDelay(elapsed: 0), 5)
        XCTAssertEqual(dapiQuotePollDelay(elapsed: 119), 5)
        XCTAssertEqual(dapiQuotePollDelay(elapsed: 120), 15)
        XCTAssertEqual(dapiQuotePollDelay(elapsed: 899), 15)
        XCTAssertNil(dapiQuotePollDelay(elapsed: 900))
    }

    // MARK: Money

    func testMoneyText() {
        XCTAssertEqual(dapiMoneyText(DapiMoney(amountMinor: 1245, currency: "usd")), "$12.45")
        XCTAssertEqual(dapiMoneyText(DapiMoney(amountMinor: 123_456, currency: "USD")), "$1,234.56")
        let euro = dapiMoneyText(DapiMoney(amountMinor: 1245, currency: "eur"))
        XCTAssertTrue(euro.contains("EUR") && euro.contains("12.45") && !euro.contains("$"), euro)
        let yen = dapiMoneyText(DapiMoney(amountMinor: 1245, currency: "jpy"))
        XCTAssertTrue(yen.contains("JPY") && yen.contains("1,245"), yen)
        XCTAssertEqual(dapiMoneyText(DapiMoney(amountMinor: 5, currency: "??")), "5 (unknown currency)")
        XCTAssertNil(dapiMoneySum(DapiMoney(amountMinor: 1, currency: "usd"), DapiMoney(amountMinor: 1, currency: "eur")))
        XCTAssertEqual(dapiMoneySum(DapiMoney(amountMinor: 1, currency: "usd"), DapiMoney(amountMinor: 2, currency: "USD"))?.amountMinor, 3)
        XCTAssertNil(dapiMoneyTimes(DapiMoney(amountMinor: Int.max, currency: "usd"), 2))
    }

    // MARK: Slant side

    func testSlantPrintTotalOnlyForACurrentEstimateOfThisModelAtThisQuantity() {
        let id = UUID()
        func total(current: Bool = true, selected: UUID? = nil, remote: String? = "f1", fileID: String = "f1",
                   estimateQuantity: Int = 3, sheetQuantity: Int = 3, estimate: [String: Any]? = ["total": "18.60"]) -> Decimal? {
            dapiSlantPrintTotal(estimate: estimate, estimateIsCurrent: current, sheetModelID: id, selectedLocalID: selected ?? id,
                                selectedRemoteID: remote, fileID: fileID, estimateQuantity: estimateQuantity, sheetQuantity: sheetQuantity)
        }
        XCTAssertEqual(total(), Decimal(string: "18.60"))
        XCTAssertNil(total(current: false), "stale estimate")
        XCTAssertNil(total(selected: UUID()), "another model is selected")
        XCTAssertNil(total(remote: "f2"), "the estimate priced another upload")
        XCTAssertNil(total(remote: nil, fileID: ""), "not uploaded")
        XCTAssertNil(total(sheetQuantity: 4), "a different quantity")
        XCTAssertNil(total(estimate: nil))
        XCTAssertNil(total(estimate: ["total": NSNull()]))
    }

    private func order(_ id: String, status: String = "SHIPPED", country: String, delivery: String) -> Record {
        Record(values: ["publicId": id, "status": status, "createdAt": "2026-10-01T00:00:00Z", "deliveryCost": delivery,
                        "items": [["type": "PRINT", "publicFileServiceId": "f1", "quantity": 1]],
                        "customer": ["details": ["address": ["country": country]]]])
    }

    func testSlantDeliveryFromLoadedOrders() {
        let orders = [order("A", country: "GB", delivery: "12.00"), order("B", country: "GB", delivery: "16.00"),
                      order("C", status: "DRAFT", country: "GB", delivery: "40.00"), order("D", country: "US", delivery: "5.00")]
        let gb = dapiSlantDelivery(orders: orders, countryCode: "gb")
        XCTAssertEqual(gb?.orders, 2)
        XCTAssertEqual(gb?.average, 14)
        XCTAssertNil(dapiSlantDelivery(orders: orders, countryCode: "AU"))
        XCTAssertNil(dapiSlantDelivery(orders: orders, countryCode: ""))
    }

    // MARK: Comparison rows

    private let ukShipping = DapiShippingEstimate(countryCode: "GB", zoneName: "UK", tier: "small",
                                                  total: DapiMoney(amountMinor: 699, currency: "usd"))

    private func inputs(quantity: Int = 1, shipping: DapiShippingEstimate? = nil, stale: Bool = false, slant: Decimal? = nil,
                        delivery: SpendReportDeliveryCost? = nil, unit: DapiMoney = DapiMoney(amountMinor: 1245, currency: "usd")) -> DapiComparisonInputs {
        DapiComparisonInputs(unitPrice: unit, quantity: quantity, countryCode: "GB", shipping: shipping ?? ukShipping,
                             shippingIsStale: stale, slantPrintTotal: slant, slantDelivery: delivery)
    }

    private func row(_ rows: [DapiComparisonRow], _ id: String) -> DapiComparisonRow { rows.first { $0.id == id }! }

    func testComparisonWithCurrentSlantEstimateAndDeliveryHistory() {
        var delivery = SpendReportDeliveryCost(countryCode: "GB")
        delivery.orders = 2; delivery.total = 28; delivery.lowest = 12; delivery.highest = 16
        let rows = dapiComparisonRows(inputs(slant: Decimal(string: "9.50"), delivery: delivery))
        XCTAssertEqual(rows.map(\.id), ["print", "shipping", "total"])
        XCTAssertEqual(row(rows, "print").dapi.value, "$12.45")
        XCTAssertEqual(row(rows, "print").slant.value, "$9.50")
        XCTAssertEqual(row(rows, "shipping").dapi.value, "$6.99")
        XCTAssertEqual(row(rows, "shipping").dapi.note, "Zone UK · small parcel · excl. VAT")
        XCTAssertEqual(row(rows, "shipping").slant.value, "$14.00 average")
        XCTAssertTrue(row(rows, "shipping").slant.note?.contains("2 loaded orders, $12.00–$16.00") == true)
        XCTAssertEqual(row(rows, "total").dapi.value, "$19.44", "one unit: not an upper bound")
        XCTAssertEqual(row(rows, "total").slant.value, "About $23.50")
    }

    func testComparisonWithoutSlantEstimateOrDeliveryHistory() {
        let rows = dapiComparisonRows(inputs())
        XCTAssertEqual(row(rows, "print").slant.note, dapiNoSlantEstimateText)
        XCTAssertTrue(row(rows, "print").slant.isWarning)
        XCTAssertTrue(row(rows, "shipping").slant.note?.contains("none of your loaded orders went to") == true)
        XCTAssertEqual(row(rows, "total").slant.value, "—")
    }

    func testQuantityAboveOneIsAnUpperBound() {
        let rows = dapiComparisonRows(inputs(quantity: 10, slant: Decimal(string: "80")))
        XCTAssertEqual(rows.map(\.id), ["unit", "print", "shipping", "total"])
        XCTAssertEqual(row(rows, "print").label, "Print, 10 units")
        XCTAssertEqual(row(rows, "print").dapi.value, "Up to $124.50")
        XCTAssertEqual(row(rows, "print").dapi.note, dapiUpperBoundNote)
        XCTAssertEqual(row(rows, "unit").slant.value, "$8.00")
        XCTAssertEqual(row(rows, "total").dapi.value, "Up to $131.49")
    }

    func testStaleShippingIsNotShownOrAdded() {
        let rows = dapiComparisonRows(inputs(stale: true))
        XCTAssertEqual(row(rows, "shipping").dapi.value, "Out of date")
        XCTAssertTrue(row(rows, "shipping").dapi.isWarning)
        XCTAssertEqual(row(rows, "total").dapi.value, "—")
        XCTAssertTrue(dapiShippingIsStale(shippingFor: DapiShippingKey(countryCode: "GB", quantity: 1),
                                          destination: DapiShippingKey(countryCode: "DE", quantity: 1)))
        XCTAssertTrue(dapiShippingIsStale(shippingFor: DapiShippingKey(countryCode: "GB", quantity: 1),
                                          destination: DapiShippingKey(countryCode: "GB", quantity: 2)))
        XCTAssertTrue(dapiShippingIsStale(shippingFor: DapiShippingKey(countryCode: "GB", quantity: 1), destination: nil))
        XCTAssertFalse(dapiShippingIsStale(shippingFor: DapiShippingKey(countryCode: "GB", quantity: 1),
                                           destination: DapiShippingKey(countryCode: "GB", quantity: 1)))
        XCTAssertFalse(dapiShippingIsStale(shippingFor: nil, destination: DapiShippingKey(countryCode: "GB", quantity: 1)))
    }

    func testNonUSDIsShownWithItsCodeAndNeverAddedToUSD() {
        let rows = dapiComparisonRows(inputs(slant: 10, unit: DapiMoney(amountMinor: 1245, currency: "eur")))
        XCTAssertTrue(row(rows, "print").dapi.value.contains("EUR"))
        XCTAssertEqual(row(rows, "total").dapi.value, "—")
        XCTAssertTrue(row(rows, "total").dapi.note?.contains("different currencies") == true)
    }

    func testNotes() {
        let materials = [DapiSuggestedMaterial(slot: 1, materialName: "PLA Red", fileFilamentType: "PLA", match: "exact")]
        let uk = dapiComparisonNotes(countryCode: "GB", shipping: ukShipping, suggestedMaterials: materials, slantMaterialName: "PETG Black")
        XCTAssertTrue(uk.contains { $0.contains("PLA Red") && $0.contains("PETG Black") })
        XCTAssertTrue(uk.contains { $0.contains("import VAT or duty") && $0.contains("zone UK") })
        XCTAssertTrue(uk.contains { $0.contains("3–5 business days") && $0.contains("Oct 2026") })
        let us = dapiComparisonNotes(countryCode: "US", shipping: nil, suggestedMaterials: [], slantMaterialName: nil)
        XCTAssertFalse(us.contains { $0.contains("import VAT") })
        XCTAssertFalse(us.contains { $0.contains("suggested") })
    }

    func testAllowanceText() {
        XCTAssertEqual(dapiOnboardingAllowanceText(DapiOnboarding(status: "collecting", approvedFiles: 0, requiredFiles: 10,
                                                                  uploadsUsed: 7, uploadsLimit: 25)), "7 of 25 quotes used this round")
        XCTAssertNil(dapiOnboardingAllowanceText(DapiOnboarding(status: "approved", approvedFiles: 10, requiredFiles: 10,
                                                                uploadsUsed: 40, uploadsLimit: nil)))
        XCTAssertNil(dapiOnboardingAllowanceText(nil))
    }

    func testErrorMessages() {
        let now = Date(timeIntervalSince1970: 1_793_396_535) // Fri 30 Oct 2026 21:42:15 UTC
        let daily = dapiQuoteErrorMessage(.rateLimited(code: "daily_quote_limit_reached", retryAt: nil), step: .create, now: now,
                                          timeZone: TimeZone(identifier: "UTC")!)
        XCTAssertTrue(daily.contains("midnight UTC"), daily)
        XCTAssertEqual(dapiNextMidnightUTC(after: now), Date(timeIntervalSince1970: 1_793_404_800))
        let rate = dapiQuoteErrorMessage(.rateLimited(code: "rate_limited", retryAt: now.addingTimeInterval(30)), step: .poll, now: now)
        XCTAssertTrue(rate.contains("about 30 seconds"), rate)
        XCTAssertTrue(dapiQuoteErrorMessage(.outcomeUnknown("x"), step: .create, now: now).contains("looks for this quote first"))
        XCTAssertTrue(dapiQuoteErrorMessage(.outcomeUnknown("x"), step: .upload, now: now).contains("may have received the file"))
        XCTAssertTrue(dapiQuoteErrorMessage(.missingKey, step: .lookup, now: now).contains("Settings"))
    }

    // MARK: Runner

    func testCacheHitReadsOnceAndNeverUploads() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        harness.cache[fileHash] = "qte_cached"
        stub.scriptQuoteReads([.success(Self.quote("qte_cached", status: "ready", cents: 500, name: quoteName))])
        let runner = harness.makeRunner(stub)
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.calls, ["read"])
        XCTAssertEqual(harness.begun, harness.ended)
    }

    func testLookupFindsReadyQuoteWithoutUploading() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.listResult = .success([Self.quote("qte_r", status: "ready", cents: 500, name: quoteName)])
        let runner = harness.makeRunner(stub)
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.count("upload") + stub.count("create"), 0)
        XCTAssertEqual(harness.cache[fileHash], "qte_r", "remembered for the session")
    }

    func testLookupFindsProcessingQuoteAndOnlyPolls() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.listResult = .success([Self.quote("qte_p", status: "processing", name: quoteName)])
        stub.scriptQuoteReads([.success(Self.quote("qte_p", status: "processing", name: quoteName)),
                               .success(Self.quote("qte_p", status: "ready", cents: 700, name: quoteName))])
        let runner = harness.makeRunner(stub)
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.count("upload") + stub.count("create"), 0)
        XCTAssertEqual(stub.count("read"), 2)
        XCTAssertEqual(harness.sleeps, [5, 5])
    }

    func testNothingFoundUploadsOnceAndCreatesOnceWithNeutralNamesAndFreshKeys() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "ready", cents: 900, name: quoteName))])
        let runner = harness.makeRunner(stub)
        runner.destination = DapiShippingKey(countryCode: "GB", quantity: 2)
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.count("upload"), 1)
        XCTAssertEqual(stub.count("create"), 1)
        XCTAssertEqual(stub.uploadNames, [dapiUploadFileName(fileHash: fileHash, format: .stl)])
        XCTAssertEqual(stub.createNames, [quoteName])
        XCTAssertEqual(stub.uploadKeys, ["key-1"])
        XCTAssertEqual(harness.keyCounter, 2, "upload and create each get their own key")
        XCTAssertEqual(stub.shippingRequests, [DapiShippingKey(countryCode: "GB", quantity: 2)], "one shipping estimate once ready")
        XCTAssertEqual(runner.shippingFor, DapiShippingKey(countryCode: "GB", quantity: 2))
        XCTAssertEqual(harness.begun, harness.ended)
        for entry in harness.activity {
            for secret in ["Secret", "Customer", "qte_", "upl_", "$", String(fileHash.prefix(16))] {
                XCTAssertFalse(entry.detail.contains(secret), "\(entry.detail) leaks \(secret)")
                XCTAssertFalse(entry.title.contains(secret))
            }
        }
        XCTAssertEqual(harness.activity.map(\.detail), ["Ready"])
    }

    func testUnknownCreateOutcomeIsNeverSentAgain() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.createResult = .failure(.outcomeUnknown("timed out"))
        let runner = harness.makeRunner(stub)
        await run(runner)
        guard case .problem(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("looks for this quote first"))
        XCTAssertEqual(stub.count("create"), 1)
        XCTAssertEqual(stub.count("read"), 0)
        XCTAssertEqual(harness.activity.map(\.detail), ["Outcome unknown"])
        // The next press looks first, and finds the quote the unknown create made.
        stub.listResult = .success([Self.quote("qte_late", status: "ready", cents: 100, name: quoteName)])
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.count("upload"), 1)
        XCTAssertEqual(stub.count("create"), 1)
    }

    func testRateLimitIsNotRetried() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.createResult = .failure(.rateLimited(code: "daily_quote_limit_reached", retryAt: nil))
        let runner = harness.makeRunner(stub)
        await run(runner)
        guard case .problem(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("midnight UTC"))
        XCTAssertEqual(stub.count("create"), 1)
        XCTAssertTrue(harness.sleeps.isEmpty)

        let listStub = ScriptedDapi(), listHarness = DapiTestHarness()
        listStub.listResult = .failure(.rateLimited(code: "rate_limited", retryAt: nil))
        let listRunner = listHarness.makeRunner(listStub)
        await run(listRunner)
        XCTAssertEqual(listStub.calls, ["list"], "nothing is uploaded when the lookup couldn't run")
    }

    func testStopBetweenPollsStopsReading() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "processing", name: quoteName))])
        let runner = harness.makeRunner(stub)
        harness.onSleep = { number in if number == 2 { harness.runner?.stop() } }
        await run(runner)
        guard case .paused = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertEqual(stub.count("read"), 1)
        XCTAssertEqual(harness.activity.last?.detail, "Stopped")
        // Check Again: one read, then polling resumes.
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "ready", cents: 300, name: quoteName))])
        runner.checkAgain()
        await runner.runTask?.value
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.count("read"), 2)
        XCTAssertEqual(stub.count("create"), 1)
    }

    func testGivesUpAfterFifteenMinutes() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "processing", name: quoteName))])
        let runner = harness.makeRunner(stub)
        await run(runner)
        guard case .paused(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("Still processing on 3DAPI"))
        XCTAssertEqual(harness.sleeps.filter { $0 == 5 }.count, 24)
        XCTAssertTrue(harness.sleeps.allSatisfy { $0 == 5 || $0 == 15 })
        XCTAssertEqual(harness.sleeps.reduce(0, +), 900)
        XCTAssertEqual(harness.activity.last?.detail, "Still processing")
    }

    func testQuoteThatFailsShowsTheReason() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "failed", failure: "Not manifold"))])
        let runner = harness.makeRunner(stub)
        runner.destination = DapiShippingKey(countryCode: "GB", quantity: 1)
        await run(runner)
        XCTAssertEqual(runner.phase, .quoteFailed("Not manifold"))
        XCTAssertNil(harness.cache[fileHash])
        XCTAssertEqual(stub.count("shipping"), 0)
        XCTAssertEqual(harness.activity.map(\.detail), ["Failed"])
    }

    func testCountryChangeMarksShippingStaleAndUpdateShippingAsksOnce() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.listResult = .success([Self.quote("qte_r", status: "ready", cents: 500, name: quoteName)])
        let runner = harness.makeRunner(stub)
        let gb = DapiShippingKey(countryCode: "GB", quantity: 1), de = DapiShippingKey(countryCode: "DE", quantity: 1)
        runner.destination = gb
        await run(runner)
        XCTAssertEqual(stub.count("shipping"), 1)
        runner.destination = de
        XCTAssertTrue(dapiShippingIsStale(shippingFor: runner.shippingFor, destination: runner.destination))
        XCTAssertEqual(stub.count("shipping"), 1, "no request on a change by itself")
        runner.requestShipping(de)
        runner.requestShipping(de) // a double press while the first is in flight
        await runner.shippingTask?.value
        XCTAssertEqual(stub.count("shipping"), 2)
        XCTAssertEqual(runner.shippingFor, de)
        XCTAssertFalse(dapiShippingIsStale(shippingFor: runner.shippingFor, destination: runner.destination))
    }

    func testDoublePressStartsOneRun() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "ready", cents: 900))])
        let runner = harness.makeRunner(stub)
        runner.getQuote(fileURL: fileURL, format: .stl)
        runner.getQuote(fileURL: fileURL, format: .stl)
        await runner.runTask?.value
        XCTAssertEqual(stub.count("upload"), 1)
        XCTAssertEqual(stub.count("create"), 1)
    }

    func testClosingDuringUploadLetsItFinishAndSendsNothingMore() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        let runner = harness.makeRunner(stub)
        stub.duringUpload = { await MainActor.run { harness.runner?.close() } }
        await run(runner)
        XCTAssertEqual(stub.count("upload"), 1)
        XCTAssertEqual(stub.count("create"), 0, "no create after closing")
        guard case .problem(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("Stopped after the upload"))
        XCTAssertEqual(harness.begun, harness.ended)
        // A closed sheet starts nothing new.
        runner.getQuote(fileURL: fileURL, format: .stl)
        XCTAssertFalse(runner.isWorking)
        await runner.runTask?.value
        XCTAssertEqual(stub.count("upload"), 1)
    }

    func testFileProblemsSendNothing() async throws {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        let runner = harness.makeRunner(stub)
        let empty = tempDirectory.appendingPathComponent("empty.stl")
        try Data().write(to: empty)
        runner.getQuote(fileURL: empty, format: .stl)
        await runner.runTask?.value
        XCTAssertEqual(runner.phase, .problem("The model’s file is empty."))
        try FileManager.default.removeItem(at: fileURL)
        runner.getQuote(fileURL: fileURL, format: .stl)
        await runner.runTask?.value
        guard case .problem = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(stub.calls.isEmpty)
        XCTAssertTrue(harness.activity.isEmpty)
    }

    func testMissingKeySendsNothing() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        harness.hasKey = false
        let runner = harness.makeRunner(stub)
        await run(runner)
        guard case .problem(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("No 3DAPI key"))
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testKeyRemovedWhilePollingPausesWithoutRetrying() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "processing"))])
        let runner = harness.makeRunner(stub)
        harness.onSleep = { number in if number == 2 { harness.hasKey = false } }
        await run(runner)
        guard case .paused(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("No 3DAPI key"), message)
        XCTAssertEqual(stub.count("read"), 1)
    }
}
