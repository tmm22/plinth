import Foundation

// 3DAPI (dapi.digital) HTTP client: price comparison only (an upload, a quote, reads and a shipping estimate). It never
// orders or pays. See docs/3DAPI_REFERENCE.md for the contract and DapiTypes.swift for the shared types.
//
// Rules this file keeps:
// - Every API request goes to `https://` + `dapiAPIHost` under `/v2/`, and only those requests carry `x-api-key` and
//   `User-Agent: Plinth/…`. The presigned storage PUT carries neither, nor cookies.
// - Redirects are never followed: a 3xx comes back as it is and counts as a failure.
// - Nothing is retried. Each method sends each request at most once (the paged list sends one request per page).
// - Every 3DAPI text that reaches the seller passes `dapiRedacted`.

// MARK: Limits

/// Largest API reply Plinth reads; a list page of 100 quotes is far smaller.
let dapiMaxResponseBytes = 2_000_000
/// Largest reply Plinth reads from the storage PUT (normally empty).
let dapiMaxStorageResponseBytes = 64 * 1024
/// Idle timeout for API calls, and the whole-call limit.
let dapiAPIRequestTimeout: TimeInterval = 30
let dapiAPIResourceTimeout: TimeInterval = 60
/// Idle timeout for the storage PUT; its whole-call limit grows with the file (`dapiUploadResourceTimeout`).
let dapiUploadIdleTimeout: TimeInterval = 60
/// The longest Plinth waits after a 429, whatever 3DAPI says.
let dapiMaxRetryWait: TimeInterval = 3600
/// Longest 3DAPI ID Plinth puts in a path (real ones are about 36 characters).
let dapiMaxIDLength = 128
/// Longest 3DAPI message Plinth shows.
let dapiMaxMessageLength = 300
/// Longest failure reason Plinth shows for a failed quote (3DAPI's explanations can run to a few sentences).
let dapiMaxFailureReasonLength = 600
/// Pages `quotes(named:maxPages:)` may read.
let dapiQuoteListPageLimit = 1...10
/// The formats Plinth quotes, for copy.
let dapiQuotableFormatsText = "Plinth can quote STL, OBJ and 3MF models."

/// The content type Plinth declares for a quote file with this extension, or nil for one Plinth doesn't quote (3DAPI
/// also takes STEP, but Plinth's library holds only STL, OBJ and 3MF). `createUpload` sends only this pairing, because
/// 3DAPI refuses a `content_type` that doesn't match the file name's extension.
func dapiQuoteFileContentType(forExtension fileExtension: String) -> String? {
    switch fileExtension.lowercased() {
    case "stl": return "model/stl"
    case "3mf": return "model/3mf"
    case "obj": return "model/obj"
    default: return nil
    }
}

/// The storage PUT's whole-call limit: two minutes plus 200 kB/s, between 5 minutes and an hour (250 MiB ≈ 24 min).
func dapiUploadResourceTimeout(bytes: Int64) -> TimeInterval {
    min(3600, max(300, 120 + Double(max(bytes, 0)) / 200_000))
}

// MARK: IDs, URLs and headers

/// A 3DAPI ID safe to put in a path: `prefix` then ASCII letters and digits only (`^qte_[0-9A-Za-z]+$`), bounded.
func dapiIDIsSafe(_ id: String, prefix: String) -> Bool {
    guard id.hasPrefix(prefix), id.utf8.count > prefix.utf8.count, id.utf8.count <= dapiMaxIDLength else { return false }
    return id.utf8.dropFirst(prefix.utf8.count).allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) }
}
func dapiQuoteIDIsSafe(_ id: String) -> Bool { dapiIDIsSafe(id, prefix: "qte_") }
func dapiUploadIDIsSafe(_ id: String) -> Bool { dapiIDIsSafe(id, prefix: "upl_") }

/// Percent-encodes everything but RFC 3986's unreserved characters, so a cursor can't add or split a query item.
private let dapiQueryValueAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// An API URL: https, `dapiAPIHost` exactly, a path under `/v2/` made only of safe segments, and a strictly encoded
/// query in the order given. Nil for anything else.
func dapiAPIURL(path: String, query: [(String, String)] = []) -> URL? {
    guard path.hasPrefix("/v2/"), path.utf8.count <= 200 else { return nil }
    let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
    guard segments.allSatisfy({ segment in
        !segment.isEmpty && segment != "." && segment != ".."
            && segment.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x5F || $0 == 0x2D }
    }) else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = dapiAPIHost
    components.path = path
    if !query.isEmpty {
        var parts: [String] = []
        for (name, value) in query {
            guard let encodedName = name.addingPercentEncoding(withAllowedCharacters: dapiQueryValueAllowed),
                  let encodedValue = value.addingPercentEncoding(withAllowedCharacters: dapiQueryValueAllowed) else { return nil }
            parts.append("\(encodedName)=\(encodedValue)")
        }
        components.percentEncodedQuery = parts.joined(separator: "&")
    }
    guard let url = components.url, url.host == dapiAPIHost, url.scheme == "https" else { return nil }
    return url
}

/// Printable ASCII without spaces (0x21–0x7E): what a header value made by Plinth may hold.
private func dapiIsPrintableToken(_ text: String) -> Bool {
    !text.isEmpty && text.unicodeScalars.allSatisfy { $0.value >= 0x21 && $0.value <= 0x7E }
}

/// Why the key can't be sent as a header, or nil. Empty is handled separately (`.missingKey`).
func dapiKeyHeaderProblem(_ key: String) -> String? {
    guard dapiIsPrintableToken(key), key.utf8.count <= 512 else {
        return "The saved 3DAPI key has spaces or characters a key never has. Copy it again from the 3DAPI dashboard and save it in Settings."
    }
    return nil
}

/// An `Idempotency-Key` 3DAPI accepts (1–255 characters) that is also safe as a header value.
func dapiIdempotencyKeyIsValid(_ key: String) -> Bool {
    dapiIsPrintableToken(key) && key.utf8.count <= 255
}

