import XCTest
@testable import Plinth

/// Holds a stubbed request until the test opens it, so a test can act while a request is in flight.
private actor DapiTestGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var arrived = 0

    func wait() async {
        arrived += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A `DapiQuoting` that answers only the account and onboarding reads. Nothing reaches the network.
private final class StubDapi: DapiQuoting, @unchecked Sendable {
    let accountResult: Result<DapiAccount, DapiError>
    let onboardingResult: Result<DapiOnboarding, DapiError>
    let gate: DapiTestGate?
    /// Thrown instead of the results when set (a cancellation, say).
    var accountThrows: Error?
    var onboardingThrows: Error?

    init(account: Result<DapiAccount, DapiError>,
         onboarding: Result<DapiOnboarding, DapiError> = .failure(.readFailed("no")), gate: DapiTestGate? = nil) {
        accountResult = account
        onboardingResult = onboarding
        self.gate = gate
    }

    func account() async throws -> DapiAccount {
        if let gate { await gate.wait() }
        if let accountThrows { throw accountThrows }
        return try accountResult.get()
    }
    func onboarding() async throws -> DapiOnboarding {
        if let onboardingThrows { throw onboardingThrows }
        return try onboardingResult.get()
    }
    func quotes(named name: String, maxPages: Int) async throws -> [DapiQuote] { throw DapiError.notSent("stub") }
    func createUpload(fileName: String, contentType: String, sizeBytes: Int64, idempotencyKey: String) async throws -> DapiUploadTarget {
        throw DapiError.notSent("stub")
    }
    func sendUploadBytes(_ target: DapiUploadTarget, fileURL: URL) async throws { throw DapiError.notSent("stub") }
    func createQuote(uploadID: String, name: String, idempotencyKey: String) async throws -> DapiQuote { throw DapiError.notSent("stub") }
    func quote(id: String) async throws -> DapiQuote { throw DapiError.notSent("stub") }
    func shippingEstimate(quoteID: String, quantity: Int, countryCode: String) async throws -> DapiShippingEstimate {
        throw DapiError.notSent("stub")
    }
}

/// Which stub each key gets, and the keys `makeClient` was given.
private final class StubDapiRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var stubs: [String: StubDapi] = [:]
    private var made: [String] = []

    func set(_ stub: StubDapi, for key: String) { lock.withLock { stubs[key] = stub } }
    func make(_ key: String) -> any DapiQuoting {
        lock.withLock {
            made.append(key)
            return stubs[key] ?? StubDapi(account: .failure(.refused(status: 401, code: "invalid_api_key", message: nil)))
        }
    }
    var keysMade: [String] { lock.withLock { made } }
}

/// The key in memory instead of the Keychain.
private final class MemoryDapiKeyStore: DapiKeyStore {
    var value: String?
    var loadError: Error?
    var saveError: Error?
    var loads = 0

    func load() throws -> String? {
        loads += 1
        if let loadError { throw loadError }
        return value
    }
    func save(_ value: String) throws {
        if let saveError { throw saveError }
        self.value = value
    }
    func delete() throws { value = nil }
}

private let integratorKey = "sk_" + String(repeating: "a1", count: 32)
private let otherIntegratorKey = "sk_" + String(repeating: "b2", count: 32)
private let designerKey = "dk_" + String(repeating: "c3", count: 16)
private let allScopes = ["quotes:read", "quotes:write", "orders:read"]
private let pendingOnboarding = DapiOnboarding(status: "collecting", approvedFiles: 3, requiredFiles: 10, uploadsUsed: 7, uploadsLimit: 25)

@MainActor
final class DapiConnectionTests: XCTestCase {
    private var suite = ""
    private var defaults: UserDefaults!
    private var keys: MemoryDapiKeyStore!
    private var registry: StubDapiRegistry!

    override func setUp() async throws {
        suite = testDefaultsSuiteName("DapiConnectionTests")
        defaults = UserDefaults(suiteName: suite)
        keys = MemoryDapiKeyStore()
        registry = StubDapiRegistry()
    }

    override func tearDown() async throws {
        removeTestDefaultsSuite(defaults, named: suite)
    }

    private func makeConnection() -> DapiConnection {
        let registry = registry!
        return DapiConnection(defaults: defaults, keychain: keys, makeClient: { registry.make($0) })
    }

