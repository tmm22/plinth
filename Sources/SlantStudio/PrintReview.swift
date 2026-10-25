import Foundation
import simd

// MARK: - Review for Printing with Claude (pure parts)
//
// Studio measures a library model itself first (size, mesh check, wall thickness, flat base, overhangs, build volume)
// and renders four views. Only after the seller presses Ask Claude are those pictures and numbers sent, with the
// context another tool passed in (`PrintReviewContext`), with the purpose and real size the seller gave in the sheet.
// Claude answers through one strict tool, `propose_plan`, made only of Studio's own tools (repair, simplify, the Print
// orientation tool's fixed turns, scale, flat base, plinth and Auto-improve) plus "manual" advice. Studio validates
// every step, ticks none, and runs only the ticked ones, in plan order, on an in-memory copy; one library copy is saved,
// or nothing when a step fails or the result is worse than the model. The model's name is never sent. Everything here
// is pure and deterministic.

// MARK: Overhangs

/// cos 45°: a face overhangs when its normal points down more steeply than this.
let printReviewOverhangCosine = 0.70710678

/// Downward-facing surface steeper than 45° from vertical, area-weighted, with the model as placed in its file.
/// Faces lying flat on the bed (the same rule as `bottomContactAreaMM2`) are not overhangs.
struct OverhangShare: Equatable, Sendable {
    let overhangAreaMM2: Double
    let surfaceAreaMM2: Double
    var fraction: Double { surfaceAreaMM2 > 0 ? min(1, overhangAreaMM2 / surfaceAreaMM2) : 0 }
}

func overhangShare(_ mesh: STLMesh) -> OverhangShare {
    let v = mesh.vertices
    let floor = Double(mesh.minimum.z) + 0.0001
    var surface = 0.0, overhang = 0.0
    var i = 0
    while i + 8 < v.count {
        let a = SIMD3<Double>(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))
        let b = SIMD3<Double>(Double(v[i + 3]), Double(v[i + 4]), Double(v[i + 5]))
        let c = SIMD3<Double>(Double(v[i + 6]), Double(v[i + 7]), Double(v[i + 8]))
        i += 9
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        guard length > 0, length.isFinite else { continue }
        let area = length / 2
        surface += area
        let nz = cross.z / length
        let onBed = max(a.z, b.z, c.z) <= floor && nz <= -0.999999
        if !onBed, nz < -printReviewOverhangCosine { overhang += area }
    }
    return OverhangShare(overhangAreaMM2: overhang, surfaceAreaMM2: surface)
}

/// Overhangs on less than this share of the surface count as minor: "checks found no problems" allows them.
let printReviewOverhangLimit = 0.02

extension OverhangShare {
    /// Under `printReviewOverhangLimit` of the surface.
    var isMinor: Bool { fraction < printReviewOverhangLimit }
}

// MARK: Turning the model

/// The fixed turns the review can suggest (the Print orientation tool's standard placements), with the names Claude
/// uses. "As placed" (`zUp`) isn't a step.
let printReviewTurns: [(name: String, orientation: PrintOrientation)] = [
    ("upside_down", .zDown), ("x_up", .xUp), ("x_down", .xDown), ("y_up", .yUp), ("y_down", .yDown)
]

/// "upside down", "on its side, +X side up", …
func printReviewTurnLabel(_ orientation: PrintOrientation) -> String {
    switch orientation {
    case .zUp: return "as placed"
    case .zDown: return "upside down"
    case .xUp: return "on its side, +X side up"
    case .xDown: return "on its side, +X side down"
    case .yUp: return "on its side, +Y side up"
    case .yDown: return "on its side, +Y side down"
    case .face: return "on a flat face"
    }
}

/// The overhang share the model would have if turned.
struct PrintReviewTurnOverhang: Equatable, Sendable {
    let orientation: PrintOrientation
    let overhang: OverhangShare
}

// MARK: Measurements

/// What Studio measured on this Mac. Shown before anything is sent, sent with the review, and measured again after
/// a run for the before → after comparison.
struct PrintReviewMeasurements: Equatable, Sendable {
    let sizeMM: SIMD3<Float>
    /// The model's lowest corner, so thin-spot positions read from there.
    let origin: SIMD3<Float>
    let triangles: Int
    let health: MeshHealthReport
    let wall: WallThicknessReport
    let flatBase: FlatBaseSuggestion
    let overhang: OverhangShare
    /// The same check for each of `printReviewTurns`, in that order.
    var turns: [PrintReviewTurnOverhang] = []

    var fitsBuildVolume: Bool { sizeMM.max() <= slantBuildVolumeMM }
    var isSound: Bool { meshHealthIsSound(health) }
    var bottomContactMM2: Double { flatBase.currentContactMM2 }
    var wallSummary: WallThicknessSummary { wallThicknessSummary(wall, origin: origin) }
    /// "Studio's checks found no problems" may be said only when this is true: a sound mesh in one part, no walls
    /// under 2 mm found, a flat base, minor overhangs at most, and a fit in the build volume.
    var checksFoundNoProblems: Bool {
        isSound && health.shells == 1 && wallSummary.isClear && fitsBuildVolume && flatBase.alreadyFlat && overhang.isMinor
    }
}

/// What "Studio's checks found no problems" covers, said with it.
let printReviewNoProblemsLine = "Studio’s checks found no problems: a closed mesh in one part, no walls under 2 mm found, a flat base, overhangs on under \(Int(printReviewOverhangLimit * 100))% of the surface, and it fits Slant’s 220 mm build volume."

/// Measures `mesh` for the review. Nil when cancelled. `wallSamples` bounds the wall-thickness check (tests use fewer).
func measureForPrintReview(_ mesh: STLMesh, wallSamples: Int = wallThicknessMaximumSamples,
                           progress: (Double, String) -> Void = { _, _ in },
                           isCancelled: () -> Bool = { false }) -> PrintReviewMeasurements? {
    progress(0, "Checking the mesh…")
    guard let health = analyzeMeshHealth(mesh, isCancelled: isCancelled), !isCancelled() else { return nil }
    progress(0.1, "Measuring wall thickness…")
    guard let wall = analyzeWallThickness(mesh, maximumSamples: wallSamples,
                                          progress: { progress(0.1 + $0 * 0.75, "Measuring wall thickness…") },
                                          isCancelled: isCancelled), !isCancelled() else { return nil }
    progress(0.85, "Measuring the base and overhangs…")
    let flat = mesh.flatBaseSuggestion()
    let overhang = overhangShare(mesh)
    var turns: [PrintReviewTurnOverhang] = []
    for turn in printReviewTurns {
        if isCancelled() { return nil }
        turns.append(PrintReviewTurnOverhang(orientation: turn.orientation, overhang: overhangShare(mesh.oriented(turn.orientation))))
    }
    if isCancelled() { return nil }
    progress(1, "Measured")
    return PrintReviewMeasurements(sizeMM: mesh.maximum - mesh.minimum, origin: mesh.minimum, triangles: mesh.triangleCount,
                                   health: health, wall: wall, flatBase: flat, overhang: overhang, turns: turns)
}

private func mm(_ value: Float) -> String { String(format: "%.1f mm", value) }
private func mmValue(_ value: Double) -> String { String(format: "%g", (value * 100).rounded() / 100) }
private func counted(_ n: Int, _ singular: String, _ plural: String) -> String { "\(n.formatted()) \(n == 1 ? singular : plural)" }

/// The mesh check in one line, without repair instructions (the plan decides those).
func printReviewMeshCheckLine(_ report: MeshHealthReport) -> String {
    var problems: [String] = []
    if report.openEdges > 0 { problems.append(counted(report.openEdges, "open edge", "open edges")) }
    if report.nonManifoldEdges > 0 {
        problems.append(counted(report.nonManifoldEdges, "edge shared by more than two faces", "edges shared by more than two faces"))
    }
    if report.flippedEdges > 0 { problems.append(counted(report.flippedEdges, "flipped edge", "flipped edges")) }
    if report.isInsideOut { problems.append("faces pointing inward") }
    if report.degenerateTriangles > 0 { problems.append(counted(report.degenerateTriangles, "zero-area triangle", "zero-area triangles")) }
    let parts = counted(report.shells, "part", "parts")
    if problems.isEmpty { return "Mesh check: closed and consistent, \(parts)." }
    return "Mesh check: needs repair — \(problems.joined(separator: ", ")); \(parts)."
}

