import Foundation
import Security

// MARK: - Image to 3D services
//
// The provider-neutral layer behind Generate a Replica from an Image: one to four labelled photos (already prepared,
// re-encoded without metadata, by ImagePreparation.swift) go to the seller's chosen service — Meshy or Tripo3D — which
// makes a mesh that Studio downloads as STL or 3MF into a `SlantStudio-Generated3D-…` temporary folder. One photo uses
// the service's single-image endpoint; two to four use its multi-view endpoint (`ImageTo3DTaskKind.multiImageGeneration`).
//
// Rules this layer keeps:
//   - Creating a task (generation, Tripo's conversion, Meshy's repair) spends the seller's credits, so it is sent once
//     and never retried. When Studio can't tell whether it was created (timeout, lost connection, 5xx, 408/409, a
//     reply it can't read, stopped mid-request) the result is `.unknown`, carrying any task ID already known, so the
//     UI can send the seller to the service's dashboard rather than send it again.
//   - Status reads may be sent again after transient failures, with a bounded backoff, waiting out 429 Retry-After,
//     within an overall limit (`imageTo3DPollTimeout`), and they stop when the Swift task is cancelled.
//   - Keys live in their own Keychain items (this device only), are sent only to the service's API host and never to
//     download hosts, and never appear in errors, logs or Activity (`imageTo3DRedacted`).
//   - Downloads are https only, capped at `imageTo3DMaxDownloadBytes`, carry no credentials or cookies and follow a
//     redirect only to another https host.
//   - Nothing here touches Slant, `store.run`, `busy` or the unknown-outcome lock.

/// Largest generated model Studio downloads: the preview's limit.
let imageTo3DMaxDownloadBytes: Int64 = 128 * 1024 * 1024
/// Largest JSON reply read from a service's API. Task replies are a few kilobytes.
let imageTo3DMaxResponseBytes = 2 * 1024 * 1024
/// Largest prepared image accepted. Tripo's upload limit is 20 MB; a prepared 2048 px JPEG is far smaller.
let imageTo3DMaxImageBytes = 20 * 1024 * 1024
/// Most photos one generation takes: Meshy's Multi-Image to 3D and Tripo's multiview-to-model both take up to four.
let imageTo3DMaxPhotos = 4
/// Per-request timeout for API calls. A create can take a while to answer under load.
let imageTo3DRequestTimeout: TimeInterval = 60
/// Longest Studio waits for one task (generation, conversion or repair) to finish.
let imageTo3DPollTimeout: TimeInterval = 10 * 60
/// Gap between status reads while a task runs.
let imageTo3DPollInterval: TimeInterval = 4
/// Status reads that fail in a row (transport, 5xx, 408, unreadable reply) before Studio stops waiting.
let imageTo3DMaxConsecutivePollFailures = 5
/// Longest single wait Studio accepts from a 429 `Retry-After`; longer asks are capped to this.
let imageTo3DMaxRetryAfter: TimeInterval = 120
/// The default (and highest suggested) triangle budget, so Reinforce and Auto-improve (20,000-triangle cap) accept the result.
let imageTo3DDefaultTriangleTarget = 20_000
/// Longest API key accepted in Settings.
let imageTo3DMaxKeyLength = 256
/// Temporary folder prefix for downloaded models; added to the launch clean-up in Personalisation.swift.
let imageTo3DTempFolderPrefix = "SlantStudio-Generated3D-"

// MARK: Services

enum ImageTo3DService: String, CaseIterable, Identifiable, Codable, Sendable {
    case meshy, tripo

    var id: String { rawValue }

    var title: String {
        switch self {
        case .meshy: return "Meshy"
        case .tripo: return "Tripo"
        }
    }

    /// Keychain account, alongside the Slant key's "api-key" in the "SlantStudio" service.
    var keychainAccount: String {
        switch self {
        case .meshy: return "meshy-api-key"
        case .tripo: return "tripo-api-key"
        }
    }

    /// How Meshy's keys begin (`msy_`, docs.meshy.ai/llms.txt). Tripo's docs disagree (`tsk_…` and `sk-…`), so
    /// Studio only uses these to spot a key pasted into the wrong service's field.
    var keyPrefix: String? {
        switch self {
        case .meshy: return "msy_"
        case .tripo: return nil
        }
    }
}

/// The only hosts Studio sends a 3D service key to: Meshy's API and Tripo's international and China mainland APIs.
let imageTo3DKnownAPIHosts: Set<String> = ["api.meshy.ai", "openapi.tripo3d.ai", "openapi.tripo3d.com"]

// MARK: Requests

enum ImageTo3DOutputFormat: String, CaseIterable, Identifiable, Sendable {
    case stl, threeMF = "3mf"
    var id: String { rawValue }
    var fileExtension: String { rawValue }
    var title: String { self == .stl ? "STL" : "3MF" }
}

/// The prepared photo: JPEG or PNG bytes with no metadata.
struct ImageTo3DImage: Equatable, Sendable {
    let data: Data
    /// `image/jpeg` or `image/png`.
    let mediaType: String

    init(data: Data, mediaType: String) {
        self.data = data
        self.mediaType = mediaType.lowercased()
    }

    var fileExtension: String { mediaType == "image/png" ? "png" : "jpg" }
}

/// The view a photo shows, in slot order. The names are Tripo's multiview keys; Meshy only needs the front first.
/// Left and right are the object's own sides (from the front, its left side is on the viewer's right).
enum ImageTo3DPhotoView: String, CaseIterable, Identifiable, Sendable {
    case front, left, back, right

    var id: String { rawValue }

    var title: String {
        switch self {
        case .front: return "Front"
        case .left: return "Left side"
        case .back: return "Back"
        case .right: return "Right side"
        }
    }
}

/// One prepared photo and the view it shows.
struct ImageTo3DViewImage: Equatable, Sendable {
    let view: ImageTo3DPhotoView
    let image: ImageTo3DImage
}

/// The photos in slot order (front, left side, back, right side): Meshy reads the first as the front.
func imageTo3DOrderedViews(_ views: [ImageTo3DViewImage]) -> [ImageTo3DViewImage] {
    ImageTo3DPhotoView.allCases.compactMap { slot in views.first { $0.view == slot } }
}

/// Why these photos can't be sent together, or nil: one to four, a front view, each view once, each photo valid.
func imageTo3DViewsProblem(_ views: [ImageTo3DViewImage]) -> String? {
    if views.isEmpty { return "Choose a photo of the object." }
    if views.count > imageTo3DMaxPhotos { return "Use at most \(imageTo3DMaxPhotos) photos." }
    guard views.contains(where: { $0.view == .front }) else { return "Add a front photo: both services need the front view." }
    for slot in ImageTo3DPhotoView.allCases where views.filter({ $0.view == slot }).count > 1 {
        return "Use one photo for the \(slot.title.lowercased()) view."
    }
    for view in imageTo3DOrderedViews(views) {
        if let problem = imageTo3DImageProblem(view.image) {
            return views.count == 1 ? problem : "\(view.view.title) photo: \(problem)"
        }
    }
    return nil
}

/// Why the image can't be sent, or nil.
func imageTo3DImageProblem(_ image: ImageTo3DImage) -> String? {
    if image.data.isEmpty { return "The photo is empty." }
    if image.data.count > imageTo3DMaxImageBytes { return "The photo is larger than 20 MB." }
    guard image.mediaType == "image/jpeg" || image.mediaType == "image/png" else { return "Use a JPEG or PNG photo." }
    let bytes = [UInt8](image.data.prefix(8))
    let isJPEG = bytes.count >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF
    let isPNG = bytes == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    if image.mediaType == "image/jpeg" && !isJPEG { return "The photo isn’t a JPEG image." }
    if image.mediaType == "image/png" && !isPNG { return "The photo isn’t a PNG image." }
    return nil
}

