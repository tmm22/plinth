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
    /// The Slant API path the reply answers (`APIClient.request`), or nil (storage PUTs, downloads, hand-made replies).
    let requestPath: String?

    init(data: Data, statusCode: Int, contentType: String? = nil, headers: [String: String] = [:], requestPath: String? = nil) {
        self.data = data
        self.statusCode = statusCode
        self.contentType = contentType
        self.headers = headers
        self.requestPath = requestPath
    }

    var json: Any? { try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) }
    var pretty: String {
        if let json, let formatted = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]),
           let text = String(data: formatted, encoding: .utf8) { return text }
        return String(data: data, encoding: .utf8) ?? "\(data.count) bytes returned"
    }

    /// The per-minute allowance this reply reports, for the shared figure (`StudioStore.rateLimit`) and the paced
    /// batches. Always empty for `POST /files/openScad` (`slantReplyRateLimitIsShared`).
    var rateLimit: RateLimitInfo {
        slantReplyRateLimitIsShared(path: requestPath) ? rateLimitInfo(from: headers) : RateLimitInfo()
    }
}

/// False for `/files/openScad`: Slant's docs show its replies carrying OpenSCAD's own limiter (`X-RateLimit-Limit: 5`,
/// an hour), and "4 of 5 left" in the shared figure would stop every paced read for up to an hour. OpenSCAD keeps its
/// own allowance (`OpenSCADQuota`). Compared ignoring case and trailing slashes, as a hand-typed Workbench path may be.
func slantReplyRateLimitIsShared(path: String?) -> Bool {
    guard var normalized = path?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return true }
    while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
    return normalized != "/files/openscad"
}

/// When Slant's `X-RateLimit-Reset` says requests may resume. Live responses (observed 23 Oct 2026) send epoch
/// **milliseconds** (`1800000685873` = 08:11:25 UTC, 60 s after a request that opened a quiet minute). At other times
/// it was only seconds ahead while Remaining stayed low, so it may mark when the oldest counted request leaves a sliding
/// window rather than when the whole allowance returns; which reading is right is unresolved (docs/API_REFERENCE.md).
/// Callers re-check the allowance after waiting, and a 429 waits at least a minute (`comparisonRateLimitedUntil`).
/// Epoch seconds are tolerated too, and a small number (up to an hour) is read as seconds from now. Negative,
/// non-finite or unparseable values, and times more than a day away (an unknown unit), give nil.
func rateLimitResetDate(_ raw: String?, now: Date) -> Date? {
    guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
          let value = Double(text), value.isFinite, value >= 0 else { return nil }
    let date: Date
    if value >= 1e11 {
        date = Date(timeIntervalSince1970: value / 1000)
    } else if value >= 1e9 {
        date = Date(timeIntervalSince1970: value)
    } else {
        // Slant's windows are a minute (OpenSCAD an hour); a larger relative value is probably another unit.
        guard value <= 3600 else { return nil }
        date = now.addingTimeInterval(value)
    }
    guard date.timeIntervalSince(now) <= rateLimitResetMaxLead else { return nil }
    return date
}

/// The latest reset `rateLimitResetDate` accepts. Slant's limits are per minute (OpenSCAD per hour).
let rateLimitResetMaxLead: TimeInterval = 24 * 3600

