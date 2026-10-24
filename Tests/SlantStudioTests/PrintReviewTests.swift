import XCTest
import simd
@testable import SlantStudio

final class PrintReviewTests: XCTestCase {
    // MARK: Fixtures

    private func corners(_ low: SIMD3<Float>, _ high: SIMD3<Float>) -> [Float] {
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

    private func box(_ low: SIMD3<Float>, _ high: SIMD3<Float>) throws -> STLMesh {
        try STLMesh.validated(corners(low, high))
    }

    /// A closed sphere of 5,120 triangles, centred on the origin.
    private func ball() throws -> STLMesh { try MeshRepairTests.sphere(levels: 4, radius: 20) }

    /// The same sphere with one triangle missing: open.
    private func openBall() throws -> STLMesh {
        let whole = try ball()
        return try STLMesh.validated(Array(whole.vertices.dropLast(9)))
    }

    private func context(_ mesh: STLMesh, scale: String? = nil, base: String? = nil) -> PrintReviewPlanContext {
        PrintReviewPlanContext(triangles: mesh.triangleCount, sizeMM: mesh.maximum - mesh.minimum,
                               scaleBlockedReason: scale, baseBlockedReason: base)
    }

    private func step(_ tool: String, target: AnthropicJSON = nil, axis: AnthropicJSON = nil, mm: AnthropicJSON = nil,
                      cut: AnthropicJSON = nil, shape: AnthropicJSON = nil, margin: AnthropicJSON = nil,
                      thickness: AnthropicJSON = nil, text: AnthropicJSON = nil) -> AnthropicJSON {
        ["tool": .string(tool), "reason": "Because.", "target_triangles": target, "axis": axis, "mm": mm, "cut_mm": cut,
         "shape": shape, "margin_mm": margin, "thickness_mm": thickness, "text": text]
    }

    private func planInput(_ steps: [AnthropicJSON], risks: [AnthropicJSON] = []) -> AnthropicJSON {
        ["assessment": "Looks printable.", "risks": .array(risks), "steps": .array(steps),
         "orientation": "Stand it upright.", "material_note": "PLA is fine."]
    }

    private func reply(stop: String, blocks: [AnthropicOutputBlock], details: AnthropicStopDetails? = nil) -> AnthropicMessage {
        var usage = AnthropicUsage()
        usage.inputTokens = 8_000
        usage.outputTokens = 4_000
        return AnthropicMessage(id: "msg_1", model: anthropicDefaultModel, requestedModel: anthropicDefaultModel, blocks: blocks,
                                stopReason: AnthropicStopReason(stop), stopDetails: details, usage: usage)
    }

    private func toolBlock(_ input: AnthropicJSON, problem: String? = nil, id: String = "toolu_1") -> AnthropicOutputBlock {
        let use = AnthropicToolUse(id: id, name: printReviewToolName, input: input, rawInputJSON: input.encodedString, inputProblem: problem)
        return AnthropicOutputBlock(content: .toolUse(use),
                                    raw: ["type": "tool_use", "id": .string(id), "name": .string(printReviewToolName), "input": input])
    }

    private func textBlock(_ text: String) -> AnthropicOutputBlock {
        AnthropicOutputBlock(content: .text(text), raw: ["type": "text", "text": .string(text)])
    }

    // MARK: Overhangs

    func testOverhangShareIgnoresTheBedAndCountsRaisedUndersides() throws {
        let cube = try box(.zero, SIMD3(10, 10, 10))
        XCTAssertEqual(overhangShare(cube).overhangAreaMM2, 0)
        XCTAssertEqual(overhangShare(cube).surfaceAreaMM2, 600, accuracy: 1e-6)

        // A second block floating above the first: its 4 × 4 underside overhangs; the bed face doesn't.
        let combined = try STLMesh.validated(corners(.zero, SIMD3(10, 10, 10)) + corners(SIMD3(0, 0, 15), SIMD3(4, 4, 19)))
        let share = overhangShare(combined)
        XCTAssertEqual(share.overhangAreaMM2, 16, accuracy: 1e-6)
        XCTAssertEqual(share.fraction, 16.0 / (600 + 96), accuracy: 1e-9)
        XCTAssertTrue(printReviewOverhangLine(share).contains("2%"))
        XCTAssertTrue(printReviewOverhangLine(overhangShare(cube)).hasPrefix("Overhangs: no downward faces"))
    }

    func testOverhangShareOfASphereIsTheSteepLowerCap() throws {
        let share = overhangShare(try ball())
        // Faces within 45° of straight down: a cap of height r(1 − cos 45°), about 14.6% of the sphere's area.
        XCTAssertEqual(share.fraction, 0.146, accuracy: 0.02)
        XCTAssertEqual(overhangShare(try ball()), share)
    }

    // MARK: Facts

    func testFactLinesForASoundBlockSayTheChecksFoundNoProblems() throws {
        let block = try box(.zero, SIMD3(20, 30, 40))
        let measured = try XCTUnwrap(measureForPrintReview(block))
        XCTAssertTrue(measured.checksFoundNoProblems)
        let lines = printReviewFactLines(measured)
        XCTAssertEqual(lines.first, "Size: 20.0 mm wide (X) × 30.0 mm deep (Y) × 40.0 mm tall (Z).")
        XCTAssertTrue(lines.contains("Fits Slant’s 220 mm build volume."))
        XCTAssertTrue(lines.contains("Mesh check: closed and consistent, 1 part."))
        XCTAssertTrue(lines.contains("Flat base: enough flat area to stand on as placed."))
        XCTAssertEqual(lines.last, "Studio’s checks found no problems.")
    }

    func testFactLinesForAnOpenOversizedModelNeverClaimNoProblems() throws {
        let big = try MeshRepairTests.sphere(levels: 3, radius: 150)
        let open = try STLMesh.validated(Array(big.vertices.dropLast(9)))
        let measured = try XCTUnwrap(measureForPrintReview(open))
        XCTAssertFalse(measured.checksFoundNoProblems)
        let lines = printReviewFactLines(measured)
        XCTAssertFalse(lines.contains("Studio’s checks found no problems."))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Larger than Slant’s 220 mm build volume") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Mesh check: needs repair — 3 open edges") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("Flat base: removing") })
    }

    func testMeasuringStopsWhenCancelled() throws {
        XCTAssertNil(measureForPrintReview(try ball(), isCancelled: { true }))
    }

    func testContextLinesAreBoundedAndSkipEmptyValues() {
        var context = PrintReviewContext(origin: "Generated by Meshy\nfrom a photo", intendedSizeNote: "  ", purpose: "Display piece")
        context.findings = Array(repeating: String(repeating: "x", count: 500), count: 30)
        let lines = printReviewContextLines(context)
        XCTAssertEqual(lines.first, "Origin: Generated by Meshy from a photo")
        XCTAssertEqual(lines[1], "Purpose: Display piece")
        XCTAssertEqual(lines.count, 22)
        XCTAssertEqual(lines.last?.count, 301)
        XCTAssertEqual(printReviewContextLines(PrintReviewContext()), [])
    }

    // MARK: Plan decoding and validation

    func testAValidPlanDecodesEveryToolWithNothingProblematic() throws {
        let mesh = try ball()
        let plan = decodePrintReviewPlan(planInput([
            step("repair"),
            step("simplify", target: 3000),
            step("scale_to_size", axis: "z", mm: 60),
            step("flat_base", cut: 1.5),
            step("manual", text: "Use Reinforce to add a gusset.")
        ], risks: [["part": "Tail", "issue": "Thin at the tip.", "severity": "high"],
                   ["part": "Ear", "issue": "Small.", "severity": "odd"]]), context: context(mesh))
        XCTAssertEqual(plan.steps.map(\.tool), ["repair", "simplify", "scale_to_size", "flat_base", "manual"])
        XCTAssertEqual(plan.steps.map(\.problem), [nil, nil, nil, nil, nil])
        XCTAssertEqual(plan.steps.map(\.isRunnable), [true, true, true, true, false])
        XCTAssertEqual(plan.steps[1].action, .simplify(target: 3000))
        XCTAssertEqual(plan.steps[2].action, .scaleToSize(axis: .z, mm: 60))
        XCTAssertEqual(plan.steps[2].title, "Scale so the height (Z) is 60 mm")
        XCTAssertEqual(plan.steps[3].action, .flatBase(cutMM: 1.5))
        XCTAssertEqual(plan.steps[4].action, .manual("Use Reinforce to add a gusset."))
        XCTAssertEqual(plan.risks.map(\.severity), [.high, .medium])
        XCTAssertEqual(plan.assessment, "Looks printable.")
        XCTAssertEqual(plan.notes, [])
    }

    func testBadAndOutOfRangeSettingsAreShownButNeverRunnable() throws {
        let mesh = try ball()
        let plan = decodePrintReviewPlan(planInput([
            step("simplify", target: 500),
            step("simplify", target: 2500.5),
            step("simplify"),
            step("scale_to_size", axis: "z", mm: 400),
            step("scale_to_size", axis: "diagonal", mm: 50),
            step("flat_base", cut: 0),
            step("flat_base", cut: 6),
            step("plinth", shape: "round", margin: 0, thickness: 3),
            step("plinth", shape: "hexagonal", margin: 3, thickness: 3),
            step("manual", text: "   ")
        ]), context: context(mesh))
        XCTAssertEqual(plan.steps.count, 10)
        XCTAssertTrue(plan.steps.allSatisfy { !$0.isRunnable })
        XCTAssertTrue(plan.steps.allSatisfy { $0.problem != nil })
        XCTAssertEqual(plan.steps[0].problem, "The target must be from 2,000 to 20,000 triangles.")
        XCTAssertEqual(plan.steps[1].problem, "The target must be a whole number of triangles.")
        XCTAssertTrue(plan.steps[3].problem?.contains("larger than Slant’s 220 mm build volume") == true)
        XCTAssertEqual(plan.steps[7].problem, "Choose a margin from 1 to 30 mm.")
        XCTAssertNil(plan.steps[9].action)
    }

    func testSimplifyAboveTheModelsTrianglesIsANoOpProblem() throws {
        let cube = try box(.zero, SIMD3(10, 10, 10))
        let plan = decodePrintReviewPlan(planInput([step("simplify", target: 5000)]), context: context(cube))
        XCTAssertEqual(plan.steps[0].problem, "This model already has 12 triangles, so there’s nothing to simplify.")
    }

    func testUnknownToolsAreDroppedWithANoteAndDuplicatesAreRefused() throws {
        let mesh = try ball()
        let plan = decodePrintReviewPlan(planInput([
            step("repair"),
            step("hollow_out"),
            step("repair"),
            step("simplify", target: 100),
            step("simplify", target: 4000),
            step("flat_base", cut: 1),
            step("plinth", shape: "round", margin: 3, thickness: 3),
            step("manual", text: "One."),
            step("manual", text: "Two.")
        ]), context: context(mesh))
        XCTAssertEqual(plan.notes, ["Claude suggested a tool Studio doesn’t have (“hollow_out”), so it was left out."])
        XCTAssertEqual(plan.steps.map(\.id), Array(1...8))
        XCTAssertEqual(plan.steps[1].problem, "Already in the plan as step 1.")
        // An invalid first simplify doesn't block a valid second one.
        XCTAssertNotNil(plan.steps[2].problem)
        XCTAssertNil(plan.steps[3].problem)
        XCTAssertNil(plan.steps[4].problem)
        XCTAssertEqual(plan.steps[5].problem, "Step 5 already adds a base. Choose a flat base or a plinth, not both.")
        XCTAssertEqual(plan.steps.filter(\.isManual).map(\.problem), [nil, nil])
    }

    func testBlockedFitToolsAndTooManyStepsAreReported() throws {
        let mesh = try ball()
        let blocked = decodePrintReviewPlan(planInput([
            step("scale_to_size", axis: "longest", mm: 50),
            step("plinth", shape: "rectangular", margin: 3, thickness: 3)
        ]), context: context(mesh, scale: "Scale the original.", base: "Add the base to the original."))
        XCTAssertEqual(blocked.steps.map(\.problem), ["Scale the original.", "Add the base to the original."])

        let many = decodePrintReviewPlan(planInput(Array(repeating: step("manual", text: "Tip."), count: 15)), context: context(mesh))
        XCTAssertEqual(many.steps.count, printReviewMaximumSteps)
        XCTAssertEqual(many.notes, ["Claude suggested more than 12 steps; the rest were left out."])
    }

    func testAMissingOrMalformedInputGivesAnEmptyPlan() throws {
        let plan = decodePrintReviewPlan(["steps": "nope"], context: context(try box(.zero, SIMD3(1, 1, 1))))
        XCTAssertEqual(plan.steps, [])
        XCTAssertEqual(plan.assessment, "")
    }

    func testTheToolSchemaIsStrictCompatibleAndAcceptsAPlanWithNulls() throws {
        let schema = printReviewPlanTool.inputSchema
        let text = schema.encodedString
        for unsupported in ["minimum", "maximum", "minLength", "maxLength", "minItems", "maxItems"] {
            XCTAssertFalse(text.contains("\"\(unsupported)\""), unsupported)
        }
        XCTAssertTrue(printReviewPlanTool.strict)
        XCTAssertFalse(printReviewPlanTool.eagerInputStreaming)
        let input = planInput([step("repair"), step("simplify", target: 3000)])
        XCTAssertNil(anthropicSchemaProblem(input, schema: schema))
        XCTAssertNotNil(anthropicSchemaProblem(input.setting("extra", to: 1), schema: schema))
        XCTAssertNotNil(anthropicSchemaProblem(planInput([["tool": "repair"]]), schema: schema))
    }

    // MARK: Request and replies

    func testTheFirstRequestPutsImagesFirstAtHighEffortWithOneCacheBreakpoint() throws {
        let rgba = [UInt8](repeating: 200, count: 16 * 16 * 4)
        let image = try XCTUnwrap(prepareRenderedImage(rgba: rgba, width: 16, height: 16, format: .jpeg(quality: 0.8, background: SIMD3(1, 1, 1))))
        let request = printReviewAnthropicRequest(views: [PrintReviewRender(title: "Front", image: image)],
                                                  factLines: ["Size: 1 mm."], contextLines: ["Purpose: Display piece"])
        XCTAssertNil(request.problem)
        XCTAssertEqual(request.effort, .high)
        XCTAssertGreaterThanOrEqual(request.maxTokens, 32_000)
        XCTAssertEqual(request.tools.map(\.name), [printReviewToolName])
        let json = request.json
        XCTAssertEqual(json["tool_choice"]?["type"], "auto")
        let content = try XCTUnwrap(json["messages"]?.arrayValue?.first?["content"]?.arrayValue)
        XCTAssertEqual(content.map { $0["type"]?.stringValue }, ["image", "text"])
        let userText = try XCTUnwrap(content.last?["text"]?.stringValue)
        XCTAssertTrue(userText.contains("- Size: 1 mm."))
        XCTAssertTrue(userText.contains("- Purpose: Display piece"))
        XCTAssertTrue(userText.contains("Pictures above, in order: Front."))
        XCTAssertEqual(json.encodedString.components(separatedBy: "\"cache_control\"").count - 1, 1)
    }

    func testRepliesMapToPlanRefusalFailureOrOneFollowUp() throws {
        let mesh = try ball()
        let ctx = context(mesh)
        let good = reply(stop: "tool_use", blocks: [toolBlock(planInput([step("repair")]))])
        guard case .plan(let plan) = printReviewReplyOutcome(good, context: ctx) else { return XCTFail("expected a plan") }
        XCTAssertEqual(plan.steps.count, 1)

        let refusal = reply(stop: "refusal", blocks: [toolBlock(planInput([step("repair")]))],
                            details: AnthropicStopDetails(explanation: "Not this one."))
        guard case .refused(let message) = printReviewReplyOutcome(refusal, context: ctx) else { return XCTFail("expected a refusal") }
        XCTAssertTrue(message.contains("Not this one."))
        XCTAssertNil(printReviewFollowUpRequest(printReviewAnthropicRequest(views: [], factLines: [], contextLines: []), reply: refusal))

        let cut = reply(stop: "max_tokens", blocks: [toolBlock(planInput([step("repair")]))])
        guard case .failed = printReviewReplyOutcome(cut, context: ctx) else { return XCTFail("expected a failure") }

        let chat = reply(stop: "end_turn", blocks: [textBlock("Here is my view.")])
        XCTAssertEqual(printReviewReplyOutcome(chat, context: ctx), .needsFollowUp)
        let first = printReviewAnthropicRequest(views: [], factLines: ["Size: 1 mm."], contextLines: [])
        let nudge = try XCTUnwrap(printReviewFollowUpRequest(first, reply: chat))
        XCTAssertNil(nudge.problem)
        XCTAssertEqual(nudge.effort, .medium)
        XCTAssertEqual(nudge.messages.map(\.role), [.user, .assistant, .user])
        XCTAssertEqual(nudge.messages[0], first.messages[0])

        let bad = reply(stop: "tool_use", blocks: [toolBlock(["steps": []], problem: "input.assessment is missing.")])
        XCTAssertEqual(printReviewReplyOutcome(bad, context: ctx), .needsFollowUp)
        let fix = try XCTUnwrap(printReviewFollowUpRequest(first, reply: bad))
        let last = try XCTUnwrap(fix.json["messages"]?.arrayValue?.last?["content"]?.arrayValue)
        XCTAssertEqual(last.first?["type"], "tool_result")
        XCTAssertEqual(last.first?["tool_use_id"], "toolu_1")
        XCTAssertEqual(last.first?["is_error"], true)
    }

    func testCostEstimateAndImageTokens() {
        XCTAssertEqual(printReviewImageTokens(width: 768, height: 768), 784)
        XCTAssertEqual(printReviewImageTokens(width: 0, height: 768), 0)
        XCTAssertEqual(printReviewCostRangeText(inputTokens: 7_500), "about $0.09–$0.35")
        let request = printReviewAnthropicRequest(views: [], factLines: [], contextLines: [])
        let tokens = printReviewEstimatedInputTokens(request, imageSizes: Array(repeating: (768, 768), count: 4))
        XCTAssertGreaterThan(tokens, 4 * 784)
        XCTAssertLessThan(tokens, 12_000)
        var usage = AnthropicUsage()
        usage.inputTokens = 1_000_000
        let replies = [AnthropicMessage(id: "a", model: anthropicDefaultModel, requestedModel: anthropicDefaultModel, blocks: [],
                                        stopReason: .endTurn, stopDetails: nil, usage: usage)]
        XCTAssertEqual(printReviewCostSoFar(replies + replies).usd, 8)
        XCTAssertEqual(printReviewActivityDetail(steps: 3, cost: printReviewCostSoFar(replies)), "Plan with 3 steps · about $4.00")
        XCTAssertEqual(printReviewActivityDetail(steps: nil, cost: AnthropicCostEstimate(usd: 0, complete: true), status: "Stopped"),
                       "Stopped · under $0.01")
    }

    // MARK: Running steps

    func testTheRunnerAppliesStepsInOrderAndGivesTheSameBytesTwice() throws {
        let mesh = try openBall()
        let steps = [PrintReviewRunStep(number: 1, action: .repair),
                     PrintReviewRunStep(number: 2, action: .simplify(target: 2_000)),
                     PrintReviewRunStep(number: 3, action: .scaleToSize(axis: .z, mm: 30)),
                     PrintReviewRunStep(number: 4, action: .flatBase(cutMM: 1)),
                     PrintReviewRunStep(number: 5, action: .manual("Never run."))]
        let first = try runPrintReviewSteps(steps, on: mesh)
        let second = try runPrintReviewSteps(steps, on: mesh)
        XCTAssertEqual(first.data, second.data)
        XCTAssertTrue(first.changed)
        XCTAssertEqual(first.lines.count, 4)
        XCTAssertLessThanOrEqual(first.mesh.triangleCount, 2_100)
        let report = try XCTUnwrap(analyzeMeshHealth(first.mesh))
        XCTAssertTrue(meshHealthIsSound(report))
        // Scaled to 30 mm, then 1 mm cut off the bottom.
        XCTAssertEqual(first.mesh.maximum.z - first.mesh.minimum.z, 29, accuracy: 0.15)
        XCTAssertEqual(try STLMesh.parse(first.data).vertices, first.mesh.vertices)
    }

    func testEachMeshStepAloneIsDeterministic() throws {
        let mesh = try ball()
        var plinth = PlinthSettings()
        plinth.shape = .rectangular
        for action in [PrintReviewAction.repair, .simplify(target: 2_500), .scaleToSize(axis: .longest, mm: 55),
                       .flatBase(cutMM: 0.8), .plinth(plinth)] {
            let steps = [PrintReviewRunStep(number: 1, action: action)]
            XCTAssertEqual(try runPrintReviewSteps(steps, on: mesh).data, try runPrintReviewSteps(steps, on: mesh).data, "\(action)")
        }
    }

    func testAFailingStepStopsTheRunAndNothingIsReturned() throws {
        let open = try openBall()
        XCTAssertThrowsError(try runPrintReviewSteps([PrintReviewRunStep(number: 2, action: .flatBase(cutMM: 1))], on: open)) { error in
            guard case .step(let number, let title, _) = error as? PrintReviewRunError else { return XCTFail("\(error)") }
            XCTAssertEqual(number, 2)
            XCTAssertEqual(title, "Flat base: remove 1 mm from the bottom")
            XCTAssertTrue(error.localizedDescription.contains("nothing was saved"))
        }
        XCTAssertThrowsError(try runPrintReviewSteps([PrintReviewRunStep(number: 1, action: .scaleToSize(axis: .x, mm: 500))], on: open))
    }

    func testManualOnlyCancelledAndNoOpRuns() throws {
        let cube = try box(.zero, SIMD3(10, 10, 10))
        XCTAssertThrowsError(try runPrintReviewSteps([PrintReviewRunStep(number: 1, action: .manual("Tip."))], on: cube)) {
            XCTAssertEqual($0 as? PrintReviewRunError, .nothingToRun)
        }
        XCTAssertThrowsError(try runPrintReviewSteps([PrintReviewRunStep(number: 1, action: .repair)], on: try ball(), isCancelled: { true })) {
            XCTAssertEqual($0 as? PrintReviewRunError, .cancelled)
        }
        let unchanged = try runPrintReviewSteps([PrintReviewRunStep(number: 1, action: .repair)], on: cube)
        XCTAssertFalse(unchanged.changed)
        XCTAssertEqual(unchanged.lines, ["Repair the mesh: nothing needed changing."])
    }

    // MARK: Copy rules and notes

    func testSendSummaryNamesWhatIsSent() {
        XCTAssertEqual(printReviewSendSummary(pictures: 4, hasContext: true),
                       "Studio sends Anthropic 4 pictures of the model and the measurements above, with what Studio knows about it. It doesn’t send the model file or its name. Claude Opus 5.5 suggests a plan made of Studio’s tools; nothing runs until you tick it.")
        XCTAssertTrue(printReviewSendSummary(pictures: 0, hasContext: false).hasPrefix("Studio sends Anthropic the measurements above. "))
    }

    func testCopyNamesAndRecordRules() {
        XCTAssertEqual(printReadyCopyName("Dragon.stl"), "Dragon (print-ready)")
        XCTAssertEqual(printReadyCopyName("  "), "Model (print-ready)")
        XCTAssertTrue(printReadyCopyKeepsRecords([.repair, .simplify(target: 3000)]))
        XCTAssertFalse(printReadyCopyKeepsRecords([.repair, .flatBase(cutMM: 1)]))
        XCTAssertFalse(printReadyCopyKeepsRecords([.scaleToSize(axis: .z, mm: 10)]))
    }

    func testSelectionNotesWarnAboutABaseOnAnOpenMesh() throws {
        let small = try MeshRepairTests.sphere(levels: 2, radius: 20)
        let measured = try XCTUnwrap(measureForPrintReview(try STLMesh.validated(Array(small.vertices.dropLast(9)))))
        XCTAssertEqual(printReviewSelectionNotes([.flatBase(cutMM: 1)], measurements: measured).count, 1)
        XCTAssertEqual(printReviewSelectionNotes([.repair, .plinth(PlinthSettings())], measurements: measured), [])
        XCTAssertEqual(printReviewSelectionNotes([.simplify(target: 2000)], measurements: measured), ["Simplify works best on a repaired mesh."])
        let sound = try XCTUnwrap(measureForPrintReview(try box(.zero, SIMD3(10, 10, 10))))
        XCTAssertEqual(printReviewSelectionNotes([.flatBase(cutMM: 1)], measurements: sound), [])
    }

    func testStudioNotesShowStudiosOwnNumbers() throws {
        let measured = try XCTUnwrap(measureForPrintReview(try box(.zero, SIMD3(20, 30, 40))))
        let scale = printReviewStudioNote(.scaleToSize(axis: .z, mm: 80), measurements: measured,
                                          context: PrintReviewContext(intendedSizeNote: "Height 80 mm"))
        XCTAssertEqual(scale, "Studio: the height (Z) is now 40.0 mm; result 40.0 × 60.0 × 80.0 mm. You said: Height 80 mm")
        XCTAssertTrue(printReviewStudioNote(.scaleToSize(axis: .z, mm: 80), measurements: measured, context: PrintReviewContext())
            .hasSuffix("Claude can’t measure it."))
        XCTAssertEqual(printReviewStudioNote(.repair, measurements: measured, context: PrintReviewContext()),
                       "Studio: the mesh is already closed and consistent, so this may change nothing.")
    }

    func testRenderedViewsAreFourDeterministicJPEGs() throws {
        let block = try box(.zero, SIMD3(20, 30, 40))
        let first = try XCTUnwrap(renderPrintReviewViews(block, size: 64))
        let second = try XCTUnwrap(renderPrintReviewViews(block, size: 64))
        XCTAssertEqual(first.map(\.title), ["Front", "Side", "Top", "Three-quarter"])
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.image.mediaType == .jpeg && $0.image.pixelWidth == 64 })
        XCTAssertNil(renderPrintReviewViews(block, size: 64, isCancelled: { true }))
    }
}
