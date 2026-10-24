import Foundation
import Security

// MARK: - Claude (Anthropic) client
//
// A raw HTTPS client for the Messages API (`POST https://api.anthropic.com/v1/messages`), always streamed (SSE), used
// by the photo-based design and review tools. The seller's own Anthropic key lives in its own Keychain item and is
// sent only to api.anthropic.com. Every request costs the seller money, so the client never sends one again by itself:
// callers decide, after showing what happened. Error text never carries a key. Prompts, photos and replies stay in
// memory; Activity gets titles, counts, status and cost only.

let anthropicMessagesURL = URL(string: "https://api.anthropic.com/v1/messages")!
let anthropicAPIVersion = "2023-06-01"
/// Claude Opus 5.5.
let anthropicDefaultModel = "claude-opus-5-5"
/// `fallbacks: "default"`: a request a safety classifier declines is re-run server-side on the model Anthropic
/// recommends for that category, instead of just stopping.
let anthropicFallbackBeta = "server-side-fallback-2026-07-01"
/// `thinking.display: "updates"`: short progress notes while reasoning stays hidden.
let anthropicThinkingUpdatesBeta = "thinking-display-updates-2026-08-18"
/// Anthropic's limit for a Messages request body.
let anthropicMaxRequestBytes = 32 * 1024 * 1024
/// Largest streamed reply Studio reads. A 64,000-token reply with its event framing is a few megabytes.
let anthropicMaxResponseBytes = 32 * 1024 * 1024
/// Largest error body read.
let anthropicMaxErrorBodyBytes = 256 * 1024
/// Longest silence allowed on an open stream. Anthropic sends `ping` events while it works.
let anthropicStreamIdleTimeout: TimeInterval = 300
/// Longest a whole request may take, long thinking included.
let anthropicStreamResourceTimeout: TimeInterval = 60 * 60
/// Longest key accepted.
let anthropicMaxKeyLength = 256
/// Most `cache_control` breakpoints one request may carry.
let anthropicMaxCacheBreakpoints = 4

// MARK: Request

enum AnthropicCacheTTL: String, Equatable, Sendable {
    case fiveMinutes = "5m"
    case oneHour = "1h"
}

/// A prompt-caching breakpoint. Five-minute writes cost 1.25× input, one-hour writes 2×; reads 0.05× on Opus 5.5.
struct AnthropicCacheControl: Equatable, Sendable {
    var ttl: AnthropicCacheTTL = .fiveMinutes

    static let fiveMinutes = AnthropicCacheControl()
    static let oneHour = AnthropicCacheControl(ttl: .oneHour)

    var json: AnthropicJSON {
        ttl == .fiveMinutes ? ["type": "ephemeral"] : ["type": "ephemeral", "ttl": "1h"]
    }
}

enum AnthropicImageMediaType: String, Equatable, Sendable {
    case jpeg = "image/jpeg"
    case png = "image/png"
}

/// A base64 image for an `image` block or a tool result.
struct AnthropicImage: Equatable, Sendable {
    let mediaType: AnthropicImageMediaType
    let base64Data: String

    var json: AnthropicJSON {
        ["type": "image", "source": ["type": "base64", "media_type": .string(mediaType.rawValue), "data": .string(base64Data)]]
    }
}

enum AnthropicToolResultContent: Equatable, Sendable {
    case text(String)
    case image(AnthropicImage)

    var json: AnthropicJSON {
        switch self {
        case .text(let text): return ["type": "text", "text": .string(text)]
        case .image(let image): return image.json
        }
    }
}

/// One block of a turn Studio sends. Assistant turns echo the reply's blocks verbatim through `.raw`.
enum AnthropicInputBlock: Equatable, Sendable {
    case text(String, cacheControl: AnthropicCacheControl? = nil)
    case image(AnthropicImage, cacheControl: AnthropicCacheControl? = nil)
    case toolResult(toolUseID: String, content: [AnthropicToolResultContent], isError: Bool = false,
                    cacheControl: AnthropicCacheControl? = nil)
    case raw(AnthropicJSON)

    var cacheControl: AnthropicCacheControl? {
        switch self {
        case .text(_, let cache), .image(_, let cache), .toolResult(_, _, _, let cache): return cache
        case .raw(let json): return json["cache_control"].map { _ in .fiveMinutes }
        }
    }

    var json: AnthropicJSON {
        switch self {
        case .text(let text, let cache):
            var block: AnthropicJSON = ["type": "text", "text": .string(text)]
            if let cache { block = block.setting("cache_control", to: cache.json) }
            return block
        case .image(let image, let cache):
            var block = image.json
            if let cache { block = block.setting("cache_control", to: cache.json) }
            return block
        case .toolResult(let id, let content, let isError, let cache):
            var block: AnthropicJSON = ["type": "tool_result", "tool_use_id": .string(id), "content": .array(content.map(\.json))]
            if isError { block = block.setting("is_error", to: true) }
            if let cache { block = block.setting("cache_control", to: cache.json) }
            return block
        case .raw(let json):
            return json
        }
    }
}

enum AnthropicRole: String, Equatable, Sendable {
    case user, assistant
    /// A mid-conversation operator message (Opus 5.5): appended instead of editing the top-level system prompt, so
    /// the cached prefix and earlier thinking stay valid. Must follow a user turn.
    case system
}

struct AnthropicMessageParam: Equatable, Sendable {
    var role: AnthropicRole
    var content: [AnthropicInputBlock]

    static func user(_ content: [AnthropicInputBlock]) -> AnthropicMessageParam { AnthropicMessageParam(role: .user, content: content) }
    static func user(text: String) -> AnthropicMessageParam { .user([.text(text)]) }
    static func system(_ text: String) -> AnthropicMessageParam { AnthropicMessageParam(role: .system, content: [.text(text)]) }
    /// Claude's reply as the next assistant turn: its blocks unchanged (thinking and signatures included), as the
    /// conversation history must be append-only.
    static func assistant(_ message: AnthropicMessage) -> AnthropicMessageParam {
        AnthropicMessageParam(role: .assistant, content: message.historyContent.map { .raw($0) })
    }

    var json: AnthropicJSON {
        if role == .system {
            let text = content.compactMap { block -> String? in if case .text(let text, _) = block { return text }; return nil }
            return ["role": "system", "content": .string(text.joined(separator: "\n\n"))]
        }
        return ["role": .string(role.rawValue), "content": .array(content.map(\.json))]
    }
}

struct AnthropicSystemBlock: Equatable, Sendable {
    var text: String
    var cacheControl: AnthropicCacheControl?

