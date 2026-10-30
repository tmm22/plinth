import Foundation

// MARK: - Suggest Accessories
//
// A step before Design an Accessory from a Photo: Claude (Opus 5.5) looks at the seller's photos, says what the object
// is and suggests accessories the seller could sell for it, through one strict tool (`suggest_accessories`). Each press
// of Suggest Accessories, Suggest Again or More Ideas is one request: never retried, never resent, with no automatic
// follow-up. Studio validates and clips what comes back, drops ideas its own deny list or claim check catches whatever
// the prompt said, and refuses objects it doesn't suggest for. Picking an idea fills the brief
// (`accessoryBriefApplyingIdea`); the design itself still starts only with Start Design. The ideas live in the sheet's
// memory and go when it closes; Activity gets counts, cost and status only.

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
/// Alternative names are shown as buttons clipped to this; the full text is in the help.
let accessoryAlternativeButtonMaximumLength = 40

// MARK: Values

enum AccessoryIdentificationConfidence: String, CaseIterable, Equatable, Sendable {
    case clear, likely, unsure
}

enum AccessoryIdeaFit: String, CaseIterable, Equatable, Sendable {
    case loose, snug, tight

    /// The fit, defined, for Claude in the design turn.
    var designPhrase: String {
        switch self {
        case .loose: return "loose (tolerates about ±1 mm)"
        case .snug: return "snug (about ±0.5 mm)"
        case .tight: return "tight (within about 0.5 mm: calipers and a test print)"
        }
    }
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
    /// Nil when the object itself is one Studio doesn't suggest for.
    var identification: AccessoryObjectIdentification?
    var ideas: [AccessoryIdea]
    var notes: String
    /// Ideas the deny list or the claim check dropped (their text is never shown).
    var leftOut: Int
    /// The object (or the seller's hint) is one Studio doesn't suggest accessories for: no ideas, no identification.
    var objectDenied = false
}

// MARK: Prompt and tool

