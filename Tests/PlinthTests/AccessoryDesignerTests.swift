import XCTest
import simd
@testable import Plinth

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

/// Enough work to check what the analysis reports, far less than the app's (a 20,000-sample wall check and four
/// 512 px pictures per render), so the loop tests stay fast.
private let testBudget = AccessoryAnalysisBudget(wallThicknessSamples: 400, pictureSize: 48, rasterBudget: 400_000)

private func render(_ stl: Data, code: String = "width = 20; // [10:1:40] Width\ncube([width, 30, 10]);",
                    fitSizes: [AccessoryFitSize] = []) throws -> AccessoryRender {
    try XCTUnwrap(analyseAccessoryRender(stl: stl, code: code, openSCADMessages: [], fitSizes: fitSizes, budget: testBudget))
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
private let finishInput: AnthropicJSON = ["name": "Phone stand", "summary": "A stand.", "print_orientation": "Flat on its back.", "notes": ["Check the lip."], "photo_check": "Matches the photos."]

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
        XCTAssertFalse(accessorySystemPrompt.contains("prefer multiples of 0.45 mm (1.8, 2.25, 2.7)"), "1.8 mm isn't preferred for load")
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
        XCTAssertTrue(text.contains("The app can accept this render"))
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
        XCTAssertNil(try analyseAccessoryRender(stl: try boxSTL(), code: goodCode, openSCADMessages: [], budget: testBudget, isCancelled: { true }))
    }

    func testRenderToolResultCarriesFactsThenCaptionedPictures() throws {
        let result = try render(try boxSTL())
        guard case .toolResult(let id, let content, let isError, _) = accessoryRenderToolResult(.rendered(result), toolUseID: "t1", renderNumber: 1, maxRenders: 4) else {
            return XCTFail("Expected a tool result")
        }
        XCTAssertEqual(id, "t1")
        XCTAssertFalse(isError)
        XCTAssertEqual(content.count, 1 + 2 * 4 + 1)
        guard case .text(let last) = content.last else { return XCTFail("Expected the photo comparison line last") }
        XCTAssertEqual(last, accessoryPhotoComparisonText)
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
        WARNING: Ignoring unknown variable 'wdth' in file /private/var/folders/ab/T/Plinth-Accessory-1234/design.scad, line 4
        ECHO: "angle", 60
        ERROR: Parser error in file "/var/folders/ab/T/Plinth-Accessory-1234/design.scad", line 9: syntax error
        Rendering Polygon Mesh using CGAL...
        """
        let messages = accessoryOpenSCADMessages(log)
        // The echoed size is a fit size, reported on its own line rather than among the messages.
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(accessoryFitSizes(log), [AccessoryFitSize(name: "angle", millimetres: 60)])
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
            printf '%s\\n' "$@" > "\(folder.path)/args.txt"
            out=""
            while [ $# -gt 0 ]; do
              if [ "$1" = "-o" ]; then out="$2"; shift; fi
              shift
            done
            echo "WARNING: Ignoring unknown variable in file $PWD/design.scad, line 1" >&2
            echo 'ECHO: "slot_width", 9.9' >&2
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
        let outcome = try await renderAccessoryDesign(code: goodCode, executable: fake.executable, timeout: 30, budget: testBudget)
        guard case .rendered(let result) = outcome else { return XCTFail("Expected a render, got \(outcome)") }
        XCTAssertTrue(result.isAcceptable)
        XCTAssertEqual(result.facts.triangles, 4)
        XCTAssertEqual(result.facts.openSCADMessages, ["WARNING: Ignoring unknown variable in file design.scad, line 1"])
        XCTAssertEqual(result.facts.fitSizes, [AccessoryFitSize(name: "slot_width", millimetres: 9.9)])
        XCTAssertEqual(accessoryTempFolders(), before, "The render's temporary folder is removed")
    }

    func testRenderFailureCarriesOpenSCADsMessage() async throws {
        let fake = try fakeOpenSCAD(failing: true)
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let outcome = try await renderAccessoryDesign(code: goodCode, executable: fake.executable, timeout: 30, budget: testBudget)
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
                           render: { _, _ in counter.bump(); return try outcome() })
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
        XCTAssertEqual(content.count, 10)
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
    // MARK: Round 6 fixes

    func testRepliesThatCantJoinTheHistoryAreSetAside() async throws {
        // A reply cut off by the context window (or any reason but end_turn, tool_use, stop_sequence or pause_turn)
        // may hold a half-written tool call: it is set aside, never run and never added to the history.
        for stop: AnthropicStopReason? in [.other("model_context_window_exceeded"), .other("something_new"), nil, .maxTokens] {
            let cut = AnthropicToolUse(id: "t1", name: "render_scad", input: ["code": .string(goodCode)], rawInputJSON: "{}", inputProblem: nil)
            let message = reply([AnthropicOutputBlock(content: .toolUse(cut), raw: ["type": "tool_use", "id": "t1", "name": "render_scad", "input": ["code": .string(goodCode)]])], stop: stop)
            XCTAssertFalse(message.canJoinHistory)
            let stub = StubClaude([.success(message)])
            let counter = RenderCounter()
            let run = makeRun(stub, counter: counter) { .failed("unused") }
            run.start(firstTurn: .user(text: "brief"))
            await settle(run)
            XCTAssertEqual(counter.count, 0, "\(String(describing: stop))")
            XCTAssertEqual(run.messages.count, 1, "The cut-off reply isn't kept")
            XCTAssertTrue(run.canTryAgain)
            XCTAssertEqual(run.totalReplies, 1, "It is still counted and costed")
            guard case .stopped(let reason) = run.phase else { return XCTFail("Expected a stop") }
            XCTAssertEqual(reason, accessorySetAsideText(stop))
        }
        XCTAssertTrue(accessorySetAsideText(.other("model_context_window_exceeded")).contains("Start Over"))
        XCTAssertTrue(accessorySetAsideText(.maxTokens).contains("Send Again"))
        XCTAssertTrue(accessorySetAsideText(.other("x")).contains("(x)"))
    }

    func testOverhangsAreMeasuredAndLocated() throws {
        // A 10 mm cube on the bed and a 10 × 10 × 5 mm block floating at Z = 5: its 100 mm² underside overhangs.
        let mesh = try STLMesh.validated(boxTriangles(.zero, SIMD3(10, 10, 10)) + boxTriangles(SIMD3(20, 0, 5), SIMD3(30, 10, 10)))
        let result = try render(try mesh.stlCopyData())
        XCTAssertEqual(result.facts.overhang, overhangShare(mesh), "Plinth's shared overhang rule")
        XCTAssertEqual(result.facts.overhang.overhangAreaMM2, 100, accuracy: 0.001)
        XCTAssertEqual(result.facts.overhang.fraction, 0.1, accuracy: 0.0001)
        XCTAssertTrue(result.facts.hasNotableOverhangs)
        let location = try XCTUnwrap(result.facts.overhangLocation)
        XCTAssertEqual(location.lowestZ, 5)
        XCTAssertEqual(location.highestZ, 5)
        XCTAssertEqual(location.mainBands, [AccessoryOverhangBand(bottomZ: 5, areaMM2: 100)])
        let text = accessoryRenderFactsText(result.facts, renderNumber: 1, maxRenders: 4)
        XCTAssertTrue(text.contains("Overhangs: 10% of the surface (100 mm²) faces down more steeply than 45° from vertical, at Z = 5.0 mm; most at Z 5–6 mm (100 mm²)."), text)
        XCTAssertTrue(text.contains("These need supports"))
        XCTAssertTrue(accessoryStudioCheckLines(result.facts).contains { $0.hasPrefix("Overhangs: 10% of the surface") && $0.contains("at 5 mm up") })
        // A box on the bed has none: its underside is on the bed.
        let box = try render(try boxSTL())
        XCTAssertNil(box.facts.overhangLocation)
        XCTAssertFalse(box.facts.hasNotableOverhangs)
        XCTAssertTrue(accessoryRenderFactsText(box.facts, renderNumber: 1, maxRenders: 4).contains("Overhangs: no downward faces steeper than 45° from vertical."))
        XCTAssertTrue(accessoryStudioCheckLines(box.facts).contains("Overhangs: none steeper than 45° from vertical"))
        XCTAssertEqual(accessoryOverhangLocation(mesh), accessoryOverhangLocation(mesh))
    }

    func testOverhangBandsAreLargestFirstAndCapped() throws {
        // Floating blocks at Z = 2, 4, 6 and 8 with undersides of 4, 16, 16 and 1 mm².
        let blocks = boxTriangles(.zero, SIMD3(40, 40, 1))
            + boxTriangles(SIMD3(0, 0, 2), SIMD3(2, 2, 3)) + boxTriangles(SIMD3(5, 0, 4), SIMD3(9, 4, 5))
            + boxTriangles(SIMD3(10, 0, 6), SIMD3(14, 4, 7)) + boxTriangles(SIMD3(20, 0, 8), SIMD3(21, 1, 9))
        let location = try XCTUnwrap(accessoryOverhangLocation(try STLMesh.validated(blocks)))
        XCTAssertEqual(location.lowestZ, 2)
        XCTAssertEqual(location.highestZ, 8)
        XCTAssertEqual(location.mainBands.map(\.bottomZ), [4, 6, 2], "Largest first, ties by height, at most 3")
    }

    func testFitSizesAreReadFromEchoes() {
        let log = """
        ECHO: "slot_width", 9.9
        ECHO: hole_d = 3.4
        ECHO: "slot_width", 12
        ECHO: "note", "text"
        ECHO: "pair", [1, 2]
        ECHO: "tiny", 1e-1
        WARNING: something
        ECHO: "bad name/../x", 4
        """
        XCTAssertEqual(accessoryFitSizes(log), [AccessoryFitSize(name: "slot_width", millimetres: 9.9),
                                                AccessoryFitSize(name: "hole_d", millimetres: 3.4),
                                                AccessoryFitSize(name: "tiny", millimetres: 0.1)])
        let many = (0..<40).map { "ECHO: \"s\($0)\", \($0)" }.joined(separator: "\n")
        XCTAssertEqual(accessoryFitSizes(many).count, accessoryMaximumFitSizes)
        XCTAssertEqual(accessoryOpenSCADMessages(log).filter { $0.hasPrefix("ECHO") }.count, 3, "Only echoes that aren't fit sizes stay messages")
        XCTAssertEqual(accessoryFitSizeText(AccessoryFitSize(name: "slot_width", millimetres: 9.9)), "slot_width 9.9 mm")
    }

    func testFitSizesAreFedBackAndShownBesideTheMeasurements() throws {
        let fits = [AccessoryFitSize(name: "slot_width", millimetres: 9.9)]
        let result = try render(try boxSTL(), fitSizes: fits)
        XCTAssertEqual(result.facts.fitSizes, fits)
        XCTAssertTrue(accessoryRenderFactsText(result.facts, renderNumber: 1, maxRenders: 4).contains("Fit sizes echoed by the code: slot_width 9.9 mm."))
        let none = try render(try boxSTL())
        XCTAssertTrue(accessoryRenderFactsText(none.facts, renderNumber: 1, maxRenders: 4).contains("Fit sizes echoed by the code: none. echo(\"name\", value)"))
        XCTAssertEqual(accessoryFitSizeLines(fits), ["slot_width 9.9 mm"])
        XCTAssertTrue(accessoryFitSizeLines([])[0].contains("didn’t report"))
        let rows = [AccessoryMeasurement(label: "Phone thickness", millimetres: "9.5", method: .calipers), AccessoryMeasurement(),
                    AccessoryMeasurement(label: "Width", millimetres: "75", method: .estimate)]
        XCTAssertEqual(accessoryTypedMeasurementLines(rows), ["Phone thickness: 9.5 mm (calipers)", "Width: 75 mm (estimate)"])
    }

    func testPromptCarriesTheRound6PrintingRules() {
        for phrase in ["2.25 or 2.7 mm", "1.8 mm only where it carries none", "never under 1.0 mm", "add 0.2–0.4 mm",
                       "M3 3.4 mm, M4 4.5 mm", "teardrop", "measure it with calipers", "0.9 mm", "at least 5 mm high",
                       "0.8–1 mm deep", "side walls rather than the bottom face", "at least 5 times as long", "taper",
                       "PETG", "radius 3 mm or more", "keep the height and the amount of material low", "ask about the load",
                       "echo(\"slot_width\", slot_width);", "Never call a design strong", "dxf_"] {
            XCTAssertTrue(accessorySystemPrompt.contains(phrase), phrase)
        }
    }

    func testPromptUsesSlantsPublishedSettings() {
        for phrase in ["0.2 mm layers (0.3 mm first layer)", "0.4 mm nozzle", "1 mm walls (about 2 lines)", "25% grid-like infill",
                       "overhangs up to 50° from vertical", "no brims", "textured bed", "220 mm cube build volume",
                       "re-orienting only an obviously wrong upload", "print exactly as it sits in your file",
                       "Not published: the line width, the tolerances Slant holds and which slicer it uses",
                       "mostly sparse infill", "walls or ribs rather than solid blocks",
                       "Never leave closed internal voids", "about $0.39 each", "about 0.25 mm wide that open through the bottom face",
                       "Slant bills each separate body after the first", "at least about 20 mm on a side",
                       "Slant allows 50°; 45° leaves a margin"] {
            XCTAssertTrue(accessorySystemPrompt.contains(phrase), phrase)
        }
        for gone in ["unknown slicer settings", "slicer settings aren't", "slicer settings are unknown", "2 perimeters of 0.45 mm",
                     "multiples of the 0.45 mm line", "low infill"] {
            XCTAssertFalse(accessorySystemPrompt.contains(gone), gone)
        }
    }

    func testRenderOutcomeForTooMuchMemory() {
        XCTAssertTrue(accessoryOpenSCADFailureText(.tooMuchMemory, messages: []).contains("too much memory"))
    }
}

// MARK: - Round 9: the fit-test piece and the photo comparison

private let fitTestCode = """
/* [Fit test] */
fit_test = false; // Print only a small fit-test piece
clearance = 0.25; // [0:0.05:1] Fit clearance per side (mm)
/* [Size] */
width = 20; // [10:1:40] Width
module body() { cube([width, 30, 10]); }
if (fit_test) intersection() { body(); cube([5, 5, 5]); } else body();
"""

/// Facts of an axis-aligned box from `low` to `high`, with the given fit sizes.
private func boxFacts(_ low: SIMD3<Float> = .zero, _ high: SIMD3<Float>, fitSizes: [AccessoryFitSize] = [],
                      code: String = fitTestCode) throws -> AccessoryRenderFacts {
    try render(try boxSTL(low, high), code: code, fitSizes: fitSizes).facts
}

/// A 40 × 30 × 20 mm render of `code` with an optional fit-test piece attached, as the run attaches it.
private func renderWithPiece(code: String = fitTestCode, fitSizes: [AccessoryFitSize] = [],
                             piece: AccessoryRenderOutcome?) throws -> AccessoryRender {
    var result = try render(try boxSTL(.zero, SIMD3(40, 30, 20)), code: code, fitSizes: fitSizes)
    if let piece { result.fitTest = accessoryFitTestOutcome(piece, part: result.facts) }
    return result
}

private func toolResultTexts(_ block: AnthropicInputBlock) -> (texts: [String], images: Int) {
    guard case .toolResult(_, let content, _, _) = block else { return ([], 0) }
    var texts: [String] = []
    var images = 0
    for item in content {
        switch item {
        case .text(let text): texts.append(text)
        case .image: images += 1
        }
    }
    return (texts, images)
}

/// Stands in for OpenSCAD in the loop: the part for `.design`, the piece for `.fitTest`, counting each.
private final class VariantRenderer: @unchecked Sendable {
    private let lock = NSLock()
    private var designs = 0
    private var pieces = 0
    private var codes: [(AccessoryRenderVariant, String)] = []
    /// The code each render was given, in order.
    var renderedCode: [(variant: AccessoryRenderVariant, code: String)] { lock.withLock { codes.map { (variant: $0.0, code: $0.1) } } }
    var designCount: Int { lock.withLock { designs } }
    var pieceCount: Int { lock.withLock { pieces } }
    let part: AccessoryRenderOutcome
    let piece: AccessoryRenderOutcome
    let pieceWaitsForStop: Bool
    init(part: AccessoryRenderOutcome, piece: AccessoryRenderOutcome, pieceWaitsForStop: Bool = false) {
        self.part = part
        self.piece = piece
        self.pieceWaitsForStop = pieceWaitsForStop
    }
    func render(_ variant: AccessoryRenderVariant, code: String) async throws -> AccessoryRenderOutcome {
        lock.withLock { codes.append((variant, code)) }
        switch variant {
        case .design:
            lock.withLock { designs += 1 }
            return part
        case .fitTest:
            lock.withLock { pieces += 1 }
            if pieceWaitsForStop { try await Task.sleep(nanoseconds: 20_000_000_000) }
            return piece
        }
    }
}

extension AccessoryDesignerTests {
    func testFitTestIsDetectedOnlyAsATopLevelCustomizerValue() {
        XCTAssertEqual(accessoryFitTestDeclaration(fitTestCode), .ready)
        XCTAssertEqual(accessoryFitTestAssignments(fitTestCode), [ScadAssignment(name: "fit_test", literal: "true")])
        let cases: [(String, AccessoryFitTestDeclaration)] = [
            (goodCode, .none),
            ("module a(fit_test = false) { cube(1); }\na();", .notCustomizerValue),
            ("module a() { fit_test = false; cube(1); }\na();", .notCustomizerValue),
            ("width = 2;\nmodule a() { cube(width); }\nfit_test = false;\na();", .notCustomizerValue),
            ("/* [Hidden] */\nfit_test = false;\ncube(1);", .notCustomizerValue),
            ("fit_test = 0; // Fit test\ncube(1);", .notBoolean),
            ("fit_test = \"no\";\ncube(1);", .notBoolean),
            ("fit_test = true; // Print only a small fit-test piece\ncube(1);", .defaultTrue),
            ("my_fit_test = false;\ncube(1);", .none),
            // A second top-level assignment wins in OpenSCAD, so the file might make only the piece.
            ("fit_test = false; // Fit test\nmodule a() { cube(1); }\nfit_test = true;\na();", .notCustomizerValue),
            ("fit_test = false; // Fit test\n/* [Hidden] */\nfit_test = true;\ncube(1);", .notCustomizerValue),
            ("fit_test = false; // Fit test\nfit_test = false;\ncube(1);", .notCustomizerValue),
            // Mentions in comments and strings aren't code.
            ("// fit_test = true\ncube(1);", .none),
            ("/* fit_test = true; */\ncube(1);", .none),
            ("echo(\"fit_test = true\");\ncube(1);", .none),
        ]
        for (code, expected) in cases {
            XCTAssertEqual(accessoryFitTestDeclaration(code), expected, code)
            XCTAssertEqual(accessoryFitTestAssignments(code), [], code)
        }
        // A mention in a comment or a string beside the real declaration doesn't count as a second assignment, and an
        // assignment inside a module is local to it.
        for code in [fitTestCode + "\n// fit_test = true;", fitTestCode + "\necho(\"fit_test = true;\");",
                     fitTestCode + "\nmodule b() { fit_test = true; cube(1); }"] {
            XCTAssertEqual(accessoryFitTestDeclaration(code), .ready, code)
        }
        XCTAssertEqual(accessoryFitTestUses("fit_test = false;\nmodule a() {}\nfit_test = true;").topLevelAssignments, 2)
    }

    func testFitTestTrueByDefaultBlocksFinishing() throws {
        let result = try render(try boxSTL(), code: "fit_test = true; // Print only a small fit-test piece\ncube([20, 30, 10]);")
        XCTAssertEqual(result.facts.fitTestDeclaration, .defaultTrue)
        XCTAssertFalse(result.isAcceptable)
        XCTAssertTrue(result.problems.joined().contains("set fit_test = false"))
        XCTAssertTrue(try XCTUnwrap(accessoryFitTestFactsText(result)).contains("already the piece"))
    }

    func testFitTestRenderPassesTheDefineOnlyForADeclaredValue() async throws {
        let fake = try fakeOpenSCAD(failing: false)
        defer { try? FileManager.default.removeItem(at: fake.folder) }
        let argsFile = fake.folder.appendingPathComponent("args.txt")
        func arguments() throws -> [String] {
            try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        }
        let before = accessoryTempFolders()

        guard case .rendered(let piece) = try await renderAccessoryDesign(code: fitTestCode, variant: .fitTest, executable: fake.executable,
                                                                           timeout: 30, budget: testBudget) else {
            return XCTFail("Expected the piece")
        }
        let pieceArguments = try arguments()
        let define = try XCTUnwrap(pieceArguments.firstIndex(of: "-D"))
        XCTAssertEqual(pieceArguments[define + 1], "fit_test=true")
        XCTAssertEqual(pieceArguments.filter { $0 == "-D" }.count, 1)
        XCTAssertEqual(piece.images.count, 1, "One three-quarter picture of the piece")
        XCTAssertNil(piece.facts.wallThickness, "The piece's walls aren't measured")

        try FileManager.default.removeItem(at: argsFile)
        guard case .rendered(let part) = try await renderAccessoryDesign(code: fitTestCode, executable: fake.executable,
                                                                          timeout: 30, budget: testBudget) else {
            return XCTFail("Expected the part")
        }
        XCTAssertFalse(try arguments().contains("-D"), "The part renders as written")
        XCTAssertEqual(part.images.count, 4)

        // Code without a top-level fit_test never runs as a fit test.
        try FileManager.default.removeItem(at: argsFile)
        for code in [goodCode, "module a() { fit_test = false; cube(1); }\na();", "fit_test = true;\ncube(1);"] {
            guard case .failed = try await renderAccessoryDesign(code: code, variant: .fitTest, executable: fake.executable, timeout: 30, budget: testBudget) else {
                return XCTFail("Expected a refusal for \(code)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: argsFile.path), "OpenSCAD wasn't run")
        // The safety check still applies to the fit-test render.
        guard case .failed(let refused) = try await renderAccessoryDesign(code: fitTestCode + "\nimport(\"a.stl\");", variant: .fitTest,
                                                                           executable: fake.executable) else {
            return XCTFail("Expected a refusal")
        }
        XCTAssertTrue(refused.contains("import"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: argsFile.path), "OpenSCAD wasn't run")
        XCTAssertEqual(accessoryTempFolders(), before, "The temporary folders are removed")
    }

    func testFitTestCheckCoversEveryBranch() throws {
        let slot = AccessoryFitSize(name: "slot_width", millimetres: 9.9)
        let hole = AccessoryFitSize(name: "hole_d", millimetres: 3.4)
        // A 40 × 30 × 20 mm part (24,000 mm³).
        let part = try boxFacts(.zero, SIMD3(40, 30, 20), fitSizes: [slot, hole])

        // A small piece with the same fit sizes (within 0.001 mm, plus an extra one, which is ignored) passes.
        let good = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(10, 10, 5), fitSizes: [slot, AccessoryFitSize(name: "extra", millimetres: 1),
                                                                                                    AccessoryFitSize(name: "hole_d", millimetres: 3.4005)]), part: part)
        XCTAssertTrue(good.passes, "\(good.problems)")
        XCTAssertEqual(try XCTUnwrap(good.volumeShare), 500.0 / 24_000, accuracy: 1e-6)
        XCTAssertFalse(good.isLargerThanNeeded)
        XCTAssertEqual(good.partFitSizeCount, 2)

        // Over a quarter of the part: passes, flagged.
        let large = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(40, 30, 6), fitSizes: [slot, hole]), part: part)
        XCTAssertTrue(large.passes)
        XCTAssertTrue(large.isLargerThanNeeded)

        // Sixty percent of the part fails, and so does exactly half.
        let sixtyPercent = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(40, 30, 12), fitSizes: [slot, hole]), part: part)
        XCTAssertFalse(sixtyPercent.passes)
        XCTAssertFalse(sixtyPercent.isSmallerThanPart)
        XCTAssertTrue(sixtyPercent.problems.joined().contains("It uses 60% of the part’s volume"))
        let exactlyHalf = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(40, 30, 10), fitSizes: [slot, hole]), part: part)
        XCTAssertEqual(exactlyHalf.volumeShare, 0.5)
        XCTAssertFalse(exactlyHalf.passes)
        XCTAssertTrue(exactlyHalf.problems.joined().contains("It uses 50.0% of the part’s volume; it must use under 50%"), "\(exactlyHalf.problems)")
        XCTAssertFalse(exactlyHalf.equalsPart)

        // The same model as the part, or one longer than it, fails.
        let same = accessoryFitTestCheck(piece: part, part: part)
        XCTAssertTrue(same.equalsPart)
        XCTAssertEqual(same.problems.first, "It is the same model as the part.")
        let longer = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(50, 5, 5), fitSizes: [slot, hole]), part: part)
        XCTAssertFalse(longer.withinPartSize)
        XCTAssertFalse(longer.passes)
        // A piece turned 90° is still within the part's size.
        let turned = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(5, 38, 5), fitSizes: [slot, hole]), part: part)
        XCTAssertTrue(turned.withinPartSize)

        // Off the bed, two parts, too big for the build volume.
        let raised = accessoryFitTestCheck(piece: try boxFacts(SIMD3(0, 0, 2), SIMD3(10, 10, 7), fitSizes: [slot, hole]), part: part)
        XCTAssertFalse(raised.sitsOnBed)
        XCTAssertFalse(raised.passes)
        let twoParts = try render(try STLMesh.validated(boxTriangles(.zero, SIMD3(5, 5, 5)) + boxTriangles(SIMD3(10, 0, 0), SIMD3(15, 5, 5))).stlCopyData(),
                                  code: fitTestCode, fitSizes: [slot, hole]).facts
        let split = accessoryFitTestCheck(piece: twoParts, part: part)
        XCTAssertFalse(split.isOneClosedSolid)
        XCTAssertNil(split.volumeShare)
        XCTAssertEqual(split.problems.first, "It isn’t one closed solid.")
        let bigPart = try boxFacts(.zero, SIMD3(300, 30, 20), fitSizes: [slot])
        let tooBig = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(230, 5, 5), fitSizes: [slot]), part: bigPart)
        XCTAssertFalse(tooBig.fitsBuildVolume)
        XCTAssertFalse(tooBig.passes)

        // Fit sizes that differ by more than 0.001 mm, or are missing.
        let differs = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(10, 10, 5), fitSizes: [AccessoryFitSize(name: "slot_width", millimetres: 9.902)]), part: part)
        XCTAssertFalse(differs.passes)
        XCTAssertEqual(differs.fitSizeMismatches, [AccessoryFitSizeMismatch(name: "slot_width", partMM: 9.9, pieceMM: 9.902),
                                                   AccessoryFitSizeMismatch(name: "hole_d", partMM: 3.4, pieceMM: nil)])
        XCTAssertEqual(accessoryFitSizeMismatchText(differs.fitSizeMismatches[1]), "hole_d: 3.4 mm in the part, not echoed by the piece")
        XCTAssertEqual(accessoryFitSizeMismatchText(AccessoryFitSizeMismatch(name: "slot_width", partMM: 9.9, pieceMM: 10.1)),
                       "slot_width: 9.9 mm in the part, 10.1 mm in the piece")

        // A part with no fit sizes has nothing to compare.
        let noFits = accessoryFitTestCheck(piece: try boxFacts(.zero, SIMD3(10, 10, 5)), part: try boxFacts(.zero, SIMD3(40, 30, 20)))
        XCTAssertTrue(noFits.passes)
        XCTAssertEqual(noFits.partFitSizeCount, 0)
    }

    func testToolResultCarriesTheFitTestBlockOnlyWhenThereIsOne() throws {
        let slot = AccessoryFitSize(name: "slot_width", millimetres: 9.9)
        let pieceRender = try render(try boxSTL(.zero, SIMD3(10, 10, 5)), code: fitTestCode, fitSizes: [slot])

        // A passing piece: the block after the facts, and its picture after the part's four.
        let passing = try renderWithPiece(fitSizes: [slot], piece: .rendered(pieceRender))
        XCTAssertNotNil(passing.passingFitTest)
        let result = toolResultTexts(accessoryRenderToolResult(.rendered(passing), toolUseID: "t1", renderNumber: 1, maxRenders: 4))
        XCTAssertEqual(result.images, 5)
        XCTAssertTrue(result.texts[1].hasPrefix("Fit-test piece: the app rendered this file again with fit_test = true"), result.texts[1])
        XCTAssertTrue(result.texts[1].contains("volume: 2% of the part’s"), result.texts[1])
        XCTAssertTrue(result.texts[1].contains("the piece’s code reports the same fit sizes as the part’s (1 of 1)"))
        XCTAssertTrue(result.texts[1].contains("not the shape"))
        XCTAssertTrue(result.texts[1].contains("Overhangs: no downward faces"))
        XCTAssertTrue(result.texts[1].contains("5.0 mm high, 25% of the part’s 20.0 mm"), result.texts[1])
        XCTAssertFalse(result.texts[1].contains("Clearance:"), "The code has a clearance value")
        XCTAssertTrue(result.texts[1].contains("passes the app’s checks"))
        XCTAssertTrue(result.texts.contains { $0.hasPrefix("Fit-test piece: Three-quarter view") })
        XCTAssertEqual(result.texts.last, accessoryPhotoComparisonText)

        // A failing piece: the block says why, and no picture of it is sent.
        let failing = try renderWithPiece(fitSizes: [slot], piece: .rendered(try render(try boxSTL(.zero, SIMD3(10, 10, 5)), code: fitTestCode)))
        XCTAssertNil(failing.passingFitTest)
        let failed = toolResultTexts(accessoryRenderToolResult(.rendered(failing), toolUseID: "t1", renderNumber: 1, maxRenders: 4))
        XCTAssertEqual(failed.images, 4)
        XCTAssertTrue(failed.texts[1].contains("Fit sizes that differ or are missing: slot_width: 9.9 mm in the part, not echoed by the piece."), failed.texts[1])
        XCTAssertTrue(failed.texts[1].contains("doesn’t pass"))

        // OpenSCAD couldn't make the piece.
        let broken = try renderWithPiece(piece: .failed("OpenSCAD didn’t finish within 120 seconds, so Plinth stopped it."))
        XCTAssertTrue(try XCTUnwrap(accessoryFitTestFactsText(broken)).contains("and it failed. OpenSCAD didn’t finish"))
        // Declared, but not made (the run makes it only after an acceptable render).
        XCTAssertTrue(try XCTUnwrap(accessoryFitTestFactsText(try renderWithPiece(piece: nil))).contains("not made"))

        // No fit_test and no fit sizes: no block at all.
        let plain = try render(try boxSTL())
        XCTAssertNil(accessoryFitTestFactsText(plain))
        let plainResult = toolResultTexts(accessoryRenderToolResult(.rendered(plain), toolUseID: "t1", renderNumber: 1, maxRenders: 4))
        XCTAssertFalse(plainResult.texts.contains { $0.hasPrefix("Fit-test piece") })
        XCTAssertEqual(plainResult.texts.count, 1 + 4 + 1)
        // Fit sizes but no fit_test: one line asking for it.
        let hint = try XCTUnwrap(accessoryFitTestFactsText(try render(try boxSTL(), fitSizes: [slot])))
        XCTAssertTrue(hint.contains("doesn’t declare fit_test"))
        XCTAssertTrue(hint.contains("fit_test = false; // Print only a small fit-test piece"))
    }

    func testFinishDesignRequiresAPhotoCheckAndClipsIt() throws {
        let finish = try XCTUnwrap(accessoryTools.first { $0.name == "finish_design" })
        XCTAssertTrue(finish.strict)
        XCTAssertEqual(finish.inputSchema["additionalProperties"], .bool(false))
        XCTAssertEqual(finish.inputSchema["required"]?.arrayValue?.compactMap(\.stringValue), ["name", "summary", "print_orientation", "notes", "photo_check"])
        XCTAssertEqual(finish.inputSchema["properties"]?["photo_check"]?["type"], .string("string"))
        XCTAssertNil(anthropicSchemaProblem(finishInput, schema: finish.inputSchema))
        let missing: AnthropicJSON = ["name": "Phone stand", "summary": "A stand.", "print_orientation": "Flat.", "notes": []]
        XCTAssertNotNil(anthropicSchemaProblem(missing, schema: finish.inputSchema))

        XCTAssertEqual(accessoryFinishFields(finishInput).photoCheck, "Matches the photos.")
        let long: AnthropicJSON = ["name": "Phone stand", "summary": "A stand.", "print_orientation": "Flat.", "notes": [],
                                   "photo_check": .string(String(repeating: "p", count: 900))]
        XCTAssertEqual(accessoryFinishFields(long).photoCheck.count, accessoryPhotoCheckMaximumLength + 1)
        XCTAssertEqual(accessoryFinishFields(missing).photoCheck, "")

        for phrase in ["compare the pictures with the seller's photos", "In photo_check", "never say it fits exactly or",
                       "fit_test = false; // Print only a small fit-test piece", "intersection()", "change the clearance, not the measurement",
                       "doesn't count as one of your renders", "Never promise a fit"] {
            XCTAssertTrue(accessorySystemPrompt.contains(phrase), phrase)
        }
    }

    func testResultScreenTextAndTheFitTestName() throws {
        XCTAssertEqual(accessoryFitTestLibraryName(libraryName: "Phone stand (designed)"), "Phone stand (fit test)")
        XCTAssertEqual(accessoryFitTestLibraryName(libraryName: "  Hook  "), "Hook (fit test)")
        XCTAssertEqual(accessoryFitTestLibraryName(libraryName: "Hook (fit test)"), "Hook (fit test)")
        XCTAssertEqual(accessoryFitTestLibraryName(libraryName: ""), "Accessory (fit test)")
        let long = accessoryFitTestLibraryName(libraryName: String(repeating: "x", count: 300))
        XCTAssertLessThanOrEqual(long.count, maximumModelNameLength)
        XCTAssertTrue(long.hasSuffix(" (fit test)"))

        let slot = AccessoryFitSize(name: "slot_width", millimetres: 9.9)
        let passing = try renderWithPiece(fitSizes: [slot], piece: .rendered(try render(try boxSTL(.zero, SIMD3(10, 10, 5)), code: fitTestCode, fitSizes: [slot])))
        XCTAssertNil(accessoryNoFitTestLines(passing))
        let piece = try XCTUnwrap(passing.passingFitTest)
        let lines = accessoryFitTestCheckLines(piece)
        XCTAssertEqual(lines.first, "Size: 10.0 × 10.0 × 5.0 mm (W × D × H), 5.0 mm high, 25% of the part’s 20.0 mm")
        XCTAssertTrue(lines.contains("Its code reports the same fit sizes as the part (1 of 1); check the Fit Test preview shows the slot or hole."), "\(lines)")
        XCTAssertTrue(lines.contains("Volume: 2% of the part’s"))
        XCTAssertTrue(accessoryFitTestChecksCaption.contains("not that its shape matches"))

        let failingPiece = try renderWithPiece(fitSizes: [slot], piece: .rendered(try render(try boxSTL(.zero, SIMD3(10, 10, 5)), code: fitTestCode)))
        let noPiece = try XCTUnwrap(accessoryNoFitTestLines(failingPiece))
        XCTAssertEqual(noPiece.first, "No fit-test piece: print the whole part to check the fit.")
        XCTAssertTrue(noPiece[1].contains("didn’t pass"))
        if case .made(let failed)? = failingPiece.fitTest {
            XCTAssertTrue(accessoryFitTestCheckLines(failed).contains("slot_width: 9.9 mm in the part, not echoed by the piece"))
        } else { XCTFail("Expected a made piece") }
        XCTAssertEqual(accessoryNoFitTestLines(try render(try boxSTL(), fitSizes: [slot])),
                       ["No fit-test piece: print the whole part to check the fit, or ask Claude in a note to add a fit-test piece."])
        XCTAssertNil(accessoryNoFitTestLines(try render(try boxSTL())), "Nothing to fit, nothing to say")

        // None of it promises a fit.
        for text in [accessoryFitTestPrintAdvice(code: fitTestCode), accessoryFitTestPrintAdvice(code: goodCode), accessoryPhotoCheckCaption,
                     accessoryFitTestChecksCaption, accessoryFitTestSavedText, accessoryNoteImageLimitText] + lines {
            for word in ["guarantee", "perfect", "will fit", "safe", "strong"] { XCTAssertFalse(text.lowercased().contains(word), "\(text): \(word)") }
        }
    }

    func testCostForecastCountsTheFitTestPiece() {
        let picture = accessoryImageTokens(pixelWidth: accessoryRenderPixelSize, pixelHeight: accessoryRenderPixelSize)
        XCTAssertGreaterThanOrEqual(accessoryForecastRenderTokens, 5 * picture + 700)
        let forecast = accessoryCostForecast(photoSizes: [(1568, 1176)], textCharacters: 600)
        XCTAssertLessThan(forecast.firstReply.usd, forecast.typical.usd)
        XCTAssertLessThan(forecast.typical.usd, forecast.maximum.usd)
        XCTAssertLessThan(forecast.maximum.usd, 10, "Still a few dollars at most")
    }

    func testCustomizerCommentsOtherThanANumberRangeReadAsBefore() throws {
        // Regressions: these must parse exactly as before round 9, so Import Orders' Etsy text still fits them.
        let strings = scadTemplateParameters("""
            line2 = ""; // [optional] Second line
            name = ""; // [max 20] Name
            nick = ""; // [e.g. Bob] Nickname
            hole = 5; // [5, 10] Hole
            pick = "c"; // ["a]b", "c"]
            size = 2; // [1:Small, 2:Large]
            cube(1);
            """).parameters
        XCTAssertEqual(strings.map(\.name), ["line2", "name", "nick", "hole", "pick", "size"])
        for (index, description) in ["[optional] Second line", "[max 20] Name", "[e.g. Bob] Nickname", "[5, 10] Hole"].enumerated() {
            XCTAssertEqual(strings[index].description, description)
            XCTAssertEqual(strings[index].choices, [], description)
            XCTAssertNil(strings[index].range, description)
        }
        // Free text stays free text for any buyer's personalisation.
        XCTAssertNil(scadValueProblem("Happy birthday, Emma", for: strings[0]))
        XCTAssertNil(scadValueProblem("Bob", for: strings[2]))
        XCTAssertNil(scadValueProblem("7", for: strings[3]))
        // A whole-comment drop-down is read as one, a quoted "]" included, and a whole-comment number drop-down too.
        XCTAssertEqual(strings[4].choices.map(\.value), ["a]b", "c"])
        XCTAssertNil(strings[4].description)
        XCTAssertEqual(strings[5].choices.map(\.label), ["Small", "Large"])
        // The one new form: a number range, then a description.
        let clearance = try XCTUnwrap(scadTemplateParameters("gap = 0.25; // [0:0.05:1] Fit clearance per side (mm)\ncube(1);").parameters.first)
        XCTAssertEqual(clearance.range, 0...1)
        XCTAssertEqual(clearance.description, "Fit clearance per side (mm)")
    }

    func testTemplateKeepsFitTestAsACheckbox() throws {
        let text = accessoryTemplateFileText(code: fitTestCode, name: "Phone stand")
        XCTAssertTrue(text.contains("// Fit test: turn on fit_test (“Print only a small fit-test piece”) to make only the small fit-test piece, and print it first.\n"), text)
        XCTAssertTrue(text.contains("// If the piece is tight or loose, change clearance (“Fit clearance per side (mm)”) in Personalise from Template.\n"), text)
        let parameters = scadTemplateParameters(text).parameters
        XCTAssertEqual(parameters.map(\.name), ["fit_test", "clearance", "width"])
        XCTAssertEqual(parameters[1].range, 0...1)
        XCTAssertEqual(parameters[1].description, "Fit clearance per side (mm)", "A constraint, then a description, on one line")
        // Only a number with a numeric range is split; everything else reads as before (the whole comment is the
        // description, or a whole-comment constraint).
        let other = scadTemplateParameters("a = 2; // [not a range] Size\nb = \"x\"; // [Small, Large] Size name\ncube(a);").parameters
        XCTAssertEqual(other[0].description, "[not a range] Size")
        XCTAssertNil(other[0].range)
        XCTAssertEqual(other[1].description, "[Small, Large] Size name")
        XCTAssertEqual(other[1].choices, [])
        let fitTest = try XCTUnwrap(parameters.first)
        XCTAssertEqual(fitTest.kind, .boolean)
        XCTAssertEqual(fitTest.defaultValue, "false")
        XCTAssertEqual(fitTest.description, "Print only a small fit-test piece")
        XCTAssertEqual(fitTest.group, "Fit test")
        XCTAssertNil(scadValueProblem("true", for: fitTest))
        XCTAssertEqual(scadAssignments([fitTest], values: ["fit_test": "true"]), [ScadAssignment(name: "fit_test", literal: "true")])
        XCTAssertFalse(accessoryTemplateFileText(code: goodCode, name: "Stand").contains("fit_test"))
    }

    // MARK: The loop with a fit-test piece

    private func makeVariantRun(_ stub: StubClaude, renderer: VariantRenderer, limits: AccessoryDesignLimits = AccessoryDesignLimits()) -> AccessoryDesignRun {
        AccessoryDesignRun(limits: limits, send: { request, _ in try stub.next(request) },
                           render: { code, variant in try await renderer.render(variant, code: code) })
    }

    func testTheLoopAttachesThePieceWithoutUsingARender() async throws {
        let slot = AccessoryFitSize(name: "slot_width", millimetres: 9.9)
        let part = try render(try boxSTL(.zero, SIMD3(40, 30, 20)), code: fitTestCode, fitSizes: [slot])
        let piece = try render(try boxSTL(.zero, SIMD3(10, 10, 5)), code: fitTestCode, fitSizes: [slot])
        let renderer = VariantRenderer(part: .rendered(part), piece: .rendered(piece))
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(fitTestCode)])),
                               .success(toolCall("t2", "render_scad", ["code": .string(fitTestCode)])),
                               .success(toolCall("t3", "finish_design", finishInput))])
        let run = makeVariantRun(stub, renderer: renderer, limits: AccessoryDesignLimits(maxReplies: 10, maxRenders: 1))
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(run.phase, .finished)
        XCTAssertEqual(renderer.designCount, 1, "The second render_scad is over the limit of 1")
        XCTAssertEqual(renderer.pieceCount, 1)
        XCTAssertEqual(run.rendersThisRound, 1, "The piece isn't one of Claude's renders")
        XCTAssertEqual(run.totalRenders, 1)
        XCTAssertNotNil(run.latestRender?.passingFitTest)
        XCTAssertNotNil(run.finish?.render.passingFitTest)
        XCTAssertEqual(run.finish?.photoCheck, "Matches the photos.")
        XCTAssertTrue(run.transcript.contains { if case .fitTest(_, true) = $0.kind { return true }; return false })
        let sent = toolResultTexts(try XCTUnwrap(lastUserBlocks(stub.requests[1]).first))
        XCTAssertTrue(sent.texts[1].hasPrefix("Fit-test piece:"))
        XCTAssertEqual(sent.images, 5)
        guard case .toolResult(_, _, let overLimit, _) = try XCTUnwrap(lastUserBlocks(stub.requests[2]).first) else { return XCTFail("No tool result") }
        XCTAssertTrue(overLimit)
    }

    func testThePieceIsMadeOnlyForAnAcceptableRenderThatDeclaresFitTest() async throws {
        let twoParts = try render(try STLMesh.validated(boxTriangles(.zero, SIMD3(10, 10, 10)) + boxTriangles(SIMD3(20, 0, 0), SIMD3(30, 10, 10))).stlCopyData(),
                                  code: fitTestCode)
        let plain = try render(try boxSTL())
        let defaultTrue = try render(try boxSTL(), code: "fit_test = true;\ncube([20, 30, 10]);")
        for part in [twoParts, plain, defaultTrue] {
            let renderer = VariantRenderer(part: .rendered(part), piece: .failed("unused"))
            let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(part.code)]))])
            let run = makeVariantRun(stub, renderer: renderer)
            run.start(firstTurn: .user(text: "brief"))
            await settle(run)
            XCTAssertEqual(renderer.designCount, 1)
            XCTAssertEqual(renderer.pieceCount, 0, part.code)
            XCTAssertNil(run.latestRender?.fitTest)
        }
    }

    func testAFailedPieceLeavesThePartAcceptable() async throws {
        let part = try render(try boxSTL(.zero, SIMD3(40, 30, 20)), code: fitTestCode)
        let renderer = VariantRenderer(part: .rendered(part), piece: .failed("OpenSCAD didn’t finish within 120 seconds, so Plinth stopped it."))
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(fitTestCode)])),
                               .success(toolCall("t2", "finish_design", finishInput))])
        let run = makeVariantRun(stub, renderer: renderer)
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertEqual(run.phase, .finished, "finish_design doesn't need a fit-test piece")
        XCTAssertNil(run.finish?.render.passingFitTest)
        XCTAssertEqual(accessoryNoFitTestLines(try XCTUnwrap(run.finish?.render))?.last, "OpenSCAD couldn’t make the fit-test piece.")
        let sent = toolResultTexts(try XCTUnwrap(lastUserBlocks(stub.requests[1]).first))
        XCTAssertTrue(sent.texts[1].contains("and it failed. OpenSCAD didn’t finish within 120 seconds"))
        XCTAssertEqual(sent.images, 4)
    }

    func testStopDuringThePieceKeepsTheDesignRender() async throws {
        let part = try render(try boxSTL(.zero, SIMD3(40, 30, 20)), code: fitTestCode)
        let renderer = VariantRenderer(part: .rendered(part), piece: .failed("unused"), pieceWaitsForStop: true)
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(fitTestCode)])),
                               .success(toolCall("t2", "finish_design", finishInput))])
        let run = makeVariantRun(stub, renderer: renderer)
        run.start(firstTurn: .user(text: "brief"))
        for _ in 0..<2_000 where run.phase != .working("Rendering the fit-test piece with OpenSCAD…") {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(run.phase, .working("Rendering the fit-test piece with OpenSCAD…"))
        run.stop()
        await settle(run)
        XCTAssertEqual(run.phase, .stopped("Stopped. Nothing more was sent."))
        XCTAssertEqual(stub.requests.count, 1, "Nothing more was sent")
        XCTAssertEqual(renderer.pieceCount, 1)
        XCTAssertEqual(run.rendersThisRound, 1)
        // The design render really ran, so it is kept, with the piece recorded as stopped.
        let kept = try XCTUnwrap(run.latestRender)
        XCTAssertEqual(kept.id, part.id)
        guard case .stopped? = kept.fitTest else { return XCTFail("Expected the piece to be recorded as stopped") }
        XCTAssertTrue(run.transcript.contains { if case .fitTest(let line, false) = $0.kind { return line.contains("stopped") }; return false })
        XCTAssertNil(run.finish)
        XCTAssertFalse(run.canTryAgain)
        // A note sends that render's real result (not a "not run" error), and finish_design can use it.
        XCTAssertTrue(run.canSendNote)
        run.sendNote("Looks right")
        await settle(run)
        guard case .toolResult(let id, let content, let isError, _) = try XCTUnwrap(lastUserBlocks(stub.requests[1]).first) else { return XCTFail("No tool result") }
        XCTAssertEqual(id, "t1")
        XCTAssertFalse(isError)
        XCTAssertTrue(toolResultTexts(.toolResult(toolUseID: id, content: content)).texts[1].contains("the seller pressed Stop"))
        XCTAssertEqual(run.phase, .finished)
        XCTAssertEqual(run.finish?.render.id, part.id)
        XCTAssertEqual(accessoryNoFitTestLines(try XCTUnwrap(run.finish?.render))?.last, "The fit-test piece was stopped before it was made.")
    }

    func testBothRendersGetTheSameCode() async throws {
        let part = try render(try boxSTL(.zero, SIMD3(40, 30, 20)), code: fitTestCode)
        let piece = try render(try boxSTL(.zero, SIMD3(10, 10, 5)), code: fitTestCode)
        let renderer = VariantRenderer(part: .rendered(part), piece: .rendered(piece))
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(fitTestCode)]))])
        let run = makeVariantRun(stub, renderer: renderer)
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        let codes = renderer.renderedCode
        XCTAssertEqual(codes.map(\.variant), [.design, .fitTest])
        XCTAssertEqual(codes.map(\.code), [fitTestCode, fitTestCode])
    }

    func testAPieceThatIsThePartBlocksFinishing() async throws {
        // fit_test = true changed nothing: the piece is the part (say, fit_test is already true somewhere Studio
        // can't see, or the code ignores it).
        let slot = AccessoryFitSize(name: "slot_width", millimetres: 9.9)
        let part = try render(try boxSTL(.zero, SIMD3(40, 30, 20)), code: fitTestCode, fitSizes: [slot])
        let same = try render(try boxSTL(.zero, SIMD3(40, 30, 20)), code: fitTestCode, fitSizes: [slot])
        let renderer = VariantRenderer(part: .rendered(part), piece: .rendered(same))
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(fitTestCode)])),
                               .success(toolCall("t2", "finish_design", finishInput))])
        let run = makeVariantRun(stub, renderer: renderer)
        run.start(firstTurn: .user(text: "brief"))
        await settle(run)
        XCTAssertNil(run.finish, "Refused, as for fit_test = true in the code")
        let kept = try XCTUnwrap(run.latestRender)
        XCTAssertFalse(kept.isAcceptable)
        XCTAssertEqual(kept.problems.last, accessoryFitTestEqualsPartProblem)
        let sent = toolResultTexts(try XCTUnwrap(lastUserBlocks(stub.requests[1]).first))
        XCTAssertTrue(sent.texts[0].contains("The app can’t accept this render as the finished design yet"), sent.texts[0])
        XCTAssertTrue(sent.texts[1].contains("The piece is the same model as the part."))
        guard case .toolResult(_, _, let refused, _) = try XCTUnwrap(lastUserBlocks(stub.requests[2]).first) else { return XCTFail("No tool result") }
        XCTAssertTrue(refused)
    }

    func testClearanceIsAskedForWhenFitSizesHaveNone() throws {
        let slot = AccessoryFitSize(name: "slot_width", millimetres: 9.9)
        let noClearance = fitTestCode.replacingOccurrences(of: "clearance = 0.25; // [0:0.05:1] Fit clearance per side (mm)\n", with: "")
        XCTAssertEqual(accessoryClearanceValueNames(noClearance), [])
        XCTAssertEqual(accessoryClearanceValueNames(fitTestCode), ["clearance"])
        XCTAssertEqual(accessoryClearanceValueNames("slot_clearance = 0.2;\n/* [Hidden] */\nhole_clearance = 0.3;\ncube(1);"), ["slot_clearance"])
        let piece = AccessoryRenderOutcome.rendered(try render(try boxSTL(.zero, SIMD3(10, 10, 5)), code: noClearance, fitSizes: [slot]))
        let missing = try XCTUnwrap(accessoryFitTestFactsText(try renderWithPiece(code: noClearance, fitSizes: [slot], piece: piece)))
        XCTAssertTrue(missing.contains("Clearance: no top-level Customizer value has “clearance” in its name"), missing)
        XCTAssertTrue(missing.contains("clearance = 0.25; // [0:0.05:1] Fit clearance per side (mm)"))
        // Advisory: the piece still passes.
        XCTAssertNotNil(try renderWithPiece(code: noClearance, fitSizes: [slot], piece: piece).passingFitTest)
        // Without fit sizes there is nothing to adjust.
        XCTAssertFalse(try XCTUnwrap(accessoryFitTestFactsText(try renderWithPiece(code: noClearance, piece: piece))).contains("Clearance:"))
        for phrase in ["Fit clearance per side (mm)", "grows by half that, 0.15 mm", "measure the printed piece with calipers",
                       "join them with a thin bar", "at least 8–10 mm thick", "Assign fit_test only there",
                       "The photos show the object, not the accessory", "When they show only the object"] {
            XCTAssertTrue(accessorySystemPrompt.contains(phrase), phrase)
        }
        XCTAssertTrue(accessoryPhotoComparisonText.contains("If they show only the object"))
        // The advice names the design's own clearance values, or asks for one.
        XCTAssertEqual(accessoryFitTestPrintAdvice(code: fitTestCode),
                       "Print this first and check it against the real object; Order a Sample to Me… in Models can print it. Save Template… too: if the piece is tight or loose, change “Fit clearance per side (mm)” in Personalise from Template, or tell Claude by how much while this window is open.")
        XCTAssertTrue(accessoryFitTestPrintAdvice(code: "slot_clearance = 0.2; // [0:0.05:1] Slot clearance\nhole_clearance = 0.3;\ncube(1);")
            .contains("change “Slot clearance” or “hole_clearance” in Personalise from Template"))
        XCTAssertEqual(accessoryFitTestPrintAdvice(code: noClearance),
                       "Print this first and check it against the real object; Order a Sample to Me… in Models can print it. If the piece is tight or loose, tell Claude by how much while this window is open, or ask it to add a Fit clearance value.")
        XCTAssertEqual(accessoryFitTestNameCaption(libraryName: "Phone stand (designed)"), "Saves as “Phone stand (fit test)”, from the library name below.")
    }

    func testThePictureSentenceNeedsAPicture() throws {
        let slot = AccessoryFitSize(name: "slot_width", millimetres: 9.9)
        var noPictures = testBudget
        noPictures.pictureAngles = []
        let bare = try XCTUnwrap(analyseAccessoryRender(stl: try boxSTL(.zero, SIMD3(10, 10, 5)), code: fitTestCode, openSCADMessages: [],
                                                        fitSizes: [slot], budget: noPictures))
        let render = try renderWithPiece(fitSizes: [slot], piece: .rendered(bare))
        let piece = try XCTUnwrap(render.passingFitTest)
        XCTAssertNil(piece.image)
        let text = try XCTUnwrap(accessoryFitTestFactsText(render))
        XCTAssertTrue(text.contains("The piece passes the app’s checks."))
        XCTAssertFalse(text.contains("its picture follows"))
        XCTAssertEqual(toolResultTexts(accessoryRenderToolResult(.rendered(render), toolUseID: "t", renderNumber: 1, maxRenders: 4)).images, 4)
    }

    func testShareLabelsAgreeWithTheVerdictAtTheThresholds() {
        XCTAssertEqual(accessoryShareLabel(0.4996), "49.9%")
        XCTAssertEqual(accessoryShareLabel(0.5), "50.0%")
        XCTAssertEqual(accessoryShareLabel(0.50004), "50.1%")
        XCTAssertEqual(accessoryShareLabel(0.2496), "24.9%")
        XCTAssertEqual(accessoryShareLabel(0.25004), "25.1%")
        XCTAssertEqual(accessoryShareLabel(0.12), "12%")
        XCTAssertEqual(accessoryShareLabel(0.005), "under 1%")
    }

    func testNotePlaceholderInvitesTheFitTestResult() {
        XCTAssertEqual(accessoryNotePlaceholder(finished: true, hasPassingFitTest: true), "Fit-test result, such as “the slot was 0.3 mm too tight”")
        XCTAssertEqual(accessoryNotePlaceholder(finished: false, hasPassingFitTest: true), "Fit-test result, such as “the slot was 0.3 mm too tight”")
        XCTAssertEqual(accessoryNotePlaceholder(finished: true, hasPassingFitTest: false), "Ask for changes, such as “make the lip 2 mm taller”")
        XCTAssertEqual(accessoryNotePlaceholder(finished: false, hasPassingFitTest: false), "Tell Claude how to continue")
    }

    func testANoteOverThePictureLimitKeepsTheFinishedDesign() async throws {
        let picture = AnthropicInputBlock.image(AnthropicImage(mediaType: .jpeg, base64Data: "AA=="))
        let rendered = try render(try boxSTL())
        // One reply that renders and finishes: the render's four pictures are still waiting to go with the next turn.
        let render = AnthropicToolUse(id: "t1", name: "render_scad", input: ["code": .string(goodCode)], rawInputJSON: "{}", inputProblem: nil)
        let finish = AnthropicToolUse(id: "t2", name: "finish_design", input: finishInput, rawInputJSON: "{}", inputProblem: nil)
        let both = reply([AnthropicOutputBlock(content: .toolUse(render), raw: ["type": "tool_use", "id": "t1", "name": "render_scad", "input": ["code": .string(goodCode)]]),
                          AnthropicOutputBlock(content: .toolUse(finish), raw: ["type": "tool_use", "id": "t2", "name": "finish_design", "input": finishInput])],
                         stop: .toolUse)
        let stub = StubClaude([.success(both)])
        let run = makeRun(stub) { .rendered(rendered) }
        run.start(firstTurn: .user(Array(repeating: picture, count: 97) + [.text("brief")]))
        await settle(run)
        XCTAssertEqual(run.phase, .finished)
        let finished = try XCTUnwrap(run.finish)
        let history = run.messages
        run.sendNote("Make the lip taller")
        XCTAssertEqual(stub.requests.count, 1, "Nothing was sent")
        XCTAssertEqual(run.phase, .finished, "The finished design stays")
        XCTAssertEqual(run.finish?.render.id, finished.render.id, "Its Save buttons stay")
        XCTAssertEqual(run.messages, history, "The history is unchanged")
        XCTAssertTrue(run.imageLimitReached)
        XCTAssertFalse(run.canSendNote)
        if case .notice(let text) = run.transcript.last?.kind { XCTAssertEqual(text, accessoryNoteImageLimitText) } else { XCTFail("Expected the notice") }
        XCTAssertTrue(accessoryNoteImageLimitText.contains("Save what you have"))
    }

    func testAnAnswerOverThePictureLimitChangesNothing() async throws {
        let picture = AnthropicInputBlock.image(AnthropicImage(mediaType: .jpeg, base64Data: "AA=="))
        let rendered = try render(try boxSTL())
        let render = AnthropicToolUse(id: "t1", name: "render_scad", input: ["code": .string(goodCode)], rawInputJSON: "{}", inputProblem: nil)
        let ask = AnthropicToolUse(id: "t2", name: "ask_seller", input: ["question": "How thick is it?"], rawInputJSON: "{}", inputProblem: nil)
        let both = reply([AnthropicOutputBlock(content: .toolUse(render), raw: ["type": "tool_use", "id": "t1", "name": "render_scad", "input": ["code": .string(goodCode)]]),
                          AnthropicOutputBlock(content: .toolUse(ask), raw: ["type": "tool_use", "id": "t2", "name": "ask_seller", "input": ["question": "How thick is it?"]])],
                         stop: .toolUse)
        let stub = StubClaude([.success(both)])
        let run = makeRun(stub) { .rendered(rendered) }
        run.start(firstTurn: .user(Array(repeating: picture, count: 97) + [.text("brief")]))
        await settle(run)
        XCTAssertEqual(run.phase, .waitingForSeller)
        let history = run.messages
        run.answer("9.5 mm")
        XCTAssertEqual(stub.requests.count, 1, "Nothing was sent")
        XCTAssertEqual(run.messages, history)
        XCTAssertEqual(run.phase, .stopped(accessoryNoteImageLimitText))
        XCTAssertFalse(run.canTryAgain)
        XCTAssertFalse(run.canSendNote)
    }

    func testTooManyPicturesStopsBeforeSending() async throws {
        let picture = AnthropicInputBlock.image(AnthropicImage(mediaType: .jpeg, base64Data: "AA=="))
        XCTAssertEqual(accessoryImageCount([.user([picture, picture, .text("x")]),
                                            .user([.toolResult(toolUseID: "t", content: [.text("a"), .image(AnthropicImage(mediaType: .jpeg, base64Data: "AA=="))])])]), 3)

        // 100 pictures may go; 101 may not, and nothing is sent.
        let atLimit = StubClaude([.success(toolCall("t1", "finish_design", finishInput))])
        let fine = makeRun(atLimit) { .failed("unused") }
        fine.start(firstTurn: .user(Array(repeating: picture, count: 100) + [.text("brief")]))
        await settle(fine)
        XCTAssertEqual(atLimit.requests.count, 2)
        XCTAssertFalse(fine.imageLimitReached)

        let over = StubClaude([])
        let run = makeRun(over) { .failed("unused") }
        run.start(firstTurn: .user(Array(repeating: picture, count: 101) + [.text("brief")]))
        await settle(run)
        XCTAssertEqual(over.requests.count, 0, "Nothing was sent")
        XCTAssertTrue(run.imageLimitReached)
        XCTAssertEqual(run.phase, .stopped(accessoryImageLimitText))
        XCTAssertFalse(run.canTryAgain)
        XCTAssertFalse(run.canSendNote)

        // A render's pictures that would take the next request over the limit stop it too, with the history unchanged.
        let rendered = try render(try boxSTL())
        let stub = StubClaude([.success(toolCall("t1", "render_scad", ["code": .string(goodCode)]))])
        let late = makeRun(stub) { .rendered(rendered) }
        late.start(firstTurn: .user(Array(repeating: picture, count: 97) + [.text("brief")]))
        await settle(late)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertTrue(late.imageLimitReached)
        XCTAssertEqual(late.messages.count, 3, "The first turn, Claude's reply and the render's result, unchanged")
        XCTAssertEqual(accessoryImageCount(late.messages), 101)
    }
}