/// Why Plinth won't PUT a file to this presigned `upload_url`, or nil. It must be https to a named host (not an IP
/// literal, a single-label name or a local one) on the default port, with no user name, password or fragment, and
/// it must not contain the key.
func dapiUploadURLProblem(_ url: URL, apiKey: String = "") -> String? {
    guard url.scheme?.lowercased() == "https" else { return "it isn’t a secure (https) link" }
    guard let rawHost = url.host, !rawHost.isEmpty else { return "it has no host" }
    let host = rawHost.lowercased()
    guard url.user == nil, url.password == nil else { return "it carries sign-in details" }
    guard url.fragment == nil else { return "it is an unusual link" }
    if let port = url.port, port != 443 { return "it uses an unusual port" }
    let labels = host.split(separator: ".", omittingEmptySubsequences: false)
    if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || host.hasSuffix(".internal")
        || imageTo3DHostIsIPLiteral(host) || labels.count < 2 || labels.contains(where: \.isEmpty)
        || (labels.last?.allSatisfy(\.isNumber) ?? true) || host.contains("%") {
        return "it points to a local or numeric address"
    }
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.count >= 4, url.absoluteString.contains(key) { return "it contains your API key" }
    return nil
}

/// Header names never copied from 3DAPI's upload reply onto the storage PUT: credentials, cookies, and the headers
/// URLSession itself controls (host, length, framing, connection) or that change where the request goes.
let dapiUploadHeaderDenylist: Set<String> = [
    "authorization", "proxy-authorization", "cookie", "cookie2", "set-cookie", "x-api-key", "host", "content-length",
    "transfer-encoding", "connection", "keep-alive", "upgrade", "te", "trailer", "expect", "user-agent", "origin",
    "referer", "forwarded", "via", "idempotency-key", "x-forwarded-for", "x-forwarded-host", "x-forwarded-proto"
]

/// The headers from 3DAPI's upload reply that the storage PUT may carry: token names (letters, digits, `-`) that are
/// not on the denylist and don't start with `proxy-` or `sec-`, values of printable characters without line breaks,
/// never one containing the key, at most 32 headers. Everything else is dropped. Storage refuses a PUT missing a
/// header it signed, which ends as a definite refusal rather than a leak. Values are printable ASCII only.
func dapiSafeUploadHeaders(_ raw: Any?, apiKey: String = "") -> [String: String] {
    guard let pairs = raw as? [String: Any] else { return [:] }
    let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
    var headers: [String: String] = [:]
    for name in pairs.keys.sorted() {
        guard headers.count < 32, let value = pairs[name] as? String else { continue }
        let lower = name.lowercased()
        guard !name.isEmpty, name.utf8.count <= 64,
              name.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x2D }),
              !dapiUploadHeaderDenylist.contains(lower), !lower.hasPrefix("proxy-"), !lower.hasPrefix("sec-"),
              value.utf8.count <= 4096, value.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }),
              !(key.count >= 4 && value.contains(key)),
              !headers.keys.contains(where: { $0.lowercased() == lower }) else { continue }
        headers[name] = value
    }
    return headers
}

// MARK: Rate limits

/// When a 429 may be tried again: `Retry-After` in seconds (0 or more), else `X-RateLimit-Reset` in Unix SECONDS (a
/// value in the past, or one so large it must be milliseconds, is ignored). Never more than an hour ahead.
func dapiRetryAt(retryAfter: String?, rateLimitReset: String?, now: Date = Date()) -> Date? {
    let latest = now.addingTimeInterval(dapiMaxRetryWait)
    if let text = retryAfter?.trimmingCharacters(in: .whitespacesAndNewlines), let seconds = Double(text),
       seconds.isFinite, seconds >= 0 {
        return min(now.addingTimeInterval(seconds), latest)
    }
    if let text = rateLimitReset?.trimmingCharacters(in: .whitespacesAndNewlines), let seconds = Double(text),
       seconds.isFinite, seconds > 0, seconds < 100_000_000_000 {
        let reset = Date(timeIntervalSince1970: seconds)
        guard reset > now else { return nil }
        return min(reset, latest)
    }
    return nil
}

// MARK: Redaction