/// "Overhangs: 12% of the surface…", for the facts and the comparison.
func printReviewOverhangLine(_ share: OverhangShare) -> String {
    if share.overhangAreaMM2 <= 0 { return "Overhangs: no downward faces steeper than 45° from vertical, as placed." }
    return "Overhangs: \(percentLabel(share.fraction)) of the surface faces down more steeply than 45° from vertical, as placed (\(Int(share.overhangAreaMM2.rounded()).formatted()) mm²; likely to need supports or a different orientation)."
}

/// Studio's facts, one per line: shown to the seller and sent to Claude word for word.
func printReviewFactLines(_ m: PrintReviewMeasurements) -> [String] {
    var lines: [String] = []
    lines.append("Size: \(mm(m.sizeMM.x)) wide (X) × \(mm(m.sizeMM.y)) deep (Y) × \(mm(m.sizeMM.z)) tall (Z).")
    lines.append(m.fitsBuildVolume
                 ? "Fits Slant’s 220 mm build volume."
                 : "Larger than Slant’s 220 mm build volume: the longest side is \(mm(m.sizeMM.max())).")
    if let small = smallPartAdvisory(extentMM: m.sizeMM) { lines.append(small) }
    lines.append("Triangles: \(m.triangles.formatted()).")
    lines.append(printReviewMeshCheckLine(m.health))
    if m.health.shells > 1 { lines.append(meshBodyChargeAdvisory(bodies: m.health.shells)) }
    let wall = m.wallSummary
    lines.append(wall.line + ".")
    lines.append(contentsOf: wall.details)
    let flat = m.flatBase
    lines.append("Flat on the bed now: \(Int(flat.currentContactMM2.rounded()).formatted()) mm² (footprint \(Int(flat.footprintMM2.rounded()).formatted()) mm²).")
    if flat.alreadyFlat {
        lines.append("Flat base: enough flat area to stand on as placed.")
    } else if let cut = flat.cutHeightMM, let contact = flat.contactAtCutMM2 {
        lines.append("Flat base: removing \(mmValue(Double(cut))) mm from the bottom would give \(Int(contact.rounded()).formatted()) mm² flat on the bed.")
    } else {
        lines.append("Flat base: removing up to \(mmValue(Double(flat.maximumCutMM))) mm doesn’t give \(Int(flat.targetContactMM2.rounded()).formatted()) mm² flat on the bed; a plinth may suit it better.")
    }
    lines.append(printReviewOverhangLine(m.overhang))
    if let turns = printReviewTurnsLine(m) { lines.append(turns) }
    if m.checksFoundNoProblems { lines.append(printReviewNoProblemsLine) }
    return lines
}

/// "If turned, overhangs would be: upside down 30%, …", or nil when the turns weren't measured.
func printReviewTurnsLine(_ m: PrintReviewMeasurements) -> String? {
    guard !m.turns.isEmpty else { return nil }
    let list = m.turns.map { "\(printReviewTurnLabel($0.orientation)) \(percentLabel($0.overhang.fraction))" }
    return "If turned, overhangs would be: \(list.joined(separator: "; ")) (as placed: \(percentLabel(m.overhang.fraction)))."
}

/// The context lines, bounded: what another tool or the seller said about this model.
func printReviewContextLines(_ context: PrintReviewContext) -> [String] {
    func clip(_ text: String) -> String? {
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return nil }
        return line.count > 300 ? String(line.prefix(300)) + "…" : line
    }
    var lines: [String] = []
    if let origin = clip(context.origin) { lines.append("Origin: \(origin)") }
    if let size = context.intendedSizeNote.flatMap(clip) { lines.append("Intended size: \(size)") }
    if let purpose = context.purpose.flatMap(clip) { lines.append("Purpose: \(purpose)") }
    for finding in context.findings.prefix(20) { if let line = clip(finding) { lines.append(line) } }
    return lines
}

/// Before → after, one line per measurement that changed (or every line when asked).
func printReviewComparisonLines(before: PrintReviewMeasurements, after: PrintReviewMeasurements) -> [String] {
    func size(_ s: SIMD3<Float>) -> String { meshFitSizeLabel(s) }
    var lines: [String] = []
    lines.append("Size: \(size(before.sizeMM)) → \(size(after.sizeMM))")
    lines.append("Triangles: \(before.triangles.formatted()) → \(after.triangles.formatted())")
    lines.append("Before: \(printReviewMeshCheckLine(before.health))")
    lines.append("After: \(printReviewMeshCheckLine(after.health))")
    lines.append("\(before.wallSummary.line) → \(after.wallSummary.line.replacingOccurrences(of: "Wall thickness: ", with: ""))")
    lines.append("Flat on the bed: \(Int(before.bottomContactMM2.rounded()).formatted()) mm² → \(Int(after.bottomContactMM2.rounded()).formatted()) mm²")
    lines.append("Overhangs: \(percentLabel(before.overhang.fraction)) → \(percentLabel(after.overhang.fraction)) of the surface")
    if !after.fitsBuildVolume { lines.append("Larger than Slant’s 220 mm build volume.") }
    if after.checksFoundNoProblems { lines.append(printReviewNoProblemsLine) }
    return lines
}

// MARK: What the seller says about the model

/// "What is it for?", asked before Ask Claude.
enum PrintReviewPurposeChoice: String, CaseIterable, Identifiable, Sendable {
    case display = "Display piece", functional = "Functional part", notSure = "Not sure"
    var id: String { rawValue }
}

/// The choice to start with: what another tool passed in, else the model's saved part purpose, else Not sure.
func printReviewInitialPurpose(context: PrintReviewContext, partIntent: PartIntent?) -> PrintReviewPurposeChoice {
    if let said = context.purpose?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        if said.hasPrefix("display") { return .display }
        if said.hasPrefix("functional") { return .functional }
    }
    guard let partIntent else { return .notSure }
    return partIntent.purpose == .decorative ? .display : .functional
}

/// Reads a size note such as Generate a Replica's "Height should be 120 mm (typed by the seller)" or Studio's own
/// "Height (Z) should be 120 mm …". Nil for anything else.
func printReviewSizeFromNote(_ note: String?) -> (axis: MeshFitAxis, mm: Double)? {
    guard let text = note?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !text.isEmpty else { return nil }
    let axis: MeshFitAxis
    if text.hasPrefix("height") { axis = .z }
    else if text.hasPrefix("width") { axis = .x }
    else if text.hasPrefix("depth") { axis = .y }
    else if text.hasPrefix("longest") { axis = .longest }
    else { return nil }
    guard let range = text.range(of: " should be ") else { return nil }
    let rest = text[range.upperBound...]
    guard let end = rest.range(of: " mm") else { return nil }
    guard let value = meshFitMillimetres(String(rest[..<end.lowerBound])) else { return nil }
    return (axis, value)
}

/// "Height (Z) should be 120 mm (typed by the seller)".
func printReviewSizeNote(axis: MeshFitAxis, mm: Double) -> String {
    "\(axis.rawValue) should be \(mmValue(mm)) mm (typed by the seller)"
}

/// Why the typed real size can't be used, or nil (an empty field is fine: the size is optional).
func printReviewSizeProblem(_ text: String) -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    guard let value = meshFitMillimetres(trimmed) else { return "Enter the size in millimetres, such as 120 or 85.5." }
    if value < 1 { return "Enter at least 1 mm." }
    return nil
}

/// The context sent with the review: the seller's purpose and real size replace what was passed in. A size note that
/// Studio couldn't read into the fields is kept while the size field is empty.
func printReviewEffectiveContext(_ base: PrintReviewContext, purpose: PrintReviewPurposeChoice, sizeAxis: MeshFitAxis,
                                 sizeText: String) -> PrintReviewContext {
    var context = base
    context.purpose = purpose == .notSure ? nil : purpose.rawValue
    let trimmed = sizeText.trimmingCharacters(in: .whitespacesAndNewlines)
    if printReviewSizeProblem(trimmed) == nil, let value = meshFitMillimetres(trimmed) {
        context.intendedSizeNote = printReviewSizeNote(axis: sizeAxis, mm: value)
    } else if printReviewSizeFromNote(base.intendedSizeNote) != nil || !trimmed.isEmpty {
        context.intendedSizeNote = nil
    }
    return context
}

