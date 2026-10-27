import Foundation
import simd

// MARK: - Design an Accessory from a Photo
//
// The seller adds 1–3 photos, says what the accessory is and types the measurements it depends on. Claude (Opus 5.5)
// writes a parametric OpenSCAD file; Studio checks the code (ScadSafety.swift), renders it with OpenSCAD on this Mac,
// measures the result itself and sends back the facts and four pictures, and Claude iterates. The loop is bounded
// (replies and renders per round), shows its running cost, and stops on any failure without retrying. Claude never
// edits triangles and never judges strength: Studio's own checks are shown beside what Claude says. Photos, the
// brief, the conversation and the renders stay in memory and go when the sheet closes; temporary files live under
// `accessoryTempFolderPrefix` and are removed after each render and save (and at launch, if Studio quit mid-way).
// Saving a design adds a new library model through `importModel`; Save Template… writes the .scad where the seller
// chooses. Neither sends anything.
//
// When the code declares `fit_test = false;` as a top-level Customizer value, Studio renders it a second time after
// each acceptable render with `-D fit_test=true` (locally, the same safety check, timeout and memory cap; not one of
// Claude's renders) to get a small fit-test piece, checks it against the part (`accessoryFitTestCheck`) and reports it
// to Claude. A passing piece can be saved as its own library model, "<name> (fit test)".

let accessoryTempFolderPrefix = "SlantStudio-Accessory-"
let accessoryMaximumPhotos = 3
let accessoryMaximumMeasurements = 12
let accessoryDescriptionMaximumLength = 1_000
let accessoryNotesMaximumLength = 2_000
let accessoryLabelMaximumLength = 80
/// OpenSCAD time limit per render.
let accessoryOpenSCADTimeout: TimeInterval = 120
/// Edge of each render sent to Claude and shown in the sheet.
let accessoryRenderPixelSize = 512
/// Pixel tests allowed per render (512 px sampled at 1024 × 1024): about 60 times the sample grid.
let accessoryRenderRasterBudget = 64_000_000
/// Reply limit per request. Adaptive thinking at high effort plus a full OpenSCAD file fits well within it.
let accessoryMaxTokens = 48_000

struct AccessoryDesignLimits: Equatable, Sendable {
    /// Claude replies per round (a round starts with Start Design or each Send to Claude).
    var maxReplies = 10
    /// OpenSCAD renders per round.
    var maxRenders = 4
}

// MARK: Brief

enum AccessoryMeasurementMethod: String, CaseIterable, Identifiable, Sendable {
    case calipers, ruler, estimate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .calipers: return "Calipers (±0.2 mm)"
        case .ruler: return "Ruler (±1 mm)"
        case .estimate: return "Estimate (±3 mm)"
        }
    }

    var uncertaintyMM: Double {
        switch self {
        case .calipers: return 0.2
        case .ruler: return 1
        case .estimate: return 3
        }
    }

    /// For Claude: how it was measured and how far off it may be.
    var promptPhrase: String {
        switch self {
        case .calipers: return "measured with calipers, about ±0.2 mm"
        case .ruler: return "measured with a ruler or tape, about ±1 mm"
        case .estimate: return "estimated, about ±3 mm"
        }
    }
}

/// Where and how to take a measurement, from a suggested idea (AccessorySuggestions.swift), with the name it was
/// written for. Display only; it goes to Claude only in the context of a design started from that idea.
struct AccessoryMeasurementGuidance: Equatable, Sendable {
    var label: String
    var how: String
    /// The tool the idea suggested.
    var method: AccessoryMeasurementMethod = .calipers
}

struct AccessoryMeasurement: Identifiable, Equatable, Sendable {
    let id = UUID()
    var label = ""
    var millimetres = ""
    var method: AccessoryMeasurementMethod = .calipers
    var guidance: AccessoryMeasurementGuidance?
    /// Added by Use This Idea (not typed by the seller). Such a row is removed when another idea is used, unless the
    /// seller has typed a size into it or renamed it.
    var addedByIdea = false