/// Text safe to show or record: everything `aiServiceRedacted` masks (the given secrets, Bearer tokens, `x-api-key`
/// values and other services' keys), plus 3DAPI keys (`sk_…`), the query and fragment of every URL (signed storage
/// links carry their signature there) and signature-like query parameters on their own. One line, capped.
func dapiRedacted(_ text: String, secrets: [String] = [], limit: Int = dapiMaxMessageLength) -> String {
    var result = text
    for secret in secrets.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where secret.count >= 4 {
        result = result.replacingOccurrences(of: secret, with: "[redacted]")
    }
    let patterns: [(String, String)] = [
        (#"(?i)\b((?:https?|wss?)://[^\s?#"'<>]+)[?#][^\s"'<>]*"#, "$1?[redacted]"),
        (#"(?<![A-Za-z0-9])sk_[A-Za-z0-9]+"#, "[redacted]"),
        (#"(?i)\b(x-amz-[a-z0-9-]+|signature|sig|token|access_token|key|googleaccessid|policy|se|sp|sv|sr)=[^\s&"'<>]+"#, "$1=[redacted]")
    ]
    for (pattern, replacement) in patterns {
        result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return aiServiceRedacted(result, secrets: secrets, limit: limit)
}

// MARK: Parsing

/// An integer from JSON: a number (not a boolean) with no fractional part, within ±2^53.
func dapiJSONInt(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, double == double.rounded(.towardZero), abs(double) <= 9_007_199_254_740_992 else { return nil }
    return Int(double)
}

private func dapiJSONBool(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
    return number.boolValue
}

/// A short display string from JSON: trimmed, control characters removed, capped; nil when empty or not a string.
func dapiDisplayText(_ value: Any?, limit: Int = 120) -> String? {
    guard let text = value as? String else { return nil }
    let cleaned = String(String.UnicodeScalarView(text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }))
        .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return cleaned.count > limit ? String(cleaned.prefix(limit)) : cleaned
}

/// A lower-cased enum-like word (status, kind, tier) as sent, or nil.
private func dapiWord(_ value: Any?) -> String? { dapiDisplayText(value, limit: 64)?.lowercased() }

/// `{amount: int, currency}`: the amount must be a whole, non-negative number and the currency three ASCII letters
/// (lower-cased). Anything else is nil, never a guessed price.
func dapiMoney(_ value: Any?) -> DapiMoney? {
    guard let object = value as? [String: Any], let amount = dapiJSONInt(object["amount"]), amount >= 0,
          let currency = (object["currency"] as? String)?.lowercased(), currency.utf8.count == 3,
          currency.utf8.allSatisfy({ (0x61...0x7A).contains($0) }) else { return nil }
    return DapiMoney(amountMinor: amount, currency: currency)
}

private let dapiDateFractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
private let dapiDatePlain = Date.ISO8601FormatStyle()

/// An ISO 8601 UTC time, with or without fractional seconds; nil otherwise.
func dapiDate(_ value: Any?) -> Date? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= 64 else { return nil }
    return (try? dapiDateFractional.parse(text)) ?? (try? dapiDatePlain.parse(text))
}

/// `GET /v2/me`. Nil without a `kind`.
func dapiParseAccount(_ json: [String: Any]) -> DapiAccount? {
    guard let kind = dapiWord(json["kind"]) else { return nil }
    let scopes = (json["effective_scopes"] as? [Any] ?? []).compactMap { dapiDisplayText($0, limit: 64) }
    return DapiAccount(kind: kind, approval: dapiWord(json["approval"]), effectiveScopes: Array(scopes.prefix(64)))
}

/// `GET /v2/integrator/onboarding`. Nil unless the status, both file counts, `uploads.used` and an `uploads.limit`
/// (a number, or null for unlimited) are all there: a missing limit must never read as unlimited.
func dapiParseOnboarding(_ json: [String: Any]) -> DapiOnboarding? {
    guard let status = dapiWord(json["status"]),
          let approved = dapiJSONInt(json["approved_files"]), approved >= 0,
          let required = dapiJSONInt(json["required_files"]), required >= 0,
          let uploads = json["uploads"] as? [String: Any],
          let used = dapiJSONInt(uploads["used"]), used >= 0,
          let rawLimit = uploads["limit"] else { return nil }
    let limit: Int?
    if rawLimit is NSNull {
        limit = nil
    } else {
        guard let value = dapiJSONInt(rawLimit), value >= 0 else { return nil }
        limit = value
    }
    return DapiOnboarding(status: status, approvedFiles: approved, requiredFiles: required, uploadsUsed: used, uploadsLimit: limit)
}

/// A quote object. Nil without a valid `qte_` ID or a status. A missing or odd price, material or date is nil; the
/// failure reason is redacted and capped.
func dapiParseQuote(_ json: [String: Any], secrets: [String] = []) -> DapiQuote? {
    guard let id = json["id"] as? String, dapiQuoteIDIsSafe(id), let status = dapiWord(json["status"]) else { return nil }
    let materials: [DapiSuggestedMaterial] = (json["suggested_materials"] as? [Any] ?? []).prefix(32).compactMap { entry in
        guard let object = entry as? [String: Any], let slot = dapiJSONInt(object["slot"]), slot >= 0 else { return nil }
        let material = object["material"] as? [String: Any]
        return DapiSuggestedMaterial(slot: slot, materialName: dapiDisplayText(material?["name"]),
                                     fileFilamentType: dapiDisplayText(object["file_filament_type"], limit: 40),
                                     match: dapiWord(object["match"]))
    }
    let failure = (json["failure_reason"] as? String).map { dapiRedacted($0, secrets: secrets, limit: dapiMaxFailureReasonLength) }
        .flatMap { $0.isEmpty ? nil : $0 }
    let approval = dapiWord((json["approval"] as? [String: Any])?["status"])
    return DapiQuote(id: id, name: json["name"] as? String, status: status, price: dapiMoney(json["price"]),
                     failureReason: failure, suggestedMaterials: materials, createdAt: dapiDate(json["created_at"]),
                     approvalStatus: approval)
}

/// `POST /v2/integrator/orders/shipping-estimate`. Nil without a readable total.
func dapiParseShippingEstimate(_ json: [String: Any], requestedCountry: String) -> DapiShippingEstimate? {
    guard let total = dapiMoney(json["total"]) else { return nil }
    let country = (json["country_code"] as? String).flatMap { code -> String? in
        let upper = code.uppercased()
        return upper.utf8.count == 2 && upper.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) ? upper : nil
    } ?? requestedCountry
    let zone = json["zone"] as? [String: Any]
    return DapiShippingEstimate(countryCode: country, zoneName: dapiDisplayText(zone?["name"], limit: 60),
                                tier: dapiWord(json["tier"]), total: total)
}

/// 3DAPI's error body: its stable `code` (only `[a-z0-9_]`, ≤ 64, so it is safe in Activity) and its `message`,
/// redacted. Nil when the body isn't a JSON object.
func dapiErrorBody(_ data: Data, secrets: [String] = []) -> (code: String?, message: String?)? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let code = (json["code"] as? String).flatMap { text -> String? in
        text.utf8.count <= 64 && !text.isEmpty && text.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }) ? text : nil
    }
    let message = (json["message"] as? String).map { dapiRedacted($0, secrets: secrets) }.flatMap { $0.isEmpty ? nil : $0 }
    return (code, message)
}

// MARK: Transport

/// One HTTP reply, its body already capped by the transport.
struct DapiHTTPReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// Transport failures that aren't a `URLError`.
enum DapiTransportError: Error, Equatable {
    /// The reply was larger than the cap, so it wasn't read.
    case responseTooLarge
    /// The reply wasn't HTTP.
    case notHTTP
}

