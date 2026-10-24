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

struct AccessoryMeasurement: Identifiable, Equatable, Sendable {
    let id = UUID()
    var label = ""
    var millimetres = ""
    var method: AccessoryMeasurementMethod = .calipers

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

/// The text of the first turn, after the photos.
func accessoryFirstTurnText(_ brief: AccessoryDesignBrief, photoCount: Int) -> String {
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
    lines.append("")
    lines.append("Design the accessory, then call render_scad with the complete OpenSCAD file.")
    return lines.joined(separator: "\n")
}

/// The first user turn: the photos first, then the brief.
func accessoryFirstTurn(_ brief: AccessoryDesignBrief, photos: [PreparedImage]) -> AnthropicMessageParam {
    .user(photos.map { .image($0.anthropicImage) } + [.text(accessoryFirstTurnText(brief, photoCount: photos.count))])
}

// MARK: Prompt and tools

let accessorySystemPrompt = """
You design small functional accessories for 3D printing, as parametric OpenSCAD code, from a seller's photos and \
measurements. The seller sells printed products; Slant 3D prints them on FDM printers whose slicer settings aren't \
published, so design for FDM with unknown slicer settings.

How you work
- The photos show the object the accessory is for (or a sketch or an example). Photos have no reliable scale: take \
sizes only from the typed measurements. If a size you need isn't measured, ask with ask_seller rather than guess, \
unless a sensible default is clearly fine; then say what you assumed.
- Call render_scad with the complete OpenSCAD file. Studio renders it with OpenSCAD on the seller's Mac and replies \
with facts it measured itself (size, mesh check, wall thickness, flat contact with the bed, build-volume fit, OpenSCAD \
messages) and pictures from the three-quarter, front, side and top views. Look at them critically and fix what is \
wrong.
- You have at most 4 renders and 10 replies, so plan the design before the first render and make each render count.
- When the latest render is right, call finish_design. Studio accepts finish_design only right after a render that is \
one closed solid within the 220 mm build volume.
- Use exactly one tool in each reply. Keep any text outside tools short and plain: the seller reads it.

OpenSCAD conventions
- Millimetres. Z is up. The part sits flat on the bed in the orientation it should print, with its lowest face on Z = 0.
- One closed solid: union everything; no loose parts.
- Every dimension and option is a named top-level variable set to a plain literal, declared before the first module, \
with a Customizer comment on the same line, for example `phone_thickness = 9.5; // [5:0.1:20] Phone thickness (mm)`. \
Group them with /* [Section] */ comments and put derived values in a /* [Hidden] */ section after the editable ones, \
so the seller can adjust the design later in Studio's Personalise from Template.
- $fn between 32 and 96 for curves. Keep each render well under a minute: avoid minkowski() on complex shapes, long \
hull() chains and deep recursion.
- No include, use, import() or surface(); everything in one file. Studio refuses those, and any text that looks like a \
file path.

Designing for FDM printing (assume about 2 perimeters of 0.45 mm, low infill, 0.2 mm layers, no supports)
- Load-bearing walls at least 2.0 mm and never under 1.0 mm anywhere; prefer multiples of 0.45 mm (1.8, 2.25, 2.7).
- Overhangs at most 45° from vertical; chamfer rather than leave flat ceilings; teardrop-shaped horizontal holes; \
bridges under 5 mm.
- A flat base with a generous footprint, and a 0.5 mm chamfer on the bottom edge against elephant's foot.
- Fillet or chamfer inside corners where load concentrates, such as the roots of arms, hooks and clips.
- Orient the part so its main loads run along the layers (in XY) rather than pulling layers apart.
- Pins and posts at least 3–5 mm across; embossed or engraved detail about 1 mm.
- Fits: add 0.2–0.3 mm clearance per side for a printed fit, plus each measurement's uncertainty (calipers ±0.2 mm, \
ruler ±1 mm, estimate ±3 mm). Make estimated dimensions easy to change.
- PLA softens around 55–60 °C: for a car or anything near heat, recommend PETG in the notes.

Honesty
- Never call a design strong, approved, guaranteed or safe, and never give a strength percentage. Say "likely weak \
point" or "below the 2 mm guideline"; say "checks found no problems" only when Studio's checks really found none.
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
        description: "Render a complete OpenSCAD file with OpenSCAD on the seller's Mac. Studio replies with the facts it measured (size in mm, triangles, mesh check, wall thickness, flat contact with the bed, build-volume fit, Customizer values found, OpenSCAD messages) and four pictures. Code using include, use, import() or surface(), or text that looks like a file path, is refused without rendering.",
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
                "notes": ["type": "array", "items": ["type": "string"], "description": "Short notes for the seller: likely weak points, what to check on the first print, material advice. At most 6."]
            ],
            "required": ["name", "summary", "print_orientation", "notes"],
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

/// A rough forecast before anything is sent: the first turn is written to the cache, each later reply reads the
/// conversation so far from the cache and adds one render's facts and pictures, and every reply writes about 8,000
/// tokens. Anthropic's invoice is what counts; the sheet shows the real running cost from each reply's usage.
func accessoryCostForecast(photoSizes: [(width: Int, height: Int)], textCharacters: Int,
                           limits: AccessoryDesignLimits = AccessoryDesignLimits(), typicalReplies: Int = 5) -> AccessoryCostForecast {
    let fixed = (accessorySystemPrompt.count + AnthropicJSON.array(accessoryTools.map(\.json)).encodedString.count) * 2 / 7
    let photos = photoSizes.reduce(0) { $0 + accessoryImageTokens(pixelWidth: $1.width, pixelHeight: $1.height) }
    let first = fixed + photos + textCharacters * 2 / 7 + 50
    let renderTokens = 4 * accessoryImageTokens(pixelWidth: accessoryRenderPixelSize, pixelHeight: accessoryRenderPixelSize) + 700
    func cost(replies: Int) -> AnthropicCostEstimate {
        var usage = AnthropicUsage()
        var context = 0
        for reply in 0..<max(1, replies) {
            let added = reply == 0 ? first : accessoryForecastHistoryTokensPerReply + renderTokens
            usage.cacheReadInputTokens += context
            usage.cacheCreationInputTokens += added
            usage.outputTokens += accessoryForecastOutputTokensPerReply
            context += added
        }
        usage.cacheCreation5mInputTokens = usage.cacheCreationInputTokens
        return anthropicEstimatedCost(usage, model: anthropicDefaultModel)
    }
    let typical = min(max(1, typicalReplies), limits.maxReplies)
    return AccessoryCostForecast(firstReply: cost(replies: 1), typical: cost(replies: typical), maximum: cost(replies: limits.maxReplies),
                                 typicalReplies: typical, maximumReplies: limits.maxReplies)
}

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
    var customizerValues: [String]
    var openSCADMessages: [String]

    var isOneClosedSolid: Bool {
        health.isClosed && health.isConsistentlyOriented && !health.isInsideOut && health.shells == 1
    }
    var fitsBuildVolume: Bool { sizeMM.max() <= slantBuildVolumeMM }
    var sitsOnBed: Bool { abs(lowestZ) <= 0.01 }
}

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
    return problems
}

private func accessoryOneDecimal(_ value: Float) -> String { String(format: "%.1f", value) }

/// The text part of a render's tool result: Studio's own measurements, plain and in a fixed order.
func accessoryRenderFactsText(_ facts: AccessoryRenderFacts, renderNumber: Int, maxRenders: Int) -> String {
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
    let problems = accessoryRenderProblems(facts)
    if problems.isEmpty {
        lines.append("Studio can accept this render as the finished design.")
    } else {
        lines.append("Studio can’t accept this render as the finished design yet: \(problems.joined(separator: " "))")
    }
    return lines.joined(separator: "\n")
}

/// The messages worth passing on from OpenSCAD's log (errors, warnings, echoes, traces), at most 12 lines of 300
/// characters, with the temporary folder's path removed so only "design.scad" is named.
func accessoryOpenSCADMessages(_ log: String) -> [String] {
    let prefixes = ["ERROR", "WARNING", "ECHO", "TRACE", "DEPRECATED"]
    var result: [String] = []
    for raw in log.split(whereSeparator: \.isNewline) {
        let line = raw.trimmingCharacters(in: .whitespaces)
        guard prefixes.contains(where: { line.uppercased().hasPrefix($0) }) else { continue }
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

    var problems: [String] { accessoryRenderProblems(facts) }
    var isAcceptable: Bool { problems.isEmpty }
}

enum AccessoryRenderOutcome: Sendable {
    case rendered(AccessoryRender)
    /// No model: the text says why (for Claude and the seller).
    case failed(String)
}

/// Parses OpenSCAD's STL and measures it, then renders the pictures. Pure CPU work, deterministic (the same bytes
/// give the same STL, facts and pictures). Nil when cancelled; throws when the STL can't be used.
func analyseAccessoryRender(stl data: Data, code: String, openSCADMessages: [String],
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
                                     customizerValues: scadTemplateParameters(code).parameters.map(\.name),
                                     openSCADMessages: openSCADMessages)
    if facts.isOneClosedSolid {
        guard let report = analyzeWallThickness(mesh, isCancelled: isCancelled) else { return nil }
        facts.wallThickness = wallThicknessSummary(report, origin: mesh.minimum)
    }
    var images: [AccessoryRenderImage] = []
    for angle in accessoryRenderAngles {
        if isCancelled() { return nil }
        let camera = listingCamera(angle)
        let style = listingRenderStyle(colour: listingNeutralColour, camera: camera)
        guard let rgba = renderMeshRGBA(mesh, size: accessoryRenderPixelSize, camera: camera, style: style,
                                        rasterBudget: accessoryRenderRasterBudget, isCancelled: isCancelled) else {
            if isCancelled() { return nil }
            continue
        }
        if let image = prepareRenderedImage(rgba: rgba, width: accessoryRenderPixelSize, height: accessoryRenderPixelSize,
                                            format: .jpeg(quality: 0.85, background: SIMD3(1, 1, 1))) {
            images.append(AccessoryRenderImage(title: accessoryRenderViewCaption(angle), image: image))
        }
    }
    return AccessoryRender(code: code, stl: binary, mesh: mesh, facts: facts, images: images)
}

/// A render's tool result: the facts, then each picture after its caption.
func accessoryRenderToolResult(_ outcome: AccessoryRenderOutcome, toolUseID: String, renderNumber: Int, maxRenders: Int) -> AnthropicInputBlock {
    switch outcome {
    case .rendered(let render):
        var content: [AnthropicToolResultContent] = [.text(accessoryRenderFactsText(render.facts, renderNumber: renderNumber, maxRenders: maxRenders))]
        for picture in render.images {
            content.append(.text(picture.title))
            content.append(.image(picture.image.anthropicImage))
        }
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
func renderAccessoryDesign(code: String, executable: URL, timeout: TimeInterval = accessoryOpenSCADTimeout) async throws -> AccessoryRenderOutcome {
    if let problem = scadSafetyProblem(code) { return .failed(problem) }
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
        data = try await runOpenSCADProcess(executable: executable, templateURL: scad, assignments: [], timeout: timeout,
                                            logCapture: capture)
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
    let flag = AccessoryCancelFlag()
    let work = Task.detached(priority: .userInitiated) { () -> Result<AccessoryRender?, Error> in
        Result { try analyseAccessoryRender(stl: data, code: code, openSCADMessages: messages, isCancelled: { flag.isCancelled }) }
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
    let render: AccessoryRender
}

private func accessoryClipped(_ text: String?, _ limit: Int) -> String {
    let trimmed = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
}

/// Claude's finish_design input, clipped for display: name ≤ 60, summary ≤ 1,500, orientation ≤ 400, at most 6 notes of
/// ≤ 400 characters (empty ones dropped).
func accessoryFinishFields(_ input: AnthropicJSON) -> (name: String, summary: String, orientation: String, notes: [String]) {
    let notes = (input["notes"]?.arrayValue ?? []).compactMap(\.stringValue)
        .map { accessoryClipped($0, 400) }.filter { !$0.isEmpty }.prefix(6)
    return (accessoryClipped(input["name"]?.stringValue, 60), accessoryClipped(input["summary"]?.stringValue, 1_500),
            accessoryClipped(input["print_orientation"]?.stringValue, 400), Array(notes))
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

/// The .scad file Save Template… writes: a short header, then Claude's code unchanged.
func accessoryTemplateFileText(code: String, name: String) -> String {
    let title = name.split(whereSeparator: \.isNewline).joined(separator: " ")
    return "// \(title)\n// Designed with Claude in Slant Studio. Check every measurement on a test print before selling.\n\n" + code
        + (code.hasSuffix("\n") ? "" : "\n")
}

// MARK: - The design loop

struct AccessoryTranscriptEntry: Identifiable, Sendable {
    enum Kind: Sendable {
        /// Text Claude wrote outside its tools.
        case claude(String)
        case render(renderID: UUID, number: Int, line: String, acceptable: Bool)
        case renderFailed(number: Int, text: String)
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

/// The bounded conversation with Claude. Each round (Start Design, or each note the seller sends) allows
/// `limits.maxReplies` replies and `limits.maxRenders` renders. Nothing is sent again by itself: a failure, a refusal,
/// a cut-off reply or a limit stops the round, and only the seller's click starts the next. The history is append-only;
/// a turn Anthropic never answered is the only one that may still change (Try Again resends it as it is).
@MainActor final class AccessoryDesignRun: ObservableObject {
    typealias Send = @MainActor (AnthropicRequest, @escaping @MainActor @Sendable (AnthropicStreamProgress) -> Void) async throws -> AnthropicMessage
    typealias Render = @Sendable (String) async throws -> AccessoryRenderOutcome

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
    /// The last turn was never answered (a failed or stopped send): Try Again resends it.
    var canTryAgain: Bool { hasStarted && !isWorking && !refused && questionToolUseID == nil && messages.last?.role == .user }
    /// The seller may write to Claude to start another round.
    var canSendNote: Bool { hasStarted && !isWorking && !refused && questionToolUseID == nil && !messages.isEmpty }

    func start(firstTurn: AnthropicMessageParam) {
        guard phase == .ready, task == nil else { return }
        messages = [firstTurn]
        beginRound()
        launch()
    }

    /// Answers Claude's question (empty or nil skips it) and carries on in the same round.
    func answer(_ text: String?) {
        guard let id = questionToolUseID, !isWorking else { return }
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
            if reply.stopReason == .maxTokens {
                halt("Claude’s reply was cut off before it finished, so Studio set it aside. Try Again sends the same request.")
                return
            }
            guard !reply.historyContent.isEmpty else {
                halt("Claude sent an empty reply. Try Again sends the same request.")
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
            let outcome: AccessoryRenderOutcome
            do { outcome = try await render(code) } catch { return .cancelled }
            if Task.isCancelled { return .cancelled }
            switch outcome {
            case .rendered(let result):
                latestRender = result
                lastAcceptableRender = result.isAcceptable ? result : nil
                transcript.append(AccessoryTranscriptEntry(kind: .render(renderID: result.id, number: totalRenders,
                                                                         line: accessoryRenderLine(result, number: totalRenders),
                                                                         acceptable: result.isAcceptable)))
            case .failed(let text):
                lastAcceptableRender = nil
                transcript.append(AccessoryTranscriptEntry(kind: .renderFailed(number: totalRenders, text: text)))
            }
            addResult(accessoryRenderToolResult(outcome, toolUseID: use.id, renderNumber: number, maxRenders: limits.maxRenders), for: use.id)
            return .next
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
            finish = AccessoryFinish(name: fields.name, summary: fields.summary, printOrientation: fields.orientation,
                                     notes: fields.notes, render: accepted)
            addResult(.toolResult(toolUseID: use.id, content: [.text("Studio showed the seller this design. If they ask for changes, their note follows.")]), for: use.id)
            return .finished
        default:
            addResult(use.errorResult, for: use.id)
            return .next
        }
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