    private func integrator(_ scopes: [String] = allScopes, approval: String? = "pending") -> DapiAccount {
        DapiAccount(kind: "integrator", approval: approval, effectiveScopes: scopes)
    }

    private func waitUntilArrived(_ gate: DapiTestGate) async {
        for _ in 0..<1_000 where await gate.arrived == 0 { await Task.yield() }
    }

    // MARK: Pure helpers

    func testKeyProblemTable() {
        let cases: [(String, Bool)] = [
            ("", true), ("   \n", true),
            (integratorKey, false), (integratorKey + "\n", false), ("  \(integratorKey)  ", false),
            ("sk_abc def" + String(repeating: "0", count: 30), true),
            ("sk_abc\ndef" + String(repeating: "0", count: 30), true),
            ("sk_abc\tdef" + String(repeating: "0", count: 30), true),
            ("sk_é" + String(repeating: "0", count: 30), true),
            ("sk_123", true), (String(repeating: "x", count: dapiMinKeyLength - 1), true),
            (String(repeating: "x", count: dapiMinKeyLength), false),
            (String(repeating: "x", count: dapiMaxKeyLength), false),
            (String(repeating: "x", count: dapiMaxKeyLength + 1), true),
            (designerKey, false), // no sk_ prefix needed: the seller key format is undocumented
        ]
        for (key, refused) in cases {
            XCTAssertEqual(dapiKeyProblem(key) != nil, refused, key.debugDescription)
        }
        XCTAssertEqual(dapiKeyProblem(""), "Enter the 3DAPI API key.")
    }

    func testAccountProblem() throws {
        XCTAssertNil(dapiAccountProblem(integrator()))
        XCTAssertNil(dapiAccountProblem(integrator(["orders:read", "QUOTES:WRITE", "quotes:read", "orders:write"])))
        let designer = try XCTUnwrap(dapiAccountProblem(DapiAccount(kind: "designer", approval: nil, effectiveScopes: allScopes)))
        XCTAssertEqual(designer, "This key is from a 3DAPI seller account, which can’t get quotes. Make a 3DAPI integrator account (with a different email from your seller account) and use its key.")
        // One message everywhere: the client's refusals for a seller key say the same.
        XCTAssertEqual(DapiError.refused(status: 403, code: "actor_not_allowed", message: nil).userMessage, designer)
        XCTAssertEqual(DapiError.refused(status: 403, code: "purpose_not_allowed", message: nil).userMessage, designer)
        XCTAssertNotNil(dapiAccountProblem(DapiAccount(kind: "admin", approval: nil, effectiveScopes: allScopes)))
        let oneMissing = try XCTUnwrap(dapiAccountProblem(integrator(["quotes:read", "quotes:write"])))
        XCTAssertTrue(oneMissing.hasPrefix("This key can’t use orders:read."), oneMissing)
        let twoMissing = try XCTUnwrap(dapiAccountProblem(integrator(["quotes:read"])))
        XCTAssertTrue(twoMissing.hasPrefix("This key can’t use quotes:write and orders:read."), twoMissing)
        let none = try XCTUnwrap(dapiAccountProblem(integrator([])))
        XCTAssertTrue(none.hasPrefix("This key can’t use quotes:read, quotes:write and orders:read."), none)
    }