/// What to ask the service for. Texture is always off: Slant prints a single material, and texturing costs more.
struct ImageTo3DOptions: Equatable, Sendable {
    /// Triangle budget for Tripo's `face_limit` (its own range applies). Meshy isn't asked to remesh, so it keeps the
    /// detail it generates and ignores this.
    var targetTriangles: Int = imageTo3DDefaultTriangleTarget
    var format: ImageTo3DOutputFormat = .stl
    /// Paid higher-detail geometry: Meshy's Ultra `geometry_resolution` 2k (+5 credits), Tripo's `geometry_quality:
    /// detailed` (+20 credits). Off unless the seller ticks it for this replica.
    var higherDetail = false
    /// Put the model's origin at the centre of its base (Meshy `auto_size` + `origin_at: bottom`; Tripo's conversion
    /// `pivot_to_center_bottom`, which makes it an "advanced" conversion at 10 credits rather than 5).
    ///
    /// No size is sent: neither service takes one in millimetres (Meshy's Resize and Tripo's `auto_size` work in
    /// metres and estimate the size themselves), and the units of a downloaded STL aren't documented — probably
    /// metres. The caller must always scale the result to the seller's measurement.
    var originAtBottom = true
}

/// The triangle budget clamped to `range`.
func imageTo3DClampedTriangles(_ value: Int, range: ClosedRange<Int>) -> Int {
    min(max(value, range.lowerBound), range.upperBound)
}

/// What a generation is expected to cost, from the service's published price list. Approximate: prices change and
/// the service charges what it charges.
struct ImageTo3DCostEstimate: Equatable, Sendable {
    let service: ImageTo3DService
    /// Credits for the whole run (generation plus any conversion).
    let credits: Int
    /// What the figure covers, in one line.
    let breakdown: String

    var summary: String { "About \(credits) \(service.title) credits (\(breakdown)). Approximate: \(service.title)’s prices may have changed." }
}

// MARK: Tasks

enum ImageTo3DTaskState: Equatable, Sendable {
    case queued, running, succeeded, failed, banned, expired, cancelled
    /// A status Studio doesn't know. Treated as still running until the overall limit.
    case other(String)

    var isTerminal: Bool {
        switch self {
        case .succeeded, .failed, .banned, .expired, .cancelled: return true
        case .queued, .running, .other: return false
        }
    }

    var title: String {
        switch self {
        case .queued: return "Waiting in the queue"
        case .running: return "Generating"
        case .succeeded: return "Finished"
        case .failed: return "Failed"
        case .banned: return "Refused by the service’s content rules"
        case .expired: return "Expired"
        case .cancelled: return "Cancelled"
        case .other(let raw): return "Status “\(raw.prefix(40))”"
        }
    }
}

/// One status read of a task.
struct ImageTo3DTaskStatus: Equatable, Sendable {
    let taskID: String
    let state: ImageTo3DTaskState
    /// 0–100 when the service says.
    let progress: Int?
    /// The service's failure message, redacted and clipped.
    let message: String?
    /// Model links by lower-case format (`stl`, `3mf`, `glb`, …), https only.
    let modelURLs: [String: URL]
    /// The service's own suggested wait before the next read (Meshy sends `Retry-After` on a running task).
    let suggestedDelay: TimeInterval?

    init(taskID: String, state: ImageTo3DTaskState, progress: Int? = nil, message: String? = nil,
         modelURLs: [String: URL] = [:], suggestedDelay: TimeInterval? = nil) {
        self.taskID = taskID
        self.state = state
        self.progress = progress.map { min(100, max(0, $0)) }
        self.message = message
        self.modelURLs = modelURLs
        self.suggestedDelay = suggestedDelay
    }
}

/// The result of sending a create (generation, conversion or repair) once.
enum ImageTo3DCreateResult: Equatable, Sendable {
    /// The service accepted it and returned this task ID.
    case created(taskID: String)
    /// Definitely not created: refused (4xx other than 408/409, including 402 and 429) or stopped before sending.
    case notSent(ImageTo3DError)
    /// It may have been created. `taskID` is the latest task Studio knows of in this run (for Tripo's conversion,
    /// the generation), so the seller can look for it in the service's dashboard.
    case unknown(taskID: String?, error: ImageTo3DError)
}

/// The account's spendable credits.
struct ImageTo3DBalance: Equatable, Sendable {
    let service: ImageTo3DService
    let credits: Double
    /// Credits held for running tasks, when the service reports it (Tripo).
    let frozen: Double?

    var summary: String {
        let held = frozen.flatMap { $0 > 0 ? " (\(imageTo3DCreditText($0)) held for running tasks)" : nil } ?? ""
        return "\(imageTo3DCreditText(credits)) \(service.title) credits available\(held)."
    }
}

func imageTo3DCreditText(_ value: Double) -> String {
    value.rounded() == value ? String(Int(value)) : String(format: "%.1f", value)
}

// MARK: Errors

enum ImageTo3DError: LocalizedError, Equatable, Sendable {
    case notConfigured(ImageTo3DService)
    case invalidInput(String)
    /// The service answered with this status. `message` is the service's own text, redacted and clipped; `code` is
    /// Tripo's numeric error code when sent.
    case http(service: ImageTo3DService, status: Int, code: Int?, message: String)
    /// HTTP 429 (or Tripo's rate-limit code). Nothing was done.
    case rateLimited(service: ImageTo3DService, retryAfter: TimeInterval?)
    /// HTTP 402 or the service's "not enough credits" code: a free plan (no API access) or an empty balance.
    case paymentRequired(service: ImageTo3DService, message: String)
    /// No usable reply: timeout, lost connection and so on. Redacted.
    case transport(String)
    case invalidResponse(String)
    case responseTooLarge
    /// A model link or download Studio won't follow (not https, credentials in the link, wrong redirect).
    case downloadRefused(String)
    /// The finished model is larger than `imageTo3DMaxDownloadBytes`: downloading it again can't work.
    case modelTooLarge

    var errorDescription: String? { userMessage }

    var userMessage: String {
        switch self {
        case .notConfigured(let service):
            return "Add your \(service.title) API key in Settings › Design Tools › 3D generation first."
        case .invalidInput(let message):
            return message
        case .http(let service, let status, _, let message):
            let detail = message.isEmpty ? "" : " \(message)"
            switch status {
            case 401: return "\(service.title) rejected the API key. Check it in Settings › Design Tools › 3D generation."
            case 403: return "\(service.title) refused this request.\(detail)"
            case 404: return "\(service.title) couldn’t find that task. It may have been deleted or expired."
            case 400, 422: return "\(service.title) couldn’t accept that request.\(detail)"
            case 300...399: return "\(service.title) redirected the request, so Plinth stopped."
            case 500...599: return "\(service.title) is having trouble right now (HTTP \(status))."
            default: return "\(service.title) couldn’t complete that request (HTTP \(status)).\(detail)"
            }
        case .rateLimited(let service, let retryAfter):
            if let retryAfter, retryAfter > 0 {
                return "\(service.title) is limiting requests. \(rateLimitResetWaitCopy(secondsFromNow: retryAfter))"
            }
            return "\(service.title) is limiting requests. Wait a moment, then try again."
        case .paymentRequired(let service, let message):
            let detail = message.isEmpty ? "" : " \(message)"
            return "\(service.title) needs a paid plan with enough credits for API use.\(detail)"
        case .transport(let message):
            return "Plinth couldn’t reach the service: \(message)"
        case .invalidResponse(let message):
            return message
        case .responseTooLarge:
            return "The service’s reply was larger than Plinth reads, so it was ignored."
        case .downloadRefused(let message):
            return message
        case .modelTooLarge:
            return imageTo3DTooLargeMessage
        }
    }

    /// Activity-safe one line: status and kind only, no service text.
    var activityDetail: String {
        switch self {
        case .notConfigured: return "No API key"
        case .invalidInput: return "Not sent"
        case .http(_, let status, let code, _): return code.map { "HTTP \(status), code \($0)" } ?? "HTTP \(status)"
        case .rateLimited: return "Rate limited (HTTP 429)"
        case .paymentRequired: return "Payment required"
        case .transport: return "No reply"
        case .invalidResponse: return "Unreadable reply"
        case .responseTooLarge: return "Reply too large"
        case .downloadRefused: return "Download refused"
        case .modelTooLarge: return "Model too large"
        }
    }
}

