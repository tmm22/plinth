import Foundation

// MARK: - Suggest Accessories
//
// A step before Design an Accessory from a Photo: Claude (Opus 5.5) looks at the seller's photos, says what the object
// is and suggests accessories the seller could sell for it, through one strict tool (`suggest_accessories`). Each press
// of Suggest Accessories, Suggest Again or More Ideas is one request: never retried, never resent, with no automatic
// follow-up. Studio validates and clips what comes back, and drops ideas a small deny list catches, whatever the prompt
// said. Picking an idea fills the brief (`accessoryBriefApplyingIdea`); the design itself still starts only with Start
// Design. The ideas live in the sheet's memory and go when it closes; Activity gets counts, cost and status only.

let accessorySuggestToolName = "suggest_accessories"
/// Reply limit per suggestion request (adaptive thinking at medium effort plus up to six ideas).
let accessorySuggestionMaxTokens = 16_000
/// Ideas kept from one reply.
let accessorySuggestionMaximumIdeasPerReply = 6
/// Ideas the sheet keeps in all (More Ideas appends up to this).
let accessorySuggestionMaximumIdeas = 12
let accessorySuggestionMaximumMeasurements = 6
let accessorySuggestionMaximumHardware = 8
let accessorySuggestionMaximumAlternatives = 3
let accessorySuggestionMaximumFeatures = 8
/// The seller's "What is it?" hint.
let accessoryObjectHintMaximumLength = 200
let accessoryIdeaTitleMaximumLength = 60
let accessoryIdeaDescriptionMaximumLength = 500

// MARK: Values

enum AccessoryIdentificationConfidence: String, CaseIterable, Equatable, Sendable {
    case clear, likely, unsure
}

enum AccessoryIdeaFit: String, CaseIterable, Equatable, Sendable {
    case loose, snug, tight
}

/// What Claude thinks the object is. Display only, apart from the design turn's context.
struct AccessoryObjectIdentification: Equatable, Sendable {
    var name: String
    /// Brand or model text Claude read in the photos, copied exactly; empty when none.
    var seenText: String
    var alternatives: [String]
    var confidence: AccessoryIdentificationConfidence
    var evidence: String
    var wouldConfirm: String
    var features: [String]
}

/// A measurement an idea needs: the label, where and how to take it, and the tool.
struct AccessoryIdeaMeasurement: Equatable, Sendable {
    var label: String
    var how: String
    var method: AccessoryMeasurementMethod
}

struct AccessoryIdea: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var description: String
    var whoWantsIt: String
    var fit: AccessoryIdeaFit
    var hardware: [String]
    var measurements: [AccessoryIdeaMeasurement]
    var caution: String

    init(id: UUID = UUID(), title: String, description: String, whoWantsIt: String = "", fit: AccessoryIdeaFit = .snug,
         hardware: [String] = [], measurements: [AccessoryIdeaMeasurement] = [], caution: String = "") {
        self.id = id
        self.title = title
        self.description = description
        self.whoWantsIt = whoWantsIt
        self.fit = fit
        self.hardware = hardware
        self.measurements = measurements
        self.caution = caution
    }
}

/// One reply, validated.
struct AccessorySuggestionSet: Equatable, Sendable {
    var identification: AccessoryObjectIdentification
    var ideas: [AccessoryIdea]
    var notes: String
    /// Ideas the deny list dropped (their text is never shown).
    var leftOut: Int
}

// MARK: Prompt and tool

let accessorySuggestionSystemPrompt = """
You suggest 3D-printable accessories that a seller could make and sell for the object in their photos. The seller \
sells 3D-printed products; Slant 3D prints them on demand on FDM printers whose slicer settings aren't published, so \
every idea must suit FDM printing with unknown slicer settings.

Identifying the object
- Say honestly what the object is. Give a make and model only when the photos show them clearly (a readable logo, \
label or model number). Copy any brand or model text you can read exactly into seen_text, and leave it empty when \
there is none. Never guess a model number.
- If the seller says what the object is, that outranks what you see: use it, and say in evidence if the photos seem \
to disagree.
- confidence is "clear", "likely" or "unsure", never a percentage. Say "unsure" rather than guess, list up to 3 \
alternatives, and say in would_confirm what would settle it, such as "a photo of the label underneath". Leave \
would_confirm empty when it is clear.
- In features, list what matters for accessories: ports, buttons, vents, curves, edges, flat faces and mounting points.

Choosing ideas
- Suggest accessories a buyer of this object would want and pay for. Order them best first: most useful to buyers, \
then easiest to print.
- Each idea must print on an FDM printer without supports, ideally as one part with no hardware. If it needs hardware \
(screws, magnets, rubber feet), list it in hardware, with sizes, such as "2 × M3 screws" or "4 × 6×2 mm magnets".
- Each idea must be designable from the seller's photos plus measurements they can take with calipers or a ruler. \
Don't propose anything that needs the object's internal dimensions, its electronics, threads that match a \
proprietary part, or tolerances finer than about ±0.2 mm.
- Prefer ideas that tolerate ±1 mm: parts often print 0.1–0.3 mm oversize. fit is "loose" when a millimetre or more \
either way is fine, "snug" for a fit within about 1 mm, and "tight" when it must fit within about 0.5 mm (calipers \
needed, and the seller should test a print first).
- Photos have no scale, so list the measurements the seller must take for each idea: only those the design needs, \
usually 1–5. Each has a short, concrete label (such as "Headband width at the top"), where and how to measure it in \
how (such as "Calipers across the widest point, with the ear cushions on"), and the tool in method: "calipers", \
"ruler" or "estimate".
- Put anything the seller should know about an idea in caution, such as "Fit depends on the case; measure with the \
case on" or "Outdoor use: suggest PETG or ASA". Leave it empty when there is nothing.
- Suggest 3 to 6 ideas. Fewer good ideas are better than unsuitable ones; suggest none if nothing suits.
- If the seller lists ideas already suggested, don't repeat them or close variants of them.

Never suggest
- Anything that holds a person's or a pet's weight, or restrains a person or a pet.
- Products for children (in the US these need lab testing and certificates).
- Helmets or other protective gear; parts for a vehicle's controls, brakes or steering; medical devices, or anything \
with a medical or health claim.
- Firearm parts or accessories, anything designed to harm or that could be mistaken for a weapon, or drug \
paraphernalia.
- Cups, utensils or anything whose purpose is contact with food or drink.
- Replicas of trademarked designs, logos or brand-shaped geometry.

Writing
- title is 2–6 words in Title Case and describes the function, never a brand, such as "Stand for Over-Ear Headphones". \
Naming compatibility with a brand is the seller's decision.
- description is one or two sentences written as a design instruction, such as "A desk stand that holds the \
headphones by the headband, with a wide base". It becomes the brief for designing the part.
- who_wants_it is one sentence on who would buy it. You have no sales data: never claim demand, popularity or sales \
figures.
- Never call an idea strong, safe, approved or guaranteed, never say it fits perfectly, and never give strength \
figures.
- Put anything else the seller should know, such as "these photos show only the front", in notes, or leave it empty.

Answer only by calling suggest_accessories, once.
"""

