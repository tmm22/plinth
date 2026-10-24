import Foundation

// MARK: - Meshy
//
// Meshy's Open API (docs.meshy.ai, read 24–25 Oct 2026; not tested live). Base `https://api.meshy.ai/openapi`, header
// `Authorization: Bearer msy_…`. Every create answers 202 `{"result": "<task id>"}` and is then read with
// `GET …/<id>`; Meshy has no idempotency key and says a 4xx means no task was created, so creates are sent once.
//   - Image to 3D: `POST /openapi/v1/image-to-3d` (`image_url`, a data URI, JPEG/PNG/WebP ≤ 20 MB), read
//     `GET /openapi/v1/image-to-3d/{id}`. Statuses PENDING, IN_PROGRESS, SUCCEEDED, FAILED, CANCELED; `progress` 0–100;
//     `model_urls` per format (3MF only when asked for); `task_error.message`. A failed task is refunded.
//   - Multi-Image to 3D: `POST /openapi/v1/multi-image-to-3d` (`image_urls`, 1–4 data URIs; with meshy-7.1 the first
//     is the front view and the others' order doesn't matter), read `GET /openapi/v1/multi-image-to-3d/{id}`, same
//     task shape. Studio uses it for two to four photos.
//   - Options sent (docs.meshy.ai/api/image-to-3d, /multi-image-to-3d): `should_remesh: false` (Meshy: "For the
//     highest-quality 3D model, set it to false"; `topology` and `target_polycount` only apply when remeshing, so they
//     aren't sent — the triangle count is whatever Meshy generates, undocumented, and Studio simplifies on the Mac);
//     `image_enhancement` (default true, "optimize the input images", which can change details) only when the seller
//     ticks it; `geometry_resolution` `4k` (single image) or `2k` (multi-image accepts only `2k`) for Higher detail,
//     +5 credits; `symmetry_mode` is deprecated and never sent.
//   - Analyze Printability (free): `POST /openapi/v1/print/analyze` from a finished task (the docs list Image to 3D and
//     Multi-Image to 3D), read `GET /openapi/v1/print/analyze/{id}`; `printability` holds the verdict and counts.
//   - Repair Printability (10 credits): `POST /openapi/v1/print/repair`, read `GET /openapi/v1/print/repair/{id}`.
//     From a task ID Meshy always repairs the task's GLB and returns GLB only, so Studio converts the result.
//   - Convert (1 credit): `POST /openapi/v1/convert` (`input_task_id` or `model_url`, `target_formats`), read
//     `GET /openapi/v1/convert/{id}`. Whether Convert takes a repair task's ID isn't documented; after a definite
//     refusal (400/422, so nothing was created) Studio sends the repair's own GLB link as `model_url` instead.
//   - Running tasks answer with `Retry-After` (seconds), used as the poll interval.
//   - Balance: `GET /openapi/v1/balance` → `{"balance": …}`.
//   - Errors: `{"message": "…"}`; 402 = not enough credits or the Free plan (which has no API keys); 429 = rate or
//     concurrency limit (`Retry-After` on the rate limit only). Generated files stay on assets.meshy.ai for 3 days.

/// Meshy's published credit prices (docs.meshy.ai/api/pricing, 25 Oct 2026). Approximate: prices change.
/// Image to 3D and Multi-Image to 3D cost the same, mesh only.
let meshyImageTo3DMeshOnlyCredits = 20
/// The Ultra geometry surcharge (`geometry_resolution` 2k or 4k, meshy-7.1 only).
let meshyHigherDetailCredits = 5
let meshyRepairPrintabilityCredits = 10
let meshyConvertCredits = 1
/// The model asked for, pinned so the published price (20 credits, mesh only) stays right.
let meshyAIModel = "meshy-7.1"
let meshyAPIHost = "api.meshy.ai"
/// Higher detail's `geometry_resolution`: 4k ("for the most surface detail") with one photo; Multi-Image to 3D accepts
/// only 2k. Both cost the same surcharge.
let meshySingleImageHigherDetailResolution = "4k"
let meshyMultiImageHigherDetailResolution = "2k"
/// The size range Analyze and Repair Printability accept for `intended_print_longest_side_mm`.
let meshyAnalyzeMaxSideMM = 1...1000.0

