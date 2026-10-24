import Foundation
import Security

// MARK: - Shopify connection
//
// A direct, optional link to the seller's own Shopify store, used only by Import Orders (From Shopify…) and Tracking
// for Your Shop (Send Tracking to Shopify…). Only the store's own `*.myshopify.com` host is ever contacted. Two ways
// in, both set up by the seller:
//   - a Dev Dashboard app installed on their own store: its client ID and secret buy a short-lived (about 24 hour)
//     token with the client credentials grant, held in memory only;
//   - an Admin API access token (`shpat_…`) from a custom app created in the store admin before 2026, which keep working.
// The credentials live in their own Keychain item, separate from the Slant key. Error text never carries a token,
// secret or client ID. Reads may wait out Shopify's throttle and try again; a mutation is sent once and never retried.

/// The GraphQL Admin API version Studio speaks. Each version is supported for at least 12 months; 2026-10 is listed
/// until October 2027.
let shopifyAPIVersion = "2026-10"
/// Largest reply Studio reads from Shopify. The biggest query (an import page) is far smaller.
let shopifyMaxResponseBytes = 4 * 1024 * 1024
let shopifyRequestTimeout: TimeInterval = 30
/// Longest a read waits for Shopify's throttle before giving up.
let shopifyMaxThrottleWait: TimeInterval = 30
/// Throttled reads are sent again at most this many times. Mutations never are.
let shopifyMaxThrottleRetries = 3
/// Longest client ID, secret or token accepted.
let shopifyMaxCredentialLength = 256

// MARK: Shop address

/// The store's `handle.myshopify.com` host from what the seller typed: a bare handle, the myshopify.com address
/// (with or without https:// and a path), or the admin address `admin.shopify.com/store/handle`. Nil for anything
/// else, including custom domains: Studio only ever contacts the store's myshopify.com host.
func shopifyShopDomain(_ raw: String) -> String? {
    var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !text.isEmpty, text.count <= 255 else { return nil }
    for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text = String(text.dropFirst(scheme.count)) }
    // Anything that could change the host (credentials, ports, queries) is refused rather than stripped.
    guard !text.contains(where: { $0.isWhitespace || "@:?#\\%".contains($0) }) else { return nil }
    let parts = text.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
    guard let host = parts.first, !host.isEmpty else { return nil }
    let handle: String
    if host == "admin.shopify.com" {
        guard parts.count >= 3, parts[1] == "store" else { return nil }
        handle = parts[2]
    } else if host.hasSuffix(".myshopify.com") {
        handle = String(host.dropLast(".myshopify.com".count))
    } else if parts.count == 1 {
        handle = host
    } else {
        return nil
    }
    guard handle.range(of: #"^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$"#, options: .regularExpression) != nil else { return nil }
    return "\(handle).myshopify.com"
}

/// The two endpoints Studio uses, both on the validated shop host.
func shopifyGraphQLURL(shop: String) -> URL? {
    guard shopifyShopDomain(shop) == shop else { return nil }
    return URL(string: "https://\(shop)/admin/api/\(shopifyAPIVersion)/graphql.json")
}

func shopifyTokenURL(shop: String) -> URL? {
    guard shopifyShopDomain(shop) == shop else { return nil }
    return URL(string: "https://\(shop)/admin/oauth/access_token")
}

// MARK: Credentials

enum ShopifyCredential: Equatable {
    /// A Dev Dashboard app's client ID and secret (client credentials grant).
    case app(clientID: String, clientSecret: String)
    /// An Admin API access token from a custom app made in the store admin.
    case accessToken(String)

    var secrets: [String] {
        switch self {
        case .app(let id, let secret): return [id, secret]
        case .accessToken(let token): return [token]
        }
    }
}

/// What the Keychain item holds, as JSON.
struct ShopifyStoredConnection: Codable, Equatable {
    var shop: String
    var clientID: String?
    var clientSecret: String?
    var accessToken: String?