/// The purpose Auto-improve works to: the model's own (as Optimise for purpose shows it), else a decorative part for a
/// display piece, else Optimise for purpose's default, as the Auto-improve card does.
func printReviewAutoImproveIntent(_ model: LocalModel, purpose: PrintReviewPurposeChoice) -> PartIntent {
    if let saved = designEditIntent(model) { return saved }
    return purpose == .display ? PartIntent(purpose: .decorative) : PartIntent()
}

/// Auto-improve's settings for this model, or why it can't run here.
func printReviewAutoImproveSettings(_ model: LocalModel, purpose: PrintReviewPurposeChoice) -> (PrintReviewAutoImprove?, String?) {
    if model.autoImprovement != nil { return (nil, "This copy has been auto-improved already.") }
    let intent = printReviewAutoImproveIntent(model, purpose: purpose)
    guard intent.isReady else {
        return (nil, "Auto-improve needs the part’s main stress direction\(intent.purpose == .custom ? " and a description" : ""). Set it in Optimise for purpose, then review again.")
    }
    return (PrintReviewAutoImprove(intent: intent, keepPlacement: model.printRecipe != nil || model.requiresZUp), nil)
}

/// Why the review can't turn this model, or nil.
func printReviewOrientBlockedReason(_ model: LocalModel) -> String? {
    if model.requiresZUp { return "This copy has features that depend on its print layers, so it stays Z up." }
    if model.printRecipe != nil { return "This copy already has a prepared placement. Turn the original instead." }
    return nil
}

/// Manual advice that names Reinforce gets a link to that card.
func printReviewMentionsReinforce(_ text: String) -> Bool {
    text.range(of: "reinforce", options: .caseInsensitive) != nil
}

// MARK: Plan

enum PrintReviewSeverity: String, Equatable, Sendable {
    case low, medium, high
    var title: String { rawValue.capitalized }
}

struct PrintReviewRisk: Equatable, Sendable {
    let part: String
    let issue: String
    let severity: PrintReviewSeverity
}

/// How Auto-improve runs in a review: the part's purpose, and whether it keeps the model's placement (a prepared or
/// Z-up-locked copy) rather than choosing one for the purpose.
struct PrintReviewAutoImprove: Equatable, Sendable {
    let intent: PartIntent
    let keepPlacement: Bool
}

/// A step Studio can run with its own tools, or advice it never runs.
enum PrintReviewAction: Equatable, Sendable {
    case repair
    case simplify(target: Int)
    /// One of `printReviewTurns`.
    case orient(PrintOrientation)
    case scaleToSize(axis: MeshFitAxis, mm: Double)
    case flatBase(cutMM: Float)
    case plinth(PlinthSettings)
    case autoImprove(PrintReviewAutoImprove)
    case manual(String)

    var toolName: String {
        switch self {
        case .repair: return "repair"
        case .simplify: return "simplify"
        case .orient: return "orient"
        case .scaleToSize: return "scale_to_size"
        case .flatBase: return "flat_base"
        case .plinth: return "plinth"
        case .autoImprove: return "auto_improve"
        case .manual: return "manual"
        }
    }

    var isManual: Bool { if case .manual = self { return true }; return false }
    /// Repair and simplify keep the model's placement and edit records, and Auto-improve keeps them as its own card
    /// does; turning, scaling and bases change what those records describe.
    var keepsRecords: Bool {
        switch self {
        case .repair, .simplify, .autoImprove: return true
        default: return false
        }
    }
}

struct PrintReviewStep: Equatable, Identifiable, Sendable {
    /// Position in the plan as shown, from 1.
    let id: Int
    let tool: String
    let title: String
    /// Nil when the step's settings couldn't be read.
    let action: PrintReviewAction?
    let reason: String
    /// Why Studio won't run this step, or nil.
    let problem: String?

    var isManual: Bool { tool == "manual" }
    var isRunnable: Bool { action != nil && problem == nil && !isManual }
}

struct PrintReviewPlan: Equatable, Sendable {
    let assessment: String
    let risks: [PrintReviewRisk]
    let steps: [PrintReviewStep]
    let orientation: String
    let materialNote: String
    /// Studio's own notes on what it left out (unknown tools, too many steps).
    let notes: [String]
}

/// What plan validation checks steps against: the model as measured, and what the fit tools allow for it.
struct PrintReviewPlanContext: Equatable, Sendable {
    var triangles: Int
    var sizeMM: SIMD3<Float>
    /// `meshFitEditBlockedReason(model, tool: .scale)`.
    var scaleBlockedReason: String?
    /// `meshFitEditBlockedReason(model, tool: .flatBase)` (the same rule covers plinths).
    var baseBlockedReason: String?
    /// `printReviewOrientBlockedReason(model)`.
    var orientBlockedReason: String? = nil
    /// `printReviewAutoImproveSettings(model, purpose:)`: the settings, or why Auto-improve can't run.
    var autoImprove: PrintReviewAutoImprove? = nil
    var autoImproveBlockedReason: String? = nil
}

let printReviewSimplifyRange = 2_000...20_000
let printReviewMaximumSteps = 12
let printReviewMaximumRisks = 12
let printReviewToolNames = ["repair", "simplify", "orient", "scale_to_size", "flat_base", "plinth", "auto_improve", "manual"]

/// One line of Claude's text, trimmed and bounded, for display.
func printReviewText(_ value: AnthropicJSON?, limit: Int) -> String {
    guard let text = value?.stringValue else { return "" }
    var scalars = String.UnicodeScalarView()
    for scalar in text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
    where scalar == "\n" || !CharacterSet.controlCharacters.contains(scalar) {
        scalars.append(scalar)
    }
    var result = String(scalars)
    if result.count > limit { result = String(result.prefix(limit)) + "…" }
    return result
}

func printReviewAxisName(_ axis: MeshFitAxis) -> String {
    switch axis {
    case .longest: return "longest side"
    case .x: return "width (X)"
    case .y: return "depth (Y)"
    case .z: return "height (Z)"
    }
}

/// The title shown for a step.
func printReviewStepTitle(_ action: PrintReviewAction) -> String {
    switch action {
    case .repair: return "Repair the mesh"
    case .simplify(let target): return "Simplify to \(target.formatted()) triangles"
    case .orient(let orientation): return "Turn it \(printReviewTurnLabel(orientation))"
    case .scaleToSize(let axis, let value): return "Scale so the \(printReviewAxisName(axis)) is \(mmValue(value)) mm"
    case .flatBase(let cut): return "Flat base: remove \(mmValue(Double(cut))) mm from the bottom"
    case .plinth(let settings):
        return "\(settings.shape.rawValue) plinth, \(mmValue(Double(settings.marginMM))) mm margin, \(mmValue(Double(settings.thicknessMM))) mm thick"
    case .autoImprove(let settings): return "Auto-improve as a \(settings.intent.purpose.rawValue.lowercased()) part"
    case .manual: return "Do this yourself"
    }
}

private func printReviewToolTitle(_ tool: String) -> String {
    switch tool {
    case "repair": return "Repair the mesh"
    case "simplify": return "Simplify"
    case "orient": return "Turn the model"
    case "scale_to_size": return "Scale to size"
    case "flat_base": return "Flat base"
    case "plinth": return "Plinth"
    case "auto_improve": return "Auto-improve"
    default: return "Do this yourself"
    }
}

/// The model's size after a step, so later steps are checked against the size they will meet. Plinths are estimated
/// (a round one is a little larger).
private func printReviewSize(after action: PrintReviewAction, from size: SIMD3<Float>) -> SIMD3<Float> {
    switch action {
    case .orient(let orientation): return simd_abs(orientation.rotate(size))
    case .scaleToSize(let axis, let value):
        return (try? scaleToSizePlan(extentMM: size, axis: axis, targetMM: value))?.resultSizeMM ?? size
    case .flatBase(let cut): return SIMD3(size.x, size.y, max(0, size.z - cut))
    case .plinth(let settings):
        let grow = 2 * settings.marginMM
        let across = settings.shape == .round ? (size.x * size.x + size.y * size.y).squareRoot() + grow : 0
        return SIMD3(max(size.x + grow, across), max(size.y + grow, across),
                     size.z + settings.thicknessMM - settings.joinDepthMM)
    default: return size
    }
}