/// The options both generation endpoints share: meshy-7.1, mesh only, not remeshed (Meshy keeps the detail it
/// generates; Studio simplifies on the Mac), photo enhancement only when asked for, only the printable format, and
/// `auto_size` with `origin_at: bottom` when the seller wants the base at the origin.
private func meshyGenerationBody(options: ImageTo3DOptions, higherDetailResolution: String) -> [String: Any] {
    var body: [String: Any] = [
        "ai_model": meshyAIModel,
        "should_texture": false,
        "should_remesh": false,
        "image_enhancement": options.enhancePhoto,
        "target_formats": [options.format.rawValue]
    ]
    if options.higherDetail { body["geometry_resolution"] = higherDetailResolution }
    if options.originAtBottom {
        body["auto_size"] = true
        body["origin_at"] = "bottom"
    }
    return body
}

/// The JSON body for an Image to 3D create (one photo).
func meshyImageTo3DBody(imageDataURI: String, options: ImageTo3DOptions) -> [String: Any] {
    var body = meshyGenerationBody(options: options, higherDetailResolution: meshySingleImageHigherDetailResolution)
    body["image_url"] = imageDataURI
    return body
}

/// The JSON body for a Multi-Image to 3D create: the data URIs in order, front first.
func meshyMultiImageTo3DBody(imageDataURIs: [String], options: ImageTo3DOptions) -> [String: Any] {
    var body = meshyGenerationBody(options: options, higherDetailResolution: meshyMultiImageHigherDetailResolution)
    body["image_urls"] = imageDataURIs
    return body
}

/// `data:image/jpeg;base64,…` for the prepared photo.
func meshyImageDataURI(_ image: ImageTo3DImage) -> String {
    "data:\(image.mediaType);base64,\(image.data.base64EncodedString())"
}

/// The task ID from a create reply (`{"result": "…"}`), or nil.
func meshyCreatedTaskID(_ root: [String: Any]?) -> String? {
    guard let id = root?["result"] as? String, imageTo3DTaskIDIsSafe(id) else { return nil }
    return id
}

func meshyTaskState(_ raw: String?, errorCode: String?) -> ImageTo3DTaskState {
    switch raw?.uppercased() {
    case "PENDING": return .queued
    case "IN_PROGRESS": return .running
    case "SUCCEEDED": return .succeeded
    case "FAILED": return errorCode == "moderation_blocked" ? .banned : .failed
    case "CANCELED", "CANCELLED": return .cancelled
    case "EXPIRED": return .expired
    case let other?: return .other(other)
    case nil: return .other("missing")
    }
}

/// A task from `GET …/{id}`. Nil when the reply isn't a task.
func meshyTaskStatus(_ root: [String: Any]?, secrets: [String] = [], suggestedDelay: TimeInterval? = nil) -> ImageTo3DTaskStatus? {
    guard let root, let id = root["id"] as? String, imageTo3DTaskIDIsSafe(id) else { return nil }
    let error = root["task_error"] as? [String: Any]
    let code = error?["code"] as? String
    let state = meshyTaskState(root["status"] as? String, errorCode: code)
    var message: String?
    if let text = error?["message"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        message = imageTo3DRedacted(text, secrets: secrets)
    }
    let progress = (root["progress"] as? NSNumber)?.intValue
    return ImageTo3DTaskStatus(taskID: id, state: state, progress: progress, message: message,
                               modelURLs: imageTo3DModelURLs(root["model_urls"]), suggestedDelay: suggestedDelay)
}

func meshyBalance(_ root: [String: Any]?) -> ImageTo3DBalance? {
    guard let value = (root?["balance"] as? NSNumber)?.doubleValue, value.isFinite else { return nil }
    return ImageTo3DBalance(service: .meshy, credits: value, frozen: nil)
}

/// The error for a non-2xx Meshy reply.
func meshyError(status: Int, body: Data, retryAfter: String?, secrets: [String]) -> ImageTo3DError {
    let message = imageTo3DServiceMessage(from: body, secrets: secrets)
    switch status {
    case 402: return .paymentRequired(service: .meshy, message: message)
    case 429: return .rateLimited(service: .meshy, retryAfter: imageTo3DRetryAfterSeconds(retryAfter))
    default: return .http(service: .meshy, status: status, code: nil, message: message)
    }
}

// MARK: Printability

enum MeshyPrintabilityVerdict: String, Sendable {
    case healthy, warning, error, unknown
}

