import Foundation

// 3DAPI's key and session state: the saved-key flag, the last account check, the work counters that keep the key
// from changing under a request or an open quote sheet, and the session-only cache of ready quotes. See
// docs/3DAPI_REFERENCE.md §1 (account kinds), §5.1 (keys) and §8 (privacy).

extension AIServiceKeychainItem {
    static let dapi = AIServiceKeychainItem(account: "dapi-api-key")
}

/// Where the 3DAPI key is kept. The app uses its own Keychain item (`AIServiceKeychainItem.dapi`); tests pass an
/// in-memory store, so they never touch the real Keychain.
protocol DapiKeyStore {
    func load() throws -> String?
    func save(_ value: String) throws
    func delete() throws
}

extension AIServiceKeychainItem: DapiKeyStore {}

/// The scopes a key needs to be saved: uploads and quotes, and `orders:read` for the shipping estimate and the order
/// list. `orders:write` is optional: it lets Plinth place orders (`dapiOrderingProblem`).
let dapiRequiredScopes = ["quotes:read", "quotes:write", "orders:read"]

/// Where a seller makes an integrator account (one email can't hold both a seller and an integrator account).
let dapiIntegratorSignUpURL = URL(string: "https://www.dapi.digital/integrator/sign-up")!

/// Longest key Plinth accepts. 3DAPI's example integrator key is `sk_` and 63 hex characters (no length is documented); the designer format is
/// undocumented, so the limit is generous.
let dapiMaxKeyLength = 256
/// Shortest key Plinth accepts: anything shorter is a partial paste.
let dapiMinKeyLength = 20

/// The first problem with a typed key, or nil. The key is trimmed first, so a trailing line break is fine. The `sk_`
/// prefix isn't required, because 3DAPI doesn't document the seller key's format; `GET /v2/me` decides the rest.
func dapiKeyProblem(_ raw: String) -> String? {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty { return "Enter the 3DAPI API key." }
    guard key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
        return "The key has spaces, line breaks or characters a 3DAPI key never has. Copy it again."
    }
    if key.count < dapiMinKeyLength { return "That 3DAPI key is too short. Copy the whole key again." }
    if key.count > dapiMaxKeyLength { return "That 3DAPI key is too long." }
    return nil
}

