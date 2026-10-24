import XCTest
@testable import SlantStudio

// Suggest Accessories: the strict tool, the request, Studio's own validation and deny list, using an idea in the
// brief, the design turn's context, the cost forecast and the runner, driven by stubbed replies (no network).

private func reply(_ blocks: [AnthropicOutputBlock], stop: AnthropicStopReason?, details: AnthropicStopDetails? = nil) -> AnthropicMessage {
    AnthropicMessage(id: "msg", model: anthropicDefaultModel, requestedModel: anthropicDefaultModel, blocks: blocks,
                     stopReason: stop, stopDetails: details, usage: AnthropicUsage(inputTokens: 10_000, outputTokens: 3_000))
}

private func textBlock(_ text: String) -> AnthropicOutputBlock {
    AnthropicOutputBlock(content: .text(text), raw: ["type": "text", "text": .string(text)])
}

private func toolReply(_ input: AnthropicJSON, name: String = accessorySuggestToolName, problem: String? = nil,
                       stop: AnthropicStopReason = .toolUse) -> AnthropicMessage {
    let use = AnthropicToolUse(id: "toolu_1", name: name, input: input, rawInputJSON: input.encodedString, inputProblem: problem)
    return reply([AnthropicOutputBlock(content: .toolUse(use), raw: ["type": "tool_use", "id": "toolu_1", "name": .string(name), "input": input])],
                 stop: stop)
}

private func measurementJSON(_ label: String, how: String = "Calipers across the widest point", method: String = "calipers") -> AnthropicJSON {
    ["label": .string(label), "how": .string(how), "method": .string(method)]
}

private func ideaJSON(_ title: String, description: String? = nil, fit: String = "snug", hardware: [String] = [],
                      measurements: [AnthropicJSON] = [], caution: String = "") -> AnthropicJSON {
    ["title": .string(title), "description": .string(description ?? "A \(title.lowercased()) for the object."),
     "who_wants_it": "People who own one.", "fit": .string(fit), "hardware": .array(hardware.map { .string($0) }),
     "measurements": .array(measurements), "caution": .string(caution)]
}

private func suggestionInput(_ ideas: [AnthropicJSON], confidence: String = "likely", name: String = "Over-ear wireless headphones",
                             notes: String = "") -> AnthropicJSON {
    ["object": ["name": .string(name), "seen_text": "", "alternatives": ["Gaming headset"], "confidence": .string(confidence),
                "evidence": "Two ear cups joined by a headband.", "would_confirm": "A photo of the label.", "features": ["Headband", "USB-C port"]],
     "ideas": .array(ideas), "notes": .string(notes)]
}

private let photo = PreparedImage(data: Data([1, 2, 3]), mediaType: .jpeg, pixelWidth: 1568, pixelHeight: 1176)

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

@MainActor private final class ActivityLog {
    var entries: [(detail: String, success: Bool)] = []
    func record(_ detail: String, _ success: Bool) { entries.append((detail, success)) }
}

@MainActor
final class AccessorySuggestionsTests: XCTestCase {
    // MARK: Tool and request

    /// Every object in the schema has `additionalProperties: false` and lists every property as required, and no
    /// length or number constraint appears anywhere.
    private func assertStrict(_ schema: AnthropicJSON, path: String = "input", file: StaticString = #filePath, line: UInt = #line) {
        guard let members = schema.objectMembers else { return }
        for keyword in ["maxLength", "minLength", "maxItems", "minItems", "minimum", "maximum", "pattern"] {
            XCTAssertNil(schema[keyword], "\(path) uses \(keyword)", file: file, line: line)
        }
        if schema["type"]?.stringValue == "object" {
            XCTAssertEqual(schema["additionalProperties"], .bool(false), "\(path) allows other properties", file: file, line: line)
            let properties = schema["properties"]?.objectMembers?.map(\.key) ?? []
            let required = schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? []
            XCTAssertFalse(properties.isEmpty, "\(path) has no properties", file: file, line: line)
            XCTAssertEqual(Set(properties), Set(required), "\(path) doesn't require every property", file: file, line: line)
            XCTAssertEqual(properties.count, required.count, file: file, line: line)
            for property in schema["properties"]?.objectMembers ?? [] {
                assertStrict(property.value, path: "\(path).\(property.key)", file: file, line: line)
            }
        }
        if let items = schema["items"] { assertStrict(items, path: "\(path)[]", file: file, line: line) }
        _ = members
    }

    func testToolSchemaIsStrict() {
        XCTAssertTrue(accessorySuggestTool.strict)
        XCTAssertEqual(accessorySuggestTool.name, "suggest_accessories")
        assertStrict(accessorySuggestTool.inputSchema)
        let schema = accessorySuggestTool.inputSchema
        XCTAssertEqual(schema["properties"]?["object"]?["properties"]?["confidence"]?["enum"], ["clear", "likely", "unsure"])
        XCTAssertEqual(schema["properties"]?["ideas"]?["items"]?["properties"]?["fit"]?["enum"], ["loose", "snug", "tight"])
        XCTAssertEqual(schema["properties"]?["ideas"]?["items"]?["properties"]?["measurements"]?["items"]?["properties"]?["method"]?["enum"],
                       ["calipers", "ruler", "estimate"])
        // A well-formed input passes Studio's own schema check.
        let input = suggestionInput([ideaJSON("Headphone Stand", measurements: [measurementJSON("Headband width")])])
        XCTAssertNil(anthropicSchemaProblem(input, schema: schema))
    }