    var isBlank: Bool {
        label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && millimetres.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// What the seller typed. Memory only.
struct AccessoryDesignBrief: Equatable, Sendable {
    var description = ""
    var measurements: [AccessoryMeasurement] = [AccessoryMeasurement()]
    var notes = ""
}

/// "75 mm", "9.5 mm", "0.25 mm": up to two decimals, trailing zeros dropped.
func accessoryMillimetresText(_ value: Double) -> String {
    var text = String(format: "%.2f", value)
    while text.hasSuffix("0") { text.removeLast() }
    if text.hasSuffix(".") { text.removeLast() }
    return "\(text) mm"
}

/// Why the measurements can't be sent, or nil. Blank rows are ignored; at least one complete row is required.
func accessoryMeasurementsProblem(_ rows: [AccessoryMeasurement]) -> String? {
    let filled = rows.filter { !$0.isBlank }
    if filled.isEmpty {
        return "Add at least one measurement. A photo has no scale, so Claude takes every size from what you measure."
    }
    if filled.count > accessoryMaximumMeasurements { return "Use at most \(accessoryMaximumMeasurements) measurements." }
    for (index, row) in filled.enumerated() {
        let label = row.label.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = label.isEmpty ? "Measurement \(index + 1)" : "“\(label)”"
        if label.isEmpty { return "\(name) needs a name, such as “Phone thickness”." }
        if label.count > accessoryLabelMaximumLength { return "\(name) has a name longer than \(accessoryLabelMaximumLength) characters." }
        if meshFitMillimetres(row.millimetres) == nil { return "\(name) needs a size in millimetres, such as 9.5." }
    }
    return nil
}

/// One line per measurement for Claude, such as "- Phone thickness: 9.5 mm (measured with calipers, about ±0.2 mm)".
/// Rows that are blank or can't be read are left out (the sheet refuses to start with any of those).
func accessoryMeasurementLines(_ rows: [AccessoryMeasurement]) -> [String] {
    rows.compactMap { row in
        let label = row.label.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !label.isEmpty, let value = meshFitMillimetres(row.millimetres) else { return nil }
        return "- \(label): \(accessoryMillimetresText(value)) (\(row.method.promptPhrase))"
    }
}

/// Why the design can't start, or nil.
func accessoryBriefProblem(_ brief: AccessoryDesignBrief, photoCount: Int) -> String? {
    if photoCount < 1 { return "Add a photo of the object the accessory is for." }
    if photoCount > accessoryMaximumPhotos { return "Use at most \(accessoryMaximumPhotos) photos." }
    let description = brief.description.trimmingCharacters(in: .whitespacesAndNewlines)
    if description.isEmpty { return "Say what the accessory is, such as “a stand that holds this phone at 60°”." }
    if description.count > accessoryDescriptionMaximumLength { return "Describe the accessory in at most \(accessoryDescriptionMaximumLength.formatted()) characters." }
    if brief.notes.count > accessoryNotesMaximumLength { return "Keep the notes to \(accessoryNotesMaximumLength.formatted()) characters or fewer." }
    return accessoryMeasurementsProblem(brief.measurements)
}

/// The text of the first turn, after the photos. `ideaContext` (a design started from a suggested idea) adds what is
/// known about the object and the idea before the last line; without it the text is unchanged.
func accessoryFirstTurnText(_ brief: AccessoryDesignBrief, photoCount: Int, ideaContext: AccessoryDesignIdeaContext? = nil) -> String {
    var lines: [String] = []
    let photos = photoCount == 1 ? "The photo above is" : "The \(photoCount) photos above are"
    lines.append("\(photos) the seller’s, in the order they added them.")
    lines.append("")
    lines.append("What the seller wants: \(brief.description.trimmingCharacters(in: .whitespacesAndNewlines))")
    lines.append("")
    lines.append("Measurements typed by the seller (the only reliable sizes; the photos have no scale):")
    lines.append(contentsOf: accessoryMeasurementLines(brief.measurements))
    let notes = brief.notes.trimmingCharacters(in: .whitespacesAndNewlines)
    if !notes.isEmpty {
        lines.append("")
        lines.append("Seller’s notes: \(notes)")
    }
    if let ideaContext {
        lines.append("")
        lines.append(contentsOf: accessoryDesignIdeaContextLines(ideaContext, measurements: brief.measurements))
    }
    lines.append("")
    lines.append("Design the accessory, then call render_scad with the complete OpenSCAD file.")
    return lines.joined(separator: "\n")
}

/// The first user turn: the photos first, then the brief.
func accessoryFirstTurn(_ brief: AccessoryDesignBrief, photos: [PreparedImage], ideaContext: AccessoryDesignIdeaContext? = nil) -> AnthropicMessageParam {
    .user(photos.map { .image($0.anthropicImage) } + [.text(accessoryFirstTurnText(brief, photoCount: photos.count, ideaContext: ideaContext))])
}

// MARK: Prompt and tools

let accessorySystemPrompt = """
You design small functional accessories for 3D printing, as parametric OpenSCAD code, from a seller's photos and \
measurements. The seller sells printed products; Slant 3D prints them on demand on FDM printers with fixed settings \
that can't be changed for an order or a part.

Slant's print settings
- Published by Slant: 0.2 mm layers (0.3 mm first layer), a 0.4 mm nozzle, 1 mm walls (about 2 lines), 25% grid-like \
infill, overhangs up to 50° from vertical, no brims, a textured bed and a 220 mm cube build volume.
- Slant prints a part in the orientation it is uploaded in, re-orienting only an obviously wrong upload, and decides \
at upload whether it needs supports. Design the part to print exactly as it sits in your file, and avoid supports: \
Slant prices supports, surface area and failure risk, and charges extra for each separate body.
- Not published: the line width, the tolerances Slant holds and which slicer it uses. Treat every fit as unverified \
until the seller prints it.
- Slant recommends parts at least about 20 mm on a side. If the accessory must be smaller, say so in the notes.

How you work
- The photos show the object the accessory is for (or a sketch or an example). Photos have no reliable scale: take \
sizes only from the typed measurements. If a size you need isn't measured, ask with ask_seller rather than guess, \
unless a sensible default is clearly fine; then say what you assumed.
- Call render_scad with the complete OpenSCAD file. Studio renders it with OpenSCAD on the seller's Mac and replies \
with facts it measured itself (size, mesh check, wall thickness, overhangs and their heights, flat contact with the \
bed, build-volume fit, the fit sizes your code echoed, OpenSCAD messages) and pictures from the three-quarter, front, \
side and top views. Look at them critically and fix what is wrong.
- After each render, compare the pictures with the seller's photos. When the photos show the accessory itself, a \
sketch or an example of it, compare from the matching angles and look for differences in shape, features, positions \
and proportions that matter (a missing notch, a cut-out on the wrong side, a curve that doesn't follow the object). \
When they show only the object, check where the design meets it: cut-outs for ports and buttons, contact faces and \
their positions. Fix what matters before you finish. If you keep a difference on purpose, say which and why.
- If a size that must fit was only estimated, ask the seller with ask_seller to measure it with calipers rather than \
adding the estimate's ±3 mm on each side. If they skip, use the estimate with generous clearance and say so.
- If the part carries weight (a hook, bracket, shelf or mount) and the seller hasn't said how much, ask about the load.
- You have at most 4 renders and 10 replies, so plan the design before the first render and make each render count.
- When the latest render is right, call finish_design. Studio accepts finish_design only right after a render that is \
one closed solid within the 220 mm build volume. In photo_check, say in one or two sentences how the design matches \
the photos and any difference you kept on purpose; if the photos show the object rather than the accessory, say so \
("The photos show the object, not the accessory") and say how the design lines up with the object's features. Say it \
"matches the photos"; never say it fits exactly or perfectly, because only a test print shows that.
- Use exactly one tool in each reply. Keep any text outside tools short and plain: the seller reads it.

OpenSCAD conventions
- Millimetres. Z is up. The part sits flat on the bed in the orientation it should print, with its lowest face on Z = 0.
- One closed solid: union everything; no loose parts. Slant bills each separate body after the first.
- Every dimension and option is a named top-level variable set to a plain literal, declared before the first module, \
with a Customizer comment on the same line, for example `phone_thickness = 9.5; // [5:0.1:20] Phone thickness (mm)`. \
Group them with /* [Section] */ comments and put derived values in a /* [Hidden] */ section after the editable ones, \
so the seller can adjust the design later in Studio's Personalise from Template.
- $fn between 32 and 96 for curves. Keep each render well under a minute: avoid minkowski() on complex shapes, long \
hull() chains and deep recursion.
- Report every size that has to fit with echo and its name, such as `echo("slot_width", slot_width);`: slot and gap \
widths, hole diameters, inner lengths and depths. Studio shows them to the seller beside the typed measurements and \
sends them back with the facts.
- No include, use, import(), surface(), dxf_ modules or file = arguments; everything in one file. Studio refuses \
those, and any text that looks like a file path.

Designing for FDM printing (Slant's settings above, no supports)
- With 1 mm walls and 25% infill, a region much thicker than 2 mm is mostly sparse infill inside a 1 mm skin. Make \
load-bearing features walls or ribs rather than solid blocks.
- Load-bearing walls at least 2.0 mm: use 2.25 or 2.7 mm (several lines) wherever the part carries load, 1.8 mm only \
where it carries none, and never under 1.0 mm anywhere.
- Never leave closed internal voids or hidden pockets: Slant bills each one as an extra body (about $0.39 each in a \
Slant estimate on 25 Oct 2026). Where a thick region carries load, thin slots about 0.25 mm wide that open through the bottom face make the \
slicer add walls inside it while the part stays one body. Slant didn't require supports for their 0.25 mm ceilings in \
a test, though Studio may list them as overhangs.
- Overhangs at most 45° from vertical (Slant allows 50°; 45° leaves a margin); chamfer rather than leave flat \
ceilings; bridges under 5 mm. Studio reports any steeper downward faces and their heights: fix them.
- Holes: vertical holes print about 0.2 mm small, so add 0.2–0.4 mm to their diameter. Screw clearance holes: M3 \
3.4 mm, M4 4.5 mm. Make horizontal holes teardrop-shaped, point up.
- A flat base with a generous footprint, and a 0.5 mm chamfer on the bottom edge against elephant's foot. Round the \
corners of large footprints (radius 3 mm or more) against warping.
- Fillet or chamfer inside corners where load concentrates, such as the roots of arms, hooks and clips.
- Orient the part so its main loads run along the layers (in XY) rather than pulling layers apart.
- Pins and posts at least 3–5 mm across.
- Detail finer than about 0.9 mm disappears. Text at least 5 mm high and 0.8–1 mm deep (raised or cut in), on side \
walls rather than the bottom face.
- Clips and snap fits must flex within a layer (bending in XY, not across layers), be at least 5 times as long as \
they are thick, and taper towards the tip. Recommend PETG in the notes for parts that must flex.
- Fits: add 0.2–0.3 mm clearance per side for a printed fit, plus the measurement's uncertainty (calipers ±0.2 mm, \
ruler ±1 mm). Make fit-critical dimensions easy to change.
- For production, keep the height and the amount of material low where the design allows: a lower, lighter part \
prints faster and costs less.
- PLA softens around 55–60 °C: for a car or anything near heat, recommend PETG in the notes.

Fit-test piece
- When anything must fit the object (any size you echo as a fit size, or a snug or tight fit), declare \
`fit_test = false; // Print only a small fit-test piece` as a top-level value in its own /* [Fit test] */ section \
before the first module (never in [Hidden]), and leave it false. Assign fit_test only there, never again anywhere in \
the file. The seller prints the piece first to check the fit, because Slant doesn't publish its tolerances or line \
width.
- Beside fit_test, outside [Hidden], declare an editable clearance, such as \
`clearance = 0.25; // [0:0.05:1] Fit clearance per side (mm)` (or one per fit, each named with "clearance", such as \
`slot_clearance`), and drive every fit-critical size through it. The seller prints the piece days later, after this \
conversation has gone, and adjusts the fit by changing the clearance in Personalise from Template.
- With fit_test true, the file makes only the fit-critical region: the same geometry with the same sizes, cut down \
with intersection() to a box around the slot or hole, or a thin slice through the clip. Don't scale, rotate or \
redesign it, and change no size because of fit_test; you may move the piece down so it sits on Z = 0. Keep every \
fit-size echo outside any fit_test condition, so both versions echo the same values.
- Keep every fit-critical feature in the piece. Where the spacing between features matters (two mounting holes, say), \
keep both and join them with a thin bar. Make a slice through a clip or other flexing feature at least 8–10 mm thick, \
or the feature's full width, so it flexes like the part.
- The piece must be one closed solid sitting flat on Z = 0, as small and low as possible: aim for under about 15% of \
the full part's volume.
- After each render Studio can accept, Studio renders the same file again with fit_test = true on the seller's Mac. \
That doesn't count as one of your renders. It reports the piece's size and height, its share of the part's volume, \
its overhangs, whether it is one closed solid on the bed and no larger than the part, and whether its code reports \
every fit size with the same value, plus one picture when it passes. Studio doesn't check that the piece's shape \
matches the part's fit region: check that in the picture. If a check fails, fix it in your next render.
- If the seller reports a fit-test result, change the clearance, not the measurement, and keep fit_test. Apply the \
amount to the fit size: "the slot was 0.3 mm too tight" means the slot must be 0.3 mm wider, so a clearance per side \
grows by half that, 0.15 mm (a hole or pin diameter the same way). If they don't say by how much, use ask_seller to \
ask them to measure the printed piece with calipers.

Honesty
- Never call a design strong, approved, guaranteed or safe, and never give a strength percentage. Say "likely weak \
point" or "below the 2 mm guideline"; say "checks found no problems" only when Studio's checks really found none.
- Never promise a fit: say what matches the photos and the measurements, not that a part fits perfectly.
- Studio's measured facts outrank your intent: if they disagree, fix the code.
"""

/// Tool names, as Claude calls them.
enum AccessoryToolName {
    static let render = "render_scad"
    static let ask = "ask_seller"
    static let finish = "finish_design"
}

/// Strict tools. Lengths aren't in the schemas (strict tools don't support them); Studio clips what it shows.
let accessoryTools: [AnthropicTool] = [
    AnthropicTool(
        name: AccessoryToolName.render,
        description: "Render a complete OpenSCAD file with OpenSCAD on the seller's Mac. Studio replies with the facts it measured (size in mm, triangles, mesh check, wall thickness, overhangs steeper than 45° and their heights, flat contact with the bed, build-volume fit, the fit sizes the code echoed, Customizer values found, OpenSCAD messages) and four pictures; when the code declares fit_test, also the facts of the fit-test piece Studio renders from it. Code using include, use, import(), surface(), dxf_ modules or a file = argument, or text that looks like a file path, is refused without rendering.",
        inputSchema: [
            "type": "object",
            "properties": ["code": ["type": "string", "description": "The complete OpenSCAD file, at most 64 KB."]],
            "required": ["code"],
            "additionalProperties": false
        ]),
    AnthropicTool(
        name: AccessoryToolName.ask,
        description: "Ask the seller one short question, such as a measurement you need or a choice between two designs. The seller's answer comes back as the result; they may skip it, in which case use your best judgement and say what you assumed.",
        inputSchema: [
            "type": "object",
            "properties": ["question": ["type": "string", "description": "One short, plain question."]],
            "required": ["question"],
            "additionalProperties": false
        ]),
    AnthropicTool(
        name: AccessoryToolName.finish,
        description: "Finish when the latest render is the design to keep. Studio shows the seller that render, its own checks and what you write here.",
        inputSchema: [
            "type": "object",
            "properties": [
                "name": ["type": "string", "description": "A short name for the seller's library, 2–5 words, such as \"Phone stand\"."],
                "summary": ["type": "string", "description": "Two or three sentences on what the design is and how it fits the measurements."],
                "print_orientation": ["type": "string", "description": "How it should sit on the bed, and why."],
                "notes": ["type": "array", "items": ["type": "string"], "description": "Short notes for the seller: likely weak points, what to check on the first print, material advice. At most 6."],
                "photo_check": ["type": "string", "description": "One or two sentences on how the design matches the seller's photos, and any difference you kept on purpose and why. If the photos show the object, not the accessory, say so and how the design lines up with the object's features. Say it matches the photos; never that it fits exactly or perfectly."]
            ],
            "required": ["name", "summary", "print_orientation", "notes", "photo_check"],
            "additionalProperties": false
        ])
]

/// One request in the design conversation. Tools and the system prompt are cached (one breakpoint on the system block,
/// which follows the tools in the cached prefix), and so is the growing conversation (automatic caching), so photos
/// and earlier renders are read from the cache on later replies. Effort stays `high` throughout: every reply is a
/// design step, and changing it would invalidate the cached conversation.
func accessoryDesignRequest(messages: [AnthropicMessageParam]) -> AnthropicRequest {
    AnthropicRequest(maxTokens: accessoryMaxTokens,
                     system: [AnthropicSystemBlock(accessorySystemPrompt, cacheControl: .fiveMinutes)],
                     tools: accessoryTools, disableParallelToolUse: true, messages: messages,
                     effort: .high, automaticCaching: .fiveMinutes)
}

/// Sent once when Claude ends a reply without calling a tool.
let accessoryNudgeText = "Please continue by calling one tool: render_scad, ask_seller or finish_design."

// MARK: Cost forecast

struct AccessoryCostForecast: Equatable, Sendable {
    let firstReply: AnthropicCostEstimate
    let typical: AnthropicCostEstimate
    let maximum: AnthropicCostEstimate
    let typicalReplies: Int
    let maximumReplies: Int
}

/// Tokens Claude is assumed to write per reply (adaptive thinking at high effort plus code), and to keep per reply in
/// the conversation, for the forecast only.
let accessoryForecastOutputTokensPerReply = 8_000
let accessoryForecastHistoryTokensPerReply = 4_000

/// Image tokens, roughly one per 750 pixels (Anthropic's vision guidance).
func accessoryImageTokens(pixelWidth: Int, pixelHeight: Int) -> Int {
    max(1, (pixelWidth * pixelHeight + 749) / 750)
}

/// Tokens one render's tool result adds, for the forecast: the four pictures and the facts, plus the fit-test piece's
/// facts and picture (assumed on every render, as an upper bound) and the line asking Claude to compare with the photos.
var accessoryForecastRenderTokens: Int {
    let picture = accessoryImageTokens(pixelWidth: accessoryRenderPixelSize, pixelHeight: accessoryRenderPixelSize)
    return 4 * picture + 700 + picture + 250 + 60
}

/// A rough forecast before anything is sent: the first turn is written to the cache, each later reply reads the
/// conversation so far from the cache and adds one render's facts and pictures, and every reply writes about 8,000
/// tokens. Anthropic's invoice is what counts; the sheet shows the real running cost from each reply's usage.
func accessoryCostForecast(photoSizes: [(width: Int, height: Int)], textCharacters: Int,
                           limits: AccessoryDesignLimits = AccessoryDesignLimits(), typicalReplies: Int = 5) -> AccessoryCostForecast {
    let photos = photoSizes.reduce(0) { $0 + accessoryImageTokens(pixelWidth: $1.width, pixelHeight: $1.height) }
    let first = accessoryForecastFixedTokens + photos + textCharacters * 2 / 7 + 50
    return accessoryRoundForecast(firstTurnTokens: first, maximumReplies: limits.maxReplies, typicalReplies: typicalReplies)
}

/// The system prompt and tools, sent with every request.
private var accessoryForecastFixedTokens: Int {
    (accessorySystemPrompt.count + AnthropicJSON.array(accessoryTools.map(\.json)).encodedString.count) * 2 / 7
}

/// A round of up to `maximumReplies` replies whose first request carries `firstTurnTokens`, all written to the cache
/// (a later round's history may no longer be cached); each later reply reads the conversation so far from the cache,
/// adds one render's facts and pictures, and writes about 8,000 tokens.
private func accessoryRoundForecast(firstTurnTokens: Int, maximumReplies: Int, typicalReplies: Int) -> AccessoryCostForecast {
    let renderTokens = accessoryForecastRenderTokens
    func cost(replies: Int) -> AnthropicCostEstimate {
        var usage = AnthropicUsage()
        var context = 0
        for reply in 0..<max(1, replies) {
            let added = reply == 0 ? firstTurnTokens : accessoryForecastHistoryTokensPerReply + renderTokens
            usage.cacheReadInputTokens += context
            usage.cacheCreationInputTokens += added
            usage.outputTokens += accessoryForecastOutputTokensPerReply
            context += added
        }
        usage.cacheCreation5mInputTokens = usage.cacheCreationInputTokens
        return anthropicEstimatedCost(usage, model: anthropicDefaultModel)
    }
    let maximum = max(1, maximumReplies)
    let typical = min(max(1, typicalReplies), maximum)
    return AccessoryCostForecast(firstReply: cost(replies: 1), typical: cost(replies: typical), maximum: cost(replies: maximum),
                                 typicalReplies: typical, maximumReplies: maximum)
}

/// Rough input tokens of the conversation so far, for the next send's forecast: the system prompt and tools, each
/// photo at the largest size Studio sends Claude, each render picture at its own size, and the text (Claude's turns
/// as stored, which overstates a little).
func accessoryConversationTokens(_ messages: [AnthropicMessageParam]) -> Int {
    let photo = accessoryImageTokens(pixelWidth: 1568, pixelHeight: 1176)
    let picture = accessoryImageTokens(pixelWidth: accessoryRenderPixelSize, pixelHeight: accessoryRenderPixelSize)
    var characters = 0
    var tokens = accessoryForecastFixedTokens
    for message in messages {
        for block in message.content {
            switch block {
            case .text(let text, _): characters += text.count
            case .image: tokens += photo
            case .toolResult(_, let content, _, _):
                for item in content {
                    switch item {
                    case .text(let text): characters += text.count
                    case .image: tokens += picture
                    }
                }
            case .raw(let json): characters += json.encodedString.count
            }
        }
    }
    return tokens + characters * 2 / 7
}

/// The cost of the next send in a design that has started: Send Answer or Skip carry on in the current round with the
/// replies it has left; Send to Claude and Send Again start a new round. Nil when nothing would be sent (no replies
/// left in the round).
func accessoryNextSendForecast(messages: [AnthropicMessageParam], repliesLeft: Int, typicalReplies: Int = 5) -> AccessoryCostForecast? {
    guard repliesLeft > 0 else { return nil }
    // The seller's answer or note is short; allow for it.
    return accessoryRoundForecast(firstTurnTokens: accessoryConversationTokens(messages) + 300, maximumReplies: repliesLeft,
                                  typicalReplies: typicalReplies)
}

/// "Estimated cost of sending: about $0.40 if Claude needs 5 replies, at most about $1.10 if it uses all 10. …", shown
/// beside the buttons that send again once a design has started.
func accessoryNextSendForecastText(_ forecast: AccessoryCostForecast, newRound: Bool) -> String {
    let limit = newRound ? "all \(forecast.maximumReplies)" : "the \(forecast.maximumReplies) left in this round"
    let estimate = forecast.typicalReplies < forecast.maximumReplies
        ? "\(anthropicCostText(forecast.typical)) if Claude needs \(forecast.typicalReplies) replies, at most \(anthropicCostText(forecast.maximum)) if it uses \(limit)"
        : "at most \(anthropicCostText(forecast.maximum)) if Claude uses \(limit)"
    return "Estimated cost of sending: \(estimate). Anthropic bills your account."
}

/// Said once in Design an Accessory (and its Ideas) when no Claude key is saved.
let accessoryMissingClaudeKeyText = "Add your Anthropic API key in Settings › Design Tools › Claude (Anthropic)."

/// "Estimated cost: about $0.90 for a typical design (5 replies), at most about $1.90 if Claude uses all 10. …"
func accessoryCostForecastText(_ forecast: AccessoryCostForecast) -> String {
    "Estimated cost: \(anthropicCostText(forecast.typical)) for a typical design (\(forecast.typicalReplies) replies), at most "
        + "\(anthropicCostText(forecast.maximum)) if Claude uses all \(forecast.maximumReplies). Anthropic bills your account; "
        + "the real cost is shown as Claude works."
}

/// Adds two estimates; the total is complete only when both are.
func accessoryAddCost(_ a: AnthropicCostEstimate, _ b: AnthropicCostEstimate) -> AnthropicCostEstimate {
    AnthropicCostEstimate(usd: a.usd + b.usd, complete: a.complete && b.complete)
}

// MARK: Render facts

struct AccessoryRenderImage: Identifiable, Equatable, Sendable {
    var id: String { title }
    let title: String
    let image: PreparedImage
}

/// The views sent with every render, in this order.
let accessoryRenderAngles: [ListingImageAngle] = [.threeQuarter, .front, .side, .top]

/// What each picture shows, for Claude (directions in the model's own axes).
func accessoryRenderViewCaption(_ angle: ListingImageAngle) -> String {
    switch angle {
    case .threeQuarter: return "Three-quarter view (from front right, above)"
    case .front: return "Front view (looking along +Y from the −Y side)"
    case .side: return "Side view (looking along −X from the +X side)"
    case .top: return "Top view (looking down along −Z; +Y is up the picture)"
    case .back: return "Back view"
    case .rearThreeQuarter: return "Rear three-quarter view"
    }
}

/// What Studio measured on one render, on this Mac.
struct AccessoryRenderFacts: Equatable, Sendable {
    var sizeMM: SIMD3<Float>
    var lowestZ: Float
    var triangles: Int
    var health: MeshHealthReport
    var contactAreaMM2: Double
    var footprintMM2: Double
    /// Nil when the measurement was skipped (not a closed solid).
    var wallThickness: WallThicknessSummary?
    /// Downward faces steeper than 45° from vertical (`overhangShare`, the same rule as Review for Printing).
    var overhang = OverhangShare(overhangAreaMM2: 0, surfaceAreaMM2: 0)
    /// Where those faces are; nil when there are none.
    var overhangLocation: AccessoryOverhangLocation?
    /// Sizes the code reported with `echo` as ones that must fit.
    var fitSizes: [AccessoryFitSize] = []
    var customizerValues: [String]
    var openSCADMessages: [String]
    /// How the code declares `fit_test` (`accessoryFitTestDeclaration`).
    var fitTestDeclaration: AccessoryFitTestDeclaration = .none

    /// The enclosed volume in mm³ (the mesh check's signed volume); meaningful only for one closed solid.
    var volumeMM3: Double { health.signedVolume }
    var isOneClosedSolid: Bool {
        health.isClosed && health.isConsistentlyOriented && !health.isInsideOut && health.shells == 1
    }
    var fitsBuildVolume: Bool { sizeMM.max() <= slantBuildVolumeMM }
    var sitsOnBed: Bool { abs(lowestZ) <= 0.01 }
    /// Enough overhang to need supports or a redesign: at least `accessoryOverhangNotableShare` of the surface.
    var hasNotableOverhangs: Bool { overhang.overhangAreaMM2 > 0 && overhang.fraction >= accessoryOverhangNotableShare }
}

// MARK: Overhangs

/// Share of the surface above which overhangs are reported to the seller as needing supports or a redesign. Below it
/// (a few small curved edges, say) they are still listed for Claude.
let accessoryOverhangNotableShare = 0.01

/// One 1 mm height band of overhanging faces, by the band's lower edge in the model's own Z.
struct AccessoryOverhangBand: Equatable, Sendable {
    let bottomZ: Int
    let areaMM2: Double
}

/// Where the faces `overhangShare` counts are: their full Z range and the 1 mm bands with the most overhanging area
/// (at most 3, largest first), in the model's own coordinates so Claude can find them in its code.
struct AccessoryOverhangLocation: Equatable, Sendable {
    let lowestZ: Float
    let highestZ: Float
    let mainBands: [AccessoryOverhangBand]
}

/// The location of the overhangs, by the same face rule as `overhangShare` (PrintReview.swift): a face whose normal
/// points down more steeply than 45° from vertical, except faces lying flat on the bed. Nil when there are none.
/// Deterministic: triangles in index order, ties broken by height.
func accessoryOverhangLocation(_ mesh: STLMesh) -> AccessoryOverhangLocation? {
    let v = mesh.vertices
    let floor = Double(mesh.minimum.z) + 0.0001
    var low = Double.infinity, high = -Double.infinity
    var bands: [Int: Double] = [:]
    var i = 0
    while i + 8 < v.count {
        let a = SIMD3<Double>(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))
        let b = SIMD3<Double>(Double(v[i + 3]), Double(v[i + 4]), Double(v[i + 5]))
        let c = SIMD3<Double>(Double(v[i + 6]), Double(v[i + 7]), Double(v[i + 8]))
        i += 9
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        guard length > 0, length.isFinite else { continue }
        let nz = cross.z / length
        let onBed = max(a.z, b.z, c.z) <= floor && nz <= -0.999999
        guard !onBed, nz < -printReviewOverhangCosine else { continue }
        low = min(low, a.z, b.z, c.z)
        high = max(high, a.z, b.z, c.z)
        let centre = (a.z + b.z + c.z) / 3
        guard centre.isFinite, abs(centre) < 1e6 else { continue }
        bands[Int(centre.rounded(.down)), default: 0] += length / 2
    }
    guard low <= high else { return nil }
    let main = bands.map { AccessoryOverhangBand(bottomZ: $0.key, areaMM2: $0.value) }
        .sorted { $0.areaMM2 != $1.areaMM2 ? $0.areaMM2 > $1.areaMM2 : $0.bottomZ < $1.bottomZ }
        .prefix(3)
    return AccessoryOverhangLocation(lowestZ: Float(low), highestZ: Float(high), mainBands: Array(main))
}

/// One line about overhangs, for Claude and the seller, such as "Overhangs: 4% of the surface (120 mm²) faces down
/// more steeply than 45° from vertical, between Z = 12.0 and 30.5 mm; most at Z 12–13 mm (80 mm²)."
func accessoryOverhangLine(_ share: OverhangShare, location: AccessoryOverhangLocation?) -> String {
    guard share.overhangAreaMM2 > 0, let location else {
        return "Overhangs: no downward faces steeper than 45° from vertical."
    }
    var line = "Overhangs: \(percentLabel(share.fraction)) of the surface (\(Int(share.overhangAreaMM2.rounded()).formatted()) mm²) faces down more steeply than 45° from vertical"
    line += location.highestZ - location.lowestZ < 0.05
        ? ", at Z = \(accessoryOneDecimal(location.lowestZ)) mm"
        : ", between Z = \(accessoryOneDecimal(location.lowestZ)) and \(accessoryOneDecimal(location.highestZ)) mm"
    if !location.mainBands.isEmpty {
        let bands = location.mainBands.map { "Z \($0.bottomZ)–\($0.bottomZ + 1) mm (\(Int($0.areaMM2.rounded()).formatted()) mm²)" }
        line += "; most at " + bands.joined(separator: ", ")
    }
    return line + "."
}

// MARK: Fit sizes

/// A size the design reported with `echo("name", value)` (or `echo(name = value)`) as one that must fit.
struct AccessoryFitSize: Equatable, Sendable {
    let name: String
    let millimetres: Double
}

let accessoryMaximumFitSizes = 20

private let accessoryNumberPattern = #"([-+]?(?:[0-9]+\.?[0-9]*|\.[0-9]+)(?:[eE][-+]?[0-9]+)?)"#

/// The fit sizes in OpenSCAD's log: `ECHO: "slot_width", 9.9` or `ECHO: slot_width = 9.9`, one name and one number per
/// line, in order, the first of each name only, at most `accessoryMaximumFitSizes`. Other echoes are ignored.
func accessoryFitSizes(_ log: String) -> [AccessoryFitSize] {
    var result: [AccessoryFitSize] = []
    var seen: Set<String> = []
    for raw in log.split(whereSeparator: \.isNewline) {
        guard let fit = accessoryFitSize(fromLogLine: String(raw)), seen.insert(fit.name).inserted else { continue }
        result.append(fit)
        if result.count == accessoryMaximumFitSizes { break }
    }
    return result
}

/// One log line as a fit size, or nil.
func accessoryFitSize(fromLogLine raw: String) -> AccessoryFitSize? {
    let line = raw.trimmingCharacters(in: .whitespaces)
    guard line.hasPrefix("ECHO:") else { return nil }
    let patterns = [#"^ECHO:\s*"([A-Za-z0-9_ .\-]{1,60})"\s*,\s*"# + accessoryNumberPattern + #"\s*$"#,
                    #"^ECHO:\s*([A-Za-z_$][A-Za-z0-9_$]{0,59})\s*=\s*"# + accessoryNumberPattern + #"\s*$"#]
    for pattern in patterns {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let nameRange = Range(match.range(at: 1), in: line), let valueRange = Range(match.range(at: 2), in: line),
              let value = Double(line[valueRange]), value.isFinite else { continue }
        let name = line[nameRange].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return AccessoryFitSize(name: name, millimetres: value)
    }
    return nil
}

/// "slot_width 9.9 mm", as listed for Claude and the seller.
func accessoryFitSizeText(_ fit: AccessoryFitSize) -> String {
    "\(fit.name) \(accessoryMillimetresText(fit.millimetres))"
}

// MARK: Fit-test piece

/// The Customizer value that switches the file to its small fit-test piece.
let accessoryFitTestVariable = "fit_test"
/// The piece must use less than this share of the part's volume.
let accessoryFitTestMaximumVolumeShare = 0.5
/// Above this share the piece is flagged as larger than it needs to be (advisory).
let accessoryFitTestLargeVolumeShare = 0.25
/// How closely the piece's echoed fit sizes must match the part's, in mm.
let accessoryFitTestFitSizeTolerance = 0.001

/// How the code declares `fit_test`.
enum AccessoryFitTestDeclaration: Equatable, Sendable {
    /// Not mentioned at all.
    case none
    /// Mentioned, but not as a top-level Customizer value before the first module (inside a module, after one, or in
    /// a [Hidden] section).
    case notCustomizerValue
    /// A top-level Customizer value, but not `true`/`false`.
    case notBoolean
    /// `fit_test = true;`: the file as written makes only the piece.
    case defaultTrue
    /// `fit_test = false;`: Studio can render the piece with `-D fit_test=true`.
    case ready
}

/// Where `fit_test` appears in the code itself (comments and strings skipped): how many top-level assignments
/// (`fit_test = …` outside any bracket, anywhere in the file, [Hidden] and after modules included) and whether it is
/// mentioned at all.
func accessoryFitTestUses(_ code: String) -> (topLevelAssignments: Int, mentioned: Bool) {
    var state = ScadScanState()
    var assignments = 0
    var mentioned = false
    let name = Array(accessoryFitTestVariable)
    func isIdentifier(_ char: Character) -> Bool { char.isASCII && (char.isLetter || char.isNumber || char == "_" || char == "$") }
    let lines = code.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        .split(separator: "\n", omittingEmptySubsequences: false)
    for line in lines {
        var inString = state.inString
        var depth = state.depth
        let chars = Array(scadScanLine(String(line), state: &state).code)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if inString {
                if char == "\\" { index += 2; continue }
                if char == "\"" { inString = false }
                index += 1
                continue
            }
            switch char {
            case "\"": inString = true
            case "{", "[", "(": depth += 1
            case "}", "]", ")": depth = max(0, depth - 1)
            default: break
            }
            if char == name[0], index + name.count <= chars.count, Array(chars[index..<(index + name.count)]) == name,
               index == 0 || !isIdentifier(chars[index - 1]),
               index + name.count == chars.count || !isIdentifier(chars[index + name.count]) {
                mentioned = true
                var after = index + name.count
                while after < chars.count, chars[after].isWhitespace { after += 1 }
                if depth == 0, after < chars.count, chars[after] == "=", after + 1 >= chars.count || chars[after + 1] != "=" {
                    assignments += 1
                }
                index += name.count
                continue
            }
            index += 1
        }
    }
    return (assignments, mentioned)
}

/// Reads the code's `fit_test` declaration with the same Customizer detection as Personalise from Template. It is
/// `.ready` only when the one top-level assignment is the Customizer's `fit_test = false;`: a second assignment
/// anywhere at the top level (in [Hidden] or after the modules) would win, so the file might make only the piece.
func accessoryFitTestDeclaration(_ code: String) -> AccessoryFitTestDeclaration {
    let uses = accessoryFitTestUses(code)
    guard uses.mentioned else { return .none }
    guard let parameter = scadTemplateParameters(code).parameters.first(where: { $0.name == accessoryFitTestVariable }),
          uses.topLevelAssignments == 1 else { return .notCustomizerValue }
    guard parameter.kind == .boolean else { return .notBoolean }
    return parameter.defaultValue == "true" ? .defaultTrue : .ready
}

/// The top-level Customizer values whose name contains "clearance", which Personalise from Template can change.
func accessoryClearanceValueNames(_ code: String) -> [String] {
    scadTemplateParameters(code).parameters.filter { $0.kind == .number && $0.name.lowercased().contains("clearance") }.map(\.name)
}

/// The `-D` assignment that makes the piece, `fit_test=true`, only when the code declares `fit_test = false;` as a
/// top-level Customizer value; empty otherwise.
func accessoryFitTestAssignments(_ code: String) -> [ScadAssignment] {
    accessoryFitTestDeclaration(code) == .ready ? [ScadAssignment(name: accessoryFitTestVariable, literal: "true")] : []
}

/// A fit size the piece didn't echo, or echoed with a different value.
struct AccessoryFitSizeMismatch: Equatable, Sendable {
    let name: String
    let partMM: Double
    /// Nil when the piece didn't echo it.
    let pieceMM: Double?
}

/// A share as a percentage. Within a point of the 25% and 50% thresholds it shows one decimal, rounded towards the
/// side the check decided, so the label and the verdict never disagree ("49.9%" passes, "50.0%" doesn't).
func accessoryShareLabel(_ share: Double) -> String {
    for threshold in [accessoryFitTestLargeVolumeShare, accessoryFitTestMaximumVolumeShare] where abs(share - threshold) < 0.01 {
        let tenths = share * 1_000
        let rounded = share < threshold ? tenths.rounded(.down) : (share > threshold ? tenths.rounded(.up) : tenths.rounded())
        return String(format: "%.1f%%", rounded / 10)
    }
    return percentLabel(share)
}

/// Studio's checks of the fit-test piece against the full part. They cover the piece's size, volume and the fit sizes
/// its code reports, not whether its shape matches the part's fit region.
struct AccessoryFitTestCheck: Equatable, Sendable {
    var isOneClosedSolid: Bool
    var sitsOnBed: Bool
    var fitsBuildVolume: Bool
    /// No side longer than the part's matching side (sides compared largest to largest, so a 90° turn is allowed).
    var withinPartSize: Bool
    /// The piece's volume as a share of the part's; nil unless both are closed solids.
    var volumeShare: Double?
    var fitSizeMismatches: [AccessoryFitSizeMismatch]
    /// How many fit sizes the part echoed.
    var partFitSizeCount: Int
    /// The same size and volume as the part (within 0.1%): `fit_test = true` didn't change the model.
    var equalsPart = false
    /// The piece's overhangs (the same rule as the part's) and its height beside the part's.
    var overhang = OverhangShare(overhangAreaMM2: 0, surfaceAreaMM2: 0)
    var heightMM: Float = 0
    var partHeightMM: Float = 0