/// Why an account can't be used for price quotes, or nil when it can: it must be an integrator account whose key
/// has every scope in `dapiRequiredScopes`.
func dapiAccountProblem(_ account: DapiAccount) -> String? {
    let kind = account.kind.lowercased()
    guard kind == "integrator" else {
        if kind == "designer" { return dapiDesignerKeyMessage }
        return "This key isn’t for a 3DAPI integrator account, which price quotes need."
    }
    let scopes = Set(account.effectiveScopes.map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    let missing = dapiRequiredScopes.filter { !scopes.contains($0) }
    guard !missing.isEmpty else { return nil }
    return "This key can’t use \(dapiJoinedList(missing)). In 3DAPI’s dashboard, make a key with quotes:read, quotes:write and orders:read (and orders:write to place orders)."
}

/// "a", "a and b", "a, b and c" (fixed English wording, independent of the Mac's locale).
func dapiJoinedList(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
}

/// The Settings line for the saved key's account, or nil when there is nothing to show (no check yet, the last check
/// failed, or the account can't quote, which `dapiAccountProblem` explains instead).
func dapiAccountStatusLine(_ account: DapiAccount?, onboarding: DapiOnboarding?) -> String? {
    guard let account, account.kind.lowercased() == "integrator" else { return nil }
    let approval = account.approval?.lowercased()
    if approval == "approved" || onboarding?.status == "approved" { return "Integrator account · Approved" }
    if approval == "rejected" { return "Integrator account · Not approved by 3DAPI" }
    var line = "Not yet approved by 3DAPI"
    guard let onboarding else { return line }
    if let limit = onboarding.uploadsLimit { line += " · \(onboarding.uploadsUsed) of \(limit) quotes used" }
    switch onboarding.status {
    case "in_review": line += " · Files in review"
    case "changes_requested": line += " · Changes requested"
    default: break
    }
    return line
}

/// Settings' ordering line for the saved key's account: whether it can place 3DAPI orders, or why not. Nil before the
/// first account check, after a failed one, or when the key can't be used at all (`dapiAccountProblem` says why).
func dapiOrderingStatusLine(_ account: DapiAccount?, onboarding: DapiOnboarding?) -> (ready: Bool, text: String)? {
    guard let account, dapiAccountProblem(account) == nil else { return nil }
    if let problem = dapiOrderingProblem(account: account, onboardingOrderBlockers: onboarding?.orderBlockers ?? []) {
        return (false, "Ordering: not available yet. \(problem)")
    }
    return (true, "Ordering: ready. Each order is charged when you press Place Order.")
}

/// Why the 3DAPI key can't be saved or removed now, or nil. A quote write still waiting for 3DAPI (`writesInFlight`)
/// counts as a request even after its sheet closed. `orderSessionReason` is the order screens' own
/// (`DapiOrderSession.changeBlockedReason`: an order or cancellation waiting for 3DAPI, or an order sheet open).
func dapiKeyChangeBlockedReason(activeRequests: Int, openSheets: Int, writesInFlight: Int = 0,
                                orderSessionReason: String? = nil) -> String? {
    if let orderSessionReason { return orderSessionReason }
    if activeRequests > 0 || writesInFlight > 0 { return "Wait for the 3DAPI request to finish." }
    if openSheets > 0 { return "Close the Get 3DAPI quote sheet first." }
    return nil
}

/// A failed request's text for the seller, with the typed key masked too.
func dapiFailureMessage(_ error: Error, key: String? = nil) -> String {
    let text = (error as? DapiError)?.userMessage ?? error.localizedDescription
    return dapiRedacted(text, secrets: key.map { [$0] } ?? [])
}

/// The app-wide 3DAPI connection: whether a key is saved (a preferences flag; the key itself lives only in the
/// `dapi-api-key` Keychain item), the last account check (memory only), the work counters that stop the key changing
/// mid-request, the session-only cache of ready quotes by file hash, and the session-only records of quote writes
/// (upload and create) still waiting for 3DAPI or whose outcome is unknown, by file hash.
@MainActor final class DapiConnection: ObservableObject {
    static let shared = DapiConnection()
    static let keySavedDefaultsKey = "dapiKeySaved"

    @Published private(set) var isConfigured: Bool
    /// The saved key's account from the last `GET /v2/me`; nil before the first check and after a failed one.
    @Published private(set) var account: DapiAccount?
    @Published private(set) var onboarding: DapiOnboarding?
    /// 3DAPI requests running now (the quote sheet's and Settings'). The key can't change under them.
    @Published private(set) var activeRequests = 0
    /// Open Get 3DAPI quote sheets. A quote belongs to one account, so the key can't change while one is open.
    @Published private(set) var openSheets = 0

    /// File SHA-256s (hex, lower-case) with an upload or quote create sent and not yet answered. Memory only; never
    /// cleared by closing a sheet, so a reopened sheet can't send a second one meanwhile.
    @Published private(set) var quoteWritesInFlight: Set<String> = []
    /// File SHA-256s whose upload or quote create had an unknown outcome this session. Memory only; cleared for a file
    /// once a usable quote for it is found. A key save or removal never clears them: Plinth can't tell whether a new
    /// key belongs to the same 3DAPI account (an account may hold up to 10 keys), as with Slant's outcome lock.
    @Published private(set) var quoteWritesUnknown: Set<String> = []

    private var client: (any DapiQuoting)?
    /// File SHA-256 (hex, lower-case) → ready quote ID. Memory only, and for the saved key's account only.
    private var readyQuotes: [String: String] = [:]
    /// Bumped whenever the key is saved or removed, so a reply for an earlier key is never kept.
    /// Bumped whenever the saved key is saved, replaced or removed: replies for an earlier key are dropped, and the
    /// order screens and the order watch start over for the new key (it may belong to another account).
    @Published private(set) var keyGeneration = 0
    private let defaults: UserDefaults
    private let keychain: any DapiKeyStore
    private let makeClient: @Sendable (String) -> any DapiQuoting
    /// The order screens' reason the key can't change (an order write waiting, an order sheet open).
    private let orderSessionBlockedReason: @MainActor () -> String?

    init(defaults: UserDefaults = .standard, keychain: any DapiKeyStore = AIServiceKeychainItem.dapi,
         makeClient: @escaping @Sendable (String) -> any DapiQuoting = { DapiClient(apiKey: $0) },
         orderSessionBlockedReason: @escaping @MainActor () -> String? = { DapiOrderSession.shared.changeBlockedReason }) {
        self.defaults = defaults
        self.keychain = keychain
        self.makeClient = makeClient
        self.orderSessionBlockedReason = orderSessionBlockedReason
        isConfigured = defaults.bool(forKey: Self.keySavedDefaultsKey)
    }

    var isBusy: Bool { activeRequests > 0 }

    /// Why the key can't be saved or removed now, or nil.
    var keyChangeBlockedReason: String? {
        dapiKeyChangeBlockedReason(activeRequests: activeRequests, openSheets: openSheets, writesInFlight: quoteWritesInFlight.count,
                                   orderSessionReason: orderSessionBlockedReason())
    }

    func quoteWriteIsInFlight(forFileHash hash: String) -> Bool { quoteWritesInFlight.contains(hash.lowercased()) }
    func quoteWriteOutcomeUnknown(forFileHash hash: String) -> Bool { quoteWritesUnknown.contains(hash.lowercased()) }
    func beginQuoteWrite(forFileHash hash: String) {
        guard !hash.isEmpty else { return }
        quoteWritesInFlight.insert(hash.lowercased())
    }
    func endQuoteWrite(forFileHash hash: String) { quoteWritesInFlight.remove(hash.lowercased()) }
    func noteQuoteWriteUnknown(forFileHash hash: String) {
        guard !hash.isEmpty else { return }
        quoteWritesUnknown.insert(hash.lowercased())
    }

    func beginRequest() { activeRequests += 1 }
    func endRequest() { activeRequests = max(0, activeRequests - 1) }
    func sheetOpened() { openSheets += 1 }
    func sheetClosed() { openSheets = max(0, openSheets - 1) }

    /// The client for the saved key, reading the Keychain the first time. Throws `DapiError.missingKey` without a
    /// saved key, and clears the saved flag when the Keychain item has gone; a Keychain read that fails for another
    /// reason (locked, refused) throws `DapiError.notSent` and leaves the flag alone, so a later read tries again.
    func currentClient() throws -> any DapiQuoting {
        if let client { return client }
        guard isConfigured else { throw DapiError.missingKey }
        let key: String?
        do {
            key = try keychain.load()
        } catch {
            throw DapiError.notSent("Plinth couldn’t read the 3DAPI key from the Keychain: \(dapiRedacted(error.localizedDescription))")
        }
        guard let key, dapiKeyProblem(key) == nil else {
            forgetSavedKey()
            throw DapiError.missingKey
        }
        let client = makeClient(key.trimmingCharacters(in: .whitespacesAndNewlines))
        self.client = client
        return client
    }

    /// The ordering client for the saved key (the same `DapiClient`). Throws like `currentClient()`, and `.notSent`
    /// when the client can't order (a test stub that only quotes).
    func currentOrderingClient() throws -> any DapiOrdering {
        guard let ordering = try currentClient() as? any DapiOrdering else {
            throw DapiError.notSent("This 3DAPI connection can’t place orders.")
        }
        return ordering
    }

    /// Reads `GET /v2/integrator/onboarding` with the saved key, keeps it in `onboarding` and returns it. A failure
    /// returns nil and hides the allowance line; a cancellation (Stop, or Settings closing) returns nil and keeps the
    /// last reading.
    @discardableResult
    func refreshOnboarding() async -> DapiOnboarding? {
        guard let client = try? currentClient() else { onboarding = nil; return nil }
        let generation = keyGeneration
        beginRequest()
        defer { endRequest() }
        do {
            let result = try await client.onboarding()
            guard generation == keyGeneration else { return nil }
            onboarding = result
            return result
        } catch {
            guard generation == keyGeneration, !dapiIsCancellation(error) else { return nil }
            onboarding = nil
            return nil
        }
    }

    /// Reads the saved key's account, then its onboarding when it can quote. A failure clears both, so Settings'
    /// account line is hidden rather than out of date; a cancellation leaves both as they were. Returns the failure's
    /// text, the reason the account can't quote, or nil.
    @discardableResult
    func refreshStatus() async -> String? {
        let client: any DapiQuoting
        do {
            client = try currentClient()
        } catch {
            account = nil
            onboarding = nil
            return dapiFailureMessage(error)
        }
        let generation = keyGeneration
        beginRequest()
        let result: Result<DapiAccount, Error>
        do { result = .success(try await client.account()) } catch { result = .failure(error) }
        endRequest()
        guard generation == keyGeneration else { return nil }
        switch result {
        case .failure(let error):
            if dapiIsCancellation(error) { return nil }
            account = nil
            onboarding = nil
            return dapiFailureMessage(error)
        case .success(let checked):
            account = checked
            if let problem = dapiAccountProblem(checked) {
                onboarding = nil
                return problem
            }
            await refreshOnboarding()
            return nil
        }
    }

    /// Settings' Save & Test: reads `GET /v2/me` with the typed key and saves it only when it belongs to an
    /// integrator account with every scope in `dapiRequiredScopes`. Returns nil once saved, or why it wasn't. A
    /// failed test leaves any earlier key, its account and the quote cache as they were.
    func saveAndTest(key raw: String) async -> String? {
        if let reason = keyChangeBlockedReason { return reason }
        if let problem = dapiKeyProblem(raw) { return problem }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = makeClient(key)
        beginRequest()
        let result: Result<DapiAccount, Error>
        do { result = .success(try await candidate.account()) } catch { result = .failure(error) }
        endRequest()
        let checked: DapiAccount
        switch result {
        case .failure(let error): return dapiFailureMessage(error, key: key)
        case .success(let value): checked = value
        }
        if let problem = dapiAccountProblem(checked) { return problem }
        // A quote sheet may have opened, or another request started, while the test ran.
        if let reason = keyChangeBlockedReason { return reason }
        do {
            try keychain.save(key)
        } catch {
            return "Couldn’t save the 3DAPI key: \(dapiRedacted(error.localizedDescription, secrets: [key]))"
        }
        defaults.set(true, forKey: Self.keySavedDefaultsKey)
        keyGeneration += 1
        client = candidate
        readyQuotes = [:]
        account = checked
        onboarding = nil
        isConfigured = true
        await refreshOnboarding()
        return nil
    }

    /// Settings' Test Saved Key: the same account check with the saved key. Nil when the key works for quotes.
    func testSavedKey() async -> String? {
        await refreshStatus()
    }

    /// Deletes the Keychain item and forgets the client, the account check and the quote cache.
    func remove() throws {
        if let reason = keyChangeBlockedReason { throw StudioError(reason) }
        try keychain.delete()
        forgetSavedKey()
    }

    /// The ready quote this session already found for a file's SHA-256 (hex), or nil.
    func readyQuoteID(forFileHash hash: String) -> String? { readyQuotes[hash.lowercased()] }

    /// Remembers a usable ready quote for a file, which also settles any unknown write outcome for that file.
    func rememberReadyQuote(id: String, forFileHash hash: String) {
        guard isConfigured, !id.isEmpty, !hash.isEmpty else { return }
        readyQuotes[hash.lowercased()] = id
        quoteWritesUnknown.remove(hash.lowercased())
    }

    private func forgetSavedKey() {
        defaults.set(false, forKey: Self.keySavedDefaultsKey)
        keyGeneration += 1
        client = nil
        readyQuotes = [:]
        account = nil
        onboarding = nil
        isConfigured = false
    }
}
