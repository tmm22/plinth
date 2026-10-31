import Foundation

// 3DAPI (dapi.digital) HTTP client: quotes (an upload, a quote, reads and a shipping estimate) and
// wallet-mode ordering (`DapiOrdering`: materials, wallet, order reads, placing and cancelling). See
// docs/3DAPI_REFERENCE.md for the contract and DapiTypes.swift / DapiOrderTypes.swift for the shared types.
//
// Rules this file keeps:
// - Every API request goes to `https://` + `dapiAPIHost` under `/v2/`, and only those requests carry `x-api-key` and
//   `User-Agent: Plinth/…`. The presigned storage PUT carries neither, nor cookies.
// - Redirects are never followed: a 3xx comes back as it is and counts as a failure.
// - Nothing is retried. Each method sends each request at most once (the paged lists send one request per page).
// - Placing and cancelling an order are checked locally first, sent once with the caller's Idempotency-Key, and never
//   cancelled once handed to the network: a cancellation after that is an unknown outcome.
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
/// Pages of 100 `materials()` may read (the live catalogue is one page).
let dapiMaterialPageLimit = 5
/// What one order reply or list page may hold; anything past these is dropped.
let dapiMaxOrdersPerPage = 100
let dapiMaxOrderLines = 100
let dapiMaxOrderRefunds = 50
/// 3DAPI's limits for an order line and an order.
let dapiOrderUnitRange = 1...10_000
let dapiOrderLineRange = 1...100

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
func dapiOrderIDIsSafe(_ id: String) -> Bool { dapiIDIsSafe(id, prefix: "ord_") }
func dapiMaterialIDIsSafe(_ id: String) -> Bool { dapiIDIsSafe(id, prefix: "mat_") }

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
    return DapiOnboarding(status: status, approvedFiles: approved, requiredFiles: required, uploadsUsed: used, uploadsLimit: limit,
                          orderBlockers: dapiParseOrderBlockers(json["order_blockers"]))
}

/// `order_blockers`: strings (or objects with a `code`), lower-cased, at most 16. An entry Plinth can't read still
/// counts, as "unrecognised", so a blocker is never dropped and ordering never looks open when it isn't.
func dapiParseOrderBlockers(_ value: Any?) -> [String] {
    guard let entries = value as? [Any] else { return [] }
    var blockers: [String] = []
    for entry in entries.prefix(16) {
        let raw = (entry as? String) ?? ((entry as? [String: Any])?["code"] as? String)
        let word = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        let blocker = dapiErrorCodeIsSafe(word) ? word : "unrecognised"
        if !blockers.contains(blocker) { blockers.append(blocker) }
    }
    return blockers
}

/// A quote object. Nil without a valid `qte_` ID or a status. A missing or odd price, material or date is nil; the
/// failure reason is redacted and capped.
func dapiParseQuote(_ json: [String: Any], secrets: [String] = []) -> DapiQuote? {
    guard let id = json["id"] as? String, dapiQuoteIDIsSafe(id), let status = dapiWord(json["status"]) else { return nil }
    let materials: [DapiSuggestedMaterial] = (json["suggested_materials"] as? [Any] ?? []).prefix(32).compactMap { entry in
        guard let object = entry as? [String: Any], let slot = dapiJSONInt(object["slot"]), slot >= 0 else { return nil }
        let material = object["material"] as? [String: Any]
        // Only a well-formed `mat_` ID is kept: it may later be sent as an order line's material.
        let materialID = (material?["id"] as? String).flatMap { dapiMaterialIDIsSafe($0) ? $0 : nil }
        return DapiSuggestedMaterial(slot: slot, materialName: dapiDisplayText(material?["name"]),
                                     fileFilamentType: dapiDisplayText(object["file_filament_type"], limit: 40),
                                     match: dapiWord(object["match"]), materialID: materialID)
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

/// A catalogue material. Nil without a `mat_` ID (custom materials may have none) or a name.
func dapiParseMaterial(_ json: [String: Any]) -> DapiMaterial? {
    guard let id = json["id"] as? String, dapiMaterialIDIsSafe(id), let name = dapiDisplayText(json["name"]) else { return nil }
    let hex = (json["color_hex"] as? String).flatMap { text -> String? in
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.utf8.count == 7, trimmed.hasPrefix("#"),
              trimmed.utf8.dropFirst().allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) }) else { return nil }
        return trimmed.uppercased()
    }
    return DapiMaterial(id: id, name: name, color: dapiDisplayText(json["color"], limit: 60), colorHex: hex,
                        filamentType: dapiDisplayText(json["filament_type"], limit: 40)?.lowercased())
}

/// `GET /v2/wallet`. Nil without a readable balance.
func dapiParseWallet(_ json: [String: Any]) -> DapiWallet? {
    guard let balance = dapiMoney(json["balance"]) else { return nil }
    return DapiWallet(balance: balance, sampleCredit: dapiMoney(json["sample_credit"]),
                      sampleCreditExpiresAt: dapiDate(json["sample_credit_expires_at"]))
}

/// An upper-case ISO alpha-2 code, or nil.
private func dapiCountryCode(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).uppercased(), text.utf8.count == 2,
          text.utf8.allSatisfy({ (0x41...0x5A).contains($0) }) else { return nil }
    return text
}