    var isSmallerThanPart: Bool { volumeShare.map { $0 < accessoryFitTestMaximumVolumeShare } ?? false }
    /// Over a quarter of the part: it passes, but could be cut down further.
    var isLargerThanNeeded: Bool { volumeShare.map { $0 > accessoryFitTestLargeVolumeShare } ?? false }
    var passes: Bool { problems.isEmpty }

    /// Why the piece fails, most important first; empty when it passes.
    var problems: [String] {
        var result: [String] = []
        if equalsPart { result.append("It is the same model as the part.") }
        if !isOneClosedSolid { result.append("It isn’t one closed solid.") }
        if !sitsOnBed { result.append("It doesn’t sit on the bed (Z = 0).") }
        if !fitsBuildVolume { result.append("It doesn’t fit Slant’s \(Int(slantBuildVolumeMM)) mm build volume.") }
        if !withinPartSize { result.append("It is larger than the part along at least one side.") }
        if isOneClosedSolid, !isSmallerThanPart, !equalsPart {
            let share = volumeShare.map { "It uses \(accessoryShareLabel($0)) of the part’s volume" } ?? "Its volume couldn’t be compared with the part’s"
            result.append("\(share); it must use under \(percentLabel(accessoryFitTestMaximumVolumeShare)).")
        }
        if !fitSizeMismatches.isEmpty { result.append("Its code doesn’t report all the part’s fit sizes with the same values.") }
        return result
    }
}

/// Checks the piece rendered with `fit_test = true` against the full part: one closed solid on the bed, within the
/// build volume, no larger than the part, under half its volume, and every fit size the part echoed echoed again with
/// the same value (±0.001 mm). Sizes only the piece echoes are ignored.
func accessoryFitTestCheck(piece: AccessoryRenderFacts, part: AccessoryRenderFacts) -> AccessoryFitTestCheck {
    let pieceSides = [piece.sizeMM.x, piece.sizeMM.y, piece.sizeMM.z].sorted()
    let partSides = [part.sizeMM.x, part.sizeMM.y, part.sizeMM.z].sorted()
    let within = zip(pieceSides, partSides).allSatisfy { $0 <= $1 + 0.01 }
    var share: Double?
    if piece.isOneClosedSolid, part.isOneClosedSolid, part.volumeMM3 > 0, piece.volumeMM3.isFinite {
        share = piece.volumeMM3 / part.volumeMM3
    }
    let sameSize = (0..<3).allSatisfy { abs(piece.sizeMM[$0] - part.sizeMM[$0]) <= max(part.sizeMM[$0], 0.01) * 0.001 }
    let equalsPart = sameSize && share.map { abs($0 - 1) <= 0.001 } == true
    var mismatches: [AccessoryFitSizeMismatch] = []
    for fit in part.fitSizes {
        let echoed = piece.fitSizes.first { $0.name == fit.name }
        if let echoed, abs(echoed.millimetres - fit.millimetres) <= accessoryFitTestFitSizeTolerance { continue }
        mismatches.append(AccessoryFitSizeMismatch(name: fit.name, partMM: fit.millimetres, pieceMM: echoed?.millimetres))
    }
    return AccessoryFitTestCheck(isOneClosedSolid: piece.isOneClosedSolid, sitsOnBed: piece.sitsOnBed,
                                 fitsBuildVolume: piece.fitsBuildVolume, withinPartSize: within, volumeShare: share,
                                 fitSizeMismatches: mismatches, partFitSizeCount: part.fitSizes.count, equalsPart: equalsPart,
                                 overhang: piece.overhang, heightMM: piece.sizeMM.z, partHeightMM: part.sizeMM.z)
}

/// "slot_width: 9.9 mm in the part, 10.1 mm in the piece" or "hole_d: 3.4 mm in the part, not echoed by the piece".
func accessoryFitSizeMismatchText(_ mismatch: AccessoryFitSizeMismatch) -> String {
    let piece = mismatch.pieceMM.map { "\(accessoryMillimetresText($0)) in the piece" } ?? "not echoed by the piece"
    return "\(mismatch.name): \(accessoryMillimetresText(mismatch.partMM)) in the part, \(piece)"
}

/// "8.0 mm high, 40% of the part’s 20.0 mm".
func accessoryFitTestHeightText(_ check: AccessoryFitTestCheck) -> String {
    var text = "\(accessoryOneDecimal(check.heightMM)) mm high"
    if check.partHeightMM > 0 {
        text += ", \(percentLabel(Double(check.heightMM / check.partHeightMM))) of the part’s \(accessoryOneDecimal(check.partHeightMM)) mm"
    }
    return text
}

/// The small piece Studio rendered from the same code with `fit_test = true`, with one three-quarter picture.
struct AccessoryFitTestPiece: Identifiable, Sendable {
    let id = UUID()
    let stl: Data
    let mesh: STLMesh
    let facts: AccessoryRenderFacts
    let image: AccessoryRenderImage?
    let check: AccessoryFitTestCheck
}

enum AccessoryFitTestOutcome: Sendable {
    case made(AccessoryFitTestPiece)
    /// OpenSCAD or Studio couldn't make the piece; the text says why.
    case failed(String)
    /// The seller pressed Stop while it was rendering. The part's render is kept.
    case stopped
}

/// The piece's render outcome, checked against the part.
func accessoryFitTestOutcome(_ outcome: AccessoryRenderOutcome, part: AccessoryRenderFacts) -> AccessoryFitTestOutcome {
    switch outcome {
    case .rendered(let piece):
        return .made(AccessoryFitTestPiece(stl: piece.stl, mesh: piece.mesh, facts: piece.facts, image: piece.images.first,
                                           check: accessoryFitTestCheck(piece: piece.facts, part: part)))
    case .failed(let text):
        return .failed(text)
    }
}

/// Why a render whose fit-test piece is the same model as the part can't be finished: `fit_test = true` changed
/// nothing, so either the part already is the piece or the piece isn't made.
let accessoryFitTestEqualsPartProblem = "With fit_test = true the file makes the same model as without it, so either fit_test is already true somewhere or it changes nothing. Make fit_test false give the whole part and true only the fit-critical region, or remove fit_test."

/// The "Fit-test piece" block of a render's tool result, or nil when there is nothing to say (no fit_test and no fit
/// sizes).
func accessoryFitTestFactsText(_ render: AccessoryRender) -> String? {
    let facts = render.facts
    let declare = "declare `fit_test = false; // Print only a small fit-test piece` as a top-level value before the first module"
    switch facts.fitTestDeclaration {
    case .none:
        guard !facts.fitSizes.isEmpty else { return nil }
        return "Fit-test piece: none, because the code doesn’t declare fit_test. This design echoes fit sizes, so \(declare), and make only the fit-critical region when it is true."
    case .notCustomizerValue:
        let assignments = accessoryFitTestUses(render.code).topLevelAssignments
        if assignments > 1 {
            return "Fit-test piece: none, because fit_test is assigned \(assignments) times at the top level, and OpenSCAD uses the last one, so the file could make only the piece. Assign it once: \(declare), outside [Hidden]."
        }
        return "Fit-test piece: none, because fit_test isn’t a top-level Customizer value: \(declare), outside [Hidden]."
    case .notBoolean:
        return "Fit-test piece: none, because fit_test isn’t true or false: \(declare)."
    case .defaultTrue:
        return "Fit-test piece: none. fit_test is true in the code, so this render is already the piece and the file doesn’t make the whole part. Set fit_test = false; Studio makes the piece itself."
    case .ready:
        break
    }
    var lines: [String] = []
    switch render.fitTest {
    case nil:
        lines.append("Fit-test piece: not made, because Studio makes it only after a render it can accept as the finished design.")
    case .stopped?:
        lines.append("Fit-test piece: not made, because the seller pressed Stop while Studio was rendering it.")
    case .failed(let text)?:
        lines.append("Fit-test piece: Studio rendered this file again with fit_test = true, and it failed. \(text)\nFix this in your next render.")
    case .made(let piece)?:
        lines.append("Fit-test piece: Studio rendered this file again with fit_test = true (not one of your renders).")
        let size = piece.facts.sizeMM
        let check = piece.check
        var sizeLine = "Size: \(accessoryOneDecimal(size.x)) × \(accessoryOneDecimal(size.y)) × \(accessoryOneDecimal(size.z)) mm (\(accessoryFitTestHeightText(check))); triangles: \(piece.facts.triangles.formatted())"
        if let share = check.volumeShare { sizeLine += "; volume: \(accessoryShareLabel(share)) of the part’s" }
        lines.append(sizeLine + ".")
        func yes(_ flag: Bool) -> String { flag ? "yes" : "no" }
        lines.append("One closed solid: \(yes(check.isOneClosedSolid)). On the bed (Z = 0): \(yes(check.sitsOnBed)). "
                     + "Fits the build volume: \(yes(check.fitsBuildVolume)). No side longer than the part’s: \(yes(check.withinPartSize)). "
                     + "Under half the part’s volume: \(yes(check.isSmallerThanPart)).")
        lines.append(accessoryOverhangLine(check.overhang, location: piece.facts.overhangLocation))
        if check.partFitSizeCount == 0 {
            lines.append("Fit sizes: the part’s code reports none, so Studio had none to compare.")
        } else if check.fitSizeMismatches.isEmpty {
            lines.append("Fit sizes: the piece’s code reports the same fit sizes as the part’s (\(check.partFitSizeCount) of \(check.partFitSizeCount)). Studio compares only these values and the size and volume, not the shape, so check in the picture that the piece keeps every slot, hole or clip that must fit.")
        } else {
            lines.append("Fit sizes that differ or are missing: " + check.fitSizeMismatches.map(accessoryFitSizeMismatchText).joined(separator: "; ") + ".")
        }
        if check.equalsPart {
            lines.append("The piece is the same model as the part. \(accessoryFitTestEqualsPartProblem)")
        } else if check.passes {
            lines.append(piece.image != nil ? "The piece passes Studio’s checks; its picture follows the part’s." : "The piece passes Studio’s checks.")
            if check.isLargerThanNeeded { lines.append("It is larger than it needs to be: cut it down to just the fit-critical region.") }
        } else {
            lines.append("The piece doesn’t pass: \(check.problems.joined(separator: " ")) Fix this in your next render.")
        }
    }
    if !facts.fitSizes.isEmpty, accessoryClearanceValueNames(render.code).isEmpty {
        lines.append("Clearance: no top-level Customizer value has “clearance” in its name. Declare `clearance = 0.25; // [0:0.05:1] Fit clearance per side (mm)` beside fit_test, outside [Hidden], and drive every fit size through it, so the seller can adjust the fit in Personalise from Template after printing the piece.")
    }
    return lines.joined(separator: "\n")
}

/// The line after a render's pictures asking Claude to compare them with the seller's photos where that makes sense.
let accessoryPhotoComparisonText = "If the seller’s photos show the accessory itself, a sketch or an example of it, compare these pictures with them from the matching angles and fix differences in shape, features, positions or proportions that matter. If they show only the object, check where the design meets it: cut-outs for ports and buttons, contact faces and their positions. Say which differences you keep on purpose."

/// Why Studio won't accept this render as a finished design; empty when it will.
func accessoryRenderProblems(_ facts: AccessoryRenderFacts) -> [String] {
    var problems: [String] = []
    if !facts.health.isClosed {
        problems.append("The surface isn’t closed (\(facts.health.openEdges.formatted()) open and \(facts.health.nonManifoldEdges.formatted()) non-manifold edges).")
    } else if !facts.health.isConsistentlyOriented || facts.health.isInsideOut {
        problems.append("Some faces point the wrong way.")
    }
    if facts.health.shells > 1 {
        problems.append("It is \(facts.health.shells.formatted()) separate parts; union them into one solid.")
    }
    if !facts.fitsBuildVolume {
        problems.append("Its largest side is \(accessoryMillimetresText(Double(facts.sizeMM.max()))), over Slant’s \(Int(slantBuildVolumeMM)) mm build volume.")
    }
    if facts.fitTestDeclaration == .defaultTrue {
        problems.append("fit_test is true in the code, so the file makes only the fit-test piece; set fit_test = false.")
    }
    return problems
}

private func accessoryOneDecimal(_ value: Float) -> String { String(format: "%.1f", value) }

/// The text part of a render's tool result: Studio's own measurements, plain and in a fixed order.
/// `extraProblems` are the render's own (`AccessoryRender.problems` beyond the facts'), such as a fit-test piece that is
/// the same model as the part.
func accessoryRenderFactsText(_ facts: AccessoryRenderFacts, renderNumber: Int, maxRenders: Int, extraProblems: [String] = []) -> String {
    var lines: [String] = []
    lines.append("Render \(renderNumber) of \(maxRenders) this round, made by OpenSCAD on the seller’s Mac and measured by Studio.")
    let size = facts.sizeMM
    lines.append("Size: \(accessoryOneDecimal(size.x)) × \(accessoryOneDecimal(size.y)) × \(accessoryOneDecimal(size.z)) mm (X width × Y depth × Z height).")
    if facts.sitsOnBed {
        lines.append("Lowest point: Z = 0 (on the bed).")
    } else {
        lines.append("Lowest point: Z = \(String(format: "%.2f", facts.lowestZ)) mm, not on the bed (Z = 0). Move it so the base is on Z = 0.")
    }
    lines.append("Triangles: \(facts.triangles.formatted()).")
    let summary = meshHealthSummary(facts.health)
    lines.append("Mesh check: \(summary.title).")
    for detail in summary.details { lines.append("  - \(detail)") }
    if facts.fitsBuildVolume {
        lines.append("Build volume: fits Slant’s \(Int(slantBuildVolumeMM)) mm limit.")
    } else {
        lines.append("Build volume: doesn’t fit; the largest side is \(accessoryOneDecimal(size.max())) mm and the limit is \(Int(slantBuildVolumeMM)) mm.")
    }
    lines.append("Flat contact with the bed: \(Int(facts.contactAreaMM2.rounded()).formatted()) mm² of a \(Int(facts.footprintMM2.rounded()).formatted()) mm² footprint.")
    if let wall = facts.wallThickness {
        lines.append("\(wall.line).")
        for detail in wall.details { lines.append("  - \(detail)") }
    } else {
        lines.append("Wall thickness: not measured, because the model isn’t one closed solid.")
    }
    lines.append(accessoryOverhangLine(facts.overhang, location: facts.overhangLocation))
    if facts.hasNotableOverhangs {
        lines.append("  - These need supports, which Slant may not add. Chamfer them to 45° or less, make horizontal holes teardrop-shaped, or turn the part so they face up.")
    }
    if facts.fitSizes.isEmpty {
        lines.append("Fit sizes echoed by the code: none. echo(\"name\", value) every size that must fit (slot widths, hole diameters, inner lengths) so Studio can show them beside the seller’s measurements.")
    } else {
        lines.append("Fit sizes echoed by the code: \(facts.fitSizes.map(accessoryFitSizeText).joined(separator: ", ")). Check each against the seller’s measurement plus clearance.")
    }
    if facts.customizerValues.isEmpty {
        lines.append("Customizer values found: none. Put each dimension in a top-level variable set to a literal, before the first module.")
    } else {
        let shown = facts.customizerValues.prefix(20).joined(separator: ", ")
        let more = facts.customizerValues.count > 20 ? ", and \(facts.customizerValues.count - 20) more" : ""
        lines.append("Customizer values found: \(facts.customizerValues.count) (\(shown)\(more)).")
    }
    if facts.openSCADMessages.isEmpty {
        lines.append("OpenSCAD messages: none.")
    } else {
        lines.append("OpenSCAD messages:")
        for message in facts.openSCADMessages { lines.append("  \(message)") }
    }
    let problems = accessoryRenderProblems(facts) + extraProblems
    if problems.isEmpty {
        lines.append("Studio can accept this render as the finished design.")
    } else {
        lines.append("Studio can’t accept this render as the finished design yet: \(problems.joined(separator: " "))")
    }
    return lines.joined(separator: "\n")
}

/// The messages worth passing on from OpenSCAD's log (errors, warnings, echoes, traces), at most 12 lines of 300
/// characters, with the temporary folder's path removed so only "design.scad" is named. Echoes read as fit sizes
/// (`accessoryFitSizes`) are reported there instead.
func accessoryOpenSCADMessages(_ log: String) -> [String] {
    let prefixes = ["ERROR", "WARNING", "ECHO", "TRACE", "DEPRECATED"]
    var result: [String] = []
    for raw in log.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard prefixes.contains(where: { line.uppercased().hasPrefix($0) }), accessoryFitSize(fromLogLine: line) == nil else { continue }
        var cleaned = line.replacingOccurrences(of: #"[^\s,"'()]*/design\.scad"#, with: "design.scad", options: .regularExpression)
        cleaned = cleaned.replacingOccurrences(of: #"/(private/)?(var|tmp|Users)/[^\s,"']*"#, with: "[path]", options: .regularExpression)
        if cleaned.count > 300 { cleaned = String(cleaned.prefix(300)) + "…" }
        result.append(cleaned)
        if result.count == 12 { break }
    }
    return result
}

/// What to tell Claude (and the seller) when OpenSCAD didn't produce a model.
func accessoryOpenSCADFailureText(_ error: OpenSCADRunError, messages: [String]) -> String {
    var text: String
    switch error {
    case .timedOut(let seconds):
        text = "OpenSCAD didn’t finish within \(Int(seconds)) seconds, so Studio stopped it. Lower $fn, and avoid minkowski() on complex shapes, long hull() chains and deep recursion."
    case .outputTooLarge:
        text = "OpenSCAD’s output grew past Studio’s 128 MB limit, so Studio stopped it. Lower $fn and simplify the shape."
    case .tooMuchMemory:
        text = "OpenSCAD used too much memory, so Studio stopped it. Lower $fn, and avoid minkowski() on complex shapes, long hull() chains and deep recursion."
    case .failed(let status, _):
        text = "OpenSCAD couldn’t render the code (exit code \(status))."
    case .noOutput:
        text = "OpenSCAD finished without writing a model; the top-level object may be empty."
    case .cancelled:
        text = "The render was stopped."
    }
    if !messages.isEmpty { text += "\nOpenSCAD messages:\n" + messages.map { "  \($0)" }.joined(separator: "\n") }
    return text
}

// MARK: Renders

/// One rendered design: the code, Studio's binary STL of it, the parsed mesh, the facts and the pictures.
struct AccessoryRender: Identifiable, Sendable {
    let id = UUID()
    let code: String
    let stl: Data
    let mesh: STLMesh
    let facts: AccessoryRenderFacts
    let images: [AccessoryRenderImage]
    /// The fit-test piece Studio rendered from the same code, when the code declares `fit_test` and this render is
    /// acceptable.
    var fitTest: AccessoryFitTestOutcome?

    var problems: [String] { accessoryRenderProblems(facts) + fitTestProblems }
    /// A fit-test piece that is the same model as the part blocks finishing, like `fit_test = true` in the code.
    var fitTestProblems: [String] {
        if case .made(let piece)? = fitTest, piece.check.equalsPart { return [accessoryFitTestEqualsPartProblem] }
        return []
    }
    var isAcceptable: Bool { problems.isEmpty }
    /// The fit-test piece, when it was made and passes Studio's checks.
    var passingFitTest: AccessoryFitTestPiece? {
        if case .made(let piece)? = fitTest, piece.check.passes { return piece }
        return nil
    }
}

/// Which model a render makes: the design as written, or its fit-test piece (`-D fit_test=true`).
enum AccessoryRenderVariant: Equatable, Sendable {
    case design
    case fitTest
}

enum AccessoryRenderOutcome: Sendable {
    case rendered(AccessoryRender)
    /// No model: the text says why (for Claude and the seller).
    case failed(String)
}

/// How much work one render's analysis may do. Tests use smaller values; the app uses the defaults.
struct AccessoryAnalysisBudget: Equatable, Sendable {
    var wallThicknessSamples = wallThicknessMaximumSamples
    var pictureSize = accessoryRenderPixelSize
    var rasterBudget = accessoryRenderRasterBudget
    /// The views pictured, in order.
    var pictureAngles = accessoryRenderAngles
    var measuresWallThickness = true

    /// The fit-test piece's analysis: one three-quarter picture and no wall-thickness check.
    var forFitTest: AccessoryAnalysisBudget {
        var budget = self
        budget.pictureAngles = [.threeQuarter]
        budget.measuresWallThickness = false
        return budget
    }
}

/// Parses OpenSCAD's STL and measures it, then renders the pictures. Pure CPU work, deterministic (the same bytes
/// give the same STL, facts and pictures). Nil when cancelled; throws when the STL can't be used.
func analyseAccessoryRender(stl data: Data, code: String, openSCADMessages: [String], fitSizes: [AccessoryFitSize] = [],
                            budget: AccessoryAnalysisBudget = AccessoryAnalysisBudget(),
                            isCancelled: () -> Bool = { false }) throws -> AccessoryRender? {
    guard !data.isEmpty else { throw StudioError("OpenSCAD wrote an empty file; the top-level object may be empty.") }
    let mesh: STLMesh
    do { mesh = try STLMesh.parse(data) } catch {
        throw StudioError("OpenSCAD’s output isn’t a usable model: \(error.localizedDescription) Lower $fn if it has too many triangles.")
    }
    let binary = try mesh.stlCopyData()
    if isCancelled() { return nil }
    guard let health = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { return nil }
    let extent = mesh.maximum - mesh.minimum
    var facts = AccessoryRenderFacts(sizeMM: extent, lowestZ: mesh.minimum.z, triangles: mesh.triangleCount, health: health,
                                     contactAreaMM2: mesh.bottomContactAreaMM2(),
                                     footprintMM2: Double(extent.x) * Double(extent.y), wallThickness: nil,
                                     overhang: overhangShare(mesh), overhangLocation: accessoryOverhangLocation(mesh),
                                     fitSizes: fitSizes,
                                     customizerValues: scadTemplateParameters(code).parameters.map(\.name),
                                     openSCADMessages: openSCADMessages,
                                     fitTestDeclaration: accessoryFitTestDeclaration(code))
    if facts.isOneClosedSolid, budget.measuresWallThickness {
        guard let report = analyzeWallThickness(mesh, maximumSamples: budget.wallThicknessSamples, isCancelled: isCancelled) else { return nil }
        facts.wallThickness = wallThicknessSummary(report, origin: mesh.minimum)
    }
    var images: [AccessoryRenderImage] = []
    for angle in budget.pictureAngles {
        if isCancelled() { return nil }
        let camera = listingCamera(angle)
        let style = listingRenderStyle(colour: listingNeutralColour, camera: camera)
        guard let rgba = renderMeshRGBA(mesh, size: budget.pictureSize, camera: camera, style: style,
                                        rasterBudget: budget.rasterBudget, isCancelled: isCancelled) else {
            if isCancelled() { return nil }
            continue
        }
        if let image = prepareRenderedImage(rgba: rgba, width: budget.pictureSize, height: budget.pictureSize,
                                            format: .jpeg(quality: 0.85, background: SIMD3(1, 1, 1))) {
            images.append(AccessoryRenderImage(title: accessoryRenderViewCaption(angle), image: image))
        }
    }
    return AccessoryRender(code: code, stl: binary, mesh: mesh, facts: facts, images: images)
}

/// A render's tool result: the facts, the fit-test block when there is one, each picture after its caption, the
/// passing fit-test piece's picture, and the line asking Claude to compare the pictures with the photos.
func accessoryRenderToolResult(_ outcome: AccessoryRenderOutcome, toolUseID: String, renderNumber: Int, maxRenders: Int) -> AnthropicInputBlock {
    switch outcome {
    case .rendered(let render):
        var content: [AnthropicToolResultContent] = [.text(accessoryRenderFactsText(render.facts, renderNumber: renderNumber, maxRenders: maxRenders, extraProblems: render.fitTestProblems))]
        if let fitTest = accessoryFitTestFactsText(render) { content.append(.text(fitTest)) }
        for picture in render.images {
            content.append(.text(picture.title))
            content.append(.image(picture.image.anthropicImage))
        }
        if let piece = render.passingFitTest, let picture = piece.image {
            content.append(.text("Fit-test piece: \(picture.title)"))
            content.append(.image(picture.image.anthropicImage))
        }
        content.append(.text(accessoryPhotoComparisonText))
        return .toolResult(toolUseID: toolUseID, content: content)
    case .failed(let text):
        return .toolResult(toolUseID: toolUseID, content: [.text("Render \(renderNumber) of \(maxRenders) this round failed. \(text)")], isError: true)
    }
}

/// Cancellation flag readable from detached work.
private final class AccessoryCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Renders code with the local OpenSCAD in an empty temporary folder (removed afterwards), then measures and pictures
/// the result off the main actor. Throws only `CancellationError`; every other failure is a `.failed` outcome.
/// `.fitTest` renders the same code with `-D fit_test=true` (only when the code declares `fit_test = false;` as a
/// top-level Customizer value), with the same safety check, timeout and memory cap, and `budget.forFitTest`.
func renderAccessoryDesign(code: String, variant: AccessoryRenderVariant = .design, executable: URL,
                           timeout: TimeInterval = accessoryOpenSCADTimeout,
                           budget: AccessoryAnalysisBudget = AccessoryAnalysisBudget()) async throws -> AccessoryRenderOutcome {
    if let problem = scadSafetyProblem(code) { return .failed(problem) }
    let assignments: [ScadAssignment]
    let budget = variant == .fitTest ? budget.forFitTest : budget
    switch variant {
    case .design:
        assignments = []
    case .fitTest:
        assignments = accessoryFitTestAssignments(code)
        guard !assignments.isEmpty else {
            return .failed("The code doesn’t declare fit_test = false; as a top-level value, so Studio can’t make a fit-test piece.")
        }
    }
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("\(accessoryTempFolderPrefix)\(UUID().uuidString)")
    let scad = folder.appendingPathComponent("design.scad")
    do {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(code.utf8).write(to: scad, options: .atomic)
    } catch {
        try? FileManager.default.removeItem(at: folder)
        return .failed("Studio couldn’t write the code to a temporary file: \(error.localizedDescription)")
    }
    defer { try? FileManager.default.removeItem(at: folder) }
    let capture = OpenSCADLogCapture()
    let data: Data
    do {
        data = try await runOpenSCADProcess(executable: executable, templateURL: scad, assignments: assignments, timeout: timeout,
                                            maxMemoryBytes: openSCADMemoryLimitBytes, logCapture: capture)
    } catch OpenSCADRunError.cancelled {
        throw CancellationError()
    } catch is CancellationError {
        throw CancellationError()
    } catch let error as OpenSCADRunError {
        return .failed(accessoryOpenSCADFailureText(error, messages: accessoryOpenSCADMessages(capture.log)))
    } catch {
        return .failed("OpenSCAD couldn’t be started: \(error.localizedDescription)")
    }
    try Task.checkCancellation()
    let messages = accessoryOpenSCADMessages(capture.log)
    let fitSizes = accessoryFitSizes(capture.log)
    let flag = AccessoryCancelFlag()
    let work = Task.detached(priority: .userInitiated) { () -> Result<AccessoryRender?, Error> in
        Result {
            try analyseAccessoryRender(stl: data, code: code, openSCADMessages: messages, fitSizes: fitSizes, budget: budget,
                                       isCancelled: { flag.isCancelled })
        }
    }
    let result = await withTaskCancellationHandler { await work.value } onCancel: { flag.cancel() }
    try Task.checkCancellation()
    switch result {
    case .success(let render?): return .rendered(render)
    case .success(nil): throw CancellationError()
    case .failure(let error): return .failed(error.localizedDescription)
    }
}

// MARK: Finishing

struct AccessoryFinish: Sendable {
    let name: String
    let summary: String
    let printOrientation: String
    let notes: [String]
    /// Claude's own comparison of the design with the seller's photos (display only).
    var photoCheck = ""
    let render: AccessoryRender
}

private func accessoryClipped(_ text: String?, _ limit: Int) -> String {
    let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
}

/// Claude's finish_design input, clipped for display: name ≤ 60, summary ≤ 1,500, orientation ≤ 400, at most 6 notes of
/// ≤ 400 characters (empty ones dropped), and the photo check ≤ `accessoryPhotoCheckMaximumLength`.
func accessoryFinishFields(_ input: AnthropicJSON) -> (name: String, summary: String, orientation: String, notes: [String], photoCheck: String) {
    let notes = (input["notes"]?.arrayValue ?? []).compactMap(\.stringValue)
        .map { accessoryClipped($0, 400) }.filter { !$0.isEmpty }.prefix(6)
    return (accessoryClipped(input["name"]?.stringValue, 60), accessoryClipped(input["summary"]?.stringValue, 1_500),
            accessoryClipped(input["print_orientation"]?.stringValue, 400), Array(notes),
            accessoryClipped(input["photo_check"]?.stringValue, accessoryPhotoCheckMaximumLength))
}

let accessoryPhotoCheckMaximumLength = 600

/// The fit-test piece's library name: the design's name without " (designed)", with " (fit test)", such as
/// "Phone stand (fit test)".
func accessoryFitTestLibraryName(libraryName: String) -> String {
    var base = libraryName.trimmingCharacters(in: .whitespacesAndNewlines)
    base = base.replacingOccurrences(of: #"\s*\((designed|fit test)\)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        .trimmingCharacters(in: .whitespaces)
    if base.isEmpty { base = "Accessory" }
    let suffix = " (fit test)"
    if base.count + suffix.count > maximumModelNameLength {
        base = String(base.prefix(max(1, maximumModelNameLength - suffix.count))).trimmingCharacters(in: .whitespaces)
    }
    return base + suffix
}

/// The library name: Claude's suggestion (else the first words of the seller's description, else "Accessory"),
/// tidied, with " (designed)" added, such as "Phone stand (designed)".
func accessoryLibraryName(suggested: String, description: String) -> String {
    func tidy(_ text: String) -> String {
        var words = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).map(String.init)
        if let first = words.first, ["a", "an", "the"].contains(first.lowercased()), words.count > 1 { words.removeFirst() }
        let punctuation = CharacterSet(charactersIn: " .,;:!?-–—\"'“”‘’")
        var result = words.joined(separator: " ").trimmingCharacters(in: punctuation)
        result = result.replacingOccurrences(of: #"\s*\(designed\)$"#, with: "", options: [.regularExpression, .caseInsensitive])
        result = result.trimmingCharacters(in: punctuation)
        if result.count > 60 { result = String(result.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return result.prefix(1).uppercased() + result.dropFirst()
    }
    var base = tidy(suggested)
    if base.isEmpty {
        let words = description.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).prefix(6).joined(separator: " ")
        base = tidy(words)
    }
    if base.isEmpty { base = "Accessory" }
    let name = "\(base) (designed)"
    return name.count > maximumModelNameLength ? String(name.prefix(maximumModelNameLength)) : name
}

/// The .scad file Save Template… writes: a short header (saying how to make the fit-test piece when the code has one),
/// then Claude's code unchanged, so `fit_test` stays an adjustable value.
func accessoryTemplateFileText(code: String, name: String) -> String {
    let title = name.split(whereSeparator: \.isNewline).joined(separator: " ")
    var header = "// \(title)\n// Designed with Claude in Slant Studio. Check every measurement on a test print before selling.\n"
    if accessoryFitTestDeclaration(code) == .ready {
        let parameters = scadTemplateParameters(code).parameters
        func named(_ name: String) -> String {
            let description = parameters.first { $0.name == name }?.description?.split(whereSeparator: \.isNewline).joined(separator: " ")
            return description.map { "\(name) (“\($0)”)" } ?? name
        }
        header += "// Fit test: turn on \(named(accessoryFitTestVariable)) to make only the small fit-test piece, and print it first.\n"
        let clearances = accessoryClearanceValueNames(code)
        if !clearances.isEmpty {
            header += "// If the piece is tight or loose, change \(clearances.map(named).joined(separator: ", ")) in Personalise from Template.\n"
        }
    }
    return header + "\n" + code + (code.hasSuffix("\n") ? "" : "\n")
}

// MARK: - The design loop

struct AccessoryTranscriptEntry: Identifiable, Sendable {
    enum Kind: Sendable {
        /// Text Claude wrote outside its tools.
        case claude(String)
        case render(renderID: UUID, number: Int, line: String, acceptable: Bool)
        case renderFailed(number: Int, text: String)
        /// The fit-test piece Studio made after an acceptable render.
        case fitTest(line: String, passed: Bool)
        /// Studio didn't run the code (ScadSafety).
        case refusedCode(String)
        case question(String)
        case answer(String)
        case seller(String)
        case notice(String)
    }
    let id = UUID()
    let kind: Kind
}

enum AccessoryDesignPhase: Equatable, Sendable {
    /// Nothing sent yet.
    case ready
    case working(String)
    /// Claude asked a question (`AccessoryDesignRun.pendingQuestion`).
    case waitingForSeller
    case finished
    /// Stopped by the seller, a failure or a limit; the text says why.
    case stopped(String)
}

/// One line for a render in the conversation, such as "Render 2: 82.0 × 60.5 × 95.2 mm, closed, 1 part".
func accessoryRenderLine(_ render: AccessoryRender, number: Int) -> String {
    let size = render.facts.sizeMM
    let health = meshHealthSummary(render.facts.health).title.lowercased()
    return "Render \(number): \(accessoryOneDecimal(size.x)) × \(accessoryOneDecimal(size.y)) × \(accessoryOneDecimal(size.z)) mm, \(health)"
}

/// One line for the fit-test piece in the conversation, such as "Fit-test piece: 30.0 × 12.0 × 8.0 mm, 9% of the
/// part's volume, passes Studio's checks".
func accessoryFitTestTranscriptLine(_ outcome: AccessoryFitTestOutcome) -> String {
    switch outcome {
    case .failed:
        return "Fit-test piece: OpenSCAD couldn’t make it; Claude is told why"
    case .stopped:
        return "Fit-test piece: stopped before it was made"
    case .made(let piece):
        let size = piece.facts.sizeMM
        var line = "Fit-test piece: \(accessoryOneDecimal(size.x)) × \(accessoryOneDecimal(size.y)) × \(accessoryOneDecimal(size.z)) mm"
        if let share = piece.check.volumeShare { line += ", \(accessoryShareLabel(share)) of the part’s volume" }
        return line + (piece.check.passes ? ", passes Studio’s checks" : ", doesn’t pass Studio’s checks; Claude is told why")
    }
}

/// Anthropic's limit on pictures in one request.
let accessoryMaximumImagesPerRequest = 100

let accessoryImageLimitText = "This conversation has too many pictures for Claude, so Studio didn’t send it. Start Over, or save what you have."

/// When the seller's answer or note would take the conversation over the picture limit: nothing changes, and a
/// finished design keeps its Save buttons.
let accessoryNoteImageLimitText = "Studio didn’t send this to Claude: the conversation has too many pictures for Claude. Save what you have, or close this window and start a new design."

/// Pictures in the messages: image blocks, and images inside tool results.
func accessoryImageCount(_ messages: [AnthropicMessageParam]) -> Int {
    messages.reduce(0) { total, message in
        total + message.content.reduce(0) { count, block in
            switch block {
            case .image: return count + 1
            case .toolResult(_, let content, _, _):
                return count + content.filter { if case .image = $0 { return true }; return false }.count
            case .text, .raw: return count
            }
        }
    }
}

/// The bounded conversation with Claude. Each round (Start Design, or each note the seller sends) allows
/// `limits.maxReplies` replies and `limits.maxRenders` renders. Nothing is sent again by itself: a failure, a refusal,
/// a cut-off reply or a limit stops the round, and only the seller's click starts the next. The history is append-only;
/// a turn Anthropic never answered is the only one that may still change (Send Again resends it as it is).
@MainActor final class AccessoryDesignRun: ObservableObject {
    typealias Send = @MainActor (AnthropicRequest, @escaping @MainActor @Sendable (AnthropicStreamProgress) -> Void) async throws -> AnthropicMessage
    /// Renders the code as written (`.design`) or its fit-test piece (`.fitTest`), locally.
    typealias Render = @Sendable (String, AccessoryRenderVariant) async throws -> AccessoryRenderOutcome

    let limits: AccessoryDesignLimits
    private let send: Send
    private let render: Render

    @Published private(set) var phase: AccessoryDesignPhase = .ready
    @Published private(set) var transcript: [AccessoryTranscriptEntry] = []
    @Published private(set) var latestRender: AccessoryRender?
    @Published private(set) var finish: AccessoryFinish?
    @Published private(set) var pendingQuestion: String?
    @Published private(set) var repliesThisRound = 0
    @Published private(set) var rendersThisRound = 0
    @Published private(set) var totalReplies = 0
    @Published private(set) var totalRenders = 0
    @Published private(set) var cost = AnthropicCostEstimate(usd: 0, complete: true)
    /// A reply failed or was stopped part-way, so Anthropic may bill more than `cost` shows.
    @Published private(set) var costMayBeHigher = false
    /// Claude declined: the design can't continue in this conversation.
    @Published private(set) var refused = false
    /// The next request would carry more pictures than Anthropic accepts (`accessoryMaximumImagesPerRequest`). The
    /// history is append-only, so the design can't continue in this conversation.
    @Published private(set) var imageLimitReached = false

    private(set) var messages: [AnthropicMessageParam] = []
    private var pendingResults: [AnthropicInputBlock] = []
    private var openToolUseIDs: [String] = []
    private var questionToolUseID: String?
    private var nudged = false
    /// The render from the most recent render_scad call when it was acceptable; nil after a failed or refused call.
    private var lastAcceptableRender: AccessoryRender?
    private var task: Task<Void, Never>?

    init(limits: AccessoryDesignLimits = AccessoryDesignLimits(), send: @escaping Send, render: @escaping Render) {
        self.limits = limits
        self.send = send
        self.render = render
    }

    var isWorking: Bool { if case .working = phase { return true }; return false }
    var hasStarted: Bool { phase != .ready }
    /// The last turn was never answered (a failed or stopped send): Send Again resends it.
    var canTryAgain: Bool { hasStarted && !isWorking && !refused && !imageLimitReached && questionToolUseID == nil && messages.last?.role == .user }
    /// The seller may write to Claude to start another round.
    var canSendNote: Bool { hasStarted && !isWorking && !refused && !imageLimitReached && questionToolUseID == nil && !messages.isEmpty }

    func start(firstTurn: AnthropicMessageParam) {
        guard phase == .ready, task == nil else { return }
        messages = [firstTurn]
        beginRound()
        launch()
    }

    /// Answers Claude's question (empty or nil skips it) and carries on in the same round.
    func answer(_ text: String?) {
        guard let id = questionToolUseID, !isWorking else { return }
        // Checked before anything changes: the answer itself adds no pictures, but results waiting to go may.
        if wouldExceedImageLimit { refuseForImageLimit(); return }
        let trimmed = accessoryClipped(text, 1_000)
        transcript.append(AccessoryTranscriptEntry(kind: .answer(trimmed.isEmpty ? "Skipped" : trimmed)))
        let reply = trimmed.isEmpty
            ? "The seller skipped this question. Use your best judgement and say what you assumed."
            : "The seller answered: \(trimmed)"
        addResult(.toolResult(toolUseID: id, content: [.text(reply)]), for: id)
        questionToolUseID = nil
        pendingQuestion = nil
        messages.append(.user(takeOutgoingBlocks()))
        launch()
    }

    /// Sends the seller's note and starts a new round. A note is required when Claude's turn is last.
    func sendNote(_ note: String) {
        guard canSendNote else { return }
        // Checked before the history or the finished design changes, so a finished design keeps its Save buttons.
        if wouldExceedImageLimit { refuseForImageLimit(); return }
        let trimmed = accessoryClipped(note, 2_000)
        if messages.last?.role == .assistant {
            guard !trimmed.isEmpty else { return }
            messages.append(.user(takeOutgoingBlocks() + [.text("The seller says: \(trimmed)")]))
        } else if !trimmed.isEmpty, var last = messages.popLast() {
            // Anthropic never answered this turn, so adding to it doesn't change the history it has seen.
            last.content.append(.text("The seller says: \(trimmed)"))
            messages.append(last)
        }
        if !trimmed.isEmpty { transcript.append(AccessoryTranscriptEntry(kind: .seller(trimmed))) }
        finish = nil
        beginRound()
        launch()
    }

    /// The next request would carry more pictures than Anthropic accepts: the history so far plus the results waiting
    /// to go with the next turn (a note or an answer adds none).
    private var wouldExceedImageLimit: Bool {
        accessoryImageCount(messages) + accessoryImageCount([.user(pendingResults)]) > accessoryMaximumImagesPerRequest
    }

    /// Refuses the seller's answer or note without changing the history, the phase of a finished design or `finish`.
    private func refuseForImageLimit() {
        imageLimitReached = true
        transcript.append(AccessoryTranscriptEntry(kind: .notice(accessoryNoteImageLimitText)))
        if phase != .finished { phase = .stopped(accessoryNoteImageLimitText) }
    }

    /// Resends the unanswered turn as it is, in a new round.
    func tryAgain() {
        guard canTryAgain else { return }
        beginRound()
        launch()
    }

    /// Stops the current reply or render. Nothing more is sent.
    func stop() {
        task?.cancel()
    }

    private func beginRound() {
        repliesThisRound = 0
        rendersThisRound = 0
        nudged = false
    }

    private func launch() {
        phase = .working("Sending to Claude…")
        task = Task { [weak self] in await self?.loop() }
    }

    private func halt(_ reason: String) {
        phase = .stopped(reason)
        transcript.append(AccessoryTranscriptEntry(kind: .notice(reason)))
    }

    private func addResult(_ block: AnthropicInputBlock, for id: String) {
        pendingResults.append(block)
        openToolUseIDs.removeAll { $0 == id }
    }

    /// Results for every tool call in Claude's last turn: those Studio made, then an error for each it didn't run.
    private func takeOutgoingBlocks() -> [AnthropicInputBlock] {
        var blocks = pendingResults
        for id in openToolUseIDs {
            blocks.append(.toolResult(toolUseID: id, content: [.text("Not run: Studio runs one tool per reply, or the seller stopped the design here.")], isError: true))
        }
        pendingResults = []
        openToolUseIDs = []
        return blocks
    }

    private func noteProgress(_ progress: AnthropicStreamProgress) {
        guard isWorking else { return }
        let status: String?
        switch progress {
        case .started: status = "Claude is thinking…"
        case .toolInput(let name, let characters):
            switch name {
            case AccessoryToolName.render: status = "Claude is writing OpenSCAD code (\((characters / 100 * 100).formatted()) characters)…"
            case AccessoryToolName.ask: status = "Claude is writing a question…"
            case AccessoryToolName.finish: status = "Claude is writing up the design…"
            default: status = nil
            }
        case .textDelta: status = "Claude is writing…"
        default: status = nil
        }
        if let status, phase != .working(status) { phase = .working(status) }
    }

    private enum ToolStep { case next, waitForSeller, finished, cancelled }

    private func loop() async {
        defer { task = nil }
        while true {
            if Task.isCancelled { halt("Stopped. Nothing more was sent."); return }
            guard repliesThisRound < limits.maxReplies else {
                halt("Claude used all \(limits.maxReplies) replies in this round without finishing. Write a note to continue, or close the window.")
                return
            }
            // Checked before sending: Anthropic refuses a request with too many pictures, and earlier turns can't change.
            if accessoryImageCount(messages) > accessoryMaximumImagesPerRequest {
                imageLimitReached = true
                halt(accessoryImageLimitText)
                return
            }
            phase = .working("Waiting for Claude…")
            let reply: AnthropicMessage
            do {
                reply = try await send(accessoryDesignRequest(messages: messages)) { [weak self] progress in self?.noteProgress(progress) }
            } catch is CancellationError {
                costMayBeHigher = true
                halt("Stopped before Claude finished its reply. Anthropic may bill the part it wrote.")
                return
            } catch {
                if let failure = error as? AnthropicError, accessoryErrorMayHaveBeenBilled(failure) { costMayBeHigher = true }
                halt(error.localizedDescription)
                return
            }
            repliesThisRound += 1
            totalReplies += 1
            cost = accessoryAddCost(cost, anthropicEstimatedCost(reply.usage, model: reply.model, requestedModel: reply.requestedModel))
            if reply.isRefusal {
                refused = true
                halt(anthropicRefusalMessage(reply.stopDetails))
                return
            }
            // Only a reply that ended normally may join the history: one cut off for any reason can end in a
            // half-written tool call or an unsigned thinking block, which the next request would be refused for.
            guard reply.canJoinHistory else {
                halt(accessorySetAsideText(reply.stopReason))
                return
            }
            guard !reply.historyContent.isEmpty else {
                halt("Claude sent an empty reply. Send Again sends the same request.")
                return
            }
            if Task.isCancelled { halt("Stopped. Nothing more was sent."); return }
            messages.append(.assistant(reply))
            openToolUseIDs = reply.toolUses.map(\.id)
            let text = accessoryClipped(reply.text, 4_000)
            if !text.isEmpty { transcript.append(AccessoryTranscriptEntry(kind: .claude(text))) }
            let uses = reply.toolUsesToRun
            if uses.isEmpty {
                if nudged {
                    halt("Claude stopped without finishing the design. Write a note to continue, or close the window.")
                    return
                }
                nudged = true
                messages.append(.user(takeOutgoingBlocks() + [.text(accessoryNudgeText)]))
                continue
            }
            var outcome = ToolStep.next
            for use in uses {
                outcome = await handle(use)
                if outcome != .next { break }
            }
            switch outcome {
            case .next:
                messages.append(.user(takeOutgoingBlocks()))
            case .waitForSeller:
                phase = .waitingForSeller
                return
            case .finished:
                phase = .finished
                return
            case .cancelled:
                halt("Stopped. Nothing more was sent.")
                return
            }
        }
    }

    private func handle(_ use: AnthropicToolUse) async -> ToolStep {
        if Task.isCancelled { return .cancelled }
        if use.inputProblem != nil {
            addResult(use.errorResult, for: use.id)
            return .next
        }
        switch use.name {
        case AccessoryToolName.render:
            let code = use.input["code"]?.stringValue ?? ""
            guard rendersThisRound < limits.maxRenders else {
                addResult(.toolResult(toolUseID: use.id, content: [.text("No renders left in this round (\(limits.maxRenders) used). If the latest render is right, call finish_design; otherwise ask_seller or explain what you would change.")], isError: true), for: use.id)
                return .next
            }
            if let problem = scadSafetyProblem(code) {
                lastAcceptableRender = nil
                transcript.append(AccessoryTranscriptEntry(kind: .refusedCode(problem)))
                addResult(.toolResult(toolUseID: use.id, content: [.text("Studio didn’t run this code. \(problem)")], isError: true), for: use.id)
                return .next
            }
            rendersThisRound += 1
            totalRenders += 1
            let number = rendersThisRound
            phase = .working("Rendering design \(number) of \(limits.maxRenders) with OpenSCAD…")
            var outcome: AccessoryRenderOutcome
            do { outcome = try await render(code, .design) } catch { return .cancelled }
            if Task.isCancelled { return .cancelled }
            // The fit-test piece: the same code again with fit_test = true, locally. It isn't a request to Claude and
            // doesn't count against the render limit. Stop during it keeps the design render, which really ran, records
            // the piece as stopped and answers the call with that render, then stops: nothing more is sent.
            var fitTestEntry: AccessoryTranscriptEntry?
            var stoppedDuringPiece = false
            if case .rendered(var result) = outcome, result.isAcceptable, result.facts.fitTestDeclaration == .ready {
                phase = .working("Rendering the fit-test piece with OpenSCAD…")
                let fitTest: AccessoryFitTestOutcome
                do {
                    let piece = try await render(code, .fitTest)
                    fitTest = Task.isCancelled ? .stopped : accessoryFitTestOutcome(piece, part: result.facts)
                } catch {
                    // The renderer throws only when cancelled.
                    fitTest = .stopped
                }
                if case .stopped = fitTest { stoppedDuringPiece = true }
                result.fitTest = fitTest
                outcome = .rendered(result)
                fitTestEntry = AccessoryTranscriptEntry(kind: .fitTest(line: accessoryFitTestTranscriptLine(fitTest),
                                                                       passed: result.passingFitTest != nil))
            }
            switch outcome {
            case .rendered(let result):
                latestRender = result
                lastAcceptableRender = result.isAcceptable ? result : nil
                transcript.append(AccessoryTranscriptEntry(kind: .render(renderID: result.id, number: totalRenders,
                                                                         line: accessoryRenderLine(result, number: totalRenders),
                                                                         acceptable: result.isAcceptable)))
                if let fitTestEntry { transcript.append(fitTestEntry) }
            case .failed(let text):
                lastAcceptableRender = nil
                transcript.append(AccessoryTranscriptEntry(kind: .renderFailed(number: totalRenders, text: text)))
            }
            addResult(accessoryRenderToolResult(outcome, toolUseID: use.id, renderNumber: number, maxRenders: limits.maxRenders), for: use.id)
            return stoppedDuringPiece ? .cancelled : .next
        case AccessoryToolName.ask:
            let question = accessoryClipped(use.input["question"]?.stringValue, 500)
            guard !question.isEmpty else {
                addResult(.toolResult(toolUseID: use.id, content: [.text("The question was empty.")], isError: true), for: use.id)
                return .next
            }
            questionToolUseID = use.id
            pendingQuestion = question
            transcript.append(AccessoryTranscriptEntry(kind: .question(question)))
            return .waitForSeller
        case AccessoryToolName.finish:
            guard let accepted = lastAcceptableRender else {
                addResult(.toolResult(toolUseID: use.id, content: [.text("Studio can’t finish yet: the latest render_scad call didn’t give one closed solid within the build volume. Fix the code and render again.")], isError: true), for: use.id)
                return .next
            }
            let fields = accessoryFinishFields(use.input)
            // A fit-test piece isn't required: some designs have nothing to fit, and the result screen says when the
            // seller should print the whole part to check the fit.
            finish = AccessoryFinish(name: fields.name, summary: fields.summary, printOrientation: fields.orientation,
                                     notes: fields.notes, photoCheck: fields.photoCheck, render: accepted)
            addResult(.toolResult(toolUseID: use.id, content: [.text("Studio showed the seller this design. If they ask for changes, their note follows.")]), for: use.id)
            return .finished
        default:
            addResult(use.errorResult, for: use.id)
            return .next
        }
    }
}

/// Why a reply that can't join the history (`AnthropicMessage.canJoinHistory`) was set aside, for the seller.
func accessorySetAsideText(_ stopReason: AnthropicStopReason?) -> String {
    switch stopReason {
    case .maxTokens?:
        return "Claude’s reply was cut off before it finished, so Studio set it aside. Send Again sends the same request."
    case .other("model_context_window_exceeded")?:
        return "Claude’s reply was cut off because the conversation reached the model’s length limit, so Studio set it aside. Start Over with fewer or smaller photos or a shorter brief; Send Again would most likely stop the same way."
    case .other(let raw)?:
        return "Claude’s reply ended before it finished (\(accessoryClipped(raw, 60))), so Studio set it aside. Send Again sends the same request."
    default:
        return "Claude’s reply ended before it finished, so Studio set it aside. Send Again sends the same request."
    }
}

/// True when Anthropic may have started (and billed) a reply before the failure: anything after the request was sent
/// and accepted, as opposed to a refusal of the request itself.
func accessoryErrorMayHaveBeenBilled(_ error: AnthropicError) -> Bool {
    switch error {
    case .stream, .transport, .timedOut, .invalidResponse, .responseTooLarge, .incomplete: return true
    case .missingKey, .notSent, .http: return false
    }
}

/// "3 Claude replies · 2 renders · about $0.42", for the sheet and Activity (counts and cost only).
func accessoryRunSummary(replies: Int, renders: Int, cost: AnthropicCostEstimate, costMayBeHigher: Bool) -> String {
    let replyText = replies == 1 ? "1 Claude reply" : "\(replies) Claude replies"
    let renderText = renders == 1 ? "1 render" : "\(renders) renders"
    let costText = replies == 0 && !costMayBeHigher ? "nothing spent" : anthropicCostText(cost) + (costMayBeHigher ? " or a little more" : "")
    return "\(replyText) · \(renderText) · \(costText)"
}