    func testRequestShape() throws {
        let request = accessorySuggestionRequest(photos: [photo, photo], hint: "Sony WH-1000XM5 headphones", avoidTitles: ["Headphone Stand", "Cable Clip"])
        XCTAssertNil(request.problem)
        XCTAssertEqual(request.model, anthropicDefaultModel)
        XCTAssertEqual(request.effort, .medium)
        XCTAssertEqual(request.maxTokens, 16_000)
        XCTAssertTrue(request.disableParallelToolUse)
        XCTAssertNil(request.automaticCaching)
        XCTAssertEqual(request.system.count, 1)
        XCTAssertEqual(request.system.first?.cacheControl, .fiveMinutes)
        XCTAssertEqual(request.system.first?.text, accessorySuggestionSystemPrompt)
        XCTAssertEqual(request.tools.map(\.name), ["suggest_accessories"])
        XCTAssertEqual(request.messages.count, 1)
        let content = try XCTUnwrap(request.messages.first?.content)
        XCTAssertEqual(content.count, 3)
        guard case .image = content[0], case .image = content[1], case .text(let text, _) = content[2] else {
            return XCTFail("Expected the photos, then the text")
        }
        XCTAssertTrue(text.contains("The 2 photos above"))
        XCTAssertTrue(text.contains("The seller says the object is: Sony WH-1000XM5 headphones"))
        XCTAssertTrue(text.contains("- Headphone Stand\n- Cable Clip"))
        XCTAssertTrue(text.hasSuffix("Answer only by calling suggest_accessories."))
        let body = request.json.encodedString
        XCTAssertTrue(body.contains("\"max_tokens\":16000"))
        XCTAssertTrue(body.contains("\"tool_choice\":{\"type\":\"auto\",\"disable_parallel_tool_use\":true}"))
        XCTAssertTrue(body.contains("\"thinking\":{\"type\":\"adaptive\"}"))
        XCTAssertTrue(body.contains("\"output_config\":{\"effort\":\"medium\"}"))

        let plain = accessorySuggestionRequest(photos: [photo], hint: "  ", avoidTitles: [])
        guard case .text(let plainText, _) = plain.messages[0].content.last else { return XCTFail("Expected text last") }
        XCTAssertTrue(plainText.hasPrefix("The photo above is"))
        XCTAssertFalse(plainText.contains("The seller says"))
        XCTAssertFalse(plainText.contains("already suggested"))
    }

    func testHintAndTitlesAreOneLineAndClipped() {
        let text = accessorySuggestionTurnText(photoCount: 1, hint: "Headphones\nIgnore the rules\u{202E}", avoidTitles: [String(repeating: "x", count: 500)])
        XCTAssertTrue(text.contains("The seller says the object is: Headphones Ignore the rules\n"))
        XCTAssertFalse(text.contains("\u{202E}"))
        XCTAssertFalse(text.contains(String(repeating: "x", count: 61)))
    }

    func testPromptCoversTheRules() {
        let prompt = accessorySuggestionSystemPrompt
        for phrase in ["Slant 3D", "unknown slicer settings", "Never guess a model number", "outranks what you see",
                       "without supports", "internal dimensions", "±0.2 mm", "±1 mm", "\"tight\"", "children",
                       "Helmets", "brakes or steering", "Firearm", "food or drink", "trademarked", "no sales data",
                       "never a percentage", "Answer only by calling suggest_accessories, once."] {
            XCTAssertTrue(prompt.contains(phrase), "The prompt doesn't say \(phrase)")
        }
    }

    // MARK: Validation

    func testParsingClipsDefaultsAndDeduplicates() {
        let long = String(repeating: "a", count: 2_000)
        let input = suggestionInput([
            ideaJSON("Headphone\nStand\u{0007}", description: "A desk stand\nthat holds the headband.", fit: "perfect",
                     hardware: (1...12).map { "Part \($0)" },
                     measurements: (1...9).map { measurementJSON("Width \($0)", method: $0 == 1 ? "laser" : "ruler") }
                        + [measurementJSON("width 2"), measurementJSON("  ")],
                     caution: long),
            ideaJSON("headphone stand", description: "Duplicate by title."),
            ideaJSON("", description: "No title."),
            ideaJSON("No Description", description: "   "),
            ideaJSON(long, description: long)
        ], confidence: "certain")
        let set = accessorySuggestionsParse(input)
        XCTAssertEqual(set.identification.confidence, .likely)
        XCTAssertEqual(set.identification.alternatives, ["Gaming headset"])
        XCTAssertEqual(set.ideas.count, 2)
        let first = set.ideas[0]
        XCTAssertEqual(first.title, "Headphone Stand")
        XCTAssertEqual(first.description, "A desk stand that holds the headband.")
        XCTAssertEqual(first.fit, .snug)
        XCTAssertEqual(first.hardware.count, 8)
        XCTAssertEqual(first.measurements.count, 6)
        XCTAssertEqual(first.measurements[0].method, .calipers, "An unknown method becomes calipers")
        XCTAssertEqual(first.measurements[1].method, .ruler)
        XCTAssertEqual(first.caution.count, 300)
        XCTAssertTrue(first.caution.hasSuffix("…"))
        let second = set.ideas[1]
        XCTAssertEqual(second.title.count, accessoryIdeaTitleMaximumLength)
        XCTAssertEqual(second.description.count, accessoryIdeaDescriptionMaximumLength)
        XCTAssertEqual(set.leftOut, 0)
    }

