import XCTest
import simd
@testable import SlantStudio

// Design an Accessory from a Photo: code safety, the brief and prompt, Studio's render facts, and the bounded design
// loop driven by stubbed Claude replies and renders (no network, no OpenSCAD).

private func boxTriangles(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> [Float] {
    let p: [SIMD3<Float>] = [
        SIMD3(low.x, low.y, low.z), SIMD3(high.x, low.y, low.z), SIMD3(high.x, high.y, low.z), SIMD3(low.x, high.y, low.z),
        SIMD3(low.x, low.y, high.z), SIMD3(high.x, low.y, high.z), SIMD3(high.x, high.y, high.z), SIMD3(low.x, high.y, high.z)
    ]
    let faces: [(Int, Int, Int)] = [
        (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
        (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)
    ]
    return faces.flatMap { [p[$0.0], p[$0.1], p[$0.2]] }.flatMap { [$0.x, $0.y, $0.z] }
}

private func boxSTL(_ low: SIMD3<Float> = .zero, _ high: SIMD3<Float> = SIMD3(20, 30, 10)) throws -> Data {
    try STLMesh.validated(boxTriangles(low, high)).stlCopyData()
}

private func render(_ stl: Data, code: String = "width = 20; // [10:1:40] Width\ncube([width, 30, 10]);") throws -> AccessoryRender {
    try XCTUnwrap(analyseAccessoryRender(stl: stl, code: code, openSCADMessages: []))
}

private func reply(_ blocks: [AnthropicOutputBlock], stop: AnthropicStopReason?, details: AnthropicStopDetails? = nil) -> AnthropicMessage {
    AnthropicMessage(id: "msg", model: anthropicDefaultModel, requestedModel: anthropicDefaultModel, blocks: blocks,
                     stopReason: stop, stopDetails: details, usage: AnthropicUsage(inputTokens: 1_000, outputTokens: 500))
}

private func textBlock(_ text: String) -> AnthropicOutputBlock {
    AnthropicOutputBlock(content: .text(text), raw: ["type": "text", "text": .string(text)])
}

private func toolCall(_ id: String, _ name: String, _ input: AnthropicJSON, problem: String? = nil, text: String? = nil) -> AnthropicMessage {
    let use = AnthropicToolUse(id: id, name: name, input: input, rawInputJSON: input.encodedString, inputProblem: problem)
    var blocks: [AnthropicOutputBlock] = []
    if let text { blocks.append(textBlock(text)) }
    blocks.append(AnthropicOutputBlock(content: .toolUse(use), raw: ["type": "tool_use", "id": .string(id), "name": .string(name), "input": input]))
    return reply(blocks, stop: .toolUse)
}

private let goodCode = "width = 20; // [10:1:40] Width\ncube([width, 30, 10]);"
private let finishInput: AnthropicJSON = ["name": "Phone stand", "summary": "A stand.", "print_orientation": "Flat on its back.", "notes": ["Check the lip."]]

/// Claude's replies in order, and every request Studio sent.
@MainActor private final class StubClaude {
    var replies: [Result<AnthropicMessage, Error>]
    var requests: [AnthropicRequest] = []
    init(_ replies: [Result<AnthropicMessage, Error>]) { self.replies = replies }
    func next(_ request: AnthropicRequest) throws -> AnthropicMessage {
        requests.append(request)
        guard !replies.isEmpty else { throw AnthropicError.incomplete }
        return try replies.removeFirst().get()
    }
}

private final class RenderCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int { lock.withLock { calls } }
    func bump() { lock.withLock { calls += 1 } }
}

@MainActor
final class AccessoryDesignerTests: XCTestCase {
    // MARK: Code safety

    func testSafeCodeIsAccepted() {
        XCTAssertNil(scadSafetyProblem(goodCode))
        XCTAssertNil(scadSafetyProblem("important_value = 3; // include this note\n/* use import() later */ cube(important_value);"))
        XCTAssertNil(scadSafetyProblem("text(\"use 1/2 inch\", font = \"Liberation Sans:style=Bold\"); text(\"90\\u00B0\");"))
        XCTAssertNil(scadSafetyProblem("label = \"Emma's \\\"stand\\\"\"; linear_extrude(1) text(label);"))
    }

    func testFileReadingCodeIsRefused() {
        XCTAssertNotNil(scadSafetyProblem("include <MCAD/boxes.scad>\ncube(1);"))
        XCTAssertNotNil(scadSafetyProblem("use <lib.scad>\ncube(1);"))
        XCTAssertNotNil(scadSafetyProblem("import(\"model.stl\");"))
        XCTAssertNotNil(scadSafetyProblem("import (\"x\");"))
        XCTAssertNotNil(scadSafetyProblem("surface(file = \"h.dat\");"))
        XCTAssertNotNil(scadSafetyProblem("cube(1); /* hidden */ include <x.scad>"))
    }

    func testPathsAndMalformedCodeAreRefused() {
        XCTAssertNotNil(scadSafetyProblem("echo(\"/etc/passwd\"); cube(1);"))
        XCTAssertNotNil(scadSafetyProblem("echo(\"~/Desktop\"); cube(1);"))
        XCTAssertNotNil(scadSafetyProblem("echo(\"C:\\\\x\"); cube(1);"))
        XCTAssertNotNil(scadSafetyProblem("echo(\"../secret\"); cube(1);"))
        XCTAssertNotNil(scadSafetyProblem("echo(\"part.stl\"); cube(1);"))
        XCTAssertNotNil(scadSafetyProblem("cube(1); /* never closed"))
        XCTAssertNotNil(scadSafetyProblem("echo(\"never closed); cube(1);"))
        XCTAssertNotNil(scadSafetyProblem("   \n "))
        XCTAssertNotNil(scadSafetyProblem("cube(1);\u{0}"))
        XCTAssertNotNil(scadSafetyProblem("// " + String(repeating: "x", count: scadSafetyMaximumBytes) + "\ncube(1);"))
        XCTAssertNil(scadSafetyProblem("// " + String(repeating: "x", count: scadSafetyMaximumBytes - 20) + "\ncube(1);"))
    }

    func testScanSkipsCommentsAndStrings() {
        let scan = scadSafetyScan("a = 1; // use\n/* include */ b = \"import\"; c();")
        XCTAssertEqual(scan.identifiers, ["a", "b", "c"])
        XCTAssertEqual(scan.strings, ["import"])
        XCTAssertNil(scan.problem)
    }

    // MARK: Brief and prompt

    func testMeasurementsNeedOneCompleteRow() {
        XCTAssertNotNil(accessoryMeasurementsProblem([AccessoryMeasurement()]))
        XCTAssertNotNil(accessoryMeasurementsProblem([AccessoryMeasurement(label: "Width", millimetres: "", method: .ruler)]))
        XCTAssertNotNil(accessoryMeasurementsProblem([AccessoryMeasurement(label: "", millimetres: "12", method: .ruler)]))
        XCTAssertNotNil(accessoryMeasurementsProblem([AccessoryMeasurement(label: "Width", millimetres: "-3", method: .ruler)]))
        XCTAssertNil(accessoryMeasurementsProblem([AccessoryMeasurement(), AccessoryMeasurement(label: "Width", millimetres: "75,5 mm", method: .ruler)]))
        let many = (0...accessoryMaximumMeasurements).map { AccessoryMeasurement(label: "M\($0)", millimetres: "1", method: .calipers) }
        XCTAssertNotNil(accessoryMeasurementsProblem(many))
    }

    func testMeasurementLinesCarryMethodAndUncertainty() {
        let rows = [AccessoryMeasurement(label: " Phone thickness ", millimetres: "9.50", method: .calipers),
                    AccessoryMeasurement(),
                    AccessoryMeasurement(label: "Cup holder", millimetres: "75", method: .estimate)]
        XCTAssertEqual(accessoryMeasurementLines(rows), [
            "- Phone thickness: 9.5 mm (measured with calipers, about ±0.2 mm)",
            "- Cup holder: 75 mm (estimated, about ±3 mm)"
        ])
        XCTAssertEqual(accessoryMillimetresText(0.25), "0.25 mm")
        XCTAssertEqual(accessoryMillimetresText(120), "120 mm")
        XCTAssertEqual(AccessoryMeasurementMethod.ruler.uncertaintyMM, 1)
    }

    func testBriefProblems() {
        var brief = AccessoryDesignBrief(description: "A phone stand", measurements: [AccessoryMeasurement(label: "Width", millimetres: "75", method: .ruler)])
        XCTAssertNil(accessoryBriefProblem(brief, photoCount: 1))
        XCTAssertNotNil(accessoryBriefProblem(brief, photoCount: 0))
        XCTAssertNotNil(accessoryBriefProblem(brief, photoCount: 4))
        brief.description = "  "
        XCTAssertNotNil(accessoryBriefProblem(brief, photoCount: 1))
    }

    func testFirstTurnPutsPhotosBeforeText() throws {
        let photo = PreparedImage(data: Data([1, 2, 3]), mediaType: .jpeg, pixelWidth: 10, pixelHeight: 10)
        let brief = AccessoryDesignBrief(description: "A stand for this phone at 60°",
                                         measurements: [AccessoryMeasurement(label: "Thickness", millimetres: "9.5", method: .calipers)],
                                         notes: "Use PETG")
        let turn = accessoryFirstTurn(brief, photos: [photo, photo])
        XCTAssertEqual(turn.role, .user)
        XCTAssertEqual(turn.content.count, 3)
        guard case .image = turn.content[0], case .image = turn.content[1], case .text(let text, _) = turn.content[2] else {
            return XCTFail("Expected two images, then the text")
        }
        XCTAssertTrue(text.contains("The 2 photos above"))
        XCTAssertTrue(text.contains("- Thickness: 9.5 mm (measured with calipers, about ±0.2 mm)"))
        XCTAssertTrue(text.contains("Seller’s notes: Use PETG"))
        XCTAssertTrue(text.contains("render_scad"))
    }

    func testRequestIsCachedStrictAndNeverForced() throws {
        let request = accessoryDesignRequest(messages: [.user(text: "hi")])
        XCTAssertNil(request.problem)
        XCTAssertEqual(request.effort, .high)
        XCTAssertGreaterThanOrEqual(request.maxTokens, 32_000)
        XCTAssertTrue(request.disableParallelToolUse)
        XCTAssertNotNil(request.system.last?.cacheControl)
        XCTAssertNotNil(request.automaticCaching)
        XCTAssertEqual(request.tools.map(\.name), ["render_scad", "ask_seller", "finish_design"])
        let body = request.json.encodedString
        XCTAssertTrue(body.contains("\"tool_choice\":{\"type\":\"auto\""))
        for tool in request.tools {
            XCTAssertTrue(tool.strict)
            let schema = tool.inputSchema.encodedString
            // Strict tools don't support these keywords; Studio checks lengths itself.
            for keyword in ["maxLength", "minLength", "maxItems", "minimum", "maximum"] { XCTAssertFalse(schema.contains(keyword), "\(tool.name) uses \(keyword)") }
            XCTAssertEqual(tool.inputSchema["additionalProperties"], .bool(false))
        }
        XCTAssertTrue(accessorySystemPrompt.contains("2.0 mm"))
        XCTAssertTrue(accessorySystemPrompt.contains("Never call a design strong"))
    }

    func testCostForecastGrowsWithReplies() {
        let forecast = accessoryCostForecast(photoSizes: [(1568, 1176)], textCharacters: 600)
        XCTAssertTrue(forecast.firstReply.complete)
        XCTAssertLessThan(forecast.firstReply.usd, forecast.typical.usd)
        XCTAssertLessThan(forecast.typical.usd, forecast.maximum.usd)
        XCTAssertEqual(forecast.maximumReplies, 10)
        XCTAssertTrue(accessoryCostForecastText(forecast).contains("all 10"))
        XCTAssertEqual(accessoryImageTokens(pixelWidth: 750, pixelHeight: 1), 1)
    }

    // MARK: Render facts

    func testAnalysisOfOneBoxIsAcceptable() throws {
        let result = try render(try boxSTL())
        XCTAssertTrue(result.isAcceptable)
        XCTAssertEqual(result.images.count, 4)
        XCTAssertEqual(result.facts.customizerValues, ["width"])
        XCTAssertTrue(result.facts.sitsOnBed)
        let text = accessoryRenderFactsText(result.facts, renderNumber: 1, maxRenders: 4)
        XCTAssertTrue(text.contains("Size: 20.0 × 30.0 × 10.0 mm"))
        XCTAssertTrue(text.contains("Lowest point: Z = 0 (on the bed)."))
        XCTAssertTrue(text.contains("Build volume: fits"))
        XCTAssertTrue(text.contains("Flat contact with the bed: 600 mm²"))
        XCTAssertTrue(text.contains("Customizer values found: 1 (width)."))
        XCTAssertTrue(text.contains("Studio can accept this render"))
        XCTAssertTrue(accessoryStudioCheckLines(result.facts).contains("Fits Slant’s 220 mm build volume"))
    }

    func testTwoPartsTooBigOrRaisedAreReported() throws {
        let twoParts = try STLMesh.validated(boxTriangles(.zero, SIMD3(10, 10, 10)) + boxTriangles(SIMD3(20, 0, 0), SIMD3(30, 10, 10))).stlCopyData()
        let parts = try render(twoParts)
        XCTAssertFalse(parts.isAcceptable)
        XCTAssertNil(parts.facts.wallThickness)
        XCTAssertTrue(parts.problems.joined().contains("2 separate parts"))

        let big = try render(try boxSTL(.zero, SIMD3(230, 10, 10)))
        XCTAssertFalse(big.isAcceptable)
        XCTAssertTrue(accessoryRenderFactsText(big.facts, renderNumber: 2, maxRenders: 4).contains("doesn’t fit"))

        let raised = try render(try boxSTL(SIMD3(0, 0, 3), SIMD3(10, 10, 13)))
        XCTAssertTrue(raised.isAcceptable, "Not sitting on Z = 0 is a note, not a blocker")
        XCTAssertTrue(accessoryRenderFactsText(raised.facts, renderNumber: 1, maxRenders: 4).contains("not on the bed"))
    }

    func testAnalysisIsDeterministic() throws {
        let stl = try boxSTL()
        let first = try render(stl)
        let second = try render(stl)
        XCTAssertEqual(first.stl, second.stl)
        XCTAssertEqual(first.facts, second.facts)
        XCTAssertEqual(first.images.map(\.image.data), second.images.map(\.image.data))
        XCTAssertEqual(accessoryRenderFactsText(first.facts, renderNumber: 1, maxRenders: 4),
                       accessoryRenderFactsText(second.facts, renderNumber: 1, maxRenders: 4))
    }

    func testUnusableOutputThrowsAndCancellationReturnsNil() throws {
        XCTAssertThrowsError(try analyseAccessoryRender(stl: Data(), code: goodCode, openSCADMessages: []))
        XCTAssertThrowsError(try analyseAccessoryRender(stl: Data("solid x\nfacet\n".utf8), code: goodCode, openSCADMessages: []))
        XCTAssertNil(try analyseAccessoryRender(stl: try boxSTL(), code: goodCode, openSCADMessages: [], isCancelled: { true }))
    }

    func testRenderToolResultCarriesFactsThenCaptionedPictures() throws {
        let result = try render(try boxSTL())
        guard case .toolResult(let id, let content, let isError, _) = accessoryRenderToolResult(.rendered(result), toolUseID: "t1", renderNumber: 1, maxRenders: 4) else {
            return XCTFail("Expected a tool result")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertFalse(isError)
        XCTAssertEqual(content.count, 1 + 2 * 4)
        guard case .text = content[1], case .image(let image) = content[2] else { return XCTFail("Expected a caption, then a picture") }
        XCTAssertEqual(image.mediaType, .jpeg)
        guard case .toolResult(_, _, let failedIsError, _) = accessoryRenderToolResult(.failed("Syntax error"), toolUseID: "t2", renderNumber: 2, maxRenders: 4) else {
            return XCTFail("Expected a tool result")
        }
        XCTAssertTrue(failedIsError)
    }

    func testOpenSCADMessagesAreFilteredAndPathsRemoved() {
        let log = """
        Compiling design (CSG Tree generation)...
        WARNING: Ignoring unknown variable 'wdth' in file /private/var/folders/ab/T/SlantStudio-Accessory-1234/design.scad, line 4
        ECHO: "angle", 60
        ERROR: Parser error in file "/var/folders/ab/T/SlantStudio-Accessory-1234/design.scad", line 9: syntax error
        Rendering Polygon Mesh using CGAL...
        """
        let messages = accessoryOpenSCADMessages(log)
        XCTAssertEqual(messages.count, 3)
        XCTAssertTrue(messages[0].hasSuffix("in file design.scad, line 4"))
        XCTAssertFalse(messages.joined().contains("/var/"))
        XCTAssertEqual(accessoryOpenSCADMessages(String(repeating: "WARNING: x\n", count: 30)).count, 12)
        XCTAssertTrue(accessoryOpenSCADFailureText(.timedOut(120), messages: []).contains("120 seconds"))
        XCTAssertTrue(accessoryOpenSCADFailureText(.failed(status: 1, summary: nil), messages: ["ERROR: x"]).contains("ERROR: x"))
    }

    // MARK: Rendering with a stand-in for OpenSCAD

    /// A script that takes OpenSCAD's arguments (`-o out.stl … design.scad`), logs to stderr and writes a tetrahedron,
    /// or fails like a parser error.
    private func fakeOpenSCAD(failing: Bool) throws -> (executable: URL, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AccessoryDesignerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("openscad")
        let body = failing
            ? "#!/bin/sh\necho \"ERROR: Parser error in file $PWD/design.scad, line 3: syntax error\" >&2\nexit 1\n"
            : """
            #!/bin/sh
            out=""
            while [ $# -gt 0 ]; do
              if [ "$1" = "-o" ]; then out="$2"; shift; fi
              shift
            done
            echo "WARNING: Ignoring unknown variable in file $PWD/design.scad, line 1" >&2
            cat > "$out" <<'STL'
            solid t
            facet normal 0 0 -1
            outer loop
            vertex 0 0 0
            vertex 0 10 0
            vertex 10 0 0
            endloop
            endfacet
            facet normal 0 -1 0
            outer loop
            vertex 0 0 0
            vertex 10 0 0
            vertex 0 0 10
            endloop
            endfacet
            facet normal -1 0 0
            outer loop
            vertex 0 0 0
            vertex 0 0 10
            vertex 0 10 0
            endloop
            endfacet
            facet normal 1 1 1
            outer loop
            vertex 10 0 0
            vertex 0 10 0
            vertex 0 0 10
            endloop
            endfacet
            endsolid t
            STL

            """
        try Data(body.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, folder)
    }

    private func accessoryTempFolders() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? [])
            .filter { $0.hasPrefix(accessoryTempFolderPrefix) }.sorted()
    }

    func testRenderRunsTheExecutableAndCleansUp() async throws {
        let fake = try fakeOpenSCAD(failing: false)
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let before = accessoryTempFolders()
        let outcome = try await renderAccessoryDesign(code: goodCode, executable: fake.executable, timeout: 30)
        guard case .rendered(let result) = outcome else { return XCTFail("Expected a render, got \(outcome)") }
        XCTAssertTrue(result.isAcceptable)
        XCTAssertEqual(result.facts.triangles, 4)
        XCTAssertEqual(result.facts.openSCADMessages, ["WARNING: Ignoring unknown variable in file design.scad, line 1"])
        XCTAssertEqual(accessoryTempFolders(), before, "The render's temporary folder is removed")
    }

    func testRenderFailureCarriesOpenSCADsMessage() async throws {
        let fake = try fakeOpenSCAD(failing: true)
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let outcome = try await renderAccessoryDesign(code: goodCode, executable: fake.executable, timeout: 30)
        guard case .failed(let text) = outcome else { return XCTFail("Expected a failure") }
        XCTAssertTrue(text.contains("exit code 1"))
        XCTAssertTrue(text.contains("ERROR: Parser error in file design.scad, line 3"))
        // Unsafe code never reaches the executable.
        guard case .failed(let refused) = try await renderAccessoryDesign(code: "import(\"a.stl\");", executable: fake.executable) else {
            return XCTFail("Expected a refusal")
        }
        XCTAssertTrue(refused.contains("import"))
    }

    func testTempFolderPrefixIsCleanedAtLaunch() {
        XCTAssertTrue(isPersonalisationTempFolderName("\(accessoryTempFolderPrefix)\(UUID().uuidString)"))
    }

    // MARK: Names and files

    func testLibraryName() {
        XCTAssertEqual(accessoryLibraryName(suggested: "phone stand", description: ""), "Phone stand (designed)")
        XCTAssertEqual(accessoryLibraryName(suggested: "A Cup Holder Insert (designed).", description: ""), "Cup Holder Insert (designed)")
        XCTAssertEqual(accessoryLibraryName(suggested: " ", description: "a stand that holds this phone at 60 degrees"), "Stand that holds this phone (designed)")
        XCTAssertEqual(accessoryLibraryName(suggested: "", description: ""), "Accessory (designed)")
        XCTAssertLessThanOrEqual(accessoryLibraryName(suggested: String(repeating: "x", count: 300), description: "").count, maximumModelNameLength)
    }

    func testTemplateFileKeepsTheCodeAndItsValues() {
        let text = accessoryTemplateFileText(code: goodCode, name: "Phone stand")
        XCTAssertTrue(text.hasPrefix("// Phone stand\n"))
        XCTAssertTrue(text.hasSuffix(goodCode + "\n"))
        XCTAssertEqual(scadTemplateParameters(text).parameters.map(\.name), ["width"])
    }

    func testFinishFieldsAreClipped() {
        let input: AnthropicJSON = ["name": .string(String(repeating: "n", count: 100)), "summary": "S", "print_orientation": "O",
                                    "notes": .array((0..<9).map { .string("note \($0)") } + [.string("  ")])]
        let fields = accessoryFinishFields(input)
        XCTAssertEqual(fields.name.count, 61)
        XCTAssertEqual(fields.notes.count, 6)
        XCTAssertEqual(fields.summary, "S")
    }

    func testRunSummary() {
        XCTAssertEqual(accessoryRunSummary(replies: 0, renders: 0, cost: AnthropicCostEstimate(usd: 0, complete: true), costMayBeHigher: false),
                       "0 Claude replies · 0 renders · nothing spent")
        XCTAssertEqual(accessoryRunSummary(replies: 1, renders: 1, cost: AnthropicCostEstimate(usd: Decimal(string: "0.42")!, complete: true), costMayBeHigher: true),
                       "1 Claude reply · 1 render · about $0.42 or a little more")
        XCTAssertTrue(accessoryErrorMayHaveBeenBilled(.stream(type: "overloaded_error", message: "")))
        XCTAssertFalse(accessoryErrorMayHaveBeenBilled(.http(status: 529, type: nil, message: "", retryAfter: nil)))
    }

    // MARK: The loop

    private func makeRun(_ stub: StubClaude, limits: AccessoryDesignLimits = AccessoryDesignLimits(), counter: RenderCounter = RenderCounter(),
                         outcome: @escaping @Sendable () throws -> AccessoryRenderOutcome) -> AccessoryDesignRun {
        AccessoryDesignRun(limits: limits, send: { request, _ in try stub.next(request) },
                           render: { _ in counter.bump(); return try outcome() })
    }

    private func settle(_ run: AccessoryDesignRun) async {
        for _ in 0..<2_000 where run.isWorking { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(run.isWorking, "The run didn't settle")
    }

    private func lastUserBlocks(_ request: AnthropicRequest) -> [AnthropicInputBlock] {
        guard let last = request.messages.last, last.role == .user else { return [] }
        return last.content
    }

    func testRenderThenFinish() async throws {
        let rendered = try render(try boxSTL())
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(goodCode)], text: "Here’s a first version.")),
                               .success(toolCall("t2", "finish_design", finishInput))])
        let counter = RenderCounter()
        let run = makeRun(stub, counter: counter) { .rendered(rendered) }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(run.phase, .finished)
        XCTAssertEqual(counter.count, 1)
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertEqual(run.finish?.render.id, rendered.id)
        XCTAssertEqual(run.finish?.name, "Phone stand")
        XCTAssertEqual(run.totalReplies, 2)
        XCTAssertEqual(run.cost.usd, 2 * Decimal(14) / 1_000) // (1,000 × $4 + 500 × $20) per million, twice
        // The second request answers the render with its facts and four captioned pictures.
        guard case .toolResult(let id, let content, let isError, _) = lastUserBlocks(stub.requests[1]).first else { return XCTFail("No tool result") }
        XCTAssertEqual(id, "t1")
        XCTAssertFalse(isError)
        XCTAssertEqual(content.count, 9)
        XCTAssertEqual(stub.requests[1].messages.map(\.role), [.user, .assistant, .user])
        if case .claude(let text) = run.transcript.first?.kind { XCTAssertEqual(text, "Here’s a first version.") } else { XCTFail("Claude's text wasn't shown") }
    }

    func testFinishBeforeAnAcceptableRenderIsRefused() async throws {
        let twoParts = try render(try STLMesh.validated(boxTriangles(.zero, SIMD3(10, 10, 10)) + boxTriangles(SIMD3(20, 0, 0), SIMD3(30, 10, 10))).stlCopyData())
        let stub = StubClaude([.success(toolCall("t1", "finish_design", finishInput)),
                               .success(toolCall("t2", "render_scad", ["code": .string(goodCode)])),
                               .success(toolCall("t3", "finish_design", finishInput))])
        let run = makeRun(stub) { .rendered(twoParts) }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        // Two refusals to finish (no render yet, then an unacceptable one); the third request then fails in the stub.
        XCTAssertNil(run.finish)
        XCTAssertEqual(stub.requests.count, 4)
        for index in [1, 3] {
            guard case .toolResult(_, _, let isError, _) = lastUserBlocks(stub.requests[index]).first else { return XCTFail("No tool result") }
            XCTAssertTrue(isError)
        }
        if case .stopped = run.phase {} else { XCTFail("Expected a stop") }
        XCTAssertTrue(run.canTryAgain)
    }

    func testRenderLimitIsEnforcedWithoutRendering() async throws {
        let rendered = try render(try boxSTL())
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(goodCode)])),
                               .success(toolCall("t2", "render_scad", ["code": .string(goodCode)])),
                               .success(toolCall("t3", "finish_design", finishInput))])
        let counter = RenderCounter()
        let run = makeRun(stub, limits: AccessoryDesignLimits(maxReplies: 10, maxRenders: 1), counter: counter) { .rendered(rendered) }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(counter.count, 1)
        guard case .toolResult(_, let content, let isError, _) = lastUserBlocks(stub.requests[2]).first,
              case .text(let text) = content.first else { return XCTFail("No tool result") }
        XCTAssertTrue(isError)
        XCTAssertTrue(text.contains("No renders left"))
        // The finish still uses the first (acceptable) render: the refused call didn't replace it.
        XCTAssertEqual(run.phase, .finished)
        XCTAssertEqual(run.finish?.render.id, rendered.id)
    }

    func testReplyLimitStopsTheRound() async throws {
        let rendered = try render(try boxSTL())
        let stub = StubClaude((1...5).map { .success(toolCall("t\($0)", "render_scad", ["code": .string(goodCode)])) })
        let run = makeRun(stub, limits: AccessoryDesignLimits(maxReplies: 2, maxRenders: 4)) { .rendered(rendered) }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(stub.requests.count, 2)
        guard case .stopped(let reason) = run.phase else { return XCTFail("Expected a stop") }
        XCTAssertTrue(reason.contains("all 2 replies"))
        // A note starts a new round, added to the unsent turn of tool results.
        XCTAssertTrue(run.canSendNote)
        run.sendNote("Make it taller")
        await settle(run)
        XCTAssertEqual(stub.requests.count, 4)
        let blocks = lastUserBlocks(stub.requests[2])
        guard case .toolResult = blocks.first, case .text(let note, _) = blocks.last else { return XCTFail("Expected results, then the note") }
        XCTAssertEqual(note, "The seller says: Make it taller")
    }

    func testNoToolCallIsNudgedOnceThenStops() async {
        let stub = StubClaude([.success(reply([textBlock("Thinking out loud")], stop: .endTurn)),
                               .success(reply([textBlock("Still no tool")], stop: .endTurn))])
        let run = makeRun(stub) { .failed("unused") }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(stub.requests.count, 2)
        guard case .text(let nudge, _) = lastUserBlocks(stub.requests[1]).last else { return XCTFail("No nudge") }
        XCTAssertEqual(nudge, accessoryNudgeText)
        guard case .stopped(let reason) = run.phase else { return XCTFail("Expected a stop") }
        XCTAssertTrue(reason.contains("without finishing"))
    }

    func testRefusalDiscardsTheReplyAndEndsTheConversation() async {
        let refusal = reply([textBlock("partial")], stop: .refusal, details: AnthropicStopDetails(explanation: "Not allowed."))
        let stub = StubClaude([.success(refusal)])
        let run = makeRun(stub) { .failed("unused") }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertTrue(run.refused)
        XCTAssertEqual(run.messages.count, 1, "The refused reply isn't kept")
        XCTAssertFalse(run.canTryAgain)
        XCTAssertFalse(run.canSendNote)
        XCTAssertFalse(run.transcript.contains { if case .claude = $0.kind { return true }; return false })
        guard case .stopped(let reason) = run.phase else { return XCTFail("Expected a stop") }
        XCTAssertTrue(reason.contains("Not allowed."))
    }

    func testQuestionWaitsForTheSeller() async throws {
        let stub = StubClaude([.success(toolCall("t1", "ask_seller", ["question": "How wide is the case?"])),
                               .success(toolCall("t2", "ask_seller", ["question": "Which side?"])),
                               .success(reply([textBlock("ok")], stop: .endTurn))])
        let run = makeRun(stub) { .failed("unused") }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(run.phase, .waitingForSeller)
        XCTAssertEqual(run.pendingQuestion, "How wide is the case?")
        XCTAssertFalse(run.canSendNote)
        run.answer("  10 mm ")
        await settle(run)
        guard case .toolResult(let id, let content, _, _) = lastUserBlocks(stub.requests[1]).first,
              case .text(let text) = content.first else { return XCTFail("No answer sent") }
        XCTAssertEqual(id, "t1")
        XCTAssertEqual(text, "The seller answered: 10 mm")
        XCTAssertEqual(run.phase, .waitingForSeller)
        run.answer(nil)
        await settle(run)
        guard case .toolResult(_, let skipped, _, _) = lastUserBlocks(stub.requests[2]).first,
              case .text(let skipText) = skipped.first else { return XCTFail("No skip sent") }
        XCTAssertTrue(skipText.contains("skipped"))
    }

    func testUnsafeCodeAndBadInputAreNeverRendered() async {
        let bad = toolCall("t2", "render_scad", [:], problem: "input.code is missing.")
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": "include <x.scad>\ncube(1);"])), .success(bad)])
        let counter = RenderCounter()
        let run = makeRun(stub, counter: counter) { .failed("unused") }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(counter.count, 0)
        XCTAssertEqual(run.rendersThisRound, 0)
        for index in [1, 2] {
            guard case .toolResult(_, _, let isError, _) = lastUserBlocks(stub.requests[index]).first else { return XCTFail("No tool result") }
            XCTAssertTrue(isError)
        }
        XCTAssertTrue(run.transcript.contains { if case .refusedCode = $0.kind { return true }; return false })
    }

    func testFailuresStopWithoutRetrying() async {
        let stub = StubClaude([.failure(AnthropicError.http(status: 529, type: "overloaded_error", message: "", retryAfter: nil)),
                               .success(reply([textBlock("cut")], stop: .maxTokens))])
        let run = makeRun(stub) { .failed("unused") }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertTrue(run.canTryAgain)
        XCTAssertFalse(run.costMayBeHigher)
        run.tryAgain()
        await settle(run)
        // A cut-off reply is set aside, not kept or acted on.
        XCTAssertEqual(stub.requests.count, 2)
        XCTAssertEqual(stub.requests[1].messages.count, 1)
        XCTAssertEqual(run.messages.count, 1)
        XCTAssertTrue(run.canTryAgain)
    }

    func testChangesAfterFinishAnswerTheFinishCall() async throws {
        let rendered = try render(try boxSTL())
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(goodCode)])),
                               .success(toolCall("t2", "finish_design", finishInput)),
                               .success(toolCall("t3", "finish_design", finishInput))])
        let run = makeRun(stub) { .rendered(rendered) }
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(run.phase, .finished)
        run.sendNote("   ")
        XCTAssertEqual(stub.requests.count, 2, "A note is required once Claude's turn is last")
        run.sendNote("Make the lip taller")
        XCTAssertNil(run.finish)
        await settle(run)
        let blocks = lastUserBlocks(stub.requests[2])
        guard case .toolResult(let id, _, let isError, _) = blocks.first, case .text(let note, _) = blocks.last else {
            return XCTFail("Expected the finish result, then the note")
        }
        XCTAssertEqual(id, "t2")
        XCTAssertFalse(isError)
        XCTAssertEqual(note, "The seller says: Make the lip taller")
        XCTAssertEqual(run.phase, .finished, "The earlier render is still the latest acceptable one")
    }
}
