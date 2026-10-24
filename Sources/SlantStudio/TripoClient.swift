import Foundation

// MARK: - Tripo
//
// Tripo's v3 API (developers.tripo3d.ai/en/docs, read 24 Oct 2026; not tested live). Two regional sites with
// separate keys: international `https://openapi.tripo3d.ai/v3` and China mainland `https://openapi.tripo3d.com/v3`.
// Header `Authorization: Bearer <key>`. Replies are `{"code": 0, "data": {…}}`; any other code is an error
// (`{"code", "message", "suggestion"}`).
//   - Upload: `POST /v3/files`, multipart field `file` (JPEG/PNG ≤ 20 MB) → `data.file_token`. Free.
//   - Image to model: `POST /v3/generation/image-to-model` with `input` = the file token → `data.task_id`. Generation
//     gives GLB only (20 credits without texture).
//   - Tasks: `GET /v3/tasks/{id}` → `status` (queued, running, success, failed, banned, expired, cancelled),
//     `progress` 0–100, `output.model_url` on success (links expire after about 5 minutes), `error_message` on failure.
//   - Convert: `POST /v3/models/convert` with `input` = the generation task and `format` STL or 3MF → a task whose
//     `output.model_url` is the file. 5 credits, or 10 with any non-default option (`pivot_to_center_bottom`).
//   - Balance: `GET /v3/account/balance` → `data.balance`, `data.frozen` (decimals).
//   - Errors: 401 bad key; 403 no permission or not enough credits (code 2010); 429 code 1007 (rate) or 2000
//     (concurrency, with Retry-After); 2008 content policy. Credits are frozen at create and released on failure.

enum TripoRegion: String, CaseIterable, Identifiable, Sendable {
    case international, chinaMainland
    var id: String { rawValue }

    var title: String {
        switch self {
        case .international: return "International (tripo3d.ai)"
        case .chinaMainland: return "China mainland (tripo3d.com)"
        }
    }

    var apiHost: String {
        switch self {
        case .international: return "openapi.tripo3d.ai"
        case .chinaMainland: return "openapi.tripo3d.com"
        }
    }

    private var site: String {
        switch self {
        case .international: return "https://developers.tripo3d.ai/en"
        case .chinaMainland: return "https://developers.tripo3d.com/en"
        }
    }

    var keysURL: URL { URL(string: "\(site)/keys")! }
    var pricingURL: URL { URL(string: "\(site)/pricing")! }
    var docsURL: URL { URL(string: "\(site)/docs/introduction")! }
    var termsURL: URL { URL(string: "\(site)/terms")! }
}

/// Tripo's published credit prices (developers.tripo3d.ai/en/pricing, 24 Oct 2026; 1 credit = US$0.01). Approximate.
let tripoImageToModelCredits = 20
let tripoConvertBasicCredits = 5
let tripoConvertAdvancedCredits = 10
/// The generation model, pinned so the published price stays right.
let tripoModelVersion = "v3.1-20260211"
/// `face_limit` range Studio sends (without smart low-poly, which costs 10 more credits).
let tripoFaceLimitRange = 500...1_500_000

/// The JSON body for image-to-model: no texture, no PBR, at most `targetTriangles` faces.
func tripoImageToModelBody(fileToken: String, options: ImageTo3DOptions) -> [String: Any] {
    [
        "input": fileToken,
        "model": tripoModelVersion,
        "texture": false,
        "pbr": false,
        "face_limit": imageTo3DClampedTriangles(options.targetTriangles, range: tripoFaceLimitRange)
    ]
}

/// The JSON body for converting a finished generation to STL or 3MF.
func tripoConvertBody(taskID: String, options: ImageTo3DOptions) -> [String: Any] {
    var body: [String: Any] = ["input": taskID, "format": options.format.rawValue.uppercased()]
    if options.originAtBottom { body["pivot_to_center_bottom"] = true }
    return body
}

/// `multipart/form-data` with the photo as the single field `file`.
func tripoUploadBody(image: ImageTo3DImage, boundary: String) -> Data {
    var data = Data()
    data.append(Data("--\(boundary)\r\n".utf8))
    data.append(Data("Content-Disposition: form-data; name=\"file\"; filename=\"photo.\(image.fileExtension)\"\r\n".utf8))
    data.append(Data("Content-Type: \(image.mediaType)\r\n\r\n".utf8))
    data.append(image.data)
    data.append(Data("\r\n--\(boundary)--\r\n".utf8))
    return data
}

/// `data` from a `{"code": 0, "data": {…}}` reply, or nil.
func tripoEnvelopeData(_ root: [String: Any]?) -> [String: Any]? {
    guard let root, (root["code"] as? NSNumber)?.intValue == 0 else { return nil }
    return root["data"] as? [String: Any]
}