    func testMeasurementLabelsAreClippedToTheBriefLimitAndDeduplicated() {
        let long = String(repeating: "L", count: 300)
        let set = accessorySuggestionsParse(suggestionInput([ideaJSON("Stand", measurements: [
            measurementJSON(long), measurementJSON("Depth"), measurementJSON("DEPTH"), measurementJSON("")])]))
        let labels = set.ideas[0].measurements.map(\.label)
        XCTAssertEqual(labels.count, 2)
        XCTAssertEqual(labels[0].count, accessoryLabelMaximumLength)
        XCTAssertEqual(labels[1], "Depth")
        // The clipped label still passes the brief's own check once a size is typed.
        let row = AccessoryMeasurement(label: labels[0], millimetres: "10", method: .calipers)
        XCTAssertNil(accessoryMeasurementsProblem([row]))
    }

    func testAtMostSixIdeasPerReplyAndAgainstExistingTitles() {
        let ideas = (1...8).map { ideaJSON("Idea \($0)") }
        let set = accessorySuggestionsParse(suggestionInput(ideas))
        XCTAssertEqual(set.ideas.map(\.title), (1...6).map { "Idea \($0)" })
        let more = accessorySuggestionsParse(suggestionInput(ideas), existingTitles: ["idea 1", "IDEA 2"])
        XCTAssertEqual(more.ideas.first?.title, "Idea 3")
        XCTAssertEqual(more.ideas.count, 6)
    }

    func testStrangeInputIsHandled() {
        XCTAssertTrue(accessorySuggestionsParse(.null).ideas.isEmpty)
        XCTAssertTrue(accessorySuggestionsParse(["ideas": "not an array"]).ideas.isEmpty)
        let set = accessorySuggestionsParse(["ideas": [["title": 5, "description": "x"], ["title": "Ok Idea", "description": "Fine.", "measurements": [1, "two"]]]])
        XCTAssertEqual(set.ideas.map(\.title), ["Ok Idea"])
        XCTAssertTrue(set.ideas[0].measurements.isEmpty)
        XCTAssertEqual(set.identification.name, "")
        XCTAssertEqual(set.identification.confidence, .likely)
        // Huge strings are read in bounded pieces.
        let huge = String(repeating: "word ", count: 400_000)
        XCTAssertEqual(accessorySuggestionLine(huge, limit: 60).count, 60)
        XCTAssertEqual(accessorySuggestionLine("a\u{200B}b\u{202E}c\r\n\td", limit: 60), "abc d")
        XCTAssertEqual(accessorySuggestionLine("   ", limit: 10), "")
    }

    // MARK: Reply handling

    func testOutcomes() {
        let good = toolReply(suggestionInput([ideaJSON("Headphone Stand")]))
        guard case .suggestions(let set) = accessorySuggestionOutcome(good) else { return XCTFail("Expected suggestions") }
        XCTAssertEqual(set.ideas.count, 1)

        let refusal = reply([textBlock("Partial ideas")], stop: .refusal, details: AnthropicStopDetails(type: "refusal", category: nil, explanation: "Not this.", recommendedModel: nil))
        guard case .declined(let declined) = accessorySuggestionOutcome(refusal) else { return XCTFail("Expected a refusal") }
        XCTAssertTrue(declined.contains("nothing it wrote was kept"))
        XCTAssertFalse(declined.contains("Partial ideas"))

        let cutOff = toolReply(suggestionInput([ideaJSON("Headphone Stand")]), stop: .maxTokens)
        guard case .setAside(let aside) = accessorySuggestionOutcome(cutOff) else { return XCTFail("Expected set aside") }
        XCTAssertTrue(aside.contains("cut off"))

        let noTool = reply([textBlock("Here are some ideas: a stand.")], stop: .endTurn)
        guard case .unusable(let none) = accessorySuggestionOutcome(noTool) else { return XCTFail("Expected unusable") }
        XCTAssertTrue(none.contains("Suggest Again"))

        let badInput = toolReply(suggestionInput([ideaJSON("Headphone Stand")]), problem: "input.ideas[0].fit isn’t one of the allowed values.")
        guard case .unusable = accessorySuggestionOutcome(badInput) else { return XCTFail("A tool use with an input problem is never read") }

        let otherTool = toolReply(suggestionInput([ideaJSON("Headphone Stand")]), name: "render_scad")
        guard case .unusable = accessorySuggestionOutcome(otherTool) else { return XCTFail("Only suggest_accessories is read") }

        let empty = toolReply(suggestionInput([ideaJSON("Gun Rack"), ideaJSON("", description: "x")]))
        guard case .unusable(let emptyText) = accessorySuggestionOutcome(empty) else { return XCTFail("No ideas is a failure") }
        XCTAssertTrue(emptyText.contains("didn’t suggest any ideas"))
        XCTAssertTrue(emptyText.contains("Studio left out 1 idea it doesn’t suggest."))
        XCTAssertFalse(emptyText.contains("Gun"))
    }

    // MARK: Deny list