/// Meshy's Analyze Printability result. Advisory: Studio's own mesh check and tools decide what happens next.
struct MeshyPrintabilityReport: Equatable, Sendable {
    let taskID: String
    let verdict: MeshyPrintabilityVerdict
    let errorCount: Int
    let warningCount: Int
    let isWatertight: Bool?
    let holes: Int?
    let nonManifoldEdges: Int?
    let degenerateFaces: Int?
    /// Only when a size was given.
    let hasThinWalls: Bool?
    let thinAreaRatio: Double?
    let wallThicknessMM: Double?
    let dimensionsMM: [Double]?

    /// One line per finding, in a fixed order.
    var findings: [String] {
        var lines: [String] = []
        if isWatertight == false { lines.append("Not watertight") }
        if let holes, holes > 0 { lines.append(holes == 1 ? "1 hole" : "\(holes) holes") }
        if let edges = nonManifoldEdges, edges > 0 { lines.append(edges == 1 ? "1 non-manifold edge" : "\(edges) non-manifold edges") }
        if let faces = degenerateFaces, faces > 0 { lines.append(faces == 1 ? "1 degenerate face" : "\(faces) degenerate faces") }
        if hasThinWalls == true {
            let share = thinAreaRatio.map { " (\(Int(($0 * 100).rounded()))% of the surface)" } ?? ""
            let limit = wallThicknessMM.map { " thinner than \(String(format: "%.1f", $0)) mm" } ?? ""
            lines.append("Thin walls\(limit)\(share)")
        }
        return lines
    }

    var summary: String {
        let head: String
        switch verdict {
        case .healthy: head = "Meshy found no printability problems"
        case .warning: head = "Meshy found possible printability problems"
        case .error: head = "Meshy found printability problems"
        case .unknown: head = "Meshy couldn’t judge printability"
        }
        let list = findings
        return list.isEmpty ? "\(head)." : "\(head): \(list.joined(separator: ", "))."
    }
}