/// Reads Claude's `propose_plan` input. Every step is checked against the model as the runnable steps before it would
/// leave it (size and triangles); a step with bad or out-of-range settings is kept with its problem (shown, never
/// runnable), an unknown tool is left out with a note, and only the first of each tool runs. Auto-improve must be the
/// last step that changes the model, and doesn't go with a turn (it places the part itself).
func decodePrintReviewPlan(_ input: AnthropicJSON, context: PrintReviewPlanContext) -> PrintReviewPlan {
    var notes: [String] = []
    var risks: [PrintReviewRisk] = []
    let rawRisks = input["risks"]?.arrayValue ?? []
    for raw in rawRisks.prefix(printReviewMaximumRisks) {
        let part = printReviewText(raw["part"], limit: 120), issue = printReviewText(raw["issue"], limit: 400)
        guard !part.isEmpty || !issue.isEmpty else { continue }
        let severity = raw["severity"]?.stringValue.flatMap(PrintReviewSeverity.init(rawValue:)) ?? .medium
        risks.append(PrintReviewRisk(part: part, issue: issue, severity: severity))
    }
    if rawRisks.count > printReviewMaximumRisks {
        notes.append("Claude listed \(rawRisks.count) risks; the first \(printReviewMaximumRisks) are shown.")
    }

    var steps: [PrintReviewStep] = []
    var firstStepForTool: [String: Int] = [:]
    var baseStep: Int?
    // The model as the runnable steps so far would leave it.
    var current = context
    let rawSteps = input["steps"]?.arrayValue ?? []
    for raw in rawSteps {
        let tool = raw["tool"]?.stringValue ?? ""
        guard printReviewToolNames.contains(tool) else {
            let name = aiServiceRedacted(tool, limit: 40)
            notes.append(name.isEmpty
                         ? "Claude suggested a step without a tool, so it was left out."
                         : "Claude suggested a tool Studio doesn’t have (“\(name)”), so it was left out.")
            continue
        }
        guard steps.count < printReviewMaximumSteps else {
            notes.append("Claude suggested more than \(printReviewMaximumSteps) steps; the rest were left out.")
            break
        }
        let number = steps.count + 1
        let reason = printReviewText(raw["reason"], limit: 400)
        let (action, ownProblem) = printReviewStepAction(tool: tool, raw: raw, context: current)
        var problem = ownProblem
        if problem == nil, tool != "manual" {
            if let earlier = firstStepForTool[tool] {
                problem = "Already in the plan as step \(earlier)."
            } else if let earlier = firstStepForTool["auto_improve"] {
                problem = "Step \(earlier) auto-improves the part, which has to come last: changing the model afterwards would spoil its treatments."
            } else if tool == "flat_base" || tool == "plinth", let earlier = baseStep {
                problem = "Step \(earlier) already adds a base. Choose a flat base or a plinth, not both."
            } else if tool == "auto_improve", let earlier = firstStepForTool["orient"] {
                problem = "Step \(earlier) already turns the part, and Auto-improve places it for its purpose itself. Choose one."
            }
        }
        // Only a step that can run claims its tool, so a later valid step can stand in for an invalid one.
        if problem == nil, tool != "manual" {
            firstStepForTool[tool] = number
            if tool == "flat_base" || tool == "plinth" { baseStep = number }
            if let action {
                current.sizeMM = printReviewSize(after: action, from: current.sizeMM)
                if case .simplify(let target) = action { current.triangles = min(current.triangles, target) }
            }
        }
        steps.append(PrintReviewStep(id: number, tool: tool, title: action.map(printReviewStepTitle) ?? printReviewToolTitle(tool),
                                     action: action, reason: reason, problem: problem))
    }
    return PrintReviewPlan(assessment: printReviewText(input["assessment"], limit: 2_000), risks: risks, steps: steps,
                           orientation: printReviewText(input["orientation"], limit: 600),
                           materialNote: printReviewText(input["material_note"], limit: 600), notes: notes)
}

/// The step's action and, when Studio won't run it, why.
private func printReviewStepAction(tool: String, raw: AnthropicJSON, context: PrintReviewPlanContext) -> (PrintReviewAction?, String?) {
    func number(_ key: String) -> Double? {
        guard let value = raw[key]?.doubleValue, value.isFinite else { return nil }
        return value
    }
    switch tool {
    case "repair":
        return (.repair, nil)
    case "orient":
        guard let name = raw["turn"]?.stringValue, let turn = printReviewTurns.first(where: { $0.name == name }) else {
            return (nil, "Claude didn’t say which way to turn it.")
        }
        let action = PrintReviewAction.orient(turn.orientation)
        if let blocked = context.orientBlockedReason { return (action, blocked) }
        return (action, nil)
    case "auto_improve":
        if let blocked = context.autoImproveBlockedReason { return (nil, blocked) }
        guard let settings = context.autoImprove else { return (nil, "Auto-improve isn’t available for this model.") }
        let action = PrintReviewAction.autoImprove(settings)
        if context.triangles > meshToolsReinforceTriangleLimit {
            return (action, "Auto-improve accepts up to \(meshToolsReinforceTriangleLimit.formatted()) triangles and the model will have \(context.triangles.formatted()) by then. Put a Simplify step before it.")
        }
        return (action, nil)
    case "simplify":
        guard let value = number("target_triangles") else { return (nil, "Claude didn’t give a target triangle count.") }
        guard value.rounded() == value, let target = Int(exactly: value) else { return (nil, "The target must be a whole number of triangles.") }
        guard printReviewSimplifyRange.contains(target) else {
            return (nil, "The target must be from \(printReviewSimplifyRange.lowerBound.formatted()) to \(printReviewSimplifyRange.upperBound.formatted()) triangles.")
        }
        let action = PrintReviewAction.simplify(target: target)
        if context.triangles <= target {
            return (action, "This model already has \(context.triangles.formatted()) triangles, so there’s nothing to simplify.")
        }
        return (action, nil)
    case "scale_to_size":
        let axes: [String: MeshFitAxis] = ["longest": .longest, "x": .x, "y": .y, "z": .z]
        guard let name = raw["axis"]?.stringValue, let axis = axes[name] else { return (nil, "Claude didn’t say which side to measure.") }
        guard let value = number("mm") else { return (nil, "Claude didn’t give a size.") }
        guard value >= 0.1, value <= 10_000 else { return (nil, "The size must be from 0.1 to 10,000 mm.") }
        let action = PrintReviewAction.scaleToSize(axis: axis, mm: value)
        if let blocked = context.scaleBlockedReason { return (action, blocked) }
        do {
            let plan = try scaleToSizePlan(extentMM: context.sizeMM, axis: axis, targetMM: value)
            if !plan.fitsBuildVolume {
                return (action, "The result would be \(mm(plan.resultSizeMM.max())) on its longest side, larger than Slant’s 220 mm build volume.")
            }
        } catch {
            return (action, error.localizedDescription)
        }
        return (action, nil)
    case "flat_base":
        guard let value = number("cut_mm") else { return (nil, "Claude didn’t say how much to remove.") }
        guard value > 0, value <= 5 else { return (nil, "The cut must be more than 0 and at most 5 mm.") }
        let action = PrintReviewAction.flatBase(cutMM: Float(value))
        if let blocked = context.baseBlockedReason { return (action, blocked) }
        if Float(value) >= context.sizeMM.z / 4 {
            return (action, "That would remove a quarter or more of the model’s height, which is \(mm(context.sizeMM.z)) at that point in the plan.")
        }
        return (action, nil)
    case "plinth":
        let shapes: [String: PlinthShape] = ["round": .round, "rectangular": .rectangular]
        guard let name = raw["shape"]?.stringValue, let shape = shapes[name] else { return (nil, "Claude didn’t choose a plinth shape.") }
        guard let margin = number("margin_mm"), let thickness = number("thickness_mm") else {
            return (nil, "Claude didn’t give the plinth’s margin and thickness.")
        }
        var settings = PlinthSettings()
        settings.shape = shape
        settings.marginMM = Float(margin)
        settings.thicknessMM = Float(thickness)
        if let problem = plinthSettingsProblem(settings) { return (nil, problem) }
        let action = PrintReviewAction.plinth(settings)
        if let blocked = context.baseBlockedReason { return (action, blocked) }
        if settings.joinDepthMM >= context.sizeMM.z / 2 { return (action, "This model is too short to sink into a plinth.") }
        return (action, nil)
    default:
        let text = printReviewText(raw["text"], limit: 400)
        guard !text.isEmpty else { return (nil, "Claude didn’t say what to do.") }
        return (.manual(text), nil)
    }
}

