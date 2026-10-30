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
    var uploadResult: Result<DapiUploadTarget, DapiError> = .success(DapiUploadTarget(
        uploadID: "upl_1", uploadURL: URL(string: "https://files.example.com/temp/a.stl?sig=1")!, headers: [:],
        contentType: "model/stl", sizeBytes: 1))
    var putResult: Result<Void, DapiError> = .success(())
    var createResult: Result<DapiQuote, DapiError> = .success(DapiQuoteTests.quote("qte_new", status: "processing"))
    var shippingResult: Result<DapiShippingEstimate, DapiError> = .success(
        DapiShippingEstimate(countryCode: "GB", zoneName: "UK", tier: "small", total: DapiMoney(amountMinor: 699, currency: "usd")))
    /// Called from inside `createUpload` (the POST), before it returns (to press Stop or close mid-request).
    var duringUpload: (@Sendable () async -> Void)?
    /// Called from inside `sendUploadBytes` (the PUT); it may throw `CancellationError` to model a cancelled transfer.
    var duringPut: (@Sendable () async throws -> Void)?
    /// Called from inside `createQuote`, before it returns.
    var duringCreate: (@Sendable () async -> Void)?
    /// Whether the task was cancelled when each `createUpload` and `createQuote` returned (writes are never cancelled).
    private var _writeCancelled: [Bool] = []
    var writeCancelled: [Bool] { lock.withLock { _writeCancelled } }
    private var _uploadSizes: [Int64] = []
    var uploadSizes: [Int64] { lock.withLock { _uploadSizes } }
    private var _uploadTypes: [String] = []
    var uploadTypes: [String] { lock.withLock { _uploadTypes } }

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
    func createUpload(fileName: String, contentType: String, sizeBytes: Int64, idempotencyKey: String) async throws -> DapiUploadTarget {
        record("upload")
        lock.withLock {
            _uploadKeys.append(idempotencyKey); _uploadNames.append(fileName)
            _uploadSizes.append(sizeBytes); _uploadTypes.append(contentType)
        }
        if let duringUpload { await duringUpload() }
        let cancelled = Task.isCancelled
        lock.withLock { _writeCancelled.append(cancelled) }
        return try uploadResult.get()
    }
    func sendUploadBytes(_ target: DapiUploadTarget, fileURL: URL) async throws {
        record("put")
        if let duringPut { try await duringPut() }
        try putResult.get()
    }
    func createQuote(uploadID: String, name: String, idempotencyKey: String) async throws -> DapiQuote {
        record("create")
        lock.withLock { _createNames.append(name) }
        if let duringCreate { await duringCreate() }
        let cancelled = Task.isCancelled
        lock.withLock { _writeCancelled.append(cancelled) }
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
    /// What `client()` throws when `hasKey` is false.
    var keyError: DapiError = .missingKey
    var inFlight: Set<String> = []
    var unknown: Set<String> = []
    /// What the allowance read returns (nil: the read failed), and how often it ran.
    var allowance: DapiOnboarding?
    var allowanceReads = 0
    /// Called before each sleep returns, with the sleep's number (1-based).
    var onSleep: ((Int) -> Void)?
    weak var runner: DapiQuoteRunner?

    func environment(_ stub: ScriptedDapi) -> DapiQuoteEnvironment {
        DapiQuoteEnvironment(
            client: { [unowned self] in
                guard self.hasKey else { throw self.keyError }
                return stub
            },
            readyQuoteID: { [unowned self] in self.cache[$0] },
            rememberReadyQuote: { [unowned self] id, hash in self.cache[hash] = id; self.unknown.remove(hash) },
            beginRequest: { [unowned self] in self.begun += 1 },
            endRequest: { [unowned self] in self.ended += 1 },
            quoteWriteInFlight: { [unowned self] in self.inFlight.contains($0) },
            quoteWriteOutcomeUnknown: { [unowned self] in self.unknown.contains($0) },
            beginQuoteWrite: { [unowned self] in self.inFlight.insert($0) },
            endQuoteWrite: { [unowned self] in self.inFlight.remove($0) },
            noteQuoteWriteUnknown: { [unowned self] in self.unknown.insert($0) },
            readAllowance: { [unowned self] in self.allowanceReads += 1; return self.allowance },
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
                                  failure: String? = nil, materials: [DapiSuggestedMaterial] = [], approval: String? = nil) -> DapiQuote {
        DapiQuote(id: id, name: name, status: status, price: cents.map { DapiMoney(amountMinor: $0, currency: "usd") },
                  failureReason: failure, suggestedMaterials: materials, createdAt: createdAt, approvalStatus: approval)
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

    func testContentTypesComeFromTheClientsExtensionTable() {
        // The runner names the upload `plinth-….<format.rawValue>` and declares the client's type for that extension.
        XCTAssertEqual(dapiQuoteFileContentType(forExtension: ModelFileFormat.stl.rawValue), "model/stl")
        XCTAssertEqual(dapiQuoteFileContentType(forExtension: ModelFileFormat.obj.rawValue), "model/obj")
        XCTAssertEqual(dapiQuoteFileContentType(forExtension: ModelFileFormat.threeMF.rawValue), "model/3mf")
        XCTAssertNil(dapiQuoteFileContentType(forExtension: "step"), "Plinth quotes STL, OBJ and 3MF only")
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
        XCTAssertEqual(dapiQuoteFileProblem(size: 10, format: nil), "Plinth can quote STL, OBJ and 3MF models.")
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

    func testPickSkipsRejectedAndPricelessQuotes() {
        let rejected = Self.quote("qte_rej", status: "ready", cents: 100, name: "n", createdAt: Date(timeIntervalSince1970: 3_000), approval: "rejected")
        let priceless = Self.quote("qte_free", status: "ready", name: "n", createdAt: Date(timeIntervalSince1970: 2_000))
        let older = Self.quote("qte_ok", status: "ready", cents: 120, name: "n", createdAt: Date(timeIntervalSince1970: 1_000), approval: "approved")
        XCTAssertEqual(dapiPickExistingQuote([rejected, priceless, older], name: "n"), .ready(older))
        XCTAssertEqual(dapiPickExistingQuote([rejected, priceless], name: "n"), .none)
        let rejectedProcessing = Self.quote("qte_rp", status: "processing", name: "n", approval: "rejected")
        XCTAssertEqual(dapiPickExistingQuote([rejectedProcessing], name: "n"), .none)
        XCTAssertFalse(rejected.isUsable)
        XCTAssertFalse(priceless.isUsable)
        XCTAssertTrue(older.isUsable)
        XCTAssertTrue(Self.quote("q", status: "ready", cents: 1, approval: "in_review").isUsable)
        XCTAssertNotNil(dapiUnusableQuoteMessage(rejected))
        XCTAssertNotNil(dapiUnusableQuoteMessage(priceless))
        XCTAssertNil(dapiUnusableQuoteMessage(older))
    }

    // MARK: Earlier writes

    func testNewQuoteGate() {
        XCTAssertEqual(dapiNewQuoteGate(writeInFlight: false, outcomeUnknown: false, confirmedAnother: false), .proceed)
        XCTAssertEqual(dapiNewQuoteGate(writeInFlight: false, outcomeUnknown: true, confirmedAnother: false), .confirm)
        XCTAssertEqual(dapiNewQuoteGate(writeInFlight: false, outcomeUnknown: true, confirmedAnother: true), .proceed)
        XCTAssertEqual(dapiNewQuoteGate(writeInFlight: true, outcomeUnknown: true, confirmedAnother: true), .wait,
                       "a write in flight blocks even after the seller confirmed")
        XCTAssertEqual(dapiNewQuoteGate(writeInFlight: true, outcomeUnknown: false, confirmedAnother: false), .wait)
    }

    func testAllowanceProblem() {
        func onboarding(_ status: String, used: Int, limit: Int?) -> DapiOnboarding {
            DapiOnboarding(status: status, approvedFiles: 0, requiredFiles: 10, uploadsUsed: used, uploadsLimit: limit)
        }
        XCTAssertNil(dapiAllowanceProblem(nil), "a failed read never blocks")
        XCTAssertNil(dapiAllowanceProblem(onboarding("collecting", used: 24, limit: 25)))
        XCTAssertNil(dapiAllowanceProblem(onboarding("approved", used: 400, limit: nil)))
        XCTAssertTrue(dapiAllowanceProblem(onboarding("in_review", used: 3, limit: 25))?.contains("reviews") == true)
        XCTAssertTrue(dapiAllowanceProblem(onboarding("collecting", used: 25, limit: 25))?.contains("all 25 quotes") == true)
        XCTAssertNotNil(dapiAllowanceProblem(onboarding("changes_requested", used: 30, limit: 25)))
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

    private func order(_ id: String, status: String = "SHIPPED", country: String, delivery: String, platform: String? = nil) -> Record {
        var customer: [String: Any] = ["details": ["address": ["country": country]]]
        if let platform { customer["platformId"] = platform }
        return Record(values: ["publicId": id, "status": status, "createdAt": "2026-10-01T00:00:00Z", "deliveryCost": delivery,
                               "items": [["type": "PRINT", "publicFileServiceId": "f1", "quantity": 1]], "customer": customer])
    }

    func testSlantDeliveryFromLoadedOrders() {
        let orders = [order("A", country: "GB", delivery: "12.00"), order("B", country: "GB", delivery: "16.00"),
                      order("C", status: "DRAFT", country: "GB", delivery: "40.00"), order("D", country: "US", delivery: "5.00")]
        let gb = dapiSlantDelivery(orders: orders, platformID: "", countryCode: "gb")
        XCTAssertEqual(gb?.orders, 2)
        XCTAssertEqual(gb?.average, 14)
        XCTAssertNil(dapiSlantDelivery(orders: orders, platformID: "", countryCode: "AU"))
        XCTAssertNil(dapiSlantDelivery(orders: orders, platformID: "", countryCode: ""))
    }

    func testSlantDeliveryCountsOnlyTheDefaultPlatformsOrdersLikeTheSpendingReport() {
        let orders = [order("A", country: "GB", delivery: "12.00", platform: "plat_mine"),
                      order("B", country: "GB", delivery: "40.00", platform: "plat_other"),
                      order("C", country: "GB", delivery: "16.00")] // names no platform: kept
        let gb = dapiSlantDelivery(orders: orders, platformID: "plat_mine", countryCode: "GB")
        XCTAssertEqual(gb?.orders, 2)
        XCTAssertEqual(gb?.average, 14)
        XCTAssertEqual(gb?.highest, 16)
        // The same figure the Spending Report sums for that platform.
        let report = spendReport(orders: ordersShownOnPlatform(orders, platformID: "plat_mine"))
        XCTAssertEqual(report.deliveryCosts.first { $0.countryCode == "GB" }, gb)
        XCTAssertEqual(dapiSlantDelivery(orders: orders, platformID: "", countryCode: "GB")?.orders, 3, "no default platform: all")
        XCTAssertNil(dapiSlantDelivery(orders: [orders[1]], platformID: "plat_mine", countryCode: "GB"))
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
        XCTAssertEqual(row(rows, "shipping").dapi.note, "Small parcel", "the parcel size only: no zone, no VAT")
        XCTAssertEqual(row(rows, "shipping").label, "Shipping (\(dapiCountryName("GB")))")
        XCTAssertEqual(row(rows, "shipping").slant.value, "$14.00")
        XCTAssertEqual(row(rows, "shipping").slant.note,
                       "Average of 2 past orders to \(dapiCountryPhrase("GB")) ($12.00–$16.00), whatever they held")
        XCTAssertEqual(row(rows, "total").dapi.value, "$19.44", "one unit: not an upper bound")
        XCTAssertNil(row(rows, "total").dapi.note)
        XCTAssertEqual(row(rows, "total").slant.value, "About $23.50")
        for cell in rows.flatMap({ [$0.dapi, $0.slant] }) {
            XCTAssertFalse((cell.value + (cell.note ?? "")).contains("VAT"), "VAT is one note under the table")
            XCTAssertFalse((cell.value + (cell.note ?? "")).contains("Zone"))
        }
        var one = SpendReportDeliveryCost(countryCode: "GB")
        one.orders = 1; one.total = 12; one.lowest = 12; one.highest = 12
        XCTAssertEqual(dapiSlantDeliveryNote(one, countryCode: "DE"), "From 1 past order to \(dapiCountryPhrase("DE")), whatever it held")
        XCTAssertEqual(dapiShippingNote(DapiShippingEstimate(countryCode: "GB", zoneName: nil, tier: nil,
                                                             total: DapiMoney(amountMinor: 1, currency: "usd"))), "Flat rate")
        XCTAssertEqual(dapiShippingNote(DapiShippingEstimate(countryCode: "GB", zoneName: "EU-Core", tier: "LARGE",
                                                             total: DapiMoney(amountMinor: 1, currency: "usd"))), "Large parcel")
    }

    func testSlantTotalOnlyForOneUnit() {
        var delivery = SpendReportDeliveryCost(countryCode: "GB")
        delivery.orders = 2; delivery.total = 28; delivery.lowest = 12; delivery.highest = 16
        let one = dapiComparisonRows(inputs(quantity: 1, slant: 9, delivery: delivery))
        XCTAssertEqual(row(one, "total").slant.value, "About $23.00")
        let several = dapiComparisonRows(inputs(quantity: 3, slant: 27, delivery: delivery))
        XCTAssertEqual(row(several, "total").slant.value, "—")
        XCTAssertEqual(row(several, "total").slant.note, dapiSlantTotalOtherParcelsText)
        XCTAssertEqual(row(several, "print").slant.value, "$27.00", "the print estimate itself is still shown")
    }

    func testComparisonWithoutSlantEstimateOrDeliveryHistory() {
        let rows = dapiComparisonRows(inputs())
        XCTAssertEqual(row(rows, "print").slant.note, dapiNoSlantEstimateText)
        XCTAssertTrue(row(rows, "print").slant.isWarning)
        XCTAssertEqual(row(rows, "shipping").slant.note, "None of your loaded orders went there. Slant prices delivery only in a draft.")
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
        // Explained once by the sheet's orange line with Update Shipping; the cells only say "—".
        XCTAssertEqual(row(rows, "shipping").dapi, DapiComparisonCell(value: "—"))
        XCTAssertEqual(row(rows, "total").dapi, DapiComparisonCell(value: "—"))
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
        XCTAssertTrue(uk.contains(dapiVATNote))
        XCTAssertTrue(uk.contains("Slant ships from the US, so a parcel to \(dapiCountryPhrase("GB")) goes through customs: it can take longer, and the buyer may pay duty or courier fees unless the marketplace collected VAT at checkout. 3DAPI prints in or near the buyer’s region where it can."))
        XCTAssertFalse(uk.contains { $0.contains("zone") || $0.contains("Zone") })
        XCTAssertTrue(uk.contains { $0.contains("1–3 business days locally or 5–10 internationally") && $0.contains("Oct 2026") })
        XCTAssertEqual(uk.last, dapiComparisonOnlyNote)
        let us = dapiComparisonNotes(countryCode: "US", shipping: nil, suggestedMaterials: [], slantMaterialName: nil)
        XCTAssertFalse(us.contains { $0.contains("customs") })
        XCTAssertFalse(us.contains { $0.contains("suggested") })
        XCTAssertTrue(us.contains(dapiVATNote))
    }

    func testCountryPhraseAddsTheOnlyInEnglish() {
        let english = Locale(identifier: "en_GB")
        XCTAssertEqual(dapiCountryPhrase("GB", locale: english), "the United Kingdom")
        XCTAssertEqual(dapiCountryPhrase("nl", locale: english), "the Netherlands")
        XCTAssertEqual(dapiCountryPhrase("DE", locale: english), "Germany")
        XCTAssertEqual(dapiCountryPhrase("GB", locale: Locale(identifier: "de_DE")), dapiCountryName("GB", locale: Locale(identifier: "de_DE")))
    }

    func testAllowanceText() {
        XCTAssertEqual(dapiOnboardingAllowanceText(DapiOnboarding(status: "collecting", approvedFiles: 0, requiredFiles: 10,
                                                                  uploadsUsed: 7, uploadsLimit: 25)),
                       "7 of 25 quotes used (3DAPI’s limit until it approves your account).")
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
        XCTAssertTrue(dapiQuoteErrorMessage(.outcomeUnknown("x"), step: .upload, now: now).contains("may have received the upload request"))
        XCTAssertTrue(dapiQuoteErrorMessage(.outcomeUnknown("x"), step: .transfer, now: now).contains("may not have reached 3DAPI in full"))
        XCTAssertTrue(dapiQuoteErrorMessage(.missingKey, step: .lookup, now: now).contains("Settings"))
        // No "3DAPI refused the file." before a message that already starts with 3DAPI.
        let expired = dapiQuoteErrorMessage(.refused(status: 422, code: "upload_expired", message: nil), step: .create, now: now)
        XCTAssertEqual(expired, "3DAPI refused the quote. The upload expired before the quote was requested (3DAPI keeps uploads for 24 hours). Press Get Quote to upload it again.")
        let missing = dapiQuoteErrorMessage(.refused(status: 422, code: "unknown_upload", message: nil), step: .create, now: now)
        XCTAssertEqual(missing, "3DAPI couldn’t find the uploaded model. Press Get Quote to upload it again.")
        let type = dapiQuoteErrorMessage(.refused(status: 422, code: "file_type_not_allowed", message: nil), step: .upload, now: now)
        XCTAssertEqual(type, "3DAPI didn’t accept this file type. Plinth can quote STL, OBJ and 3MF models.")
        let tooLarge = dapiQuoteErrorMessage(.refused(status: 413, code: "file_too_large", message: nil), step: .upload, now: now)
        XCTAssertEqual(tooLarge, "3DAPI refused the file. This model is larger than 3DAPI’s 250 MB limit for quotes.")
        let storage = dapiQuoteErrorMessage(.refused(status: 403, code: nil, message: nil), step: .transfer, now: now)
        XCTAssertEqual(storage, "3DAPI refused the file. Press Get Quote to upload it again.")
        for code in ["unknown_upload", "upload_missing", "upload_purpose_mismatch", "upload_expired", "upload_already_used"] {
            let text = DapiError.refused(status: 422, code: code, message: nil).userMessage
            XCTAssertTrue(text.hasSuffix("Press Get Quote to upload it again."), text)
            XCTAssertFalse(text.contains("afresh"), text)
        }
        XCTAssertFalse(dapiStoppedPausedText.contains("carries on"))
        XCTAssertTrue(dapiGaveUpPausedText.contains("15 minutes"))
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
        XCTAssertEqual(stub.calls, ["list", "upload", "put", "create", "read", "shipping"])
        XCTAssertEqual(harness.allowanceReads, 1, "the allowance is read once, before the upload")
        XCTAssertEqual(stub.uploadSizes, [Int64(fileBytes.count)])
        XCTAssertEqual(stub.uploadTypes, ["model/stl"])
        XCTAssertEqual(stub.writeCancelled, [false, false])
        XCTAssertTrue(harness.inFlight.isEmpty, "the in-flight record ends with the create")
        XCTAssertTrue(harness.unknown.isEmpty)
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
        XCTAssertEqual(harness.unknown, [fileHash], "remembered for the session")
        XCTAssertTrue(harness.inFlight.isEmpty)
        // The next press looks first, and finds the quote the unknown create made, which settles the record.
        stub.listResult = .success([Self.quote("qte_late", status: "ready", cents: 100, name: quoteName)])
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.count("upload"), 1)
        XCTAssertEqual(stub.count("create"), 1)
        XCTAssertTrue(harness.unknown.isEmpty)
    }

    func testAfterAnUnknownOutcomeANotFoundLookupAsksBeforeCreatingAnother() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        harness.unknown = [fileHash]
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "ready", cents: 900, name: quoteName))])
        let runner = harness.makeRunner(stub)
        await run(runner)
        XCTAssertEqual(runner.phase, .confirmAnother)
        XCTAssertEqual(stub.calls, ["list"], "the lookup runs; nothing is uploaded before the seller answers")
        XCTAssertEqual(harness.allowanceReads, 0)
        // Don't Quote sends nothing.
        runner.declineAnother()
        XCTAssertEqual(runner.phase, .idle)
        XCTAssertEqual(stub.calls, ["list"])
        // A plain Get Quote asks again; Get Another Quote looks once more, then sends one upload and one create.
        await run(runner)
        XCTAssertEqual(runner.phase, .confirmAnother)
        runner.getQuote(fileURL: fileURL, format: .stl, confirmedAnother: true)
        await runner.runTask?.value
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.calls, ["list", "list", "list", "upload", "put", "create", "read"])
        XCTAssertTrue(harness.unknown.isEmpty, "a confirmed ready quote clears the record")
    }

    func testUnknownUploadRequestIsRecordedAndNothingMoreIsSent() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.uploadResult = .failure(.outcomeUnknown("timed out"))
        let runner = harness.makeRunner(stub)
        await run(runner)
        guard case .problem = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertEqual(stub.calls, ["list", "upload"])
        XCTAssertEqual(harness.unknown, [fileHash])
        // A storage-side failure (the PUT) uses no quote, so it isn't recorded.
        let putStub = ScriptedDapi(), putHarness = DapiTestHarness()
        putStub.putResult = .failure(.outcomeUnknown("timed out"))
        let putRunner = putHarness.makeRunner(putStub)
        await run(putRunner)
        XCTAssertEqual(putStub.calls, ["list", "upload", "put"])
        XCTAssertTrue(putHarness.unknown.isEmpty)
        XCTAssertEqual(putHarness.activity.map(\.detail), ["Outcome unknown"])
    }

    func testReopenedSheetWaitsWhileAnEarlierCreateIsInFlight() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "processing", name: quoteName))])
        let first = harness.makeRunner(stub)
        let second = DapiQuoteRunner(environment: harness.environment(stub))
        let fileURL = self.fileURL!
        // The sheet closes mid-create, then reopens (a new runner) and Get Quote is pressed while the create waits.
        stub.duringCreate = {
            await MainActor.run {
                first.close()
                second.getQuote(fileURL: fileURL, format: .stl)
            }
            await second.runTask?.value
        }
        await run(first)
        XCTAssertEqual(second.phase, .problem(dapiWriteInFlightText))
        XCTAssertEqual(stub.count("upload"), 1)
        XCTAssertEqual(stub.count("create"), 1)
        XCTAssertEqual(stub.writeCancelled, [false, false], "closing never cancels a write")
        guard case .paused = first.phase else { return XCTFail("\(first.phase)") }
        XCTAssertTrue(harness.inFlight.isEmpty)
    }

    func testStopAfterTheUploadRequestSendsNoBytes() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        let runner = harness.makeRunner(stub)
        stub.duringUpload = { await MainActor.run { harness.runner?.stop() } }
        await run(runner)
        XCTAssertEqual(stub.calls, ["list", "upload"], "no PUT and no create")
        XCTAssertEqual(stub.writeCancelled, [false], "the POST itself is never cancelled")
        XCTAssertEqual(runner.phase, .problem(dapiStoppedBeforeBytesText))
        XCTAssertEqual(harness.begun, harness.ended)
        XCTAssertTrue(harness.inFlight.isEmpty)
    }

    func testStopDuringTheBytesCancelsThem() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        let runner = harness.makeRunner(stub)
        stub.duringPut = {
            await MainActor.run { harness.runner?.stop() }
            // A transfer that only ends when cancelled.
            try await Task.sleep(nanoseconds: 30_000_000_000)
        }
        let started = Date()
        await run(runner)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10, "Stop ended the transfer at once")
        XCTAssertEqual(stub.calls, ["list", "upload", "put"], "no create")
        XCTAssertEqual(runner.phase, .problem(dapiStoppedDuringBytesText))
        XCTAssertEqual(harness.activity.last?.detail, "Stopped")
        XCTAssertEqual(harness.begun, harness.ended)
        XCTAssertTrue(harness.unknown.isEmpty)
    }

    func testAllowanceInReviewOrUsedUpUploadsNothing() async {
        for onboarding in [DapiOnboarding(status: "in_review", approvedFiles: 0, requiredFiles: 10, uploadsUsed: 3, uploadsLimit: 25),
                           DapiOnboarding(status: "collecting", approvedFiles: 0, requiredFiles: 10, uploadsUsed: 25, uploadsLimit: 25)] {
            let stub = ScriptedDapi(), harness = DapiTestHarness()
            harness.allowance = onboarding
            let runner = harness.makeRunner(stub)
            await run(runner)
            XCTAssertEqual(stub.calls, ["list"], onboarding.status)
            XCTAssertEqual(runner.phase, .problem(dapiAllowanceProblem(onboarding)!))
            XCTAssertEqual(harness.allowanceReads, 1)
        }
        // A failed read (nil) doesn't block.
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        harness.allowance = nil
        stub.scriptQuoteReads([.success(Self.quote("qte_new", status: "ready", cents: 900, name: quoteName))])
        let runner = harness.makeRunner(stub)
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(stub.count("upload"), 1)
    }

    func testRejectedOrPricelessQuotesAreNeverCachedAndGetQuoteIsOfferedAgain() async {
        // A cached ID that has since been rejected falls through to the lookup.
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        harness.cache[fileHash] = "qte_cached"
        stub.scriptQuoteReads([.success(Self.quote("qte_cached", status: "ready", cents: 500, name: quoteName, approval: "rejected"))])
        stub.listResult = .success([Self.quote("qte_cached", status: "ready", cents: 500, name: quoteName, approval: "rejected"),
                                    Self.quote("qte_ok", status: "ready", cents: 600, name: quoteName)])
        let runner = harness.makeRunner(stub)
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
        XCTAssertEqual(runner.quote?.id, "qte_ok")
        XCTAssertEqual(stub.calls, ["read", "list"])
        XCTAssertEqual(harness.cache[fileHash], "qte_ok")

        // A create that comes back ready without a price is shown as a problem, not remembered, and Get Quote works.
        let priceless = ScriptedDapi(), pricelessHarness = DapiTestHarness()
        priceless.createResult = .success(Self.quote("qte_free", status: "ready", name: quoteName))
        let pricelessRunner = pricelessHarness.makeRunner(priceless)
        await run(pricelessRunner)
        guard case .problem(let message) = pricelessRunner.phase else { return XCTFail("\(pricelessRunner.phase)") }
        XCTAssertTrue(message.contains("Press Get Quote"), message)
        XCTAssertNil(pricelessHarness.cache[fileHash])
        XCTAssertEqual(pricelessHarness.activity.last?.detail, "Not usable")
        XCTAssertEqual(priceless.count("shipping"), 0)
        priceless.createResult = .success(Self.quote("qte_paid", status: "ready", cents: 700, name: quoteName))
        await run(pricelessRunner)
        XCTAssertEqual(pricelessRunner.phase, .ready)

        // Polling that ends on a rejected quote does the same.
        let polled = ScriptedDapi(), polledHarness = DapiTestHarness()
        polled.scriptQuoteReads([.success(Self.quote("qte_new", status: "ready", cents: 500, name: quoteName, approval: "rejected"))])
        let polledRunner = polledHarness.makeRunner(polled)
        await run(polledRunner)
        guard case .problem = polledRunner.phase else { return XCTFail("\(polledRunner.phase)") }
        XCTAssertNil(polledHarness.cache[fileHash])
    }

    func testKeychainErrorIsReportedAsItIs() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        harness.hasKey = false
        harness.keyError = .notSent("Plinth couldn’t read the 3DAPI key from the Keychain: locked")
        let runner = harness.makeRunner(stub)
        await run(runner)
        guard case .problem(let message) = runner.phase else { return XCTFail("\(runner.phase)") }
        XCTAssertTrue(message.contains("Keychain"), message)
        XCTAssertFalse(message.contains("No 3DAPI key"), message)
        XCTAssertTrue(stub.calls.isEmpty)
    }

    func testReopenAcceptsPressesAgain() async {
        let stub = ScriptedDapi(), harness = DapiTestHarness()
        stub.listResult = .success([Self.quote("qte_r", status: "ready", cents: 500, name: quoteName)])
        let runner = harness.makeRunner(stub)
        runner.close()
        runner.getQuote(fileURL: fileURL, format: .stl)
        XCTAssertFalse(runner.isWorking, "a closed runner starts nothing")
        runner.reopen()
        await run(runner)
        XCTAssertEqual(runner.phase, .ready)
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
        XCTAssertEqual(message, dapiGaveUpPausedText)
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
        XCTAssertEqual(stub.count("put"), 0, "no bytes after closing")
        XCTAssertEqual(stub.count("create"), 0, "no create after closing")
        XCTAssertEqual(runner.phase, .problem(dapiStoppedBeforeBytesText))
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