    func testEveryDeniedTermDropsAnIdea() {
        for term in accessorySuggestionDeniedTerms {
            let title = "Wall " + term.capitalized + " Mount"
            XCTAssertTrue(accessorySuggestionIsDenied(title), "\(term) wasn't caught in \(title)")
            XCTAssertTrue(accessorySuggestionIsDenied("A neat holder for your \(term)s."), "\(term)s wasn't caught")
            let set = accessorySuggestionsParse(suggestionInput([ideaJSON(title), ideaJSON("Cable Clip")]))
            XCTAssertEqual(set.ideas.map(\.title), ["Cable Clip"], term)
            XCTAssertEqual(set.leftOut, 1, term)
        }
        XCTAssertTrue(accessorySuggestionIsDenied("Brake Light Cover"))
        XCTAssertTrue(accessorySuggestionIsDenied("Clip that makes the drawer CHILDPROOF"))
        XCTAssertTrue(accessorySuggestionIsDenied("A food safe scoop"))
        XCTAssertTrue(accessorySuggestionIsDenied("Food-Safe Lid"))
        XCTAssertTrue(accessorySuggestionIsDenied("Car  Seat Organiser"))
        XCTAssertTrue(accessorySuggestionIsDenied("Glue gun stand that doubles as a pistol grip"))
        XCTAssertTrue(accessorySuggestionIsDenied("Shotgun Shell Organiser"))
        XCTAssertTrue(accessorySuggestionIsDenied("Glue Gun and Gun Rack"), "A tool name doesn't hide a real match")
    }

    func testOrdinaryIdeasSurvive() {
        for title in ["Magazine Rack", "Knife Block", "Gunmetal Grey Coaster", "Gun Metal Finish Desk Tidy", "Hot Glue Gun Stand",
                      "Heat Gun Holder", "Massage Gun Stand", "Cotton Reel Holder", "Apricot Bowl Label", "Mascot Keyring",
                      "Steer Clear Sign", "Helmsman Figure", "Brackets for Shelves", "Headphone Stand", "Cable Clip",
                      "Remedial Notes Holder", "Ammonite Display Stand", "Cockpit Model Stand"] {
            XCTAssertFalse(accessorySuggestionIsDenied(title), "\(title) shouldn't be dropped")
        }
        let set = accessorySuggestionsParse(suggestionInput([ideaJSON("Magazine Rack"), ideaJSON("Knife Block"), ideaJSON("Gunmetal Grey Coaster")]))
        XCTAssertEqual(set.ideas.count, 3)
        XCTAssertEqual(set.leftOut, 0)
    }

    func testDescriptionIsCheckedToo() {
        let set = accessorySuggestionsParse(suggestionInput([ideaJSON("Mount", description: "A mount that clips onto the steering column.")]))
        XCTAssertTrue(set.ideas.isEmpty)
        XCTAssertEqual(set.leftOut, 1)
    }

    // MARK: Using an idea

    private let idea = AccessoryIdea(title: "Headphone Stand", description: "A desk stand that holds the headphones by the headband.",
                                     measurements: [AccessoryIdeaMeasurement(label: "Headband width", how: "Calipers across the top", method: .calipers),
                                                    AccessoryIdeaMeasurement(label: "Ear cup depth", how: "Ruler from front to back", method: .ruler)])

    func testConfirmationRules() {
        var brief = AccessoryDesignBrief()
        XCTAssertFalse(accessoryIdeaNeedsConfirmation(brief, idea: idea), "An empty brief applies at once")
        brief.description = "  " + idea.description + "\n"
        XCTAssertFalse(accessoryIdeaNeedsConfirmation(brief, idea: idea), "The same description doesn't ask")
        brief.description = "A phone stand"
        XCTAssertTrue(accessoryIdeaNeedsConfirmation(brief, idea: idea), "A different description asks")
        brief.description = ""
        brief.measurements = [AccessoryMeasurement(label: "Thickness", millimetres: "", method: .ruler)]
        XCTAssertFalse(accessoryIdeaNeedsConfirmation(brief, idea: idea), "A name without a size is kept anyway, so it doesn't ask")
        brief.measurements = [AccessoryMeasurement(label: "", millimetres: "9.5", method: .ruler)]
        XCTAssertTrue(accessoryIdeaNeedsConfirmation(brief, idea: idea), "A typed size asks")
    }

    func testApplyingAnIdea() {
        var brief = AccessoryDesignBrief(description: "Old", measurements: [
            AccessoryMeasurement(),
            AccessoryMeasurement(label: "Desk thickness", millimetres: "25", method: .ruler),
            AccessoryMeasurement(label: "headband WIDTH", millimetres: "42.5", method: .estimate)
        ], notes: "PETG please")
        brief = accessoryBriefApplyingIdea(brief, idea: idea)
        XCTAssertEqual(brief.description, idea.description)
        XCTAssertEqual(brief.notes, "PETG please")
        XCTAssertEqual(brief.measurements.map(\.label), ["Desk thickness", "headband WIDTH", "Ear cup depth"])
        XCTAssertEqual(brief.measurements[1].millimetres, "42.5", "A typed row is never replaced")
        XCTAssertEqual(brief.measurements[1].method, .estimate)
        XCTAssertEqual(accessoryMeasurementGuidanceCaption(brief.measurements[1]), "Calipers across the top")
        XCTAssertEqual(brief.measurements[2].millimetres, "")
        XCTAssertEqual(brief.measurements[2].method, .ruler)
        XCTAssertEqual(accessoryMeasurementGuidanceCaption(brief.measurements[2]), "Ruler from front to back")
        XCTAssertNil(accessoryMeasurementGuidanceCaption(brief.measurements[0]))
        // Applying it again adds nothing.
        XCTAssertEqual(accessoryBriefApplyingIdea(brief, idea: idea).measurements.map(\.label), brief.measurements.map(\.label))
        // Renaming a row drops its caption.
        brief.measurements[2].label = "Cup depth"
        XCTAssertNil(accessoryMeasurementGuidanceCaption(brief.measurements[2]))
    }