let accessorySuggestionSystemPrompt = """
You suggest 3D-printable accessories that a seller could make and sell for the object in their photos. The seller \
sells 3D-printed products; Slant 3D prints them on demand on FDM printers with fixed settings that can't be changed \
for an order: 0.2 mm layers, a 0.4 mm nozzle, 1 mm walls (about 2 lines), 25% infill, overhangs up to 50°, no brims \
and a 220 mm build volume, printed in the orientation the file is uploaded in. Slant doesn't publish its tolerances, \
so every idea must suit FDM printing without fine fits.

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
- Give different kinds of accessory, not variants of one: a stand, a mount, an organiser, a cover, a clip and so on.
- Each idea must print on an FDM printer without supports, ideally as one part with no hardware. If it needs hardware \
(screws, magnets, rubber feet), list it in hardware, with sizes, such as "2 × M3 screws" or "4 × 6×2 mm magnets".
- Each idea must fit Slant's 220 mm build volume, and smaller is better. Prefer small, light parts that print quickly: \
they cost less to make and leave the seller a better margin. Slant recommends nothing smaller than about 20 mm on a \
side, so avoid ideas that tiny.
- Prefer one connected part: Slant charges extra for each separate body. With 1 mm walls and 25% infill, solid parts \
are mostly sparse infill, so ideas that carry load should work as walls or ribs rather than solid blocks.
- Each idea must be designable from the seller's photos plus measurements they can take with calipers or a ruler. \
Don't propose anything that needs the object's internal dimensions, its electronics, threads that match a \
proprietary part, or tolerances finer than about ±0.2 mm.
- Prefer ideas that tolerate ±1 mm: parts often print 0.1–0.3 mm oversize. fit is "loose" when it tolerates about \
±1 mm, "snug" when it needs about ±0.5 mm, and "tight" when it must fit within about 0.5 mm (calipers needed, and the \
seller should test a print first).
- Photos have no scale, so list the measurements the seller must take for each idea: only those the design needs, \
usually 1–5. Each has a short, concrete label (such as "Headband width at the top"), where and how to measure it in \
how without naming the tool (such as "Across the widest point, with the ear cushions on"), and the tool in method: "calipers", \
"ruler" or "estimate". When two ideas need the same size, use exactly the same label for it, so a size the seller \
has typed carries across.
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
figures or percentages.
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
    description: "Say what the object in the seller's photos is and suggest 3D-printable accessories the seller could make and sell for it, best first. The app shows the ideas to the seller, who may pick one to design.",
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
                                    "how": accessoryStringSchema("Where and how to measure it, without naming the tool (that goes in method)."),
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
/// characters, ending in "…" whenever anything was cut, including text past the bounded read-ahead.
func accessorySuggestionLine(_ text: String?, limit: Int) -> String {
    guard let text, limit > 0 else { return "" }
    let readAhead = limit * 4 + 64
    var scalars = text.unicodeScalars.makeIterator()
    var cleaned = String.UnicodeScalarView()
    var pendingSpace = false
    var read = 0
    while read < readAhead, let scalar = scalars.next() {
        read += 1
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
    let unread = read == readAhead && scalars.next() != nil
    if result.count > limit || (unread && result.count == limit) {
        return String(result.prefix(limit - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }
    return unread && !result.isEmpty ? result + "…" : result
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

/// One request: a fresh, single-turn conversation each time (earlier titles go in as text). The system prompt is marked
/// for caching; it may be below the model's minimum cacheable length, in which case the marker is simply ignored.
func accessorySuggestionRequest(photos: [PreparedImage], hint: String, avoidTitles: [String] = []) -> AnthropicRequest {
    let content: [AnthropicInputBlock] = photos.map { .image($0.anthropicImage) }
        + [.text(accessorySuggestionTurnText(photoCount: photos.count, hint: hint, avoidTitles: avoidTitles))]
    return AnthropicRequest(maxTokens: accessorySuggestionMaxTokens,
                            system: [AnthropicSystemBlock(accessorySuggestionSystemPrompt, cacheControl: .fiveMinutes)],
                            tools: [accessorySuggestTool], disableParallelToolUse: true, messages: [.user(content)],
                            effort: .medium)
}

// MARK: The deny list

/// Word separators: whitespace (including no-break spaces) and every dash, such as U+2011 and en dashes.
private let accessorySeparator = #"[\s\p{Pd}\x{00A0}\x{202F}]"#

/// Where a piece of Claude's text sits, which decides how negation is read.
enum AccessoryTextKind: Sendable {
    /// Titles, descriptions, hardware and measurement labels: only "not a", "not an" or "not for" right before a
    /// medical word excuses it, so "Not a Gun Holster" is still caught.
    case label
    /// Cautions, how-to text, notes, evidence and who-wants-it: a match a few words after "not", "isn't", "never",
    /// "no", "don't", "avoid" or "keep away from" in the same sentence doesn't count ("PLA isn't food-safe").
    case prose
}

/// One category Studio never suggests, as phrases. Each phrase matches as whole words, ignoring case, with any
/// separators (or none) between its words and an optional plural, so "food-safe", "food safe" and "foodsafe" all match.
struct AccessoryDenyCategory: Sendable {
    let name: String
    let phrases: [String]
    /// Extra patterns, written as regular expressions.
    var patterns: [String] = []
    /// An object whose name, readable text or hint falls in this category gets no ideas at all.
    var refusesObject = false
    /// "not a", "not an" or "not for" right before the word excuses it, even in a title ("not a medical device").
    var ignoresLabelNegation = false
}

let accessorySuggestionDenyCategories: [AccessoryDenyCategory] = {
    let s = accessorySeparator
    return [
        AccessoryDenyCategory(name: "weapons", phrases: [
            "gun", "firearm", "pistol", "rifle", "shotgun", "handgun", "revolver", "ammo", "ammunition", "suppressor",
            "weapon", "trigger guard", "trigger assembly", "picatinny", "m-lok", "airsoft", "crossbow", "taser",
            "stun gun", "brass knuckles", "knuckle duster", "gun holster", "pistol holster", "knife sheath", "switchblade",
            "magazine loader", "mag loader", "ar-15", "ak-47", "self-defence", "self-defense", "kubotan",
            "glock", "sig sauer", "smith & wesson", "smith and wesson", "beretta", "ruger", "colt"
        ], refusesObject: true),
        AccessoryDenyCategory(name: "children", phrases: [
            "baby", "babies", "infant", "toddler", "kids", "child car seat", "infant car seat", "baby car seat", "crib",
            "baby gate", "pacifier", "teether", "high chair", "child-proof", "child safety", "child lock"
        ], patterns: [
            #"\bfor"# + s + #"+(?:(?:your|the)"# + s + #"+)?children\b"#,
            #"\b(?:kids|kid|child|children)['’]s?(?=\W|$)"#
        ], refusesObject: true),
        AccessoryDenyCategory(name: "people and pets", phrases: [
            "pet harness", "dog harness", "cat harness", "leash", "muzzle", "dog collar", "pet collar", "cat collar",
            "carabiner", "step stool", "hammock", "climbing hold"
        ]),
        AccessoryDenyCategory(name: "protective gear", phrases: [
            "helmet", "protective gear", "face shield", "safety glasses", "knee pad"
        ]),
        AccessoryDenyCategory(name: "vehicle controls", phrases: [
            "brake", "steering", "gas pedal", "brake pedal", "throttle", "seat belt"
        ]),
        AccessoryDenyCategory(name: "food contact", phrases: [
            "food-safe", "food-grade", "dishwasher-safe", "utensil", "spoon", "fork", "cookie cutter", "drinking cup",
            "drinking straw", "baby bottle", "dosing funnel", "coffee scoop", "measuring scoop", "dripper", "spatula",
            "food container lid"
        ], patterns: [
            // A straw for drinking, not a straw hat or bale.
            #"\bstraws?\b(?!"# + s + #"*(?:hats?|bales?|baskets?|dolls?|colou?r))"#
        ]),
        AccessoryDenyCategory(name: "medical", phrases: [
            "medical", "orthotic", "prosthetic", "splint", "knee brace", "wrist brace", "back brace", "ankle brace", "neck brace"
        ], ignoresLabelNegation: true),
        AccessoryDenyCategory(name: "drugs", phrases: [
            "bong", "herb grinder", "weed grinder", "rolling tray", "dab rig", "dab tool", "one-hitter", "vape", "pre-roll",
            "stash box"
        ], refusesObject: true)
    ]
}()

/// Ordinary things whose names contain a denied word, removed before the check: tools called guns, gunmetal, a
/// pistol-grip handle, shotgun microphones, surge suppressors, forks that aren't cutlery, and storage for protective
/// gear or a lead ("Helmet Hook", "Helmet Light Mount", "Safety Glasses Holder", "Hook for Your Helmet").
private let accessorySuggestionExceptionPatterns: [String] = {
    let s = accessorySeparator
    let storage = #"(?:hooks?|hangers?|mounts?|stands?|holders?|racks?|shelf|shelves|storage|organi[sz]ers?|cases?|box(?:es)?|trays?)"#
    let gear = #"(?:helmets?|protective"# + s + #"+gear|face"# + s + #"*shields?|safety"# + s + #"+glasses|knee"# + s + #"*pads?|leash(?:es)?)"#
    let tools = #"(?:hot"# + s + #"+glue|glue|heat|nail|massage|caulk|caulking|staple|spray|tape|label|price|solder|soldering|grease|impact|rivet|screw|blow|air|paint|ir"# + s + #"+temperature|temperature|temp|foam)"#
    return [
        #"\b"# + tools + s + #"+guns?\b"#,
        #"\bgun"# + s + #"*metal\b"#,
        #"\bpistol"# + s + #"*grips?\b"#,
        #"\bshotgun"# + s + #"+(?:mics?|microphones?)\b"#,
        #"\bsurge"# + s + #"+suppressors?\b"#,
        #"\b(?:tuning|bike|bicycle|front|rear|suspension)"# + s + #"+forks?\b"#,
        #"\bfork"# + s + #"+(?:crowns?|mounts?)\b"#,
        #"\b"# + gear + s + #"+(?:[a-z]+"# + s + #"+)?"# + storage + #"\b"#,
        #"\b"# + storage + s + #"+for"# + s + #"+(?:(?:a|an|the|your)"# + s + #"+)?(?:(?:bike|bicycle|motorcycle|cycling|dog)"# + s + #"+)?"# + gear + #"\b"#
    ]
}()

private let accessorySuggestionExceptionRegexes = accessorySuggestionExceptionPatterns.map {
    // Force-unwrapped: fixed patterns, covered by tests.
    try! NSRegularExpression(pattern: $0, options: [.caseInsensitive])
}

/// A sim-racing wheel is a game controller, not a vehicle's steering: ideas for one skip the vehicle-controls check.
private let accessorySimRacingRegex = try! NSRegularExpression(
    pattern: #"\b(?:sim(?:ulator)?"# + accessorySeparator + #"*racing|racing"# + accessorySeparator + #"+(?:sim(?:ulator)?|wheel)|(?:gaming|game|pc|console)"#
        + accessorySeparator + #"+(?:steering"# + accessorySeparator + #"+)?wheel)"#,
    options: [.caseInsensitive])

private func accessoryDenyPhrasePattern(_ phrase: String) -> String {
    phrase.split(whereSeparator: { $0 == " " || $0 == "-" })
        .map { NSRegularExpression.escapedPattern(for: String($0)) }
        .joined(separator: accessorySeparator + "*")
}

private let accessorySuggestionDenyRegexes: [(category: AccessoryDenyCategory, regex: NSRegularExpression)] =
    accessorySuggestionDenyCategories.map { category in
        let words = #"\b(?:"# + category.phrases.map(accessoryDenyPhrasePattern).joined(separator: "|") + #")(?:s|es)?\b"#
        let pattern = ([words] + category.patterns).joined(separator: "|")
        return (category, try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
    }

private let accessoryLabelNegationRegex = try! NSRegularExpression(
    pattern: #"\bnot"# + accessorySeparator + #"+(?:a|an|for)"# + accessorySeparator + #"*$"#, options: [.caseInsensitive])

private let accessoryProseNegationWords: Set<String> = ["not", "isn't", "isnt", "aren't", "never", "no", "don't", "dont",
                                                         "doesn't", "won't", "can't", "cannot", "avoid", "avoids"]

/// Whether the text right before a match negates it: for prose, a negation word among the four words before it in the
/// same sentence, or "keep away from"; for labels, "not a", "not an" or "not for" right before it.
private func accessoryIsNegated(before: String, kind: AccessoryTextKind) -> Bool {
    switch kind {
    case .label:
        let tail = String(before.suffix(24))
        return accessoryLabelNegationRegex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)) != nil
    case .prose:
        let sentence = before.split(omittingEmptySubsequences: false, whereSeparator: { ".!?;".contains($0) }).last ?? ""
        let lowered = String(sentence).lowercased().replacingOccurrences(of: "’", with: "'")
        if lowered.range(of: #"keep\s+away\s+from\s+(?:\S+\s+){0,3}$"#, options: .regularExpression) != nil { return true }
        let words = lowered.split(whereSeparator: { !($0.isLetter || $0 == "'") }).suffix(4).map(String.init)
        return words.contains(where: accessoryProseNegationWords.contains)
    }
}

/// The category the text falls in, or nil. `skipping` leaves categories out; `refusingOnly` checks only the
/// categories that refuse an object.
func accessorySuggestionDeniedCategory(_ text: String, kind: AccessoryTextKind = .label, skipping: Set<String> = [],
                                       refusingOnly: Bool = false) -> String? {
    var stripped = text
    for regex in accessorySuggestionExceptionRegexes {
        stripped = regex.stringByReplacingMatches(in: stripped, range: NSRange(stripped.startIndex..., in: stripped), withTemplate: " ")
    }
    let range = NSRange(stripped.startIndex..., in: stripped)
    let ns = stripped as NSString
    for (category, regex) in accessorySuggestionDenyRegexes
    where !skipping.contains(category.name) && (!refusingOnly || category.refusesObject) {
        for match in regex.matches(in: stripped, range: range) {
            let before = ns.substring(to: match.range.location)
            if kind == .prose, accessoryIsNegated(before: before, kind: .prose) { continue }
            if category.ignoresLabelNegation, accessoryIsNegated(before: before, kind: .label) { continue }
            return category.name
        }
    }
    return nil
}

/// True when the text names something Studio doesn't suggest.
func accessorySuggestionIsDenied(_ text: String, kind: AccessoryTextKind = .label) -> Bool {
    accessorySuggestionDeniedCategory(text, kind: kind) != nil
}

/// True when the object's name, readable text or the seller's hint is a weapon, a drug item or a children's product.
func accessoryObjectIsRefused(_ text: String) -> Bool {
    accessorySuggestionDeniedCategory(text, refusingOnly: true) != nil
}

/// What Studio says when the object (or the seller's hint) is one it doesn't suggest accessories for.
let accessoryObjectDeniedText = "Plinth doesn’t suggest accessories for this kind of object."

// MARK: The claim check

/// Claims Claude mustn't make: safety, strength, approval, a perfect fit, demand or sales, health relief, and a
/// percentage next to strength or success words. Kept apart from the deny list: a claim blanks a caption, or drops an
/// idea whose title or description makes it.
private let accessoryClaimRegex: NSRegularExpression = {
    let s = accessorySeparator
    let percent = #"\d+(?:[.,]\d+)?"# + s + #"*(?:%|per"# + s + #"*cent\b)"#
    let strength = #"(?:strong(?:er|est)?|strength|stiffer|tougher|durab\w*|success\w*)"#
    let pain = #"(?:pain|aches?|posture|strain|tension)"#
    let patterns = [
        #"\b(?:food|child|kid|pet|baby|dishwasher|microwave)"# + s + #"*safe\b"#,
        #"\b(?:is|are|it['’]s)"# + s + #"+(?:completely"# + s + #"+|totally"# + s + #"+|perfectly"# + s + #"+)?safe\b"#,
        #"\bsafe"# + s + #"+(?:for|to|around|with)\b"#,
        // "Strong" about the part, not about the magnets or tape it uses.
        #"\bstrong(?:er|est)?\b(?!\W+(?:\w+\W+){0,2}(?:magnets?|tape|adhesive|glue|velcro|neodymium))"#,
        #"\b(?:approved|guaranteed?|certified)\b"#,
        #"\bperfect"# + s + #"+fit\b"#,
        #"\bfits?"# + s + #"+perfectly\b"#,
        #"\bbest"# + s + #"*sell(?:ing|ers?)\b"#,
        #"\bsells"# + s + #"+well\b"#,
        #"\bpopular\b"#,
        #"\b(?:in|high)"# + s + #"+demand\b"#,
        #"\b"# + strength + #"\W+(?:\w+\W+){0,3}"# + percent,
        percent + #"\W+(?:\w+\W+){0,3}"# + strength + #"\b"#,
        #"\brelie(?:f|ve|ves|ving)\b\W+(?:\w+\W+){0,3}"# + pain + #"\b"#,
        #"\b"# + pain + #"\W+(?:\w+\W+){0,3}relie(?:f|ve|ves|ving)\b"#
    ]
    return try! NSRegularExpression(pattern: patterns.joined(separator: "|"), options: [.caseInsensitive])
}()

private let accessorySturdyRegex = try! NSRegularExpression(pattern: #"\bsturd(?:y|ier|iest)\b"#, options: [.caseInsensitive])

/// True when the text makes a claim. "Sturdy" counts only in captions (`includeSturdy`): in a description it is a
/// design intent, such as "a sturdy base with thick walls". "Strong" counts when it describes the part ("a strong
/// stand", "strong enough"), not the magnets or tape it uses. In prose a negated claim ("not strong enough for heavy
/// bags") doesn't count.
func accessorySuggestionHasClaim(_ text: String, includeSturdy: Bool = false, kind: AccessoryTextKind = .label) -> Bool {
    let range = NSRange(text.startIndex..., in: text)
    let ns = text as NSString
    var regexes = [accessoryClaimRegex]
    if includeSturdy { regexes.append(accessorySturdyRegex) }
    for regex in regexes {
        for match in regex.matches(in: text, range: range) {
            if kind == .prose, accessoryIsNegated(before: ns.substring(to: match.range.location), kind: .prose) { continue }
            return true
        }
    }
    return false
}

/// A caption without claims: the text, or empty when it makes one.
private func accessoryClaimFree(_ text: String) -> String {
    accessorySuggestionHasClaim(text, includeSturdy: true, kind: .prose) ? "" : text
}

// MARK: Validation

private func accessorySuggestionStrings(_ value: AnthropicJSON?, limit: Int, count: Int) -> [String] {
    var result: [String] = []
    var seen: Set<String> = []
    for item in (value?.arrayValue ?? []).prefix(count * 4) {
        let text = accessorySuggestionLine(item.stringValue, limit: limit)
        guard !text.isEmpty, seen.insert(text.lowercased()).inserted else { continue }
        result.append(text)
    }
    return result
}

/// Claude's suggest_accessories input, validated.
/// - Every string is clipped to one line; unknown values get a neutral default (likely, snug, calipers).
/// - The object is refused (no ideas, no identification) only when its name, readable text or the seller's hint is a
///   weapon, a drug item or a children's product. Its features and evidence are never checked; a denied alternative is
///   just dropped from the alternatives. A sim-racing wheel's ideas skip the vehicle-controls check.
/// - Ideas without a title or description are dropped. An idea is left out (and counted) when any of its strings is on
///   the deny list (prose read with negation), or its title or description makes a claim; a caption with a claim is
///   blanked.
/// - Duplicates (by title, ignoring case, and against `existingTitles`) are dropped, then at most
///   `accessorySuggestionMaximumIdeasPerReply` kept, each with at most 6 measurements (unnamed or repeated ones
///   dropped) and 8 hardware items.
func accessorySuggestionsParse(_ input: AnthropicJSON, existingTitles: [String] = [], hint: String = "") -> AccessorySuggestionSet {
    let object = input["object"]
    let name = accessorySuggestionLine(object?["name"]?.stringValue, limit: 100)
    let seenText = accessorySuggestionLine(object?["seen_text"]?.stringValue, limit: 120)
    let cleanHint = accessorySuggestionLine(hint, limit: accessoryObjectHintMaximumLength)
    if [name, seenText, cleanHint].contains(where: accessoryObjectIsRefused) {
        return AccessorySuggestionSet(identification: nil, ideas: [], notes: "", leftOut: 0, objectDenied: true)
    }
    let alternatives = accessorySuggestionStrings(object?["alternatives"], limit: 100, count: accessorySuggestionMaximumAlternatives)
        .filter { !accessorySuggestionIsDenied($0) }
    let features = accessorySuggestionStrings(object?["features"], limit: 100, count: accessorySuggestionMaximumFeatures)
    let evidence = accessorySuggestionLine(object?["evidence"]?.stringValue, limit: 300)
    let simRacing = [name, cleanHint].contains { accessorySimRacingRegex.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    let skipping: Set<String> = simRacing ? ["vehicle controls"] : []
    let identification = AccessoryObjectIdentification(
        name: name, seenText: seenText,
        alternatives: Array(alternatives.prefix(accessorySuggestionMaximumAlternatives)),
        confidence: object?["confidence"]?.stringValue.flatMap(AccessoryIdentificationConfidence.init(rawValue:)) ?? .likely,
        evidence: accessoryClaimFree(evidence),
        wouldConfirm: accessorySuggestionLine(object?["would_confirm"]?.stringValue, limit: 300),
        features: Array(features.prefix(accessorySuggestionMaximumFeatures)))
    var seenTitles = Set(existingTitles.map { accessorySuggestionLine($0, limit: accessoryIdeaTitleMaximumLength).lowercased() })
    var ideas: [AccessoryIdea] = []
    var leftOut = 0
    for raw in (input["ideas"]?.arrayValue ?? []).prefix(accessorySuggestionMaximumIdeas * 4) {
        let title = accessorySuggestionLine(raw["title"]?.stringValue, limit: accessoryIdeaTitleMaximumLength)
        let description = accessorySuggestionLine(raw["description"]?.stringValue, limit: accessoryIdeaDescriptionMaximumLength)
        guard !title.isEmpty, !description.isEmpty else { continue }
        let whoWantsIt = accessorySuggestionLine(raw["who_wants_it"]?.stringValue, limit: 300)
        let caution = accessorySuggestionLine(raw["caution"]?.stringValue, limit: 300)
        let hardware = accessorySuggestionStrings(raw["hardware"], limit: 80, count: accessorySuggestionMaximumHardware)
        var measurements: [AccessoryIdeaMeasurement] = []
        var labels: Set<String> = []
        for item in (raw["measurements"]?.arrayValue ?? []).prefix(accessorySuggestionMaximumMeasurements * 4) {
            let label = accessorySuggestionLine(item["label"]?.stringValue, limit: accessoryLabelMaximumLength)
            guard !label.isEmpty, labels.insert(label.lowercased()).inserted else { continue }
            measurements.append(AccessoryIdeaMeasurement(
                label: label,
                how: accessorySuggestionLine(item["how"]?.stringValue, limit: 300),
                method: item["method"]?.stringValue.flatMap(AccessoryMeasurementMethod.init(rawValue:)) ?? .calipers))
        }
        let labelTexts = [title, description] + hardware + measurements.map(\.label)
        let proseTexts = [whoWantsIt, caution] + measurements.map(\.how)
        let denied = labelTexts.contains { accessorySuggestionDeniedCategory($0, kind: .label, skipping: skipping) != nil }
            || proseTexts.contains { accessorySuggestionDeniedCategory($0, kind: .prose, skipping: skipping) != nil }
        if denied || accessorySuggestionHasClaim(title) || accessorySuggestionHasClaim(description) {
            leftOut += 1
            continue
        }
        guard seenTitles.insert(title.lowercased()).inserted else { continue }
        guard ideas.count < accessorySuggestionMaximumIdeasPerReply else { continue }
        ideas.append(AccessoryIdea(
            title: title, description: description, whoWantsIt: accessoryClaimFree(whoWantsIt),
            fit: raw["fit"]?.stringValue.flatMap(AccessoryIdeaFit.init(rawValue:)) ?? .snug,
            hardware: Array(hardware.prefix(accessorySuggestionMaximumHardware)),
            measurements: Array(measurements.prefix(accessorySuggestionMaximumMeasurements)),
            caution: accessoryClaimFree(caution)))
    }
    return AccessorySuggestionSet(identification: identification, ideas: ideas,
                                  notes: accessoryClaimFree(accessorySuggestionLine(input["notes"]?.stringValue, limit: 600)),
                                  leftOut: leftOut)
}

/// What a reply gave, before it is merged into the sheet's ideas.
enum AccessorySuggestionReplyOutcome: Equatable, Sendable {
    case suggestions(AccessorySuggestionSet)
    /// The object is one Studio doesn't suggest for: this reply gives no ideas and no identification.
    case objectDenied
    /// Nothing usable; the text says why. Everything Claude wrote is discarded.
    case declined(String)
    case setAside(String)
    case unusable(String)
}

/// Reads one reply: a refusal discards everything; a reply that ended early is set aside; only a `suggest_accessories`
/// call from `toolUsesToRun` whose input has no problem is read; a denied object gives nothing; a set without ideas is
/// unusable.
func accessorySuggestionOutcome(_ reply: AnthropicMessage, existingTitles: [String] = [], hint: String = "") -> AccessorySuggestionReplyOutcome {
    if reply.isRefusal { return .declined(anthropicRefusalMessage(reply.stopDetails)) }
    guard reply.canJoinHistory else { return .setAside(accessorySuggestionSetAsideText(reply.stopReason)) }
    guard let use = reply.toolUsesToRun.first(where: { $0.name == accessorySuggestToolName }) else {
        return .unusable("Claude answered without suggesting ideas in the form Plinth reads, so nothing was kept. Suggest Again sends a new request, which is billed again.")
    }
    guard use.inputProblem == nil else {
        return .unusable("Claude’s suggestions couldn’t be read, so nothing was kept. Suggest Again sends a new request, which is billed again.")
    }
    let set = accessorySuggestionsParse(use.input, existingTitles: existingTitles, hint: hint)
    if set.objectDenied { return .objectDenied }
    guard !set.ideas.isEmpty else {
        var text = existingTitles.isEmpty ? "Claude didn’t suggest any ideas Plinth could use." : "Claude didn’t suggest any new ideas."
        if set.leftOut > 0 { text += " " + accessorySuggestionLeftOutText(set.leftOut) }
        return .unusable(text)
    }
    return .suggestions(set)
}

/// Why a reply that ended early was set aside (the suggestion step's version of `accessorySetAsideText`, which
/// mentions Try Again).
func accessorySuggestionSetAsideText(_ stopReason: AnthropicStopReason?) -> String {
    switch stopReason {
    case .maxTokens?:
        return "Claude’s reply was cut off before it finished, so Plinth set it aside. Suggest Again sends a new request, which is billed again."
    case .other("model_context_window_exceeded")?:
        return "Claude’s reply was cut off because the request reached the model’s length limit, so Plinth set it aside. Use fewer or smaller photos."
    default:
        return "Claude’s reply ended before it finished, so Plinth set it aside. Suggest Again sends a new request, which is billed again."
    }
}

/// "Studio left out 2 ideas it doesn't suggest." Never their text.
func accessorySuggestionLeftOutText(_ count: Int) -> String {
    count == 1 ? "Plinth left out 1 idea it doesn’t suggest." : "Plinth left out \(count) ideas it doesn’t suggest."
}

// MARK: Showing ideas

/// "Claude thinks this is: Over-ear headphones (probably)".
func accessoryIdentificationLine(_ identification: AccessoryObjectIdentification) -> String {
    let name = identification.name.isEmpty ? "something it couldn’t name" : identification.name
    switch identification.confidence {
    case .clear: return "Claude thinks this is: \(name) (confident)"
    case .likely: return "Claude thinks this is: \(name) (probably)"
    case .unsure: return "Claude thinks this is: \(name) (not sure: correct it in What is it? and suggest again)"
    }
}

/// The smaller lines under the identification, in order: evidence, text on the object, what would confirm it and the
/// notes. (Features go only to the design turn.)
func accessoryIdentificationDetailLines(_ identification: AccessoryObjectIdentification, notes: String) -> [String] {
    var lines: [String] = []
    if !identification.evidence.isEmpty { lines.append(identification.evidence) }
    if !identification.seenText.isEmpty { lines.append("Text on the object: “\(identification.seenText)”") }
    if !identification.wouldConfirm.isEmpty { lines.append("To be sure: \(identification.wouldConfirm)") }
    if !notes.isEmpty { lines.append("Note: \(notes)") }
    return lines
}

/// An alternative's button title, at most `accessoryAlternativeButtonMaximumLength` characters.
func accessoryAlternativeButtonTitle(_ alternative: String) -> String {
    accessorySuggestionLine(alternative, limit: accessoryAlternativeButtonMaximumLength)
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

/// True when "What to make" is exactly the idea's description.
func accessoryIdeaIsInUse(_ idea: AccessoryIdea, brief: AccessoryDesignBrief) -> Bool {
    let description = accessoryTrimmed(brief.description)
    return !description.isEmpty && description == accessoryTrimmed(idea.description)
}

/// The card's marker: "In use" for the chosen idea, "In use (edited)" once the seller has changed What to make, nil
/// for every other idea.
func accessoryIdeaUseLabel(_ idea: AccessoryIdea, chosen: AccessoryIdea?, brief: AccessoryDesignBrief) -> String? {
    guard let chosen, chosen.id == idea.id else { return nil }
    return accessoryIdeaIsInUse(idea, brief: brief) ? "In use" : "In use (edited)"
}

/// The chosen idea after the list changed: kept while it is listed, or the listed idea with the same title and
/// description after Suggest Again; otherwise nil.
func accessoryChosenIdeaAfterUpdate(_ chosen: AccessoryIdea?, ideas: [AccessoryIdea]) -> AccessoryIdea? {
    guard let chosen else { return nil }
    if let same = ideas.first(where: { $0.id == chosen.id }) { return same }
    return ideas.first { $0.title.lowercased() == chosen.title.lowercased()
        && accessoryTrimmed($0.description) == accessoryTrimmed(chosen.description) }
}

/// A row an earlier idea added that the seller hasn't typed a size into or renamed.
private func accessoryRowIsUntouchedIdeaRow(_ row: AccessoryMeasurement) -> Bool {
    guard row.addedByIdea, accessoryTrimmed(row.millimetres).isEmpty else { return false }
    guard let guidance = row.guidance else { return true }
    return accessoryLabelKey(guidance.label) == accessoryLabelKey(row.label)
}

/// Using the idea asks first when it would replace a description the seller wrote or edited (not the previous idea's
/// own, unchanged), or when any measurement already has a size typed.
func accessoryIdeaNeedsConfirmation(_ brief: AccessoryDesignBrief, idea: AccessoryIdea, previousIdea: AccessoryIdea? = nil) -> Bool {
    let description = accessoryTrimmed(brief.description)
    if !description.isEmpty, description != accessoryTrimmed(idea.description),
       description != previousIdea.map({ accessoryTrimmed($0.description) }) {
        return true
    }
    return brief.measurements.contains { !accessoryTrimmed($0.millimetres).isEmpty }
}

/// The confirmation's message, matching what `accessoryBriefApplyingIdea` does.
let accessoryIdeaReplaceMessage = "What to make becomes this idea’s description and its measurements are added. Every measurement with a size typed is kept, and so are names you typed; empty rows and the earlier idea’s rows without a size are removed."

/// The brief with the idea used:
/// - "What to make" becomes the idea's description; notes are unchanged.
/// - Blank rows go, and so do rows an earlier idea added that still have no size and their original name.
/// - Every other row stays: a size the seller typed is never thrown away. A kept row whose name matches one of the
///   idea's measurements (ignoring case) gets this idea's how-to-measure note.
/// - The idea's other measurements are added with the size empty and the idea's method, up to
///   `accessoryMaximumMeasurements` rows, so none is added twice.
func accessoryBriefApplyingIdea(_ brief: AccessoryDesignBrief, idea: AccessoryIdea) -> AccessoryDesignBrief {
    var result = brief
    result.description = String(idea.description.prefix(accessoryDescriptionMaximumLength))
    var rows = brief.measurements.filter { !$0.isBlank && !accessoryRowIsUntouchedIdeaRow($0) }
    for measurement in idea.measurements {
        let key = accessoryLabelKey(measurement.label)
        guard !key.isEmpty else { continue }
        let guidance = AccessoryMeasurementGuidance(label: measurement.label, how: measurement.how, method: measurement.method)
        if let index = rows.firstIndex(where: { accessoryLabelKey($0.label) == key }) {
            if !measurement.how.isEmpty { rows[index].guidance = guidance }
            continue
        }
        guard rows.count < accessoryMaximumMeasurements else { continue }
        rows.append(AccessoryMeasurement(label: measurement.label, millimetres: "", method: measurement.method,
                                         guidance: measurement.how.isEmpty ? nil : guidance, addedByIdea: true))
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

/// "2 of the idea's measurements weren't added", shown only while the brief's rows and the ideas are exactly as they
/// were when the idea was used: typing, adding or removing a row, using another idea or new ideas hide it.
struct AccessoryIdeaNotice: Equatable, Sendable {
    let leftOut: Int
    let measurements: [AccessoryMeasurement]
    let ideaIDs: [UUID]

    func text(brief: AccessoryDesignBrief, ideaIDs current: [UUID]) -> String? {
        guard leftOut > 0, brief.measurements == measurements, current == ideaIDs else { return nil }
        let what = leftOut == 1 ? "1 of the idea’s measurements wasn’t" : "\(leftOut) of the idea’s measurements weren’t"
        return "\(what) added: use at most \(accessoryMaximumMeasurements)."
    }
}

/// The row Use This Idea focuses (and scrolls to): the first row the idea added that still has no size. Rows the
/// seller added are never chosen; nil when the idea added none.
func accessoryFirstIdeaRowToMeasure(_ brief: AccessoryDesignBrief) -> UUID? {
    brief.measurements.first { $0.addedByIdea && accessoryTrimmed($0.millimetres).isEmpty }?.id
}

/// "Now measure: Headband width, Ear cup depth": the idea's measurements still without a size, or nil.
func accessoryNowMeasureText(_ brief: AccessoryDesignBrief, idea: AccessoryIdea) -> String? {
    let keys = Set(idea.measurements.map { accessoryLabelKey($0.label) })
    let labels = brief.measurements
        .filter { keys.contains(accessoryLabelKey($0.label)) && accessoryTrimmed($0.millimetres).isEmpty }
        .map { accessoryTrimmed($0.label) }
    return labels.isEmpty ? nil : "Now measure: " + labels.joined(separator: ", ")
}

/// The idea's how-to-measure note for a row, while the row still has the name it was written for.
func accessoryMeasurementGuidanceHow(_ row: AccessoryMeasurement) -> String? {
    guard let guidance = row.guidance, !guidance.how.isEmpty,
          accessoryLabelKey(guidance.label) == accessoryLabelKey(row.label) else { return nil }
    return guidance.how
}

/// The caption under a measurement row, as advice naming the tool, such as "Use calipers: across the widest point",
/// so a seller without that tool knows to change How measured.
/// A leading tool word that repeats the method ("Calipers across the top", "With a ruler, from…") is dropped.
func accessoryMeasurementGuidanceCaption(_ row: AccessoryMeasurement) -> String? {
    guard let how = accessoryMeasurementGuidanceHow(row), let method = row.guidance?.method else { return nil }
    let tool: String
    switch method {
    case .calipers: tool = #"(?:digital\s+)?cal(?:l)?ipers?"#
    case .ruler: tool = #"(?:ruler|tape(?:\s+measure)?|measuring\s+tape)"#
    case .estimate: tool = #"estimate"#
    }
    let leading = #"^(?:(?:with|using|use)\s+)?(?:(?:a|the|your)\s+)?"# + tool + #"\b[\s,:;\-–—]*"#
    var advice = how.replacingOccurrences(of: leading, with: "", options: [.regularExpression, .caseInsensitive])
    if advice.isEmpty { advice = how }
    switch method {
    case .calipers: return "Use calipers: \(advice)"
    case .ruler: return "Use a ruler: \(advice)"
    case .estimate: return "Estimate it: \(advice)"
    }
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
    /// After a request that gave nothing, or when the ideas are stale: a new set replaces any held ideas (after
    /// asking, when there are any).
    case again
    /// Ideas are held and current: new ones are appended (disabled at 12, beside a separate Suggest Again).
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

/// At 12 ideas More Ideas is disabled and a separate Suggest Again (replace) is offered beside it.
func accessoryOffersSeparateSuggestAgain(ideaCount: Int, mode: AccessorySuggestMode) -> Bool {
    mode == .more && ideaCount >= accessorySuggestionMaximumIdeas
}

/// Suggest Again asks "Replace these ideas?" first (Keep These Ideas is the default) whenever it would replace ideas
/// the seller already paid for.
func accessorySuggestAgainNeedsConfirmation(ideaCount: Int) -> Bool {
    ideaCount > 0
}

/// "Replace these ideas?": what the confirmation says.
func accessoryReplaceIdeasMessage(ideaCount: Int) -> String {
    let ideas = ideaCount == 1 ? "the idea you have" : "the \(ideaCount) ideas you have"
    return "Suggest Again asks Claude for a new set, which is billed again, and replaces \(ideas). An idea already in What to make stays there."
}

/// When an append adds ideas while one is chosen (and the list folded), the list opens so the new ones show.
func accessoryShouldExpandIdeas(old: [UUID], new: [UUID]) -> Bool {
    !old.isEmpty && new.count > old.count && old.allSatisfy(new.contains)
}

let accessoryIdeasFullText = "\(accessorySuggestionMaximumIdeas) ideas is the most Plinth keeps."

/// Why the suggest button is disabled, or nil. OpenSCAD isn't needed for suggestions.
func accessorySuggestBlockedReason(photoCount: Int, preparingPhotos: Int, claudeConfigured: Bool, suggesting: Bool,
                                   designStarted: Bool, hint: String, ideaCount: Int, mode: AccessorySuggestMode) -> String? {
    if designStarted { return "Suggestions are made before the design starts." }
    if suggesting { return "Claude is already suggesting ideas." }
    if !claudeConfigured { return "Add your Anthropic API key in Settings first." }
    if photoCount < 1 { return "Add a photo of the object first." }
    if preparingPhotos > 0 { return "Preparing photos…" }
    if hint.count > accessoryObjectHintMaximumLength { return "Keep What is it? to \(accessoryObjectHintMaximumLength) characters or fewer." }
    if accessoryObjectIsRefused(hint) { return accessoryObjectDeniedText }
    if mode == .more, ideaCount >= accessorySuggestionMaximumIdeas { return accessoryIdeasFullText }
    return nil
}

/// Whether closing the sheet asks first, and with what words; nil closes at once. It asks when a design has started,
/// when ideas Claude was paid for are held, or while a suggestion request runs. Nothing is lost otherwise.
func accessoryCloseConfirmation(designStarted: Bool, ideasHeld: Bool, suggesting: Bool) -> (title: String, message: String)? {
    if designStarted {
        let ideas = ideasHeld ? ", the suggested ideas" : ""
        return ("Close and discard this design?", "Plinth doesn’t keep the photos, the conversation\(ideas) or designs you haven’t saved.")
    }
    if ideasHeld || suggesting {
        return ("Close and discard these ideas?", "Plinth doesn’t keep the photos or Claude’s ideas. Suggesting them again is billed again.")
    }
    return nil
}

// MARK: Cost

/// Tokens Claude is assumed to write for a short suggestion reply; the high end is the whole reply limit.
let accessorySuggestionShortReplyTokens = 3_000

struct AccessorySuggestionCostForecast: Equatable, Sendable {
    let low: AnthropicCostEstimate
    let high: AnthropicCostEstimate
}

/// A rough range before anything is sent, from the prompt, the tool and the photos' sizes (one image token per 750
/// pixels), all at the plain input price: the system prompt and tool are probably below the minimum length Anthropic
/// caches. The low end is a short reply; the high end the full `accessorySuggestionMaxTokens`. Anthropic's invoice is
/// what counts.
func accessorySuggestionCostForecast(photoSizes: [(width: Int, height: Int)], textCharacters: Int) -> AccessorySuggestionCostForecast {
    let fixed = (accessorySuggestionSystemPrompt.count + accessorySuggestTool.json.encodedString.count) * 2 / 7
    let photos = photoSizes.reduce(0) { $0 + accessoryImageTokens(pixelWidth: $1.width, pixelHeight: $1.height) }
    let input = fixed + photos + textCharacters * 2 / 7 + 50
    func estimate(_ output: Int) -> AnthropicCostEstimate {
        anthropicEstimatedCost(AnthropicUsage(inputTokens: input, outputTokens: output), model: anthropicDefaultModel)
    }
    return AccessorySuggestionCostForecast(low: estimate(accessorySuggestionShortReplyTokens), high: estimate(accessorySuggestionMaxTokens))
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

/// "Suggesting costs about $0.05–$0.37 (estimated from Anthropic's list prices)."
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
    /// Ideas Studio left out of the latest successful reply.
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

    /// Sends one request. `append` (More Ideas) keeps the held ideas and the first identification, and asks Claude to
    /// avoid the held titles; otherwise a successful reply replaces them. A failed reply never removes ideas already
    /// held, and neither does a refused object (only that reply's ideas are discarded).
    func suggest(photos: [PreparedImage], hint: String, inputs: AccessorySuggestionInputs, append: Bool, log: @escaping Log) {
        guard task == nil, !closing, !photos.isEmpty else { return }
        if append, ideas.count >= accessorySuggestionMaximumIdeas { return }
        let avoid = append ? ideas.map(\.title) : []
        let request = accessorySuggestionRequest(photos: photos, hint: hint, avoidTitles: avoid)
        progress = "Claude is looking at your photos…"
        message = nil
        task = Task { [weak self] in await self?.perform(request, append: append, hint: hint, inputs: inputs, log: log) }
    }

    /// Stops the request. Anthropic may bill the part Claude had already written.
    func stop() {
        task?.cancel()
    }

    /// The sheet is closing: stops the request. Its single Activity line ("Closed while working", with the reply's
    /// cost if one still arrives) is written when it ends; the log holds the store, not the sheet.
    func closeWhileWorking() {
        guard task != nil else { return }
        closing = true
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

    /// Shows the outcome and writes the request's one Activity line.
    private func finish(_ text: String, problem: Bool, status: String?, ideas count: Int?, cost requestCost: AnthropicCostEstimate?,
                        mayBeBilled: Bool, log: Log) {
        message = (text, problem)
        if closing {
            log(accessorySuggestionActivityDetail(status: "Closed while working", ideas: nil, cost: requestCost, mayBeBilled: mayBeBilled), false)
        } else {
            log(accessorySuggestionActivityDetail(status: status, ideas: count, cost: requestCost, mayBeBilled: mayBeBilled), !problem)
        }
    }

    private func perform(_ request: AnthropicRequest, append: Bool, hint: String, inputs: AccessorySuggestionInputs, log: Log) async {
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
            finish("Stopped. Anthropic may bill the part Claude had already written.", problem: true, status: "Stopped",
                   ideas: nil, cost: nil, mayBeBilled: true, log: log)
            return
        } catch {
            let billed = (error as? AnthropicError).map(accessoryErrorMayHaveBeenBilled) ?? false
            if billed { costMayBeHigher = true }
            finish(error.localizedDescription + (billed ? " Anthropic may bill the part Claude had already written." : ""),
                   problem: true, status: "Failed", ideas: nil, cost: nil, mayBeBilled: billed, log: log)
            return
        }
        let replyCost = anthropicEstimatedCost(reply.usage, model: reply.model, requestedModel: reply.requestedModel)
        cost = accessoryAddCost(cost, replyCost)
        let existing = append ? ideas.map(\.title) : []
        switch accessorySuggestionOutcome(reply, existingTitles: existing, hint: hint) {
        case .declined(let text):
            finish(text, problem: true, status: "Claude declined", ideas: nil, cost: replyCost, mayBeBilled: false, log: log)
        case .setAside(let text):
            finish(text, problem: true, status: "Reply set aside", ideas: nil, cost: replyCost, mayBeBilled: false, log: log)
        case .unusable(let text):
            finish(text, problem: true, status: "No usable ideas", ideas: nil, cost: replyCost, mayBeBilled: false, log: log)
        case .objectDenied:
            // Only this reply's ideas are discarded; ideas already held (checked when they came) stay.
            finish(accessoryObjectDeniedText, problem: true, status: "Object not suggested", ideas: nil, cost: replyCost,
                   mayBeBilled: false, log: log)
        case .suggestions(let set):
            let room = max(0, accessorySuggestionMaximumIdeas - (append ? ideas.count : 0))
            let added = Array(set.ideas.prefix(room))
            if append {
                ideas += added
                if identification == nil { identification = set.identification }
                if notes.isEmpty { notes = set.notes }
            } else {
                ideas = added
                identification = set.identification
                notes = set.notes
                suggestedFor = inputs
            }
            leftOut = set.leftOut
            let count = added.count
            var text = append ? (count == 1 ? "Claude suggested 1 more idea." : "Claude suggested \(count) more ideas.")
                              : (count == 1 ? "Claude suggested 1 idea." : "Claude suggested \(count) ideas.")
            if set.leftOut > 0 { text += " " + accessorySuggestionLeftOutText(set.leftOut) }
            finish(text, problem: false, status: nil, ideas: count, cost: replyCost, mayBeBilled: false, log: log)
        }
    }
}

// MARK: The design turn's context

/// What the first design turn says about the object when the design starts from a chosen idea, edited or not.
struct AccessoryDesignIdeaContext: Equatable, Sendable {
    /// The seller's "What is it?", if any.
    var objectHint: String
    /// Claude's identification, unless the photos or the hint changed since (then nil).
    var identification: AccessoryObjectIdentification?
    var idea: AccessoryIdea
    /// The seller changed What to make after choosing the idea.
    var descriptionEdited = false
}

/// The context lines added to the first design turn (before its last instruction).
func accessoryDesignIdeaContextLines(_ context: AccessoryDesignIdeaContext, measurements: [AccessoryMeasurement]) -> [String] {
    var lines = ["About the object and the chosen idea (from the app’s Suggest Accessories step; the photos and typed measurements outrank it):"]
    let hint = accessorySuggestionLine(context.objectHint, limit: accessoryObjectHintMaximumLength)
    if !hint.isEmpty { lines.append("- The seller says the object is: \(hint)") }
    if let identification = context.identification, !identification.name.isEmpty {
        var line = "- Identified from the photos as: \(identification.name) (confidence: \(identification.confidence.rawValue))"
        if !identification.seenText.isEmpty { line += "; text on it: “\(identification.seenText)”" }
        lines.append(line)
        if !identification.features.isEmpty { lines.append("- Features noted: " + identification.features.joined(separator: ", ")) }
    }
    lines.append("- The idea: \(context.idea.title)")
    if context.descriptionEdited {
        lines.append("- The seller edited the idea’s description; what the seller wants, above, is what to make.")
    }
    lines.append("- Fit it needs: \(context.idea.fit.designPhrase)")
    if !context.idea.hardware.isEmpty { lines.append("- Hardware it uses: " + context.idea.hardware.joined(separator: ", ")) }
    if !context.idea.caution.isEmpty { lines.append("- Caution: \(context.idea.caution)") }
    let guidance = measurements.compactMap { row -> String? in
        guard let how = accessoryMeasurementGuidanceHow(row) else { return nil }
        return "  - \(accessorySuggestionLine(row.label, limit: accessoryLabelMaximumLength)): \(how)"
    }
    if !guidance.isEmpty {
        lines.append("- How the seller was asked to measure:")
        lines.append(contentsOf: guidance)
    }
    return lines
}