func tripoTaskState(_ raw: String?) -> ImageTo3DTaskState {
    switch raw?.lowercased() {
    case "queued": return .queued
    case "running": return .running
    case "success": return .succeeded
    case "failed": return .failed
    case "banned": return .banned
    case "expired": return .expired
    case "cancelled", "canceled": return .cancelled
    case let other?: return .other(other)
    case nil: return .other("missing")
    }
}

/// A task from `GET /v3/tasks/{id}`. The output link is keyed by its file extension (`stl`, `3mf`, `glb`, …), or
/// `model` when the link has none.
func tripoTaskStatus(_ root: [String: Any]?, secrets: [String] = []) -> ImageTo3DTaskStatus? {
    guard let data = tripoEnvelopeData(root), let id = data["task_id"] as? String, imageTo3DTaskIDIsSafe(id) else { return nil }
    var message: String?
    if let text = data["error_message"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        message = imageTo3DRedacted(text, secrets: secrets)
    }
    var urls: [String: URL] = [:]
    if let output = data["output"] as? [String: Any], let text = output["model_url"] as? String,
       let url = URL(string: text), imageTo3DDownloadURLProblem(url) == nil {
        let ext = url.pathExtension.lowercased()
        urls[ext.isEmpty ? "model" : ext] = url
    }
    return ImageTo3DTaskStatus(taskID: id, state: tripoTaskState(data["status"] as? String),
                               progress: (data["progress"] as? NSNumber)?.intValue, message: message, modelURLs: urls)
}

func tripoBalance(_ root: [String: Any]?) -> ImageTo3DBalance? {
    guard let data = tripoEnvelopeData(root), let balance = (data["balance"] as? NSNumber)?.doubleValue, balance.isFinite else { return nil }
    let frozen = (data["frozen"] as? NSNumber)?.doubleValue
    return ImageTo3DBalance(service: .tripo, credits: balance, frozen: frozen.flatMap { $0.isFinite ? $0 : nil })
}

/// The error for a Tripo reply that isn't a success: a non-2xx status, or a 2xx with a non-zero `code`. Tripo's codes
/// are read only on a 2xx or a plain 4xx: a 5xx, 408, 409 or redirect keeps its HTTP status whatever the body says,
/// so a create that got one stays an unknown outcome (`imageTo3DCreateOutcomeUnknown`).
func tripoError(status: Int, body: Data, retryAfter: String?, secrets: [String]) -> ImageTo3DError {
    let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    let code = (root?["code"] as? NSNumber)?.intValue
    let message = imageTo3DServiceMessage(from: body, secrets: secrets)
    let codesApply = (200..<300).contains(status) || ((400..<500).contains(status) && status != 408 && status != 409)
    guard codesApply else { return .http(service: .tripo, status: status, code: code, message: message) }
    if code == 2010 { return .paymentRequired(service: .tripo, message: message) }
    if status == 429 || code == 1007 || code == 2000 {
        return .rateLimited(service: .tripo, retryAfter: imageTo3DRetryAfterSeconds(retryAfter))
    }
    if code == 1000 || code == 1001 { return .http(service: .tripo, status: 401, code: code, message: message) }
    // A readable 2xx refusal is definite: report it as a 400 so it is never taken for an unknown outcome.
    let effective = (200..<300).contains(status) ? 400 : status
    return .http(service: .tripo, status: effective, code: code, message: message)
}

struct TripoClient: ImageTo3DProvider {
    let service = ImageTo3DService.tripo
    let region: TripoRegion
    private let apiKey: String
    private let transport: ImageTo3DTransport