/// How the client reaches the network; tests substitute a scripted one. Neither call follows a redirect (a 3xx comes
/// back as the reply) or retries. Failures are thrown as `URLError` (unchanged, so the client can tell failures before
/// sending from the rest), `DapiTransportError` or `CancellationError`.
protocol DapiTransport: Sendable {
    /// Sends one JSON API request and reads at most `dapiMaxResponseBytes` of the reply.
    func send(_ request: URLRequest) async throws -> DapiHTTPReply
    /// PUTs the file's bytes, streamed from disk, to a presigned storage URL, reading at most
    /// `dapiMaxStorageResponseBytes` of the reply. The request carries no credentials or cookies.
    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> DapiHTTPReply
}

/// Ephemeral, with no cookies, cache or stored credentials.
func dapiSessionConfiguration(requestTimeout: TimeInterval, resourceTimeout: TimeInterval) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.httpCookieAcceptPolicy = .never
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpAdditionalHeaders = nil
    configuration.waitsForConnectivity = false
    configuration.timeoutIntervalForRequest = requestTimeout
    configuration.timeoutIntervalForResource = resourceTimeout
    return configuration
}

private final class DapiNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// The real network. API calls share one session; each storage PUT gets its own, with a time limit for its size.
final class URLSessionDapiTransport: DapiTransport, @unchecked Sendable {
    static let shared = URLSessionDapiTransport()

    private let session: URLSession

    init() {
        session = URLSession(configuration: dapiSessionConfiguration(requestTimeout: dapiAPIRequestTimeout, resourceTimeout: dapiAPIResourceTimeout),
                             delegate: DapiNoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> DapiHTTPReply {
        try await DapiCappedTask(maxBytes: dapiMaxResponseBytes).run { session.dataTask(with: request) }
    }

    func upload(_ request: URLRequest, fromFile fileURL: URL) async throws -> DapiHTTPReply {
        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? dapiMaxQuoteFileBytes
        let configuration = dapiSessionConfiguration(requestTimeout: dapiUploadIdleTimeout, resourceTimeout: dapiUploadResourceTimeout(bytes: size))
        let uploadSession = URLSession(configuration: configuration, delegate: DapiNoRedirectDelegate(), delegateQueue: nil)
        defer { uploadSession.finishTasksAndInvalidate() }
        return try await DapiCappedTask(maxBytes: dapiMaxStorageResponseBytes).run { uploadSession.uploadTask(with: request, fromFile: fileURL) }
    }
}

/// One request as a task delegate: the reply's `Content-Length` and running total are checked against `maxBytes`,
/// redirects are refused (the 3xx is the reply), and a Swift task cancellation cancels the URL task.
private final class DapiCappedTask: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var data = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var continuation: CheckedContinuation<DapiHTTPReply, Error>?
    private var task: URLSessionTask?

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    func run(_ makeTask: () -> URLSessionTask) async throws -> DapiHTTPReply {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<DapiHTTPReply, Error>) in
                lock.lock()
                self.continuation = continuation
                let task = makeTask()
                task.delegate = self
                self.task = task
                lock.unlock()
                // A cancellation that arrived before `task` was stored found nothing to cancel.
                if Task.isCancelled { task.cancel() } else { task.resume() }
            }
        } onCancel: {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }
    }

    private func fail(_ error: Error, task: URLSessionTask) {
        lock.lock()
        if failure == nil { failure = error }
        lock.unlock()
        task.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(DapiTransportError.notHTTP, task: dataTask)
            completionHandler(.cancel)
            return
        }
        guard http.expectedContentLength <= Int64(maxBytes) else {
            fail(DapiTransportError.responseTooLarge, task: dataTask)
            completionHandler(.cancel)
            return
        }
        lock.lock()
        self.response = http
        lock.unlock()
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        let stopped = failure != nil
        if !stopped { self.data.append(data) }
        let over = self.data.count > maxBytes
        lock.unlock()
        if !stopped, over { fail(DapiTransportError.responseTooLarge, task: dataTask) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let recorded = failure
        // A refused redirect ends with the 3xx as the reply; fall back to the task's own response if it wasn't delivered.
        let response = self.response ?? (task.response as? HTTPURLResponse)
        let body = data
        lock.unlock()
        guard let continuation else { return }
        if let recorded {
            continuation.resume(throwing: recorded)
        } else if let urlError = error as? URLError, urlError.code == .cancelled {
            continuation.resume(throwing: CancellationError())
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            var headers: [String: String] = [:]
            for (key, value) in response.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            continuation.resume(returning: DapiHTTPReply(status: response.statusCode, headers: headers, body: body))
        } else {
            continuation.resume(throwing: DapiTransportError.notHTTP)
        }
    }
}

// MARK: Outcome classification

/// URL failures that certainly happened before any of the request left the Mac. Mirrors
/// `orderMutationURLErrorIsBeforeSending`: a local URL refusal always; a host-name failure only for a POST, because
/// URLSession may resend an idempotent GET or PUT on a fresh connection after a reused one drops, so a DNS failure on
/// that resend wouldn't prove the first attempt never left. No connection, a refused or lost connection, a timeout and
/// TLS failures may all follow a send, so they are not proof.
func dapiURLErrorIsBeforeSending(_ code: URLError.Code, method: String) -> Bool {
    switch code {
    case .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection:
        return true
    case .cannotFindHost, .dnsLookupFailed:
        return method.uppercased() == "POST"
    default:
        return false
    }
}