    func testAccountStatusLine() {
        XCTAssertNil(dapiAccountStatusLine(nil, onboarding: pendingOnboarding))
        XCTAssertNil(dapiAccountStatusLine(DapiAccount(kind: "designer", approval: nil, effectiveScopes: []), onboarding: nil))
        XCTAssertEqual(dapiAccountStatusLine(integrator(approval: "approved"), onboarding: nil), "Integrator account · Approved")
        XCTAssertEqual(dapiAccountStatusLine(integrator(approval: "pending"),
                                             onboarding: DapiOnboarding(status: "approved", approvedFiles: 10, requiredFiles: 10,
                                                                        uploadsUsed: 30, uploadsLimit: nil)),
                       "Integrator account · Approved")
        XCTAssertEqual(dapiAccountStatusLine(integrator(approval: "rejected"), onboarding: nil), "Integrator account · Not approved by 3DAPI")
        XCTAssertEqual(dapiAccountStatusLine(integrator(), onboarding: nil), "Not yet approved by 3DAPI")
        XCTAssertEqual(dapiAccountStatusLine(integrator(), onboarding: pendingOnboarding), "Not yet approved by 3DAPI · 7 of 25 quotes used")
        XCTAssertEqual(dapiAccountStatusLine(integrator(), onboarding: DapiOnboarding(status: "in_review", approvedFiles: 0, requiredFiles: 10,
                                                                                      uploadsUsed: 10, uploadsLimit: 25)),
                       "Not yet approved by 3DAPI · 10 of 25 quotes used · Files in review")
        XCTAssertEqual(dapiAccountStatusLine(integrator(), onboarding: DapiOnboarding(status: "changes_requested", approvedFiles: 8,
                                                                                      requiredFiles: 10, uploadsUsed: 2, uploadsLimit: nil)),
                       "Not yet approved by 3DAPI · Changes requested")
    }

    func testScopeAdviceOnlyForOrdersWrite() {
        XCTAssertNil(dapiKeyScopeAdvice(nil))
        XCTAssertNil(dapiKeyScopeAdvice(integrator()))
        let advice = dapiKeyScopeAdvice(integrator(allScopes + ["Orders:Write"]))
        XCTAssertEqual(advice, "This key can also place paid orders on 3DAPI. Plinth needs only quotes:read, quotes:write and orders:read, so a key without orders:write is safer.")
        // Advice only: the key still passes the account check.
        XCTAssertNil(dapiAccountProblem(integrator(allScopes + ["orders:write"])))
    }

    // MARK: Quote write records

    func testQuoteWriteRecordsAreSessionOnlyAndClearedByAKeyChange() async throws {
        registry.set(StubDapi(account: .success(integrator())), for: integratorKey)
        registry.set(StubDapi(account: .success(integrator())), for: otherIntegratorKey)
        let connection = makeConnection()
        let saved = await connection.saveAndTest(key: integratorKey)
        XCTAssertNil(saved)

        connection.beginQuoteWrite(forFileHash: "ABC")
        XCTAssertTrue(connection.quoteWriteIsInFlight(forFileHash: "abc"))
        XCTAssertEqual(connection.keyChangeBlockedReason, "Wait for the 3DAPI request to finish.", "even with no sheet open")
        // Closing a sheet doesn't touch the records.
        connection.sheetOpened()
        connection.sheetClosed()
        XCTAssertTrue(connection.quoteWriteIsInFlight(forFileHash: "abc"))
        connection.noteQuoteWriteUnknown(forFileHash: "abc")
        connection.endQuoteWrite(forFileHash: "abc")
        XCTAssertFalse(connection.quoteWriteIsInFlight(forFileHash: "abc"))
        XCTAssertNil(connection.keyChangeBlockedReason)
        XCTAssertTrue(connection.quoteWriteOutcomeUnknown(forFileHash: "ABC"))

        // A usable ready quote for that file settles it; another file's record stays.
        connection.noteQuoteWriteUnknown(forFileHash: "def")
        connection.rememberReadyQuote(id: "qte_1", forFileHash: "abc")
        XCTAssertFalse(connection.quoteWriteOutcomeUnknown(forFileHash: "abc"))
        XCTAssertTrue(connection.quoteWriteOutcomeUnknown(forFileHash: "def"))

        // A new key starts afresh, and so does removing it.
        let replaced = await connection.saveAndTest(key: otherIntegratorKey)
        XCTAssertNil(replaced)
        XCTAssertFalse(connection.quoteWriteOutcomeUnknown(forFileHash: "def"))
        connection.noteQuoteWriteUnknown(forFileHash: "ghi")
        try connection.remove()
        XCTAssertFalse(connection.quoteWriteOutcomeUnknown(forFileHash: "ghi"))
        // Nothing about them reaches preferences.
        XCTAssertEqual(Set((defaults.persistentDomain(forName: suite) ?? [:]).keys), [DapiConnection.keySavedDefaultsKey])
    }

    // MARK: Cancellation