    var credential: ShopifyCredential? {
        if let token = accessToken, !token.isEmpty { return .accessToken(token) }
        if let id = clientID, let secret = clientSecret, !id.isEmpty, !secret.isEmpty {
            return .app(clientID: id, clientSecret: secret)
        }
        return nil
    }

    init(shop: String, credential: ShopifyCredential) {
        self.shop = shop
        switch credential {
        case .app(let id, let secret): clientID = id; clientSecret = secret
        case .accessToken(let token): accessToken = token
        }
    }
}

/// Why a client ID, secret or token can't be right, or nil. Pasted values often carry spaces or line breaks.
func shopifyCredentialFieldProblem(_ value: String, name: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Enter the \(name)." }
    if trimmed.count > shopifyMaxCredentialLength { return "The \(name) is too long." }
    guard trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
        return "The \(name) has spaces or characters a Shopify \(name) never has. Copy it again."
    }
    return nil
}

/// The credentials item, kept apart from the Slant key's (`KeychainStore`, account "api-key").
enum ShopifyKeychainStore {
    private static let service = "SlantStudio"
    private static let account = "shopify-credentials"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() throws -> ShopifyStoredConnection? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIError.keychain(status) }
        guard let data = result as? Data, let stored = try? JSONDecoder().decode(ShopifyStoredConnection.self, from: data) else {
            throw StudioError("The saved Shopify details couldn’t be read. Disconnect Shopify in Settings and connect again.")
        }
        return stored
    }

    static func save(_ stored: ShopifyStoredConnection) throws {
        let data = try JSONEncoder().encode(stored)
        let values: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query.merging(values) { _, new in new }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIError.keychain(status) }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.keychain(status) }
    }
}

// MARK: Redaction

/// Text safe to show or record: every credential in `secrets` and anything shaped like a Shopify token
/// (`shpat_…`, `shpss_…` and similar) or an `access_token` value is replaced, and the result is clipped to one short line.
func shopifyRedacted(_ text: String, secrets: [String] = []) -> String {
    var result = text
    for secret in secrets.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where secret.count >= 4 {
        result = result.replacingOccurrences(of: secret, with: "[redacted]")
    }
    result = result.replacingOccurrences(of: #"shp[a-z]{2}_[A-Za-z0-9_\-]+"#, with: "[redacted]", options: .regularExpression)
    result = result.replacingOccurrences(of: #""?access_token"?\s*[:=]\s*"?[^"&,\s}]+"?"#, with: "access_token=[redacted]",
                                         options: [.regularExpression, .caseInsensitive])
    result = result.replacingOccurrences(of: #""?client_secret"?\s*[:=]\s*"?[^"&,\s}]+"?"#, with: "client_secret=[redacted]",
                                         options: [.regularExpression, .caseInsensitive])
    result = result.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if result.count > 240 { result = String(result.prefix(240)) + "…" }
    return result
}

// MARK: Errors

enum ShopifyError: LocalizedError, Equatable {
    case notConnected
    /// Shopify answered with this HTTP status. `message` is already redacted.
    case http(status: Int, message: String)
    /// The request was throttled (HTTP 429 or a THROTTLED error). Shopify checks the cost before running a query,
    /// so a throttled request did nothing.
    case throttled
    /// Top-level GraphQL errors, redacted, with their `extensions.code` values.
    case graphQL(messages: [String], codes: [String])
    /// Shopify withheld customer names, emails or addresses (protected customer data).
    case protectedCustomerData
    case tokenRefused(String)
    case invalidResponse(String)
    case responseTooLarge
    /// No reply was read: timeout, lost connection and so on. Whether a mutation ran is unknown.
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Connect your Shopify store in Settings › Account first."
        case .http(let status, let message):
            switch status {
            case 401: return "Shopify rejected Studio’s access. Check the app is still installed, then connect again in Settings."
            case 402: return "Shopify says this store is frozen or unpaid."
            case 403: return "Shopify refused this request. Check the app has the access scopes listed in Settings. \(message)".trimmingCharacters(in: .whitespaces)
            case 404: return "Shopify couldn’t find that store. Check the store address in Settings."
            case 423: return "Shopify says this store is locked."
            case 300...399: return "Shopify redirected the request, so Studio stopped. Check the store address in Settings."
            case 500...599: return "Shopify is having trouble right now (HTTP \(status)). Try again in a moment."
            default: return message.isEmpty ? "Shopify couldn’t complete that request (HTTP \(status))." : "Shopify couldn’t complete that request (HTTP \(status)): \(message)"
            }
        case .throttled:
            return "Shopify is limiting requests right now. Wait a minute, then try again."
        case .graphQL(let messages, let codes):
            if codes.contains("ACCESS_DENIED") {
                return "Shopify refused access. Check the app has the access scopes listed in Settings. \(messages.first ?? "")".trimmingCharacters(in: .whitespaces)
            }
            return "Shopify couldn’t complete that request: \(messages.first ?? "unknown error")"
        case .protectedCustomerData:
            return "Shopify didn’t share customers’ names and addresses with Studio’s app. Shopify gives them to custom apps on its Grow plan or higher; check the app’s protected customer data access in the Dev Dashboard."
        case .tokenRefused(let message):
            return message
        case .invalidResponse(let message):
            return message
        case .responseTooLarge:
            return "Shopify’s reply was larger than Studio reads, so it was ignored."
        case .transport(let message):
            return "Studio couldn’t reach Shopify: \(message)"
        }
    }
}

