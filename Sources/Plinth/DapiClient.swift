import Foundation

// STUB: replaced wholesale by the client implementer. Keep `init(apiKey:)` and the `DapiQuoting` conformance.

struct DapiClient: DapiQuoting {
    let apiKey: String

    init(apiKey: String) { self.apiKey = apiKey }

    func account() async throws -> DapiAccount { throw DapiError.notSent("Not built yet.") }
    func onboarding() async throws -> DapiOnboarding { throw DapiError.notSent("Not built yet.") }
    func quotes(named name: String, maxPages: Int) async throws -> [DapiQuote] { throw DapiError.notSent("Not built yet.") }
    func uploadQuoteFile(at fileURL: URL, fileName: String, contentType: String, idempotencyKey: String) async throws -> String {
        throw DapiError.notSent("Not built yet.")
    }
    func createQuote(uploadID: String, name: String, idempotencyKey: String) async throws -> DapiQuote { throw DapiError.notSent("Not built yet.") }
    func quote(id: String) async throws -> DapiQuote { throw DapiError.notSent("Not built yet.") }
    func shippingEstimate(quoteID: String, quantity: Int, countryCode: String) async throws -> DapiShippingEstimate {
        throw DapiError.notSent("Not built yet.")
    }
}

/// `DapiError`'s text for the seller. STUB: the client implementer owns the wording.
extension DapiError {
    var userMessage: String { "3DAPI request failed." }
    /// Status-only text for Activity: never a key, URL, file name, price or ID.
    var activityDetail: String { "Failed" }
}

/// Masks a 3DAPI key (`sk_…`), any `x-api-key` value and signed storage URLs. STUB.
func dapiRedacted(_ text: String, secrets: [String] = []) -> String { aiServiceRedacted(text, secrets: secrets) }
