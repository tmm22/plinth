import Foundation
import simd

// MARK: - Review for Printing with Claude (pure parts)
//
// Studio measures a library model itself first (size, mesh check, wall thickness, flat base, overhangs, build volume)
// and renders four views. Only after the seller presses Ask Claude are those pictures and numbers sent, with the
// context another tool passed in (`PrintReviewContext`). Claude answers through one strict tool, `propose_plan`, made
// only of Studio's own deterministic mesh tools plus "manual" advice. Studio validates every step, ticks none, and runs
// only the ticked ones, in plan order, on an in-memory copy; one library copy is saved, or nothing when a step fails.
// The model's name is never sent. Everything here is pure and deterministic.

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

    var fitsBuildVolume: Bool { sizeMM.max() <= slantBuildVolumeMM }
    var isSound: Bool { meshHealthIsSound(health) }
    var bottomContactMM2: Double { flatBase.currentContactMM2 }
    var wallSummary: WallThicknessSummary { wallThicknessSummary(wall, origin: origin) }
    /// "Studio's checks found no problems" may be said only when this is true.
    var checksFoundNoProblems: Bool {
        isSound && health.shells == 1 && wallSummary.isClear && fitsBuildVolume && flatBase.alreadyFlat
    }
}

/// Measures `mesh` for the review. Nil when cancelled.
func measureForPrintReview(_ mesh: STLMesh, progress: (Double, String) -> Void = { _, _ in },
                           isCancelled: () -> Bool = { false }) -> PrintReviewMeasurements? {
    progress(0, "Checking the mesh…")
    guard let health = analyzeMeshHealth(mesh, isCancelled: isCancelled), !isCancelled() else { return nil }
    progress(0.1, "Measuring wall thickness…")
    guard let wall = analyzeWallThickness(mesh, progress: { progress(0.1 + $0 * 0.75, "Measuring wall thickness…") },
                                          isCancelled: isCancelled), !isCancelled() else { return nil }
    progress(0.85, "Measuring the base and overhangs…")
    let flat = mesh.flatBaseSuggestion()
    let overhang = overhangShare(mesh)
    if isCancelled() { return nil }
    progress(1, "Measured")
    return PrintReviewMeasurements(sizeMM: mesh.maximum - mesh.minimum, origin: mesh.minimum, triangles: mesh.triangleCount,
                                   health: health, wall: wall, flatBase: flat, overhang: overhang)
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
    lines.append("Triangles: \(m.triangles.formatted()).")
    lines.append(printReviewMeshCheckLine(m.health))
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
    if m.checksFoundNoProblems { lines.append("Studio’s checks found no problems.") }
    return lines
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
    if after.checksFoundNoProblems { lines.append("Studio’s checks found no problems.") }
    return lines
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

/// A step Studio can run with its own tools, or advice it never runs.
enum PrintReviewAction: Equatable, Sendable {
    case repair
    case simplify(target: Int)
    case scaleToSize(axis: MeshFitAxis, mm: Double)
    case flatBase(cutMM: Float)
    case plinth(PlinthSettings)
    case manual(String)

    var toolName: String {
        switch self {
        case .repair: return "repair"
        case .simplify: return "simplify"
        case .scaleToSize: return "scale_to_size"
        case .flatBase: return "flat_base"
        case .plinth: return "plinth"
        case .manual: return "manual"
        }
    }

    var isManual: Bool { if case .manual = self { return true }; return false }
    /// Repair and simplify keep the model's placement and edit records; the others change size or base.
    var keepsRecords: Bool {
        switch self {
        case .repair, .simplify: return true
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
}

let printReviewSimplifyRange = 2_000...20_000
let printReviewMaximumSteps = 12
let printReviewMaximumRisks = 12
let printReviewToolNames = ["repair", "simplify", "scale_to_size", "flat_base", "plinth", "manual"]

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
    case .scaleToSize(let axis, let value): return "Scale so the \(printReviewAxisName(axis)) is \(mmValue(value)) mm"
    case .flatBase(let cut): return "Flat base: remove \(mmValue(Double(cut))) mm from the bottom"
    case .plinth(let settings):
        return "\(settings.shape.rawValue) plinth, \(mmValue(Double(settings.marginMM))) mm margin, \(mmValue(Double(settings.thicknessMM))) mm thick"
    case .manual: return "Do this yourself"
    }
}

private func printReviewToolTitle(_ tool: String) -> String {
    switch tool {
    case "repair": return "Repair the mesh"
    case "simplify": return "Simplify"
    case "scale_to_size": return "Scale to size"
    case "flat_base": return "Flat base"
    case "plinth": return "Plinth"
    default: return "Do this yourself"
    }
}

/// Reads Claude's `propose_plan` input. Every step is checked; a step with bad or out-of-range settings is kept with
/// its problem (shown, never runnable), an unknown tool is left out with a note, and only the first of each tool runs.
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
        let (action, ownProblem) = printReviewStepAction(tool: tool, raw: raw, context: context)
        var problem = ownProblem
        if problem == nil, tool != "manual" {
            if let earlier = firstStepForTool[tool] {
                problem = "Already in the plan as step \(earlier)."
            } else if tool == "flat_base" || tool == "plinth", let earlier = baseStep {
                problem = "Step \(earlier) already adds a base. Choose a flat base or a plinth, not both."
            }
        }
        // Only a step that can run claims its tool, so a later valid step can stand in for an invalid one.
        if problem == nil, tool != "manual" {
            firstStepForTool[tool] = number
            if tool == "flat_base" || tool == "plinth" { baseStep = number }
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
        if Float(value) >= context.sizeMM.z / 4 { return (action, "That would remove more than a quarter of the model’s height.") }
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
    case .manual:
        return "Studio doesn’t run this. Do it yourself, then review the result again."
    }
}