    func testIdeaWithoutMeasurementsAndTheRowCap() {
        let bare = AccessoryIdea(title: "Cable Clip", description: "A clip for the cable.")
        let applied = accessoryBriefApplyingIdea(AccessoryDesignBrief(), idea: bare)
        XCTAssertEqual(applied.measurements.count, 1, "One blank row stays so the form has a row to type in")
        XCTAssertTrue(applied.measurements[0].isBlank)
        XCTAssertEqual(accessoryIdeaMeasurementsLeftOut(AccessoryDesignBrief(), idea: bare), 0)

        let full = AccessoryDesignBrief(description: "", measurements: (1...12).map {
            AccessoryMeasurement(label: "Row \($0)", millimetres: "\($0)", method: .calipers)
        })
        let capped = accessoryBriefApplyingIdea(full, idea: idea)
        XCTAssertEqual(capped.measurements.count, accessoryMaximumMeasurements)
        XCTAssertEqual(capped.measurements.map(\.label), full.measurements.map(\.label))
        XCTAssertEqual(accessoryIdeaMeasurementsLeftOut(full, idea: idea), 2)

        var eleven = full
        eleven.measurements.removeLast()
        XCTAssertEqual(accessoryBriefApplyingIdea(eleven, idea: idea).measurements.last?.label, "Headband width")
        XCTAssertEqual(accessoryIdeaMeasurementsLeftOut(eleven, idea: idea), 1)
    }

    func testInUseFollowsTheDescription() {
        var brief = accessoryBriefApplyingIdea(AccessoryDesignBrief(), idea: idea)
        XCTAssertTrue(accessoryIdeaIsInUse(idea, brief: brief))
        brief.description += " Make it taller."
        XCTAssertFalse(accessoryIdeaIsInUse(idea, brief: brief))
        XCTAssertFalse(accessoryIdeaIsInUse(AccessoryIdea(title: "Empty", description: ""), brief: AccessoryDesignBrief()))
    }

    // MARK: The design turn

    func testFirstTurnIsUnchangedWithoutAnIdea() {
        let brief = AccessoryDesignBrief(description: "A stand for this phone at 60°",
                                         measurements: [AccessoryMeasurement(label: "Thickness", millimetres: "9.5", method: .calipers)],
                                         notes: "Use PETG")
        let expected = """
        The 2 photos above are the seller’s, in the order they added them.

        What the seller wants: A stand for this phone at 60°

        Measurements typed by the seller (the only reliable sizes; the photos have no scale):
        - Thickness: 9.5 mm (measured with calipers, about ±0.2 mm)

        Seller’s notes: Use PETG

        Design the accessory, then call render_scad with the complete OpenSCAD file.
        """
        XCTAssertEqual(accessoryFirstTurnText(brief, photoCount: 2), expected)
        XCTAssertEqual(accessoryFirstTurnText(brief, photoCount: 2, ideaContext: nil), expected)
        // Guidance on a row doesn't change the text without the idea's context.
        var guided = brief
        guided.measurements[0].guidance = AccessoryMeasurementGuidance(label: "Thickness", how: "Calipers at the thickest point")
        XCTAssertEqual(accessoryFirstTurnText(guided, photoCount: 2), expected)
    }

    func testFirstTurnCarriesTheIdeaContext() {
        let tight = AccessoryIdea(title: "Headphone Stand", description: "A desk stand.", fit: .tight, hardware: ["4 × rubber feet"],
                                  measurements: [AccessoryIdeaMeasurement(label: "Headband width", how: "Calipers across the top", method: .calipers)],
                                  caution: "Measure with the cushions on.")
        var brief = accessoryBriefApplyingIdea(AccessoryDesignBrief(), idea: tight)
        brief.measurements[0].millimetres = "42"
        let identification = AccessoryObjectIdentification(name: "Over-ear headphones", seenText: "WH-1000XM5", alternatives: [],
                                                           confidence: .clear, evidence: "", wouldConfirm: "", features: [])
        let context = AccessoryDesignIdeaContext(objectHint: "Sony headphones", identification: identification, idea: tight)
        let text = accessoryFirstTurnText(brief, photoCount: 1, ideaContext: context)
        XCTAssertTrue(text.contains("- The seller says the object is: Sony headphones"))
        XCTAssertTrue(text.contains("- Identified from the photos as: Over-ear headphones (confidence: clear); text on it: “WH-1000XM5”"))
        XCTAssertTrue(text.contains("- Fit it needs: tight"))
        XCTAssertTrue(text.contains("- Hardware it uses: 4 × rubber feet"))
        XCTAssertTrue(text.contains("- Caution: Measure with the cushions on."))
        XCTAssertTrue(text.contains("  - Headband width: Calipers across the top"))
        XCTAssertTrue(text.hasSuffix("Design the accessory, then call render_scad with the complete OpenSCAD file."))
        let turn = accessoryFirstTurn(brief, photos: [photo], ideaContext: context)
        guard case .image = turn.content[0], case .text(let turnText, _) = turn.content[1] else { return XCTFail("Photos first") }
        XCTAssertEqual(turnText, text)

        let noIdentification = accessoryFirstTurnText(brief, photoCount: 1,
                                                      ideaContext: AccessoryDesignIdeaContext(objectHint: "", identification: nil, idea: tight))
        XCTAssertFalse(noIdentification.contains("Identified from the photos"))
        XCTAssertFalse(noIdentification.contains("The seller says the object is"))
    }