/// True when a create (or other credit-spending request) that failed this way may still have been carried out: no
/// readable reply, a timeout, a conflict, a redirect or a server error. Refusals (other 4xx, 402, 429) happen before
/// the service acts. A cancellation reaching here was mid-request, so it counts as unknown too.
func imageTo3DCreateOutcomeUnknown(_ error: Error) -> Bool {
    switch error as? ImageTo3DError {
    case .http(_, let status, _, _)?:
        return status == 408 || status == 409 || status >= 500 || (300...399).contains(status)
    case .transport?, .invalidResponse?, .responseTooLarge?:
        return true
    case .notConfigured?, .invalidInput?, .rateLimited?, .paymentRequired?, .downloadRefused?, .modelTooLarge?:
        return false
    case nil:
        return true
    }
}

/// True when a status read that failed this way is worth sending again: no reply, a timeout, a server error or an
/// unreadable reply. 429 is handled separately (wait for Retry-After).
func imageTo3DReadIsTransient(_ error: Error) -> Bool {
    switch error as? ImageTo3DError {
    case .http(_, let status, _, _)?: return status == 408 || status >= 500
    case .transport?, .invalidResponse?: return true
    default: return false
    }
}

/// The create result for a reply (or failure) to a create sent once.
func imageTo3DCreateResult(_ outcome: Result<String, Error>, knownTaskID: String?) -> ImageTo3DCreateResult {
    switch outcome {
    case .success(let taskID):
        return .created(taskID: taskID)
    case .failure(let error):
        let typed = (error as? ImageTo3DError) ?? .transport("The request stopped before the service replied.")
        return imageTo3DCreateOutcomeUnknown(error) ? .unknown(taskID: knownTaskID, error: typed) : .notSent(typed)
    }
}

// MARK: Redaction

/// Text safe to show or record: every secret in `secrets`, anything shaped like a Meshy (`msy_…`), Tripo (`tsk_…`) or
/// Anthropic (`sk-ant-…`) key, Bearer tokens and signed-link query strings are replaced; the result is one short line.
func imageTo3DRedacted(_ text: String, secrets: [String] = []) -> String {
    var result = text
    for secret in secrets.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where secret.count >= 4 {
        result = result.replacingOccurrences(of: secret, with: "[redacted]")
    }
    let patterns = [
        #"(?i)bearer\s+[A-Za-z0-9._~+/=\-]+"#,
        #"msy_[A-Za-z0-9_\-]+"#,
        #"tsk_[A-Za-z0-9_\-]+"#,
        #"sk-ant-[A-Za-z0-9_\-]+"#
    ]
    for pattern in patterns {
        result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
    }
    // Signed model links carry their signature in the query; keep the host and path only.
    result = result.replacingOccurrences(of: #"(https?://[^\s"'?#]+)[?#][^\s"']*"#, with: "$1?[redacted]", options: .regularExpression)
    result = result.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if result.count > 240 { result = String(result.prefix(240)) + "…" }
    return result
}

/// The service's own message from an error body (`message`, `error.message`, `error`, `suggestion`), redacted.
func imageTo3DServiceMessage(from body: Data, secrets: [String]) -> String {
    guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
        let text = String(decoding: body.prefix(512), as: UTF8.self)
        return text.contains("<") ? "" : imageTo3DRedacted(text, secrets: secrets)
    }
    var parts: [String] = []
    for candidate in [root["message"], (root["error"] as? [String: Any])?["message"], root["error"], root["suggestion"]] {
        if let text = candidate as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !parts.contains(text) {
            parts.append(text)
        }
    }
    return imageTo3DRedacted(parts.joined(separator: " "), secrets: secrets)
}

// MARK: Retry-After

/// Seconds to wait from a `Retry-After` header: delta-seconds or an HTTP date, capped at `cap`. Nil when absent,
/// negative or unreadable.
func imageTo3DRetryAfterSeconds(_ raw: String?, now: Date = Date(), cap: TimeInterval = imageTo3DMaxRetryAfter) -> TimeInterval? {
    guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    if let value = Double(text) {
        guard value.isFinite, value >= 0 else { return nil }
        return min(value, cap)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: text) {
            return min(max(0, date.timeIntervalSince(now)), cap)
        }
    }
    return nil
}

/// Wait before the next status read: the regular interval, doubled for each failure in a row (capped at a minute),
/// or the 429's Retry-After when longer. A running task's own suggestion replaces the regular interval, kept
/// between 2 and 30 seconds.
func imageTo3DPollDelay(consecutiveFailures: Int, retryAfter: TimeInterval?, suggested: TimeInterval? = nil,
                        base: TimeInterval = imageTo3DPollInterval) -> TimeInterval {
    let start = suggested.map { min(max($0, 2), 30) } ?? base
    let backoff = start * pow(2, Double(min(max(consecutiveFailures, 0), 4)))
    let delay = min(backoff, 60)
    if let retryAfter { return max(delay, min(retryAfter, imageTo3DMaxRetryAfter)) }
    return delay
}

// MARK: Links

/// A model link Studio may download: https, a host, no user, password or fragment. The key is never sent with it.
func imageTo3DDownloadURLProblem(_ url: URL) -> String? {
    guard url.scheme?.lowercased() == "https" else { return "The service didn’t return a secure (https) model link." }
    guard let host = url.host, !host.isEmpty else { return "The service returned a model link without a host." }
    guard url.user == nil, url.password == nil else { return "The service returned a model link with sign-in details, so Plinth didn’t follow it." }
    guard url.fragment == nil else { return "The service returned an unusual model link, so Plinth didn’t follow it." }
    if host == "localhost" || host.hasSuffix(".local") || host.hasSuffix(".localhost") || imageTo3DHostIsIPLiteral(host) {
        return "The service returned a model link to a local address, so Plinth didn’t follow it."
    }
    return nil
}

/// True for IPv4 or IPv6 literals: real model links name a host.
func imageTo3DHostIsIPLiteral(_ host: String) -> Bool {
    if host.contains(":") { return true }
    let parts = host.split(separator: ".", omittingEmptySubsequences: false)
    return parts.count == 4 && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isNumber) }
}

/// Whether a download may follow a redirect to `target`: same (https) scheme, another valid model link.
func imageTo3DRedirectAllowed(from source: URL?, to target: URL?) -> Bool {
    guard let target, source?.scheme?.lowercased() == "https" else { return false }
    return imageTo3DDownloadURLProblem(target) == nil
}

/// Whether a download of `expectedLength` bytes (−1 when unknown) fits under the cap.
func imageTo3DDownloadLengthAllowed(_ expectedLength: Int64, cap: Int64 = imageTo3DMaxDownloadBytes) -> Bool {
    expectedLength < 0 || expectedLength <= cap
}

/// An API URL on one of the known service hosts: https, that host exactly, and a path without dot segments.
func imageTo3DAPIURL(host: String, path: String, query: [String: String] = [:]) -> URL? {
    guard imageTo3DKnownAPIHosts.contains(host), path.hasPrefix("/"), !path.contains("?"), !path.contains("#"), !path.contains("\\"),
          !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { return nil }
    var components = URLComponents()
    components.scheme = "https"
    components.host = host
    components.path = path
    if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
    return components.url
}

/// A task ID safe to put in a URL path: letters, digits, `-` and `_`, at most 128 characters.
func imageTo3DTaskIDIsSafe(_ id: String) -> Bool {
    !id.isEmpty && id.count <= 128 && id.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
}

/// Https model links from a JSON object of `format: url` pairs, keyed by lower-case format. Others are dropped.
func imageTo3DModelURLs(_ object: Any?) -> [String: URL] {
    guard let pairs = object as? [String: Any] else { return [:] }
    var urls: [String: URL] = [:]
    for (key, value) in pairs {
        guard let text = value as? String, let url = URL(string: text), imageTo3DDownloadURLProblem(url) == nil else { continue }
        urls[key.lowercased()] = url
    }
    return urls
}

// MARK: Transport

struct ImageTo3DHTTPReply: Sendable {
    let status: Int
    let headers: [String: String]
    let body: Data

    func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }

    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] }
}

