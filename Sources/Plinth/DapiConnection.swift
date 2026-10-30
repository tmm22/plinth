import Foundation

// STUB: replaced wholesale by the connection implementer. Keep every signature below (more may be added).

extension AIServiceKeychainItem {
    static let dapi = AIServiceKeychainItem(account: "dapi-api-key")
}

/// The app-wide 3DAPI connection: whether a key is saved (a preferences flag; the key itself lives only in the
/// `dapi-api-key` Keychain item), the last account check (memory only), the work counters that stop the key changing
/// mid-request, and the session-only cache of ready quotes by file hash.
@MainActor final class DapiConnection: ObservableObject {
    static let shared = DapiConnection()
    static let keySavedDefaultsKey = "dapiKeySaved"

    @Published private(set) var isConfigured = false
    @Published private(set) var account: DapiAccount?
    @Published private(set) var onboarding: DapiOnboarding?
    @Published private(set) var activeRequests = 0
    @Published private(set) var openSheets = 0

    init(defaults: UserDefaults = .standard, keychain: AIServiceKeychainItem = .dapi,
         makeClient: @escaping @Sendable (String) -> any DapiQuoting = { DapiClient(apiKey: $0) }) {}

    var isBusy: Bool { activeRequests > 0 }
    /// Why the key can't be saved or removed now, or nil.
    var keyChangeBlockedReason: String? { nil }

    func beginRequest() {}
    func endRequest() {}
    func sheetOpened() {}
    func sheetClosed() {}

    /// The client for the saved key. Throws `DapiError.missingKey` without one.
    func currentClient() throws -> any DapiQuoting { throw DapiError.missingKey }

    /// Reads `GET /v2/integrator/onboarding` with the saved key and keeps it in `onboarding`; failures are ignored
    /// (the allowance line just isn't shown).
    func refreshOnboarding() async {}

    /// The ready quote this session already found for a file's SHA-256 (hex), or nil.
    func readyQuoteID(forFileHash hash: String) -> String? { nil }
    func rememberReadyQuote(id: String, forFileHash hash: String) {}
}