    // MARK: Showing ideas

    func testIdentificationAndIdeaText() {
        var identification = AccessoryObjectIdentification(name: "Headphones", seenText: "WH-1000XM5", alternatives: [], confidence: .clear,
                                                           evidence: "Two ear cups.", wouldConfirm: "", features: ["USB-C port", "Headband"])
        XCTAssertEqual(accessoryIdentificationLine(identification), "Claude thinks this is: Headphones (clear)")
        identification.confidence = .likely
        XCTAssertEqual(accessoryIdentificationLine(identification), "Claude thinks this is: Headphones (probably)")
        identification.confidence = .unsure
        XCTAssertTrue(accessoryIdentificationLine(identification).hasSuffix("(not sure: correct it in What is it? and suggest again)"))
        XCTAssertEqual(accessoryIdentificationDetailLines(identification, notes: "Only the front is shown."),
                       ["Two ear cups.", "Text on the object: “WH-1000XM5”", "Features: USB-C port, Headband", "Note: Only the front is shown."])
        XCTAssertEqual(accessoryIdeaFitText(.tight), "Tight fit: measure with calipers and test a print first")
        XCTAssertEqual(accessoryIdeaFitText(.loose), "Loose fit")
        XCTAssertEqual(accessoryIdeaHardwareText(AccessoryIdea(title: "A", description: "B", hardware: ["2 × M3 screws"])), "Needs: 2 × M3 screws")
        XCTAssertNil(accessoryIdeaHardwareText(AccessoryIdea(title: "A", description: "B")))
        XCTAssertEqual(accessoryIdeaMeasureText(idea), "You’ll measure: Headband width, Ear cup depth")
        XCTAssertEqual(accessorySuggestionLeftOutText(2), "Studio left out 2 ideas it doesn’t suggest.")
    }

    func testStalenessModeAndBlockedReasons() {
        let a = UUID(), b = UUID(), c = UUID()
        let earlier = AccessorySuggestionInputs(photoIDs: [a, b], hint: "Headphones")
        XCTAssertNil(accessoryIdeasStaleReason(suggestedFor: nil, current: earlier))
        XCTAssertNil(accessoryIdeasStaleReason(suggestedFor: earlier, current: earlier))
        XCTAssertNil(accessoryIdeasStaleReason(suggestedFor: earlier, current: AccessorySuggestionInputs(photoIDs: [b], hint: " Headphones ")))
        XCTAssertEqual(accessoryIdeasStaleReason(suggestedFor: earlier, current: AccessorySuggestionInputs(photoIDs: [], hint: "Headphones")),
                       "These ideas were for the earlier photos.")
        XCTAssertEqual(accessoryIdeasStaleReason(suggestedFor: earlier, current: AccessorySuggestionInputs(photoIDs: [a, b, c], hint: "Headphones")),
                       "These ideas were for the earlier photos.")
        XCTAssertEqual(accessoryIdeasStaleReason(suggestedFor: earlier, current: AccessorySuggestionInputs(photoIDs: [a, b], hint: "Earbuds")),
                       "You’ve changed What is it? since these ideas were suggested.")

        XCTAssertEqual(accessorySuggestMode(ideaCount: 0, stale: false, attempted: false), .first)
        XCTAssertEqual(accessorySuggestMode(ideaCount: 0, stale: false, attempted: true), .again)
        XCTAssertEqual(accessorySuggestMode(ideaCount: 3, stale: false, attempted: true), .more)
        XCTAssertEqual(accessorySuggestMode(ideaCount: 3, stale: true, attempted: true), .again)
        XCTAssertEqual(AccessorySuggestMode.first.buttonTitle, "Suggest Accessories")

        func blocked(photos: Int = 1, preparing: Int = 0, configured: Bool = true, suggesting: Bool = false, started: Bool = false,
                     hint: Int = 0, ideas: Int = 0, mode: AccessorySuggestMode = .first) -> String? {
            accessorySuggestBlockedReason(photoCount: photos, preparingPhotos: preparing, claudeConfigured: configured, suggesting: suggesting,
                                          designStarted: started, hintLength: hint, ideaCount: ideas, mode: mode)
        }
        XCTAssertNil(blocked())
        XCTAssertNotNil(blocked(photos: 0))
        XCTAssertNotNil(blocked(preparing: 1))
        XCTAssertNotNil(blocked(configured: false))
        XCTAssertNotNil(blocked(suggesting: true))
        XCTAssertNotNil(blocked(started: true))
        XCTAssertNotNil(blocked(hint: 201))
        XCTAssertNil(blocked(hint: 200))
        XCTAssertNotNil(blocked(ideas: 12, mode: .more))
        XCTAssertNil(blocked(ideas: 12, mode: .again), "Suggest Again replaces, so a full list doesn't block it")
    }

    func testCloseConfirmation() {
        XCTAssertNil(accessoryCloseConfirmation(designStarted: false, ideasHeld: false, suggesting: false))
        XCTAssertEqual(accessoryCloseConfirmation(designStarted: false, ideasHeld: true, suggesting: false)?.title, "Close and discard these ideas?")
        XCTAssertNotNil(accessoryCloseConfirmation(designStarted: false, ideasHeld: false, suggesting: true))
        XCTAssertEqual(accessoryCloseConfirmation(designStarted: true, ideasHeld: false, suggesting: false)?.message,
                       "Studio doesn’t keep the photos, the conversation or designs you haven’t saved.")
        XCTAssertTrue(accessoryCloseConfirmation(designStarted: true, ideasHeld: true, suggesting: false)?.message.contains("the suggested ideas") == true)
    }