/// A JSON number in 0…1 as a Decimal (from its shortest decimal form), or nil.
private func dapiFraction(_ value: Any?) -> Decimal? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
    let double = number.doubleValue
    guard double.isFinite, (0...1).contains(double) else { return nil }
    return Decimal(string: "\(double)")
}

/// `charges`. Nil unless items, shipping, VAT and total are all readable money: a partial set must never read as a total.
func dapiParseOrderCharges(_ value: Any?) -> DapiOrderCharges? {
    guard let json = value as? [String: Any], let items = dapiMoney(json["items"]), let shipping = dapiMoney(json["shipping"]),
          let vatObject = json["vat"] as? [String: Any], let vat = dapiMoney(vatObject["amount"]),
          let total = dapiMoney(json["total"]) else { return nil }
    return DapiOrderCharges(paidBy: dapiWord(json["paid_by"]) ?? "", items: items, shipping: shipping, vat: vat,
                            vatRate: dapiFraction(vatObject["rate"]) ?? 0, vatIncluded: dapiJSONBool(vatObject["included"]) ?? false,
                            vatCountry: dapiCountryCode(vatObject["country"]), sampleCredit: dapiMoney(json["sample_credit"]),
                            total: total)
}

/// One order line. Nil without an ID, a `qte_` quote ID or a quantity of at least 1. Materials come from
/// `material_slots` only (the plain `materials` list doesn't say which slot each is in).
func dapiParseOrderItem(_ json: [String: Any]) -> DapiOrderItem? {
    guard let id = dapiDisplayText(json["id"], limit: dapiMaxIDLength),
          let quote = json["quote"] as? [String: Any], let quoteID = quote["id"] as? String, dapiQuoteIDIsSafe(quoteID),
          let quantity = dapiJSONInt(json["quantity"]), quantity >= 1 else { return nil }
    let slots: [DapiMaterialSlot] = (json["material_slots"] as? [Any] ?? []).prefix(16).compactMap { entry in
        guard let object = entry as? [String: Any], let slot = dapiJSONInt(object["slot"]), (1...16).contains(slot),
              let material = object["material"] as? [String: Any], let materialID = material["id"] as? String,
              dapiMaterialIDIsSafe(materialID) else { return nil }
        return DapiMaterialSlot(slot: slot, materialID: materialID, materialName: dapiDisplayText(material["name"]))
    }
    return DapiOrderItem(id: id, quoteID: quoteID, quoteName: dapiDisplayText(quote["name"], limit: 200),
                         materials: slots.sorted { $0.slot < $1.slot }, quantity: quantity, unitPrice: dapiMoney(json["unit_price"]),
                         productionUnitPrice: dapiMoney(json["production_unit_price"]), total: dapiMoney(json["total"]))
}

/// An order (`IntegratorOrder`). Nil without an `ord_` ID, a number or a status. Everything else is lenient: an
/// unknown status is kept as `.unknown`, null customer and address fields are nil, `items` absent (a list read without
/// `expand[]=items`) is nil, unreadable lines and refunds are skipped, and lists are capped.
func dapiParseOrder(_ json: [String: Any]) -> DapiOrder? {
    guard let id = json["id"] as? String, dapiOrderIDIsSafe(id),
          let number = dapiDisplayText(json["number"], limit: 64),
          let statusWord = dapiDisplayText(json["status"], limit: 64) else { return nil }
    let customer = json["customer"] as? [String: Any]
    let address = json["shipping_address"] as? [String: Any]
    let shipping = json["shipping"] as? [String: Any]
    let mode = dapiWord(json["mode"]) ?? {
        switch dapiWord(json["channel"]) {
        case "integrator_wallet": return "wallet"
        case "integrator_checkout": return "checkout"
        default: return ""
        }
    }()
    var items: [DapiOrderItem]?
    if let entries = json["items"] as? [Any] {
        items = entries.prefix(dapiMaxOrderLines).compactMap { ($0 as? [String: Any]).flatMap(dapiParseOrderItem) }
    }
    let refunds: [DapiRefund] = (json["refunds"] as? [Any] ?? []).prefix(dapiMaxOrderRefunds).compactMap { entry in
        guard let object = entry as? [String: Any], let refundID = dapiDisplayText(object["id"], limit: dapiMaxIDLength),
              let amount = dapiMoney(object["amount"]) else { return nil }
        return DapiRefund(id: refundID, amount: amount, createdAt: dapiDate(object["created_at"]))
    }
    let itemCount = dapiJSONInt(json["item_count"]).flatMap { $0 >= 0 ? $0 : nil } ?? items?.reduce(0) { $0 + $1.quantity } ?? 0
    return DapiOrder(
        id: id, number: number, status: DapiOrderStatus(raw: dapiRedacted(statusWord, limit: 64)), mode: mode,
        reference: dapiDisplayText(json["reference"], limit: 100),
        customerName: dapiDisplayText(customer?["name"], limit: 200), customerEmail: dapiDisplayText(customer?["email"], limit: 320),
        formattedAddress: dapiDisplayText(address?["formatted"], limit: 500), city: dapiDisplayText(address?["city"], limit: 100),
        countryName: dapiDisplayText(address?["country"], limit: 100), countryCode: dapiCountryCode(address?["country_code"]),
        charges: dapiParseOrderCharges(json["charges"]),
        shipping: DapiOrderShipping(tier: dapiWord(shipping?["tier"]), carrier: dapiDisplayText(shipping?["carrier"], limit: 80),
                                    trackingNumber: dapiDisplayText(shipping?["tracking_number"], limit: 100),
                                    shippedAt: dapiDate(shipping?["shipped_at"])),
        itemCount: itemCount, items: items, refunds: refunds,
        createdAt: dapiDate(json["created_at"]), updatedAt: dapiDate(json["updated_at"]))
}