/// The plain reason for a transport failure, for the seller.
func dapiTransportFailureReason(_ error: Error) -> String {
    if let transport = error as? DapiTransportError {
        switch transport {
        case .responseTooLarge: return "3DAPI’s reply was too large to read"
        case .notHTTP: return "3DAPI’s reply wasn’t a web reply Plinth could read"
        }
    }
    guard let urlError = error as? URLError else { return "The connection to 3DAPI failed" }
    switch urlError.code {
    case .timedOut: return "3DAPI didn’t answer in time"
    case .notConnectedToInternet: return "This Mac isn’t connected to the internet"
    case .cannotFindHost, .dnsLookupFailed: return "Plinth couldn’t find 3DAPI’s server"
    case .cannotConnectToHost: return "Plinth couldn’t connect to 3DAPI"
    case .networkConnectionLost: return "The connection to 3DAPI dropped"
    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateNotYetValid,
         .serverCertificateHasUnknownRoot, .clientCertificateRejected, .clientCertificateRequired:
        return "A secure connection to 3DAPI couldn’t be made"
    case .badURL, .unsupportedURL, .appTransportSecurityRequiresSecureConnection: return "The request’s address was refused on this Mac"
    case .cannotOpenFile, .fileDoesNotExist, .noPermissionsToReadFile: return "Plinth couldn’t read the model file"
    default: return "The connection to 3DAPI failed"
    }
}

/// The requests the client makes, and what each one's failure means.
enum DapiOperation: Sendable {
    case account, onboarding, listQuotes, createUpload, storagePut, createQuote, getQuote, shippingEstimate

    /// Writes whose failure after sending leaves the outcome unknown. The shipping estimate is a POST that creates
    /// nothing, so it is classed with reads.
    var isWrite: Bool {
        switch self {
        case .createUpload, .storagePut, .createQuote: return true
        default: return false
        }
    }

    var method: String {
        switch self {
        case .account, .onboarding, .listQuotes, .getQuote: return "GET"
        case .createUpload, .createQuote, .shippingEstimate: return "POST"
        case .storagePut: return "PUT"
        }
    }

    /// What a failed read couldn't read.
    var readObject: String {
        switch self {
        case .account: return "your 3DAPI account"
        case .onboarding: return "your 3DAPI onboarding progress"
        case .listQuotes: return "your 3DAPI quotes"
        case .getQuote: return "the 3DAPI quote"
        case .shippingEstimate: return "3DAPI’s shipping estimate"
        case .createUpload, .storagePut, .createQuote: return "3DAPI’s reply"
        }
    }

    /// What an unknown write outcome means for the seller. Plinth never sends it again by itself.
    var unknownConsequence: String {
        switch self {
        case .createUpload:
            return "Plinth can’t tell whether 3DAPI reserved the upload, and didn’t send it again. Nothing was charged; 3DAPI deletes an unused upload after 24 hours."
        case .storagePut:
            return "Plinth can’t tell whether the model reached 3DAPI’s storage, and didn’t send it again. No quote was requested and nothing was charged; 3DAPI deletes an unused upload after 24 hours."
        case .createQuote:
            return "Plinth can’t tell whether 3DAPI created the quote, and didn’t send it again. Look for it before quoting again: before approval each quote counts towards your allowance."
        default:
            return "Plinth didn’t send it again."
        }
    }
}

/// The error for a transport failure of `operation`.
func dapiClassifyTransportFailure(_ error: Error, operation: DapiOperation) -> Error {
    if error is CancellationError { return error }
    if let urlError = error as? URLError, urlError.code == .cancelled { return CancellationError() }
    let reason = dapiTransportFailureReason(error)
    if let urlError = error as? URLError, dapiURLErrorIsBeforeSending(urlError.code, method: operation.method) {
        return DapiError.notSent("\(reason), so nothing was sent. Check your connection, then try again.")
    }
    if operation.isWrite { return DapiError.outcomeUnknown("\(reason). \(operation.unknownConsequence)") }
    return DapiError.readFailed("\(reason), so Plinth couldn’t read \(operation.readObject). Try again.")
}

/// The error for a reply that isn't a success, or for a 2xx Plinth couldn't read (`unreadable2xx`).
/// - 429: `.rateLimited`, with `retryAt` from `dapiRetryAt`.
/// - Any other 4xx but 408, with a JSON body (or any 4xx from storage, whose bodies aren't 3DAPI's): `.refused`.
/// - 408, 3xx, 5xx, other statuses, a 4xx without a readable body, or an unreadable 2xx: `.outcomeUnknown` for a
///   write, `.readFailed` otherwise.
func dapiClassifyReply(_ reply: DapiHTTPReply, operation: DapiOperation, secrets: [String] = [], now: Date = Date(),
                       unreadable2xx: Bool = false) -> DapiError {
    let status = reply.status
    let isStorage = operation == .storagePut
    let body = isStorage ? nil : dapiErrorBody(reply.body, secrets: secrets)
    if status == 429 {
        return .rateLimited(code: body?.code,
                            retryAt: dapiRetryAt(retryAfter: reply.header("Retry-After"), rateLimitReset: reply.header("X-RateLimit-Reset"), now: now))
    }
    if (400..<500).contains(status), status != 408 {
        if isStorage { return .refused(status: status, code: nil, message: nil) }
        if let body { return .refused(status: status, code: body.code, message: body.message) }
    }
    let reason: String
    switch status {
    case 200..<300 where unreadable2xx: reason = "Plinth couldn’t read 3DAPI’s reply"
    case 300..<400: reason = "3DAPI answered with a redirect (HTTP \(status)), which Plinth doesn’t follow"
    case 408: reason = "3DAPI timed out (HTTP 408)"
    case 500..<600: reason = "3DAPI had a server problem (HTTP \(status))"
    default: reason = "3DAPI sent a reply Plinth couldn’t read (HTTP \(status))"
    }
    if operation.isWrite { return .outcomeUnknown("\(reason). \(operation.unknownConsequence)") }
    return .readFailed("\(reason), so Plinth couldn’t read \(operation.readObject). Try again.")
}

// MARK: Client

/// The 3DAPI client for one key. See the file header for the rules it keeps.
struct DapiClient: DapiQuoting {
    let apiKey: String
    private let transport: any DapiTransport

    init(apiKey: String) {
        self.init(apiKey: apiKey, transport: URLSessionDapiTransport.shared)
    }

    init(apiKey: String, transport: any DapiTransport) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    private var secrets: [String] { [apiKey] }