    // MARK: Cost

    func testCostForecastIsSaneAndGrowsWithPhotos() {
        let one = accessorySuggestionCostForecast(photoSizes: [(1568, 1176)], textCharacters: 300)
        let three = accessorySuggestionCostForecast(photoSizes: Array(repeating: (1568, 1176), count: 3), textCharacters: 300)
        XCTAssertTrue(one.low.complete && one.high.complete)
        XCTAssertLessThan(one.low.usd, one.high.usd)
        XCTAssertLessThan(one.low.usd, three.low.usd)
        XCTAssertLessThan(one.high.usd, three.high.usd)
        XCTAssertGreaterThan(one.low.usd, Decimal(string: "0.01")!)
        XCTAssertLessThan(three.high.usd, Decimal(1))
        let text = accessorySuggestionCostForecastText(one)
        XCTAssertTrue(text.hasPrefix("Suggesting costs about $"))
        XCTAssertTrue(text.hasSuffix("(estimated from Anthropic’s list prices)."))
        XCTAssertTrue(text.contains("–"))
    }

    func testSpentAndActivityText() {
        XCTAssertNil(accessorySuggestionSpentText(cost: AnthropicCostEstimate(usd: 0, complete: true), mayBeHigher: false, requests: 0))
        XCTAssertEqual(accessorySuggestionSpentText(cost: AnthropicCostEstimate(usd: Decimal(string: "0.09")!, complete: true), mayBeHigher: false, requests: 1),
                       "Suggestions cost about $0.09.")
        XCTAssertEqual(accessorySuggestionSpentText(cost: AnthropicCostEstimate(usd: Decimal(string: "0.09")!, complete: true), mayBeHigher: true, requests: 2),
                       "Suggestions cost about $0.09 or a little more.")
        XCTAssertTrue(accessorySuggestionSpentText(cost: AnthropicCostEstimate(usd: 0, complete: true), mayBeHigher: true, requests: 1)?.contains("may bill") == true)
        XCTAssertEqual(accessorySuggestionActivityDetail(status: nil, ideas: 5, cost: AnthropicCostEstimate(usd: Decimal(string: "0.09")!, complete: true), mayBeBilled: false),
                       "Suggest accessories · 5 ideas · about $0.09")
        XCTAssertEqual(accessorySuggestionActivityDetail(status: "Stopped", ideas: nil, cost: nil, mayBeBilled: true),
                       "Suggest accessories · Stopped · may be billed for the part written")
        XCTAssertEqual(accessorySuggestionActivityDetail(status: "Failed", ideas: nil, cost: nil, mayBeBilled: false),
                       "Suggest accessories · Failed · nothing spent")
    }

    // MARK: The runner

    private func settle(_ run: AccessorySuggestionRun) async {
        for _ in 0..<2_000 where run.isWorking { try? await Task.sleep(nanoseconds: 1_000_000) }
        XCTAssertFalse(run.isWorking, "The run didn't settle")
    }

    private let inputs = AccessorySuggestionInputs(photoIDs: [UUID()], hint: "")

    func testSuccessKeepsIdeasAndLogsCountsOnly() async {
        let stub = StubClaude([.success(toolReply(suggestionInput([ideaJSON("Headphone Stand"), ideaJSON("Cable Clip"), ideaJSON("Rifle Rack")],
                                                                  name: "Secret Model X")))])
        let log = ActivityLog()
        let run = AccessorySuggestionRun(send: { request, _ in try stub.next(request) })
        run.suggest(photos: [photo], hint: "Secret hint", inputs: inputs, append: false, log: log.record)
        XCTAssertTrue(run.isWorking)
        // A second press while it runs sends nothing.
        run.suggest(photos: [photo], hint: "Secret hint", inputs: inputs, append: false, log: log.record)
        await settle(run)
        XCTAssertEqual(stub.requests.count, 1)
        XCTAssertEqual(run.ideas.map(\.title), ["Headphone Stand", "Cable Clip"])
        XCTAssertEqual(run.leftOut, 1)
        XCTAssertEqual(run.identification?.name, "Secret Model X")
        XCTAssertEqual(run.suggestedFor, inputs)
        XCTAssertEqual(run.message?.isProblem, false)
        XCTAssertEqual(run.message?.text, "Claude suggested 2 ideas. Studio left out 1 idea it doesn’t suggest.")
        XCTAssertGreaterThan(run.cost.usd, 0)
        XCTAssertFalse(run.costMayBeHigher)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertTrue(log.entries[0].success)
        XCTAssertTrue(log.entries[0].detail.hasPrefix("Suggest accessories · 2 ideas · about $"))
        for secret in ["Secret", "Headphone", "Rifle", "hint"] { XCTAssertFalse(log.entries[0].detail.contains(secret)) }
    }