    init(apiKey: String, region: TripoRegion = .international, transport: ImageTo3DTransport) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.region = region
        self.transport = transport
    }

    private var secrets: [String] { [apiKey] }

    func estimatedCost(for options: ImageTo3DOptions) -> ImageTo3DCostEstimate {
        let convert = options.originAtBottom ? tripoConvertAdvancedCredits : tripoConvertBasicCredits
        return ImageTo3DCostEstimate(service: .tripo, credits: tripoImageToModelCredits + convert,
                                     breakdown: "image to model \(tripoImageToModelCredits), conversion to \(options.format.title) \(convert)")
    }

    func readBalance() async throws -> ImageTo3DBalance {
        let reply = try await send("GET", "/v3/account/balance")
        guard let balance = tripoBalance(reply.json) else { throw ImageTo3DError.invalidResponse("Tripo’s balance reply couldn’t be read.") }
        return balance
    }

    /// Uploads the photo, then sends the generation once. Any upload failure means nothing was created (uploads are
    /// free), so it is `.notSent`.
    func createGeneration(image: ImageTo3DImage, options: ImageTo3DOptions) async -> ImageTo3DCreateResult {
        if let problem = imageTo3DImageProblem(image) { return .notSent(.invalidInput(problem)) }
        let token: String
        do {
            let boundary = "SlantStudio-\(UUID().uuidString)"
            let reply = try await send("POST", "/v3/files", body: tripoUploadBody(image: image, boundary: boundary),
                                       contentType: "multipart/form-data; boundary=\(boundary)")
            guard let value = tripoEnvelopeData(reply.json)?["file_token"] as? String, !value.isEmpty, value.count <= 512 else {
                return .notSent(.invalidResponse("Tripo didn’t accept the photo upload."))
            }
            token = value
        } catch let error as ImageTo3DError {
            return .notSent(error)
        } catch {
            return .notSent(.transport("The photo upload stopped."))
        }
        if Task.isCancelled { return .notSent(.invalidInput("Stopped before the generation was sent.")) }
        return await create("/v3/generation/image-to-model", json: tripoImageToModelBody(fileToken: token, options: options), knownTaskID: nil)
    }

    func readTask(_ taskID: String, kind: ImageTo3DTaskKind) async throws -> ImageTo3DTaskStatus {
        guard imageTo3DTaskIDIsSafe(taskID) else { throw ImageTo3DError.invalidInput("That Tripo task ID isn’t valid.") }
        let reply = try await send("GET", "/v3/tasks/\(taskID)")
        guard let status = tripoTaskStatus(reply.json, secrets: secrets), status.taskID == taskID else {
            throw ImageTo3DError.invalidResponse("Tripo’s task reply couldn’t be read.")
        }
        return status
    }

    /// Generation gives GLB only.
    func needsConversion(after status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, to format: ImageTo3DOutputFormat) -> Bool {
        kind != .conversion
    }

    func createConversion(of status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, options: ImageTo3DOptions) async -> ImageTo3DCreateResult {
        guard imageTo3DTaskIDIsSafe(status.taskID) else { return .notSent(.invalidInput("That Tripo task ID isn’t valid.")) }
        return await create("/v3/models/convert", json: tripoConvertBody(taskID: status.taskID, options: options), knownTaskID: status.taskID)
    }

    /// Only a conversion's output is printable. Its link is taken by its extension when that names STL or 3MF, else
    /// whatever https link Tripo returned for the conversion is taken as the requested format: signed CDN links needn't
    /// end in `.stl`. The caller checks the downloaded content (`imageTo3DDetectedFormat`, then parsing).
    func modelLink(in status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, preferred: ImageTo3DOutputFormat) -> ImageTo3DModelLink? {
        guard kind == .conversion else { return nil }
        if let link = imageTo3DPrintableLink(status.modelURLs, preferred: preferred) { return link }
        let key = status.modelURLs["model"] != nil ? "model" : status.modelURLs.keys.sorted().first
        return key.flatMap { status.modelURLs[$0] }.map { ImageTo3DModelLink(url: $0, format: preferred) }
    }

    func download(_ url: URL, into folder: URL, fileName: String) async throws -> URL {
        try await transport.download(url, into: folder, fileName: fileName, maxBytes: imageTo3DMaxDownloadBytes)
    }

    // MARK: Requests

    /// A create, sent once. A reply without a task ID is an unknown outcome.
    private func create(_ path: String, json: [String: Any], knownTaskID: String?) async -> ImageTo3DCreateResult {
        guard JSONSerialization.isValidJSONObject(json),
              let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return .notSent(.invalidInput("Studio couldn’t build that Tripo request."))
        }
        let outcome: Result<String, Error>
        do {
            let reply = try await send("POST", path, body: body, contentType: "application/json")
            if let id = tripoEnvelopeData(reply.json)?["task_id"] as? String, imageTo3DTaskIDIsSafe(id) {
                outcome = .success(id)
            } else {
                outcome = .failure(ImageTo3DError.invalidResponse("Tripo’s reply had no task ID."))
            }
        } catch ImageTo3DError.invalidInput(let message) {
            return .notSent(.invalidInput(message))
        } catch ImageTo3DError.notConfigured(let service) {
            return .notSent(.notConfigured(service))
        } catch {
            outcome = .failure(error)
        }
        return imageTo3DCreateResult(outcome, knownTaskID: knownTaskID)
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, contentType: String? = nil) async throws -> ImageTo3DHTTPReply {
        guard imageTo3DKeyProblem(apiKey, service: .tripo) == nil else { throw ImageTo3DError.notConfigured(.tripo) }
        guard let url = imageTo3DAPIURL(host: region.apiHost, path: path) else {
            throw ImageTo3DError.invalidInput("Studio couldn’t build that Tripo request.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = method == "GET" ? 30 : imageTo3DRequestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType ?? "application/json", forHTTPHeaderField: "Content-Type")
        }
        let reply = try await transport.send(request)
        let code = (reply.json?["code"] as? NSNumber)?.intValue
        guard (200..<300).contains(reply.status), code == nil || code == 0 else {
            throw tripoError(status: reply.status, body: reply.body, retryAfter: reply.header("Retry-After"), secrets: secrets)
        }
        return reply
    }
}