func rateLimitInfo(from headers: [String: String], now: Date = Date()) -> RateLimitInfo {
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
    let reset = rateLimitResetDate(value("X-RateLimit-Reset"), now: now)
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
        case .invalidResponse(let message):
            // A 2xx with `success: false` stays an unknown outcome; only the wording quotes what Slant said.
            if let reported = slantReportedFailureMessage(message) { return "Slant reported a problem: \(reported)" }
            return "Slant couldn’t complete that request. Try again."
        case .http(let status, let body, let retryAfter, let rateLimitReset):
            switch status {
            case 401:
                return unauthorizedUserMessage(body: body)
            case 403:
                if let message = shortAPIMessage(from: body) {
                    return "Slant refused this request. \(message)"
                }
                return "You don’t have access to that item. It may belong to another API key."
            case 404:
                return "That item wasn’t found. Refresh and try again."
            case 409:
                return conflictUserMessage(body: body)
            case 400, 422:
                if let message = shortAPIMessage(from: body) {
                    return "Slant couldn’t accept those details. \(message)"
                }
                return "Slant couldn’t accept those details."
            case 429:
                return rateLimitUserMessage(retryAfter: retryAfter, rateLimitReset: rateLimitReset)
            case 500...599:
                return "Slant is having trouble right now. Try again in a moment."
            default:
                return slantRequestFailedSeeActivityMessage
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
            case 401: base = unauthorizedUserMessage(body: body)
            case 403: base = "You don’t have access to that item. It may belong to another API key."
            case 404: base = "That item wasn’t found. Refresh and try again."
            case 409: base = conflictUserMessage(body: body)
            case 400, 422:
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

/// The start of the diagnostic text `APIClient.checked` throws for a 2xx whose envelope says `success: false`.
let slantReportedFailurePrefix = "The API reported a failure (HTTP "

/// Slant's own message from a 2xx `success: false` reply (the text after the diagnostic line), or nil for any other
/// invalid response. Clipped like other API messages; JSON-looking messages are dropped.
func slantReportedFailureMessage(_ diagnostic: String) -> String? {
    guard diagnostic.hasPrefix(slantReportedFailurePrefix),
          let newline = diagnostic.firstIndex(of: "\n") else { return nil }
    return shortAPIMessage(from: String(diagnostic[diagnostic.index(after: newline)...]))
}

/// A 401 isn't always a bad key: Slant also answers 401 for an order or file that belongs to another creator. Only a
/// missing message, or one about the bearer token, key or authorisation, says to reconnect.
func unauthorizedUserMessage(body: String) -> String {
    guard let message = shortAPIMessage(from: body), !unauthorizedMessageIsAboutKey(message) else {
        return "Slant rejected the saved key. Reconnect in Settings."
    }
    return "Slant refused this request. \(message)"
}

/// True when a 401 message is about the credentials themselves (Slant's live reply: "Bearer token required in
/// Authorization header").
func unauthorizedMessageIsAboutKey(_ message: String) -> Bool {
    let lowered = message.lowercased()
    return ["token", "key", "authoriz", "authoris", "authent", "credential", "bearer", "sign in", "log in", "login"]
        .contains { lowered.contains($0) }
}

/// A 409 to a write leaves its outcome unknown in Studio, so the copy doesn't say the details were refused.
func conflictUserMessage(body: String) -> String {
    let advice = "Refresh to see the current state before trying again."
    guard let message = shortAPIMessage(from: body) else { return "Slant reported a conflict. \(advice)" }
    let sentence = message.last.map { ".!?".contains($0) } == true ? message : message + "."
    return "Slant reported a conflict: “\(sentence)” \(advice)"
}

func rateLimitUserMessage(retryAfter: String?, rateLimitReset: String?, now: Date = Date()) -> String {
    if let seconds = retryAfterSeconds(retryAfter) {
        return "Too many requests. \(rateLimitResetWaitCopy(secondsFromNow: seconds))"
    }
    if let reset = rateLimitResetDate(rateLimitReset, now: now), reset > now {
        return "Too many requests. \(rateLimitResetWaitCopy(secondsFromNow: reset.timeIntervalSince(now)))"
    }
    return "Too many requests. Wait a moment, then try again."
}

/// `Retry-After` as a number of seconds. Slant documents no `Retry-After`; an HTTP date or anything else isn't read.
/// Negative, non-finite and more-than-a-day values give nil, so the caller falls back to the reset header.
func retryAfterSeconds(_ raw: String?) -> TimeInterval? {
    guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
          text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
          let value = Double(text), value.isFinite, value >= 0, value <= rateLimitResetMaxLead else { return nil }
    return value
}

func rateLimitResetWaitCopy(secondsFromNow delay: TimeInterval) -> String {
    if delay < 90 {
        let seconds = max(1, Int(delay.rounded()))
        return seconds == 1 ? "Try again in about 1 second." : "Try again in about \(seconds) seconds."
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
    trimmed = apiMessageRedactingCredentials(trimmed)
    if trimmed.count > 240 {
        trimmed = String(trimmed.prefix(240)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return trimmed
}

/// Slant's quoted messages reach alerts and Activity, so anything shaped like a credential is masked first: a bearer
/// value, or a Slant key: `sl-…`, the form live keys and Slant's 401 use, or `sl_…`, the form Slant's OpenAPI security
/// scheme names. Messages that are about the key itself aren't quoted at all (`APIError.userMessage`).
func apiMessageRedactingCredentials(_ text: String) -> String {
    var result = text
    for (pattern, replacement) in [(#"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]{12,}"#, "Bearer …"), (#"\b(sl[-_])[A-Za-z0-9_\-]{6,}"#, "$1…")] {
        result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    return result
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

/// The Slant API URL for `path` (already checked by `APIClient.request`) and its query, sorted by name. `+` is
/// percent-encoded as well: URLComponents leaves it as is, and Slant's server reads a bare `+` as a space (a time
/// zone such as `+10:00` would arrive as ` 10:00`).
func slantAPIURL(path: String, query: [String: String]) -> URL? {
    let prefix = path == "/slant/webhook" ? "/v2" : "/v2/api"
    guard var components = URLComponents(string: "https://slant3dapi.com" + prefix + path) else { return nil }
    if !query.isEmpty {
        components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
    }
    return components.url
}

/// `User-Agent` for Slant API requests only: `Plinth/<version> (macOS <version>)`. A missing or odd bundle
/// version reads "dev" (as in `swift test` and `swift run`).
func slantUserAgent(appVersion: String?, os: OperatingSystemVersion) -> String {
    let trimmed = appVersion?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let allowed = !trimmed.isEmpty && trimmed.count <= 32
        && trimmed.unicodeScalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || ".-+_".unicodeScalars.contains($0)) }
    let version = allowed ? trimmed : "dev"
    let macOS = os.patchVersion > 0
        ? "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        : "\(os.majorVersion).\(os.minorVersion)"
    return "Plinth/\(version) (macOS \(macOS))"
}

let slantStudioUserAgent = slantUserAgent(
    appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
    os: ProcessInfo.processInfo.operatingSystemVersion
)

/// The step of `APIClient.upload` that was running.
enum UploadStage: Equatable, Sendable {
    /// `POST /files/direct-upload`: asks Slant for an upload link. Nothing is stored yet.
    case preparing
    /// The PUT to the presigned storage link (not Slant's API, no key).
    case uploading
    /// `POST /files/confirm-upload`: Slant adds the file to the account.
    case confirming

    var progressText: String {
        switch self {
        case .preparing: return "Preparing upload…"
        case .uploading: return "Uploading model…"
        case .confirming: return "Confirming upload and processing model…"
        }
    }
}

let uploadLinkMissingMessage = "Slant didn’t return a usable upload link, so nothing was uploaded. Try again."

/// After a confirm whose outcome is unknown. Slant doesn't let a standard key delete files, so a blind second upload
/// could leave a duplicate the seller can't remove.
let uploadUnconfirmedMessage = "Slant didn’t confirm the upload, so it may already be in your Slant files. Refresh and look for it there: if it’s listed, select it to estimate and order. If not, use Upload Again…"

/// A confirm reply (2xx) without a file ID: Slant may still have added the file.
struct UploadConfirmMissingFileID: LocalizedError {
    var errorDescription: String? { "Slant didn’t return the uploaded file’s ID." }
}

/// True when an upload failed at a point where Slant may have kept the file: during or after `confirm-upload`, other
/// than a definite refusal (a 4xx other than 408/409, or a failure before sending). Earlier steps store nothing.
func uploadOutcomeUnknown(stage: UploadStage?, error: Error) -> Bool {
    guard stage == .confirming else { return false }
    return !orderMutationErrorProvesNoEffect(error)
}

/// Replace File reuses the existing Slant file (Slant keeps one file per owner and name, 30 Oct 2026), so once the
/// storage PUT may have started, that file's contents may have changed whatever happened next: a failed PUT, a confirm
/// whose outcome is unknown, and even a definite refusal at confirm (the PUT had already succeeded and the bytes may be
/// stored under the file's key). A failure while asking for the link (`.preparing`, including the pre-PUT guard,
/// `UploadWouldOverwriteExistingFile`) sent no bytes. `replacingFileID` is the file the seller chose to replace (blank
/// when neither the listed record nor Slant's placeholder named its ID); nil for an upload that isn't a Replace File.
func uploadReplacementMayBePartial(stage: UploadStage?, replacingFileID: String?) -> Bool {
    guard replacingFileID != nil else { return false }
    switch stage {
    case .uploading?, .confirming?: return true
    case .preparing?, nil: return false
    }
}

/// The failure copy after a Replace File that stopped once the PUT may have started. `fileName` is the replaced Slant
/// file; `modelName` the model being uploaded (nil for Upload from URL); `otherModelNames` the other library models
/// that were linked to that file. Every one of them has lost its link and must be uploaded again before ordering.
func uploadReplacementPartialMessage(fileName: String, modelName: String?, otherModelNames: [String]) -> String {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let file = trimmed.isEmpty ? "the existing file in your Slant files" : "your Slant file “\(trimmed)”"
    var text = "The upload stopped partway, so \(file) may now hold part of this model, for every draft that uses it."
    if let modelName {
        text += " “\(modelName)” is no longer linked to that file; upload it again before you use it in an order."
    }
    if let first = otherModelNames.first {
        text += otherModelNames.count == 1
            ? " “\(first)” was linked to that file too and no longer is; upload it again before you use it in an order."
            : " \(otherModelNames.count) other models in your library were linked to that file and no longer are; upload them again before you use them in an order."
    }
    return text
}

/// The `publicFileServiceId` (a non-empty string) of the file `POST /files/direct-upload` would store the upload in,
/// else nil. Slant returns an existing file's placeholder when the name is already used (30 Oct 2026).
func uploadPlaceholderFileID(_ placeholder: [String: Any]) -> String? {
    guard let raw = placeholder["publicFileServiceId"] as? String else { return nil }
    let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    return id.isEmpty ? nil : id
}

/// The pre-PUT guard's decision: the protected file (ID and name) that the placeholder would write over, else nil.
/// `protectedFiles` maps trimmed file IDs to their names. A placeholder without a string `publicFileServiceId` can't
/// be checked and passes.
func uploadPlaceholderProtectedFile(_ placeholder: [String: Any], protectedFiles: [String: String]) -> (id: String, name: String)? {
    guard let id = uploadPlaceholderFileID(placeholder), let name = protectedFiles[id] else { return nil }
    return (id, name)
}

/// File IDs (trimmed) with their names, for the pre-PUT guard: every record's own file ID (`uploadedFileID`, never a
/// name), except `replacing`, the one file the seller chose to replace. Later records never overwrite an earlier
/// record's name.
func uploadProtectedFiles(_ files: [Record], replacing: String? = nil) -> [String: String] {
    let skipped = replacing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var protected: [String: String] = [:]
    for file in files {
        guard let id = uploadedFileID(file.values), id != skipped, protected[id] == nil else { continue }
        protected[id] = ((file.values["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return protected
}

/// `protected` plus every library model's link (named after the model when the list didn't name it), except the file
/// being replaced: the Models upload guard never writes over a file a library model uses.
func uploadProtectedFilesAddingLibraryLinks(_ protected: [String: String], models: [LocalModel], replacing: String?) -> [String: String] {
    let skipped = replacing?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    var result = protected
    if !skipped.isEmpty { result[skipped] = nil }
    for model in models {
        guard let id = model.remoteID?.trimmingCharacters(in: .whitespacesAndNewlines), !id.isEmpty, id != skipped,
              result[id] == nil else { continue }
        result[id] = model.name
    }
    return result
}

/// A Replace File: the listed file the seller chose to replace (its ID when known) and its name for the copy.
struct UploadReplacement: Equatable, Sendable {
    var fileID: String?
    var fileName: String
}

/// The pre-PUT guard stopped an upload: Slant returned the placeholder of a file that must not be overwritten, so no
/// bytes were sent. A definite refusal: nothing changed on Slant.
struct UploadWouldOverwriteExistingFile: LocalizedError, Equatable {
    let fileID: String
    let fileName: String
    var errorDescription: String? { uploadWouldOverwriteMessage(fileName: fileName) }
}

func uploadWouldOverwriteMessage(fileName: String) -> String {
    let trimmed = fileName.trimmingCharacters(in: .whitespacesAndNewlines)
    let file = trimmed.isEmpty ? "one of your existing Slant files" : "your existing file “\(trimmed)”"
    return "Nothing was uploaded: Slant would have saved this into \(file). Choose another name and upload again."
}

/// Upload failure copy by the step that failed. A storage refusal isn't about the API key, and a local file is never
/// told to use a secure link.
func uploadFailureMessage(stage: UploadStage?, error: Error) -> String {
    if let guarded = error as? UploadWouldOverwriteExistingFile { return uploadWouldOverwriteMessage(fileName: guarded.fileName) }
    if uploadOutcomeUnknown(stage: stage, error: error) { return uploadUnconfirmedMessage }
    switch stage {
    case .preparing?:
        if case .invalidResponse(let message)? = error as? APIError, slantReportedFailureMessage(message) == nil {
            return uploadLinkMissingMessage
        }
        return friendlyAPIMessage(error)
    case .uploading?:
        if case .http(let status, _, _, _)? = error as? APIError {
            if status == 403 {
                return "Slant’s storage refused the upload link, or it had expired, so nothing was uploaded. Upload again to get a new link."
            }
            return "Slant’s storage didn’t accept the file (HTTP \(status)), so nothing was uploaded. Upload again to get a new link."
        }
        if error is URLError {
            return "The upload was interrupted, so nothing was added to Slant. Check your connection, then upload again."
        }
        return friendlyAPIMessage(error)
    case .confirming?, nil:
        return friendlyAPIMessage(error)
    }
}

/// Slant documents uploads up to 250 MB; downloads of a Slant file allow a margin above that.
let slantDownloadMaxBytes: Int64 = 300 * 1024 * 1024
let slantDownloadTooLargeMessage = "This model is larger than 300 MB, so Studio didn’t download it."

/// False when `Content-Length` already says the download is over the cap; an unknown length (-1) is checked while reading.
func slantDownloadLengthAllowed(_ expected: Int64, maxBytes: Int64 = slantDownloadMaxBytes) -> Bool {
    expected <= maxBytes
}

/// One capped download into an open file on `APIClient`'s session, as a task delegate: data arrives in the chunks
/// URLSession delivers, `Content-Length` and the running total are checked against `maxBytes`, and redirects are
/// refused like the session's own. A non-2xx reply stops at the headers; the caller turns it into an `APIError`.
private final class CappedFileDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let handle: FileHandle
    private let maxBytes: Int64
    private let lock = NSLock()
    private var written: Int64 = 0
    private var response: URLResponse?
    private var failure: Error?
    private var continuation: CheckedContinuation<(URLResponse, Int64), Error>?
    private var task: URLSessionDataTask?

    init(handle: FileHandle, maxBytes: Int64) {
        self.handle = handle
        self.maxBytes = maxBytes
    }

    func run(session: URLSession, url: URL) async throws -> (URLResponse, Int64) {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(URLResponse, Int64), Error>) in
                lock.lock()
                self.continuation = continuation
                let task = session.dataTask(with: url)
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
        lock.lock()
        self.response = response
        lock.unlock()
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            // Reported from the response once the task ends, as `checked` words it.
            completionHandler(.cancel)
            return
        }
        guard slantDownloadLengthAllowed(http.expectedContentLength, maxBytes: maxBytes) else {
            fail(StudioError(slantDownloadTooLargeMessage), task: dataTask)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        written += Int64(data.count)
        let over = written > maxBytes
        let stopped = failure != nil
        lock.unlock()
        guard !stopped else { return }
        if over {
            fail(StudioError(slantDownloadTooLargeMessage), task: dataTask)
            return
        }
        do { try handle.write(contentsOf: data) } catch {
            fail(StudioError("Studio couldn’t save the download to a temporary file."), task: dataTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let recorded = failure
        let response = self.response
        let total = written
        lock.unlock()
        guard let continuation else { return }
        if let recorded {
            continuation.resume(throwing: recorded)
        } else if let response, !((response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false) {
            // Stopped at the headers on purpose: the caller reports the status.
            continuation.resume(returning: (response, 0))
        } else if let error {
            continuation.resume(throwing: error)
        } else if let response {
            continuation.resume(returning: (response, total))
        } else {
            continuation.resume(throwing: APIError.invalidResponse("The server returned a non-HTTP response."))
        }
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
            throw APIError.invalidRequest("Connect your account in Settings first.")
        }
        guard path.hasPrefix("/"), !path.contains("?"), !path.contains("#"), !path.contains("\\"),
              let decodedPath = path.removingPercentEncoding, !decodedPath.contains("\\"),
              !decodedPath.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw APIError.invalidRequest("Use an API path beginning with / and supply query parameters separately.")
        }
        guard let url = slantAPIURL(path: path, query: query) else { throw APIError.invalidRequest("Invalid API URL.") }
        var request = URLRequest(url: url)
        request.httpMethod = method.uppercased()
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        // Only Slant API requests name the app; presigned storage PUTs and downloads keep URLSession's default.
        request.setValue(slantStudioUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(path == "/files/openScad" ? "application/sla, application/json" : "application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard JSONSerialization.isValidJSONObject(body) else { throw APIError.invalidRequest("The request body must be a JSON object or array.") }
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: request)
        let result = try checked(data: data, response: response, requestPath: path)
        if path == "/files/openScad" {
            guard !data.isEmpty else { throw APIError.invalidResponse("OpenSCAD returned an empty model.") }
            guard result.json == nil, !(result.contentType?.lowercased().contains("json") ?? false) else {
                throw APIError.invalidResponse("OpenSCAD returned JSON instead of STL model bytes:\n\(result.pretty)")
            }
        }
        return result
    }

    /// The three requests of an upload. `stage` is called synchronously before each one is sent, so a caller can word a
    /// failure by the step that failed (`uploadFailureMessage`); the errors thrown are unchanged. `checkPlaceholder`
    /// runs on the `filePlaceholder` that direct-upload returned, before the PUT: an error it throws stops the upload
    /// with no bytes sent (the stage is still `.preparing`). Slant returns an existing file's placeholder for a name it
    /// already holds, so callers use it to refuse writing over files that must be kept (`uploadPlaceholderProtectedFile`).
    func upload(file: URL, name: String, platformId: String, ownerId: String,
                checkPlaceholder: (([String: Any]) throws -> Void)? = nil,
                stage: @escaping @Sendable (UploadStage) -> Void) async throws -> APIResponse {
        guard file.isFileURL, FileManager.default.isReadableFile(atPath: file.path) else {
            throw APIError.invalidRequest("Select a readable local model file.")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !platformId.isEmpty else {
            throw APIError.invalidRequest("Choose a model name and a platform first.")
        }
        stage(.preparing)
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
            throw APIError.invalidResponse(uploadLinkMissingMessage)
        }
        try Task.checkCancellation()
        // Before any bytes are sent: the caller may refuse the file Slant chose to store this upload in.
        try checkPlaceholder?(placeholder)
        stage(.uploading)
        var put = URLRequest(url: url)
        put.httpMethod = "PUT"
        put.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await session.upload(for: put, fromFile: file)
        _ = try checked(data: data, response: response)
        try Task.checkCancellation()
        stage(.confirming)
        return try await request("POST", path: "/files/confirm-upload", body: ["filePlaceholder": placeholder])
    }

    /// Downloads a Slant file's model to a temporary file, at most `slantDownloadMaxBytes` (checked against
    /// `Content-Length` and while reading). No Authorization header is sent and redirects are refused.
    func downloadModel(from url: URL, maxBytes: Int64 = slantDownloadMaxBytes) async throws -> URL {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw APIError.invalidResponse("Slant didn’t return a secure HTTPS download link. Try again.")
        }
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("Plinth-Download-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw StudioError("Studio couldn’t save the download to a temporary file.")
        }
        var finished = false
        defer {
            try? handle.close()
            if !finished { try? FileManager.default.removeItem(at: destination) }
        }
        // Chunks as URLSession delivers them, written straight to the file; the cap stops the transfer mid-way.
        let (response, written) = try await CappedFileDownload(handle: handle, maxBytes: maxBytes).run(session: session, url: url)
        _ = try checked(data: Data(), response: response)
        guard written > 0 else { throw StudioError("Slant sent an empty model file.") }
        finished = true
        return destination
    }

    private func checked(data: Data, response: URLResponse, requestPath: String? = nil) throws -> APIResponse {
        guard let response = response as? HTTPURLResponse else { throw APIError.invalidResponse("The server returned a non-HTTP response.") }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        let result = APIResponse(data: data, statusCode: response.statusCode, contentType: response.value(forHTTPHeaderField: "Content-Type"),
                                 headers: headers, requestPath: requestPath)
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
            throw APIError.invalidResponse("\(slantReportedFailurePrefix)\(response.statusCode)):\n\(result.pretty)")
        }
        return result
    }
}

enum KeychainStore {
    private static let account = "api-key"
    /// Plinth's service; the packaged app brings the key over from Slant Studio's on first read (LegacyMigration.swift).
    private static var item: KeychainItemStore { .standard(account: account) }

    static func load() throws -> String {
        let saved = try item.load()
        if saved == .none { return "" }
        guard case .data(let data) = saved, let value = String(data: data, encoding: .utf8) else {
            throw APIError.invalidResponse("The saved API key could not be decoded.")
        }
        return value
    }

    static func save(_ key: String) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { try delete(); return }
        try item.save(Data(normalized.utf8))
    }

    static func delete() throws {
        try item.delete()
    }
}