    func testCancellationKeepsTheAccountAndOnboarding() async throws {
        let stub = StubDapi(account: .success(integrator()), onboarding: .success(pendingOnboarding))
        registry.set(stub, for: integratorKey)
        let connection = makeConnection()
        let saved = await connection.saveAndTest(key: integratorKey)
        XCTAssertNil(saved)
        XCTAssertEqual(connection.onboarding, pendingOnboarding)

        // Settings closing mid-read (or Stop) cancels: nothing is cleared and no failure is reported.
        stub.accountThrows = CancellationError()
        let status = await connection.refreshStatus()
        XCTAssertNil(status)
        XCTAssertEqual(connection.account, integrator())
        XCTAssertEqual(connection.onboarding, pendingOnboarding)
        stub.accountThrows = nil
        stub.onboardingThrows = URLError(.cancelled)
        let read = await connection.refreshOnboarding()
        XCTAssertNil(read)
        XCTAssertEqual(connection.onboarding, pendingOnboarding)

        // A real failure still clears them.
        stub.onboardingThrows = DapiError.readFailed("down")
        await connection.refreshOnboarding()
        XCTAssertNil(connection.onboarding)
        stub.accountThrows = DapiError.readFailed("down")
        let failed = await connection.refreshStatus()
        XCTAssertNotNil(failed)
        XCTAssertNil(connection.account)
        XCTAssertEqual(connection.activeRequests, 0)
    }

    func testBlockedReasonAndCounters() {
        XCTAssertNil(dapiKeyChangeBlockedReason(activeRequests: 0, openSheets: 0))
        XCTAssertEqual(dapiKeyChangeBlockedReason(activeRequests: 1, openSheets: 1), "Wait for the 3DAPI request to finish.")
        XCTAssertEqual(dapiKeyChangeBlockedReason(activeRequests: 0, openSheets: 2), "Close the Get 3DAPI quote sheet first.")

        let connection = makeConnection()
        XCTAssertNil(connection.keyChangeBlockedReason)
        connection.endRequest()
        connection.sheetClosed()
        XCTAssertEqual(connection.activeRequests, 0)
        XCTAssertEqual(connection.openSheets, 0)
        connection.beginRequest()
        XCTAssertTrue(connection.isBusy)
        XCTAssertNotNil(connection.keyChangeBlockedReason)
        connection.endRequest()
        connection.endRequest()
        XCTAssertEqual(connection.activeRequests, 0)
        XCTAssertFalse(connection.isBusy)
        connection.sheetOpened()
        XCTAssertEqual(connection.keyChangeBlockedReason, "Close the Get 3DAPI quote sheet first.")
        XCTAssertFalse(connection.isBusy)
        connection.sheetClosed()
        connection.sheetClosed()
        XCTAssertEqual(connection.openSheets, 0)
        XCTAssertNil(connection.keyChangeBlockedReason)
    }

    // MARK: Save & Test

    func testIntegratorKeyIsSavedTrimmed() async throws {
        registry.set(StubDapi(account: .success(integrator()), onboarding: .success(pendingOnboarding)), for: integratorKey)
        let connection = makeConnection()
        let result = await connection.saveAndTest(key: integratorKey + "\n")
        XCTAssertNil(result)
        XCTAssertEqual(keys.value, integratorKey)
        XCTAssertTrue(connection.isConfigured)
        XCTAssertTrue(defaults.bool(forKey: DapiConnection.keySavedDefaultsKey))
        XCTAssertEqual(connection.account, integrator())
        XCTAssertEqual(connection.onboarding, pendingOnboarding)
        XCTAssertEqual(connection.activeRequests, 0)
        XCTAssertEqual(registry.keysMade, [integratorKey])
        // The tested client is kept: no Keychain read, no second client.
        _ = try connection.currentClient()
        XCTAssertEqual(keys.loads, 0)
        XCTAssertEqual(registry.keysMade, [integratorKey])
        // Only the flag goes to preferences.
        let saved = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(Set(saved.keys), [DapiConnection.keySavedDefaultsKey])
    }

    func testDesignerKeyIsRefusedAndNotSaved() async throws {
        registry.set(StubDapi(account: .success(DapiAccount(kind: "designer", approval: nil, effectiveScopes: allScopes))), for: designerKey)
        let connection = makeConnection()
        let outcome1 = await connection.saveAndTest(key: designerKey)
        let result = try XCTUnwrap(outcome1)
        XCTAssertTrue(result.contains("integrator account"), result)
        XCTAssertNil(keys.value)
        XCTAssertFalse(connection.isConfigured)
        XCTAssertFalse(defaults.bool(forKey: DapiConnection.keySavedDefaultsKey))
        XCTAssertNil(connection.account)
        XCTAssertEqual(connection.activeRequests, 0)
    }

