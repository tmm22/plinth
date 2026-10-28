import Foundation
import CryptoKit
import Combine

// MARK: - Noticing when Slant changes its API
//
// Slant publishes no changelog or version header (`info.version` stayed 2.0.0 through the status change of 26 Oct
// 2026), but its OpenAPI description is public and keyless. Studio compares it, once a day, with the copy bundled
// when this version was made (`slant-openapi-upstream.json`), and watches its own order replies for statuses it doesn't
// recognise. Both only inform the seller: nothing here changes what Studio sends, blocks or accepts.

/// Slant's public, keyless OpenAPI description.
let slantAPISpecURL = URL(string: "https://slant3dapi.com/v2/api/openapi.json")!
let slantAPISpecHost = "slant3dapi.com"
let slantAPISpecMaxBytes = 2 * 1024 * 1024
let slantAPISpecTimeout: TimeInterval = 30
/// The bundled copy's `Last-Modified` (26 Oct 2026 21:09:58 GMT; reviewed 28 Oct 2026). A change is dated only when
/// Slant's `Last-Modified` is later than this; update it with the bundled file.
let slantAPIBundledSpecDate = Date(timeIntervalSince1970: 1_793_048_998)
let slantAPICheckInterval: TimeInterval = 24 * 3600
let slantAPIFirstCheckDelay: TimeInterval = 60
/// Without a Slant key (or the bundled copy) no check runs; the loop looks again this often, making no request.
let slantAPIIdleRecheck: TimeInterval = 5 * 60
/// The loop never sleeps longer than this, so a Mac that slept through the due time checks soon after waking.
let slantAPIMaxWait: TimeInterval = 3600
/// UserDefaults: the check's record (see `SlantAPICheckRecord`). Nothing about the account or its orders.
let slantAPICheckDefaultsKey = "slantAPIChangeCheck"
let slantAPIMaxStatusWords = 10
let slantAPIMaxStatusWordLength = 40
let slantAPIMaxSavedAreas = 12
let slantAPIMaxAreaNameLength = 40

// MARK: - Semantic comparison

/// Wording and examples: changes to these never count.
private let slantAPIIgnoredKeys: Set<String> = ["description", "summary", "example", "examples", "externalDocs"]
/// Objects whose keys are names (properties, paths, schemas, status codes, media types…), never keywords, so a
/// property called `description` is compared like any other.
private let slantAPINameMapKeys: Set<String> = [
    "paths", "properties", "patternProperties", "schemas", "responses", "content", "headers", "securitySchemes",
    "parameters", "requestBodies", "links", "callbacks", "encoding", "variables", "mapping", "definitions", "$defs",
    "dependentSchemas", "webhooks", "scopes", "pathItems"
]
/// Values that are data, not schema: kept as they are (an `enum` is still compared as a set).
private let slantAPIDataKeys: Set<String> = ["enum", "default", "const"]
/// Arrays whose order means something. Every other OpenAPI array (required, enum, parameters, tags, allOf…) is a set.
private let slantAPIOrderedArrayKeys: Set<String> = ["servers", "prefixItems"]
private let slantAPIMethods = ["get", "put", "post", "delete", "options", "head", "patch", "trace"]
private let slantAPIMaxDepth = 64

/// One JSON value as text with sorted keys, so equal values give equal text.
func slantAPICanonicalText(_ value: Any) -> String {
    guard JSONSerialization.isValidJSONObject([value]),
          let data = try? JSONSerialization.data(withJSONObject: [value], options: [.sortedKeys, .withoutEscapingSlashes])
    else { return String(describing: value) }
    return String(decoding: data, as: UTF8.self)
}

/// The spec with wording, examples and vendor extensions (`x-…`) removed and unordered arrays sorted, so only
/// changes to what requests and replies may contain remain. Keys inside name maps are always kept.
func slantAPINormalised(_ value: Any, key: String? = nil, isNameMap: Bool = false, depth: Int = 0) -> Any {
    guard depth < slantAPIMaxDepth else { return "…" }
    if let dictionary = value as? [String: Any] {
        var result: [String: Any] = [:]
        for (childKey, child) in dictionary {
            if !isNameMap {
                if slantAPIIgnoredKeys.contains(childKey) || childKey.hasPrefix("x-") { continue }
                if slantAPIDataKeys.contains(childKey) {
                    if childKey == "enum", let values = child as? [Any] {
                        result[childKey] = slantAPISortedAsSet(values)
                    } else {
                        result[childKey] = child
                    }
                    continue
                }
            }
            // Children of a name map are named things (a schema, an operation), whose keys are keywords again.
            let childIsNameMap = !isNameMap && slantAPINameMapKeys.contains(childKey) && child is [String: Any]
            result[childKey] = slantAPINormalised(child, key: isNameMap ? nil : childKey, isNameMap: childIsNameMap, depth: depth + 1)
        }
        return result
    }
    if let array = value as? [Any] {
        let items = array.map { slantAPINormalised($0, depth: depth + 1) }
        if let key, slantAPIOrderedArrayKeys.contains(key) { return items }
        return slantAPISortedAsSet(items)
    }
    return value
}