/// Advice about the ticked steps before they run, such as a base on a mesh that isn't closed yet.
func printReviewSelectionNotes(_ actions: [PrintReviewAction], measurements m: PrintReviewMeasurements) -> [String] {
    var notes: [String] = []
    guard !m.isSound else { return notes }
    var repaired = false
    for action in actions {
        switch action {
        case .repair: repaired = true
        case .flatBase, .plinth:
            if !repaired {
                notes.append("A flat base or plinth needs a closed mesh. Tick Repair the mesh as well (it runs first when it comes first in the plan), or the run will stop.")
                return notes
            }
        case .simplify:
            if !repaired { notes.append("Simplify works best on a repaired mesh.") }
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

struct PrintReviewRunResult: Sendable {
    let mesh: STLMesh
    /// The binary STL to save.
    let data: Data
    /// What each step did, in order.
    let lines: [String]
    /// False when the result is byte-for-byte the input.
    let changed: Bool
}

enum PrintReviewRunError: LocalizedError, Equatable {
    case cancelled
    case nothingToRun
    case step(number: Int, title: String, message: String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "Stopped. Nothing was saved."
        case .nothingToRun: return "Tick at least one step that Studio can run."
        case .step(let number, let title, let message):
            return "Step \(number) (\(title)) couldn’t be done, so the run stopped and nothing was saved. \(message)"
        }
    }
}

/// Runs the steps in order on an in-memory copy with the wave-1 mesh tools. Deterministic: the same mesh and steps give
/// the same bytes. Manual steps are never run. A failing step throws and nothing is returned.
func runPrintReviewSteps(_ steps: [PrintReviewRunStep], on original: STLMesh, progress: MeshToolProgress = { _, _ in },
                         isCancelled: () -> Bool = { false }) throws -> PrintReviewRunResult {
    let runnable = steps.filter { !$0.action.isManual }
    guard !runnable.isEmpty else { throw PrintReviewRunError.nothingToRun }
    var mesh = original
    var lines: [String] = []
    let share = 1 / Double(runnable.count)
    for (index, step) in runnable.enumerated() {
        if isCancelled() { throw PrintReviewRunError.cancelled }
        let title = printReviewStepTitle(step.action)
        let base = Double(index) * share
        func stepProgress(_ fraction: Double, _ stage: String) { progress(base + fraction * share, "Step \(step.number): \(stage)") }
        progress(base, "Step \(step.number): \(title)…")
        do {
            switch step.action {
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
            case .flatBase(let cut):
                let result = try mesh.flatBaseCopy(cutHeightMM: cut, isCancelled: isCancelled)
                mesh = result.mesh
                lines.append("\(title): \(Int(result.contactAreaMM2.rounded()).formatted()) mm² now flat on the bed.")
            case .plinth(let settings):
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
    progress(1, "Done")
    return PrintReviewRunResult(mesh: mesh, data: data, lines: lines, changed: data != original.binarySTL())
}

/// "Name (print-ready)", without a model file extension.
func printReadyCopyName(_ name: String) -> String {
    var base = meshFitBaseName(name).trimmingCharacters(in: .whitespacesAndNewlines)
    if base.isEmpty { base = "Model" }
    return "\(base) (print-ready)"
}

/// The copy keeps the original's placement and edit records only when every step left size and base alone, as the
/// Repair and simplify card does; otherwise it keeps the part's purpose and source details, as the fit tools do.
func printReadyCopyKeepsRecords(_ actions: [PrintReviewAction]) -> Bool {
    actions.allSatisfy(\.keepsRecords)
}

// MARK: Claude request

let printReviewToolName = "propose_plan"
/// Edge length of each view sent: four views cost about 3,100 input tokens.
let printReviewRenderPixelSize = 768
/// Pixel tests allowed per view (768 px, sampled at 1536 × 1536): about 50 times the sample grid.
let printReviewRenderRasterBudget = 120_000_000

let printReviewSystemPrompt = """
You review 3D models for FDM printing for a small online seller who uses Slant Studio. A print partner prints them \
with settings nobody can see: assume about two perimeters (about 0.9 mm), low infill, 0.2 mm layers and no supports.

You get four orthographic renders of the model as it is placed in its file (Z up; Front looks at the −Y side, Side \
looks at the +X side, Top looks straight down, Three-quarter is from the front right, above) and Studio's own \
measurements. Studio measured the mesh itself: trust its numbers over what the pictures suggest. Units are millimetres.

Guidelines for parts that print well:
- Load-bearing walls 2.0 mm or more, never under 1.0 mm; wall thicknesses in multiples of about 0.45 mm.
- Overhangs no more than 45° from vertical; horizontal holes as teardrops; bridges under 5 mm.
- A flat base on the bed, with about a 0.5 mm chamfer on the bottom edge.
- Fillets where features meet (stress roots); loads along the layers (in X and Y), not across them.
- Pins and posts 3–5 mm or more; embossed detail about 1 mm; printed fits 0.2–0.3 mm clearance per side.
- PETG for heat (for example inside a car); PLA softens at about 55–60 °C.

Answer only by calling propose_plan, once. Studio runs a step only if the seller ticks it, on a copy, on this Mac. \
Steps may use only these tools; set every field a step doesn't use to null:
- repair: joins nearby vertices, removes zero-area, repeated and loose triangles, turns faces the right way and \
closes small holes. Suggest it when Studio's mesh check needs repair.
- simplify (target_triangles, 2000–20000): fewer triangles. Studio's Reinforce and Auto-improve tools accept up to \
20,000. Only when the model has more triangles than the target.
- scale_to_size (axis: longest, x, y or z; mm): scales evenly so that side measures mm. Only when the seller's \
intended size is given, and then use exactly that size. Never guess a real-world size.
- flat_base (cut_mm, more than 0 and at most 5): cuts the bottom level and fills it so the model stands on a flat face. \
Studio's suggested cut is in the measurements.
- plinth (shape: round or rectangular; margin_mm 1–30; thickness_mm 1–20): a base under the whole model, for tall or \
top-heavy figures. Choose a flat base or a plinth, not both.
- manual (text): anything the other tools can't do, which the seller does elsewhere, for example "Use Reinforce in \
Studio to add a gusset under the arm" or "Thicken the sword blade to 3 mm in your CAD app".
Put steps in the order they should run: repair, then simplify, then scale, then the base, then manual advice. Leave \
out steps that aren't needed; an empty list is fine.

How to write:
- You advise; you never change the model.
- Never say a part is strong, approved, safe, guaranteed or won't break, and never give a strength percentage. Say \
"likely weak point", "below the 2 mm guideline" and so on.
- Say Studio's checks found no problems only when its measurements say so.
- risks: specific parts you can see (such as "sword blade" or "left ear"), what may go wrong in printing, and a severity.
- orientation: how to place it on the bed and why, in one or two sentences. These steps can't rotate the model; the \
seller can use Studio's Print orientation tool.
- material_note: one or two sentences on material.
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
                        "tool": ["type": "string", "enum": ["repair", "simplify", "scale_to_size", "flat_base", "plinth", "manual"]],
                        "reason": ["type": "string", "description": "Why, in one sentence."],
                        "target_triangles": ["anyOf": [["type": "integer"], ["type": "null"]], "description": "simplify: 2000 to 20000."],
                        "axis": ["anyOf": [["type": "string", "enum": ["longest", "x", "y", "z"]], ["type": "null"]],
                                 "description": "scale_to_size: the side to measure."],
                        "mm": printReviewNullableNumber.setting("description", to: "scale_to_size: that side's size in millimetres."),
                        "cut_mm": printReviewNullableNumber.setting("description", to: "flat_base: millimetres to remove, more than 0 and at most 5."),
                        "shape": ["anyOf": [["type": "string", "enum": ["round", "rectangular"]], ["type": "null"]], "description": "plinth: its shape."],
                        "margin_mm": printReviewNullableNumber.setting("description", to: "plinth: 1 to 30."),
                        "thickness_mm": printReviewNullableNumber.setting("description", to: "plinth: 1 to 20."),
                        "text": ["anyOf": [["type": "string"], ["type": "null"]], "description": "manual: what the seller should do."]
                    ],
                    "required": ["tool", "reason", "target_triangles", "axis", "mm", "cut_mm", "shape", "margin_mm", "thickness_mm", "text"],
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
    eagerInputStreaming: false,
    cacheControl: .fiveMinutes)

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
    text += "Call propose_plan with your review."
    return text
}

/// The first request: images before the text, effort high, the system prompt and tool cached (one breakpoint, on the
/// tool).
func printReviewAnthropicRequest(views: [PrintReviewRender], factLines: [String], contextLines: [String]) -> AnthropicRequest {
    var content: [AnthropicInputBlock] = views.map { .image($0.image.anthropicImage) }
    content.append(.text(printReviewUserText(viewTitles: views.map(\.title), factLines: factLines, contextLines: contextLines)))
    return AnthropicRequest(maxTokens: 32_000, system: [AnthropicSystemBlock(printReviewSystemPrompt)], tools: [printReviewPlanTool],
                            disableParallelToolUse: true, messages: [.user(content)], effort: .high)
}

/// The one follow-up after a reply without a usable plan: the reply goes back unchanged, then an error result for each
/// unusable call, or a reminder when there was no call. Effort medium. Nil after a refusal or a cut-off reply.
func printReviewFollowUpRequest(_ previous: AnthropicRequest, reply: AnthropicMessage) -> AnthropicRequest? {
    guard !reply.isRefusal, reply.stopReason != .maxTokens, !reply.historyContent.isEmpty else { return nil }
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

/// "about $0.09–$0.36", for a request at list prices (the system prompt and tool counted as a cache write).
func printReviewCostRangeText(inputTokens: Int) -> String {
    func estimate(_ output: Int) -> AnthropicCostEstimate {
        var usage = AnthropicUsage()
        usage.inputTokens = inputTokens
        usage.outputTokens = output
        return anthropicEstimatedCost(usage, model: anthropicDefaultModel)
    }
    let low = estimate(printReviewEstimatedOutputTokens.lowerBound), high = estimate(printReviewEstimatedOutputTokens.upperBound)
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