/// True when a mutation that failed this way may still have been carried out: no readable reply, a timeout, a
/// conflict or a server error. Throttles, auth failures, validation errors and other 4xx refusals happen before
/// Shopify acts.
func shopifyMutationOutcomeUnknown(_ error: Error) -> Bool {
    switch error as? ShopifyError {
    case .http(let status, _)?:
        return status == 408 || status == 409 || status >= 500 || (300...399).contains(status)
    case .graphQL(_, let codes)?:
        return codes.isEmpty || codes.contains("INTERNAL_SERVER_ERROR")
    case .transport?, .invalidResponse?, .responseTooLarge?:
        return true
    case .notConnected?, .throttled?, .protectedCustomerData?, .tokenRefused?:
        return false
    case nil:
        return !(error is CancellationError)
    }
}

// MARK: Throttle

/// Shopify's cost bucket as last reported in `extensions.cost.throttleStatus`.
struct ShopifyThrottleStatus: Equatable {
    var maximumAvailable: Double
    var currentlyAvailable: Double
    var restoreRate: Double
    var observedAt: Date
}

func shopifyThrottleStatus(fromResponse root: [String: Any], now: Date = Date()) -> ShopifyThrottleStatus? {
    guard let extensions = root["extensions"] as? [String: Any], let cost = extensions["cost"] as? [String: Any],
          let throttle = cost["throttleStatus"] as? [String: Any],
          let maximum = (throttle["maximumAvailable"] as? NSNumber)?.doubleValue,
          let current = (throttle["currentlyAvailable"] as? NSNumber)?.doubleValue,
          let rate = (throttle["restoreRate"] as? NSNumber)?.doubleValue,
          maximum.isFinite, current.isFinite, rate.isFinite else { return nil }
    return ShopifyThrottleStatus(maximumAvailable: max(0, maximum), currentlyAvailable: max(0, current),
                                 restoreRate: max(0, rate), observedAt: now)
}

/// The query's requested cost from `extensions.cost`, used to size the wait after a throttle.
func shopifyRequestedCost(fromResponse root: [String: Any]) -> Double? {
    guard let extensions = root["extensions"] as? [String: Any], let cost = extensions["cost"] as? [String: Any],
          let requested = (cost["requestedQueryCost"] as? NSNumber)?.doubleValue, requested.isFinite else { return nil }
    return max(0, requested)
}