/// An unordered array in a fixed order: by canonical text, each item's text computed once.
private func slantAPISortedAsSet(_ items: [Any]) -> [Any] {
    items.map { (text: slantAPICanonicalText($0), item: $0) }.sorted { $0.text < $1.text }.map(\.item)
}

/// Every `$ref` inside a value.
private func slantAPIReferences(_ value: Any, depth: Int = 0) -> Set<String> {
    guard depth < slantAPIMaxDepth else { return [] }
    var result = Set<String>()
    if let dictionary = value as? [String: Any] {
        for (key, child) in dictionary {
            if key == "$ref", let ref = child as? String { result.insert(ref) } else { result.formUnion(slantAPIReferences(child, depth: depth + 1)) }
        }
    } else if let array = value as? [Any] {
        for child in array { result.formUnion(slantAPIReferences(child, depth: depth + 1)) }
    }
    return result
}

/// An operation's first tag as an area name ("Orders", "Files"): one line, at most 40 characters, "Other" if none.
func slantAPIAreaName(_ tag: String?) -> String {
    let cleaned = String((tag ?? "").unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) })
        .trimmingCharacters(in: .whitespaces)
    return cleaned.isEmpty ? "Other" : String(cleaned.prefix(slantAPIMaxAreaNameLength))
}

let slantAPISharedDefinitionsArea = "Shared definitions"
let slantAPIAuthenticationArea = "Authentication"
let slantAPIGeneralArea = "General"

/// The spec cut into comparable pieces: each operation (with its path's shared parameters), each component and the
/// rest (servers, security, the version number).
struct SlantAPISpecUnits: Equatable, Sendable {
    /// "GET /orders" → canonical text.
    var operations: [String: String] = [:]
    /// "GET /orders" → its area (first tag).
    var operationAreas: [String: String] = [:]
    /// "GET /orders" → the components it uses, directly or through other components.
    var operationReach: [String: Set<String>] = [:]
    /// "#/components/schemas/Order" → canonical text.
    var components: [String: String] = [:]
    var general = ""
    /// SHA-256 of the whole normalised spec: equal for specs that differ only in wording.
    var fingerprint = ""
}

/// Nil when the document isn't an OpenAPI description (no `paths` object).
func slantAPISpecUnits(_ document: [String: Any]) -> SlantAPISpecUnits? {
    guard let rawPaths = document["paths"] as? [String: Any],
          let normalised = slantAPINormalised(document) as? [String: Any] else { return nil }
    var units = SlantAPISpecUnits()
    var componentReferences: [String: Set<String>] = [:]
    for (kind, value) in normalised["components"] as? [String: Any] ?? [:] {
        guard let items = value as? [String: Any] else {
            units.components["#/components/\(kind)"] = slantAPICanonicalText(value)
            continue
        }
        for (name, item) in items {
            let key = "#/components/\(kind)/\(name)"
            units.components[key] = slantAPICanonicalText(item)
            componentReferences[key] = slantAPIReferences(item)
        }
    }
    for (path, value) in normalised["paths"] as? [String: Any] ?? [:] {
        guard let item = value as? [String: Any] else { continue }
        let shared = item.filter { !slantAPIMethods.contains($0.key) }
        let rawItem = rawPaths[path] as? [String: Any]
        for method in slantAPIMethods {
            guard let operation = item[method] as? [String: Any] else { continue }
            let key = "\(method.uppercased()) \(path)"
            units.operations[key] = slantAPICanonicalText(["operation": operation, "pathItem": shared])
            let tags = (rawItem?[method] as? [String: Any])?["tags"] as? [Any]
            units.operationAreas[key] = slantAPIAreaName(tags?.first as? String)
            // Everything the operation reaches through `$ref`s, followed through components.
            var reach = Set<String>()
            var queue = Array(slantAPIReferences(operation).union(slantAPIReferences(shared)))
            while let ref = queue.popLast() {
                guard ref.hasPrefix("#/components/"), reach.insert(ref).inserted else { continue }
                queue.append(contentsOf: componentReferences[ref] ?? [])
            }
            units.operationReach[key] = reach
        }
    }
    var general = normalised.filter { !["paths", "components", "info", "tags"].contains($0.key) }
    if let version = (document["info"] as? [String: Any])?["version"] { general["info.version"] = version }
    units.general = slantAPICanonicalText(general)
    units.fingerprint = slantAPIFingerprint(Data(slantAPICanonicalText(normalised).utf8))
    return units
}