/// Studio's own number for a step, shown next to Claude's reason.
func printReviewStudioNote(_ action: PrintReviewAction, measurements m: PrintReviewMeasurements,
                           context: PrintReviewContext) -> String {
    switch action {
    case .repair:
        return m.isSound ? "Studio: the mesh is already closed and consistent, so this may change nothing."
            : "Studio: \(printReviewMeshCheckLine(m.health))"
    case .simplify:
        return "Studio: now \(counted(m.triangles, "triangle", "triangles")). Reinforce and Auto-improve accept up to \(meshToolsReinforceTriangleLimit.formatted())."
    case .scaleToSize(let axis, let value):
        let current: Float
        switch axis {
        case .longest: current = m.sizeMM.max()
        case .x: current = m.sizeMM.x
        case .y: current = m.sizeMM.y
        case .z: current = m.sizeMM.z
        }
        var note = "Studio: the \(printReviewAxisName(axis)) is now \(mm(current))"
        if let result = try? scaleToSizePlan(extentMM: m.sizeMM, axis: axis, targetMM: value) {
            note += "; result \(meshFitSizeLabel(result.resultSizeMM))"
        }
        note += "."
        if let typed = context.intendedSizeNote?.trimmingCharacters(in: .whitespacesAndNewlines), !typed.isEmpty {
            note += " You said: \(typed)"
        } else {
            note += " Check the size against the real object; Claude can’t measure it."
        }
        return note
    case .flatBase:
        var note = "Studio: \(Int(m.bottomContactMM2.rounded()).formatted()) mm² flat on the bed now"
        if m.flatBase.alreadyFlat { note += ", which is enough to stand on" }
        else if let cut = m.flatBase.cutHeightMM { note += "; Studio would remove \(mmValue(Double(cut))) mm" }
        return note + "."
    case .plinth:
        return "Studio: \(Int(m.bottomContactMM2.rounded()).formatted()) mm² flat on the bed now; the model is \(mm(m.sizeMM.z)) tall."
    case .orient(let orientation):
        guard let turned = m.turns.first(where: { $0.orientation == orientation }) else {
            return "Studio: overhangs on \(percentLabel(m.overhang.fraction)) of the surface as placed."
        }
        return "Studio: overhangs on \(percentLabel(m.overhang.fraction)) of the surface as placed, \(percentLabel(turned.overhang.fraction)) turned this way. Check the flat base again after turning."
    case .autoImprove(let settings):
        var purpose = settings.intent.purpose.rawValue
        if settings.intent.effectiveLoad != .unknown { purpose += ", main stress along \(settings.intent.effectiveLoad.rawValue.lowercased())" }
        let placement = settings.keepPlacement ? "keeps the model’s current placement" : "places the part for that purpose"
        return "Studio: uses the part’s purpose (\(purpose)); change it in Optimise for purpose. It \(placement), then adds only treatments that pass its checks, such as chamfers under ledges and fillets in inside corners."
    case .manual:
        return "Studio doesn’t run this. Do it yourself, then review the result again."
    }
}

/// Advice about the ticked steps before they run, such as a base on a mesh that isn't closed yet, or Auto-improve on
/// a model with too many triangles.
func printReviewSelectionNotes(_ actions: [PrintReviewAction], measurements m: PrintReviewMeasurements) -> [String] {
    var notes: [String] = []
    var repaired = m.isSound
    var triangles = m.triangles
    for action in actions {
        switch action {
        case .repair: repaired = true
        case .simplify(let target):
            if !repaired { notes.append("Simplify works best on a repaired mesh.") }
            triangles = min(triangles, target)
        case .flatBase, .plinth:
            if !repaired {
                notes.append("A flat base or plinth needs a closed mesh. Tick Repair the mesh as well (it runs first when it comes first in the plan), or the run will stop.")
                return notes
            }
        case .autoImprove:
            if triangles > meshToolsReinforceTriangleLimit {
                notes.append("Auto-improve accepts up to \(meshToolsReinforceTriangleLimit.formatted()) triangles. Tick a Simplify step before it, or the run will stop.")
            }
        default: break
        }
    }
    return notes
}

// MARK: Running the ticked steps

struct PrintReviewRunStep: Equatable, Sendable {
    /// The step's number in the plan, for messages.
    let number: Int
    let action: PrintReviewAction
}

/// What Auto-improve did in a run, for the copy's records.
struct PrintReviewAutoImproveOutcome: Equatable, Sendable {
    let intent: PartIntent
    let orientation: PrintOrientation
    let applied: [AutoImprovementStep]
    let skipped: [String]
    let manual: [String]
}

struct PrintReviewRunResult: Sendable {
    let mesh: STLMesh
    /// The binary STL to save.
    let data: Data
    /// What each step did, in order.
    let lines: [String]
    /// False when the result is byte-for-byte the input.
    let changed: Bool
    /// Set when an Auto-improve step changed the model.
    var autoImprove: PrintReviewAutoImproveOutcome? = nil
}

enum PrintReviewRunError: LocalizedError, Equatable {
    case cancelled
    case nothingToRun
    case step(number: Int, title: String, message: String)
    /// The model passed the mesh check and the result wouldn't.
    case madeWorse
    /// The model fitted the build volume and the result wouldn't; its longest side.
    case tooLarge(Float)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Stopped. Nothing was saved."
        case .nothingToRun: return "Tick at least one step that Studio can run."
        case .step(let number, let title, let message):
            return "Step \(number) (\(title)) couldn’t be done, so the run stopped and nothing was saved. \(message)"
        case .madeWorse:
            return "This model passes the mesh check, but the result wouldn’t, so nothing was saved. Try fewer steps, or a higher Simplify target."
        case .tooLarge(let longest):
            return "The result would be \(String(format: "%.1f", longest)) mm on its longest side, larger than Slant’s 220 mm build volume, so nothing was saved."
        }
    }
}