/// Seconds to wait before a request costing `cost` points fits in the bucket: none when it fits (counting what has
/// refilled since the status was seen), otherwise the shortfall at the restore rate, capped. Without a status, no wait.
func shopifyThrottleWait(cost: Double, status: ShopifyThrottleStatus?, now: Date = Date(),
                         maxWait: TimeInterval = shopifyMaxThrottleWait) -> TimeInterval {
    guard let status, cost > 0 else { return 0 }
    let elapsed = max(0, now.timeIntervalSince(status.observedAt))
    let available = min(status.maximumAvailable, status.currentlyAvailable + status.restoreRate * elapsed)
    let needed = min(cost, status.maximumAvailable > 0 ? status.maximumAvailable : cost)
    guard needed > available else { return 0 }
    guard status.restoreRate > 0 else { return maxWait }
    return min(maxWait, ((needed - available) / status.restoreRate).rounded(.up))
}

// MARK: Reading replies

/// The top-level `errors` of a GraphQL reply as a ShopifyError, or nil when there are none. Any error fails the whole
/// request, even with partial data: Studio never imports half an order.
func shopifyGraphQLError(fromResponse root: [String: Any], secrets: [String] = []) -> ShopifyError? {
    guard let errors = root["errors"] else { return nil }
    let list: [[String: Any]]
    if let array = errors as? [[String: Any]] { list = array }
    else if let text = errors as? String { list = [["message": text]] }
    else { return .invalidResponse("Shopify sent an error Studio couldn’t read.") }
    guard !list.isEmpty else { return nil }
    let messages = list.map { shopifyRedacted(($0["message"] as? String) ?? "Unknown error", secrets: secrets) }
    let codes = list.compactMap { ($0["extensions"] as? [String: Any])?["code"] as? String }
    if codes.contains("THROTTLED") { return .throttled }
    // Protected customer data refusals name the object the app isn't approved for.
    if messages.contains(where: { $0.lowercased().contains("not approved to access") }) { return .protectedCustomerData }
    return .graphQL(messages: messages, codes: codes)
}

/// Seconds from a `Retry-After` header given in seconds, capped; nil when absent or unreadable.
func shopifyRetryAfterSeconds(_ raw: String?) -> TimeInterval? {
    guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { return nil }
    return min(value, shopifyMaxThrottleWait)
}

