import XCTest
@testable import SlantStudio

final class AnthropicJSONTests: XCTestCase {
    func testRoundTripKeepsKeyOrderAndEscapes() throws {
        let text = #"{"z":1,"a":[true,false,null],"m":{"q":"line\nbreak \"quoted\" \\ tab\t","e":"é😀"},"n":-2.5,"big":12345678901}"#
        let value = try AnthropicJSON.parse(text)
        XCTAssertEqual(value.objectMembers?.map(\.key), ["z", "a", "m", "n", "big"])
        XCTAssertEqual(value["m"]?["q"]?.stringValue, "line\nbreak \"quoted\" \\ tab\t")
        XCTAssertEqual(value["m"]?["e"]?.stringValue, "é😀")
        XCTAssertEqual(value["n"], .double(-2.5))
        XCTAssertEqual(value["big"], .int(12_345_678_901))
        XCTAssertEqual(value.encodedString, text)
        XCTAssertEqual(try AnthropicJSON.parse(value.encodedString), value)
    }

    func testUnicodeEscapesAndSurrogates() throws {
        XCTAssertEqual(try AnthropicJSON.parse(#""é😀\/""#).stringValue, "é😀/")
        XCTAssertThrowsError(try AnthropicJSON.parse(#""\ud83d""#))
        XCTAssertThrowsError(try AnthropicJSON.parse(#""\ude00x""#))
        XCTAssertEqual(AnthropicJSON.string("a\u{01}b").encodedString, #""a\u0001b""#)
    }

    func testStrictParsingRejectsMalformedInput() {
        for bad in ["", "{", "{\"a\":1,}", "[1,]", "01", "1.", "-", "tru", "{\"a\" 1}", "\"raw\nnewline\"", "{} x", "NaN", "'a'"] {
            XCTAssertThrowsError(try AnthropicJSON.parse(bad), bad)
        }
        let deep = String(repeating: "[", count: 300) + String(repeating: "]", count: 300)
        XCTAssertThrowsError(try AnthropicJSON.parse(deep))
        XCTAssertNoThrow(try AnthropicJSON.parse(String(repeating: "[", count: 200) + String(repeating: "]", count: 200)))
    }

    func testNonFiniteDoublesEncodeAsNull() {
        XCTAssertEqual(AnthropicJSON.array([.double(.nan), .double(.infinity), .double(3), .double(0.25)]).encodedString, "[null,null,3,0.25]")
    }

    func testSettingReplacesInPlaceAndDropsDuplicates() throws {
        let value = try AnthropicJSON.parse(#"{"a":1,"b":2,"a":3}"#)
        XCTAssertEqual(value["a"], .int(3))
        XCTAssertEqual(value.setting("a", to: 9).encodedString, #"{"a":9,"b":2}"#)
        XCTAssertEqual(value.setting("c", to: true).encodedString, #"{"a":1,"b":2,"a":3,"c":true}"#)
    }

    func testSchemaProblems() {
        let schema: AnthropicJSON = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "minLength": 1],
                "size": ["type": "number", "minimum": 0.5, "maximum": 300],
                "count": ["type": "integer"],
                "kind": ["type": "string", "enum": ["hook", "clip"]],
                "tags": ["type": "array", "items": ["type": "string"], "maxItems": 2]
            ],
            "required": ["name", "size"],
            "additionalProperties": false
        ]
        XCTAssertNil(anthropicSchemaProblem(["name": "Hook", "size": 12, "count": 2.0, "kind": "hook", "tags": ["a"]], schema: schema))
        XCTAssertEqual(anthropicSchemaProblem(["name": "Hook"], schema: schema), "input.size is missing.")
        XCTAssertEqual(anthropicSchemaProblem(["name": "Hook", "size": 0.1], schema: schema), "input.size is below 0.5.")
        XCTAssertEqual(anthropicSchemaProblem(["name": "Hook", "size": 1, "extra": 1], schema: schema), "input.extra isn’t an expected field.")
        XCTAssertEqual(anthropicSchemaProblem(["name": "Hook", "size": 1, "count": 1.5], schema: schema), "input.count should be integer.")
        XCTAssertEqual(anthropicSchemaProblem(["name": "Hook", "size": 1, "kind": "bracket"], schema: schema), "input.kind isn’t one of the allowed values.")
        XCTAssertEqual(anthropicSchemaProblem(["name": "Hook", "size": 1, "tags": ["a", 2]], schema: schema), "input.tags[1] should be string.")
        XCTAssertEqual(anthropicSchemaProblem(["name": "", "size": 1], schema: schema), "input.name is too short.")
        XCTAssertEqual(anthropicSchemaProblem("text", schema: schema), "input should be object.")
    }
}

final class AnthropicRequestTests: XCTestCase {
    private let schema: AnthropicJSON = ["type": "object", "properties": ["code": ["type": "string"]], "required": ["code"], "additionalProperties": false]

    func testRequestBodyIsStableAndOrdered() {
        let image = AnthropicImage(mediaType: .jpeg, base64Data: "QUJD")
        let request = AnthropicRequest(
            maxTokens: 64_000,
            system: [AnthropicSystemBlock("You design parts.", cacheControl: .fiveMinutes)],
            tools: [AnthropicTool(name: "write_scad", description: "Write the model", inputSchema: schema, cacheControl: .oneHour)],
            messages: [
                .user([.image(image), .text("A hook, 20 mm wide.")]),
                AnthropicMessageParam(role: .assistant, content: [.raw(["type": "tool_use", "id": "toolu_1", "name": "write_scad", "input": ["code": "cube(1);"]])]),
                .user([.toolResult(toolUseID: "toolu_1", content: [.text("Rendered"), .image(AnthropicImage(mediaType: .png, base64Data: "UE5H"))], isError: true)]),
                .system("Keep walls at least 2 mm.")
            ],
            effort: .high, thinkingDisplay: .summarized, automaticCaching: .fiveMinutes)
        let expected = #"{"model":"claude-opus-5-5","max_tokens":64000,"stream":true,"system":[{"type":"text","text":"You design parts.","cache_control":{"type":"ephemeral"}}],"tools":[{"name":"write_scad","description":"Write the model","input_schema":{"type":"object","properties":{"code":{"type":"string"}},"required":["code"],"additionalProperties":false},"strict":true,"eager_input_streaming":true,"cache_control":{"type":"ephemeral","ttl":"1h"}}],"tool_choice":{"type":"auto"},"thinking":{"type":"adaptive","display":"summarized"},"output_config":{"effort":"high"},"fallbacks":"default","cache_control":{"type":"ephemeral"},"messages":[{"role":"user","content":[{"type":"image","source":{"type":"base64","media_type":"image/jpeg","data":"QUJD"}},{"type":"text","text":"A hook, 20 mm wide."}]},{"role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"write_scad","input":{"code":"cube(1);"}}]},{"role":"user","content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[{"type":"text","text":"Rendered"},{"type":"image","source":{"type":"base64","media_type":"image/png","data":"UE5H"}}],"is_error":true}]},{"role":"system","content":"Keep walls at least 2 mm."}]}"#
        XCTAssertEqual(request.json.encodedString, expected)
        // Same request, same bytes.
        XCTAssertEqual(request.json.encoded, request.json.encoded)
        XCTAssertNil(request.problem)
        XCTAssertEqual(request.betaHeaders, [anthropicFallbackBeta])
    }

    func testMinimalRequestOmitsOptionalFields() {
        var request = AnthropicRequest(maxTokens: 10, messages: [.user(text: "Hi")], effort: .low, thinkingDisplay: .updates, useDefaultFallbacks: false)
        XCTAssertEqual(request.json.encodedString,
                       #"{"model":"claude-opus-5-5","max_tokens":10,"stream":true,"thinking":{"type":"adaptive","display":"updates"},"output_config":{"effort":"low"},"messages":[{"role":"user","content":[{"type":"text","text":"Hi"}]}]}"#)
        XCTAssertEqual(request.betaHeaders, [anthropicThinkingUpdatesBeta])
        request.disableParallelToolUse = true
        request.tools = [AnthropicTool(name: "t", description: "d", inputSchema: schema, strict: false, eagerInputStreaming: false)]
        XCTAssertTrue(request.json.encodedString.contains(#""tools":[{"name":"t","description":"d","input_schema":"#))
        XCTAssertFalse(request.json.encodedString.contains("strict"))
        XCTAssertTrue(request.json.encodedString.contains(#""tool_choice":{"type":"auto","disable_parallel_tool_use":true}"#))
    }

    func testRequestProblems() {
        XCTAssertNotNil(AnthropicRequest(messages: []).problem)
        XCTAssertNotNil(AnthropicRequest(maxTokens: 0, messages: [.user(text: "a")]).problem)
        let assistant = AnthropicMessageParam(role: .assistant, content: [.text("prefill")])
        XCTAssertEqual(AnthropicRequest(messages: [.user(text: "a"), assistant]).problem, "A conversation can’t end with Claude’s turn.")
        XCTAssertNotNil(AnthropicRequest(messages: [assistant, .user(text: "a")]).problem)
        XCTAssertNotNil(AnthropicRequest(messages: [.user(text: "a"), assistant, .system("x"), .user(text: "b")]).problem)
        XCTAssertNil(AnthropicRequest(messages: [.user(text: "a"), .system("x")]).problem)
        XCTAssertNotNil(AnthropicRequest(messages: [.user([])]).problem)
        let tool = AnthropicTool(name: "t", description: "", inputSchema: schema)
        XCTAssertEqual(AnthropicRequest(tools: [tool, tool], messages: [.user(text: "a")]).problem, "Two tools are both called t.")
        let cached = AnthropicInputBlock.text("x", cacheControl: .fiveMinutes)
        XCTAssertNotNil(AnthropicRequest(system: [AnthropicSystemBlock("s", cacheControl: .fiveMinutes)],
                                         messages: [.user([cached, cached, cached])], automaticCaching: .fiveMinutes).problem)
        XCTAssertNil(AnthropicRequest(messages: [.user([cached, cached, cached])], automaticCaching: .fiveMinutes).problem)
    }

    func testKeyTestRequestIsCheap() {
        let request = AnthropicClient.keyTestRequest()
        XCTAssertLessThanOrEqual(request.maxTokens, 256)
        XCTAssertEqual(request.effort, .low)
        XCTAssertTrue(request.tools.isEmpty)
        XCTAssertNil(request.problem)
    }

    func testURLRequestHeaders() throws {
        let client = AnthropicClient(apiKey: "  sk-ant-api03-test  ")
        let urlRequest = try client.urlRequest(for: AnthropicRequest(messages: [.user(text: "Hi")]))
        XCTAssertEqual(urlRequest.url, URL(string: "https://api.anthropic.com/v1/messages"))
        XCTAssertEqual(urlRequest.httpMethod, "POST")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "x-api-key"), "sk-ant-api03-test")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        XCTAssertEqual(urlRequest.value(forHTTPHeaderField: "content-type"), "application/json")
        XCTAssertThrowsError(try AnthropicClient(apiKey: "nope").urlRequest(for: AnthropicRequest(messages: [.user(text: "Hi")]))) {
            XCTAssertEqual($0 as? AnthropicError, .missingKey)
        }
        XCTAssertThrowsError(try client.urlRequest(for: AnthropicRequest(messages: []))) {
            guard case .notSent? = $0 as? AnthropicError else { return XCTFail("expected notSent") }
        }
        // Anthropic's 32 MB limit, checked with a smaller injected limit so the test doesn't build a 32 MB request.
        XCTAssertEqual(anthropicMaxRequestBytes, 32 * 1024 * 1024)
        let large = AnthropicRequest(messages: [.user(text: String(repeating: "A", count: 4_096))])
        XCTAssertThrowsError(try client.urlRequest(for: large, maxBodyBytes: 4_096)) {
            guard case .notSent? = $0 as? AnthropicError else { return XCTFail("expected notSent") }
        }
        XCTAssertNoThrow(try client.urlRequest(for: large, maxBodyBytes: 8_192))
    }
}

// MARK: - Streaming

/// A recorded-style stream: summarised thinking with a signature, text, then a tool call whose input arrives in pieces.
let anthropicToolStreamFixture = """
event: message_start
data: {"type":"message_start","message":{"id":"msg_01","type":"message","role":"assistant","model":"claude-opus-5-5","content":[],"stop_reason":null,"stop_sequence":null,"usage":{"input_tokens":1200,"cache_creation_input_tokens":3000,"cache_read_input_tokens":0,"output_tokens":1}}}

event: ping
data: {"type": "ping"}

: a comment line

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"Measuring the "}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hook."}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"EqQBCgIYAhIM1gbcDa9GJwZA2b3h"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Here’s a "}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"first draft."}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: content_block_start
data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_01","name":"write_scad","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"code\\": \\"cube([20, "}}

event: content_block_delta
data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"10, 2]);\\", \\"wall\\": 2.0}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":2}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use","stop_sequence":null},"usage":{"output_tokens":420}}

event: message_stop
data: {"type":"message_stop"}


"""

private let fixtureTools = [AnthropicTool(
    name: "write_scad", description: "Write OpenSCAD",
    inputSchema: ["type": "object", "properties": ["code": ["type": "string"], "wall": ["type": "number", "minimum": 1]],
                  "required": ["code", "wall"], "additionalProperties": false])]

private func events(_ text: String, chunkSize: Int) -> [AnthropicSSEEvent] {
    var parser = AnthropicSSEParser()
    let bytes = Array(text.utf8)
    var events: [AnthropicSSEEvent] = []
    var start = 0
    while start < bytes.count {
        let end = min(bytes.count, start + chunkSize)
        events += parser.feed(bytes[start..<end])
        start = end
    }
    return events + parser.finish()
}

private func accumulate(_ text: String, tools: [AnthropicTool] = fixtureTools, chunkSize: Int = 7) throws -> (AnthropicMessage, [AnthropicStreamProgress]) {
    var accumulator = AnthropicStreamAccumulator(tools: tools)
    var progress: [AnthropicStreamProgress] = []
    for event in events(text, chunkSize: chunkSize) { progress += try accumulator.handle(event) }
    return (try accumulator.message(), progress)
}

final class AnthropicStreamTests: XCTestCase {
    func testSSEParserHandlesAnyChunkingAndLineEndings() {
        let reference = events(anthropicToolStreamFixture, chunkSize: 100_000)
        XCTAssertEqual(reference.count, 18)
        XCTAssertEqual(reference.first?.event, "message_start")
        for size in [1, 2, 3, 5, 64] { XCTAssertEqual(events(anthropicToolStreamFixture, chunkSize: size), reference, "chunk \(size)") }
        let crlf = anthropicToolStreamFixture.replacingOccurrences(of: "\n", with: "\r\n")
        for size in [1, 2, 7] { XCTAssertEqual(events(crlf, chunkSize: size), reference, "CRLF chunk \(size)") }
        let cr = anthropicToolStreamFixture.replacingOccurrences(of: "\n", with: "\r")
        XCTAssertEqual(events(cr, chunkSize: 3), reference)
    }

    func testSSEParserMultiLineDataAndUnterminatedFinalEvent() {
        var parser = AnthropicSSEParser()
        var result = parser.feed(Array("event: x\ndata: a\ndata:b\nid: 1\nretry: 5\n\ndata: tail".utf8))
        XCTAssertEqual(result, [AnthropicSSEEvent(event: "x", data: "a\nb")])
        result = parser.finish()
        XCTAssertEqual(result, [AnthropicSSEEvent(event: nil, data: "tail")])
        // A UTF-8 character split across chunks is put back together.
        var split = AnthropicSSEParser()
        let bytes = Array("data: é😀\n\n".utf8)
        var out: [AnthropicSSEEvent] = []
        for byte in bytes { out += split.feed([byte]) }
        XCTAssertEqual(out, [AnthropicSSEEvent(event: nil, data: "é😀")])
    }

    func testToolStreamAssemblesCompleteMessage() throws {
        let (message, progress) = try accumulate(anthropicToolStreamFixture)
        XCTAssertEqual(message.id, "msg_01")
        XCTAssertEqual(message.model, "claude-opus-5-5")
        XCTAssertEqual(message.stopReason, .toolUse)
        XCTAssertNil(message.stopDetails)
        XCTAssertEqual(message.text, "Here’s a first draft.")
        XCTAssertEqual(message.thinkingText, "Measuring the hook.")
        XCTAssertEqual(message.blocks.map(\.type), ["thinking", "text", "tool_use"])
        guard case .thinking(_, let signature) = message.blocks[0].content else { return XCTFail() }
        XCTAssertEqual(signature, "EqQBCgIYAhIM1gbcDa9GJwZA2b3h")
        XCTAssertEqual(message.toolUses.count, 1)
        let use = message.toolUses[0]
        XCTAssertEqual(use.id, "toolu_01")
        XCTAssertEqual(use.input["code"]?.stringValue, "cube([20, 10, 2]);")
        XCTAssertEqual(use.input["wall"]?.doubleValue, 2)
        XCTAssertNil(use.inputProblem)
        XCTAssertEqual(message.toolUsesToRun, [use])
        XCTAssertEqual(message.usage.inputTokens, 1200)
        XCTAssertEqual(message.usage.cacheCreationInputTokens, 3000)
        XCTAssertEqual(message.usage.outputTokens, 420)
        XCTAssertEqual(progress.first, .started(model: "claude-opus-5-5"))
        XCTAssertTrue(progress.contains(.textDelta("first draft.")))
        XCTAssertTrue(progress.contains(.thinkingDelta("hook.")))
        XCTAssertEqual(progress.last(where: { if case .toolInput = $0 { return true }; return false }),
                       .toolInput(toolName: "write_scad", characters: use.rawInputJSON.count))
        XCTAssertEqual(progress.last, .finished(.toolUse))
        // History keeps the blocks verbatim: thinking and signature included, the tool input in Claude's key order.
        let history = AnthropicMessageParam.assistant(message).json.encodedString
        XCTAssertEqual(history, #"{"role":"assistant","content":[{"type":"thinking","thinking":"Measuring the hook.","signature":"EqQBCgIYAhIM1gbcDa9GJwZA2b3h"},{"type":"text","text":"Here’s a first draft."},{"type":"tool_use","id":"toolu_01","name":"write_scad","input":{"code":"cube([20, 10, 2]);","wall":2}}]}"#)
        // Chunking doesn't change the result.
        XCTAssertEqual(try accumulate(anthropicToolStreamFixture, chunkSize: 1).0, message)
    }

    func testInvalidAndOutOfSchemaToolInputsAreFlaggedNotRun() throws {
        let broken = anthropicToolStreamFixture.replacingOccurrences(of: #"\", \"wall\": 2.0}"#, with: #"\", \"wall\": 2.0"#)
        let (message, _) = try accumulate(broken)
        let use = try XCTUnwrap(message.toolUses.first)
        XCTAssertEqual(use.input, .object([]))
        XCTAssertNotNil(use.inputProblem)
        guard case .toolResult(let id, let content, let isError, _) = use.errorResult else { return XCTFail() }
        XCTAssertEqual(id, "toolu_01")
        XCTAssertTrue(isError)
        guard case .text(let detail)? = content.first else { return XCTFail() }
        XCTAssertTrue(detail.hasPrefix(#"{"INVALID_JSON":"{\"code\": "#), detail)

        let thin = anthropicToolStreamFixture.replacingOccurrences(of: #"\"wall\": 2.0"#, with: #"\"wall\": 0.4"#)
        let thinUse = try XCTUnwrap(try accumulate(thin).0.toolUses.first)
        XCTAssertEqual(thinUse.inputProblem, "input.wall is below 1.")
        guard case .toolResult(_, let thinContent, _, _) = thinUse.errorResult, case .text(let thinDetail)? = thinContent.first else { return XCTFail() }
        XCTAssertEqual(thinDetail, #"{"error":"input.wall is below 1."}"#)

        let unknown = try XCTUnwrap(try accumulate(anthropicToolStreamFixture, tools: []).0.toolUses.first)
        XCTAssertEqual(unknown.inputProblem, "Claude asked for a tool Studio didn’t offer (write_scad).")
    }

    func testCutOffReplyHasNoToolsToRun() throws {
        let cut = anthropicToolStreamFixture.replacingOccurrences(of: #""stop_reason":"tool_use""#, with: #""stop_reason":"max_tokens""#)
        let (message, _) = try accumulate(cut)
        XCTAssertEqual(message.stopReason, .maxTokens)
        XCTAssertEqual(message.toolUses.count, 1)
        XCTAssertTrue(message.toolUsesToRun.isEmpty)
    }

    func testRefusalCarriesStopDetails() throws {
        let stream = """
        event: message_start
        data: {"type":"message_start","message":{"id":"msg_r","model":"claude-opus-5-5","content":[],"usage":{"input_tokens":50,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":"Partial"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"refusal","stop_details":{"type":"refusal","category":"cyber","explanation":"This looks like a request for harmful code."}},"usage":{"output_tokens":3}}

        event: message_stop
        data: {"type":"message_stop"}


        """
        let (message, progress) = try accumulate(stream)
        XCTAssertTrue(message.isRefusal)
        XCTAssertEqual(message.stopDetails?.category, "cyber")
        XCTAssertTrue(message.toolUsesToRun.isEmpty)
        XCTAssertTrue(progress.contains(.textDelta("Partial")))
        XCTAssertEqual(anthropicRefusalMessage(message.stopDetails),
                       "Claude declined this request, so nothing it wrote was kept. Anthropic said: This looks like a request for harmful code.")
        XCTAssertEqual(anthropicRefusalMessage(nil), "Claude declined this request, so nothing it wrote was kept.")
    }

    func testErrorEventThrowsAndIncompleteStreamThrows() {
        let overloaded = """
        event: message_start
        data: {"type":"message_start","message":{"id":"m","model":"claude-opus-5-5","usage":{}}}

        event: error
        data: {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}


        """
        XCTAssertThrowsError(try accumulate(overloaded)) { error in
            XCTAssertEqual(error as? AnthropicError, .stream(type: "overloaded_error", message: "Overloaded"))
            XCTAssertTrue((error as? AnthropicError)?.isTemporary == true)
        }
        let truncated = String(anthropicToolStreamFixture.prefix(upTo: anthropicToolStreamFixture.range(of: "event: message_delta")!.lowerBound))
        XCTAssertThrowsError(try accumulate(truncated)) { XCTAssertEqual($0 as? AnthropicError, .incomplete) }
        XCTAssertThrowsError(try accumulate("data: {not json}\n\n")) {
            guard case .invalidResponse? = $0 as? AnthropicError else { return XCTFail("\($0)") }
        }
        // A delta for a block that never started.
        let orphan = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"model\":\"x\"}}\n\ndata: {\"type\":\"content_block_delta\",\"index\":4,\"delta\":{\"type\":\"text_delta\",\"text\":\"a\"}}\n\n"
        XCTAssertThrowsError(try accumulate(orphan)) {
            guard case .invalidResponse? = $0 as? AnthropicError else { return XCTFail("\($0)") }
        }
    }

    func testUnknownEventsAndBlocksAreKept() throws {
        let stream = """
        data: {"type":"message_start","message":{"id":"m","model":"claude-opus-5-5","usage":{"input_tokens":5}}}

        data: {"type":"brand_new_event","x":1}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"redacted_thinking","data":"ENCRYPTED"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

        data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Done"}}

        data: {"type":"content_block_stop","index":1}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9}}

        data: {"type":"message_stop"}
        """
        let (message, _) = try accumulate(stream)
        XCTAssertEqual(message.blocks.map(\.type), ["redacted_thinking", "text"])
        XCTAssertEqual(message.historyContent.first, ["type": "redacted_thinking", "data": "ENCRYPTED"])
        XCTAssertEqual(message.stopReason, .endTurn)
    }

    func testToolCallsBeforeAFallbackAreNotRunAndCutOffRepliesDontJoinHistory() throws {
        let stream = """
        data: {"type":"message_start","message":{"id":"m","model":"claude-opus-5","usage":{"input_tokens":5}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_old","name":"render_scad","input":{}}}

        data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"code\\":\\"cube(1);\\"}"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-5"}}}

        data: {"type":"content_block_stop","index":1}

        data: {"type":"content_block_start","index":2,"content_block":{"type":"tool_use","id":"toolu_new","name":"render_scad","input":{}}}

        data: {"type":"content_block_delta","index":2,"delta":{"type":"input_json_delta","partial_json":"{\\"code\\":\\"cube(2);\\"}"}}

        data: {"type":"content_block_stop","index":2}

        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":9}}

        data: {"type":"message_stop"}
        """
        let (message, _) = try accumulate(stream)
        XCTAssertEqual(message.toolUses.map(\.id), ["toolu_new"])
        XCTAssertEqual(message.toolUsesToRun.map(\.id), ["toolu_new"])
        XCTAssertTrue(message.canJoinHistory)
        XCTAssertEqual(message.historyContent.compactMap { $0["id"]?.stringValue }, ["toolu_new"])

        let cutOff = stream.replacingOccurrences(of: #""stop_reason":"tool_use""#, with: #""stop_reason":"model_context_window_exceeded""#)
        let (cutMessage, _) = try accumulate(cutOff)
        XCTAssertFalse(cutMessage.canJoinHistory)
        XCTAssertTrue(cutMessage.toolUsesToRun.isEmpty)
    }

    func testMidReplyFallbackHistoryKeepsOnlyEarlierText() throws {
        let stream = """
        data: {"type":"message_start","message":{"id":"m","model":"claude-opus-5","usage":{"input_tokens":5}}}

        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":"S1"}}

        data: {"type":"content_block_stop","index":0}

        data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":"Before "}}

        data: {"type":"content_block_stop","index":1}

        data: {"type":"content_block_start","index":2,"content_block":{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-5"}}}

        data: {"type":"content_block_stop","index":2}

        data: {"type":"content_block_start","index":3,"content_block":{"type":"thinking","thinking":"","signature":"S2"}}

        data: {"type":"content_block_stop","index":3}

        data: {"type":"content_block_start","index":4,"content_block":{"type":"text","text":"after"}}

        data: {"type":"content_block_stop","index":4}

        data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":9,"iterations":[{"type":"message","input_tokens":5,"output_tokens":2},{"type":"fallback_message","input_tokens":5,"output_tokens":7}]}}

        data: {"type":"message_stop"}
        """
        let (message, progress) = try accumulate(stream)
        XCTAssertTrue(message.fallbackServed)
        XCTAssertTrue(progress.contains(.fallback(from: "claude-opus-5-5", to: "claude-opus-5")))
        XCTAssertEqual(message.text, "Before after")
        XCTAssertEqual(message.historyContent.map { $0["type"]?.stringValue }, ["text", "thinking", "text"])
        XCTAssertEqual(message.historyContent[1]["signature"]?.stringValue, "S2")
    }
}

// MARK: - Errors, redaction, keys, cost

final class AnthropicSupportTests: XCTestCase {
    func testRedaction() {
        let text = "x-api-key: sk-ant-api03-AbC_123-xyz failed\nBearer tsk_secret.value and msy_ABCdef123 and \"x-api-key\":\"plain\" mine=MYSECRET"
        let redacted = aiServiceRedacted(text, secrets: ["MYSECRET"])
        for secret in ["sk-ant-api03", "AbC_123", "tsk_secret", "msy_ABC", "plain", "MYSECRET"] {
            XCTAssertFalse(redacted.contains(secret), "\(secret) in \(redacted)")
        }
        XCTAssertFalse(redacted.contains("\n"))
        XCTAssertEqual(aiServiceRedacted(String(repeating: "a", count: 500)).count, 241)
    }

    func testErrorBodyParsingRedactsAndMapsStatuses() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"bad key sk-ant-api03-zzz"},"request_id":"req_1"}"#.utf8)
        let details = anthropicErrorDetails(fromBody: body, secrets: [])
        XCTAssertEqual(details.type, "invalid_request_error")
        XCTAssertEqual(details.message, "bad key [redacted]")
        XCTAssertEqual(anthropicErrorDetails(fromBody: Data("<html>".utf8), secrets: []).message, "")

        XCTAssertEqual(AnthropicError.http(status: 429, type: "rate_limit_error", message: "", retryAfter: 30).errorDescription,
                       "Anthropic is limiting requests right now. Try again in 30 seconds.")
        XCTAssertEqual(AnthropicError.http(status: 429, type: nil, message: "", retryAfter: 90).errorDescription,
                       "Anthropic is limiting requests right now. Try again in 2 minutes.")
        XCTAssertEqual(AnthropicError.http(status: 429, type: nil, message: "", retryAfter: 90).retryAfter, 90)
        XCTAssertTrue(AnthropicError.http(status: 529, type: "overloaded_error", message: "", retryAfter: nil).isTemporary)
        XCTAssertTrue(AnthropicError.http(status: 500, type: nil, message: "", retryAfter: nil).isTemporary)
        XCTAssertFalse(AnthropicError.http(status: 400, type: nil, message: "", retryAfter: nil).isTemporary)
        XCTAssertFalse(AnthropicError.http(status: 401, type: nil, message: "", retryAfter: nil).isTemporary)
        for status in [400, 401, 402, 403, 404, 413, 500, 529, 302, 418] {
            let text = AnthropicError.http(status: status, type: nil, message: "detail", retryAfter: nil).errorDescription ?? ""
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertTrue(AnthropicError.http(status: 401, type: nil, message: "", retryAfter: nil).errorDescription!.contains("API key"))
        XCTAssertTrue(AnthropicError.http(status: 413, type: nil, message: "", retryAfter: nil).errorDescription!.contains("smaller photo"))
        XCTAssertEqual(anthropicRetryAfterSeconds("12"), 12)
        XCTAssertEqual(anthropicRetryAfterSeconds("99999"), 3600)
        XCTAssertNil(anthropicRetryAfterSeconds("soon"))
        XCTAssertNil(anthropicRetryAfterSeconds(nil))
    }

    func testKeyProblems() {
        XCTAssertNil(anthropicKeyProblem("  sk-ant-api03-abcDEF_123-x \n"))
        XCTAssertNotNil(anthropicKeyProblem(""))
        XCTAssertNotNil(anthropicKeyProblem("sk-ant-api03 abc"))
        XCTAssertNotNil(anthropicKeyProblem("sl-slantkey"))
        XCTAssertNotNil(anthropicKeyProblem("sk-ant-admin01-abc"))
        XCTAssertNotNil(anthropicKeyProblem("sk-ant-" + String(repeating: "a", count: 300)))
        XCTAssertEqual(anthropicKeyChangeBlockedReason(activeRequests: 1), "Wait for the current Claude request to finish.")
        XCTAssertNil(anthropicKeyChangeBlockedReason(activeRequests: 0))
        XCTAssertEqual(anthropicKeyChangeBlockedReason(activeRequests: 0, openSessions: 1),
                       "Close Design an Accessory or Review for Printing first.")
    }

    func testCostEstimate() {
        var usage = AnthropicUsage()
        usage.inputTokens = 10_000
        usage.outputTokens = 20_000
        usage.cacheReadInputTokens = 100_000
        usage.cacheCreationInputTokens = 4_000
        // 10k × $4 + 20k × $20 + 100k × $0.20 + 4k × $5 = 0.04 + 0.40 + 0.02 + 0.02
        let estimate = anthropicEstimatedCost(usage, model: "claude-opus-5-5")
        XCTAssertEqual(estimate, AnthropicCostEstimate(usd: Decimal(string: "0.48")!, complete: true))
        XCTAssertEqual(anthropicCostText(estimate), "about $0.48")

        usage.cacheCreation5mInputTokens = 1_000
        usage.cacheCreation1hInputTokens = 3_000
        // 1k × $5 + 3k × $8 = 0.005 + 0.024 instead of 0.02
        XCTAssertEqual(anthropicEstimatedCost(usage, model: "claude-opus-5-5").usd, Decimal(string: "0.489")!)

        var tiny = AnthropicUsage()
        tiny.inputTokens = 20
        tiny.outputTokens = 100
        XCTAssertEqual(anthropicCostText(anthropicEstimatedCost(tiny, model: "claude-opus-5-5")), "under $0.01")

        XCTAssertEqual(anthropicEstimatedCost(tiny, model: "claude-unknown").complete, false)
        XCTAssertEqual(anthropicCostText(anthropicEstimatedCost(usage, model: "claude-unknown")), "unknown")
        XCTAssertNotNil(anthropicPricing(forModel: "claude-opus-5-5"))
        XCTAssertEqual(anthropicPricing(forModel: "claude-opus-5")?.input, 5)
        XCTAssertEqual(anthropicPricing(forModel: "claude-opus-5-20260101")?.input, 5)
        XCTAssertEqual(anthropicPricing(forModel: "claude-opus-5-5")?.input, 4)
    }

    func testCostUsesPerAttemptFiguresForFallbacks() {
        var usage = AnthropicUsage()
        usage.inputTokens = 1_000_000 // top level covers only the serving attempt; ignored when iterations exist
        usage.iterations = [
            AnthropicUsageIteration(type: "message", model: nil, inputTokens: 100_000, outputTokens: 0),
            AnthropicUsageIteration(type: "fallback_message", model: nil, inputTokens: 100_000, outputTokens: 10_000)
        ]
        // Opus 5.5 attempt: 100k × $4 = 0.40; Opus 5 fallback: 100k × $5 + 10k × $25 = 0.75
        let estimate = anthropicEstimatedCost(usage, model: "claude-opus-5", requestedModel: "claude-opus-5-5")
        XCTAssertEqual(estimate, AnthropicCostEstimate(usd: Decimal(string: "1.15")!, complete: true))
        XCTAssertEqual(anthropicCostText(AnthropicCostEstimate(usd: Decimal(string: "1234.567")!, complete: false)), "at least $1,234.57")
    }

    func testUsageMergeTakesFinalCounts() {
        var usage = AnthropicUsage()
        usage.merge(["input_tokens": 10, "output_tokens": 1, "cache_read_input_tokens": 5, "cache_creation": ["ephemeral_5m_input_tokens": 2, "ephemeral_1h_input_tokens": 3]])
        usage.merge(["output_tokens": 50, "input_tokens": 12])
        XCTAssertEqual(usage.inputTokens, 12)
        XCTAssertEqual(usage.outputTokens, 50)
        XCTAssertEqual(usage.cacheReadInputTokens, 5)
        XCTAssertEqual(usage.cacheCreation1hInputTokens, 3)
        XCTAssertFalse(usage.fallbackServed)
    }

    func testKeyTestStatusLine() {
        var usage = AnthropicUsage()
        usage.inputTokens = 15
        usage.outputTokens = 40
        let message = AnthropicMessage(id: "m", model: "claude-opus-5-5", requestedModel: "claude-opus-5-5", blocks: [],
                                       stopReason: .maxTokens, stopDetails: nil, usage: usage)
        XCTAssertEqual(anthropicKeyTestStatusLine(message), "The key works with Claude Opus 5.5. Test cost under $0.01.")
    }
}

// MARK: - The client against a local stub (no network)

final class AnthropicStubProtocol: URLProtocol {
    struct Reply {
        var status: Int
        var headers: [String: String]
        var chunks: [Data]
    }
    nonisolated(unsafe) static var reply = Reply(status: 200, headers: [:], chunks: [])
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
            stream.close()
            Self.lastBody = data
        } else {
            Self.lastBody = request.httpBody
        }
        let reply = Self.reply
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in reply.chunks { client?.urlProtocol(self, didLoad: chunk) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AnthropicClientStubTests: XCTestCase {
    private func client() -> AnthropicClient { AnthropicClient(apiKey: "sk-ant-api03-stubkey", protocolClasses: [AnthropicStubProtocol.self]) }

    @MainActor func testStreamedReplyThroughTheClient() async throws {
        let bytes = Data(anthropicToolStreamFixture.utf8)
        var chunks: [Data] = []
        var start = 0
        while start < bytes.count { chunks.append(bytes.subdata(in: start..<min(bytes.count, start + 13))); start += 13 }
        AnthropicStubProtocol.reply = .init(status: 200, headers: ["Content-Type": "text/event-stream"], chunks: chunks)
        let request = AnthropicRequest(tools: fixtureTools, messages: [.user(text: "Make a hook")])
        let collector = ProgressCollector()
        let message = try await client().send(request) { progress in collector.items.append(progress) }
        XCTAssertEqual(message.toolUses.first?.input["code"]?.stringValue, "cube([20, 10, 2]);")
        XCTAssertEqual(AnthropicStubProtocol.lastRequest?.value(forHTTPHeaderField: "x-api-key"), "sk-ant-api03-stubkey")
        XCTAssertEqual(AnthropicStubProtocol.lastBody, request.json.encoded)
        let items = await MainActor.run { collector.items }
        XCTAssertEqual(items.first, .started(model: "claude-opus-5-5"))
        XCTAssertEqual(items.last, .finished(.toolUse))
    }

    func testHTTPErrorsAreMappedWithRetryAfterAndRedacted() async {
        AnthropicStubProtocol.reply = .init(status: 429, headers: ["retry-after": "20", "Content-Type": "application/json"], chunks: [
            Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"Slow down sk-ant-api03-stubkey"}}"#.utf8)
        ])
        do {
            _ = try await client().send(AnthropicRequest(messages: [.user(text: "Hi")]))
            XCTFail("expected an error")
        } catch let error as AnthropicError {
            XCTAssertEqual(error, .http(status: 429, type: "rate_limit_error", message: "Slow down [redacted]", retryAfter: 20))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testStreamThatEndsEarlyIsIncomplete() async {
        let truncated = String(anthropicToolStreamFixture.prefix(upTo: anthropicToolStreamFixture.range(of: "event: message_stop")!.lowerBound))
        AnthropicStubProtocol.reply = .init(status: 200, headers: [:], chunks: [Data(truncated.utf8)])
        do {
            _ = try await client().send(AnthropicRequest(tools: fixtureTools, messages: [.user(text: "Hi")]))
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? AnthropicError, .incomplete)
        }
    }

    func testCancelledBeforeSendingThrowsCancellation() async {
        AnthropicStubProtocol.reply = .init(status: 200, headers: [:], chunks: [Data(anthropicToolStreamFixture.utf8)])
        let task = Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await self.client().send(AnthropicRequest(messages: [.user(text: "Hi")])); return nil } catch { return error }
        }
        let error = await task.value
        XCTAssertTrue(error is CancellationError, "\(String(describing: error))")
    }
}

@MainActor private final class ProgressCollector: @unchecked Sendable {
    var items: [AnthropicStreamProgress] = []
}