/// How the clients reach the network; tests substitute a scripted one.
protocol ImageTo3DTransport: Sendable {
    /// Sends one request without following redirects and reads at most `imageTo3DMaxResponseBytes`. Throws
    /// `ImageTo3DError.transport` (redacted) when no reply was read, or `CancellationError`.
    func send(_ request: URLRequest) async throws -> ImageTo3DHTTPReply
    /// Downloads `url` (already checked) to a new file inside `folder`, with no credentials, at most `maxBytes`,
    /// following only https redirects. Returns the file.
    func download(_ url: URL, into folder: URL, fileName: String, maxBytes: Int64) async throws -> URL
}

private final class ImageTo3DNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

func imageTo3DSessionConfiguration(timeout: TimeInterval) -> URLSessionConfiguration {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCredentialStorage = nil
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout * 3
    return configuration
}

/// The real network. API calls use a session that never follows redirects; each download gets its own session.
final class URLSessionImageTo3DTransport: ImageTo3DTransport, @unchecked Sendable {
    private let session: URLSession
    private let secrets: [String]

    init(secrets: [String]) {
        self.secrets = secrets
        session = URLSession(configuration: imageTo3DSessionConfiguration(timeout: imageTo3DRequestTimeout),
                             delegate: ImageTo3DNoRedirectDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func send(_ request: URLRequest) async throws -> ImageTo3DHTTPReply {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw ImageTo3DError.invalidResponse("The service returned a non-HTTP response.") }
            if http.expectedContentLength > Int64(imageTo3DMaxResponseBytes) { throw ImageTo3DError.responseTooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > imageTo3DMaxResponseBytes { throw ImageTo3DError.responseTooLarge }
            }
            var headers: [String: String] = [:]
            for (key, value) in http.allHeaderFields {
                if let key = key as? String, let value = value as? String { headers[key] = value }
            }
            return ImageTo3DHTTPReply(status: http.statusCode, headers: headers, body: data)
        } catch let error as ImageTo3DError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ImageTo3DError.transport(imageTo3DRedacted(error.localizedDescription, secrets: secrets))
        }
    }

    func download(_ url: URL, into folder: URL, fileName: String, maxBytes: Int64) async throws -> URL {
        if let problem = imageTo3DDownloadURLProblem(url) { throw ImageTo3DError.downloadRefused(problem) }
        let destination = folder.appendingPathComponent(fileName)
        return try await ImageTo3DBoundedDownload(url: url, destination: destination, maxBytes: maxBytes).run()
    }
}

/// One capped download straight to a file. Its own ephemeral session: no cookies, cache or credentials, and no
/// Authorization header, ever. A redirect is followed only to another valid https link.
private final class ImageTo3DBoundedDownload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let url: URL
    private let destination: URL
    private let maxBytes: Int64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var written: Int64 = 0
    private var failure: Error?
    private var continuation: CheckedContinuation<URL, Error>?
    private var task: URLSessionDataTask?

    init(url: URL, destination: URL, maxBytes: Int64) {
        self.url = url
        self.destination = destination
        self.maxBytes = maxBytes
    }

    func run() async throws -> URL {
        try Task.checkCancellation()
        let configuration = imageTo3DSessionConfiguration(timeout: imageTo3DRequestTimeout)
        configuration.timeoutIntervalForResource = 15 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard FileManager.default.createFile(atPath: destination.path, contents: nil),
              let handle = try? FileHandle(forWritingTo: destination) else {
            throw ImageTo3DError.downloadRefused("Plinth couldn’t create a temporary file for the model.")
        }
        self.handle = handle
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<URL, Error>) in
                lock.lock()
                self.continuation = continuation
                let task = session.dataTask(with: request)
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
        guard imageTo3DRedirectAllowed(from: response.url ?? task.currentRequest?.url, to: request.url) else {
            fail(ImageTo3DError.downloadRefused("The model link redirected somewhere Plinth doesn’t follow."), task: task)
            completionHandler(nil)
            return
        }
        var next = request
        next.setValue(nil, forHTTPHeaderField: "Authorization")
        next.httpShouldHandleCookies = false
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            fail(ImageTo3DError.invalidResponse("The download returned a non-HTTP response."), task: dataTask)
            completionHandler(.cancel)
            return
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = http.statusCode == 403 || http.statusCode == 404
                ? "The model link has expired or was removed (HTTP \(http.statusCode))."
                : "The model download failed (HTTP \(http.statusCode))."
            fail(ImageTo3DError.downloadRefused(message), task: dataTask)
            completionHandler(.cancel)
            return
        }
        guard imageTo3DDownloadLengthAllowed(http.expectedContentLength, cap: maxBytes) else {
            fail(ImageTo3DError.modelTooLarge, task: dataTask)
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        written += Int64(data.count)
        let over = written > maxBytes
        let handle = self.handle
        lock.unlock()
        if over {
            fail(ImageTo3DError.modelTooLarge, task: dataTask)
            return
        }
        do { try handle?.write(contentsOf: data) } catch {
            fail(ImageTo3DError.downloadRefused("Plinth couldn’t save the model to a temporary file."), task: dataTask)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        let recorded = failure
        let handle = self.handle
        self.handle = nil
        let total = written
        lock.unlock()
        try? handle?.close()
        guard let continuation else { return }
        if let recorded {
            try? FileManager.default.removeItem(at: destination)
            continuation.resume(throwing: recorded)
        } else if let error {
            try? FileManager.default.removeItem(at: destination)
            if (error as? URLError)?.code == .cancelled { continuation.resume(throwing: CancellationError()) }
            else { continuation.resume(throwing: ImageTo3DError.transport(imageTo3DRedacted(error.localizedDescription))) }
        } else if total == 0 {
            try? FileManager.default.removeItem(at: destination)
            continuation.resume(throwing: ImageTo3DError.downloadRefused("The service sent an empty model."))
        } else {
            continuation.resume(returning: destination)
        }
    }
}

let imageTo3DTooLargeMessage = "The generated model is larger than 128 MB, so Plinth didn’t download it."

/// A new `SlantStudio-Generated3D-<UUID>` folder in the temporary directory. The caller removes it after import;
/// leftovers go at the next launch.
func makeImageTo3DTempFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(imageTo3DTempFolderPrefix)\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
    return folder
}

// MARK: Credentials

/// Why a typed API key can't be right, or nil. Pasted keys often carry spaces or line breaks.
func imageTo3DKeyProblem(_ value: String, service: ImageTo3DService) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "Enter the \(service.title) API key." }
    if trimmed.count < 8 { return "That \(service.title) API key is too short. Copy it again." }
    if trimmed.count > imageTo3DMaxKeyLength { return "That \(service.title) API key is too long." }
    guard trimmed.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
        return "The key has spaces or characters an API key never has. Copy it again."
    }
    return nil
}

/// An advisory (never a refusal) when the key looks like another service's: a Meshy key in the Tripo field, or a
/// Claude key in either.
func imageTo3DKeyPrefixAdvice(_ value: String, service: ImageTo3DService) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    if trimmed.hasPrefix("sk-ant-") { return "This looks like a Claude key. 3D generation needs a \(service.title) key." }
    for other in ImageTo3DService.allCases where other != service {
        if let prefix = other.keyPrefix, trimmed.hasPrefix(prefix) {
            return "This looks like a \(other.title) key. Choose \(other.title) above, or paste a \(service.title) key."
        }
    }
    if let prefix = service.keyPrefix, !trimmed.hasPrefix(prefix) { return "\(service.title) keys usually begin with \(prefix)." }
    return nil
}

/// One Keychain item per service (`meshy-api-key`, `tripo-api-key`), apart from the Slant, Shopify and Claude items,
/// through the shared `AIServiceKeychainItem`.
enum ImageTo3DKeychainStore {
    private static func item(_ service: ImageTo3DService) -> AIServiceKeychainItem {
        service == .meshy ? .meshy : .tripo
    }

    /// The saved key, or nil when none is saved.
    static func load(_ service: ImageTo3DService) throws -> String? {
        guard let value = try item(service).load() else { return nil }
        guard !value.isEmpty else {
            throw StudioError("The saved \(service.title) key couldn’t be read. Remove it in Settings and add it again.")
        }
        return value
    }