    // MARK: Requests

    /// An API request to `dapiAPIHost`: the key, `Accept`, Plinth's `User-Agent`, a JSON body when given and an
    /// `Idempotency-Key` when given. Throws `.missingKey` or `.notSent` before anything is sent.
    func makeAPIRequest(method: String, path: String, query: [(String, String)] = [], body: [String: Any]? = nil,
                        idempotencyKey: String? = nil) throws -> URLRequest {
        guard !apiKey.isEmpty else { throw DapiError.missingKey }
        if let problem = dapiKeyHeaderProblem(apiKey) { throw DapiError.notSent(problem) }
        guard let url = dapiAPIURL(path: path, query: query), url.host == dapiAPIHost else {
            throw DapiError.notSent("Plinth couldn’t build a safe 3DAPI address for this request, so nothing was sent.")
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: dapiAPIRequestTimeout)
        request.httpMethod = method
        request.httpShouldHandleCookies = false
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(plinthUserAgent, forHTTPHeaderField: "User-Agent")
        if let idempotencyKey {
            guard dapiIdempotencyKeyIsValid(idempotencyKey) else {
                throw DapiError.notSent("Plinth couldn’t make a safe request ID for 3DAPI, so nothing was sent. Try again.")
            }
            request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        }
        if let body {
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
                throw DapiError.notSent("Plinth couldn’t build the request for 3DAPI, so nothing was sent.")
            }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    /// Sends one API request once and returns its JSON object, or throws the classified error.
    private func perform(_ request: URLRequest, _ operation: DapiOperation) async throws -> [String: Any] {
        try Task.checkCancellation()
        let reply: DapiHTTPReply
        do {
            reply = try await transport.send(request)
        } catch {
            throw dapiClassifyTransportFailure(error, operation: operation)
        }
        guard (200..<300).contains(reply.status) else {
            throw dapiClassifyReply(reply, operation: operation, secrets: secrets)
        }
        guard let json = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any] else {
            throw dapiClassifyReply(reply, operation: operation, secrets: secrets, unreadable2xx: true)
        }
        return json
    }

    /// A 2xx whose content Plinth couldn't use.
    private func unreadable(_ operation: DapiOperation) -> DapiError {
        dapiClassifyReply(DapiHTTPReply(status: 200, headers: [:], body: Data()), operation: operation, unreadable2xx: true)
    }

    // MARK: DapiQuoting

    func account() async throws -> DapiAccount {
        let json = try await perform(try makeAPIRequest(method: "GET", path: "/v2/me"), .account)
        guard let account = dapiParseAccount(json) else { throw unreadable(.account) }
        return account
    }

    func onboarding() async throws -> DapiOnboarding {
        let json = try await perform(try makeAPIRequest(method: "GET", path: "/v2/integrator/onboarding"), .onboarding)
        guard let onboarding = dapiParseOnboarding(json) else { throw unreadable(.onboarding) }
        return onboarding
    }

    /// Reads pages of 100 newest first, following `next_cursor` while `has_more`, for at most `maxPages` (clamped to
    /// 1…10) pages. Any page failing fails the whole lookup, and so does `has_more` with a missing, unusable or repeated
    /// cursor: a partial answer could hide a quote and lead to a duplicate create. An entry Plinth can't read is
    /// skipped, unless its name is the one asked for, which fails the lookup as unreadable.
    func quotes(named name: String, maxPages: Int) async throws -> [DapiQuote] {
        guard !name.isEmpty else { throw DapiError.notSent("A quote name is needed to look for existing quotes.") }
        let pages = min(max(maxPages, dapiQuoteListPageLimit.lowerBound), dapiQuoteListPageLimit.upperBound)
        var matches: [DapiQuote] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        for _ in 0..<pages {
            var query: [(String, String)] = [("limit", "100")]
            if let cursor { query.append(("cursor", cursor)) }
            let json = try await perform(try makeAPIRequest(method: "GET", path: "/v2/quotes", query: query), .listQuotes)
            guard let data = json["data"] as? [Any] else { throw unreadable(.listQuotes) }
            for entry in data {
                guard let object = entry as? [String: Any] else { continue }
                guard let quote = dapiParseQuote(object, secrets: secrets) else {
                    if (object["name"] as? String) == name { throw unreadable(.listQuotes) }
                    continue
                }
                if quote.name == name { matches.append(quote) }
            }
            guard dapiJSONBool(json["has_more"]) == true else { break }
            guard let next = json["next_cursor"] as? String, !next.isEmpty, next.utf8.count <= 2048,
                  !seenCursors.contains(next) else { throw unreadable(.listQuotes) }
            seenCursors.insert(next)
            cursor = next
        }
        return matches
    }

    func createUpload(fileName: String, contentType: String, sizeBytes: Int64, idempotencyKey: String) async throws -> DapiUploadTarget {
        // Local checks, before anything is sent.
        guard !fileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, fileName.utf16.count <= 255,
              fileName.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw DapiError.notSent("The model’s file name can’t be sent to 3DAPI (it must be 1 to 255 characters), so nothing was sent.")
        }
        guard let expectedType = dapiQuoteFileContentType(forExtension: (fileName as NSString).pathExtension) else {
            throw DapiError.notSent("\(dapiQuotableFormatsText) Nothing was sent.")
        }
        let type = contentType.trimmingCharacters(in: .whitespaces).lowercased()
        guard type == expectedType else {
            throw DapiError.notSent("The file’s type doesn’t match its extension, which 3DAPI refuses, so nothing was sent.")
        }
        guard sizeBytes >= 1 else { throw DapiError.notSent("The model file is empty, so nothing was sent.") }
        guard sizeBytes <= dapiMaxQuoteFileBytes else {
            throw DapiError.notSent("This model is larger than 3DAPI’s 250 MB limit for quotes, so nothing was sent.")
        }
        let body: [String: Any] = ["purpose": "quote_file", "file_name": fileName, "content_type": type, "size_bytes": sizeBytes]
        let request = try makeAPIRequest(method: "POST", path: "/v2/uploads", body: body, idempotencyKey: idempotencyKey)

