import Foundation

// 3DAPI (dapi.digital): the types shared by the client (DapiClient.swift), the key and session state
// (DapiConnection.swift) and the quote sheet (DapiQuote.swift, DapiQuoteView.swift). See docs/3DAPI_REFERENCE.md.
// Plinth uses 3DAPI only to price a library model for comparison with Slant: an upload, a quote, reads and a
// shipping estimate. It never orders or pays through 3DAPI.

/// The only host that ever receives the 3DAPI key.
let dapiAPIHost = "public-api.dapi.digital"

/// 3DAPI's own limit for a quote file (250 MiB, `quote_file` uploads).
let dapiMaxQuoteFileBytes: Int64 = 262_144_000

/// Money as 3DAPI sends it: an integer amount in minor units and a lower-case ISO currency ("usd" today).
struct DapiMoney: Equatable, Sendable {
    let amountMinor: Int
    let currency: String

    /// The amount in major units, only for USD (the one currency 3DAPI uses today); nil for anything else, which
    /// Plinth shows with its currency code rather than guessing its decimal places.
    var usd: Decimal? {
        guard currency.lowercased() == "usd" else { return nil }
        return Decimal(amountMinor) / 100
    }
}

/// Who the key belongs to (`GET /v2/me`). Kept in memory only.
struct DapiAccount: Equatable, Sendable {
    /// "integrator" or "designer" as 3DAPI sent it (lower-cased); anything else is kept as sent.
    let kind: String
    /// "pending", "approved", "rejected", or nil (always nil for designers).
    let approval: String?
    /// The scopes the key can use now (`effective_scopes`); empty when 3DAPI sent none.
    let effectiveScopes: [String]

    var isIntegrator: Bool { kind == "integrator" }
}

/// An integrator's onboarding state (`GET /v2/integrator/onboarding`). Kept in memory only.
struct DapiOnboarding: Equatable, Sendable {
    /// "collecting", "in_review", "changes_requested" or "approved" (as sent, lower-cased).
    let status: String
    let approvedFiles: Int
    let requiredFiles: Int
    /// Quotes used this onboarding round, and the round's limit (nil once approved: unlimited).
    let uploadsUsed: Int
    let uploadsLimit: Int?
}

/// One extruder slot's suggested material on a ready quote.
struct DapiSuggestedMaterial: Equatable, Sendable {
    let slot: Int
    /// The catalogue material's name, such as "PLA Red", or nil.
    let materialName: String?
    /// "PLA", "PETG" and so on, as the file declared it, or nil.
    let fileFilamentType: String?
    /// "exact", "close" or "approximate", or nil.
    let match: String?
}

/// A quote (`POST /v2/quotes`, `GET /v2/quotes/{id}`, `GET /v2/quotes`).
struct DapiQuote: Equatable, Sendable {
    let id: String
    /// The name Plinth gave it (see `dapiQuoteName` in DapiQuote.swift), or nil.
    let name: String?
    /// "processing", "ready" or "failed" (lower-cased); anything else is kept as sent and treated as not ready.
    let status: String
    /// The price to print ONE unit; nil until ready, and on failure.
    let price: DapiMoney?
    /// 3DAPI's explanation of a failed quote, redacted and capped; nil otherwise.
    let failureReason: String?
    let suggestedMaterials: [DapiSuggestedMaterial]
    let createdAt: Date?

    var isReady: Bool { status == "ready" }
    var isProcessing: Bool { status == "processing" }
    var isFailed: Bool { status == "failed" }
}

/// `POST /v2/integrator/orders/shipping-estimate`: shipping for a quantity of one ready quote to a country.
/// Nothing is created on 3DAPI. The total excludes VAT.
struct DapiShippingEstimate: Equatable, Sendable {
    let countryCode: String
    /// The shipping zone's name, such as "UK" or "EU-Core", or nil when 3DAPI couldn't weigh the order yet.
    let zoneName: String?
    /// "small", "medium" or "large", or nil (flat rate).
    let tier: String?
    let total: DapiMoney
}

/// How a 3DAPI request ended, when it didn't succeed. Every message is already redacted (no key, no signed URL).
enum DapiError: Error, Equatable {
    /// No key is saved, or the saved key couldn't be read.
    case missingKey
    /// Nothing was sent: a local check refused it (file too large or unreadable, unsafe URL, bad ID) or the
    /// connection failed before the request could leave the Mac.
    case notSent(String)
    /// 3DAPI answered with a definite refusal (a 4xx with its error body, other than 408 and 429). `code` is 3DAPI's
    /// stable error code, such as "invalid_file" or "upload_limit_reached"; `message` is its text, redacted.
    case refused(status: Int, code: String?, message: String?)
    /// HTTP 429. `code` tells "rate_limited" apart from "daily_quote_limit_reached" (which resets at midnight UTC);
    /// `retryAt` comes from Retry-After (seconds) or X-RateLimit-Reset (Unix SECONDS, unlike Slant's milliseconds).
    case rateLimited(code: String?, retryAt: Date?)
    /// A write (`create_upload`, the storage PUT or `create_quote`) whose outcome is unknown: a timeout or transport
    /// error after sending, 408, 5xx, or a reply Plinth couldn't read. 3DAPI may have created it.
    case outcomeUnknown(String)
    /// A read failed (transport error, timeout, 5xx or an unreadable reply). Nothing was created.
    case readFailed(String)
}

/// Everything Plinth asks of 3DAPI. `DapiClient` (DapiClient.swift) is the real one; tests use stubs. No method
/// retries anything by itself: each call sends each request at most once.
protocol DapiQuoting: Sendable {
    /// `GET /v2/me`: who the key belongs to.
    func account() async throws -> DapiAccount
    /// `GET /v2/integrator/onboarding`: approval progress and this round's quote allowance (integrators only).
    func onboarding() async throws -> DapiOnboarding
    /// `GET /v2/quotes`, newest first, reading at most `maxPages` pages of 100, and returning only the quotes whose
    /// `name` equals `name` exactly. Read-only.
    func quotes(named name: String, maxPages: Int) async throws -> [DapiQuote]
    /// `POST /v2/uploads` (purpose `quote_file`), then the presigned PUT of the file's bytes to the `upload_url` it
    /// returns (never with the key). Returns the `upl_` ID. A failure after `POST /v2/uploads` was sent is
    /// `.outcomeUnknown` or `.refused`, except a storage link Plinth refuses to use, which is `.notSent`: no bytes
    /// left the Mac, and the empty upload can't become a quote and expires in 24 hours. Nothing is ever sent twice.
    func uploadQuoteFile(at fileURL: URL, fileName: String, contentType: String, idempotencyKey: String) async throws -> String
    /// `POST /v2/quotes` for an upload. Returns the new quote (usually "processing").
    func createQuote(uploadID: String, name: String, idempotencyKey: String) async throws -> DapiQuote
    /// `GET /v2/quotes/{id}`.
    func quote(id: String) async throws -> DapiQuote
    /// `POST /v2/integrator/orders/shipping-estimate` for `quantity` units of one ready quote to `countryCode`
    /// (upper-case ISO alpha-2). Creates nothing.
    func shippingEstimate(quoteID: String, quantity: Int, countryCode: String) async throws -> DapiShippingEstimate
}