func slantAPIFingerprint(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

struct SlantAPIDifference: Equatable, Sendable {
    /// Named areas, Slant's tags in alphabetical order, then Authentication, Shared definitions and General.
    var areas: [String] = []
    /// Added, removed or changed operations ("GET /orders"), sorted.
    var operations: [String] = []
    /// Changed definitions, by name ("Order"), sorted.
    var definitions: [String] = []
    var general = false
    var isEmpty: Bool { operations.isEmpty && definitions.isEmpty && !general }
}

private func slantAPIAreaRank(_ area: String) -> Int {
    switch area {
    case "Other": 1
    case slantAPIAuthenticationArea: 2
    case slantAPISharedDefinitionsArea: 3
    case slantAPIGeneralArea: 4
    default: 0
    }
}

func slantAPISortedAreas(_ areas: Set<String>) -> [String] {
    areas.sorted { lhs, rhs in
        let l = slantAPIAreaRank(lhs), r = slantAPIAreaRank(rhs)
        return l != r ? l < r : lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

/// What differs between the bundled spec and Slant's, by area. A component change counts for the areas of every
/// operation (in either spec) that uses it, else for "Shared definitions"; security schemes are "Authentication".
func slantAPIDifference(bundled: SlantAPISpecUnits, live: SlantAPISpecUnits) -> SlantAPIDifference {
    var difference = SlantAPIDifference()
    var areas = Set<String>()
    for key in Set(bundled.operations.keys).union(live.operations.keys) where bundled.operations[key] != live.operations[key] {
        difference.operations.append(key)
        areas.insert(live.operationAreas[key] ?? bundled.operationAreas[key] ?? "Other")
    }
    for key in Set(bundled.components.keys).union(live.components.keys) where bundled.components[key] != live.components[key] {
        difference.definitions.append(String(key.split(separator: "/").last ?? Substring(key)))
        if key.hasPrefix("#/components/securitySchemes") {
            areas.insert(slantAPIAuthenticationArea)
            continue
        }
        var users = Set<String>()
        for units in [bundled, live] {
            for (operation, reach) in units.operationReach where reach.contains(key) {
                users.insert(units.operationAreas[operation] ?? "Other")
            }
        }
        if users.isEmpty { areas.insert(slantAPISharedDefinitionsArea) } else { areas.formUnion(users) }
    }
    if bundled.general != live.general {
        difference.general = true
        areas.insert(slantAPIGeneralArea)
    }
    difference.operations.sort()
    difference.definitions = Array(Set(difference.definitions)).sorted()
    difference.areas = slantAPISortedAreas(areas)
    return difference
}

struct SlantAPIComparison: Equatable, Sendable {
    var difference: SlantAPIDifference
    /// The live spec's `SlantAPISpecUnits.fingerprint`.
    var liveFingerprint: String
}

/// Nil when the reply isn't a readable OpenAPI description.
func slantAPICompare(liveData: Data, bundled: SlantAPISpecUnits) -> SlantAPIComparison? {
    guard liveData.count <= slantAPISpecMaxBytes,
          let document = (try? JSONSerialization.jsonObject(with: liveData)) as? [String: Any],
          let live = slantAPISpecUnits(document) else { return nil }
    return SlantAPIComparison(difference: slantAPIDifference(bundled: bundled, live: live), liveFingerprint: live.fingerprint)
}

// MARK: - The bundled copy

/// Packaged apps keep it in `Contents/Resources`; tests and `swift run` use the SwiftPM bundle (consulted only after
/// the app bundle lookup fails, as `EndpointCatalog` does).
func slantAPIBundledSpecURL() -> URL? {
    if let packaged = Bundle.main.url(forResource: "slant-openapi-upstream", withExtension: "json") { return packaged }
    return Bundle.module.url(forResource: "slant-openapi-upstream", withExtension: "json")
}

func slantAPIBundledSpecData() -> Data? {
    slantAPIBundledSpecURL().flatMap { try? Data(contentsOf: $0) }
}

// MARK: - The saved record

/// Everything the check saves (UserDefaults): Slant's cache headers, when it checked, the changed area names, which
/// change was dismissed, and fingerprints (hashes) of the bundled and the differing public spec. No key, account,
/// order or customer data.
struct SlantAPICheckRecord: Equatable {
    /// SHA-256 of the bundled file the rest was compared with. A new Studio build starts afresh.
    var bundledFingerprint = ""
    var etag: String?
    var lastModified: String?
    /// The last check that got an answer (200 or 304).
    var checkedAt: Date?
    /// The last check started, whatever its outcome: the schedule counts from it.
    var attemptedAt: Date?
    /// Areas that differ from the bundled copy; empty when it matches.
    var areas: [String] = []
    /// Fingerprint of the differing live spec, so wording-only edits don't count as a new change.
    var changeToken: String?
    /// Slant's `Last-Modified` when this change was first seen.
    var changedOn: Date?
    /// The `changeToken` the seller dismissed.
    var dismissedToken: String?

    var hasChange: Bool { changeToken != nil && !areas.isEmpty }
}

/// A header value safe to save and send back: printable ASCII, at most 256 characters.
func slantAPIHeaderValue(_ raw: String?) -> String? {
    guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text.count <= 256,
          text.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value <= 0x7E }) else { return nil }
    return text
}

/// An HTTP date (`Last-Modified`), or nil.
func slantAPIHTTPDate(_ raw: String?) -> Date? {
    guard let text = raw?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    for format in ["EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy"] {
        formatter.dateFormat = format
        if let date = formatter.date(from: text) { return date }
    }
    return nil
}

func encodeSlantAPICheckRecord(_ record: SlantAPICheckRecord) -> [String: Any] {
    var result: [String: Any] = ["version": 1, "bundledFingerprint": record.bundledFingerprint, "areas": record.areas]
    if let etag = record.etag { result["etag"] = etag }
    if let lastModified = record.lastModified { result["lastModified"] = lastModified }
    if let date = record.checkedAt { result["checkedAt"] = date.timeIntervalSince1970 }
    if let date = record.attemptedAt { result["attemptedAt"] = date.timeIntervalSince1970 }
    if let token = record.changeToken { result["changeToken"] = token }
    if let date = record.changedOn { result["changedOn"] = date.timeIntervalSince1970 }
    if let token = record.dismissedToken { result["dismissedToken"] = token }
    return result
}

private func slantAPIToken(_ value: Any?) -> String? {
    guard let text = value as? String, text.count == 64, text.allSatisfy(\.isHexDigit) else { return nil }
    return text
}

/// Lenient: unusable fields are dropped. A record made against another bundled copy (another Studio build) is
/// discarded, so its cache headers, areas and dismissal never apply to a different baseline.
func decodeSlantAPICheckRecord(_ value: Any?, bundledFingerprint: String) -> SlantAPICheckRecord {
    let fresh = SlantAPICheckRecord(bundledFingerprint: bundledFingerprint)
    guard let root = value as? [String: Any], root["bundledFingerprint"] as? String == bundledFingerprint else { return fresh }
    func date(_ raw: Any?) -> Date? {
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let seconds = number.doubleValue
        guard seconds.isFinite, seconds > 0, seconds < 1e11 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
    var record = fresh
    record.etag = slantAPIHeaderValue(root["etag"] as? String)
    record.lastModified = slantAPIHeaderValue(root["lastModified"] as? String)
    record.checkedAt = date(root["checkedAt"])
    record.attemptedAt = date(root["attemptedAt"])
    record.areas = slantAPISavedAreas((root["areas"] as? [Any] ?? []).compactMap { $0 as? String })
    record.changeToken = slantAPIToken(root["changeToken"])
    record.changedOn = date(root["changedOn"])
    record.dismissedToken = slantAPIToken(root["dismissedToken"])
    // Cache headers without a comparison to go with them would turn a 304 into "unchanged".
    if record.checkedAt == nil { record.etag = nil; record.lastModified = nil }
    if record.changeToken == nil || record.areas.isEmpty { record.changeToken = nil; record.changedOn = nil; record.areas = [] }
    return record
}

func slantAPISavedAreas(_ areas: [String]) -> [String] {
    var seen = Set<String>()
    return areas.map(slantAPIAreaName).filter { seen.insert($0).inserted }.prefix(slantAPIMaxSavedAreas).map { $0 }
}

/// After a 200 that was compared. A spec that matches clears the change; a differing one keeps its first-seen date
/// until it changes again (wording-only edits don't).
func slantAPIRecordAfterFetch(_ record: SlantAPICheckRecord, comparison: SlantAPIComparison, etag: String?,
                              lastModified: String?, now: Date) -> SlantAPICheckRecord {
    var next = record
    next.etag = slantAPIHeaderValue(etag)
    next.lastModified = slantAPIHeaderValue(lastModified)
    next.checkedAt = now
    if comparison.difference.isEmpty {
        next.areas = []
        next.changeToken = nil
        next.changedOn = nil
    } else {
        next.areas = slantAPISavedAreas(comparison.difference.areas)
        if next.changeToken != comparison.liveFingerprint {
            next.changeToken = comparison.liveFingerprint
            next.changedOn = slantAPIHTTPDate(lastModified)
        }
    }
    return next
}

/// The conditional headers for the next request: only with a comparison already saved.
func slantAPIConditionalHeaders(_ record: SlantAPICheckRecord) -> (etag: String?, lastModified: String?) {
    guard record.checkedAt != nil else { return (nil, nil) }
    return (record.etag, record.lastModified)
}

// MARK: - When to check

enum SlantAPICheckDecision: Equatable {
    case checkNow
    case wait(TimeInterval)
}

/// Due 24 hours after the last attempt (whatever its outcome, so a failure waits for the next scheduled check), only
/// with a Slant key and the bundled copy. A last attempt in the future (the clock moved back) is due now.
func slantAPICheckDecision(hasKey: Bool, bundleAvailable: Bool, lastAttempt: Date?, now: Date) -> SlantAPICheckDecision {
    guard hasKey, bundleAvailable else { return .wait(slantAPIIdleRecheck) }
    guard let lastAttempt, lastAttempt <= now else { return .checkNow }
    let remaining = lastAttempt.addingTimeInterval(slantAPICheckInterval).timeIntervalSince(now)
    guard remaining > 0 else { return .checkNow }
    return .wait(min(slantAPIMaxWait, max(1, remaining)))
}

// MARK: - The request

/// A keyless GET of the public spec: https only, no cookies, no Authorization, conditional when a comparison is saved.
func slantAPISpecRequest(etag: String?, lastModified: String?) -> URLRequest {
    var request = URLRequest(url: slantAPISpecURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: slantAPISpecTimeout)
    request.httpMethod = "GET"
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    if let etag = slantAPIHeaderValue(etag) { request.setValue(etag, forHTTPHeaderField: "If-None-Match") }
    if let lastModified = slantAPIHeaderValue(lastModified) { request.setValue(lastModified, forHTTPHeaderField: "If-Modified-Since") }
    return request
}

/// Whether a request may be sent by the spec fetcher: https to Slant's host, a GET, and no credentials of any kind.
func slantAPISpecRequestIsSafe(_ request: URLRequest) -> Bool {
    guard let url = request.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == slantAPISpecHost,
          url.user == nil, url.password == nil, (request.httpMethod ?? "GET") == "GET", request.httpBody == nil else { return false }
    let headers = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
    return !headers.contains { ["authorization", "cookie", "x-api-key", "proxy-authorization"].contains($0) }
}

enum SlantAPISpecFetchResult: Equatable {
    case notModified
    case fetched(Data, etag: String?, lastModified: String?)
}

enum SlantAPISpecFetchError: Error, Equatable {
    case unsafeRequest
    case noConnection
    case timedOut
    case transport
    case redirected(Int)
    case http(Int)
    case tooLarge
    case unreadable
    /// A 304 to a request that wasn't conditional.
    case unexpectedNotModified
}

func slantAPIFetchErrorText(_ error: SlantAPISpecFetchError) -> String {
    switch error {
    case .unsafeRequest: "the request wasn’t to Slant’s public address"
    case .noConnection: "no internet connection"
    case .timedOut: "Slant didn’t answer in time"
    case .transport: "couldn’t reach Slant"
    case .redirected(let status): "Slant redirected the request (HTTP \(status)), which Studio doesn’t follow"
    case .http(let status): "Slant answered HTTP \(status)"
    case .tooLarge: "the reply was larger than 2 MB"
    case .unreadable: "the reply wasn’t a readable API description"
    case .unexpectedNotModified: "Slant’s reply was unexpected"
    }
}

private final class SlantAPISpecSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        // Normal TLS checks only; never answer a request for credentials.
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

/// Its own ephemeral session, never `APIClient` (which attaches the bearer key): no cookies, cache or credentials,
/// redirects refused, 30 s, at most 2 MB. Never retried.
final class SlantAPISpecFetcher: @unchecked Sendable {
    private let session: URLSession

    /// `protocolClasses` is for tests only (a local stub in place of the network).
    init(protocolClasses: [AnyClass]? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = slantAPISpecTimeout
        configuration.timeoutIntervalForResource = slantAPISpecTimeout
        configuration.waitsForConnectivity = false
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: SlantAPISpecSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func fetch(_ request: URLRequest) async throws -> SlantAPISpecFetchResult {
        guard slantAPISpecRequestIsSafe(request) else { throw SlantAPISpecFetchError.unsafeRequest }
        let conditional = request.value(forHTTPHeaderField: "If-None-Match") != nil || request.value(forHTTPHeaderField: "If-Modified-Since") != nil
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { bytes.task.cancel(); throw SlantAPISpecFetchError.unreadable }
            switch http.statusCode {
            case 304:
                bytes.task.cancel()
                guard conditional else { throw SlantAPISpecFetchError.unexpectedNotModified }
                return .notModified
            case 300..<400:
                bytes.task.cancel()
                throw SlantAPISpecFetchError.redirected(http.statusCode)
            case 200:
                break
            default:
                bytes.task.cancel()
                throw SlantAPISpecFetchError.http(http.statusCode)
            }
            if http.expectedContentLength > Int64(slantAPISpecMaxBytes) { bytes.task.cancel(); throw SlantAPISpecFetchError.tooLarge }
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
                if data.count > slantAPISpecMaxBytes { bytes.task.cancel(); throw SlantAPISpecFetchError.tooLarge }
            }
            return .fetched(data, etag: http.value(forHTTPHeaderField: "ETag"),
                            lastModified: http.value(forHTTPHeaderField: "Last-Modified"))
        } catch let error as SlantAPISpecFetchError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            switch error.code {
            case .cancelled: throw CancellationError()
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff: throw SlantAPISpecFetchError.noConnection
            case .timedOut: throw SlantAPISpecFetchError.timedOut
            default: throw SlantAPISpecFetchError.transport
            }
        } catch {
            throw SlantAPISpecFetchError.transport
        }
    }
}