// MARK: Order requests

/// The JSON-schema length of a string (Unicode scalars).
private func dapiLength(_ text: String) -> Int { text.unicodeScalars.count }

/// A trimmed optional field: nil when absent or empty.
private func dapiOptionalField(_ text: String?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func dapiHasControlCharacters(_ text: String, allowingLineBreaks: Bool = false) -> Bool {
    text.unicodeScalars.contains { scalar in
        if allowingLineBreaks, scalar == "\n" || scalar == "\r" || scalar == "\t" { return false }
        return CharacterSet.controlCharacters.contains(scalar)
    }
}

/// `^[A-Za-z0-9_-]{1,100}$`.
func dapiOrderReferenceIsValid(_ reference: String) -> Bool {
    !reference.isEmpty && reference.utf8.count <= 100
        && reference.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || $0 == 0x5F || $0 == 0x2D }
}

/// An email 3DAPI is likely to accept: one `@` with text before it, a dotted domain after it, no spaces, ≤ 254.
func dapiEmailLooksValid(_ email: String) -> Bool {
    let parts = email.split(separator: "@", omittingEmptySubsequences: false)
    guard parts.count == 2, !parts[0].isEmpty, email.utf8.count <= 254,
          !email.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else { return false }
    let domain = parts[1].split(separator: ".", omittingEmptySubsequences: false)
    return domain.count >= 2 && domain.allSatisfy { !$0.isEmpty }
}

/// Why this order can't be sent as it is, or nil. Checked before anything is sent: a problem means nothing was sent.
func dapiOrderRequestProblem(_ request: DapiOrderRequest) -> String? {
    guard dapiOrderLineRange.contains(request.lines.count) else {
        return request.lines.isEmpty ? "Add something to print first." : "3DAPI takes at most 100 lines in one order."
    }
    for line in request.lines {
        guard dapiQuoteIDIsSafe(line.quoteID) else { return "A line’s quote ID isn’t one 3DAPI issues. Get the quote again." }
        guard dapiOrderUnitRange.contains(line.quantity) else { return "Each line must be 1 to 10,000 units." }
        if case .slots(let slots) = line.materials {
            guard (1...16).contains(slots.count) else { return "Choose a material for each colour slot, or use the suggested materials." }
            guard slots.allSatisfy({ (1...16).contains($0.slot) }), Set(slots.map(\.slot)).count == slots.count else {
                return "Each colour slot (1 to 16) can have only one material."
            }
            guard slots.allSatisfy({ dapiMaterialIDIsSafe($0.materialID) }) else {
                return "A chosen material isn’t one 3DAPI lists. Reload the materials and choose again."
            }
        }
    }
    guard dapiOrderReferenceIsValid(request.reference) else {
        return "Plinth couldn’t make a valid order reference, so nothing was sent. Try again."
    }
    let recipient = request.recipient
    let name = recipient.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...200).contains(dapiLength(name)), !dapiHasControlCharacters(name) else { return "Enter the recipient’s name (up to 200 characters)." }
    let email = recipient.email.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !email.isEmpty else { return "3DAPI needs the recipient’s email address." }
    guard dapiEmailLooksValid(email) else { return "The recipient’s email address doesn’t look right." }
    if let phone = dapiOptionalField(recipient.phone), dapiLength(phone) > 40 || dapiHasControlCharacters(phone) {
        return "The phone number must be 40 characters or fewer."
    }
    let line1 = recipient.line1.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...200).contains(dapiLength(line1)), !dapiHasControlCharacters(line1) else { return "Enter the first address line (up to 200 characters)." }
    if let line2 = dapiOptionalField(recipient.line2), dapiLength(line2) > 200 || dapiHasControlCharacters(line2) {
        return "The second address line must be 200 characters or fewer."
    }
    let city = recipient.city.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...100).contains(dapiLength(city)), !dapiHasControlCharacters(city) else { return "Enter the town or city (up to 100 characters)." }
    if let state = dapiOptionalField(recipient.state), dapiLength(state) > 100 || dapiHasControlCharacters(state) {
        return "The state, county or region must be 100 characters or fewer."
    }
    if let postal = dapiOptionalField(recipient.postalCode), dapiLength(postal) > 20 || dapiHasControlCharacters(postal) {
        return "The postcode must be 20 characters or fewer."
    }
    guard dapiCountryCode(recipient.countryCode) != nil else { return "Choose the delivery country." }
    if let notes = dapiOptionalField(request.customerNotes), dapiLength(notes) > 2000 || dapiHasControlCharacters(notes, allowingLineBreaks: true) {
        return "Order notes must be 2,000 characters or fewer."
    }
    return nil
}