    init(_ text: String, cacheControl: AnthropicCacheControl? = nil) {
        self.text = text
        self.cacheControl = cacheControl
    }

    var json: AnthropicJSON {
        var block: AnthropicJSON = ["type": "text", "text": .string(text)]
        if let cacheControl { block = block.setting("cache_control", to: cacheControl.json) }
        return block
    }
}

/// A client tool. `strict` makes Claude's arguments match the schema (which then needs `additionalProperties: false`
/// and `required`); `eagerInputStreaming` streams large inputs as they are written, after which Studio checks them
/// against the schema itself (`AnthropicToolUse.inputProblem`).
struct AnthropicTool: Equatable, Sendable {
    var name: String
    var description: String
    var inputSchema: AnthropicJSON
    var strict = true
    var eagerInputStreaming = true
    var cacheControl: AnthropicCacheControl?

    var json: AnthropicJSON {
        var tool: AnthropicJSON = ["name": .string(name), "description": .string(description), "input_schema": inputSchema]
        if strict { tool = tool.setting("strict", to: true) }
        if eagerInputStreaming { tool = tool.setting("eager_input_streaming", to: true) }
        if let cacheControl { tool = tool.setting("cache_control", to: cacheControl.json) }
        return tool
    }
}

enum AnthropicEffort: String, CaseIterable, Equatable, Sendable {
    case low, medium, high, xhigh, max
}

/// How thinking comes back. Thinking always runs on Opus 5.5 and is billed the same whichever is chosen.
enum AnthropicThinkingDisplay: String, Equatable, Sendable {
    /// Empty thinking text (the API default).
    case omitted
    /// A readable summary of the reasoning, streamed as `thinking_delta`.
    case summarized
    /// Short progress notes between tool calls; reasoning stays hidden. Beta.
    case updates
}

/// One Messages request. Always streamed. `tool_choice` is always `auto` (forced tool use is refused on Opus 5.5),
/// so callers steer with the prompt and check a tool was actually called.
struct AnthropicRequest: Equatable, Sendable {
    var model = anthropicDefaultModel
    var maxTokens = 32_000
    var system: [AnthropicSystemBlock] = []
    var tools: [AnthropicTool] = []
    /// With `auto`, at most one tool call per turn.
    var disableParallelToolUse = false
    var messages: [AnthropicMessageParam]
    /// Opus 5.5 defaults to medium, so it is always sent explicitly.
    var effort: AnthropicEffort = .medium
    var thinkingDisplay: AnthropicThinkingDisplay = .omitted
    var useDefaultFallbacks = true
    /// Top-level automatic caching of the growing conversation tail (uses one of the four breakpoints).
    var automaticCaching: AnthropicCacheControl?

    init(model: String = anthropicDefaultModel, maxTokens: Int = 32_000, system: [AnthropicSystemBlock] = [],
         tools: [AnthropicTool] = [], disableParallelToolUse: Bool = false, messages: [AnthropicMessageParam],
         effort: AnthropicEffort = .medium, thinkingDisplay: AnthropicThinkingDisplay = .omitted,
         useDefaultFallbacks: Bool = true, automaticCaching: AnthropicCacheControl? = nil) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.tools = tools
        self.disableParallelToolUse = disableParallelToolUse
        self.messages = messages
        self.effort = effort
        self.thinkingDisplay = thinkingDisplay
        self.useDefaultFallbacks = useDefaultFallbacks
        self.automaticCaching = automaticCaching
    }

    /// The body, keys always in the same order, so the same request is the same bytes every time.
    var json: AnthropicJSON {
        var pairs: [(String, AnthropicJSON)] = [("model", .string(model)), ("max_tokens", .int(maxTokens)), ("stream", true)]
        if !system.isEmpty { pairs.append(("system", .array(system.map(\.json)))) }
        if !tools.isEmpty {
            pairs.append(("tools", .array(tools.map(\.json))))
            var choice: AnthropicJSON = ["type": "auto"]
            if disableParallelToolUse { choice = choice.setting("disable_parallel_tool_use", to: true) }
            pairs.append(("tool_choice", choice))
        }
        var thinking: AnthropicJSON = ["type": "adaptive"]
        if thinkingDisplay != .omitted { thinking = thinking.setting("display", to: .string(thinkingDisplay.rawValue)) }
        pairs.append(("thinking", thinking))
        pairs.append(("output_config", ["effort": .string(effort.rawValue)]))
        if useDefaultFallbacks { pairs.append(("fallbacks", "default")) }
        if let automaticCaching { pairs.append(("cache_control", automaticCaching.json)) }
        pairs.append(("messages", .array(messages.map(\.json))))
        return .fromPairs(pairs)
    }

    var betaHeaders: [String] {
        var betas: [String] = []
        if useDefaultFallbacks { betas.append(anthropicFallbackBeta) }
        if thinkingDisplay == .updates { betas.append(anthropicThinkingUpdatesBeta) }
        return betas
    }

    /// Why Anthropic would refuse this request outright, or nil. Checked before sending, so nothing is spent.
    var problem: String? {
        if model.trimmingCharacters(in: .whitespaces).isEmpty { return "No model is set." }
        if maxTokens < 1 { return "The reply limit must be at least one token." }
        guard let first = messages.first else { return "There’s nothing to send." }
        if first.role != .user { return "A conversation must start with a user turn." }
        // Opus 5.5 refuses a final assistant turn (prefill).
        if messages.last?.role == .assistant { return "A conversation can’t end with Claude’s turn." }
        for (index, message) in messages.enumerated() {
            if message.content.isEmpty { return "Turn \(index + 1) is empty." }
            if message.role == .system, index == 0 || messages[index - 1].role == .assistant {
                return "A system note must follow a user turn."
            }
        }
        var names: [String] = []
        for tool in tools {
            if tool.name.isEmpty { return "A tool has no name." }
            if names.contains(tool.name) { return "Two tools are both called \(tool.name)." }
            names.append(tool.name)
        }
        let breakpoints = system.filter { $0.cacheControl != nil }.count + tools.filter { $0.cacheControl != nil }.count
            + messages.reduce(0) { $0 + $1.content.filter { $0.cacheControl != nil }.count } + (automaticCaching == nil ? 0 : 1)
        if breakpoints > anthropicMaxCacheBreakpoints { return "The request has more than \(anthropicMaxCacheBreakpoints) cache breakpoints." }
        return nil
    }
}

// MARK: Reply

