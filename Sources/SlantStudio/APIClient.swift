import Foundation
import Security

struct RateLimitInfo: Equatable {
    var limit: Int?
    var remaining: Int?
    var reset: Date?
    var role: String?
    /// False when the response carried no rate-limit headers, so it says nothing about the current allowance.
    var hasValues: Bool { limit != nil || remaining != nil || reset != nil || role != nil }
}

struct APIResponse {
    let data: Data
    let statusCode: Int
    let contentType: String?
    let headers: [String: String]

    init(data: Data, statusCode: Int, contentType: String? = nil, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.contentType = contentType
        self.headers = headers
    }

    var json: Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
    var pretty: String {
        if let json, let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let text = String(data: formatted, encoding: .utf8) { return text }
        return String(data: data, encoding: .utf8) ?? "\(data.count) bytes returned"
    }

    var rateLimit: RateLimitInfo {
        rateLimitInfo(from: headers)
    }
}

func rateLimitInfo(from headers: [String: String]) -> RateLimitInfo {
    func value(_ names: String...) -> String? {
        for name in names {
            if let match = headers.first(where: { $0.key.lowercased() == name.lowercased() })?.value, !match.isEmpty {
                return match
            }
        }
        return nil
    }
    let limit = value("X-RateLimit-Limit").flatMap(Int.init)
    let remaining = value("X-RateLimit-Remaining").flatMap(Int.init)
    let role = value("X-RateLimit-Role")
    let reset: Date?
    if let raw = value("X-RateLimit-Reset"), let seconds = TimeInterval(raw) {
        reset = Date(timeIntervalSince1970: seconds)
    } else {
        reset = nil
    }
    return RateLimitInfo(limit: limit, remaining: remaining, reset: reset, role: role)
}

enum APIError: LocalizedError {
    case invalidRequest(String)
    case invalidResponse(String)
    case http(status: Int, body: String, retryAfter: String?, rateLimitReset: String?)
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidRequest(let message), .invalidResponse(let message): return message
        case .http(let status, let body, let retryAfter, _):
            let retry = retryAfter.map { "\nRetry-After: \($0)" } ?? ""
            return "HTTP \(status): \(body.isEmpty ? HTTPURLResponse.localizedString(forStatusCode: status) : body)\(retry)"
        case .keychain(let status):
            return "Keychain: \((SecCopyErrorMessageString(status, nil) as String?) ?? String(status))"
        }
    }

    /// One-sentence UI copy. Keep `errorDescription` for diagnostics only (may include bodies).
    var userMessage: String {
        switch self {
        case .invalidRequest(let message):
            let line = message.split(separator: "\n").first.map(String.init) ?? message
            return line.count > 180 ? "Slant couldn’t complete that request. Try again." : line
        case .invalidResponse:
            return "Slant couldn’t complete that request. Try again."
        case .http(let status, let body, let retryAfter, let rateLimitReset):
            switch status {
            case 401:
                return "Slant rejected the saved key. Reconnect in Connection."
            case 403:
                if let message = shortAPIMessage(from: body) {
                    return "Slant refused this request. \(message)"
                }
                return "You don’t have access to that item. It may belong to another API key."
            case 404:
                return "That item wasn’t found. Refresh and try again."
            case 400, 409, 422:
                if let message = shortAPIMessage(from: body) {
                    return "Slant couldn’t accept those details. \(message)"
                }
                return "Slant couldn’t accept those details."
            case 429:
                return rateLimitUserMessage(retryAfter: retryAfter, rateLimitReset: rateLimitReset)
            case 500...599:
                return "Slant is having trouble right now. Try again in a moment."
            default:
                return "Slant couldn’t complete that request. The details are in Activity."
            }
        case .keychain:
            return "Slant Studio couldn’t read the saved key. Enter it again."
        }
    }

    var activityDetail: String {
        switch self {
        case .http(let status, let body, _, _):
            let base: String
            switch status {
            case 401: base = "Slant rejected the saved key. Reconnect in Connection."
            case 403: base = "You don’t have access to that item. It may belong to another API key."
            case 404: base = "That item wasn’t found. Refresh and try again."
            case 400, 409, 422:
                if let message = shortAPIMessage(from: body) {
                    base = "Slant couldn’t accept those details. \(message)"
                } else {
                    base = "Slant couldn’t accept those details."
                }
            case 429: base = "Too many requests. Wait a moment, then try again."
            case 500...599: base = "Slant is having trouble right now. Try again in a moment."
            default: base = "Slant couldn’t complete that request."
            }
            return "\(base) (HTTP \(status))"
        default:
            return userMessage
        }
    }
}

func rateLimitUserMessage(retryAfter: String?, rateLimitReset: String?) -> String {
    if let retryAfter, !retryAfter.isEmpty {
        return "Too many requests. Wait \(retryAfter), then try again."
    }
    if let rateLimitReset, let seconds = TimeInterval(rateLimitReset) {
        let delay = max(0, seconds - Date().timeIntervalSince1970)
        return "Too many requests. \(rateLimitResetWaitCopy(secondsFromNow: delay))"
    }
    return "Too many requests. Wait a moment, then try again."
}

func rateLimitResetWaitCopy(secondsFromNow delay: TimeInterval) -> String {
    if delay < 90 {
        let seconds = max(1, Int(delay.rounded()))
        return "Try again in about \(seconds) seconds."
    }
    let minutes = max(1, Int((delay / 60).rounded()))
    return "Try again in about \(minutes) minutes."
}

func shortAPIMessage(from body: String) -> String? {
    guard let data = body.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let candidates: [Any?] = [
        json["message"],
        (json["error"] as? [String: Any])?["message"],
        json["error"]
    ]
    for candidate in candidates {
        guard let text = candidate as? String else { continue }
        if let clipped = clippedAPIAlertMessage(text) { return clipped }
    }
    return nil
}