    static func save(_ key: String, for service: ImageTo3DService) throws {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { try delete(service); return }
        try item(service).save(normalized)
    }

    static func delete(_ service: ImageTo3DService) throws {
        try item(service).delete()
    }
}

/// A client for `service` with `key`, sending through `transport` (the real network by default). `tripoRegion`
/// picks Tripo's API host; Tripo keys work only in the region they were made in.
func makeImageTo3DProvider(_ service: ImageTo3DService, key: String, tripoRegion: TripoRegion = .international,
                           transport: ImageTo3DTransport? = nil) -> ImageTo3DProvider {
    let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
    let transport = transport ?? URLSessionImageTo3DTransport(secrets: [trimmed])
    switch service {
    case .meshy: return MeshyClient(apiKey: trimmed, transport: transport)
    case .tripo: return TripoClient(apiKey: trimmed, region: tripoRegion, transport: transport)
    }
}

// MARK: Unconfirmed paid requests

/// A paid request (a generation or conversion) whose outcome Studio couldn't confirm: its create may have gone
/// through (timeout, 5xx, 408/409, an unreadable reply, the sheet closed mid-request), or its task was left running or
/// undelivered. Memory only, kept for the whole app session so that generating again in any sheet asks first.
struct ImageTo3DUnconfirmedRequest: Equatable, Sendable, Identifiable {
    let id: UUID
    let service: ImageTo3DService
    /// The generation (or repair) task, when known: how a later success confirms it.
    let sourceTaskID: String?
    /// The latest task Studio knows of, for the dashboard.
    let taskID: String?
    let time: Date
    /// What kind of request it was (a single- or multi-image generation, a conversion or repair), when known.
    var sourceKind: ImageTo3DTaskKind? = nil
}

/// The most records kept; older ones drop off, and `unconfirmedRequestsOverflowed` keeps the guard.
let imageTo3DUnconfirmedRequestLimit = 10

/// Whether a stop leaves a paid request unaccounted for: credits may have gone and no model was delivered. A task
/// the service ended (failed, banned, expired) made nothing to duplicate, so it isn't kept.
func imageTo3DStopIsUnconfirmed(_ stop: ImageTo3DStop) -> Bool {
    guard stop.creditsMayHaveBeenSpent else { return false }
    if case .taskEnded = stop.reason { return false }
    // A model too large for Studio is a known outcome: paid for, on the service's dashboard, and explained.
    if stop.reason == .modelTooLarge { return false }
    return true
}

/// "Meshy at 14:32 (task t1)"; "Meshy at 14:32 (multi-image task t1)" for a generation from several photos, which
/// Meshy lists apart from its single-image tasks.
func imageTo3DUnconfirmedLabel(_ request: ImageTo3DUnconfirmedRequest,
                               timeText: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }) -> String {
    // The latest task may be the generation's conversion, which isn't a multi-image task.
    let multi = request.sourceKind == .multiImageGeneration && (request.taskID == nil || request.taskID == request.sourceTaskID)
    let kind = multi ? "multi-image task" : "task"
    let task = request.taskID.map { " (\(kind) \($0))" } ?? (multi ? " (multi-image)" : "")
    return "\(request.service.title) at \(timeText(request.time))\(task)"
}

// MARK: Connection state

extension ImageTo3DService {
    /// The same service in the shared photo-sharing consent.
    var sharingService: ImageSharingService { self == .meshy ? .meshy : .tripo }
}

/// The app-wide 3D generation settings. Preferences hold only the chosen service, which services have a key saved
/// (so Settings can say so without reading the Keychain); keys are read from the Keychain only when a request is about
/// to be made. The one-time photo consent lives in `ImageSharingConsentStore`. No image, prompt or customer data is stored.
@MainActor final class ImageTo3DConnection: ObservableObject {
    static let shared = ImageTo3DConnection()
    static let serviceDefaultsKey = "imageTo3DService"
    static let savedKeysDefaultsKey = "imageTo3DSavedKeyServices"
    static let tripoRegionDefaultsKey = "imageTo3DTripoRegion"

    @Published var selectedService: ImageTo3DService {
        didSet { defaults.set(selectedService.rawValue, forKey: Self.serviceDefaultsKey) }
    }
    /// Which Tripo site the seller's key comes from.
    @Published var tripoRegion: TripoRegion {
        didSet { defaults.set(tripoRegion.rawValue, forKey: Self.tripoRegionDefaultsKey) }
    }
    @Published private(set) var savedKeys: Set<ImageTo3DService>
    /// Generations, repairs or key tests running now. Keys can't be replaced or removed meanwhile.
    @Published private(set) var activeWork = 0

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selectedService = defaults.string(forKey: Self.serviceDefaultsKey).flatMap(ImageTo3DService.init(rawValue:)) ?? .meshy
        tripoRegion = defaults.string(forKey: Self.tripoRegionDefaultsKey).flatMap(TripoRegion.init(rawValue:)) ?? .international
        savedKeys = Set((defaults.stringArray(forKey: Self.savedKeysDefaultsKey) ?? []).compactMap(ImageTo3DService.init(rawValue:)))
    }

    var busy: Bool { activeWork > 0 }
    func beginWork() { activeWork += 1 }
    func endWork() { activeWork = max(0, activeWork - 1) }

    /// Paid requests this session whose outcome is unconfirmed, oldest first. Memory only: never saved, and kept
    /// through key and service changes until quit.
    @Published private(set) var unconfirmedRequests: [ImageTo3DUnconfirmedRequest] = []
    /// Set once a record dropped off the list, so the guard stays for the rest of the session.
    @Published private(set) var unconfirmedRequestsOverflowed = false

    var hasUnconfirmedRequests: Bool { !unconfirmedRequests.isEmpty || unconfirmedRequestsOverflowed }

    /// Records `stop` when it leaves a paid request unaccounted for (`imageTo3DStopIsUnconfirmed`); a later stop of the
    /// same task replaces its earlier record. Returns the record's ID, or nil when nothing was recorded.
    @discardableResult
    func rememberUnconfirmed(_ stop: ImageTo3DStop, at time: Date = Date()) -> UUID? {
        if stop.reason == .modelTooLarge, let source = stop.sourceTaskID ?? stop.taskID {
            // The model arrived (too large to use): its earlier stops, such as a Keep Waiting timeout, are accounted for.
            confirmDelivered(service: stop.service, sourceTaskID: source)
        }
        guard imageTo3DStopIsUnconfirmed(stop) else { return nil }
        let source = stop.resumePoint?.sourceTaskID ?? stop.taskID
        if let source {
            unconfirmedRequests.removeAll { $0.service == stop.service && $0.sourceTaskID == source }
        }
        let record = ImageTo3DUnconfirmedRequest(id: UUID(), service: stop.service, sourceTaskID: source, taskID: stop.taskID, time: time,
                                                 sourceKind: stop.resumePoint?.sourceKind ?? stop.requestKind)
        unconfirmedRequests.append(record)
        if unconfirmedRequests.count > imageTo3DUnconfirmedRequestLimit {
            unconfirmedRequests.removeFirst(unconfirmedRequests.count - imageTo3DUnconfirmedRequestLimit)
            unconfirmedRequestsOverflowed = true
        }
        return record.id
    }

    /// A model from this task arrived, so its earlier stops are accounted for.
    func confirmDelivered(service: ImageTo3DService, sourceTaskID: String) {
        unconfirmedRequests.removeAll { $0.service == service && $0.sourceTaskID == sourceTaskID }
    }

    func hasKey(_ service: ImageTo3DService) -> Bool { savedKeys.contains(service) }
    /// Whether the seller agreed to send photos to `service` (Settings › Design Tools › Photo sharing).
    func hasPhotoConsent(_ service: ImageTo3DService) -> Bool {
        ImageSharingConsentStore.shared.hasConsented(service.sharingService)
    }

    /// Why a key can't be saved or removed now, or nil.
    var keyChangeBlockedReason: String? {
        busy ? "Wait for the current 3D generation task to finish." : nil
    }

    /// The client for the saved key, reading the Keychain now.
    func provider(for service: ImageTo3DService) throws -> ImageTo3DProvider {
        guard let key = try ImageTo3DKeychainStore.load(service) else {
            if savedKeys.contains(service) { markKey(service, saved: false) }
            throw ImageTo3DError.notConfigured(service)
        }
        if !savedKeys.contains(service) { markKey(service, saved: true) }
        return makeImageTo3DProvider(service, key: key, tripoRegion: tripoRegion)
    }

    /// The client for the chosen service.
    func currentProvider() throws -> ImageTo3DProvider { try provider(for: selectedService) }

    /// Saves a key that has just passed Save & Test.
    func save(key: String, for service: ImageTo3DService) throws {
        try ImageTo3DKeychainStore.save(key, for: service)
        markKey(service, saved: true)
    }

    func removeKey(for service: ImageTo3DService) throws {
        if let reason = keyChangeBlockedReason { throw StudioError(reason) }
        try ImageTo3DKeychainStore.delete(service)
        markKey(service, saved: false)
    }

    private func markKey(_ service: ImageTo3DService, saved: Bool) {
        if saved { savedKeys.insert(service) } else { savedKeys.remove(service) }
        defaults.set(ImageTo3DService.allCases.filter(savedKeys.contains).map(\.rawValue), forKey: Self.savedKeysDefaultsKey)
    }
}