/// `grant_type=client_credentials&client_id=…&client_secret=…`, form-encoded as the grant requires.
func shopifyTokenRequestBody(clientID: String, clientSecret: String) -> Data {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")
    func encode(_ value: String) -> String { value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
    let fields = [("grant_type", "client_credentials"), ("client_id", clientID), ("client_secret", clientSecret)]
    return Data(fields.map { "\($0.0)=\(encode($0.1))" }.joined(separator: "&").utf8)
}

/// The token, its granted scopes and when to stop using it (a minute early, so a request never carries a token
/// that expires on the way). Shopify sends `expires_in` in seconds; a missing value is read as Shopify's 24 hours.
struct ShopifyAccessToken: Equatable {
    let value: String
    let scopes: Set<String>
    let expires: Date
}

func shopifyAccessToken(fromTokenResponse data: Data, now: Date = Date()) throws -> ShopifyAccessToken {
    guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let token = root["access_token"] as? String, !token.isEmpty, shopifyCredentialFieldProblem(token, name: "token") == nil else {
        throw ShopifyError.invalidResponse("Shopify didn’t return an access token.")
    }
    let lifetime = (root["expires_in"] as? NSNumber)?.doubleValue ?? 86_400
    let expires = now.addingTimeInterval(max(60, min(lifetime, 86_400 * 2)) - 60)
    return ShopifyAccessToken(value: token, scopes: shopifyScopes(root["scope"] as? String ?? ""), expires: expires)
}

/// Scopes from a comma-separated `scope` string.
func shopifyScopes(_ text: String) -> Set<String> {
    Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
}

/// The message for a refused token request. Shopify answers `shop_not_permitted` when the app and the store aren't
/// in the same organisation.
func shopifyTokenRefusalMessage(status: Int, body: String, secrets: [String]) -> String {
    let text = body.lowercased()
    if text.contains("shop_not_permitted") {
        return "Shopify won’t issue a token for this store: the app must be created in the Dev Dashboard of the organisation that owns the store, and installed on it."
    }
    if text.contains("invalid_client") || status == 401 {
        return "Shopify rejected the client ID or secret. Copy both again from the app’s Settings in the Dev Dashboard."
    }
    if status == 400, text.contains("app_not_installed") || text.contains("not installed") {
        return "The app isn’t installed on this store. Install it from the app’s page in the Dev Dashboard."
    }
    let detail = shopifyRedacted(body, secrets: secrets)
    return detail.isEmpty ? "Shopify refused the token request (HTTP \(status))." : "Shopify refused the token request (HTTP \(status)): \(detail)"
}

/// What Studio needs from the granted scopes. Write scopes include read.
struct ShopifyScopeSummary: Equatable {
    var canReadOrders: Bool
    var canFulfil: Bool
}

let shopifyFulfilmentScopes: Set<String> = [
    "write_merchant_managed_fulfillment_orders", "write_assigned_fulfillment_orders", "write_third_party_fulfillment_orders"
]

func shopifyScopeSummary(_ scopes: Set<String>) -> ShopifyScopeSummary {
    ShopifyScopeSummary(canReadOrders: scopes.contains("read_orders") || scopes.contains("write_orders"),
                        canFulfil: !scopes.isDisjoint(with: shopifyFulfilmentScopes))
}

// MARK: Client

private final class ShopifyNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Talks to one store. The token is kept in memory only and fetched again when it is about to expire.
@MainActor final class ShopifyClient {
    let shop: String
    private let credential: ShopifyCredential
    private let session: URLSession
    private var token: ShopifyAccessToken?
    private(set) var lastThrottle: ShopifyThrottleStatus?
    private var lastRequestedCost: Double?
    /// From the token reply (Dev Dashboard apps) or `currentAppInstallation` (both), once known.
    private(set) var grantedScopes: Set<String>?

    init?(shop: String, credential: ShopifyCredential) {
        guard shopifyShopDomain(shop) == shop else { return nil }
        self.shop = shop
        self.credential = credential
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = shopifyRequestTimeout
        configuration.timeoutIntervalForResource = shopifyRequestTimeout * 3
        session = URLSession(configuration: configuration, delegate: ShopifyNoRedirectDelegate(), delegateQueue: nil)
    }

    func invalidate() {
        session.invalidateAndCancel()
        token = nil
    }

    private var secrets: [String] { credential.secrets + [token?.value].compactMap { $0 } }

    /// A read-only query. A throttled read waits for the bucket and is sent again, at most three times; an expired
    /// Dev Dashboard token is fetched again once.
    func query(_ query: String, variables: [String: Any] = [:], estimatedCost: Double = 50) async throws -> [String: Any] {
        var throttles = 0
        var refreshedToken = false
        while true {
            let wait = shopifyThrottleWait(cost: estimatedCost, status: lastThrottle)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            do {
                return try await send(query, variables: variables)
            } catch ShopifyError.throttled {
                throttles += 1
                guard throttles <= shopifyMaxThrottleRetries else { throw ShopifyError.throttled }
                // The throttled reply's own requested cost is the better guide when Studio's estimate was low.
                let delay = max(1, shopifyThrottleWait(cost: max(estimatedCost, lastRequestedCost ?? 0), status: lastThrottle))
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch ShopifyError.http(let status, let message) where status == 401 {
                guard case .app = credential, !refreshedToken else { throw ShopifyError.http(status: status, message: message) }
                refreshedToken = true
                token = nil
            }
        }
    }

    /// A mutation, sent exactly once. Waits beforehand if the bucket is low, but never resends: Shopify's
    /// `fulfillmentCreate` has no idempotency key, so a second send could fulfil twice.
    func mutate(_ mutation: String, variables: [String: Any], estimatedCost: Double = 10) async throws -> [String: Any] {
        let wait = shopifyThrottleWait(cost: estimatedCost, status: lastThrottle)
        if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        // A token that would expire within five minutes is replaced first, so the mutation isn't refused part-way.
        if case .app = credential, let token, token.expires.timeIntervalSinceNow < 300 { self.token = nil }
        do {
            return try await send(mutation, variables: variables)
        } catch is CancellationError {
            // Cancelled on the way: Shopify may have acted, so it counts as unconfirmed, never as not sent.
            throw ShopifyError.transport("The request was cancelled before Shopify replied.")
        }
    }

    /// The installation's granted scopes, read once and remembered for this connection.
    func accessScopes() async throws -> Set<String> {
        if let grantedScopes { return grantedScopes }
        let data = try await query("query StudioScopes { currentAppInstallation { accessScopes { handle } } }", estimatedCost: 5)
        let scopes = shopifyInstallationScopes(data)
        grantedScopes = scopes
        return scopes
    }

    private func accessTokenValue() async throws -> String {
        switch credential {
        case .accessToken(let value):
            return value
        case .app(let clientID, let clientSecret):
            if let token, token.expires > Date() { return token.value }
            guard let url = shopifyTokenURL(shop: shop) else { throw ShopifyError.notConnected }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = shopifyTokenRequestBody(clientID: clientID, clientSecret: clientSecret)
            let (data, response) = try await Self.read(request, session: session, secrets: credential.secrets)
            guard (200..<300).contains(response.statusCode) else {
                throw ShopifyError.tokenRefused(shopifyTokenRefusalMessage(
                    status: response.statusCode, body: String(decoding: data, as: UTF8.self), secrets: credential.secrets))
            }
            let fresh = try shopifyAccessToken(fromTokenResponse: data)
            token = fresh
            if !fresh.scopes.isEmpty { grantedScopes = fresh.scopes }
            return fresh.value
        }
    }

    private func send(_ document: String, variables: [String: Any]) async throws -> [String: Any] {
        guard let url = shopifyGraphQLURL(shop: shop) else { throw ShopifyError.notConnected }
        let tokenValue = try await accessTokenValue()
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(tokenValue, forHTTPHeaderField: "X-Shopify-Access-Token")
        let body: [String: Any] = variables.isEmpty ? ["query": document] : ["query": document, "variables": variables]
        guard JSONSerialization.isValidJSONObject(body) else { throw ShopifyError.invalidResponse("Studio couldn’t build that request.") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (data, response) = try await Self.read(request, session: session, secrets: secrets)
        let status = response.statusCode
        if status == 429 {
            if let seconds = shopifyRetryAfterSeconds(response.value(forHTTPHeaderField: "Retry-After")) {
                lastThrottle = ShopifyThrottleStatus(maximumAvailable: 1, currentlyAvailable: 0, restoreRate: 1 / max(seconds, 1), observedAt: Date())
            }
            throw ShopifyError.throttled
        }
        guard (200..<300).contains(status) else {
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let message = root.flatMap { shopifyGraphQLError(fromResponse: $0, secrets: secrets)?.errorDescription }
                ?? (root?["errors"] as? String).map { shopifyRedacted($0, secrets: secrets) } ?? ""
            throw ShopifyError.http(status: status, message: shopifyRedacted(message, secrets: secrets))
        }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ShopifyError.invalidResponse("Shopify’s reply couldn’t be read.")
        }
        if let throttle = shopifyThrottleStatus(fromResponse: root) { lastThrottle = throttle }
        lastRequestedCost = shopifyRequestedCost(fromResponse: root)
        if let error = shopifyGraphQLError(fromResponse: root, secrets: secrets) { throw error }
        guard let payload = root["data"] as? [String: Any] else { throw ShopifyError.invalidResponse("Shopify’s reply had no data.") }
        return payload
    }

    /// Sends the request and reads at most `shopifyMaxResponseBytes`. Transport failures are reported without the URL
    /// query or headers. Off the main actor, as the reply is read a byte at a time.
    nonisolated private static func read(_ request: URLRequest, session: URLSession, secrets: [String]) async throws -> (Data, HTTPURLResponse) {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ShopifyError.invalidResponse("Shopify returned a non-HTTP response.") }
            if http.expectedContentLength > Int64(shopifyMaxResponseBytes) { throw ShopifyError.responseTooLarge }
            var data = Data()
            data.reserveCapacity(Int(max(0, min(http.expectedContentLength, Int64(shopifyMaxResponseBytes)))))
            for try await byte in bytes {
                data.append(byte)
                if data.count > shopifyMaxResponseBytes { throw ShopifyError.responseTooLarge }
            }
            return (data, http)
        } catch let error as ShopifyError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ShopifyError.transport(shopifyRedacted(error.localizedDescription, secrets: secrets))
        }
    }
}