/// The `POST /v2/integrator/orders` body for a wallet-mode order: each line with `use_suggested_materials: true` or
/// `materials` (never both), the address and customer (empty optional fields as null), the reference and notes, and
/// `use_sample_credit: true` only when the seller ticked it (`request.useSampleCredit`; wallet mode, which is the only
/// mode Plinth sends; otherwise the key is omitted). It never carries `checkout`, `unit_sales_price` or extras. Check
/// `dapiOrderRequestProblem` first.
func dapiOrderRequestBody(_ request: DapiOrderRequest) -> [String: Any] {
    func nullable(_ text: String?) -> Any { dapiOptionalField(text) ?? NSNull() }
    let items: [[String: Any]] = request.lines.map { line in
        var item: [String: Any] = ["quote": line.quoteID, "quantity": line.quantity]
        switch line.materials {
        case .suggested:
            item["use_suggested_materials"] = true
        case .slots(let slots):
            item["materials"] = slots.sorted { $0.slot < $1.slot }.map { ["slot": $0.slot, "material": $0.materialID] as [String: Any] }
        }
        return item
    }
    let recipient = request.recipient
    var body: [String: Any] = [
        "mode": "wallet",
        "items": items,
        "shipping_address": [
            "line1": recipient.line1.trimmingCharacters(in: .whitespacesAndNewlines),
            "line2": nullable(recipient.line2),
            "city": recipient.city.trimmingCharacters(in: .whitespacesAndNewlines),
            "state": nullable(recipient.state),
            "postal_code": nullable(recipient.postalCode),
            "country_code": recipient.countryCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        ] as [String: Any],
        "customer": [
            "name": recipient.name.trimmingCharacters(in: .whitespacesAndNewlines),
            "email": recipient.email.trimmingCharacters(in: .whitespacesAndNewlines),
            "phone": nullable(recipient.phone)
        ] as [String: Any],
        "reference": request.reference,
        "customer_notes": nullable(request.customerNotes)
    ]
    // Only an explicit true is sent; without the key 3DAPI charges the order in full (its default is false).
    if request.useSampleCredit { body["use_sample_credit"] = true }
    return body
}

/// The query for `GET /v2/integrator/orders`: `status` repeated (form style, not `status[]`), `reference`, `search`
/// (trimmed, ≤ 100), `created_after` / `created_before` (ISO 8601 UTC), `limit` clamped to 1…100, `cursor`, and
/// `expand[]=items`. Throws `.notSent` for a filter 3DAPI would refuse or that can't match.
func dapiOrderListQueryItems(_ query: DapiOrderListQuery) throws -> [(String, String)] {
    var items: [(String, String)] = []
    var seen: Set<String> = []
    for status in query.statuses {
        guard !status.isUnknown else { throw DapiError.notSent("Plinth can filter 3DAPI orders only by the statuses 3DAPI documents.") }
        if seen.insert(status.raw).inserted { items.append(("status", status.raw)) }
    }
    if let reference = dapiOptionalField(query.reference) {
        guard dapiLength(reference) <= 100, !dapiHasControlCharacters(reference) else {
            throw DapiError.notSent("An order reference is at most 100 characters, so nothing was looked up.")
        }
        items.append(("reference", reference))
    }
    if let search = dapiOptionalField(query.search), !dapiHasControlCharacters(search) {
        let capped = String(String.UnicodeScalarView(search.unicodeScalars.prefix(100))).trimmingCharacters(in: .whitespacesAndNewlines)
        if !capped.isEmpty { items.append(("search", capped)) }
    }
    if let after = query.createdAfter { items.append(("created_after", dapiDatePlain.format(after))) }
    if let before = query.createdBefore { items.append(("created_before", dapiDatePlain.format(before))) }
    items.append(("limit", String(min(max(query.limit, 1), 100))))
    if let cursor = query.cursor {
        guard !cursor.isEmpty, cursor.utf8.count <= 2048 else { throw DapiError.notSent("The list position isn’t usable. Reload the list.") }
        items.append(("cursor", cursor))
    }
    // Sent percent-encoded (`expand%5B%5D=items`, the standard form). 3DAPI's spec names the parameter `expand[]`;
    // whether its server decodes the encoded brackets is unverified live. A page whose orders come back without
    // `items` still reads as a normal page: those orders have `items == nil` (not an error), and the Orders screen
    // keeps the lines it already holds for them.
    if query.expandItems { items.append(("expand[]", "items")) }
    return items
}

/// 3DAPI's error body: its stable `code` (only `[a-z0-9_]`, ≤ 64, so it is safe in Activity) and its `message`,
/// redacted. Nil when the body isn't a JSON object.
func dapiErrorBody(_ data: Data, secrets: [String] = []) -> (code: String?, message: String?)? {
    guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    let code = (json["code"] as? String).flatMap { text -> String? in
        text.utf8.count <= 64 && !text.isEmpty && text.utf8.allSatisfy({ (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }) ? text : nil
    }
    var message = (json["message"] as? String).map { dapiRedacted($0, secrets: secrets) }.flatMap { $0.isEmpty ? nil : $0 }
    if let code, let summary = dapiErrorDetailsSummary(code: code, details: json["details"] as? [String: Any], secrets: secrets) {
        message = dapiRedacted([message, summary].compactMap { $0 }.joined(separator: " "), secrets: secrets, limit: 600)
    }
    return (code, message)
}

/// A scope name such as "orders:write".
private func dapiScopeName(_ value: Any?) -> String? {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces).lowercased(), text.utf8.count <= 40 else { return nil }
    let parts = text.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2, parts.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (0x61...0x7A).contains($0) || $0 == 0x5F } }) else { return nil }
    return text
}