/// Runs the steps in order on an in-memory copy with Studio's mesh tools, Print orientation's fixed turns and
/// Auto-improve. Deterministic: the same mesh and steps give the same bytes (Auto-improve's own time limit aside). Manual
/// steps are never run. A failing step throws and nothing is returned, and so does a result that fails the mesh check
/// or the build volume when the model passed it.
func runPrintReviewSteps(_ steps: [PrintReviewRunStep], on original: STLMesh, progress: MeshToolProgress = { _, _ in },
                         isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> PrintReviewRunResult {
    let runnable = steps.filter { !$0.action.isManual }
    guard !runnable.isEmpty else { throw PrintReviewRunError.nothingToRun }
    var mesh = original
    var lines: [String] = []
    var autoImprove: PrintReviewAutoImproveOutcome?
    // A flat base or plinth made earlier in the run must stay on the bed, so Auto-improve then keeps Z up.
    var baseAdded = false
    let share = 1 / Double(runnable.count)
    for (index, step) in runnable.enumerated() {
        if isCancelled() { throw PrintReviewRunError.cancelled }
        let title = printReviewStepTitle(step.action)
        let base = Double(index) * share
        func stepProgress(_ fraction: Double, _ stage: String) { progress(base + fraction * share, "Step \(step.number): \(stage)") }
        progress(base, "Step \(step.number): \(title)…")
        do {
            switch step.action {
            case .orient(let orientation):
                let before = overhangShare(mesh)
                mesh = mesh.oriented(orientation)
                lines.append("\(title): overhangs \(percentLabel(before.fraction)) → \(percentLabel(overhangShare(mesh).fraction)) of the surface; now \(meshFitSizeLabel(mesh.maximum - mesh.minimum)).")
            case .autoImprove(let settings):
                let placement: PrintOrientation
                if settings.keepPlacement || baseAdded {
                    placement = .zUp
                } else {
                    guard let found = AutoImprover.orientation(for: mesh, intent: settings.intent, locked: false) else {
                        throw StudioError("No flat-bed placement fits among the positions checked.")
                    }
                    placement = found
                }
                let result = try AutoImprover.improve(mesh, intent: settings.intent, orientation: placement, cancelled: isCancelled)
                if result.changed {
                    mesh = result.mesh
                    autoImprove = PrintReviewAutoImproveOutcome(intent: settings.intent, orientation: result.orientation,
                                                                applied: result.applied, skipped: result.skipped, manual: result.manual)
                    let applied = result.applied.isEmpty ? "no treatments suited it" : result.applied.map(\.summary).joined(separator: "; ")
                    lines.append("\(title): placed \(printReviewTurnLabel(result.orientation)); \(applied).")
                } else {
                    lines.append("\(title): no automatic changes suit this part.")
                }
            case .flatBase(let cut):
                baseAdded = true
                let height = mesh.maximum.z - mesh.minimum.z
                guard cut < height / 4 else {
                    throw StudioError("That would remove a quarter or more of the model’s height, which is \(String(format: "%.1f", height)) mm at that point.")
                }
                let result = try mesh.flatBaseCopy(cutHeightMM: cut, isCancelled: isCancelled)
                mesh = result.mesh
                lines.append("\(title): \(Int(result.contactAreaMM2.rounded()).formatted()) mm² now flat on the bed.")
            case .repair:
                let result = try repairMesh(mesh, progress: stepProgress, isCancelled: isCancelled)
                if result.summary.changed { mesh = result.mesh }
                lines.append("\(title): " + (result.summary.changed ? meshRepairSummaryLines(result.summary).joined(separator: " ")
                                                                    : "nothing needed changing."))
            case .simplify(let target):
                var options = MeshSimplifyOptions()
                options.targetTriangles = target
                let result = try simplifyMesh(mesh, options: options, progress: stepProgress, isCancelled: isCancelled)
                if result.changed { mesh = result.mesh }
                lines.append("\(title): " + meshSimplifySummaryLines(result).joined(separator: " "))
            case .scaleToSize(let axis, let value):
                let before = mesh.maximum - mesh.minimum
                let scaled = try mesh.scaledToSizeSTLData(axis: axis, targetMM: value)
                mesh = try STLMesh.parse(scaled.data)
                lines.append("\(title): \(meshFitSizeLabel(before)) → \(meshFitSizeLabel(scaled.plan.resultSizeMM)).")
            case .plinth(let settings):
                baseAdded = true
                let result = try mesh.plinthCopy(settings, isCancelled: isCancelled)
                mesh = result.mesh
                lines.append("\(title): now \(meshFitSizeLabel(result.sizeMM)).")
            case .manual:
                continue
            }
        } catch let error as MeshToolError where error == .cancelled {
            throw PrintReviewRunError.cancelled
        } catch let error as MeshFitError where error == .stopped {
            throw PrintReviewRunError.cancelled
        } catch {
            if isCancelled() { throw PrintReviewRunError.cancelled }
            throw PrintReviewRunError.step(number: step.number, title: title, message: error.localizedDescription)
        }
    }
    if isCancelled() { throw PrintReviewRunError.cancelled }
    let data = mesh.binarySTL()
    let changed = data != original.binarySTL()
    if changed {
        // The copy must be no worse than the model: still sound if it was, and still within the build volume if it was.
        progress(0.98, "Checking the result…")
        guard let before = analyzeMeshHealth(original, isCancelled: isCancelled),
              let after = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw PrintReviewRunError.cancelled }
        if meshToolMadeWorse(before: before, after: after) { throw PrintReviewRunError.madeWorse }
        let longest = (mesh.maximum - mesh.minimum).max()
        if longest > slantBuildVolumeMM, (original.maximum - original.minimum).max() <= slantBuildVolumeMM {
            throw PrintReviewRunError.tooLarge(longest)
        }
    }
    progress(1, "Done")
    return PrintReviewRunResult(mesh: mesh, data: data, lines: lines, changed: changed, autoImprove: autoImprove)
}

/// "Name (print-ready)", without a model file extension.
func printReadyCopyName(_ name: String) -> String {
    var base = meshFitBaseName(name).trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { base = "Model" }
    return "\(base) (print-ready)"
}

/// The copy keeps the original's placement and edit records only when every step left size, base and placement alone
/// (repair, simplify and Auto-improve, as their own cards do); otherwise it keeps the part's purpose and source
/// details, as the fit tools do.
func printReadyCopyKeepsRecords(_ actions: [PrintReviewAction]) -> Bool {
    actions.allSatisfy(\.keepsRecords)
}

/// The records a print-ready copy is saved with (`StudioStore.importModel`).
struct PrintReadyCopyRecords: Equatable {
    var recipe: PreparedPrintRecipe?
    var improvement: DesignImprovementRecord?
    var intent: PartIntent?
    var reinforcement: ReinforcementRecord?
    var autoImprovement: AutoImprovementRecord?
    /// Kept from a print-ready original, so the copy stays as placed (`LocalModel.requiresZUp`).
    var printPreparation: PrintPreparationRecord?
}

/// The original's records when every step keeps them; and when Auto-improve changed the copy, its record and placement
/// as the Auto-improve card saves them.
func printReadyCopyRecords(for model: LocalModel, actions: [PrintReviewAction], autoImprove: PrintReviewAutoImproveOutcome?,
                           materialID: String?, now: Date = Date()) -> PrintReadyCopyRecords {
    var records = PrintReadyCopyRecords(intent: model.partIntent)
    let keeps = printReadyCopyKeepsRecords(actions)
    if keeps {
        records.recipe = model.printRecipe
        records.improvement = model.designImprovement
        records.reinforcement = model.reinforcement
        records.autoImprovement = model.autoImprovement
        records.printPreparation = model.printPreparation
    }
    if let auto = autoImprove {
        records.autoImprovement = AutoImprovementRecord(sourceID: model.id, orientation: auto.orientation, applied: auto.applied,
                                                        skipped: auto.skipped, manual: auto.manual, created: now)
        records.recipe = records.recipe ?? PreparedPrintRecipe(sourceID: model.id, sourceName: model.name, intent: auto.intent,
                                                               orientation: auto.orientation, materialID: materialID, created: now)
        records.intent = auto.intent
    }
    return records
}

// MARK: Claude request

let printReviewToolName = "propose_plan"
/// Edge length of each view sent: four views cost about 3,100 input tokens.
let printReviewRenderPixelSize = 768
/// Pixel tests allowed per view (768 px, sampled at 1536 × 1536): about 50 times the sample grid.
let printReviewRenderRasterBudget = 120_000_000