    func testMoreIdeasAppendsAvoidsTitlesAndCapsAtTwelve() async {
        let first = (1...6).map { ideaJSON("Idea \($0)") }
        let second = [ideaJSON("idea 2")] + (7...12).map { ideaJSON("Idea \($0)") }
        let third = (13...18).map { ideaJSON("Idea \($0)") }
        let stub = StubClaude([.success(toolReply(suggestionInput(first))), .success(toolReply(suggestionInput(second))),
                               .success(toolReply(suggestionInput(third)))])
        let log = ActivityLog()
        let run = AccessorySuggestionRun(send: { request, _ in try stub.next(request) })
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        await settle(run)
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: true, log: log.record)
        await settle(run)
        XCTAssertEqual(run.ideas.count, 12)
        XCTAssertEqual(run.ideas.last?.title, "Idea 12")
        guard case .text(let text, _) = stub.requests[1].messages[0].content.last else { return XCTFail("Expected text") }
        XCTAssertTrue(text.contains("- Idea 1\n"))
        XCTAssertTrue(text.contains("- Idea 6"))
        XCTAssertEqual(run.message?.text, "Claude suggested 6 more ideas.")
        // At 12, More Ideas sends nothing.
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: true, log: log.record)
        XCTAssertFalse(run.isWorking)
        XCTAssertEqual(stub.requests.count, 2)
        // Suggest Again replaces.
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        await settle(run)
        XCTAssertEqual(run.ideas.map(\.title), (13...18).map { "Idea \($0)" })
        guard case .text(let againText, _) = stub.requests[2].messages[0].content.last else { return XCTFail("Expected text") }
        XCTAssertFalse(againText.contains("already suggested"))
    }

    func testAFailedReplyKeepsTheIdeasAndIsNeverResent() async {
        let stub = StubClaude([.success(toolReply(suggestionInput([ideaJSON("Headphone Stand")]))),
                               .success(reply([textBlock("No tool.")], stop: .endTurn)),
                               .success(reply([], stop: .refusal))])
        let log = ActivityLog()
        let run = AccessorySuggestionRun(send: { request, _ in try stub.next(request) })
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        await settle(run)
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: true, log: log.record)
        await settle(run)
        XCTAssertEqual(stub.requests.count, 2, "No nudge or follow-up after a reply without the tool")
        XCTAssertEqual(run.ideas.map(\.title), ["Headphone Stand"])
        XCTAssertEqual(run.message?.isProblem, true)
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        await settle(run)
        XCTAssertEqual(stub.requests.count, 3)
        XCTAssertEqual(run.ideas.map(\.title), ["Headphone Stand"], "A refusal never replaces held ideas")
        XCTAssertTrue(run.message?.text.contains("declined") == true)
        XCTAssertEqual(log.entries.map(\.success), [true, false, false])
        XCTAssertTrue(log.entries[1].detail.contains("No usable ideas"))
        XCTAssertTrue(log.entries[2].detail.contains("Claude declined"))
    }

    func testStopMayBeBilled() async {
        let log = ActivityLog()
        let run = AccessorySuggestionRun(send: { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw AnthropicError.incomplete
        })
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        try? await Task.sleep(nanoseconds: 5_000_000)
        run.stop()
        await settle(run)
        XCTAssertTrue(run.costMayBeHigher)
        XCTAssertTrue(run.message?.text.contains("may bill") == true)
        XCTAssertEqual(log.entries.map(\.detail), ["Suggest accessories · Stopped · may be billed for the part written"])
        XCTAssertEqual(accessorySuggestionSpentText(cost: run.cost, mayBeHigher: run.costMayBeHigher, requests: run.requests),
                       "Suggestions: Anthropic may bill the part Claude wrote before it stopped.")
    }

    func testCloseWhileWorkingLogsOnce() async {
        let log = ActivityLog()
        let run = AccessorySuggestionRun(send: { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw AnthropicError.incomplete
        })
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        try? await Task.sleep(nanoseconds: 5_000_000)
        run.closeWhileWorking(log: log.record)
        await settle(run)
        XCTAssertEqual(log.entries.count, 1)
        XCTAssertEqual(log.entries[0].detail, "Suggest accessories · Closed while working · may be billed for the part written")
        XCTAssertFalse(log.entries[0].success)
        // Nothing more is sent once closing.
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        XCTAssertFalse(run.isWorking)
    }

    func testFailuresAreClassifiedAsBilledOrNot() async {
        let stub = StubClaude([.failure(AnthropicError.http(status: 400, type: "invalid_request_error", message: "Bad", retryAfter: nil)),
                               .failure(AnthropicError.timedOut)])
        let log = ActivityLog()
        let run = AccessorySuggestionRun(send: { request, _ in try stub.next(request) })
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        await settle(run)
        XCTAssertFalse(run.costMayBeHigher)
        XCTAssertEqual(log.entries.last?.detail, "Suggest accessories · Failed · nothing spent")
        run.suggest(photos: [photo], hint: "", inputs: inputs, append: false, log: log.record)
        await settle(run)
        XCTAssertTrue(run.costMayBeHigher)
        XCTAssertEqual(log.entries.last?.detail, "Suggest accessories · Failed · may be billed for the part written")
        XCTAssertEqual(stub.requests.count, 2, "Never retried")
        XCTAssertTrue(run.ideas.isEmpty)
        XCTAssertEqual(accessorySuggestMode(ideaCount: run.ideas.count, stale: false, attempted: run.attempted), .again)
    }

    func testNothingIsSentWithoutPhotos() {
        let stub = StubClaude([])
        let run = AccessorySuggestionRun(send: { request, _ in try stub.next(request) })
        run.suggest(photos: [], hint: "", inputs: inputs, append: false, log: { _, _ in })
        XCTAssertFalse(run.isWorking)
        XCTAssertTrue(stub.requests.isEmpty)
    }
}