/// Scope handles from `currentAppInstallation { accessScopes { handle } }`.
func shopifyInstallationScopes(_ data: [String: Any]) -> Set<String> {
    guard let installation = data["currentAppInstallation"] as? [String: Any],
          let list = installation["accessScopes"] as? [[String: Any]] else { return [] }
    return Set(list.compactMap { ($0["handle"] as? String)?.lowercased() })
}

// MARK: Connection state

/// The app-wide Shopify connection. Only the shop address (the seller's own store, no customer data) is kept in
/// preferences, so Studio can show whether Shopify is set up without reading the Keychain; the credentials are read
/// from the Keychain only when a Shopify request is about to be made.
@MainActor final class ShopifyConnection: ObservableObject {
    static let shared = ShopifyConnection()
    static let shopDefaultsKey = "shopifyShopDomain"

    @Published private(set) var shop: String?
    /// A Shopify request is running (Test Connection, an import fetch or tracking checks and sends).
    @Published var busy = false
    private var client: ShopifyClient?
    /// Tracking sends whose outcome wasn't confirmed this session, by Slant order ID. Memory only.
    @Published var unconfirmedTrackingSends: [String: Date] = [:]

    private init() {
        shop = UserDefaults.standard.string(forKey: Self.shopDefaultsKey).flatMap(shopifyShopDomain)
    }