let printReviewSystemPrompt = """
You review 3D models for FDM printing for a small online seller who uses Slant Studio. Slant 3D prints them on \
demand with fixed settings it publishes, which can't be changed for an order or a part: 0.2 mm layers (0.3 mm first \
layer), a 0.4 mm nozzle, 1 mm walls (about 2 lines), 25% grid-like infill, overhangs up to 50° from vertical, no \
brims, a textured bed and a 220 mm cube build volume. Slant prints the model in the orientation it is uploaded in, \
re-orienting only an obviously wrong upload, so the placement the seller uploads is how it prints. Slant decides at \
upload whether supports are needed, prices supports, surface area and failure risk, and charges extra for each \
separate body. Not published: the line width, the tolerances Slant holds and which slicer it uses.

You get four orthographic renders of the model as it is placed in its file (Z up; Front looks at the −Y side, Side \
looks at the +X side, Top looks straight down, Three-quarter is from the front right, above) and Studio's own \
measurements. Studio measured the mesh itself: trust its numbers over what the pictures suggest. Units are millimetres. \
Thin-spot positions are measured from the model's lowest corner.

Guidelines for parts that print well:
- Load-bearing walls 2.0 mm or more (several lines), never under 1.0 mm. With 1 mm walls and 25% infill, a thick \
solid region is mostly sparse infill: for load, walls and ribs do more than solid bulk.
- One connected body. More than one shell (separate pieces, or closed hidden pockets inside) is billed as extra bodies \
(about $0.39 each in a test); a cavity open to the outside is not. Thin slots about 0.25 mm wide that open through \
the bottom face make the slicer add walls and keep one body.
- Parts at least about 20 mm on a side, as Slant recommends; flag smaller ones as advice, not a reason to refuse.
- Overhangs no more than 45° from vertical (Slant allows 50°; 45° leaves a margin); horizontal holes as teardrops; \
bridges under 5 mm. Fewer supports cost less.
- A flat base on the bed, with about a 0.5 mm chamfer on the bottom edge.
- Fillets where features meet (stress roots); loads along the layers (in X and Y), not across them.
- Pins and posts 3–5 mm or more; embossed detail about 1 mm; printed fits 0.2–0.3 mm clearance per side.
- PETG for heat (for example inside a car); PLA softens at about 55–60 °C.
- Thin protrusions (tails, horns, blades, antennae, fingers) under about 3 mm across are likely to snap in printing, \
when supports come off, or in the post. Flag them.

Answer only by calling propose_plan, once. Studio runs a step only if the seller ticks it, on a copy, on this Mac. \
Steps may use only these tools; set every field a step doesn't use to null:
- repair: joins nearby vertices, removes zero-area, repeated and loose triangles, turns faces the right way and \
closes small holes. Suggest it when Studio's mesh check needs repair.
- simplify (target_triangles, 2000–20000): fewer triangles. Suggest it only when the model has more than 20,000 \
triangles and you also suggest auto_improve or advise Reinforce (both accept up to 20,000); otherwise detail is worth \
keeping.
- orient (turn: upside_down, x_up, x_down, y_up or y_down): turns the model onto another side (x_up puts the side \
shown in the Side view on top; y_up puts the side facing away from the Front view on top). Studio lists the overhang \
share for each turn: suggest the one that clearly reduces overhangs, if it still leaves a stable, flat base.
- scale_to_size (axis: longest, x, y or z; mm): scales evenly so that side measures mm, as the model is at that point \
in the plan. Only when the seller's intended size is given, and then use exactly that size. Never guess a real-world size.
- flat_base (cut_mm, more than 0 and at most 5): cuts the bottom level and fills it so the model stands on a flat face. \
Studio's suggested cut is in the measurements.
- plinth (shape: round or rectangular; margin_mm 1–30; thickness_mm 1–20): a base with a chamfered bottom edge under \
the whole model, for tall or top-heavy figures. Choose a flat base or a plinth, not both.
- auto_improve: Studio's Auto-improve places the part for its purpose (unless its placement is fixed) and adds only \
treatments that pass its checks: bridging for counterbores, chamfers under ledges, thin walls thickened on the \
inside to a whole number of Studio's assumed 0.45 mm lines, and fillets in inside corners. Accepts up to 20,000 triangles. It must be the last step that changes the model, and \
it doesn't go with orient. Suggest it for functional parts.
- manual (text): anything the tools above can't do, which the seller does elsewhere. Prefer Studio's own tools: \
"Use Reinforce in Studio to add a gusset under the arm" or "Use Reinforce to add a rib along the handle" before \
"Thicken the sword blade to 3 mm in your CAD app".
Put steps in the order they should run: repair, simplify, orient, scale, the base, auto_improve, then manual advice. \
Leave out steps that aren't needed; an empty list is fine.

How to write:
- You advise; you never change the model.
- Never say a part is strong, approved, safe, guaranteed or won't break, and never give a strength percentage. Say \
"likely weak point", "below the 2 mm guideline" and so on.
- Quote Studio's numbers and positions when you use them, such as "walls of 0.8 mm about 40 mm up".
- Say Studio's checks found no problems only when its measurements say so.
- risks: specific parts you can see (such as "sword blade" or "left ear"), what may go wrong, and a severity: high when \
the print is likely to fail or the part to break in printing, shipping or normal use; medium for a likely weak point \
or a visible flaw worth fixing first; low for something worth knowing that most prints survive.
- orientation: how to place it on the bed and why, in one or two sentences, naming the turn with the fewest overhangs \
when it differs from how the model is placed.
- material_note: one or two sentences on material.
- If the seller says it is a display piece, favour looks and standing steady; for a functional part, favour strength \
along its loads.
- Plain, short sentences in British English.
"""

private let printReviewNullableNumber: AnthropicJSON = ["anyOf": [["type": "number"], ["type": "null"]]]

/// `propose_plan`. Strict, so every field is required (null when unused) and numbers carry no range keywords (strict
/// schemas don't support them); Studio checks ranges itself in `decodePrintReviewPlan`.
let printReviewPlanTool = AnthropicTool(
    name: printReviewToolName,
    description: "Give your review of the model for FDM printing and a plan made only of Studio's tools. Call this once with your whole answer.",
    inputSchema: [
        "type": "object",
        "properties": [
            "assessment": ["type": "string", "description": "Two to four sentences: how printable the model looks and why."],
            "risks": [
                "type": "array",
                "description": "Likely weak points or print problems, most serious first.",
                "items": [
                    "type": "object",
                    "properties": [
                        "part": ["type": "string", "description": "The part, such as \"sword blade\"."],
                        "issue": ["type": "string", "description": "What may go wrong when it prints."],
                        "severity": ["type": "string", "enum": ["low", "medium", "high"]]
                    ],
                    "required": ["part", "issue", "severity"],
                    "additionalProperties": false
                ]
            ],
            "steps": [
                "type": "array",
                "description": "Steps in the order they should run. Set every field the tool doesn't use to null.",
                "items": [
                    "type": "object",
                    "properties": [
                        "tool": ["type": "string", "enum": .array(printReviewToolNames.map { .string($0) })],
                        "reason": ["type": "string", "description": "Why, in one sentence."],
                        "target_triangles": ["anyOf": [["type": "integer"], ["type": "null"]], "description": "simplify: 2000 to 20000."],
                        "turn": ["anyOf": [["type": "string", "enum": .array(printReviewTurns.map { .string($0.name) })], ["type": "null"]],
                                 "description": "orient: which side goes up."],
                        "axis": ["anyOf": [["type": "string", "enum": ["longest", "x", "y", "z"]], ["type": "null"]],
                                 "description": "scale_to_size: the side to measure."],
                        "mm": printReviewNullableNumber.setting("description", to: "scale_to_size: that side's size in millimetres."),
                        "cut_mm": printReviewNullableNumber.setting("description", to: "flat_base: millimetres to remove, more than 0 and at most 5."),
                        "shape": ["anyOf": [["type": "string", "enum": ["round", "rectangular"]], ["type": "null"]], "description": "plinth: its shape."],
                        "margin_mm": printReviewNullableNumber.setting("description", to: "plinth: 1 to 30."),
                        "thickness_mm": printReviewNullableNumber.setting("description", to: "plinth: 1 to 20."),
                        "text": ["anyOf": [["type": "string"], ["type": "null"]], "description": "manual: what the seller should do."]
                    ],
                    "required": ["tool", "reason", "target_triangles", "turn", "axis", "mm", "cut_mm", "shape", "margin_mm", "thickness_mm", "text"],
                    "additionalProperties": false
                ]
            ],
            "orientation": ["type": "string", "description": "How to place it on the bed and why."],
            "material_note": ["type": "string", "description": "One or two sentences on material."]
        ],
        "required": ["assessment", "risks", "steps", "orientation", "material_note"],
        "additionalProperties": false
    ],
    strict: true,
    // A short input: wait for the whole call, so Anthropic's strict check covers it.
    eagerInputStreaming: false)

/// A rendered view to send.
struct PrintReviewRender: Equatable, Sendable {
    let title: String
    let image: PreparedImage
}

/// The views sent, in order.
let printReviewAngles: [ListingImageAngle] = [.front, .side, .top, .threeQuarter]

/// Renders the review's views as JPEGs on white, without metadata. A view too complex to draw is left out. Nil when
/// cancelled. Deterministic, like the listing images it shares cameras and lighting with.
func renderPrintReviewViews(_ mesh: STLMesh, size: Int = printReviewRenderPixelSize,
                            rasterBudget: Int = printReviewRenderRasterBudget,
                            isCancelled: () -> Bool = { false }) -> [PrintReviewRender]? {
    var renders: [PrintReviewRender] = []
    for angle in printReviewAngles {
        if isCancelled() { return nil }
        let camera = listingCamera(angle)
        let style = listingRenderStyle(colour: listingNeutralColour, camera: camera)
        guard let rgba = renderMeshRGBA(mesh, size: size, camera: camera, style: style, rasterBudget: rasterBudget,
                                        isCancelled: isCancelled) else { continue }
        guard let image = prepareRenderedImage(rgba: rgba, width: size, height: size,
                                               format: .jpeg(quality: 0.85, background: SIMD3<Float>(1, 1, 1))) else { continue }
        renders.append(PrintReviewRender(title: angle.title, image: image))
    }
    return isCancelled() ? nil : renders
}