/// "This quote needs a material for slots 1 and 2." from `material_slots_mismatch`'s `details.expected_slots` (slot
/// numbers 1–16, or objects with a `slot`; 3DAPI doesn't document the shape further), or nil when none is readable.
func dapiExpectedSlotsSentence(_ value: Any?) -> String? {
    var slots: [Int] = []
    for entry in (value as? [Any] ?? []).prefix(16) {
        let slot = dapiJSONInt(entry) ?? dapiJSONInt((entry as? [String: Any])?["slot"])
        if let slot, (1...16).contains(slot), !slots.contains(slot) { slots.append(slot) }
    }
    guard !slots.isEmpty else { return nil }
    let numbers = slots.sorted().map(String.init)
    if numbers.count == 1 { return "This quote needs a material for slot \(numbers[0])." }
    return "This quote needs a material for slots \(numbers.dropLast().joined(separator: ", ")) and \(numbers.last!)."
}

/// The parts of `details` worth showing, as a sentence appended to 3DAPI's message: the fields `validation_failed` lists
/// (≤ 5), the scopes `missing_scope` names, the requirement codes `compliance_blocked` lists and the slots
/// `material_slots_mismatch` expects. Never `fix_url` or any other link. 3DAPI doesn't document the shape of `details.errors`, so the usual shapes are read.
func dapiErrorDetailsSummary(code: String, details: [String: Any]?, secrets: [String] = []) -> String? {
    guard let details else { return nil }
    switch code {
    case "validation_failed":
        func fieldName(_ value: Any?) -> String? {
            if let path = value as? [Any] {
                let joined = path.map { "\($0)" }.joined(separator: ".")
                return joined.isEmpty ? nil : dapiDisplayText(joined, limit: 60)
            }
            return dapiDisplayText(value, limit: 60)
        }
        var problems: [String] = []
        if let list = details["errors"] as? [Any] {
            for entry in list {
                if let text = dapiDisplayText(entry, limit: 120) {
                    problems.append(text)
                } else if let object = entry as? [String: Any] {
                    let field = fieldName(object["field"] ?? object["path"] ?? object["name"] ?? object["loc"] ?? object["param"])
                    guard let text = dapiDisplayText(object["message"] ?? object["msg"] ?? object["detail"] ?? object["reason"], limit: 120) else {
                        if let field { problems.append(field) }
                        continue
                    }
                    problems.append(field.map { "\($0): \(text)" } ?? text)
                }
            }
        } else if let map = details["errors"] as? [String: Any] {
            for field in map.keys.sorted() {
                let value = map[field]
                let text = dapiDisplayText(value, limit: 120) ?? ((value as? [Any])?.compactMap { dapiDisplayText($0, limit: 120) }.first)
                problems.append(text.map { "\(field): \($0)" } ?? field)
            }
        }
        let shown = problems.prefix(5).map { dapiRedacted($0, secrets: secrets, limit: 160) }
        guard !shown.isEmpty else { return nil }
        let more = problems.count > shown.count ? " (and \(problems.count - shown.count) more)" : ""
        return "Fields: \(shown.joined(separator: "; "))\(more)."
    case "missing_scope":
        var scopes: [String] = []
        for key in ["scope", "required_scope", "missing_scope"] { if let scope = dapiScopeName(details[key]) { scopes.append(scope) } }
        for key in ["scopes", "required_scopes", "missing_scopes"] {
            scopes += (details[key] as? [Any] ?? []).prefix(8).compactMap(dapiScopeName)
        }
        var unique: [String] = []
        for scope in scopes where !unique.contains(scope) { unique.append(scope) }
        return unique.isEmpty ? nil : "Scope needed: \(unique.prefix(4).joined(separator: ", "))."
    case "compliance_blocked":
        let requirements = (details["requirements"] as? [Any] ?? []).prefix(8).compactMap { entry -> String? in
            let raw = (entry as? String) ?? ((entry as? [String: Any])?["code"] as? String)
            guard let word = raw?.trimmingCharacters(in: .whitespaces).lowercased(), dapiErrorCodeIsSafe(word) else { return nil }
            return word
        }
        return requirements.isEmpty ? nil : "Requirements: \(requirements.joined(separator: ", "))."
    case "material_slots_mismatch":
        return dapiExpectedSlotsSentence(details["expected_slots"])
    default:
        return nil
    }
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
    case materials, wallet, listOrders, getOrder, placeOrder, cancelOrder

    /// Writes whose failure after sending leaves the outcome unknown. The shipping estimate is a POST that creates
    /// nothing, so it is classed with reads.
    var isWrite: Bool {
        switch self {
        case .createUpload, .storagePut, .createQuote, .placeOrder, .cancelOrder: return true
        default: return false
        }
    }

    /// Writes that move money: once handed to the network they are never cancelled, so a cancellation reported after
    /// that is an unknown outcome, not a stop.
    var isMoneyWrite: Bool { self == .placeOrder || self == .cancelOrder }

    var method: String {
        switch self {
        case .account, .onboarding, .listQuotes, .getQuote, .materials, .wallet, .listOrders, .getOrder: return "GET"
        case .createUpload, .createQuote, .shippingEstimate, .placeOrder, .cancelOrder: return "POST"
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
        case .materials: return "3DAPI’s materials"
        case .wallet: return "your 3DAPI wallet"
        case .listOrders: return "your 3DAPI orders"
        case .getOrder: return "the 3DAPI order"
        case .createUpload, .storagePut, .createQuote, .placeOrder, .cancelOrder: return "3DAPI’s reply"
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
        case .placeOrder:
            return "Plinth can’t tell whether 3DAPI placed the order and charged you, and didn’t send it again. Look for it in your 3DAPI orders before ordering again."
        case .cancelOrder:
            return "Plinth can’t tell whether 3DAPI cancelled the order, and didn’t send it again. Reload the order to see its status before cancelling again."
        default:
            return "Plinth didn’t send it again."
        }
    }
}