private func accessoryStringSchema(_ description: String) -> AnthropicJSON {
    ["type": "string", "description": .string(description)]
}

private func accessoryStringArraySchema(_ description: String) -> AnthropicJSON {
    ["type": "array", "items": ["type": "string"], "description": .string(description)]
}

/// Strict: every object has `additionalProperties: false` and lists every property as required. There are no length or
/// count limits in the schema (strict tools don't support them); Studio clips and validates instead.
let accessorySuggestTool = AnthropicTool(
    name: accessorySuggestToolName,
    description: "Say what the object in the seller's photos is and suggest 3D-printable accessories the seller could make and sell for it, best first. Studio shows the ideas to the seller, who may pick one to design.",
    inputSchema: [
        "type": "object",
        "properties": [
            "object": [
                "type": "object",
                "properties": [
                    "name": accessoryStringSchema("A generic best guess, such as \"Over-ear wireless headphones\"."),
                    "seen_text": accessoryStringSchema("Brand or model text readable in the photos, copied exactly; empty if none. Never guessed."),
                    "alternatives": accessoryStringArraySchema("Up to 3 other things it could be."),
                    "confidence": ["type": "string", "enum": ["clear", "likely", "unsure"], "description": "How sure you are, in words."],
                    "evidence": accessoryStringSchema("One line on what in the photos supports the guess."),
                    "would_confirm": accessoryStringSchema("What would settle it, such as \"a photo of the label underneath\"; empty if clear."),
                    "features": accessoryStringArraySchema("What matters for accessories: ports, buttons, curves, mounting points.")
                ],
                "required": ["name", "seen_text", "alternatives", "confidence", "evidence", "would_confirm", "features"],
                "additionalProperties": false
            ],
            "ideas": [
                "type": "array",
                "description": "3 to 6 ideas, best first; fewer rather than unsuitable ones.",
                "items": [
                    "type": "object",
                    "properties": [
                        "title": accessoryStringSchema("2–6 words in Title Case describing the function, with no brand name."),
                        "description": accessoryStringSchema("One or two sentences of what to make, written as a design instruction."),
                        "who_wants_it": accessoryStringSchema("One sentence on who would buy it. No demand or sales claims."),
                        "fit": ["type": "string", "enum": ["loose", "snug", "tight"], "description": "How closely it must fit the object; tight means within about 0.5 mm."],
                        "hardware": accessoryStringArraySchema("Hardware needed, such as \"2 × M3 screws\"; empty if none."),
                        "measurements": [
                            "type": "array",
                            "description": "Only the measurements the design needs, usually 1–5.",
                            "items": [
                                "type": "object",
                                "properties": [
                                    "label": accessoryStringSchema("Short and concrete, such as \"Headband width at the top\"."),
                                    "how": accessoryStringSchema("Where and how to measure it."),
                                    "method": ["type": "string", "enum": ["calipers", "ruler", "estimate"], "description": "The tool the seller should use."]
                                ],
                                "required": ["label", "how", "method"],
                                "additionalProperties": false
                            ]
                        ],
                        "caution": accessoryStringSchema("Anything the seller should know about this idea; empty if none.")
                    ],
                    "required": ["title", "description", "who_wants_it", "fit", "hardware", "measurements", "caution"],
                    "additionalProperties": false
                ]
            ],
            "notes": accessoryStringSchema("A short note for the seller, such as \"these photos show only the front\"; empty if none.")
        ],
        "required": ["object", "ideas", "notes"],
        "additionalProperties": false
    ])