struct AnthropicToolUse: Equatable, Sendable {
    let id: String
    let name: String
    /// The parsed input; `{}` when it couldn't be parsed.
    let input: AnthropicJSON
    /// The input exactly as streamed, for an `INVALID_JSON` error result.
    let rawInputJSON: String
    /// Why the input can't be used (unparseable, wrong shape, unknown tool), or nil when it fits the tool's schema.
    /// Never run a tool whose input has a problem: answer with `AnthropicToolUse.errorResult` instead.
    let inputProblem: String?

    /// The `is_error` tool result to send back when `inputProblem` is set.
    var errorResult: AnthropicInputBlock {
        let detail: AnthropicJSON = input == .object([]) && !rawInputJSON.isEmpty && (try? AnthropicJSON.parse(rawInputJSON)) == nil
            ? ["INVALID_JSON": .string(rawInputJSON)]
            : ["error": .string(inputProblem ?? "The input couldn’t be used.")]
        return .toolResult(toolUseID: id, content: [.text(detail.encodedString)], isError: true)
    }
}

enum AnthropicOutputContent: Equatable, Sendable {
    case text(String)
    /// Thinking text (empty unless a display was asked for) and its signature, kept to be passed back unchanged.
    case thinking(String, signature: String)
    case redactedThinking
    case toolUse(AnthropicToolUse)
    /// A server-side fallback switch point: the models before and after.
    case fallback(from: String?, to: String?)
    case other(type: String)
}

/// A reply block: what Studio reads from it, and the block itself as received (for the conversation history).
struct AnthropicOutputBlock: Equatable, Sendable {
    let content: AnthropicOutputContent
    let raw: AnthropicJSON

    var type: String { raw["type"]?.stringValue ?? "" }
}

enum AnthropicStopReason: Equatable, Sendable {
    case endTurn, maxTokens, stopSequence, toolUse, pauseTurn, refusal
    case other(String)

    init(_ raw: String) {
        switch raw {
        case "end_turn": self = .endTurn
        case "max_tokens": self = .maxTokens
        case "stop_sequence": self = .stopSequence
        case "tool_use": self = .toolUse
        case "pause_turn": self = .pauseTurn
        case "refusal": self = .refusal
        default: self = .other(raw)
        }
    }
}

/// Only filled for refusals. `category` is an open set ("cyber", "bio", "reasoning_extraction", …) and may be nil.
struct AnthropicStopDetails: Equatable, Sendable {
    var type: String?
    var category: String?
    var explanation: String?
    var recommendedModel: String?

    init(type: String? = nil, category: String? = nil, explanation: String? = nil, recommendedModel: String? = nil) {
        self.type = type
        self.category = category
        self.explanation = explanation
        self.recommendedModel = recommendedModel
    }

    init?(json: AnthropicJSON?) {
        guard let json, case .object = json else { return nil }
        type = json["type"]?.stringValue
        category = json["category"]?.stringValue
        explanation = json["explanation"]?.stringValue
        recommendedModel = json["recommended_model"]?.stringValue
    }
}

/// One attempt in `usage.iterations`: `message` for the requested model, `fallback_message` for a fallback that ran.
struct AnthropicUsageIteration: Equatable, Sendable {
    var type: String
    var model: String?
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadInputTokens = 0
    var cacheCreationInputTokens = 0
    var cacheCreation5mInputTokens: Int?
    var cacheCreation1hInputTokens: Int?
}

struct AnthropicUsage: Equatable, Sendable {
    var inputTokens = 0
    var outputTokens = 0
    var cacheReadInputTokens = 0
    var cacheCreationInputTokens = 0
    /// The write split by lifetime, when Anthropic reports it.
    var cacheCreation5mInputTokens: Int?
    var cacheCreation1hInputTokens: Int?
    /// Per attempt, when fallbacks are on: the source of truth for billing. Top-level figures cover only the attempt
    /// that produced the message.
    var iterations: [AnthropicUsageIteration] = []

    /// A fallback model served this reply.
    var fallbackServed: Bool { iterations.contains { $0.type == "fallback_message" } }

    /// Fields present in `json` replace the current values (message_delta carries the final counts).
    mutating func merge(_ json: AnthropicJSON?) {
        guard let json, case .object = json else { return }
        if let value = json["input_tokens"]?.intValue { inputTokens = max(0, value) }
        if let value = json["output_tokens"]?.intValue { outputTokens = max(0, value) }
        if let value = json["cache_read_input_tokens"]?.intValue { cacheReadInputTokens = max(0, value) }
        if let value = json["cache_creation_input_tokens"]?.intValue { cacheCreationInputTokens = max(0, value) }
        if let split = json["cache_creation"], case .object = split {
            cacheCreation5mInputTokens = split["ephemeral_5m_input_tokens"]?.intValue.map { max(0, $0) }
            cacheCreation1hInputTokens = split["ephemeral_1h_input_tokens"]?.intValue.map { max(0, $0) }
        }
        if let list = json["iterations"]?.arrayValue {
            iterations = list.map { entry in
                var iteration = AnthropicUsageIteration(type: entry["type"]?.stringValue ?? "message", model: entry["model"]?.stringValue)
                iteration.inputTokens = max(0, entry["input_tokens"]?.intValue ?? 0)
                iteration.outputTokens = max(0, entry["output_tokens"]?.intValue ?? 0)
                iteration.cacheReadInputTokens = max(0, entry["cache_read_input_tokens"]?.intValue ?? 0)
                iteration.cacheCreationInputTokens = max(0, entry["cache_creation_input_tokens"]?.intValue ?? 0)
                if let split = entry["cache_creation"], case .object = split {
                    iteration.cacheCreation5mInputTokens = split["ephemeral_5m_input_tokens"]?.intValue
                    iteration.cacheCreation1hInputTokens = split["ephemeral_1h_input_tokens"]?.intValue
                }
                return iteration
            }
        }
    }
}

/// A complete reply.
struct AnthropicMessage: Equatable, Sendable {
    let id: String
    /// The model that produced the reply (a fallback model when one served it).
    let model: String
    /// The model the request asked for.
    let requestedModel: String
    let blocks: [AnthropicOutputBlock]
    let stopReason: AnthropicStopReason?
    let stopDetails: AnthropicStopDetails?
    let usage: AnthropicUsage

    /// All text blocks, in order.
    var text: String {
        blocks.compactMap { block -> String? in if case .text(let text) = block.content { return text }; return nil }.joined()
    }

    /// Thinking summaries or progress notes, when a display was asked for.
    var thinkingText: String {
        blocks.compactMap { block -> String? in
            if case .thinking(let text, _) = block.content, !text.isEmpty { return text }
            return nil
        }.joined(separator: "\n\n")
    }