func clippedAPIAlertMessage(_ text: String) -> String? {
    var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return nil }
    if let nl = trimmed.firstIndex(of: "\n") {
        trimmed = String(trimmed[..<nl]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !trimmed.isEmpty, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") else { return nil }
    if trimmed.count > 240 {
        trimmed = String(trimmed.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

func isRetryableAPICall(method: String, path: String) -> Bool {
    let method = method.uppercased()
    let path = path.split(separator: "?").first.map(String.init) ?? path
    if method == "DELETE" { return false }
    if method == "GET" { return true }
    if method == "POST" {
        if path.hasSuffix("/estimate") { return true }
        return false
    }
    return false
}

/// File type for direct-upload: omit for STL so the known-good request stays unchanged.
func uploadTypeParameter(forFileExtension ext: String) -> String? {
    switch ext.lowercased() {
    case "obj": return "obj"
    case "3mf": return "3mf"
    default: return nil
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct APIClient {
    let apiKey: String
    private let session: URLSession

    init(apiKey: String, configuration: URLSessionConfiguration = .ephemeral) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 1800
        self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    /// Tear down the underlying session when the store rotates keys.
    func invalidate() {
        session.invalidateAndCancel()
    }

    func request(_ method: String, path: String, query: [String: String] = [:], body: Any? = nil) async throws -> APIResponse {
        guard (path == "/health/status" || !apiKey.isEmpty), !apiKey.contains("\r"), !apiKey.contains("\n") else {
            throw APIError.invalidRequest("Connect your account in Connection first.")
        }
        guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              let decodedPath = path.removingPercentEncoding, !decodedPath.contains("\\"),
              !decodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw APIError.invalidRequest("Use an API path beginning with / and supply query parameters separately.")
        }
        let prefix = path == "/slant/webhook" ? "/v2" : "/v2/api"
        guard var components = URLComponents(string: "https://slant3dapi.com" + prefix + path) else {
            throw APIError.invalidRequest("Invalid API path.")
        }
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        guard let url = components.url else { throw APIError.invalidRequest("Invalid API URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        request.setValue(path == "/files/openScad" ? "application/sla, application/json" : "application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard JSONSerialization.isValidJSONObject(body) else { throw APIError.invalidRequest("The request body must be a JSON object or array.") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let result = try checked(data: data, response: response)
        if path == "/files/openScad" {
            guard !data.isEmpty else { throw APIError.invalidResponse("OpenSCAD returned an empty model.") }
            guard result.json == nil, !(result.contentType?.lowercased().contains("json") ?? false) else {
                throw APIError.invalidResponse("OpenSCAD returned JSON instead of STL model bytes:\n\(result.pretty)")
            }
        }
        return result
    }

    func upload(file: URL, name: String, platformId: String, ownerId: String,
                stage: @escaping @Sendable (String) -> Void) async throws -> APIResponse {
        guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else {
            throw APIError.invalidRequest("Select a readable local model file.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !platformId.isEmpty else {
            throw APIError.invalidRequest("Choose a model name and a platform first.")
        }
        stage("Preparing upload…")
        var body: [String: Any] = ["name": name, "platformId": platformId]
        if !ownerId.isEmpty { body["ownerId"] = ownerId }
        if let type = uploadTypeParameter(forFileExtension: file.pathExtension) {
            body["type"] = type
        }
        let prepared = try await request("POST", path: "/files/direct-upload", body: body)
        guard let root = prepared.json as? [String: Any], let payload = root["data"] as? [String: Any],
              let urlString = payload["presignedUrl"] as? String,
              let url = URL(string: urlString), url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty, url.user == nil, url.password == nil, url.fragment == nil,
              let placeholder = payload["filePlaceholder"] as? [String: Any] else {
            throw APIError.invalidResponse("Slant didn’t accept the upload. Try again with a secure HTTPS link.")
        }
        try Task.checkCancellation()
        stage("Uploading model…")
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: put, fromFile: file)
        _ = try checked(data: data, response: response)
        try Task.checkCancellation()
        stage("Confirming upload and processing model…")
        return try await request("POST", path: "/files/confirm-upload", body: ["filePlaceholder": placeholder])
    }

    func downloadModel(from url: URL) async throws -> URL {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw APIError.invalidResponse("Slant didn’t return a secure HTTPS download link. Try again.")
        }
        let (temporaryURL, response) = try await session.download(from: url)
        do {
            _ = try checked(data: Data(), response: response)
            return temporaryURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func checked(data: Data, response: URLResponse) throws -> APIResponse {
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse("The server returned a non-HTTP response.") }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let result = APIResponse(data: data, statusCode: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"), headers: headers)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.http(
                status: response.statusCode,
                body: result.pretty,
                retryAfter: response.value(forHTTPHeaderField: "Retry-After"),
                rateLimitReset: response.value(forHTTPHeaderField: "X-RateLimit-Reset")
            )
        }
        if let envelope = result.json as? [String: Any], let success = envelope["success"] as? NSNumber,
           CFGetTypeID(success) == CFBooleanGetTypeID(), !success.boolValue {
            throw APIError.invalidResponse("The API reported a failure (HTTP \(response.statusCode)):\n\(result.pretty)")
        }
        return result
    }
}

enum KeychainStore {
    private static let service = "SlantStudio"
    private static let account = "api-key"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    static func load() throws -> String {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return "" }
        guard status == errSecSuccess else { throw APIError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse("The saved API key could not be decoded.")
        }
        return value
    }

    static func save(_ key: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { try delete(); return }
        let values: [String: Any] = [kSecValueData as String: Data(normalized.utf8)]
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