/// Clips one line of Claude's (or the seller's) text: control and line-break characters become spaces, invisible format
/// characters (such as direction overrides) are removed, runs of spaces collapse, and the result is at most `limit`
/// characters, ending in "…" when clipped. Bounded work whatever the input's length.
func accessorySuggestionLine(_ text: String?, limit: Int) -> String {
    guard let text, limit > 0 else { return "" }
    var cleaned = String.UnicodeScalarView()
    var pendingSpace = false
    for scalar in text.unicodeScalars.prefix(limit * 4 + 64) {
        switch scalar.properties.generalCategory {
        case .format:
            continue
        case .control, .lineSeparator, .paragraphSeparator, .spaceSeparator:
            pendingSpace = true
            continue
        default:
            break
        }
        if pendingSpace, !cleaned.isEmpty { cleaned.append(" ") }
        pendingSpace = false
        cleaned.append(scalar)
    }
    let result = String(cleaned)
    guard result.count > limit else { return result }
    return String(result.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
}

/// The user turn: the photos first, then the hint and any titles to avoid, then the instruction.
func accessorySuggestionTurnText(photoCount: Int, hint: String, avoidTitles: [String]) -> String {
    var lines: [String] = []
    lines.append(photoCount == 1 ? "The photo above is the seller’s photo of the object."
                                 : "The \(photoCount) photos above are the seller’s photos of the object.")
    let cleanHint = accessorySuggestionLine(hint, limit: accessoryObjectHintMaximumLength)
    if !cleanHint.isEmpty {
        lines.append("")
        lines.append("The seller says the object is: \(cleanHint)")
    }
    let titles = avoidTitles.prefix(accessorySuggestionMaximumIdeas)
        .map { accessorySuggestionLine($0, limit: accessoryIdeaTitleMaximumLength) }.filter { !$0.isEmpty }
    if !titles.isEmpty {
        lines.append("")
        lines.append("Ideas already suggested, so don’t repeat them:")
        lines.append(contentsOf: titles.map { "- \($0)" })
    }
    lines.append("")
    lines.append("Identify the object and suggest accessories the seller could make and sell for it. Answer only by calling suggest_accessories.")
    return lines.joined(separator: "\n")
}

/// One request: a fresh, single-turn conversation each time (earlier titles go in as text). The system prompt is cached.
func accessorySuggestionRequest(photos: [PreparedImage], hint: String, avoidTitles: [String] = []) -> AnthropicRequest {
    let content: [AnthropicInputBlock] = photos.map { .image($0.anthropicImage) }
        + [.text(accessorySuggestionTurnText(photoCount: photos.count, hint: hint, avoidTitles: avoidTitles))]
    return AnthropicRequest(maxTokens: accessorySuggestionMaxTokens,
                            system: [AnthropicSystemBlock(accessorySuggestionSystemPrompt, cacheControl: .fiveMinutes)],
                            tools: [accessorySuggestTool], disableParallelToolUse: true, messages: [.user(content)],
                            effort: .medium)
}

// MARK: Validation

/// Words Studio never suggests, whatever Claude wrote: weapons, children's safety products, protective gear, vehicle
/// controls, and food-contact or medical claims. Matched as whole words (plurals too), ignoring case.
let accessorySuggestionDeniedTerms = [
    "gun", "shotgun", "handgun", "firearm", "pistol", "revolver", "rifle", "ammo", "ammunition", "suppressor", "holster", "weapon",
    "car seat", "child seat", "crib", "cot", "baby gate", "child-proof", "childproof", "teether",
    "helmet", "brake", "steering",
    "food safe", "food-safe", "medical", "orthotic"
]

/// Ordinary tools whose names contain "gun" (a glue gun stand is a craft accessory), removed before the check.
private let accessorySuggestionToolGunPattern = #"\b(?:hot\s+glue|glue|heat|nail|staple|caulk|caulking|massage|spray|paint|grease|solder|soldering|label|price|tape|foam|airbrush)[\s\-]+guns?\b|\bgun[\s\-]?metal\b"#

private let accessorySuggestionDenyRegex: NSRegularExpression = {
    let terms = accessorySuggestionDeniedTerms.map { term in
        term.split(whereSeparator: { $0 == " " || $0 == "-" })
            .map { NSRegularExpression.escapedPattern(for: String($0)) }
            .joined(separator: #"[\s\-]*"#)
    }
    // Force-unwrapped: the pattern is built from the fixed list above and covered by tests.
    return try! NSRegularExpression(pattern: #"\b(?:"# + terms.joined(separator: "|") + #")(?:s|es)?\b"#,
                                    options: [.caseInsensitive])
}()

private let accessorySuggestionToolGunRegex = try! NSRegularExpression(pattern: accessorySuggestionToolGunPattern, options: [.caseInsensitive])

/// True when the text names something Studio doesn't suggest.
func accessorySuggestionIsDenied(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    let stripped = accessorySuggestionToolGunRegex.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    return accessorySuggestionDenyRegex.firstMatch(in: stripped, range: NSRange(stripped.startIndex..., in: stripped)) != nil
}

private func accessorySuggestionStrings(_ value: AnthropicJSON?, limit: Int, count: Int) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    for item in (value?.arrayValue ?? []).prefix(count * 4) {
        let text = accessorySuggestionLine(item.stringValue, limit: limit)
        guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
        result.append(text)
        if result.count == count { break }
    }
    return result
}

/// Claude's suggest_accessories input, validated: every string clipped to one line, unknown values given a neutral
/// default (likely, snug, calipers), ideas without a title or description dropped, duplicates (by title, ignoring
/// case, and against `existingTitles`) dropped, denied ideas counted in `leftOut` and dropped, then at most
/// `accessorySuggestionMaximumIdeasPerReply` kept, each with at most 6 measurements (unnamed or repeated ones dropped)
/// and 8 hardware items.
func accessorySuggestionsParse(_ input: AnthropicJSON, existingTitles: [String] = []) -> AccessorySuggestionSet {
    let object = input["object"]
    let identification = AccessoryObjectIdentification(
        name: accessorySuggestionLine(object?["name"]?.stringValue, limit: 100),
        seenText: accessorySuggestionLine(object?["seen_text"]?.stringValue, limit: 120),
        alternatives: accessorySuggestionStrings(object?["alternatives"], limit: 100, count: accessorySuggestionMaximumAlternatives),
        confidence: object?["confidence"]?.stringValue.flatMap(AccessoryIdentificationConfidence.init(rawValue:)) ?? .likely,
        evidence: accessorySuggestionLine(object?["evidence"]?.stringValue, limit: 300),
        wouldConfirm: accessorySuggestionLine(object?["would_confirm"]?.stringValue, limit: 300),
        features: accessorySuggestionStrings(object?["features"], limit: 100, count: accessorySuggestionMaximumFeatures))
    var seenTitles = Set(existingTitles.map { accessorySuggestionLine($0, limit: accessoryIdeaTitleMaximumLength).lowercased() })
    var ideas: [AccessoryIdea] = []
    var leftOut = 0
    for raw in (input["ideas"]?.arrayValue ?? []).prefix(accessorySuggestionMaximumIdeas * 4) {
        let title = accessorySuggestionLine(raw["title"]?.stringValue, limit: accessoryIdeaTitleMaximumLength)
        let description = accessorySuggestionLine(raw["description"]?.stringValue, limit: accessoryIdeaDescriptionMaximumLength)
        guard !title.isEmpty, !description.isEmpty else { continue }
        if accessorySuggestionIsDenied(title) || accessorySuggestionIsDenied(description) {
            leftOut += 1
            continue
        }
        guard seenTitles.insert(title.lowercased()).inserted else { continue }
        guard ideas.count < accessorySuggestionMaximumIdeasPerReply else { continue }
        var measurements: [AccessoryIdeaMeasurement] = []
        var labels: Set<String> = []
        for item in (raw["measurements"]?.arrayValue ?? []).prefix(accessorySuggestionMaximumMeasurements * 4) {
            let label = accessorySuggestionLine(item["label"]?.stringValue, limit: accessoryLabelMaximumLength)
            guard !label.isEmpty, labels.insert(label.lowercased()).inserted else { continue }
            measurements.append(AccessoryIdeaMeasurement(
                label: label,
                how: accessorySuggestionLine(item["how"]?.stringValue, limit: 300),
                method: item["method"]?.stringValue.flatMap(AccessoryMeasurementMethod.init(rawValue:)) ?? .calipers))
            if measurements.count == accessorySuggestionMaximumMeasurements { break }
        }
        ideas.append(AccessoryIdea(
            title: title, description: description,
            whoWantsIt: accessorySuggestionLine(raw["who_wants_it"]?.stringValue, limit: 300),
            fit: raw["fit"]?.stringValue.flatMap(AccessoryIdeaFit.init(rawValue:)) ?? .snug,
            hardware: accessorySuggestionStrings(raw["hardware"], limit: 80, count: accessorySuggestionMaximumHardware),
            measurements: measurements,
            caution: accessorySuggestionLine(raw["caution"]?.stringValue, limit: 300)))
    }
    return AccessorySuggestionSet(identification: identification, ideas: ideas,
                                  notes: accessorySuggestionLine(input["notes"]?.stringValue, limit: 600), leftOut: leftOut)
}

/// What a reply gave, before it is merged into the sheet's ideas.
enum AccessorySuggestionReplyOutcome: Equatable, Sendable {
    case suggestions(AccessorySuggestionSet)
    /// Nothing usable; the text says why. Everything Claude wrote is discarded.
    case declined(String)
    case setAside(String)
    case unusable(String)
}

/// Reads one reply: a refusal discards everything; a reply that ended early is set aside; only a `suggest_accessories`
/// call from `toolUsesToRun` whose input has no problem is read; a set without ideas is unusable.
func accessorySuggestionOutcome(_ reply: AnthropicMessage, existingTitles: [String] = []) -> AccessorySuggestionReplyOutcome {
    if reply.isRefusal { return .declined(anthropicRefusalMessage(reply.stopDetails)) }
    guard reply.canJoinHistory else { return .setAside(accessorySuggestionSetAsideText(reply.stopReason)) }
    guard let use = reply.toolUsesToRun.first(where: { $0.name == accessorySuggestToolName }) else {
        return .unusable("Claude answered without suggesting ideas in the form Studio reads, so nothing was kept. Suggest Again sends a new request, which is billed again.")
    }
    guard use.inputProblem == nil else {
        return .unusable("Claude’s suggestions couldn’t be read, so nothing was kept. Suggest Again sends a new request, which is billed again.")
    }
    let set = accessorySuggestionsParse(use.input, existingTitles: existingTitles)
    guard !set.ideas.isEmpty else {
        var text = existingTitles.isEmpty ? "Claude didn’t suggest any ideas Studio could use." : "Claude didn’t suggest any new ideas."
        if set.leftOut > 0 { text += " " + accessorySuggestionLeftOutText(set.leftOut) }
        return .unusable(text)
    }
    return .suggestions(set)
}

/// Why a reply that ended early was set aside (the suggestion step's version of `accessorySetAsideText`).
func accessorySuggestionSetAsideText(_ stopReason: AnthropicStopReason?) -> String {
    switch stopReason {
    case .maxTokens?:
        return "Claude’s reply was cut off before it finished, so Studio set it aside. Suggest Again sends a new request, which is billed again."
    case .other("model_context_window_exceeded")?:
        return "Claude’s reply was cut off because the request reached the model’s length limit, so Studio set it aside. Use fewer or smaller photos."
    default:
        return "Claude’s reply ended before it finished, so Studio set it aside. Suggest Again sends a new request, which is billed again."
    }
}

/// "Studio left out 2 ideas it doesn't suggest." Never their text.
func accessorySuggestionLeftOutText(_ count: Int) -> String {
    count == 1 ? "Studio left out 1 idea it doesn’t suggest." : "Studio left out \(count) ideas it doesn’t suggest."
}

// MARK: Showing ideas

/// "Claude thinks this is: Over-ear headphones (probably)".
func accessoryIdentificationLine(_ identification: AccessoryObjectIdentification) -> String {
    let name = identification.name.isEmpty ? "something it couldn’t name" : identification.name
    switch identification.confidence {
    case .clear: return "Claude thinks this is: \(name) (clear)"
    case .likely: return "Claude thinks this is: \(name) (probably)"
    case .unsure: return "Claude thinks this is: \(name) (not sure: correct it in What is it? and suggest again)"
    }
}

/// The smaller lines under the identification, in order: evidence, text on the object, what would confirm it,
/// features and the notes.
func accessoryIdentificationDetailLines(_ identification: AccessoryObjectIdentification, notes: String) -> [String] {
    var lines: [String] = []
    if !identification.evidence.isEmpty { lines.append(identification.evidence) }
    if !identification.seenText.isEmpty { lines.append("Text on the object: “\(identification.seenText)”") }
    if !identification.wouldConfirm.isEmpty { lines.append("To be sure: \(identification.wouldConfirm)") }
    if !identification.features.isEmpty { lines.append("Features: " + identification.features.joined(separator: ", ")) }
    if !notes.isEmpty { lines.append("Note: \(notes)") }
    return lines
}

func accessoryIdeaFitText(_ fit: AccessoryIdeaFit) -> String {
    switch fit {
    case .loose: return "Loose fit"
    case .snug: return "Snug fit"
    case .tight: return "Tight fit: measure with calipers and test a print first"
    }
}

/// "Needs: 2 × M3 screws, 4 × magnets", or nil.
func accessoryIdeaHardwareText(_ idea: AccessoryIdea) -> String? {
    idea.hardware.isEmpty ? nil : "Needs: " + idea.hardware.joined(separator: ", ")
}

/// "You'll measure: Headband width, Ear cup depth", or nil.
func accessoryIdeaMeasureText(_ idea: AccessoryIdea) -> String? {
    idea.measurements.isEmpty ? nil : "You’ll measure: " + idea.measurements.map(\.label).joined(separator: ", ")
}

// MARK: Using an idea

private func accessoryTrimmed(_ text: String) -> String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

private func accessoryLabelKey(_ text: String) -> String {
    accessoryTrimmed(text.split(whereSeparator: \.isNewline).joined(separator: " ")).lowercased()
}

/// True when "What to make" is the idea's description (the idea is "In use").
func accessoryIdeaIsInUse(_ idea: AccessoryIdea, brief: AccessoryDesignBrief) -> Bool {
    let description = accessoryTrimmed(brief.description)
    return !description.isEmpty && description == accessoryTrimmed(idea.description)
}

/// Using the idea needs a confirmation when it would replace a different description the seller has, or when any
/// measurement already has a size typed. Typed rows are always kept, so a brief with only names or blank rows doesn't ask.
func accessoryIdeaNeedsConfirmation(_ brief: AccessoryDesignBrief, idea: AccessoryIdea) -> Bool {
    let description = accessoryTrimmed(brief.description)
    if !description.isEmpty && description != accessoryTrimmed(idea.description) { return true }
    return brief.measurements.contains { !accessoryTrimmed($0.millimetres).isEmpty }
}

/// The brief with the idea used: "What to make" becomes the idea's description; blank rows go; every row the seller
/// typed stays (a typed measurement is never thrown away), and gets the idea's how-to-measure note when its name
/// matches; then the idea's other measurements are added with the size empty and the idea's method, up to
/// `accessoryMaximumMeasurements` rows. Names match ignoring case, so none is added twice. Notes are unchanged.
func accessoryBriefApplyingIdea(_ brief: AccessoryDesignBrief, idea: AccessoryIdea) -> AccessoryDesignBrief {
    var result = brief
    result.description = String(idea.description.prefix(accessoryDescriptionMaximumLength))
    var rows = brief.measurements.filter { !$0.isBlank }
    for measurement in idea.measurements {
        let key = accessoryLabelKey(measurement.label)
        guard !key.isEmpty else { continue }
        let guidance = AccessoryMeasurementGuidance(label: measurement.label, how: measurement.how)
        if let index = rows.firstIndex(where: { accessoryLabelKey($0.label) == key }) {
            if rows[index].guidance == nil, !measurement.how.isEmpty { rows[index].guidance = guidance }
            continue
        }
        guard rows.count < accessoryMaximumMeasurements else { continue }
        rows.append(AccessoryMeasurement(label: measurement.label, millimetres: "", method: measurement.method,
                                         guidance: measurement.how.isEmpty ? nil : guidance))
    }
    result.measurements = rows.isEmpty ? [AccessoryMeasurement()] : rows
    return result
}

/// How many of the idea's measurements `accessoryBriefApplyingIdea` couldn't add because the brief is full.
func accessoryIdeaMeasurementsLeftOut(_ brief: AccessoryDesignBrief, idea: AccessoryIdea) -> Int {
    let applied = accessoryBriefApplyingIdea(brief, idea: idea)
    let present = Set(applied.measurements.map { accessoryLabelKey($0.label) })
    var missing: Set<String> = []
    for measurement in idea.measurements {
        let key = accessoryLabelKey(measurement.label)
        if !key.isEmpty, !present.contains(key) { missing.insert(key) }
    }
    return missing.count
}

/// The caption under a measurement row: the idea's how-to-measure note, while the row still has the name it was
/// written for.
func accessoryMeasurementGuidanceCaption(_ row: AccessoryMeasurement) -> String? {
    guard let guidance = row.guidance, !guidance.how.isEmpty,
          accessoryLabelKey(guidance.label) == accessoryLabelKey(row.label) else { return nil }
    return guidance.how
}

// MARK: Staleness and the button

/// What the ideas were suggested for: the photos (by the sheet's IDs) and the seller's hint.
struct AccessorySuggestionInputs: Equatable, Sendable {
    var photoIDs: [UUID]
    var hint: String
}

/// Why the ideas may no longer match, or nil. Removing all photos or adding one the ideas didn't see makes them stale,
/// and so does changing What is it?; removing one of several photos doesn't.
func accessoryIdeasStaleReason(suggestedFor: AccessorySuggestionInputs?, current: AccessorySuggestionInputs) -> String? {
    guard let suggestedFor else { return nil }
    if current.photoIDs.isEmpty || current.photoIDs.contains(where: { !suggestedFor.photoIDs.contains($0) }) {
        return "These ideas were for the earlier photos."
    }
    if accessorySuggestionLine(current.hint, limit: accessoryObjectHintMaximumLength)
        != accessorySuggestionLine(suggestedFor.hint, limit: accessoryObjectHintMaximumLength) {
        return "You’ve changed What is it? since these ideas were suggested."
    }
    return nil
}

enum AccessorySuggestMode: Equatable, Sendable {
    /// Nothing asked yet.
    case first
    /// After a request that gave nothing, or when the ideas are stale: a new set replaces any held ideas.
    case again
    /// Ideas are held and current: new ones are appended.
    case more

    var buttonTitle: String {
        switch self {
        case .first: return "Suggest Accessories"
        case .again: return "Suggest Again"
        case .more: return "More Ideas"
        }
    }
}

func accessorySuggestMode(ideaCount: Int, stale: Bool, attempted: Bool) -> AccessorySuggestMode {
    if ideaCount > 0 { return stale ? .again : .more }
    return attempted ? .again : .first
}

/// Why the suggest button is disabled, or nil. OpenSCAD isn't needed for suggestions.
func accessorySuggestBlockedReason(photoCount: Int, preparingPhotos: Int, claudeConfigured: Bool, suggesting: Bool,
                                   designStarted: Bool, hintLength: Int, ideaCount: Int, mode: AccessorySuggestMode) -> String? {
    if designStarted { return "Suggestions are made before the design starts." }
    if suggesting { return "Claude is already suggesting ideas." }
    if !claudeConfigured { return "Add your Anthropic API key in Settings first." }
    if photoCount < 1 { return "Add a photo of the object first." }
    if preparingPhotos > 0 { return "Preparing photos…" }
    if hintLength > accessoryObjectHintMaximumLength { return "Keep What is it? to \(accessoryObjectHintMaximumLength) characters or fewer." }
    if mode == .more, ideaCount >= accessorySuggestionMaximumIdeas { return "Studio keeps up to \(accessorySuggestionMaximumIdeas) ideas." }
    return nil
}

/// Whether closing the sheet asks first, and with what words; nil closes at once. It asks when a design has started,
/// when ideas Claude was paid for are held, or while a suggestion request runs. Nothing is lost otherwise.
func accessoryCloseConfirmation(designStarted: Bool, ideasHeld: Bool, suggesting: Bool) -> (title: String, message: String)? {
    if designStarted {
        let ideas = ideasHeld ? ", the suggested ideas" : ""
        return ("Close and discard this design?", "Studio doesn’t keep the photos, the conversation\(ideas) or designs you haven’t saved.")
    }
    if ideasHeld || suggesting {
        return ("Close and discard these ideas?", "Studio doesn’t keep the photos or Claude’s ideas. Suggesting them again is billed again.")
    }
    return nil
}

// MARK: Cost

/// Tokens Claude is assumed to write for one suggestion reply at medium effort: a short answer, and a long one.
let accessorySuggestionOutputTokens = 3_000...12_000

struct AccessorySuggestionCostForecast: Equatable, Sendable {
    let low: AnthropicCostEstimate
    let high: AnthropicCostEstimate
}

/// A rough range before anything is sent, from the prompt, the tool and the photos' sizes (one image token per 750
/// pixels). The low end is a short reply with the system prompt already cached; the high end a long one that writes
/// the cache. Anthropic's invoice is what counts.
func accessorySuggestionCostForecast(photoSizes: [(width: Int, height: Int)], textCharacters: Int) -> AccessorySuggestionCostForecast {
    let fixed = (accessorySuggestionSystemPrompt.count + accessorySuggestTool.json.encodedString.count) * 2 / 7
    let photos = photoSizes.reduce(0) { $0 + accessoryImageTokens(pixelWidth: $1.width, pixelHeight: $1.height) }
    let turn = photos + textCharacters * 2 / 7 + 50
    var low = AnthropicUsage()
    low.cacheReadInputTokens = fixed
    low.inputTokens = turn
    low.outputTokens = accessorySuggestionOutputTokens.lowerBound
    var high = AnthropicUsage()
    high.cacheCreationInputTokens = fixed
    high.cacheCreation5mInputTokens = fixed
    high.inputTokens = turn
    high.outputTokens = accessorySuggestionOutputTokens.upperBound
    return AccessorySuggestionCostForecast(low: anthropicEstimatedCost(low, model: anthropicDefaultModel),
                                           high: anthropicEstimatedCost(high, model: anthropicDefaultModel))
}

private func accessoryDollars(_ value: Decimal, _ mode: NSDecimalNumber.RoundingMode) -> String {
    var rounded = Decimal(), input = value
    NSDecimalRound(&rounded, &input, 2, mode)
    if rounded < Decimal(string: "0.01")! { rounded = Decimal(string: "0.01")! }
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 2
    formatter.maximumFractionDigits = 2
    formatter.locale = Locale(identifier: "en_US")
    return "$" + (formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)")
}

/// "Suggesting costs about $0.05–$0.25 (estimated from Anthropic's list prices)."
func accessorySuggestionCostForecastText(_ forecast: AccessorySuggestionCostForecast) -> String {
    "Suggesting costs about \(accessoryDollars(forecast.low.usd, .down))–\(accessoryDollars(forecast.high.usd, .up)) "
        + "(estimated from Anthropic’s list prices)."
}

/// "Suggestions cost about $0.09" (or a little more after a stopped or failed request), or nil before any request.
func accessorySuggestionSpentText(cost: AnthropicCostEstimate, mayBeHigher: Bool, requests: Int) -> String? {
    guard requests > 0 else { return nil }
    if cost.usd <= 0 && cost.complete {
        return mayBeHigher ? "Suggestions: Anthropic may bill the part Claude wrote before it stopped." : "Suggestions: nothing spent."
    }
    return "Suggestions cost \(anthropicCostText(cost))" + (mayBeHigher ? " or a little more." : ".")
}

/// Activity's detail for one request: status, idea count and cost only, such as "Suggest accessories · 5 ideas ·
/// about $0.09". Never the object, the hint or the ideas.
func accessorySuggestionActivityDetail(status: String?, ideas: Int?, cost: AnthropicCostEstimate?, mayBeBilled: Bool) -> String {
    var parts = ["Suggest accessories"]
    if let status { parts.append(status) }
    if let ideas { parts.append(ideas == 1 ? "1 idea" : "\(ideas) ideas") }
    if let cost {
        parts.append(anthropicCostText(cost) + (mayBeBilled ? " or a little more" : ""))
    } else {
        parts.append(mayBeBilled ? "may be billed for the part written" : "nothing spent")
    }
    return parts.joined(separator: " · ")
}

// MARK: The runner

/// The sheet's suggestions: the ideas, the identification and what was spent. One request at a time, each sent only
/// by `suggest`; nothing is retried or resent. Memory only.
@MainActor final class AccessorySuggestionRun: ObservableObject {
    typealias Send = AccessoryDesignRun.Send
    /// Adds one Activity entry (detail, success).
    typealias Log = @MainActor (String, Bool) -> Void

    private let send: Send

    /// The progress line while a request runs; nil otherwise.
    @Published private(set) var progress: String?
    /// The latest request's outcome for the seller, and whether it is a problem.
    @Published private(set) var message: (text: String, isProblem: Bool)?
    @Published private(set) var identification: AccessoryObjectIdentification?
    @Published private(set) var ideas: [AccessoryIdea] = []
    @Published private(set) var notes = ""
    /// Ideas the deny list dropped from the latest successful reply.
    @Published private(set) var leftOut = 0
    @Published private(set) var suggestedFor: AccessorySuggestionInputs?
    @Published private(set) var requests = 0
    @Published private(set) var cost = AnthropicCostEstimate(usd: 0, complete: true)
    @Published private(set) var costMayBeHigher = false

    private var task: Task<Void, Never>?
    private var closing = false

    init(send: @escaping Send) {
        self.send = send
    }

    var isWorking: Bool { progress != nil }
    var attempted: Bool { requests > 0 }

    /// Sends one request. `append` (More Ideas) keeps the held ideas and asks Claude to avoid their titles; otherwise a
    /// successful reply replaces them. A failed reply never removes ideas already held.
    func suggest(photos: [PreparedImage], hint: String, inputs: AccessorySuggestionInputs, append: Bool, log: @escaping Log) {
        guard task == nil, !closing, !photos.isEmpty else { return }
        if append, ideas.count >= accessorySuggestionMaximumIdeas { return }
        let avoid = append ? ideas.map(\.title) : []
        let request = accessorySuggestionRequest(photos: photos, hint: hint, avoidTitles: avoid)
        progress = "Claude is looking at your photos…"
        message = nil
        task = Task { [weak self] in await self?.perform(request, append: append, inputs: inputs, log: log) }
    }

    /// Stops the request. Anthropic may bill the part Claude had already written.
    func stop() {
        task?.cancel()
    }

    /// The sheet is closing: records the running request in Activity now (its own entry can't be shown once the sheet
    /// has gone), then stops it.
    func closeWhileWorking(log: Log) {
        guard task != nil, !closing else { stop(); return }
        closing = true
        log(accessorySuggestionActivityDetail(status: "Closed while working", ideas: nil, cost: nil, mayBeBilled: true), false)
        task?.cancel()
    }

    private func noteProgress(_ update: AnthropicStreamProgress) {
        guard isWorking else { return }
        let text: String?
        switch update {
        case .started: text = "Claude is looking at your photos…"
        case .toolInput(let name, _) where name == accessorySuggestToolName: text = "Claude is writing ideas…"
        default: text = nil
        }
        if let text, progress != text { progress = text }
    }

    private func finish(_ text: String, problem: Bool, activity: String, success: Bool, log: Log) {
        message = (text, problem)
        if !closing { log(activity, success) }
    }

    private func perform(_ request: AnthropicRequest, append: Bool, inputs: AccessorySuggestionInputs, log: Log) async {
        defer {
            task = nil
            progress = nil
        }
        requests += 1
        let reply: AnthropicMessage
        do {
            reply = try await send(request) { [weak self] update in self?.noteProgress(update) }
        } catch is CancellationError {
            costMayBeHigher = true
            finish("Stopped. Anthropic may bill the part Claude had already written.", problem: true,
                   activity: accessorySuggestionActivityDetail(status: "Stopped", ideas: nil, cost: nil, mayBeBilled: true),
                   success: false, log: log)
            return
        } catch {
            let billed = (error as? AnthropicError).map(accessoryErrorMayHaveBeenBilled) ?? false
            if billed { costMayBeHigher = true }
            finish(error.localizedDescription + (billed ? " Anthropic may bill the part Claude had already written." : ""),
                   problem: true,
                   activity: accessorySuggestionActivityDetail(status: "Failed", ideas: nil, cost: nil, mayBeBilled: billed),
                   success: false, log: log)
            return
        }
        let replyCost = anthropicEstimatedCost(reply.usage, model: reply.model, requestedModel: reply.requestedModel)
        cost = accessoryAddCost(cost, replyCost)
        let existing = append ? ideas.map(\.title) : []
        switch accessorySuggestionOutcome(reply, existingTitles: existing) {
        case .declined(let text):
            finish(text, problem: true, activity: accessorySuggestionActivityDetail(status: "Claude declined", ideas: nil, cost: replyCost, mayBeBilled: false),
                   success: false, log: log)
        case .setAside(let text):
            finish(text, problem: true, activity: accessorySuggestionActivityDetail(status: "Reply set aside", ideas: nil, cost: replyCost, mayBeBilled: false),
                   success: false, log: log)
        case .unusable(let text):
            finish(text, problem: true, activity: accessorySuggestionActivityDetail(status: "No usable ideas", ideas: nil, cost: replyCost, mayBeBilled: false),
                   success: false, log: log)
        case .suggestions(let set):
            let room = max(0, accessorySuggestionMaximumIdeas - (append ? ideas.count : 0))
            let added = Array(set.ideas.prefix(room))
            ideas = append ? ideas + added : added
            identification = set.identification
            notes = set.notes
            leftOut = set.leftOut
            suggestedFor = inputs
            let count = added.count
            var text = append ? (count == 1 ? "Claude suggested 1 more idea." : "Claude suggested \(count) more ideas.")
                              : (count == 1 ? "Claude suggested 1 idea." : "Claude suggested \(count) ideas.")
            if set.leftOut > 0 { text += " " + accessorySuggestionLeftOutText(set.leftOut) }
            finish(text, problem: false, activity: accessorySuggestionActivityDetail(status: nil, ideas: count, cost: replyCost, mayBeBilled: false),
                   success: true, log: log)
        }
    }
}

// MARK: The design turn's context

/// What the first design turn says about the object when the design starts from an idea that is still in use.
struct AccessoryDesignIdeaContext: Equatable, Sendable {
    /// The seller's "What is it?", if any.
    var objectHint: String
    /// Claude's identification, unless the photos or the hint changed since (then nil).
    var identification: AccessoryObjectIdentification?
    var idea: AccessoryIdea
}

/// The context lines added to the first design turn (before its last instruction).
func accessoryDesignIdeaContextLines(_ context: AccessoryDesignIdeaContext, measurements: [AccessoryMeasurement]) -> [String] {
    var lines = ["About the object and the chosen idea (from Studio’s Suggest Accessories step; the photos and typed measurements outrank it):"]
    let hint = accessorySuggestionLine(context.objectHint, limit: accessoryObjectHintMaximumLength)
    if !hint.isEmpty { lines.append("- The seller says the object is: \(hint)") }
    if let identification = context.identification, !identification.name.isEmpty {
        var line = "- Identified from the photos as: \(identification.name) (confidence: \(identification.confidence.rawValue))"
        if !identification.seenText.isEmpty { line += "; text on it: “\(identification.seenText)”" }
        lines.append(line)
    }
    lines.append("- The idea: \(context.idea.title)")
    lines.append("- Fit it needs: \(context.idea.fit.rawValue)")
    if !context.idea.hardware.isEmpty { lines.append("- Hardware it uses: " + context.idea.hardware.joined(separator: ", ")) }
    if !context.idea.caution.isEmpty { lines.append("- Caution: \(context.idea.caution)") }
    let guidance = measurements.compactMap { row -> String? in
        guard let how = accessoryMeasurementGuidanceCaption(row) else { return nil }
        return "  - \(accessorySuggestionLine(row.label, limit: accessoryLabelMaximumLength)): \(how)"
    }
    if !guidance.isEmpty {
        lines.append("- How the seller was asked to measure:")
        lines.append(contentsOf: guidance)
    }
    return lines
}