    var toolUses: [AnthropicToolUse] {
        blocks.compactMap { block -> AnthropicToolUse? in if case .toolUse(let use) = block.content { return use }; return nil }
    }

    /// Tool calls Studio may act on: only when Claude stopped to use tools (never after a refusal or a cut-off reply,
    /// which can leave a call half written).
    var toolUsesToRun: [AnthropicToolUse] { stopReason == .toolUse ? toolUses : [] }

    var isRefusal: Bool { stopReason == .refusal }

    var fallbackServed: Bool {
        usage.fallbackServed || blocks.contains { if case .fallback = $0.content { return true }; return false }
    }

    /// The reply's blocks as they go back in the next assistant turn. Unchanged, except that after a mid-reply
    /// fallback only the text blocks before the last switch point are kept (the fallback model can't use the
    /// thinking or tool calls of the model it replaced), the switch markers themselves are left out, and empty text
    /// blocks (which Anthropic refuses in a request) are dropped.
    var historyContent: [AnthropicJSON] {
        let lastFallback = blocks.lastIndex { if case .fallback = $0.content { return true }; return false }
        var result: [AnthropicJSON] = []
        for (index, block) in blocks.enumerated() {
            if case .fallback = block.content { continue }
            if case .text(let text) = block.content, text.isEmpty { continue }
            if let lastFallback, index < lastFallback {
                guard case .text = block.content else { continue }
            }
            result.append(block.raw)
        }
        return result
    }
}

/// What to tell the seller when Claude declined. Any partial reply must be discarded.
func anthropicRefusalMessage(_ details: AnthropicStopDetails?) -> String {
    let base = "Claude declined this request, so nothing it wrote was kept."
    if let explanation = details?.explanation?.trimmingCharacters(in: .whitespacesAndNewlines), !explanation.isEmpty {
        return "\(base) Anthropic said: \(aiServiceRedacted(explanation, limit: 400))"
    }
    return base
}

// MARK: Streaming progress

/// Progress while a reply streams, delivered on the main actor.
enum AnthropicStreamProgress: Equatable, Sendable {
    case started(model: String)
    case blockStarted(type: String, toolName: String?)
    case textDelta(String)
    /// A thinking summary or progress note (empty under the default display, so not sent then).
    case thinkingDelta(String)
    /// Characters of a tool's input received so far.
    case toolInput(toolName: String, characters: Int)
    case fallback(from: String?, to: String?)
    case finished(AnthropicStopReason?)
}

// MARK: Errors and redaction

enum AnthropicError: LocalizedError, Equatable {
    case missingKey
    /// Not sent: the request couldn't be built or was refused locally. Nothing was spent.
    case notSent(String)
    /// Anthropic answered with this HTTP status. `message` is already redacted.
    case http(status: Int, type: String?, message: String, retryAfter: TimeInterval?)
    /// An `error` event part-way through the stream (for example `overloaded_error`). Any partial reply is discarded.
    case stream(type: String, message: String)
    case transport(String)
    case timedOut
    case invalidResponse(String)
    case responseTooLarge
    /// The stream ended before `message_stop`.
    case incomplete

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return "Add your Anthropic API key in Settings › Account › Claude (Anthropic) first."
        case .notSent(let message):
            return message
        case .http(let status, let type, let message, let retryAfter):
            return anthropicHTTPErrorMessage(status: status, type: type, message: message, retryAfter: retryAfter)
        case .stream(let type, let message):
            switch type {
            case "overloaded_error": return "Anthropic is overloaded right now, so Claude stopped part-way. Try again in a few minutes."
            case "rate_limit_error": return "Anthropic is limiting requests right now, so Claude stopped part-way. Try again in a minute."
            case "api_error": return "Anthropic had a problem part-way through the reply. Try again in a moment."
            default: return message.isEmpty ? "Claude stopped part-way with an error (\(type))." : "Claude stopped part-way: \(message)"
            }
        case .transport(let message):
            return "Studio couldn’t reach Anthropic: \(message)"
        case .timedOut:
            return "Anthropic stopped responding, so Studio gave up waiting. Try again."
        case .invalidResponse(let message):
            return message
        case .responseTooLarge:
            return "Claude’s reply was larger than Studio reads, so it was ignored."
        case .incomplete:
            return "The connection to Anthropic ended before Claude finished. Try again."
        }
    }

    /// Seconds Anthropic asked Studio to wait, when it said.
    var retryAfter: TimeInterval? {
        if case .http(_, _, _, let seconds) = self { return seconds }
        return nil
    }

    /// The failure is likely to pass (rate limit, overload, server or connection trouble), so offering Try Again is
    /// reasonable. The client itself never resends: every request is billed.
    var isTemporary: Bool {
        switch self {
        case .http(let status, _, _, _): return status == 429 || status == 408 || status >= 500
        case .stream(let type, _): return ["overloaded_error", "rate_limit_error", "api_error"].contains(type)
        case .transport, .timedOut, .incomplete: return true
        case .missingKey, .notSent, .invalidResponse, .responseTooLarge: return false
        }
    }
}

func anthropicHTTPErrorMessage(status: Int, type: String?, message: String, retryAfter: TimeInterval?) -> String {
    let detail = message.isEmpty ? "" : " Anthropic said: \(message)"
    switch status {
    case 400:
        return "Anthropic couldn’t accept the request.\(detail)"
    case 401:
        return "Anthropic rejected the API key. Check it in Settings › Account › Claude (Anthropic)."
    case 402:
        return "Anthropic reported a billing problem with this account. Check its credit balance at console.anthropic.com."
    case 403:
        return "This API key isn’t allowed to do that.\(detail)"
    case 404:
        return "Anthropic couldn’t find Claude Opus 5.5 for this account.\(detail)"
    case 408:
        return "Anthropic timed out handling the request. Try again."
    case 413:
        return "The request was too large for Anthropic. Use a smaller photo or fewer pictures."
    case 429:
        if let retryAfter, retryAfter > 0 {
            return "Anthropic is limiting requests right now. Try again in \(anthropicWaitDescription(retryAfter))."
        }
        return "Anthropic is limiting requests right now. Try again in a minute."
    case 529:
        return "Anthropic is overloaded right now. Try again in a few minutes."
    case 300...399:
        return "Anthropic redirected the request, so Studio stopped."
    case 500...599:
        return "Anthropic is having trouble right now (HTTP \(status)). Try again in a moment."
    default:
        return "Anthropic couldn’t complete the request (HTTP \(status)).\(detail)"
    }
}