/// The report from a finished `print-analyze` task, or nil when it has none.
func meshyPrintabilityReport(_ root: [String: Any]?) -> MeshyPrintabilityReport? {
    guard let root, let id = root["id"] as? String, let printability = root["printability"] as? [String: Any] else { return nil }
    let metrics = printability["metrics"] as? [String: Any]
    let intended = printability["intended_print"] as? [String: Any]
    let thin = printability["thin_walls"] as? [String: Any]
    func int(_ object: [String: Any]?, _ key: String) -> Int? { (object?[key] as? NSNumber)?.intValue }
    func double(_ object: [String: Any]?, _ key: String) -> Double? {
        (object?[key] as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil }
    }
    func bool(_ object: [String: Any]?, _ key: String) -> Bool? {
        guard let number = object?[key] as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
    let dimensions = (intended?["dimensions_mm"] as? [NSNumber])?.map(\.doubleValue).filter(\.isFinite)
    return MeshyPrintabilityReport(
        taskID: id,
        verdict: MeshyPrintabilityVerdict(rawValue: (printability["status"] as? String)?.lowercased() ?? "") ?? .unknown,
        errorCount: int(printability, "error_count") ?? 0,
        warningCount: int(printability, "warning_count") ?? 0,
        isWatertight: bool(metrics, "is_watertight"),
        holes: int(metrics, "holes"),
        nonManifoldEdges: int(metrics, "non_manifold_edges"),
        degenerateFaces: int(metrics, "degenerate_faces"),
        hasThinWalls: bool(thin, "has_thin_walls"),
        thinAreaRatio: double(thin, "thin_area_ratio"),
        wallThicknessMM: double(intended, "wall_thickness_mm"),
        dimensionsMM: dimensions?.isEmpty == false ? dimensions : nil
    )
}

/// The body for Analyze or Repair Printability of a finished Meshy task: an FDM wall check when a size is given
/// (the longest side in millimetres, 1–1000).
func meshyPrintabilityBody(inputTaskID: String, longestSideMM: Double?) -> [String: Any] {
    var body: [String: Any] = ["input_task_id": inputTaskID]
    if let side = longestSideMM, side.isFinite, meshyAnalyzeMaxSideMM.contains(side) {
        body["printer_type"] = "fdm"
        body["intended_print_longest_side_mm"] = (side * 10).rounded() / 10
    }
    return body
}

/// The body for Convert: by task ID, or by a model link from Meshy itself when the ID was refused.
func meshyConvertBody(inputTaskID: String?, modelURL: URL?, format: ImageTo3DOutputFormat) -> [String: Any] {
    var body: [String: Any] = ["target_formats": [format.rawValue]]
    if let inputTaskID { body["input_task_id"] = inputTaskID } else if let modelURL { body["model_url"] = modelURL.absoluteString }
    return body
}

/// Repair Printability for a finished Meshy task, then Convert to `options.format`, then download — about 11
/// credits (`MeshyClient.repairCost`). The repair and the conversion are each sent once; a stop with a
/// `resumePoint` can carry on through `resumeImageTo3DGeneration`.
func runMeshyRepair(client: MeshyClient, ofTask inputTaskID: String, longestSideMM: Double?, options: ImageTo3DOptions,
                    timeout: TimeInterval = imageTo3DPollTimeout,
                    sleep: ImageTo3DSleep = imageTo3DRealSleep, now: ImageTo3DClock = { Date() },
                    makeFolder: () throws -> URL = makeImageTo3DTempFolder,
                    progress: @escaping @Sendable (ImageTo3DProgress) -> Void = { _ in }) async -> Result<ImageTo3DGeneratedModel, ImageTo3DStop> {
    if Task.isCancelled {
        return .failure(ImageTo3DStop(reason: .cancelled, stage: .repairing, service: .meshy, taskID: nil, detail: "", requestKind: .repair))
    }
    progress(ImageTo3DProgress(stage: .repairing, taskID: inputTaskID, state: nil, percent: nil))
    switch await client.createRepair(ofTask: inputTaskID, longestSideMM: longestSideMM) {
    case .created(let id):
        return await resumeImageTo3DGeneration(provider: client,
                                               from: ImageTo3DResumePoint(sourceTaskID: id, sourceKind: .repair, conversionTaskID: nil),
                                               options: options, timeout: timeout, sleep: sleep, now: now,
                                               makeFolder: makeFolder, progress: progress)
    case .notSent(let error):
        return .failure(ImageTo3DStop(reason: .notSent, stage: .repairing, service: .meshy, taskID: nil, detail: error.userMessage,
                                      requestKind: .repair))
    case .unknown(let id, let error):
        return .failure(ImageTo3DStop(reason: .outcomeUnknown, stage: .repairing, service: .meshy, taskID: id, detail: error.userMessage,
                                      requestKind: .repair))
    }
}

// MARK: Client

struct MeshyClient: ImageTo3DProvider {
    let service = ImageTo3DService.meshy
    private let apiKey: String
    private let transport: ImageTo3DTransport

    init(apiKey: String, transport: ImageTo3DTransport) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        self.transport = transport
    }

    private var secrets: [String] { [apiKey] }

    /// The same price for one photo or several; Higher detail adds the Ultra surcharge.
    func estimatedCost(for options: ImageTo3DOptions, photoCount: Int) -> ImageTo3DCostEstimate {
        let name = photoCount > 1 ? "Multi-Image to 3D" : "Image to 3D"
        guard options.higherDetail else {
            return ImageTo3DCostEstimate(service: .meshy, credits: meshyImageTo3DMeshOnlyCredits, breakdown: "\(name), mesh only")
        }
        return ImageTo3DCostEstimate(service: .meshy, credits: meshyImageTo3DMeshOnlyCredits + meshyHigherDetailCredits,
                                     breakdown: "\(name), mesh only \(meshyImageTo3DMeshOnlyCredits) + \(meshyHigherDetailCredits) for higher detail")
    }

    /// Repair Printability plus the conversion of its GLB to STL or 3MF.
    static var repairCost: ImageTo3DCostEstimate {
        ImageTo3DCostEstimate(service: .meshy, credits: meshyRepairPrintabilityCredits + meshyConvertCredits,
                              breakdown: "Repair Printability \(meshyRepairPrintabilityCredits), conversion \(meshyConvertCredits)")
    }

    func readBalance() async throws -> ImageTo3DBalance {
        let reply = try await send("GET", "/openapi/v1/balance")
        guard let balance = meshyBalance(reply.json) else { throw ImageTo3DError.invalidResponse("Meshy’s balance reply couldn’t be read.") }
        return balance
    }

    /// One photo goes to Image to 3D; two to four go to Multi-Image to 3D, front first. Sent once.
    func createGeneration(views: [ImageTo3DViewImage], options: ImageTo3DOptions,
                          proceed: @escaping @Sendable () -> Bool) async -> ImageTo3DCreateResult {
        if let problem = imageTo3DViewsProblem(views) { return .notSent(.invalidInput(problem)) }
        let ordered = imageTo3DOrderedViews(views)
        guard !Task.isCancelled, proceed() else { return .notSent(.invalidInput(imageTo3DStoppedBeforeSendingMessage)) }
        if ordered.count == 1 {
            return await create(Self.readPath(.generation),
                                body: meshyImageTo3DBody(imageDataURI: meshyImageDataURI(ordered[0].image), options: options), knownTaskID: nil)
        }
        return await create(Self.readPath(.multiImageGeneration),
                            body: meshyMultiImageTo3DBody(imageDataURIs: ordered.map { meshyImageDataURI($0.image) }, options: options),
                            knownTaskID: nil)
    }

    func readTask(_ taskID: String, kind: ImageTo3DTaskKind) async throws -> ImageTo3DTaskStatus {
        guard imageTo3DTaskIDIsSafe(taskID) else { throw ImageTo3DError.invalidInput("That Meshy task ID isn’t valid.") }
        let reply = try await send("GET", "\(Self.readPath(kind))/\(taskID)")
        guard let status = meshyTaskStatus(reply.json, secrets: secrets,
                                           suggestedDelay: imageTo3DRetryAfterSeconds(reply.header("Retry-After"))),
              status.taskID == taskID else {
            throw ImageTo3DError.invalidResponse("Meshy’s task reply couldn’t be read.")
        }
        return status
    }

    static func readPath(_ kind: ImageTo3DTaskKind) -> String {
        switch kind {
        case .generation: return "/openapi/v1/image-to-3d"
        case .multiImageGeneration: return "/openapi/v1/multi-image-to-3d"
        case .conversion: return "/openapi/v1/convert"
        case .repair: return "/openapi/v1/print/repair"
        }
    }

    /// Image to 3D makes STL and 3MF directly; a repair gives GLB only, so it needs Convert.
    func needsConversion(after status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, to format: ImageTo3DOutputFormat) -> Bool {
        kind != .conversion && modelLink(in: status, kind: kind, preferred: format) == nil
    }

    /// Convert (1 credit), sent once by task ID. Only if Meshy definitely refuses that (400/422: nothing created) and
    /// the task has a GLB link, the same conversion is sent once by that link instead.
    func createConversion(of status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, options: ImageTo3DOptions) async -> ImageTo3DCreateResult {
        guard imageTo3DTaskIDIsSafe(status.taskID) else { return .notSent(.invalidInput("That Meshy task ID isn’t valid.")) }
        let byID = await create("/openapi/v1/convert", body: meshyConvertBody(inputTaskID: status.taskID, modelURL: nil, format: options.format),
                                knownTaskID: status.taskID)
        guard case .notSent(.http(_, let httpStatus, _, _)) = byID, httpStatus == 400 || httpStatus == 422,
              let glb = status.modelURLs["glb"] else { return byID }
        return await create("/openapi/v1/convert", body: meshyConvertBody(inputTaskID: nil, modelURL: glb, format: options.format),
                            knownTaskID: status.taskID)
    }

    func modelLink(in status: ImageTo3DTaskStatus, kind: ImageTo3DTaskKind, preferred: ImageTo3DOutputFormat) -> ImageTo3DModelLink? {
        imageTo3DPrintableLink(status.modelURLs, preferred: preferred)
    }

    func download(_ url: URL, into folder: URL, fileName: String) async throws -> URL {
        try await transport.download(url, into: folder, fileName: fileName, maxBytes: imageTo3DMaxDownloadBytes)
    }

    // MARK: Printability

    /// Free. Starts Analyze Printability for a finished generation (or repair) task, with an FDM wall check at
    /// `longestSideMM` when given, waits for it and returns the report. Analyze spends no credits, so this is safe
    /// to run again; Studio still sends each request once.
    func analyzePrintability(ofTask inputTaskID: String, longestSideMM: Double?,
                             timeout: TimeInterval = imageTo3DPollTimeout, sleep: ImageTo3DSleep = imageTo3DRealSleep,
                             now: ImageTo3DClock = { Date() }) async throws -> MeshyPrintabilityReport {
        guard imageTo3DTaskIDIsSafe(inputTaskID) else { throw ImageTo3DError.invalidInput("That Meshy task ID isn’t valid.") }
        let created = try await send("POST", "/openapi/v1/print/analyze",
                                     body: meshyPrintabilityBody(inputTaskID: inputTaskID, longestSideMM: longestSideMM))
        guard let analyzeID = meshyCreatedTaskID(created.json) else { throw ImageTo3DError.invalidResponse("Meshy’s analysis reply couldn’t be read.") }
        let deadline = now().addingTimeInterval(timeout)
        var failures = 0
        var delay: TimeInterval = 1
        while true {
            try Task.checkCancellation()
            let reply: ImageTo3DHTTPReply?
            do {
                reply = try await send("GET", "/openapi/v1/print/analyze/\(analyzeID)")
                failures = 0
            } catch ImageTo3DError.rateLimited(_, let wait) {
                reply = nil
                delay = wait ?? 10
            } catch let error where imageTo3DReadIsTransient(error) {
                failures += 1
                if failures >= imageTo3DMaxConsecutivePollFailures { throw error }
                reply = nil
                delay = imageTo3DPollDelay(consecutiveFailures: failures, retryAfter: nil, base: 2)
            }
            if let reply {
                guard let status = meshyTaskStatus(reply.json, secrets: secrets) else {
                    throw ImageTo3DError.invalidResponse("Meshy’s analysis reply couldn’t be read.")
                }
                if status.state == .succeeded {
                    guard let report = meshyPrintabilityReport(reply.json) else {
                        throw ImageTo3DError.invalidResponse("Meshy’s analysis had no printability result.")
                    }
                    return report
                }
                if status.state.isTerminal {
                    throw ImageTo3DError.invalidResponse("Meshy couldn’t analyse the model (\(status.state.title.lowercased())). \(status.message ?? "")"
                        .trimmingCharacters(in: .whitespaces))
                }
                delay = imageTo3DRetryAfterSeconds(reply.header("Retry-After")).map { min(max($0, 1), 10) } ?? 2
            }
            guard now().addingTimeInterval(delay) <= deadline else {
                throw ImageTo3DError.invalidResponse("Meshy’s analysis didn’t finish in time.")
            }
            try await sleep(delay)
        }
    }

    /// Paid (about 10 credits). Sends Repair Printability for a finished task once. Never retried. Use
    /// `runMeshyRepair` for the whole repair, conversion and download.
    func createRepair(ofTask inputTaskID: String, longestSideMM: Double?) async -> ImageTo3DCreateResult {
        guard imageTo3DTaskIDIsSafe(inputTaskID) else { return .notSent(.invalidInput("That Meshy task ID isn’t valid.")) }
        return await create("/openapi/v1/print/repair",
                            body: meshyPrintabilityBody(inputTaskID: inputTaskID, longestSideMM: longestSideMM),
                            knownTaskID: nil)
    }

    // MARK: Requests

    /// A create, sent once. A reply without a task ID is an unknown outcome.
    private func create(_ path: String, body: [String: Any], knownTaskID: String?) async -> ImageTo3DCreateResult {
        let outcome: Result<String, Error>
        do {
            let reply = try await send("POST", path, body: body)
            if let id = meshyCreatedTaskID(reply.json) {
                outcome = .success(id)
            } else {
                outcome = .failure(ImageTo3DError.invalidResponse("Meshy’s reply had no task ID."))
            }
        } catch ImageTo3DError.invalidInput(let message) {
            // Built locally before anything was sent.
            return .notSent(.invalidInput(message))
        } catch {
            outcome = .failure(error)
        }
        return imageTo3DCreateResult(outcome, knownTaskID: knownTaskID)
    }

    private func send(_ method: String, _ path: String, body: [String: Any]? = nil) async throws -> ImageTo3DHTTPReply {
        guard imageTo3DKeyProblem(apiKey, service: .meshy) == nil else { throw ImageTo3DError.notConfigured(.meshy) }
        guard let url = imageTo3DAPIURL(host: meshyAPIHost, path: path) else { throw ImageTo3DError.invalidInput("Studio couldn’t build that Meshy request.") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = method == "GET" ? 30 : imageTo3DRequestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            guard JSONSerialization.isValidJSONObject(body),
                  let data = try? JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) else {
                throw ImageTo3DError.invalidInput("Studio couldn’t build that Meshy request.")
            }
            request.httpBody = data
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let reply = try await transport.send(request)
        guard (200..<300).contains(reply.status) else {
            throw meshyError(status: reply.status, body: reply.body, retryAfter: reply.header("Retry-After"), secrets: secrets)
        }
        return reply
    }
}