    func testMissingScopeIsRefusedAndNotSaved() async throws {
        registry.set(StubDapi(account: .success(integrator(["quotes:read", "quotes:write"]))), for: integratorKey)
        let connection = makeConnection()
        let outcome2 = await connection.saveAndTest(key: integratorKey)
        let result = try XCTUnwrap(outcome2)
        XCTAssertTrue(result.contains("orders:read"), result)
        XCTAssertNil(keys.value)
        XCTAssertFalse(connection.isConfigured)
    }

    func testFailedTestSavesNothingAndKeepsTheEarlierKey() async throws {
        registry.set(StubDapi(account: .success(integrator(approval: "approved")), onboarding: .success(pendingOnboarding)), for: integratorKey)
        registry.set(StubDapi(account: .failure(.readFailed("offline"))), for: otherIntegratorKey)
        let connection = makeConnection()
        let outcome3 = await connection.saveAndTest(key: integratorKey)
        XCTAssertNil(outcome3)
        connection.rememberReadyQuote(id: "qte_1", forFileHash: "ABC")

        let failure = await connection.saveAndTest(key: otherIntegratorKey)
        XCTAssertEqual(failure, DapiError.readFailed("offline").userMessage)
        XCTAssertEqual(keys.value, integratorKey)
        XCTAssertTrue(connection.isConfigured)
        XCTAssertEqual(connection.account, integrator(approval: "approved"))
        XCTAssertEqual(connection.readyQuoteID(forFileHash: "abc"), "qte_1")
        XCTAssertEqual(connection.activeRequests, 0)
    }

    func testKeyIsRefusedLocallyBeforeAnyRequest() async {
        let connection = makeConnection()
        let result = await connection.saveAndTest(key: "sk_abc def")
        XCTAssertNotNil(result)
        XCTAssertEqual(registry.keysMade, [])
    }

    func testKeychainSaveFailureLeavesNothingSaved() async throws {
        registry.set(StubDapi(account: .success(integrator())), for: integratorKey)
        keys.saveError = StudioError("Keychain refused \(integratorKey)")
        let connection = makeConnection()
        let outcome4 = await connection.saveAndTest(key: integratorKey)
        let result = try XCTUnwrap(outcome4)
        XCTAssertTrue(result.hasPrefix("Couldn’t save the 3DAPI key"), result)
        XCTAssertFalse(result.contains(integratorKey), result)
        XCTAssertFalse(connection.isConfigured)
        XCTAssertFalse(defaults.bool(forKey: DapiConnection.keySavedDefaultsKey))
    }

    func testReplacingTheKeyClearsTheQuoteCache() async {
        registry.set(StubDapi(account: .success(integrator())), for: integratorKey)
        registry.set(StubDapi(account: .success(integrator(approval: "approved"))), for: otherIntegratorKey)
        let connection = makeConnection()
        let outcome5 = await connection.saveAndTest(key: integratorKey)
        XCTAssertNil(outcome5)
        connection.rememberReadyQuote(id: "qte_1", forFileHash: "abc")
        XCTAssertEqual(connection.readyQuoteID(forFileHash: "ABC"), "qte_1")
        let outcome6 = await connection.saveAndTest(key: otherIntegratorKey)
        XCTAssertNil(outcome6)
        XCTAssertNil(connection.readyQuoteID(forFileHash: "abc"))
        XCTAssertEqual(keys.value, otherIntegratorKey)
        XCTAssertEqual(connection.account, integrator(approval: "approved"))
    }

    func testQuotesAreNotRememberedWithoutAKey() {
        let connection = makeConnection()
        connection.rememberReadyQuote(id: "qte_1", forFileHash: "abc")
        XCTAssertNil(connection.readyQuoteID(forFileHash: "abc"))
    }