/// "30 seconds", "1 minute", "5 minutes".
func anthropicWaitDescription(_ seconds: TimeInterval) -> String {
    let whole = Int(seconds.rounded(.up))
    if whole < 60 { return whole == 1 ? "1 second" : "\(whole) seconds" }
    let minutes = Int((Double(whole) / 60).rounded(.up))
    return minutes == 1 ? "1 minute" : "\(minutes) minutes"
}

/// Seconds from a `retry-after` header given in seconds, capped at an hour; nil when absent or unreadable.
func anthropicRetryAfterSeconds(_ raw: String?) -> TimeInterval? {
    guard let raw, let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite, value >= 0 else { return nil }
    return min(value, 3600)
}

/// The error type and message from an Anthropic error body (`{"type":"error","error":{"type":…,"message":…}}`).
func anthropicErrorDetails(fromBody data: Data, secrets: [String]) -> (type: String?, message: String) {
    guard let json = try? AnthropicJSON.parse(data), let error = json["error"] else {
        return (nil, "")
    }
    return (error["type"]?.stringValue, aiServiceRedacted(error["message"]?.stringValue ?? "", secrets: secrets))
}

/// Text safe to show or record: every credential in `secrets`, anything shaped like an Anthropic, Meshy or Tripo key
/// (`sk-ant-…`, `msy_…`, `tsk_…`), Bearer tokens and `x-api-key` values are replaced, and the result is clipped to one
/// short line.
func aiServiceRedacted(_ text: String, secrets: [String] = [], limit: Int = 240) -> String {
    var result = text
    for secret in secrets.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where secret.count >= 4 {
        result = result.replacingOccurrences(of: secret, with: "[redacted]")
    }
    let patterns: [(String, String)] = [
        (#"sk-ant-[A-Za-z0-9_\-]+"#, "[redacted]"),
        (#"\bmsy_[A-Za-z0-9_\-]+"#, "[redacted]"),
        (#"\btsk_[A-Za-z0-9_\-]+"#, "[redacted]"),
        (#"(?i)\bbearer\s+[A-Za-z0-9._~+/=\-]+"#, "Bearer [redacted]"),
        (#"(?i)"?x-api-key"?\s*[:=]\s*"?[^"\s,}]+"?"#, "x-api-key: [redacted]")
    ]
    for (pattern, replacement) in patterns {
        result = result.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
    }
    result = result.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    if result.count > limit { result = String(result.prefix(limit)) + "…" }
    return result
}

/// Why a typed key can't be an Anthropic API key, or nil. Pasted keys often carry spaces or line breaks.
func anthropicKeyProblem(_ raw: String) -> String? {
    let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if key.isEmpty { return "Enter the API key." }
    if key.count > anthropicMaxKeyLength { return "The API key is too long." }
    guard key.unicodeScalars.allSatisfy({ $0.value > 0x20 && $0.value < 0x7F }) else {
        return "The API key has spaces or characters an Anthropic key never has. Copy it again."
    }
    if key.hasPrefix("sk-ant-admin") { return "That’s an Admin API key. Create a regular API key in the Anthropic Console instead." }
    guard key.hasPrefix("sk-ant-") else { return "Anthropic API keys start with sk-ant-. Copy the key again from the Anthropic Console." }
    return nil
}

// MARK: Server-sent events

struct AnthropicSSEEvent: Equatable, Sendable {
    var event: String?
    var data: String
}

/// Splits a byte stream into server-sent events. Bytes may arrive in any chunks: a line, a CRLF pair or a UTF-8
/// character split across chunks is put back together. Comment lines and unknown fields are skipped.
struct AnthropicSSEParser {
    private var line: [UInt8] = []
    private var lastWasCR = false
    private var eventName: String?
    private var dataLines: [String] = []

    mutating func feed<S: Sequence>(_ bytes: S) -> [AnthropicSSEEvent] where S.Element == UInt8 {
        var events: [AnthropicSSEEvent] = []
        for byte in bytes {
            if byte == 0x0A, lastWasCR { lastWasCR = false; continue }
            lastWasCR = byte == 0x0D
            if byte == 0x0A || byte == 0x0D {
                if let event = endLine() { events.append(event) }
            } else {
                line.append(byte)
            }
        }
        return events
    }

    /// Flushes a final event that wasn't followed by a blank line.
    mutating func finish() -> [AnthropicSSEEvent] {
        var events: [AnthropicSSEEvent] = []
        if !line.isEmpty, let event = endLine() { events.append(event) }
        if let event = dispatch() { events.append(event) }
        return events
    }

    private mutating func endLine() -> AnthropicSSEEvent? {
        defer { line.removeAll(keepingCapacity: true) }
        if line.isEmpty { return dispatch() }
        if line.first == UInt8(ascii: ":") { return nil }
        let text = String(decoding: line, as: UTF8.self)
        let field: Substring
        var value: Substring
        if let colon = text.firstIndex(of: ":") {
            field = text[..<colon]
            value = text[text.index(after: colon)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }
        switch field {
        case "event": eventName = String(value)
        case "data": dataLines.append(String(value))
        default: break
        }
        return nil
    }

    private mutating func dispatch() -> AnthropicSSEEvent? {
        defer { eventName = nil; dataLines = [] }
        guard !dataLines.isEmpty else { return nil }
        return AnthropicSSEEvent(event: eventName, data: dataLines.joined(separator: "\n"))
    }
}

// MARK: Assembling the reply

/// Builds the complete reply from stream events, in the order blocks started.
struct AnthropicStreamAccumulator {
    private struct Builder {
        var index: Int
        var start: AnthropicJSON
        var type: String
        var text = ""
        var thinking = ""
        var signature = ""
        var partialJSON = ""
        var citations: [AnthropicJSON] = []
        var finished = false
    }

    private let requestedModel: String
    /// Schemas by tool name, for checking tool inputs. Looked up by name only, never iterated.
    private let schemas: [String: AnthropicJSON]
    private(set) var started = false
    private(set) var stopped = false
    private var id = ""
    private var model = ""
    private var usage = AnthropicUsage()
    private var stopReason: String?
    private var stopDetails: AnthropicJSON?
    private var builders: [Builder] = []
    private var positions: [Int: Int] = [:]

    init(requestedModel: String = anthropicDefaultModel, tools: [AnthropicTool] = []) {
        self.requestedModel = requestedModel
        var schemas: [String: AnthropicJSON] = [:]
        for tool in tools { schemas[tool.name] = tool.inputSchema }
        self.schemas = schemas
    }

    /// Applies one event. Throws for an `error` event or a malformed stream.
    mutating func handle(_ event: AnthropicSSEEvent) throws -> [AnthropicStreamProgress] {
        guard let json = try? AnthropicJSON.parse(event.data) else {
            throw AnthropicError.invalidResponse("Anthropic sent part of a reply Studio couldn’t read.")
        }
        let type = json["type"]?.stringValue ?? event.event ?? ""
        switch type {
        case "ping":
            return []
        case "error":
            let error = json["error"]
            throw AnthropicError.stream(type: error?["type"]?.stringValue ?? "error",
                                        message: aiServiceRedacted(error?["message"]?.stringValue ?? ""))
        case "message_start":
            guard !started, let message = json["message"] else { throw malformed }
            started = true
            id = message["id"]?.stringValue ?? ""
            model = message["model"]?.stringValue ?? requestedModel
            usage.merge(message["usage"])
            return [.started(model: model)]
        case "content_block_start":
            guard started, !stopped, let index = json["index"]?.intValue, positions[index] == nil,
                  let block = json["content_block"], let blockType = block["type"]?.stringValue else { throw malformed }
            var builder = Builder(index: index, start: block, type: blockType)
            builder.text = block["text"]?.stringValue ?? ""
            builder.thinking = block["thinking"]?.stringValue ?? ""
            builder.signature = block["signature"]?.stringValue ?? ""
            positions[index] = builders.count
            builders.append(builder)
            var progress: [AnthropicStreamProgress] = [.blockStarted(type: blockType, toolName: block["name"]?.stringValue)]
            if blockType == "fallback" {
                progress.append(.fallback(from: block["from"]?["model"]?.stringValue, to: block["to"]?["model"]?.stringValue))
            }
            if blockType == "text", !builder.text.isEmpty { progress.append(.textDelta(builder.text)) }
            return progress
        case "content_block_delta":
            guard started, !stopped, let index = json["index"]?.intValue, let position = positions[index],
                  !builders[position].finished, let delta = json["delta"] else { throw malformed }
            switch delta["type"]?.stringValue {
            case "text_delta":
                let text = delta["text"]?.stringValue ?? ""
                builders[position].text += text
                return text.isEmpty ? [] : [.textDelta(text)]
            case "thinking_delta":
                let text = delta["thinking"]?.stringValue ?? ""
                builders[position].thinking += text
                return text.isEmpty ? [] : [.thinkingDelta(text)]
            case "signature_delta":
                builders[position].signature += delta["signature"]?.stringValue ?? ""
                return []
            case "input_json_delta":
                builders[position].partialJSON += delta["partial_json"]?.stringValue ?? ""
                let name = builders[position].start["name"]?.stringValue ?? builders[position].type
                return [.toolInput(toolName: name, characters: builders[position].partialJSON.count)]
            case "citations_delta":
                if let citation = delta["citation"] { builders[position].citations.append(citation) }
                return []
            default:
                return []
            }
        case "content_block_stop":
            guard started, let index = json["index"]?.intValue, let position = positions[index] else { throw malformed }
            builders[position].finished = true
            return []
        case "message_delta":
            guard started else { throw malformed }
            if let reason = json["delta"]?["stop_reason"]?.stringValue { stopReason = reason }
            if let details = json["delta"]?["stop_details"], !details.isNull { stopDetails = details }
            usage.merge(json["usage"])
            return []
        case "message_stop":
            guard started else { throw malformed }
            stopped = true
            return [.finished(stopReason.map(AnthropicStopReason.init))]
        default:
            // New event types are allowed by the API's versioning policy; skip them.
            return []
        }
    }

    private var malformed: AnthropicError { .invalidResponse("Anthropic’s reply arrived out of order, so Studio stopped reading it.") }

    /// The finished reply. Throws `.incomplete` when the stream ended before `message_stop`.
    func message() throws -> AnthropicMessage {
        guard started, stopped else { throw AnthropicError.incomplete }
        let blocks = builders.map(finishedBlock)
        return AnthropicMessage(id: id, model: model, requestedModel: requestedModel, blocks: blocks,
                                stopReason: stopReason.map(AnthropicStopReason.init),
                                stopDetails: AnthropicStopDetails(json: stopDetails), usage: usage)
    }

    private func finishedBlock(_ builder: Builder) -> AnthropicOutputBlock {
        switch builder.type {
        case "text":
            var raw = builder.start.setting("text", to: .string(builder.text))
            if !builder.citations.isEmpty { raw = raw.setting("citations", to: .array(builder.citations)) }
            return AnthropicOutputBlock(content: .text(builder.text), raw: raw)
        case "thinking":
            let raw = builder.start.setting("thinking", to: .string(builder.thinking)).setting("signature", to: .string(builder.signature))
            return AnthropicOutputBlock(content: .thinking(builder.thinking, signature: builder.signature), raw: raw)
        case "redacted_thinking":
            return AnthropicOutputBlock(content: .redactedThinking, raw: builder.start)
        case "tool_use":
            let use = toolUse(builder)
            return AnthropicOutputBlock(content: .toolUse(use), raw: builder.start.setting("input", to: use.input))
        case "fallback":
            return AnthropicOutputBlock(content: .fallback(from: builder.start["from"]?["model"]?.stringValue,
                                                           to: builder.start["to"]?["model"]?.stringValue), raw: builder.start)
        default:
            var raw = builder.start
            if !builder.partialJSON.isEmpty, let input = try? AnthropicJSON.parse(builder.partialJSON) { raw = raw.setting("input", to: input) }
            return AnthropicOutputBlock(content: .other(type: builder.type), raw: raw)
        }
    }

    private func toolUse(_ builder: Builder) -> AnthropicToolUse {
        let id = builder.start["id"]?.stringValue ?? ""
        let name = builder.start["name"]?.stringValue ?? ""
        let empty = AnthropicJSON.object([AnthropicJSONMember]())
        var input = builder.start["input"] ?? empty
        var problem: String?
        if !builder.partialJSON.isEmpty {
            if let parsed = try? AnthropicJSON.parse(builder.partialJSON) {
                input = parsed
            } else {
                input = empty
                problem = builder.finished ? "Claude’s input for \(name) wasn’t valid JSON." : "Claude’s input for \(name) was cut off."
            }
        }
        if problem == nil {
            if case .object = input {
                if let schema = schemas[name] {
                    problem = anthropicSchemaProblem(input, schema: schema)
                } else {
                    problem = "Claude asked for a tool Studio didn’t offer (\(aiServiceRedacted(name, limit: 60)))."
                }
            } else {
                input = empty
                problem = "Claude’s input for \(name) wasn’t an object."
            }
        }
        if id.isEmpty, problem == nil { problem = "Claude’s tool call had no ID." }
        return AnthropicToolUse(id: id, name: name, input: input, rawInputJSON: builder.partialJSON, inputProblem: problem)
    }
}

// MARK: Cost

/// USD per million tokens.
struct AnthropicPricing: Equatable, Sendable {
    var input: Decimal
    var output: Decimal
    var cacheRead: Decimal
    var cacheWrite5m: Decimal
    var cacheWrite1h: Decimal
}

/// Published list prices (Claude API) for Opus 5.5 and the Opus models its fallbacks may use. Writes are 1.25× input
/// for five minutes and 2× for an hour.
let anthropicPriceList: [(model: String, pricing: AnthropicPricing)] = [
    ("claude-opus-5-5", AnthropicPricing(input: 4, output: 20, cacheRead: Decimal(string: "0.20")!, cacheWrite5m: 5, cacheWrite1h: 8)),
    ("claude-opus-5", AnthropicPricing(input: 5, output: 25, cacheRead: Decimal(string: "0.50")!, cacheWrite5m: Decimal(string: "6.25")!, cacheWrite1h: 10)),
    ("claude-opus-4-8", AnthropicPricing(input: 5, output: 25, cacheRead: Decimal(string: "0.50")!, cacheWrite5m: Decimal(string: "6.25")!, cacheWrite1h: 10))
]

/// The price list entry for a model ID (an exact match first, then a dated variant of a listed ID).
func anthropicPricing(forModel model: String) -> AnthropicPricing? {
    if let exact = anthropicPriceList.first(where: { $0.model == model }) { return exact.pricing }
    return anthropicPriceList.first(where: { model.hasPrefix($0.model + "-2") })?.pricing
}

struct AnthropicCostEstimate: Equatable, Sendable {
    var usd: Decimal
    /// False when part of the usage was on a model Studio has no price for (that part isn't counted).
    var complete: Bool
}

/// An estimate for display, from the reply's token counts at list prices. Per-attempt figures are used when the reply
/// reports them (fallbacks), each at its own model's price. Anthropic's invoice is what counts.
func anthropicEstimatedCost(_ usage: AnthropicUsage, model: String, requestedModel: String = anthropicDefaultModel) -> AnthropicCostEstimate {
    func cost(input: Int, output: Int, read: Int, write: Int, write5m: Int?, write1h: Int?, pricing: AnthropicPricing) -> Decimal {
        let long = max(0, write1h ?? 0)
        let short = write5m ?? max(0, write - long)
        let tokens = Decimal(input) * pricing.input + Decimal(output) * pricing.output + Decimal(read) * pricing.cacheRead
            + Decimal(short) * pricing.cacheWrite5m + Decimal(long) * pricing.cacheWrite1h
        return tokens / 1_000_000
    }
    var total = Decimal(0)
    var complete = true
    if usage.iterations.isEmpty {
        if let pricing = anthropicPricing(forModel: model) {
            total = cost(input: usage.inputTokens, output: usage.outputTokens, read: usage.cacheReadInputTokens,
                         write: usage.cacheCreationInputTokens, write5m: usage.cacheCreation5mInputTokens,
                         write1h: usage.cacheCreation1hInputTokens, pricing: pricing)
        } else {
            complete = false
        }
    } else {
        for iteration in usage.iterations {
            let iterationModel = iteration.model ?? (iteration.type == "fallback_message" ? model : requestedModel)
            guard let pricing = anthropicPricing(forModel: iterationModel) else { complete = false; continue }
            total += cost(input: iteration.inputTokens, output: iteration.outputTokens, read: iteration.cacheReadInputTokens,
                          write: iteration.cacheCreationInputTokens, write5m: iteration.cacheCreation5mInputTokens,
                          write1h: iteration.cacheCreation1hInputTokens, pricing: pricing)
        }
    }
    return AnthropicCostEstimate(usd: total, complete: complete)
}

/// "under $0.01", "about $0.42", or "at least $0.42" when part of the usage couldn't be priced.
func anthropicCostText(_ estimate: AnthropicCostEstimate) -> String {
    var rounded = Decimal()
    var value = estimate.usd
    NSDecimalRound(&rounded, &value, 2, .plain)
    if estimate.usd < Decimal(string: "0.01")! { return estimate.complete ? "under $0.01" : "unknown" }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "en_US")
    let amount = "$" + (formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)")
    return estimate.complete ? "about \(amount)" : "at least \(amount)"
}

// MARK: Client

private final class AnthropicNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Sends Messages requests with one key. Safe to use from any task; cancelling the task stops the stream.
final class AnthropicClient: @unchecked Sendable {
    private let apiKey: String
    private let session: URLSession

    /// `protocolClasses` is for tests only (a local stub in place of the network).
    init(apiKey: String, protocolClasses: [AnyClass]? = nil) {
        self.apiKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = anthropicStreamIdleTimeout
        configuration.timeoutIntervalForResource = anthropicStreamResourceTimeout
        if let protocolClasses { configuration.protocolClasses = protocolClasses }
        session = URLSession(configuration: configuration, delegate: AnthropicNoRedirectDelegate(), delegateQueue: nil)
    }

    func invalidate() { session.invalidateAndCancel() }

    /// The cheapest request that proves the key, the model and billing all work: a one-word reply at low effort.
    static func keyTestRequest() -> AnthropicRequest {
        AnthropicRequest(maxTokens: 256, messages: [.user(text: "Reply with the single word OK.")], effort: .low)
    }

    /// The URLRequest for `request`. Exposed for tests.
    func urlRequest(for request: AnthropicRequest) throws -> URLRequest {
        if let problem = request.problem { throw AnthropicError.notSent("Not sent: \(problem)") }
        guard anthropicKeyProblem(apiKey) == nil else { throw AnthropicError.missingKey }
        let body = request.json.encoded
        guard body.count <= anthropicMaxRequestBytes else {
            throw AnthropicError.notSent("Not sent: the request is larger than Anthropic accepts. Use a smaller photo or fewer pictures.")
        }
        var urlRequest = URLRequest(url: anthropicMessagesURL)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "accept")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(anthropicAPIVersion, forHTTPHeaderField: "anthropic-version")
        if !request.betaHeaders.isEmpty { urlRequest.setValue(request.betaHeaders.joined(separator: ","), forHTTPHeaderField: "anthropic-beta") }
        urlRequest.httpBody = body
        return urlRequest
    }

    /// Sends the request once and returns the complete reply. Progress is delivered on the main actor as the reply
    /// streams. Throws `CancellationError` when the task is cancelled (the stream is closed). Never retries: a
    /// failure is reported to the caller, who decides.
    func send(_ request: AnthropicRequest,
              onProgress: (@MainActor @Sendable (AnthropicStreamProgress) -> Void)? = nil) async throws -> AnthropicMessage {
        let urlRequest = try urlRequest(for: request)
        try Task.checkCancellation()
        let secrets = [apiKey]
        do {
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else { throw AnthropicError.invalidResponse("Anthropic returned a non-HTTP response.") }
            guard (200..<300).contains(http.statusCode) else {
                var body = Data()
                for try await byte in bytes {
                    body.append(byte)
                    if body.count >= anthropicMaxErrorBodyBytes { break }
                }
                let details = anthropicErrorDetails(fromBody: body, secrets: secrets)
                throw AnthropicError.http(status: http.statusCode, type: details.type, message: details.message,
                                          retryAfter: anthropicRetryAfterSeconds(http.value(forHTTPHeaderField: "retry-after")))
            }
            if http.expectedContentLength > Int64(anthropicMaxResponseBytes) { throw AnthropicError.responseTooLarge }
            var parser = AnthropicSSEParser()
            var accumulator = AnthropicStreamAccumulator(requestedModel: request.model, tools: request.tools)
            var line: [UInt8] = []
            var total = 0
            func deliver(_ events: [AnthropicSSEEvent]) async throws {
                for event in events {
                    let progress = try accumulator.handle(event)
                    if let onProgress { for item in progress { await onProgress(item) } }
                }
            }
            for try await byte in bytes {
                total += 1
                if total > anthropicMaxResponseBytes { throw AnthropicError.responseTooLarge }
                line.append(byte)
                guard byte == 0x0A || byte == 0x0D else { continue }
                let events = parser.feed(line)
                line.removeAll(keepingCapacity: true)
                try await deliver(events)
                if accumulator.stopped { break }
                try Task.checkCancellation()
            }
            if !accumulator.stopped {
                try Task.checkCancellation()
                try await deliver(parser.feed(line) + parser.finish())
            }
            return try accumulator.message()
        } catch let error as AnthropicError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw AnthropicError.timedOut
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw AnthropicError.transport(aiServiceRedacted(error.localizedDescription, secrets: secrets))
        }
    }
}

// MARK: Keychain

/// A service's API key in its own Keychain item (service "SlantStudio"), kept apart from the Slant key ("api-key")
/// and Shopify's details. Readable only on this Mac while it is unlocked.
struct AIServiceKeychainItem: Equatable, Sendable {
    let account: String

    static let anthropic = AIServiceKeychainItem(account: "anthropic-api-key")
    static let meshy = AIServiceKeychainItem(account: "meshy-api-key")
    static let tripo = AIServiceKeychainItem(account: "tripo-api-key")

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "SlantStudio", kSecAttrAccount as String: account]
    }

    func load() throws -> String? {
        var attributes = query
        attributes[kSecReturnData as String] = true
        attributes[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(attributes as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw APIError.keychain(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw StudioError("The saved key couldn’t be read. Remove it in Settings and add it again.")
        }
        return value
    }

    func save(_ value: String) throws {
        let values: [String: Any] = [kSecValueData as String: Data(value.utf8)]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query.merging(values) { _, new in new }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw APIError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw APIError.keychain(status) }
    }
}

// MARK: Connection state

/// The app-wide Claude connection. Only whether a key was saved is kept in preferences, so Studio can show whether
/// Claude is set up without reading the Keychain; the key itself is read when a request is about to be made.
@MainActor final class AnthropicConnection: ObservableObject {
    static let shared = AnthropicConnection()
    static let keySavedDefaultsKey = "anthropicKeySaved"

    @Published private(set) var isConfigured: Bool
    /// Claude requests running now (feature sheets and Settings' test). The key can't change under them.
    @Published private(set) var activeRequests = 0
    private var client: AnthropicClient?
    private let defaults: UserDefaults
    private let keychain: AIServiceKeychainItem

    init(defaults: UserDefaults = .standard, keychain: AIServiceKeychainItem = .anthropic) {
        self.defaults = defaults
        self.keychain = keychain
        isConfigured = defaults.bool(forKey: Self.keySavedDefaultsKey)
    }

    var isBusy: Bool { activeRequests > 0 }

    /// Why the key can't be saved or removed now, or nil.
    var keyChangeBlockedReason: String? {
        anthropicKeyChangeBlockedReason(activeRequests: activeRequests)
    }

    func beginRequest() { activeRequests += 1 }
    func endRequest() { activeRequests = max(0, activeRequests - 1) }

    /// The client for the saved key, reading the Keychain the first time.
    func currentClient() throws -> AnthropicClient {
        if let client { return client }
        guard isConfigured else { throw AnthropicError.missingKey }
        guard let key = try keychain.load(), anthropicKeyProblem(key) == nil else {
            isConfigured = false
            defaults.set(false, forKey: Self.keySavedDefaultsKey)
            throw AnthropicError.missingKey
        }
        let client = AnthropicClient(apiKey: key)
        self.client = client
        return client
    }

    /// Sends one request with the saved key, counted in `activeRequests` while it runs.
    func send(_ request: AnthropicRequest,
              onProgress: (@MainActor @Sendable (AnthropicStreamProgress) -> Void)? = nil) async throws -> AnthropicMessage {
        let client = try currentClient()
        beginRequest()
        defer { endRequest() }
        return try await client.send(request, onProgress: onProgress)
    }

    /// Saves a key that has just passed its test, replacing any other.
    func save(key: String, client: AnthropicClient) throws {
        try keychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        defaults.set(true, forKey: Self.keySavedDefaultsKey)
        if self.client !== client { self.client?.invalidate() }
        self.client = client
        isConfigured = true
    }

    /// Deletes the Keychain item and forgets the client.
    func remove() throws {
        try keychain.delete()
        defaults.set(false, forKey: Self.keySavedDefaultsKey)
        client?.invalidate()
        client = nil
        isConfigured = false
    }
}

/// Why the Claude key can't change now, or nil: a request using it is still running.
func anthropicKeyChangeBlockedReason(activeRequests: Int) -> String? {
    activeRequests > 0 ? "Wait for the current Claude request to finish." : nil
}