// MARK: - Runtime signals (session memory only)

private let slantAPIStatusWordCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_")

/// A status Studio doesn't recognise (`orderKnownStatuses`, any case), as a word safe to show and log: A–Z, 0–9 and
/// `_` (anything else becomes `_`), at most 40 characters. Nil for recognised statuses and anything that isn't text.
func slantAPIUnrecognisedStatusWord(_ value: Any?) -> String? {
    guard let text = value as? String else { return nil }
    let normalised = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard !normalised.isEmpty, !orderKnownStatuses.contains(normalised) else { return nil }
    let word = String(normalised.prefix(slantAPIMaxStatusWordLength).map { slantAPIStatusWordCharacters.contains($0) ? $0 : "_" })
    guard word.contains(where: { $0 != "_" }) else { return nil }
    return word
}

/// Whether a 2xx order list reply couldn't be read: no rows although Slant counts some (first pages only, where an
/// empty page can't be the end of a longer list), or rows none of which has a readable status.
func slantAPIOrderListLooksUnreadable(records: [Record], pagination: [String: Any]?, firstPage: Bool) -> Bool {
    if records.isEmpty { return firstPage && (listPaginationTotalCount(pagination) ?? 0) > 0 }
    return !records.contains { record in
        guard let status = orderObject(record.values)["status"] as? String else { return false }
        return !status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What Studio noticed in Slant's replies this session: status words (≤ 10 distinct) and counts. Never order IDs,
/// names, amounts or customer details.
struct SlantAPIRuntimeSignals: Equatable {
    private(set) var statuses: [String] = []
    /// More distinct words were seen than are kept.
    private(set) var moreStatuses = false
    private(set) var unreadableOrderLists = 0

    /// Notes each value's unrecognised status word; returns the words seen for the first time this session.
    mutating func note(statusValues: [Any?]) -> [String] {
        var added: [String] = []
        for value in statusValues {
            guard let word = slantAPIUnrecognisedStatusWord(value), !statuses.contains(word) else { continue }
            guard statuses.count < slantAPIMaxStatusWords else { moreStatuses = true; continue }
            statuses.append(word)
            added.append(word)
        }
        return added
    }

    /// Returns true for the first unreadable list this session.
    mutating func noteUnreadableOrderList() -> Bool {
        unreadableOrderLists += 1
        return unreadableOrderLists == 1
    }
}

// MARK: - What the seller sees

/// What the seller dismissed this session besides the spec change (which is saved as `dismissedToken`).
struct SlantAPINoticeDismissal: Equatable {
    var statuses: Set<String> = []
    var unreadable = false
}

/// "Orders", "Files and Orders", "Files, Orders and Platforms", "Files, Orders, Platforms and 2 more".
func slantAPIAreaListText(_ areas: [String], limit: Int = 3) -> String {
    guard !areas.isEmpty else { return "" }
    if areas.count > limit {
        return areas.prefix(limit).joined(separator: ", ") + " and \(areas.count - limit) more"
    }
    if areas.count == 1 { return areas[0] }
    return areas.dropLast().joined(separator: ", ") + " and " + areas[areas.count - 1]
}

/// The change's date, only when Slant's `Last-Modified` is later than the bundled copy's.
func slantAPIChangeDate(_ record: SlantAPICheckRecord) -> Date? {
    guard let date = record.changedOn, date > slantAPIBundledSpecDate else { return nil }
    return date
}

func slantAPISpecChangeSentence(areas: [String], changedOn: Date?) -> String {
    let list = slantAPIAreaListText(areas)
    let tail = "Some features may not work as expected until Studio is updated."
    if let changedOn {
        let day = changedOn.formatted(date: .abbreviated, time: .omitted)
        return "Slant changed its API on \(day) (\(list)), after this version of Studio was made. \(tail)"
    }
    return "Slant’s API has changed (\(list)) since this version of Studio was made. \(tail)"
}

/// Studio's handling of a status it doesn't recognise, as `orderCanRequestCancellation`, `spendReportCountedStatuses`,
/// `orderNeedsAttention` and `orderPlacedStatuses` implement it.
func slantAPIStatusSentence(_ words: [String], more: Bool) -> String {
    let list = words.joined(separator: ", ") + (more ? " and others" : "")
    let what = words.count == 1 && !more ? "an order status" : "order statuses"
    return "Slant sent \(what) this version of Studio doesn’t recognise (\(list)). Studio treats such orders with caution: it offers no Cancel for them, leaves them out of spending, never marks them late and doesn’t treat them as placed."
}

let slantAPIUnreadableSentence = "Slant sent an order list Studio couldn’t read, so some orders may not be shown."

/// The notice's lines, empty when hidden: the spec change unless dismissed, statuses not yet dismissed, and an
/// unreadable order list unless dismissed.
func slantAPINoticeLines(record: SlantAPICheckRecord, signals: SlantAPIRuntimeSignals, dismissal: SlantAPINoticeDismissal) -> [String] {
    var lines: [String] = []
    if record.hasChange, record.changeToken != record.dismissedToken {
        lines.append(slantAPISpecChangeSentence(areas: record.areas, changedOn: slantAPIChangeDate(record)))
    }
    let newStatuses = signals.statuses.filter { !dismissal.statuses.contains($0) }
    if !newStatuses.isEmpty { lines.append(slantAPIStatusSentence(newStatuses, more: signals.moreStatuses)) }
    if signals.unreadableOrderLists > 0, !dismissal.unreadable { lines.append(slantAPIUnreadableSentence) }
    return lines
}

/// Dismiss hides what is shown now: the spec change until it changes again, and this session's statuses and
/// unreadable lists until a new status appears.
func slantAPIDismissing(record: SlantAPICheckRecord, signals: SlantAPIRuntimeSignals, dismissal: SlantAPINoticeDismissal)
    -> (record: SlantAPICheckRecord, dismissal: SlantAPINoticeDismissal) {
    var nextRecord = record
    if record.hasChange { nextRecord.dismissedToken = record.changeToken }
    var nextDismissal = dismissal
    nextDismissal.statuses.formUnion(signals.statuses)
    if signals.unreadableOrderLists > 0 { nextDismissal.unreadable = true }
    return (nextRecord, nextDismissal)
}

/// Settings › Advanced › Slant API: the state of the comparison.
func slantAPISettingsStateText(record: SlantAPICheckRecord, bundleAvailable: Bool) -> String {
    guard bundleAvailable else { return "Studio’s copy of Slant’s API description is missing, so it can’t compare." }
    guard record.checkedAt != nil else { return "Not checked yet." }
    guard record.hasChange else { return "Matches the API this version of Studio was made for." }
    var text = "Changed since this version of Studio was made: \(slantAPIAreaListText(record.areas, limit: slantAPIMaxSavedAreas))."
    if let date = slantAPIChangeDate(record) {
        text += " Slant updated it on \(date.formatted(date: .abbreviated, time: .omitted))."
    }
    return text
}

/// Activity (developer tools) after a check: no account data, only areas and outcome.
func slantAPICheckActivityDetail(_ outcome: Result<SlantAPIDifference?, SlantAPISpecFetchError>) -> String {
    switch outcome {
    case .success(nil): return "Not changed since the last check"
    case .success(let difference?):
        if difference.isEmpty { return "Matches the API this version of Studio was made for" }
        return "Changed: \(slantAPIAreaListText(difference.areas, limit: slantAPIMaxSavedAreas)) (\(difference.operations.count) operations, \(difference.definitions.count) definitions)"
    case .failure(let error): return "Couldn’t check: \(slantAPIFetchErrorText(error))"
    }
}

// MARK: - The watcher

/// Checks Slant's public API description once a day while Studio runs with a Slant key, and collects this session's
/// order-reply signals. It never sets `busy`, never goes through `store.run`, never touches the unknown-outcome lock
/// or `store.orders`, sends no key, and retries nothing before the next scheduled check.
@MainActor final class SlantAPIWatch: ObservableObject {
    static let shared = SlantAPIWatch()

    @Published private(set) var record: SlantAPICheckRecord
    @Published private(set) var checking = false
    /// This session's last failed check, for Settings (memory only).
    @Published private(set) var lastFailure: SlantAPISpecFetchError?
    @Published private(set) var lastFailureAt: Date?
    /// This session's last comparison, for Settings' list of changed operations (memory only).
    @Published private(set) var lastDifference: SlantAPIDifference?
    @Published private(set) var signals = SlantAPIRuntimeSignals()
    @Published private(set) var dismissal = SlantAPINoticeDismissal()

    let bundleAvailable: Bool
    private let bundledData: Data?
    private var bundledUnits: SlantAPISpecUnits?
    private let fetcher = SlantAPISpecFetcher()
    private weak var store: StudioStore?
    private var loop: Task<Void, Never>?
    private var observers: Set<AnyCancellable> = []

    var noticeLines: [String] { slantAPINoticeLines(record: record, signals: signals, dismissal: dismissal) }

    private init() {
        let data = slantAPIBundledSpecData()
        bundledData = data
        bundleAvailable = data != nil
        let fingerprint = data.map(slantAPIFingerprint) ?? ""
        record = decodeSlantAPICheckRecord(UserDefaults.standard.object(forKey: slantAPICheckDefaultsKey), bundledFingerprint: fingerprint)
    }

    func attach(_ store: StudioStore) {
        guard self.store !== store else { return }
        self.store = store
        observers = []
        // Disconnect or removing the key forgets this session's runtime signals (they came from the account's replies).
        store.$apiKey
            .map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] hasKey in
                MainActor.assumeIsolated {
                    guard let self, !hasKey else { return }
                    self.signals = SlantAPIRuntimeSignals()
                    self.dismissal = SlantAPINoticeDismissal()
                }
            }
            .store(in: &observers)
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(slantAPIFirstCheckDelay * 1_000_000_000))
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.scheduledTick()
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
    }

    private func scheduledTick() async -> TimeInterval {
        guard !checking else { return slantAPIIdleRecheck }
        switch slantAPICheckDecision(hasKey: store?.hasKey ?? false, bundleAvailable: bundleAvailable,
                                     lastAttempt: record.attemptedAt, now: Date()) {
        case .wait(let seconds): return seconds
        case .checkNow:
            await performCheck()
            return slantAPIMaxWait
        }
    }

    /// Settings › Advanced › Check Now. Ignored while a check runs.
    func checkNow() {
        guard !checking, bundleAvailable else { return }
        Task { await performCheck() }
    }

    private func performCheck() async {
        guard !checking, let bundledData else { return }
        checking = true
        defer { checking = false }
        let started = Date()
        record.attemptedAt = started
        save()
        if bundledUnits == nil {
            bundledUnits = await Task.detached(priority: .utility) {
                ((try? JSONSerialization.jsonObject(with: bundledData)) as? [String: Any]).flatMap(slantAPISpecUnits)
            }.value
        }
        guard let bundled = bundledUnits else {
            finish(.failure(.unreadable), at: started)
            return
        }
        let headers = slantAPIConditionalHeaders(record)
        do {
            switch try await fetcher.fetch(slantAPISpecRequest(etag: headers.etag, lastModified: headers.lastModified)) {
            case .notModified:
                record.checkedAt = Date()
                finish(.success(nil), at: started)
            case .fetched(let data, let etag, let lastModified):
                let comparison = await Task.detached(priority: .utility) { slantAPICompare(liveData: data, bundled: bundled) }.value
                guard let comparison else {
                    finish(.failure(.unreadable), at: started)
                    return
                }
                record = slantAPIRecordAfterFetch(record, comparison: comparison, etag: etag, lastModified: lastModified, now: Date())
                lastDifference = comparison.difference
                finish(.success(comparison.difference), at: started)
            }
        } catch let error as SlantAPISpecFetchError {
            finish(.failure(error), at: started)
        } catch {
            // Cancelled (Studio is quitting): nothing to report.
            save()
        }
    }

    private func finish(_ outcome: Result<SlantAPIDifference?, SlantAPISpecFetchError>, at started: Date) {
        switch outcome {
        case .success:
            lastFailure = nil
            lastFailureAt = nil
        case .failure(let error):
            lastFailure = error
            lastFailureAt = started
        }
        save()
        let success: Bool
        if case .success = outcome { success = true } else { success = false }
        log(Activity(title: "Check Slant’s API description", detail: slantAPICheckActivityDetail(outcome), success: success))
    }

    /// The notice's Dismiss.
    func dismissNotice() {
        let next = slantAPIDismissing(record: record, signals: signals, dismissal: dismissal)
        dismissal = next.dismissal
        if next.record != record {
            record = next.record
            save()
        }
    }

    // MARK: Runtime hooks (StudioStore and OrderWatch)

    /// A 2xx reply to `GET /orders`. `firstPage`: page 1 of a plain or filtered list (not a search or Load More), the
    /// only replies where no rows while Slant counts some means the reply couldn't be read.
    func noteOrderList(_ response: APIResponse, firstPage: Bool) {
        let records = responseRecords(response)
        noteStatuses(records.map { orderObject($0.values)["status"] })
        if slantAPIOrderListLooksUnreadable(records: records, pagination: responsePagination(response), firstPage: firstPage),
           signals.noteUnreadableOrderList() {
            log(Activity(title: "Unreadable order list", detail: "Slant’s order list reply couldn’t be read by this version of Studio", success: false))
        }
    }

    /// An order read by ID (`GET /orders/{id}`).
    func noteOrder(_ order: [String: Any]) {
        noteStatuses([orderObject(order)["status"]])
    }

    private func noteStatuses(_ values: [Any?]) {
        guard values.contains(where: { slantAPIUnrecognisedStatusWord($0) != nil }) else { return }
        for word in signals.note(statusValues: values) {
            log(Activity(title: "Unrecognised order status", detail: "Slant sent \(word), which this version of Studio doesn’t recognise", success: false))
        }
    }

    private func log(_ activity: Activity) {
        guard let store else { return }
        store.activities.insert(activity, at: 0)
        store.activities = Array(store.activities.prefix(100))
    }

    private func save() {
        UserDefaults.standard.set(encodeSlantAPICheckRecord(record), forKey: slantAPICheckDefaultsKey)
    }
}