/// The user turn's text: the view order, Studio's facts and the context.
func printReviewUserText(viewTitles: [String], factLines: [String], contextLines: [String]) -> String {
    var text = "Review this model for printing.\n\n"
    text += viewTitles.isEmpty ? "Studio couldn’t render pictures of this model.\n\n"
        : "Pictures above, in order: \(viewTitles.joined(separator: ", ")).\n\n"
    text += "Studio’s measurements:\n" + factLines.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
    if contextLines.isEmpty {
        text += "Nothing else is known about the model: the seller hasn’t said its real size or purpose.\n\n"
    } else {
        text += "What Studio knows about the model:\n" + contextLines.map { "- \($0)" }.joined(separator: "\n") + "\n\n"
    }
    text += "Quote Studio’s numbers where you rely on them. Call propose_plan with your review."
    return text
}

/// The first request: images before the text, effort high, the system prompt and tool cached (one breakpoint, on the
/// tool).
func printReviewAnthropicRequest(views: [PrintReviewRender], factLines: [String], contextLines: [String]) -> AnthropicRequest {
    var content: [AnthropicInputBlock] = views.map { .image($0.image.anthropicImage) }
    content.append(.text(printReviewUserText(viewTitles: views.map(\.title), factLines: factLines, contextLines: contextLines)))
    return AnthropicRequest(maxTokens: 32_000, system: [AnthropicSystemBlock(printReviewSystemPrompt, cacheControl: .fiveMinutes)], tools: [printReviewPlanTool],
                            disableParallelToolUse: true, messages: [.user(content)], effort: .high)
}

/// The one follow-up after a reply without a usable plan: the reply goes back unchanged, then an error result for each
/// unusable call, or a reminder when there was no call. Effort medium. Nil after a refusal, or a reply that can't join
/// the conversation (`canJoinHistory`: cut off at max_tokens, the context window or any other early stop).
func printReviewFollowUpRequest(_ previous: AnthropicRequest, reply: AnthropicMessage) -> AnthropicRequest? {
    guard !reply.isRefusal, reply.canJoinHistory, !reply.historyContent.isEmpty else { return nil }
    var request = previous
    request.messages.append(.assistant(reply))
    let uses = reply.toolUses
    var content: [AnthropicInputBlock] = []
    if reply.stopReason == .toolUse, !uses.isEmpty {
        for use in uses {
            content.append(use.inputProblem == nil
                           ? .toolResult(toolUseID: use.id, content: [.text("Not used: call propose_plan only once, with the whole plan.")], isError: true)
                           : use.errorResult)
        }
        content.append(.text("Call propose_plan again with a corrected plan."))
    } else if !uses.isEmpty {
        // Calls in a reply that didn't stop for them can't be answered; Studio can't safely continue.
        return nil
    } else {
        content.append(.text("Please answer by calling propose_plan with your review and plan."))
    }
    request.messages.append(.user(content))
    request.effort = .medium
    return request.problem == nil ? request : nil
}

enum PrintReviewReplyOutcome: Equatable {
    case plan(PrintReviewPlan)
    /// Claude declined; the message to show. Anything it wrote is discarded.
    case refused(String)
    /// No usable `propose_plan` call: worth one follow-up.
    case needsFollowUp
    case failed(String)
}

/// What a reply means for the review.
func printReviewReplyOutcome(_ reply: AnthropicMessage, context: PrintReviewPlanContext) -> PrintReviewReplyOutcome {
    if reply.isRefusal { return .refused(anthropicRefusalMessage(reply.stopDetails)) }
    if reply.stopReason == .maxTokens {
        return .failed("Claude’s reply was cut off before the plan was finished, so nothing was kept.")
    }
    if !reply.canJoinHistory {
        return .failed("Claude’s reply stopped early, before the plan was finished, so nothing was kept.")
    }
    let uses = reply.toolUsesToRun.filter { $0.name == printReviewToolName }
    if uses.count == 1, let use = uses.first, use.inputProblem == nil {
        return .plan(decodePrintReviewPlan(use.input, context: context))
    }
    return .needsFollowUp
}

// MARK: Cost

/// Image tokens at roughly one per 28 × 28 pixel patch.
func printReviewImageTokens(width: Int, height: Int) -> Int {
    guard width > 0, height > 0 else { return 0 }
    return ((width + 27) / 28) * ((height + 27) / 28)
}

/// A rough input-token count: about one token per three characters of text and schema, plus each image at its size.
func printReviewEstimatedInputTokens(_ request: AnthropicRequest, imageSizes: [(width: Int, height: Int)]) -> Int {
    var characters = 0
    for block in request.system { characters += block.text.count }
    for tool in request.tools { characters += tool.json.encodedString.count }
    for message in request.messages {
        for block in message.content {
            switch block {
            case .text(let text, _): characters += text.count
            case .image: break
            case .toolResult, .raw: characters += block.json.encodedString.count
            }
        }
    }
    let imageTokens = imageSizes.reduce(0) { $0 + printReviewImageTokens(width: $1.width, height: $1.height) }
    return characters / 3 + imageTokens + 100
}

/// Output tokens assumed for the estimate: thinking at high effort plus the plan.
let printReviewEstimatedOutputTokens = 3_000...16_000
/// Output tokens assumed for the one follow-up (medium effort).
let printReviewFollowUpOutputTokens = 8_000

/// "about $0.09–$0.80" at list prices. The low end is one answer; the high end is a long answer plus the one follow-up
/// Studio may send, which carries the whole first exchange again.
func printReviewCostRangeText(inputTokens: Int) -> String {
    func estimate(_ input: Int, _ output: Int) -> AnthropicCostEstimate {
        var usage = AnthropicUsage()
        usage.inputTokens = input
        usage.outputTokens = output
        return anthropicEstimatedCost(usage, model: anthropicDefaultModel)
    }
    let low = estimate(inputTokens, printReviewEstimatedOutputTokens.lowerBound)
    let longest = printReviewEstimatedOutputTokens.upperBound
    var high = estimate(inputTokens, longest)
    high.usd += estimate(inputTokens + longest + 200, printReviewFollowUpOutputTokens).usd
    func dollars(_ value: Decimal) -> String {
        var rounded = Decimal(), input = value
        NSDecimalRound(&rounded, &input, 2, .up)
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US")
        return "$" + (formatter.string(from: rounded as NSDecimalNumber) ?? "\(rounded)")
    }
    return "about \(dollars(low.usd))–\(dollars(high.usd))"
}

/// The running cost of the replies so far.
func printReviewCostSoFar(_ replies: [AnthropicMessage]) -> AnthropicCostEstimate {
    var total = AnthropicCostEstimate(usd: 0, complete: true)
    for reply in replies {
        let cost = anthropicEstimatedCost(reply.usage, model: reply.model, requestedModel: reply.requestedModel)
        total.usd += cost.usd
        total.complete = total.complete && cost.complete
    }
    return total
}

/// What Ask Claude sends, said before it is pressed.
func printReviewSendSummary(pictures: Int, hasContext: Bool) -> String {
    let what = pictures > 0 ? "\(pictures == 1 ? "1 picture" : "\(pictures) pictures") of the model and the measurements above" : "the measurements above"
    return "Studio sends Anthropic \(what)\(hasContext ? ", with what Studio knows about it" : ""). It doesn’t send the model file or its name. "
        + "Claude Opus 5.5 suggests a plan made of Studio’s tools; nothing runs until you tick it."
}

/// Activity's detail: counts, cost and status only.
func printReviewActivityDetail(steps: Int?, cost: AnthropicCostEstimate, status: String? = nil) -> String {
    var parts: [String] = []
    if let steps { parts.append(steps == 1 ? "Plan with 1 step" : "Plan with \(steps) steps") }
    if let status { parts.append(status) }
    parts.append(anthropicCostText(cost))
    return parts.joined(separator: " · ")
}