// MARK: Provider

/// Which kind of task a status read is for (Meshy reads each kind from its own endpoint; Tripo has one).
/// `multiImageGeneration` is a generation from two to four photos (Meshy's Multi-Image to 3D, Tripo's
/// multiview-to-model): resume points and unconfirmed records carry it, so Keep Waiting reads the right endpoint.
enum ImageTo3DTaskKind: String, Sendable {
    case generation, multiImageGeneration, conversion, repair

    /// The generation kind for this many photos.
    static func generation(photoCount: Int) -> ImageTo3DTaskKind {
        photoCount > 1 ? .multiImageGeneration : .generation
    }

    var isGeneration: Bool { self == .generation || self == .multiImageGeneration }
}

/// One image-to-3D service. Creates are sent once; reads may be repeated by the caller.
protocol ImageTo3DProvider: Sendable {
    var service: ImageTo3DService { get }
    /// The published price of a generation from `photoCount` photos with these options (including any conversion),
    /// before anything is sent.
    func estimatedCost(for options: ImageTo3DOptions, photoCount: Int) -> ImageTo3DCostEstimate
    /// Reads the account's credits (read-only; Settings › Save & Test uses it).
    func readBalance() async throws -> ImageTo3DBalance
    /// Sends the generation once: one photo to the single-image endpoint, two to four to the multi-view one (kind
    /// `ImageTo3DTaskKind.generation(photoCount:)`). Tripo uploads every photo first; a failed upload means nothing was
    /// created. `proceed` is asked right before each upload and before the create: false stops with nothing created.
    func createGeneration(views: [ImageTo3DViewImage], options: ImageTo3DOptions,
                          proceed: @escaping @Sendable () -> Bool) async -> ImageTo3DCreateResult
    /// One status read.
    func readTask(_ taskID: String, kind: ImageTo3DTaskKind) async throws -> ImageTo3DTaskStatus
    /// Whether a finished task needs a conversion task before `format` can be downloaded (Tripo always; Meshy after
    /// a repair, which gives GLB only).
    func needsConversion(after status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, to format: ImageTo3DOutputFormat) -> Bool
    /// Sends the conversion of a finished task once. Only called when `needsConversion` is true.
    func createConversion(of status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, options: ImageTo3DOptions) async -> ImageTo3DCreateResult
    /// The link to download from a finished task, and the format it gives. Never GLB, OBJ or FBX.
    func modelLink(in status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, preferred: ImageTo3DOutputFormat) -> ImageTo3DModelLink?
    /// Downloads a model link with no credentials, capped at `imageTo3DMaxDownloadBytes`.
    func download(_ url: URL, into folder: URL, fileName: String) async throws -> URL
}

extension ImageTo3DProvider {
    /// The price of a generation from one photo.
    func estimatedCost(for options: ImageTo3DOptions) -> ImageTo3DCostEstimate { estimatedCost(for: options, photoCount: 1) }

    /// One photo, as the front view.
    func createGeneration(image: ImageTo3DImage, options: ImageTo3DOptions) async -> ImageTo3DCreateResult {
        await createGeneration(views: [ImageTo3DViewImage(view: .front, image: image)], options: options, proceed: { true })
    }
}

/// The detail of a create that `proceed` stopped before anything was sent.
let imageTo3DStoppedBeforeSendingMessage = "Stopped before the generation was sent."

struct ImageTo3DModelLink: Equatable, Sendable {
    let url: URL
    let format: ImageTo3DOutputFormat
}

/// What a downloaded model really is, from its content rather than its link: a ZIP package is 3MF, anything else is
/// read as STL. Nil for a glTF binary (GLB) or an empty file. The caller still parses it before trusting it.
func imageTo3DDetectedFormat(_ data: Data) -> ImageTo3DOutputFormat? {
    guard !data.isEmpty else { return nil }
    if data.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .threeMF }
    if data.starts(with: Array("glTF".utf8)) { return nil }
    return .stl
}

/// The printable link in `urls` for `preferred`, else the other printable format.
func imageTo3DPrintableLink(_ urls: [String: URL], preferred: ImageTo3DOutputFormat) -> ImageTo3DModelLink? {
    let order: [ImageTo3DOutputFormat] = preferred == .stl ? [.stl, .threeMF] : [.threeMF, .stl]
    for format in order {
        if let url = urls[format.rawValue] { return ImageTo3DModelLink(url: url, format: format) }
    }
    return nil
}

// MARK: Running a generation

enum ImageTo3DStage: String, Equatable, Sendable {
    case sending, generating, repairing, converting, downloading

    var title: String {
        switch self {
        case .sending: return "Sending to the service"
        case .generating: return "Generating the model"
        case .repairing: return "Repairing for printing"
        case .converting: return "Converting for printing"
        case .downloading: return "Downloading the model"
        }
    }
}

/// What the run is doing now, for a progress line. Delivered on an arbitrary thread.
struct ImageTo3DProgress: Equatable, Sendable {
    let stage: ImageTo3DStage
    let taskID: String?
    let state: ImageTo3DTaskState?
    let percent: Int?
}

/// Where an interrupted run can carry on without sending anything that may already have been created: the
/// generation (or repair) task, and the conversion task once it was confirmed created.
struct ImageTo3DResumePoint: Equatable, Sendable {
    let sourceTaskID: String
    let sourceKind: ImageTo3DTaskKind
    let conversionTaskID: String?
}

/// A downloaded model, ready for the library import. `folder` is Studio's temporary folder: remove it after import.
struct ImageTo3DGeneratedModel: Equatable, Sendable {
    let service: ImageTo3DService
    let fileURL: URL
    let folder: URL
    let format: ImageTo3DOutputFormat
    /// The generation (or repair) task.
    let sourceTaskID: String
    let sourceKind: ImageTo3DTaskKind
    /// The conversion task, when one ran.
    let conversionTaskID: String?
}

enum ImageTo3DStopReason: Equatable, Sendable {
    /// Nothing was created: refused before or at the create, or stopped before sending. No credits spent.
    case notSent
    /// A create may have gone through; Studio didn't send it again.
    case outcomeUnknown
    /// The task finished without a model (failed, banned, expired, cancelled).
    case taskEnded(ImageTo3DTaskState)
    /// The conversion was refused after the generation was made (and charged).
    case conversionRefused
    /// The task was still running when Studio stopped waiting.
    case timedOut
    /// Studio couldn't read the task's status.
    case statusUnreadable
    /// The model was made but couldn't be downloaded.
    case downloadFailed
    /// The model was made (and paid for) but is larger than Studio downloads or reads, so trying again can't work.
    case modelTooLarge
    /// The seller stopped the run. Anything already created keeps running at the service.
    case cancelled
}