    var isConfigured: Bool { shop != nil }

    /// The client for the saved connection, reading the Keychain the first time.
    func currentClient() throws -> ShopifyClient {
        if let client { return client }
        guard let shop, let stored = try ShopifyKeychainStore.load(), stored.shop == shop,
              let credential = stored.credential, let client = ShopifyClient(shop: shop, credential: credential) else {
            throw ShopifyError.notConnected
        }
        self.client = client
        return client
    }

    /// Saves a connection that has just passed Test Connection, replacing any other.
    func save(shop: String, credential: ShopifyCredential, client: ShopifyClient) throws {
        try ShopifyKeychainStore.save(ShopifyStoredConnection(shop: shop, credential: credential))
        UserDefaults.standard.set(shop, forKey: Self.shopDefaultsKey)
        self.client?.invalidate()
        self.client = client
        self.shop = shop
    }

    /// Deletes the Keychain item and forgets the shop and token.
    func disconnect() throws {
        try ShopifyKeychainStore.delete()
        UserDefaults.standard.removeObject(forKey: Self.shopDefaultsKey)
        client?.invalidate()
        client = nil
        shop = nil
    }
}

/// What Test Connection found.
struct ShopifyConnectionTest: Equatable {
    var shopName: String
    var scopes: ShopifyScopeSummary
}

let shopifyTestQuery = "query StudioShop { shop { name myshopifyDomain } currentAppInstallation { accessScopes { handle } } }"

/// Reads Test Connection's reply. The store must be the one the seller typed.
func shopifyConnectionTest(_ data: [String: Any], expectedShop: String) throws -> ShopifyConnectionTest {
    guard let shop = data["shop"] as? [String: Any], let domain = shop["myshopifyDomain"] as? String else {
        throw ShopifyError.invalidResponse("Shopify didn’t describe the store.")
    }
    guard domain.lowercased() == expectedShop.lowercased() else {
        throw ShopifyError.invalidResponse("Shopify answered for a different store (\(domain)).")
    }
    let name = ((shop["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return ShopifyConnectionTest(shopName: name.isEmpty ? domain : name, scopes: shopifyScopeSummary(shopifyInstallationScopes(data)))
}