    func testSaveIsRefusedWhileASheetIsOpen() async throws {
        registry.set(StubDapi(account: .success(integrator())), for: integratorKey)
        let connection = makeConnection()
        connection.sheetOpened()
        let result = await connection.saveAndTest(key: integratorKey)
        XCTAssertEqual(result, "Close the Get 3DAPI quote sheet first.")
        XCTAssertEqual(registry.keysMade, [])
        XCTAssertNil(keys.value)
    }

    func testSheetOpenedDuringTheTestStopsTheSave() async throws {
        let gate = DapiTestGate()
        registry.set(StubDapi(account: .success(integrator()), gate: gate), for: integratorKey)
        let connection = makeConnection()
        let save = Task { await connection.saveAndTest(key: integratorKey) }
        await waitUntilArrived(gate)
        XCTAssertEqual(connection.activeRequests, 1)
        connection.sheetOpened()
        await gate.open()
        let result = await save.value
        XCTAssertEqual(result, "Close the Get 3DAPI quote sheet first.")
        XCTAssertNil(keys.value)
        XCTAssertFalse(connection.isConfigured)
        XCTAssertEqual(connection.activeRequests, 0)
    }

    func testConcurrentSavePressesOnlyOneRuns() async throws {
        let gate = DapiTestGate()
        registry.set(StubDapi(account: .success(integrator()), gate: gate), for: integratorKey)
        registry.set(StubDapi(account: .success(integrator())), for: otherIntegratorKey)
        let connection = makeConnection()
        let first = Task { await connection.saveAndTest(key: integratorKey) }
        await waitUntilArrived(gate)
        let second = await connection.saveAndTest(key: otherIntegratorKey)
        XCTAssertEqual(second, "Wait for the 3DAPI request to finish.")
        XCTAssertThrowsError(try connection.remove())
        await gate.open()
        let firstResult = await first.value
        XCTAssertNil(firstResult)
        XCTAssertEqual(keys.value, integratorKey)
        XCTAssertEqual(registry.keysMade, [integratorKey])
    }

    // MARK: Saved key

    func testCurrentClientWithoutAKeyThrowsMissingKey() {
        let connection = makeConnection()
        XCTAssertThrowsError(try connection.currentClient()) { XCTAssertEqual($0 as? DapiError, .missingKey) }
        XCTAssertEqual(keys.loads, 0)
    }

    func testFlagSetButItemGoneResetsTheFlag() {
        defaults.set(true, forKey: DapiConnection.keySavedDefaultsKey)
        let connection = makeConnection()
        XCTAssertTrue(connection.isConfigured)
        XCTAssertThrowsError(try connection.currentClient()) { XCTAssertEqual($0 as? DapiError, .missingKey) }
        XCTAssertFalse(connection.isConfigured)
        XCTAssertFalse(defaults.bool(forKey: DapiConnection.keySavedDefaultsKey))
    }