struct ImageTo3DStop: Equatable, Sendable, Error {
    let reason: ImageTo3DStopReason
    let stage: ImageTo3DStage
    let service: ImageTo3DService
    /// The latest task Studio knows of, for the dashboard.
    let taskID: String?
    /// Redacted, one line.
    let detail: String
    /// Set when `resumeImageTo3DGeneration` can carry on (Keep Waiting, Try Download Again) without resending
    /// anything that may already exist. Nil after an unknown create outcome, a refusal of the first create or a
    /// task that ended.
    var resumePoint: ImageTo3DResumePoint? = nil
    /// The kind of the run's source request (single- or multi-image generation, or repair), also when there's no
    /// resume point, so an unconfirmed record names it.
    var requestKind: ImageTo3DTaskKind? = nil
    /// The run's generation (or repair) task, also when there's no resume point. For Tripo, `taskID` may be the
    /// conversion's.
    var sourceTaskID: String? = nil
    /// Whether the request asked for Higher detail, so advice to go without it is given only when it applies.
    var higherDetailRequested = false

    /// Whether the seller may have been charged: anything once a create may have gone through.
    var creditsMayHaveBeenSpent: Bool { reason != .notSent && !(reason == .cancelled && taskID == nil) }

    /// The message for the seller, including where to look when a task may exist.
    var userMessage: String {
        let dashboard = taskID.map { " Check \(service.title)’s dashboard for task \($0) before trying again." }
            ?? " Check \(service.title)’s dashboard before trying again."
        let detailText = detail.isEmpty ? "" : " \(detail)"
        switch reason {
        case .notSent:
            return "Nothing was made by \(service.title).\(detailText)"
        case .outcomeUnknown:
            return "Plinth couldn’t tell whether \(service.title) started the task, so it wasn’t sent again.\(detailText)\(dashboard)"
        case .taskEnded(let state):
            return "\(service.title) stopped the task: \(state.title.lowercased()).\(detailText)"
        case .conversionRefused:
            return "\(service.title) made the model but refused to convert it, so nothing more was sent.\(detailText)"
        case .timedOut:
            return "\(service.title) was still working after 10 minutes, so Plinth stopped waiting. The task carries on at \(service.title)."
        case .statusUnreadable:
            return "Plinth couldn’t read the task’s progress.\(detailText)\(dashboard)"
        case .downloadFailed:
            return "\(service.title) made the model, but Plinth couldn’t download it.\(detailText)"
        case .modelTooLarge:
            // `detail` names the limit hit when it wasn't the download's 128 MB.
            let limit = detail.isEmpty ? "over 128 MB" : detail
            let kept = service == .meshy ? " (Meshy keeps it for 3 days)" : ""
            let task = taskID.map { ", task \($0)" } ?? ""
            let advice = higherDetailRequested ? " Generating again without Higher detail may help." : ""
            return "\(service.title)’s model was too detailed for Plinth (\(limit)), so it wasn’t used. The credits for it were spent, and the model stays on \(service.title)’s dashboard\(kept)\(task).\(advice)"
        case .cancelled:
            return taskID == nil ? "Stopped before anything was sent." : "Stopped. \(service.title) may still finish the task and charge for it."
        }
    }

    /// Activity-safe line: service, stage, reason and task ID only.
    var activityDetail: String {
        let id = taskID.map { ", task \($0)" } ?? ""
        return "\(service.title): \(stage.rawValue), \(reasonCode)\(id)"
    }

    private var reasonCode: String {
        switch reason {
        case .notSent: return "not sent"
        case .outcomeUnknown: return "outcome unknown"
        case .taskEnded(let state): return "ended (\(state.title.lowercased()))"
        case .conversionRefused: return "conversion refused"
        case .timedOut: return "timed out"
        case .statusUnreadable: return "status unreadable"
        case .downloadFailed: return "download failed"
        case .modelTooLarge: return "model too large"
        case .cancelled: return "cancelled"
        }
    }

    func resumable(from point: ImageTo3DResumePoint?) -> ImageTo3DStop {
        var copy = self
        copy.resumePoint = point
        return copy
    }

    func kind(_ kind: ImageTo3DTaskKind?) -> ImageTo3DStop {
        var copy = self
        copy.requestKind = kind
        return copy
    }
}

typealias ImageTo3DSleep = @Sendable (TimeInterval) async throws -> Void
typealias ImageTo3DClock = @Sendable () -> Date

let imageTo3DRealSleep: ImageTo3DSleep = { seconds in
    try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
}

/// Reads a task until it finishes, the overall limit passes or the Swift task is cancelled. Transient failures are
/// read again with backoff (at most `imageTo3DMaxConsecutivePollFailures` in a row); a 429 waits for Retry-After.
/// Returns the finished status (any terminal state) or why it stopped.
func imageTo3DPollUntilFinished(provider: ImageTo3DProvider, taskID: String, kind: ImageTo3DTaskKind, stage: ImageTo3DStage,
                                timeout: TimeInterval = imageTo3DPollTimeout,
                                sleep: ImageTo3DSleep = imageTo3DRealSleep, now: ImageTo3DClock = { Date() },
                                progress: @Sendable (ImageTo3DProgress) -> Void = { _ in }) async -> Result<ImageTo3DTaskStatus, ImageTo3DStop> {
    let service = provider.service
    func stop(_ reason: ImageTo3DStopReason, _ detail: String = "") -> Result<ImageTo3DTaskStatus, ImageTo3DStop> {
        .failure(ImageTo3DStop(reason: reason, stage: stage, service: service, taskID: taskID, detail: detail))
    }
    let deadline = now().addingTimeInterval(timeout)
    var failures = 0
    var retryAfter: TimeInterval?
    var suggested: TimeInterval?
    var first = true
    while true {
        if Task.isCancelled { return stop(.cancelled) }
        if !first {
            let delay = imageTo3DPollDelay(consecutiveFailures: failures, retryAfter: retryAfter, suggested: suggested)
            if now().addingTimeInterval(delay) > deadline { return stop(.timedOut) }
            do { try await sleep(delay) } catch { return stop(.cancelled) }
            if Task.isCancelled { return stop(.cancelled) }
        }
        first = false
        retryAfter = nil
        do {
            let status = try await provider.readTask(taskID, kind: kind)
            failures = 0
            suggested = status.suggestedDelay
            progress(ImageTo3DProgress(stage: stage, taskID: taskID, state: status.state, percent: status.progress))
            if status.state.isTerminal { return .success(status) }
        } catch is CancellationError {
            return stop(.cancelled)
        } catch ImageTo3DError.rateLimited(_, let wait) {
            retryAfter = wait ?? imageTo3DPollInterval * 4
        } catch {
            let message = (error as? ImageTo3DError)?.userMessage ?? ""
            guard imageTo3DReadIsTransient(error) else { return stop(.statusUnreadable, message) }
            failures += 1
            if failures >= imageTo3DMaxConsecutivePollFailures { return stop(.statusUnreadable, message) }
        }
    }
}

/// The whole run: create the generation once, then carry on as `resumeImageTo3DGeneration`. Never sends a create
/// twice. Cancelling the Swift task stops waiting (the service may still finish and charge). `proceed` is asked before
/// anything is sent (and by Tripo before each upload): false stops with nothing created, as Stop does.
func runImageTo3DGeneration(provider: ImageTo3DProvider, views: [ImageTo3DViewImage], options: ImageTo3DOptions,
                            timeout: TimeInterval = imageTo3DPollTimeout,
                            sleep: ImageTo3DSleep = imageTo3DRealSleep, now: ImageTo3DClock = { Date() },
                            makeFolder: () throws -> URL = makeImageTo3DTempFolder,
                            proceed: @escaping @Sendable () -> Bool = { true },
                            progress: @escaping @Sendable (ImageTo3DProgress) -> Void = { _ in }) async -> Result<ImageTo3DGeneratedModel, ImageTo3DStop> {
    let service = provider.service
    let kind = ImageTo3DTaskKind.generation(photoCount: views.count)
    func halt(_ reason: ImageTo3DStopReason, _ taskID: String?, _ detail: String) -> Result<ImageTo3DGeneratedModel, ImageTo3DStop> {
        .failure(ImageTo3DStop(reason: reason, stage: .sending, service: service, taskID: taskID, detail: detail, requestKind: kind))
    }
    if let problem = imageTo3DViewsProblem(views) { return halt(.notSent, nil, problem) }
    if Task.isCancelled || !proceed() { return halt(.cancelled, nil, "") }
    progress(ImageTo3DProgress(stage: .sending, taskID: nil, state: nil, percent: nil))
    switch await provider.createGeneration(views: imageTo3DOrderedViews(views), options: options, proceed: proceed) {
    case .created(let id):
        return await resumeImageTo3DGeneration(provider: provider,
                                               from: ImageTo3DResumePoint(sourceTaskID: id, sourceKind: kind, conversionTaskID: nil),
                                               options: options, timeout: timeout, sleep: sleep, now: now,
                                               makeFolder: makeFolder, progress: progress)
    case .notSent(.invalidInput(imageTo3DStoppedBeforeSendingMessage)):
        return halt(.cancelled, nil, "")
    case .notSent(let error):
        return halt(.notSent, nil, error.userMessage)
    case .unknown(let id, let error):
        return halt(.outcomeUnknown, id, error.userMessage)
    }
}