        let json = try await perform(request, .createUpload)
        guard let uploadID = json["id"] as? String, dapiUploadIDIsSafe(uploadID),
              let urlText = json["upload_url"] as? String, urlText.utf8.count <= 8192,
              let method = json["method"] as? String else {
            throw unreadable(.createUpload)
        }
        // From here an upload record exists on 3DAPI. It holds no bytes until the PUT, can't become a quote without
        // them, costs nothing and is deleted after 24 hours. When Plinth refuses to send the bytes, nothing was sent
        // anywhere that matters, so the refusal is `.notSent` (see docs/3DAPI_REFERENCE.md §2.1).
        guard let uploadURL = URL(string: urlText) else {
            throw DapiError.notSent("3DAPI gave an upload link Plinth couldn’t read, so the model wasn’t sent. Nothing was charged; 3DAPI deletes the unused upload after 24 hours.")
        }
        if let problem = dapiUploadURLProblem(uploadURL, apiKey: apiKey) {
            throw DapiError.notSent("3DAPI gave an upload link Plinth won’t use (\(problem)), so the model wasn’t sent. Nothing was charged; 3DAPI deletes the unused upload after 24 hours.")
        }
        guard method.trimmingCharacters(in: .whitespaces).uppercased() == "PUT" else {
            throw DapiError.notSent("3DAPI asked for an upload method Plinth doesn’t use, so the model wasn’t sent. Nothing was charged; 3DAPI deletes the unused upload after 24 hours.")
        }
        return DapiUploadTarget(uploadID: uploadID, uploadURL: uploadURL, headers: dapiSafeUploadHeaders(json["headers"], apiKey: apiKey),
                                contentType: type, sizeBytes: sizeBytes)
    }

    func sendUploadBytes(_ target: DapiUploadTarget, fileURL: URL) async throws {
        // The same checks again, in case the target didn't come from `createUpload`.
        if let problem = dapiUploadURLProblem(target.uploadURL, apiKey: apiKey) {
            throw DapiError.notSent("Plinth won’t use this upload link (\(problem)), so the model wasn’t sent. Nothing was charged; 3DAPI deletes the unused upload after 24 hours.")
        }
        // The file must still be the size 3DAPI was told, right before the bytes go.
        guard (try? quoteFileSize(fileURL)) == target.sizeBytes else {
            throw DapiError.notSent("The model file changed after Get Quote was pressed, so it wasn’t sent. Press Get Quote to upload it again.")
        }
        var put = URLRequest(url: target.uploadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: dapiUploadIdleTimeout)
        put.httpMethod = "PUT"
        put.httpShouldHandleCookies = false
        for (name, value) in dapiSafeUploadHeaders(target.headers, apiKey: apiKey) { put.setValue(value, forHTTPHeaderField: name) }
        // Without a Content-Type from 3DAPI, send the one it was told, so URLSession doesn't pick its own.
        if put.value(forHTTPHeaderField: "Content-Type") == nil { put.setValue(target.contentType, forHTTPHeaderField: "Content-Type") }

        try Task.checkCancellation()
        let reply: DapiHTTPReply
        do {
            reply = try await transport.upload(put, fromFile: fileURL)
        } catch {
            throw dapiClassifyTransportFailure(error, operation: .storagePut)
        }
        guard (200..<300).contains(reply.status) else {
            throw dapiClassifyReply(reply, operation: .storagePut, secrets: secrets)
        }
    }

    /// The size of a readable regular file, within 1…`dapiMaxQuoteFileBytes`; `.notSent` otherwise.
    private func quoteFileSize(_ fileURL: URL) throws -> Int64 {
        guard fileURL.isFileURL,
              let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize,
              FileManager.default.isReadableFile(atPath: fileURL.path) else {
            throw DapiError.notSent("Plinth couldn’t read the model file, so nothing was sent.")
        }
        guard size >= 1 else { throw DapiError.notSent("The model file is empty, so nothing was sent.") }
        guard Int64(size) <= dapiMaxQuoteFileBytes else {
            throw DapiError.notSent("This model is larger than 3DAPI’s 250 MB limit for quotes, so nothing was sent.")
        }
        return Int64(size)
    }

    func createQuote(uploadID: String, name: String, idempotencyKey: String) async throws -> DapiQuote {
        guard dapiUploadIDIsSafe(uploadID) else {
            throw DapiError.notSent("The upload ID isn’t one 3DAPI issues, so nothing was sent.")
        }
        guard !name.isEmpty, name.utf16.count <= 200,
              name.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else {
            throw DapiError.notSent("The quote name must be 1 to 200 characters, so nothing was sent.")
        }
        let request = try makeAPIRequest(method: "POST", path: "/v2/quotes", body: ["file": ["upload": uploadID], "name": name],
                                         idempotencyKey: idempotencyKey)
        let json = try await perform(request, .createQuote)
        guard let quote = dapiParseQuote(json, secrets: secrets) else { throw unreadable(.createQuote) }
        return quote
    }

    func quote(id: String) async throws -> DapiQuote {
        guard dapiQuoteIDIsSafe(id) else { throw DapiError.notSent("The quote ID isn’t one 3DAPI issues, so nothing was sent.") }
        let json = try await perform(try makeAPIRequest(method: "GET", path: "/v2/quotes/\(id)"), .getQuote)
        guard let quote = dapiParseQuote(json, secrets: secrets) else { throw unreadable(.getQuote) }
        return quote
    }

    func shippingEstimate(quoteID: String, quantity: Int, countryCode: String) async throws -> DapiShippingEstimate {
        guard dapiQuoteIDIsSafe(quoteID) else { throw DapiError.notSent("The quote ID isn’t one 3DAPI issues, so nothing was sent.") }
        guard (1...10_000).contains(quantity) else {
            throw DapiError.notSent("3DAPI estimates shipping for 1 to 10,000 units, so nothing was sent.")
        }
        let country = countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard country.utf8.count == 2, country.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) else {
            throw DapiError.notSent("Choose a delivery country first, so 3DAPI can estimate shipping.")
        }
        let body: [String: Any] = ["country": country, "items": [["quote": quoteID, "quantity": quantity]]]
        let json = try await perform(try makeAPIRequest(method: "POST", path: "/v2/integrator/orders/shipping-estimate", body: body),
                                     .shippingEstimate)
        guard let estimate = dapiParseShippingEstimate(json, requestedCountry: country) else { throw unreadable(.shippingEstimate) }
        return estimate
    }
}