/// The error for a transport failure of `operation`.
func dapiClassifyTransportFailure(_ error: Error, operation: DapiOperation) -> Error {
    if dapiIsCancellation(error) {
        // Placing or cancelling an order is never cancelled once sent: if its request was cancelled anyway, it may
        // still have reached 3DAPI.
        if operation.isMoneyWrite { return DapiError.outcomeUnknown("The request stopped before 3DAPI answered. \(operation.unknownConsequence)") }
        return CancellationError()
    }
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
/// - 503 `card_payments_unavailable` to placing an order: `.refused` (3DAPI says no order was created).
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
        // Placing or cancelling an order counts as refused only with 3DAPI's own error code: a bare 4xx may not be
        // 3DAPI's answer, so it can't prove nothing was charged.
        if let body, !operation.isMoneyWrite || body.code != nil {
            return .refused(status: status, code: body.code, message: body.message)
        }
    }
    if status == 503, operation == .placeOrder, let body, body.code == "card_payments_unavailable" {
        return .refused(status: status, code: body.code, message: body.message)
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
            if operation.isMoneyWrite {
                // Placing or cancelling an order runs apart from the caller's task, so cancelling the caller can't cut
                // the request off part-way: it finishes, and its real outcome comes back.
                let transport = self.transport
                reply = try await Task.detached { try await transport.send(request) }.value
            } else {
                reply = try await transport.send(request)
            }
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

// MARK: DapiOrdering

extension DapiClient: DapiOrdering {
    /// Reads pages of 100, following `next_cursor` while `has_more`, for at most `dapiMaterialPageLimit` pages. A
    /// missing or repeated cursor with `has_more` fails the read, as does more than that many pages: a partial catalogue
    /// could hide the material a slot needs. Entries Plinth can't read (custom materials without an ID) are skipped.
    func materials() async throws -> [DapiMaterial] {
        var materials: [DapiMaterial] = []
        var cursor: String?
        var seenCursors: Set<String> = []
        for _ in 0..<dapiMaterialPageLimit {
            var query: [(String, String)] = [("limit", "100")]
            if let cursor { query.append(("cursor", cursor)) }
            let json = try await perform(try makeAPIRequest(method: "GET", path: "/v2/materials", query: query), .materials)
            guard let data = json["data"] as? [Any] else { throw unreadable(.materials) }
            for entry in data.prefix(100) {
                guard let material = (entry as? [String: Any]).flatMap(dapiParseMaterial),
                      !materials.contains(where: { $0.id == material.id }) else { continue }
                materials.append(material)
            }
            guard dapiJSONBool(json["has_more"]) == true else { return materials }
            guard let next = json["next_cursor"] as? String, !next.isEmpty, next.utf8.count <= 2048,
                  !seenCursors.contains(next) else { throw unreadable(.materials) }
            seenCursors.insert(next)
            cursor = next
        }
        throw unreadable(.materials)
    }

    func wallet() async throws -> DapiWallet {
        let json = try await perform(try makeAPIRequest(method: "GET", path: "/v2/wallet"), .wallet)
        guard let wallet = dapiParseWallet(json) else { throw unreadable(.wallet) }
        return wallet
    }

    /// One page. An order Plinth can't read is skipped, except in a `reference` lookup, where it fails the read: the
    /// lookup decides whether an order with an unknown outcome exists, and a skipped one could lead to a second order.
    func orders(_ query: DapiOrderListQuery) async throws -> DapiOrderPage {
        let items = try dapiOrderListQueryItems(query)
        let isLookup = items.contains { $0.0 == "reference" }
        let json = try await perform(try makeAPIRequest(method: "GET", path: "/v2/integrator/orders", query: items), .listOrders)
        guard let data = json["data"] as? [Any] else { throw unreadable(.listOrders) }
        var orders: [DapiOrder] = []
        for entry in data.prefix(dapiMaxOrdersPerPage) {
            guard let order = (entry as? [String: Any]).flatMap(dapiParseOrder) else {
                if isLookup { throw unreadable(.listOrders) }
                continue
            }
            orders.append(order)
        }
        // More rows than asked for is unexpected; in a lookup, rows past the cap could hide the order.
        if isLookup, data.count > dapiMaxOrdersPerPage { throw unreadable(.listOrders) }
        let hasMore = dapiJSONBool(json["has_more"]) == true
        var nextCursor: String?
        if hasMore {
            guard let next = json["next_cursor"] as? String, !next.isEmpty, next.utf8.count <= 2048, next != query.cursor else {
                throw unreadable(.listOrders)
            }
            nextCursor = next
        }
        return DapiOrderPage(orders: orders, hasMore: hasMore, nextCursor: nextCursor)
    }

    func order(id: String) async throws -> DapiOrder {
        guard dapiOrderIDIsSafe(id) else { throw DapiError.notSent("The order ID isn’t one 3DAPI issues, so nothing was sent.") }
        let json = try await perform(try makeAPIRequest(method: "GET", path: "/v2/integrator/orders/\(id)"), .getOrder)
        guard let order = dapiParseOrder(json), order.id == id else { throw unreadable(.getOrder) }
        return order
    }

    func shippingEstimate(lines: [DapiOrderLineRequest], countryCode: String) async throws -> DapiShippingEstimate {
        guard dapiOrderLineRange.contains(lines.count) else {
            throw DapiError.notSent(lines.isEmpty ? "Add something to print first, so 3DAPI can estimate shipping."
                                                  : "3DAPI estimates shipping for at most 100 lines, so nothing was sent.")
        }
        for line in lines {
            guard dapiQuoteIDIsSafe(line.quoteID) else { throw DapiError.notSent("The quote ID isn’t one 3DAPI issues, so nothing was sent.") }
            guard dapiOrderUnitRange.contains(line.quantity) else {
                throw DapiError.notSent("3DAPI estimates shipping for 1 to 10,000 units a line, so nothing was sent.")
            }
        }
        guard let country = dapiCountryCode(countryCode.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DapiError.notSent("Choose a delivery country first, so 3DAPI can estimate shipping.")
        }
        // Materials don't change shipping, so only the quote and quantity are sent.
        let body: [String: Any] = ["country": country, "items": lines.map { ["quote": $0.quoteID, "quantity": $0.quantity] as [String: Any] }]
        let json = try await perform(try makeAPIRequest(method: "POST", path: "/v2/integrator/orders/shipping-estimate", body: body),
                                     .shippingEstimate)
        guard let estimate = dapiParseShippingEstimate(json, requestedCountry: country) else { throw unreadable(.shippingEstimate) }
        return estimate
    }

    /// Wallet mode: CHARGES AT ONCE. Checked by `dapiOrderRequestProblem` first (a problem is `.notSent`), then sent once
    /// with `idempotencyKey`, apart from the caller's task so it can't be cut off. The order returned is whatever 3DAPI
    /// says, whatever its status: the caller judges it. A 2xx Plinth can't read, or one naming another reference, is an
    /// unknown outcome (the charge may have happened).
    func placeOrder(_ request: DapiOrderRequest, idempotencyKey: String) async throws -> DapiOrder {
        if let problem = dapiOrderRequestProblem(request) { throw DapiError.notSent("\(problem) Nothing was sent.") }
        guard dapiIdempotencyKeyIsValid(idempotencyKey) else {
            throw DapiError.notSent("Plinth couldn’t make a safe request ID for 3DAPI, so nothing was sent. Try again.")
        }
        let urlRequest = try makeAPIRequest(method: "POST", path: "/v2/integrator/orders", body: dapiOrderRequestBody(request),
                                            idempotencyKey: idempotencyKey)
        let json = try await perform(urlRequest, .placeOrder)
        guard let order = dapiParseOrder(json), order.reference == request.reference else { throw unreadable(.placeOrder) }
        return order
    }

    /// Sent once with `idempotencyKey`, without a body, apart from the caller's task. A 2xx Plinth can't read, or one
    /// for another order, is an unknown outcome.
    func cancelOrder(id: String, idempotencyKey: String) async throws -> DapiOrder {
        guard dapiOrderIDIsSafe(id) else { throw DapiError.notSent("The order ID isn’t one 3DAPI issues, so nothing was sent.") }
        guard dapiIdempotencyKeyIsValid(idempotencyKey) else {
            throw DapiError.notSent("Plinth couldn’t make a safe request ID for 3DAPI, so nothing was sent. Try again.")
        }
        let json = try await perform(try makeAPIRequest(method: "POST", path: "/v2/integrator/orders/\(id)/cancel",
                                                        idempotencyKey: idempotencyKey), .cancelOrder)
        guard let order = dapiParseOrder(json), order.id == id else { throw unreadable(.cancelOrder) }
        return order
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

/// The scopes a 3DAPI integrator key may carry, for naming the one a `missing_scope` refusal needs.
/// Every scope in the spec's `Me.effective_scopes` enum (checked 31 Oct 2026). The presets in `Me.scopes` (`pricing`,
/// `order`, `full`) have no colon and are never named.
let dapiKnownScopes = ["quotes:read", "quotes:write", "orders:read_customer", "orders:read", "orders:write", "extras:read",
                       "extras:write", "wallet:read", "webhooks:read", "products:read", "products:write", "stocks:read",
                       "stocks:write", "qc:read", "qc:write"]

/// The first known scope named in 3DAPI's message (which carries `details`' scope, see `dapiErrorDetailsSummary`).
func dapiScopeNamed(in text: String?) -> String? {
    guard let text else { return nil }
    var rest = Substring(text)
    while let range = rest.range(of: #"[a-z_]+:[a-z_]+"#, options: .regularExpression) {
        let token = String(rest[range])
        if dapiKnownScopes.contains(token) { return token }
        rest = rest[range.upperBound...]
    }
    return nil
}

/// The sentence every refused Place Order carries: 3DAPI creates and charges nothing it refuses.
let dapiNothingChargedSentence = "No order was created, so nothing was charged."

/// The seller's text for a definite refusal, by 3DAPI's stable code; 3DAPI's redacted message otherwise. With
/// `placingOrder` (a refused `POST /v2/integrator/orders`), the text always says nothing was charged; codes that only
/// placing an order can return say so either way.
func dapiRefusalMessage(status: Int, code: String?, message: String?, placingOrder: Bool = false) -> String {
    let text = dapiRefusalReason(status: status, code: code, message: message)
    guard placingOrder, !text.contains("charged") else { return text }
    return "\(text) \(dapiNothingChargedSentence)"
}

private func dapiRefusalReason(status: Int, code: String?, message: String?) -> String {
    let quoted = message.map { dapiRedacted($0) }.flatMap { $0.isEmpty ? nil : $0 }
    switch code {
    case "missing_credentials", "invalid_api_key", "invalid_session", "ambiguous_credentials":
        return "3DAPI didn’t accept the API key. Check it in Settings, or create a new key in the 3DAPI dashboard."
    case "missing_scope":
        if let scope = dapiScopeNamed(in: quoted) {
            return "This 3DAPI key doesn’t have the \(scope) permission this needs. Make a key with \(scope) in 3DAPI’s dashboard and save it in Settings › Account."
        }
        return "This 3DAPI key doesn’t have the permission this needs. Make a key with quotes:read, quotes:write and orders:read (and orders:write to place orders) in 3DAPI’s dashboard."
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
        return "A 3DAPI quote isn’t ready yet, so it can’t be used for shipping or ordering. Wait until it’s ready, then try again."
    case "quote_rejected":
        return "3DAPI rejected this file in review, so it can’t estimate shipping for it or print it."
    case "quote_not_approved":
        return "3DAPI hasn’t approved your account yet, so it can’t take orders. \(dapiNothingChargedSentence)"
    case "payment_failed":
        return "3DAPI couldn’t take the payment: the card was declined or the charge failed. \(dapiNothingChargedSentence) Check your card in 3DAPI’s dashboard."
    case "insufficient_balance":
        return "Your 3DAPI wallet doesn’t cover this order and there’s no saved card. \(dapiNothingChargedSentence) Top up the wallet or add a card in 3DAPI’s dashboard."
    case "compliance_blocked":
        var needs: [String] = []
        if quoted?.contains("billing") ?? false { needs.append("your business billing details") }
        if quoted?.contains("responsible") ?? false { needs.append("an EU responsible person (to sell to EU or UK customers from outside the EU and UK)") }
        let what = needs.isEmpty ? "account details 3DAPI asks for" : needs.joined(separator: " and ")
        return "3DAPI can’t take orders from this account yet. Add \(what) in 3DAPI’s dashboard. \(dapiNothingChargedSentence)"
    case "production_unavailable":
        // Account-wide: 3DAPI pauses production for everyone, not for this order.
        return "3DAPI has paused production, so it isn’t taking orders right now. Nothing was charged. Try again later."
    case "card_payments_unavailable":
        return "3DAPI can’t take card payments right now. \(dapiNothingChargedSentence) Try again later."
    case "order_not_cancellable":
        return "3DAPI can’t cancel this order: it’s already cancelled, or a production partner already has it. 3DAPI cancels only orders no production partner has taken yet; to stop this one, email contact@dapi.digital."
    case "order_not_found":
        return "3DAPI has no order with that ID for this account."
    case "extra_not_found", "extra_not_approved":
        return "3DAPI refused an extra part on this order. Plinth doesn’t add extras, so check the order in 3DAPI’s dashboard. \(dapiNothingChargedSentence)"
    case "material_not_allowed":
        return "3DAPI doesn’t offer one of the chosen materials. Reload the materials and choose again. \(dapiNothingChargedSentence)"
    case "material_slots_mismatch":
        // `dapiErrorBody` appends `dapiExpectedSlotsSentence` to the message when 3DAPI names the expected slots.
        let slots = quoted.flatMap { text -> String? in
            guard let range = text.range(of: #"This quote needs a material for slots? [0-9]+(, [0-9]+)*( and [0-9]+)?\."#,
                                         options: .regularExpression) else { return nil }
            return String(text[range])
        }
        if let slots {
            return "The materials chosen don’t match the colour slots this file prints with. \(slots) Choose one material for each, or use the suggested materials. \(dapiNothingChargedSentence)"
        }
        return "The materials chosen don’t match the colour slots this file prints with. Choose one material for each slot the quote lists, or use the suggested materials. \(dapiNothingChargedSentence)"
    case "suggestions_unavailable":
        return "3DAPI has no suggested materials for this quote. Choose a material for each colour slot instead. \(dapiNothingChargedSentence)"
    case "currency_not_supported":
        return "3DAPI refused the currency: it works in US dollars only."
    case "vat_number_invalid":
        return "3DAPI couldn’t confirm the VAT number. \(dapiNothingChargedSentence)"
    case "invalid_cursor":
        return "3DAPI didn’t accept the list position. Reload the list."
    case "shipping_destination_not_served":
        return "3DAPI doesn’t deliver to that country. It delivers worldwide except Russia, Belarus, Iran and Syria."
    case "shipping_zone_not_found":
        return "3DAPI has no shipping rate for that country at the moment."
    case "validation_failed":
        let detailed = message.map { dapiRedacted($0, limit: 600) }.flatMap { $0.isEmpty ? nil : $0 }
        return detailed.map { "3DAPI said the request wasn’t valid: \($0)" } ?? "3DAPI said the request wasn’t valid."
    case "idempotency_key_reused":
        return "3DAPI refused a repeated request that differed from the first. Start again."
    case "rate_limited":
        return "3DAPI is limiting requests for a moment. Try again shortly."
    default:
        return quoted.map { "3DAPI refused the request (HTTP \(status)): \($0)" } ?? "3DAPI refused the request (HTTP \(status))."
    }
}