/// One photo, as the front view.
func runImageTo3DGeneration(provider: ImageTo3DProvider, image: ImageTo3DImage, options: ImageTo3DOptions,
                            timeout: TimeInterval = imageTo3DPollTimeout,
                            sleep: ImageTo3DSleep = imageTo3DRealSleep, now: ImageTo3DClock = { Date() },
                            makeFolder: () throws -> URL = makeImageTo3DTempFolder,
                            progress: @escaping @Sendable (ImageTo3DProgress) -> Void = { _ in }) async -> Result<ImageTo3DGeneratedModel, ImageTo3DStop> {
    await runImageTo3DGeneration(provider: provider, views: [ImageTo3DViewImage(view: .front, image: image)], options: options,
                                 timeout: timeout, sleep: sleep, now: now, makeFolder: makeFolder, progress: progress)
}

/// Carries a run on from `point`: waits for the source task, sends the conversion once when the service needs one
/// (and it hasn't been sent), waits for it, then downloads the printable file into a new temporary folder. Used for
/// the first run and for Keep Waiting / Try Download Again after a stop with a `resumePoint`.
func resumeImageTo3DGeneration(provider: ImageTo3DProvider, from point: ImageTo3DResumePoint, options: ImageTo3DOptions,
                               timeout: TimeInterval = imageTo3DPollTimeout,
                               sleep: ImageTo3DSleep = imageTo3DRealSleep, now: ImageTo3DClock = { Date() },
                               makeFolder: () throws -> URL = makeImageTo3DTempFolder,
                               progress: @escaping @Sendable (ImageTo3DProgress) -> Void = { _ in }) async -> Result<ImageTo3DGeneratedModel, ImageTo3DStop> {
    let service = provider.service
    let sourceStage: ImageTo3DStage = point.sourceKind == .repair ? .repairing : .generating
    func stop(_ reason: ImageTo3DStopReason, _ stage: ImageTo3DStage, _ taskID: String?, _ detail: String,
              resume: ImageTo3DResumePoint?) -> Result<ImageTo3DGeneratedModel, ImageTo3DStop> {
        .failure(ImageTo3DStop(reason: reason, stage: stage, service: service, taskID: taskID, detail: detail, resumePoint: resume,
                               requestKind: point.sourceKind))
    }
    // Polling stops that can carry on later: waiting, reading or cancelling never sends a create.
    func canCarryOn(_ reason: ImageTo3DStopReason) -> Bool {
        reason == .timedOut || reason == .statusUnreadable || reason == .cancelled
    }

    var finished: ImageTo3DTaskStatus
    var finishedKind = point.sourceKind
    var conversionID = point.conversionTaskID
    if let known = conversionID {
        finished = ImageTo3DTaskStatus(taskID: known, state: .queued)
    } else {
        switch await imageTo3DPollUntilFinished(provider: provider, taskID: point.sourceTaskID, kind: point.sourceKind, stage: sourceStage,
                                                timeout: timeout, sleep: sleep, now: now, progress: progress) {
        case .success(let status): finished = status
        case .failure(let halt): return .failure(halt.resumable(from: canCarryOn(halt.reason) ? point : nil).kind(point.sourceKind))
        }
        guard finished.state == .succeeded else {
            return stop(.taskEnded(finished.state), sourceStage, point.sourceTaskID, finished.message ?? "", resume: nil)
        }
        if provider.needsConversion(after: finished, kind: point.sourceKind, to: options.format) {
            if Task.isCancelled { return stop(.cancelled, .converting, point.sourceTaskID, "", resume: point) }
            progress(ImageTo3DProgress(stage: .converting, taskID: point.sourceTaskID, state: nil, percent: nil))
            switch await provider.createConversion(of: finished, kind: point.sourceKind, options: options) {
            case .created(let id):
                conversionID = id
            case .notSent(let error):
                // Definitely not created, so carrying on later (after a top-up, say) may send it.
                return stop(.conversionRefused, .converting, point.sourceTaskID, error.userMessage, resume: point)
            case .unknown(let id, let error):
                return stop(.outcomeUnknown, .converting, id ?? point.sourceTaskID, error.userMessage, resume: nil)
            }
        }
    }

    if let conversionID {
        let converting = ImageTo3DResumePoint(sourceTaskID: point.sourceTaskID, sourceKind: point.sourceKind, conversionTaskID: conversionID)
        switch await imageTo3DPollUntilFinished(provider: provider, taskID: conversionID, kind: .conversion, stage: .converting,
                                                timeout: timeout, sleep: sleep, now: now, progress: progress) {
        case .success(let status): finished = status
        case .failure(let halt): return .failure(halt.resumable(from: canCarryOn(halt.reason) ? converting : nil).kind(point.sourceKind))
        }
        guard finished.state == .succeeded else {
            return stop(.taskEnded(finished.state), .converting, conversionID, finished.message ?? "", resume: nil)
        }
        finishedKind = .conversion
    }

    let lastID = conversionID ?? point.sourceTaskID
    let downloadPoint = ImageTo3DResumePoint(sourceTaskID: point.sourceTaskID, sourceKind: point.sourceKind, conversionTaskID: conversionID)
    guard let link = provider.modelLink(in: finished, kind: finishedKind, preferred: options.format) else {
        // The model is made (and paid for): reading the finished task again may return the link, and sends no create.
        return stop(.downloadFailed, .downloading, lastID, "\(service.title) didn’t return an STL or 3MF link.", resume: downloadPoint)
    }
    if Task.isCancelled { return stop(.cancelled, .downloading, lastID, "", resume: downloadPoint) }
    progress(ImageTo3DProgress(stage: .downloading, taskID: lastID, state: .succeeded, percent: nil))
    let folder: URL
    do { folder = try makeFolder() } catch {
        return stop(.downloadFailed, .downloading, lastID, "Plinth couldn’t make a temporary folder.", resume: downloadPoint)
    }
    let safeID = imageTo3DTaskIDIsSafe(lastID) ? lastID : "model"
    do {
        let file = try await provider.download(link.url, into: folder, fileName: "\(service.rawValue)-\(safeID).\(link.format.fileExtension)")
        return .success(ImageTo3DGeneratedModel(service: service, fileURL: file, folder: folder, format: link.format,
                                                sourceTaskID: point.sourceTaskID, sourceKind: point.sourceKind,
                                                conversionTaskID: conversionID))
    } catch {
        try? FileManager.default.removeItem(at: folder)
        if error is CancellationError { return stop(.cancelled, .downloading, lastID, "", resume: downloadPoint) }
        // Too large is final: downloading it again would only be refused again.
        if (error as? ImageTo3DError) == .modelTooLarge {
            var final = ImageTo3DStop(reason: .modelTooLarge, stage: .downloading, service: service, taskID: lastID, detail: "",
                                      requestKind: point.sourceKind, sourceTaskID: point.sourceTaskID)
            final.higherDetailRequested = options.higherDetail
            return .failure(final)
        }
        return stop(.downloadFailed, .downloading, lastID, (error as? ImageTo3DError)?.userMessage ?? "", resume: downloadPoint)
    }
}