// MARK: Copy

extension DapiError {
    /// Plain text for the seller. 3DAPI's own message appears only where Plinth has no copy for its code, redacted.
    var userMessage: String { userMessage(now: Date()) }

    func userMessage(now: Date) -> String {
        switch self {
        case .missingKey:
            return "Add your 3DAPI API key in Settings first."
        case .notSent(let detail), .outcomeUnknown(let detail), .readFailed(let detail):
            return dapiRedacted(detail, limit: 600)
        case .rateLimited(let code, let retryAt):
            if code == "daily_quote_limit_reached" {
                return "You’ve reached 3DAPI’s daily quote limit for accounts awaiting approval. It resets at midnight UTC."
            }
            guard let retryAt else { return "3DAPI is limiting requests for a moment. Try again shortly." }
            let minutes = Int((max(0, retryAt.timeIntervalSince(now)) / 60).rounded(.up))
            if minutes <= 1 { return "3DAPI is limiting requests for a moment. Try again in a minute." }
            return "3DAPI is limiting requests for a moment. Try again in about \(minutes) minutes."
        case .refused(let status, let code, let message):
            return dapiRefusalMessage(status: status, code: code, message: message)
        }
    }

    /// Status only, for Activity: never a key, URL, file name, price or ID.
    var activityDetail: String {
        switch self {
        case .missingKey: return "No key"
        case .notSent: return "Not sent"
        case .refused(let status, let code, _):
            if let code, dapiErrorCodeIsSafe(code) { return "HTTP \(status) \(code)" }
            return "HTTP \(status)"
        case .rateLimited(let code, _):
            return code == "daily_quote_limit_reached" ? "Daily quote limit reached" : "Rate limited"
        case .outcomeUnknown: return "Outcome unknown"
        case .readFailed: return "Read failed"
        }
    }
}

/// A 3DAPI error code fit for Activity: `[a-z0-9_]`, at most 64 characters.
func dapiErrorCodeIsSafe(_ code: String) -> Bool {
    !code.isEmpty && code.utf8.count <= 64 && code.utf8.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
}

/// The seller's text for a definite refusal, by 3DAPI's stable code; 3DAPI's redacted message otherwise.
func dapiRefusalMessage(status: Int, code: String?, message: String?) -> String {
    let quoted = message.map { dapiRedacted($0) }.flatMap { $0.isEmpty ? nil : $0 }
    switch code {
    case "missing_credentials", "invalid_api_key", "invalid_session", "ambiguous_credentials":
        return "3DAPI didn’t accept the API key. Check it in Settings, or create a new key in the 3DAPI dashboard."
    case "missing_scope":
        return "This 3DAPI key doesn’t have the permission this needs. Create a key with the quotes:read, quotes:write and orders:read scopes."
    case "actor_not_allowed", "purpose_not_allowed":
        return dapiDesignerKeyMessage
    case "credential_not_allowed":
        return "3DAPI allows this only from its dashboard, not with an API key."
    case "account_blacklisted":
        return "3DAPI says this account may no longer use its API. Contact 3DAPI."
    case "file_type_not_allowed":
        return "3DAPI didn’t accept this file type. \(dapiQuotableFormatsText)"
    case "file_too_large":
        return "This model is larger than 3DAPI’s 250 MB limit for quotes."
    case "invalid_file":
        return "3DAPI couldn’t read the file as the model type its name says. Export it again, then try again."
    case "unknown_upload", "upload_missing", "upload_purpose_mismatch":
        return "3DAPI couldn’t find the uploaded model. Press Get Quote to upload it again."
    case "upload_expired":
        return "The upload expired before the quote was requested (3DAPI keeps uploads for 24 hours). Press Get Quote to upload it again."
    case "upload_already_used":
        return "3DAPI has already used this upload for another quote. Press Get Quote to upload it again."
    case "upload_limit_reached":
        return "You’ve used the 25 quotes of this 3DAPI onboarding round. Submit files for approval in the 3DAPI dashboard to continue."
    case "approval_in_review":
        return "3DAPI pauses new quotes while it reviews your approval request. Try again once the review is done."
    case "daily_quote_limit_reached":
        return "You’ve reached 3DAPI’s daily quote limit for accounts awaiting approval. It resets at midnight UTC."
    case "quote_not_found":
        return "3DAPI has no quote with that ID for this account."
    case "quote_not_ready":
        return "The 3DAPI quote isn’t ready yet, so shipping can’t be estimated."
    case "quote_rejected":
        return "3DAPI rejected this file in review, so it can’t estimate shipping for it."
    case "shipping_destination_not_served":
        return "3DAPI doesn’t deliver to that country. It delivers worldwide except Russia, Belarus, Iran and Syria."
    case "shipping_zone_not_found":
        return "3DAPI has no shipping rate for that country at the moment."
    case "validation_failed":
        return quoted.map { "3DAPI said the request wasn’t valid: \($0)" } ?? "3DAPI said the request wasn’t valid."
    case "idempotency_key_reused":
        return "3DAPI refused a repeated request that differed from the first. Start again."
    case "rate_limited":
        return "3DAPI is limiting requests for a moment. Try again shortly."
    default:
        return quoted.map { "3DAPI refused the request (HTTP \(status)): \($0)" } ?? "3DAPI refused the request (HTTP \(status))."
    }
}