    func testUnreadableKeychainKeepsTheFlag() {
        defaults.set(true, forKey: DapiConnection.keySavedDefaultsKey)
        keys.loadError = APIError.keychain(-25308) // errSecInteractionNotAllowed: locked
        let connection = makeConnection()
        XCTAssertThrowsError(try connection.currentClient()) { error in
            guard case .notSent = error as? DapiError else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(connection.isConfigured)
        XCTAssertTrue(defaults.bool(forKey: DapiConnection.keySavedDefaultsKey))
        keys.loadError = nil
        keys.value = integratorKey
        XCTAssertNoThrow(try connection.currentClient())
        XCTAssertEqual(registry.keysMade, [integratorKey])
    }

    func testSavedKeyIsReadLazilyOnce() throws {
        defaults.set(true, forKey: DapiConnection.keySavedDefaultsKey)
        keys.value = integratorKey + "\n"
        let connection = makeConnection()
        XCTAssertEqual(keys.loads, 0)
        _ = try connection.currentClient()
        _ = try connection.currentClient()
        XCTAssertEqual(keys.loads, 1)
        XCTAssertEqual(registry.keysMade, [integratorKey])
    }

    func testRefreshStatusAndTestSavedKey() async throws {
        defaults.set(true, forKey: DapiConnection.keySavedDefaultsKey)
        keys.value = integratorKey
        registry.set(StubDapi(account: .success(integrator()), onboarding: .success(pendingOnboarding)), for: integratorKey)
        let connection = makeConnection()
        let result = await connection.testSavedKey()
        XCTAssertNil(result)
        XCTAssertEqual(connection.account, integrator())
        XCTAssertEqual(connection.onboarding, pendingOnboarding)
        XCTAssertEqual(connection.activeRequests, 0)
    }

    func testFailedTestOfSavedKeyHidesTheLineButKeepsTheKey() async throws {
        registry.set(StubDapi(account: .success(integrator()), onboarding: .success(pendingOnboarding)), for: integratorKey)
        let connection = makeConnection()
        let outcome7 = await connection.saveAndTest(key: integratorKey)
        XCTAssertNil(outcome7)
        connection.rememberReadyQuote(id: "qte_1", forFileHash: "abc")
        // The key was revoked in 3DAPI's dashboard: the next client gets 401.
        registry.set(StubDapi(account: .failure(.refused(status: 401, code: "invalid_api_key", message: nil))), for: integratorKey)
        let reloaded = makeConnection()
        let result = await reloaded.testSavedKey()
        XCTAssertNotNil(result)
        XCTAssertNil(reloaded.account)
        XCTAssertNil(reloaded.onboarding)
        XCTAssertTrue(reloaded.isConfigured)
        XCTAssertEqual(keys.value, integratorKey)
    }

    func testSavedDesignerAccountIsReported() async throws {
        defaults.set(true, forKey: DapiConnection.keySavedDefaultsKey)
        keys.value = designerKey
        registry.set(StubDapi(account: .success(DapiAccount(kind: "designer", approval: nil, effectiveScopes: [])),
                              onboarding: .success(pendingOnboarding)), for: designerKey)
        let connection = makeConnection()
        let outcome8 = await connection.refreshStatus()
        let result = try XCTUnwrap(outcome8)
        XCTAssertTrue(result.contains("integrator account"), result)
        XCTAssertNil(connection.onboarding)
    }

    func testRefreshOnboardingFailureHidesIt() async {
        registry.set(StubDapi(account: .success(integrator()), onboarding: .failure(.readFailed("down"))), for: integratorKey)
        let connection = makeConnection()
        let outcome9 = await connection.saveAndTest(key: integratorKey)
        XCTAssertNil(outcome9)
        XCTAssertNil(connection.onboarding)
        XCTAssertEqual(connection.activeRequests, 0)
        try? connection.remove()
        await connection.refreshOnboarding()
        XCTAssertNil(connection.onboarding)
        XCTAssertEqual(registry.keysMade, [integratorKey])
    }

    // MARK: Remove

    func testRemoveClearsFlagCacheAccountAndOnboarding() async throws {
        registry.set(StubDapi(account: .success(integrator()), onboarding: .success(pendingOnboarding)), for: integratorKey)
        let connection = makeConnection()
        let outcome10 = await connection.saveAndTest(key: integratorKey)
        XCTAssertNil(outcome10)
        connection.rememberReadyQuote(id: "qte_1", forFileHash: "abc")
        try connection.remove()
        XCTAssertNil(keys.value)
        XCTAssertFalse(connection.isConfigured)
        XCTAssertFalse(defaults.bool(forKey: DapiConnection.keySavedDefaultsKey))
        XCTAssertNil(connection.account)
        XCTAssertNil(connection.onboarding)
        XCTAssertNil(connection.readyQuoteID(forFileHash: "abc"))
        XCTAssertThrowsError(try connection.currentClient()) { XCTAssertEqual($0 as? DapiError, .missingKey) }
    }

    func testRemoveIsRefusedWhileBlocked() async throws {
        registry.set(StubDapi(account: .success(integrator())), for: integratorKey)
        let connection = makeConnection()
        let outcome11 = await connection.saveAndTest(key: integratorKey)
        XCTAssertNil(outcome11)
        connection.sheetOpened()
        XCTAssertThrowsError(try connection.remove()) {
            XCTAssertEqual($0.localizedDescription, "Close the Get 3DAPI quote sheet first.")
        }
        XCTAssertEqual(keys.value, integratorKey)
        XCTAssertTrue(connection.isConfigured)
        connection.sheetClosed()
        connection.beginRequest()
        XCTAssertThrowsError(try connection.remove())
        connection.endRequest()
        XCTAssertNoThrow(try connection.remove())
    }
}
