import SwiftUI
import AppKit

// Prepare new models for printing: after a new STL enters the library, Studio makes one separate "(print-ready)"
// copy with fit-safe changes only — repair when needed, placement on the bed, bridging layers and chamfers under free
// ledges, and internal walls — and keeps the original unchanged. Fillets and wall matching, which take space from
// inside corners and cavities, are added only after the seller confirms nothing on the part has to fit.
//
// Everything here is local: nothing is uploaded or sent to any service, and no menu item or shortcut starts it.
// The pipeline is pure and deterministic (each step walks meshes in index order), so the same model always gives the
// same bytes.

// MARK: - Settings

/// Settings › Design Tools › Prepare new models for printing. Both are plain preferences, on by default.
let printPreparationEnabledDefaultsKey = "prepareNewModelsForPrinting"
let printPreparationInternalWallsDefaultsKey = "prepareNewModelsAddInternalWalls"

struct PrintPreparationSettings: Equatable, Sendable {
    var enabled = true
    var internalWalls = true

    /// A missing (never set) preference reads as on.
    init(enabled: Bool = true, internalWalls: Bool = true) {
        self.enabled = enabled
        self.internalWalls = internalWalls
    }

    init(defaults: UserDefaults) {
        enabled = defaults.object(forKey: printPreparationEnabledDefaultsKey) as? Bool ?? true
        internalWalls = defaults.object(forKey: printPreparationInternalWallsDefaultsKey) as? Bool ?? true
    }
}

let printPreparationInternalWallsCaption = "Thin slots open through the base make Slant’s printer add walls inside the part. In a test the price rose about a quarter, for a stronger part (25 Oct 2026)."
let printPreparationSettingsFooter = "When you import an STL, open one from Finder, save an STL copy of an OBJ or 3MF, or save a replica, Studio makes a separate “(print-ready)” copy: it repairs the mesh if needed, places the part on the bed with the fewest overhangs, adds bridging layers over counterbores and chamfers under free ledges and, if chosen, internal walls. It never changes the original, never uploads or sends anything, and never adds fillets or thickens walls, which can change how parts fit; the copy offers those separately. Personalised models, designed accessories and copies made by Studio’s tools are left alone."

// MARK: - Eligibility

/// How a model entered the library. Every `importModel` caller states one, so whether a model is prepared for printing
/// is decided by where it came from, never guessed from its name.
enum ModelImportOrigin: Equatable, Sendable {
    /// The Import panel, Finder and Dock opens, and drag-in. Prepared.
    case imported
    /// An STL copy of an OBJ or 3MF model (ModelFileOpening.swift). Prepared: it becomes an STL.
    case stlCopyOfOtherFormat
    /// A saved replica (ReplicaGeneratorView.swift). Prepared.
    case replica
    /// A file downloaded from the seller's Slant account. Not prepared: it is a copy of what Slant already prints, and
    /// is linked to that upload.
    case downloadedFromSlant
    /// Personalise from Template output. Not prepared: made to a template's exact sizes.
    case personalised
    /// Design an Accessory's “(designed)” and “(fit test)” saves. Not prepared: already designed for their fit.
    case designedAccessory
    /// A file the API Workbench saved from a response (a developer tool). Not prepared.
    case workbench
    /// A copy made by one of Studio's tools: repaired, simplified, scaled, flat base, plinth, prepared, reinforced,
    /// auto-improved, print-ready, edge-improved. Never prepared, so preparation can never loop.
    case studioToolCopy

    var mayPrepareForPrinting: Bool {
        switch self {
        case .imported, .stlCopyOfOtherFormat, .replica: return true
        case .downloadedFromSlant, .personalised, .designedAccessory, .workbench, .studioToolCopy: return false
        }
    }
}

enum PrintPreparationSkipReason: Equatable, Sendable {
    case settingOff
    case originNotPrepared
    case notSTL
    case noDerivativesLicence
    case alreadyPrepared

    /// Shown on the original only where the seller would expect a copy and didn't get one.
    var message: String? {
        switch self {
        case .noDerivativesLicence:
            return "No print-ready copy was made: this model’s licence appears not to allow changed versions. Check the licence before editing it."
        case .settingOff, .originNotPrepared, .notSTL, .alreadyPrepared:
            return nil
        }
    }
}

/// True when the licence (or copyright) text appears to forbid derivatives, the same text match the licence advisory
/// uses (`modelLicenceAdvisory`).
func modelLicenceForbidsDerivatives(_ details: ModelSourceDetails?) -> Bool {
    guard let details else { return false }
    let text = [details.licence, details.copyright].compactMap { $0 }.joined(separator: " ")
    return modelLicenceConcerns(text).contains(.noDerivatives)
}

/// Whether a model that has just entered the library gets a print-ready copy. Nil means yes. Models failing the mesh
/// check are not refused here: preparation repairs them first, and stops without a copy if repair can't make them sound.
func printPreparationSkipReason(origin: ModelImportOrigin, fileExtension: String, sourceDetails: ModelSourceDetails?,
                                settings: PrintPreparationSettings, alreadyHandled: Bool) -> PrintPreparationSkipReason? {
    guard settings.enabled else { return .settingOff }
    guard origin.mayPrepareForPrinting else { return .originNotPrepared }
    guard fileExtension.lowercased() == "stl" else { return .notSTL }
    guard !alreadyHandled else { return .alreadyPrepared }
    if modelLicenceForbidsDerivatives(sourceDetails) { return .noDerivativesLicence }
    return nil
}

/// The "never twice" rule: a model that already has a preparation outcome, that a print-ready copy was made from
/// (tracked by source ID in the copy's record), or that this session has already queued is never prepared again.
func printPreparationAlreadyHandled(modelID: UUID, library: [LocalModel], queuedThisSession: Set<UUID>) -> Bool {
    if queuedThisSession.contains(modelID) { return true }
    if library.first(where: { $0.id == modelID })?.printPreparationStatus != nil { return true }
    return library.contains { $0.printPreparation?.sourceID == modelID }
}

// MARK: - Step plan

enum PrintPreparationStep: String, Codable, CaseIterable, Sendable {
    case repair, orientation, treatments, internalWalls

    var title: String {
        switch self {
        case .repair: return "Repair"
        case .orientation: return "Placement"
        case .treatments: return "Bridging and chamfers"
        case .internalWalls: return "Internal walls"
        }
    }
}

enum PrintPreparationDecision: Equatable, Sendable {
    case run
    case skip(String)
}

let printPreparationRepairNotNeeded = "Not needed: the mesh check passed."
let printPreparationTreatmentsTooLarge = "Skipped: this model has more than \(meshToolsReinforceTriangleLimit.formatted()) triangles, the limit for bridging and chamfers. Simplify a copy, then use Auto-improve."
let printPreparationWallsOff = "Off in Settings › Design Tools."

/// Whether each step runs, checked against the mesh as it stands when that step is reached (repair can change the
/// triangle count). Steps always run in `PrintPreparationStep.allCases` order: repair, placement, bridging and chamfers,
/// then internal walls, which need the bed face down.
func printPreparationDecision(_ step: PrintPreparationStep, triangles: Int, meshSound: Bool,
                              internalWallsOn: Bool) -> PrintPreparationDecision {
    switch step {
    case .repair:
        return meshSound ? .skip(printPreparationRepairNotNeeded) : .run
    case .orientation:
        return .run
    case .treatments:
        return triangles > meshToolsReinforceTriangleLimit ? .skip(printPreparationTreatmentsTooLarge) : .run
    case .internalWalls:
        guard internalWallsOn else { return .skip(printPreparationWallsOff) }
        return triangles > internalWallsMaximumTriangles ? .skip("Skipped: " + InternalWallsSkipReason.tooManyTriangles.message) : .run
    }
}

func printPreparationPlan(triangles: Int, meshSound: Bool, internalWallsOn: Bool) -> [(step: PrintPreparationStep, decision: PrintPreparationDecision)] {
    PrintPreparationStep.allCases.map {
        ($0, printPreparationDecision($0, triangles: triangles, meshSound: meshSound, internalWallsOn: internalWallsOn))
    }
}

// MARK: - Placement

/// The purpose isn't known at import, so placement uses a neutral ranking unless the model already has a complete
/// saved purpose: `PartIntent()`'s balanced priority with no load direction, which scores only overhangs, bed contact,
/// height and slenderness. A bracket, clip or custom part needs a load direction, which Studio never guesses.
func printPreparationPlacementIntent(saved: PartIntent?) -> (intent: PartIntent, note: String) {
    let neutral = PartIntent(purpose: .enclosure, details: "", load: .unknown)
    let neutralNote = "Neutral placement: the fewest overhangs and a steady bed face."
    guard let saved else {
        return (neutral, "\(neutralNote) The part’s purpose isn’t known, so no load direction was assumed. For a bracket or clip, choose its stress direction in Optimise for purpose on the original.")
    }
    guard saved.isReady else {
        return (neutral, "\(neutralNote) The saved purpose (\(saved.purpose.rawValue.lowercased())) has no stress direction, and Studio never guesses one. Choose it in Optimise for purpose on the original.")
    }
    if saved.effectiveLoad != .unknown {
        return (saved, "Placed for its saved purpose (\(saved.purpose.rawValue.lowercased()), main stress along \(saved.effectiveLoad.rawValue.lowercased())).")
    }
    return (saved, "Placed for its saved purpose (\(saved.purpose.rawValue.lowercased())): the fewest overhangs and a steady bed face.")
}

// MARK: - Records

struct PrintPreparationStepRecord: Codable, Equatable, Sendable {
    var step: PrintPreparationStep
    var applied: Bool
    /// Studio's own figures when applied, or why it was skipped.
    var lines: [String]
}

/// Internal-wall figures, from `InternalWallsResult`.
struct PrintPreparationWalls: Codable, Equatable, Sendable {
    var slots: Int
    var totalLengthMM: Double
    var removedVolumeMM3: Double
    var removedFraction: Double
    var spacingMM: Double
}

/// Read for a record whose source ID is damaged: matches no model.
let printPreparationUnknownSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

/// Saved with a print-ready copy: what was applied and skipped, with Studio's numbers. `sourceID` is the original, so
/// a model is never prepared twice.
struct PrintPreparationRecord: Codable, Equatable, Sendable {
    var sourceID: UUID
    var sourceName: String
    var created: Date
    var steps: [PrintPreparationStepRecord]
    var orientation: PrintOrientation
    var treatments: [AutoImprovementStep]
    var internalWalls: PrintPreparationWalls?
    /// Advice for the seller's review (Auto-improve's notes: holes and bores left alone, and the like).
    var notes: [String]

    init(sourceID: UUID, sourceName: String, created: Date, steps: [PrintPreparationStepRecord], orientation: PrintOrientation,
         treatments: [AutoImprovementStep], internalWalls: PrintPreparationWalls?, notes: [String]) {
        self.sourceID = sourceID; self.sourceName = sourceName; self.created = created; self.steps = steps
        self.orientation = orientation; self.treatments = treatments; self.internalWalls = internalWalls; self.notes = notes
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, sourceName, created, steps, orientation, treatments, internalWalls, notes
    }

    /// Lenient: never throws, because models.json loads as a whole and a damaged record must not stop the library
    /// loading. A damaged field reads as empty; the record itself still marks the copy (it stays Z up).
    init(from decoder: Decoder) {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        sourceID = (try? c?.decode(UUID.self, forKey: .sourceID)) ?? printPreparationUnknownSourceID
        sourceName = (try? c?.decode(String.self, forKey: .sourceName)) ?? ""
        created = (try? c?.decode(Date.self, forKey: .created)) ?? Date(timeIntervalSince1970: 0)
        steps = (try? c?.decode([PrintPreparationStepRecord].self, forKey: .steps)) ?? []
        orientation = (try? c?.decode(PrintOrientation.self, forKey: .orientation)) ?? .zUp
        treatments = (try? c?.decode([AutoImprovementStep].self, forKey: .treatments)) ?? []
        internalWalls = try? c?.decode(PrintPreparationWalls.self, forKey: .internalWalls)
        notes = (try? c?.decode([String].self, forKey: .notes)) ?? []
    }

    var appliedSteps: [PrintPreparationStepRecord] { steps.filter(\.applied) }
    var skippedSteps: [PrintPreparationStepRecord] { steps.filter { !$0.applied } }
    var chamferCount: Int { treatments.filter { $0.settings.kind == .overhang }.count }
    var bridgeCount: Int { treatments.filter { $0.settings.kind == .bridge }.count }
}

/// The outcome saved on the original, so the inspector can say what happened and the model is never prepared twice.
struct PrintPreparationStatus: Codable, Equatable, Sendable {
    enum Outcome: String, Codable, Sendable {
        case madeCopy, nothingToChange, noCopy, stopped
    }
    var outcome: Outcome
    var copyID: UUID?
    var lines: [String]
    var date: Date

    init(outcome: Outcome, copyID: UUID? = nil, lines: [String] = [], date: Date) {
        self.outcome = outcome; self.copyID = copyID; self.lines = lines; self.date = date
    }

    private enum CodingKeys: String, CodingKey { case outcome, copyID, lines, date }

    /// Lenient, like the record: never throws, and an unknown outcome reads as "no copy", which still prevents a
    /// second run.
    init(from decoder: Decoder) {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        outcome = (try? c?.decode(Outcome.self, forKey: .outcome)) ?? .noCopy
        copyID = try? c?.decode(UUID.self, forKey: .copyID)
        lines = (try? c?.decode([String].self, forKey: .lines)) ?? []
        date = (try? c?.decode(Date.self, forKey: .date)) ?? Date(timeIntervalSince1970: 0)
    }
}

let printPreparationNothingToChange = "Already print-ready: nothing to change."
let printPreparationPriceNote = "Slant’s price for this copy may differ: get a new estimate after uploading."

/// One line per applied step, with Studio's numbers.
func printPreparationAppliedLines(_ record: PrintPreparationRecord) -> [String] {
    record.appliedSteps.map { "\($0.step.title): " + $0.lines.joined(separator: " ") }
}

/// One line per step that was skipped or found nothing to do, with the reason.
func printPreparationSkippedLines(_ record: PrintPreparationRecord) -> [String] {
    record.skippedSteps.map { "\($0.step.title): " + $0.lines.joined(separator: " ") }
}

/// The copy's caption: what changed, in counts.
func printPreparationCaption(_ record: PrintPreparationRecord) -> String {
    var parts: [String] = []
    for step in record.appliedSteps {
        switch step.step {
        case .repair: parts.append("repaired")
        case .orientation: parts.append("placed for printing")
        case .treatments:
            if record.bridgeCount > 0 { parts.append(record.bridgeCount == 1 ? "1 bridging layer" : "\(record.bridgeCount) bridging layers") }
            if record.chamferCount > 0 { parts.append(record.chamferCount == 1 ? "1 chamfer" : "\(record.chamferCount) chamfers") }
        case .internalWalls:
            let slots = record.internalWalls?.slots ?? 0
            parts.append(slots == 1 ? "internal walls (1 slot)" : "internal walls (\(slots) slots)")
        }
    }
    guard !parts.isEmpty else { return "Original preserved" }
    let text = parts.joined(separator: ", ")
    return text.prefix(1).uppercased() + text.dropFirst() + " · Original preserved"
}

/// Activity: title, counts and status only (no model name, no geometry).
let printPreparationActivityTitle = "Prepare for printing"
func printPreparationActivityDetail(_ status: PrintPreparationStatus, applied: Int = 0, skipped: Int = 0) -> String {
    switch status.outcome {
    case .madeCopy: return "Print-ready copy saved · \(applied) applied, \(skipped) skipped"
    case .nothingToChange: return "Already print-ready: nothing to change"
    case .noCopy: return "No copy made"
    case .stopped: return "Stopped"
    }
}

// MARK: - Pipeline

enum PrintPreparationError: LocalizedError, Equatable {
    case stopped
    var errorDescription: String? { "Preparing for printing stopped. Nothing was saved." }
}

struct PrintPreparationInput: Sendable {
    var sourceID: UUID
    var sourceName: String
    /// The model's saved purpose (`designEditIntent`), if any.
    var savedIntent: PartIntent?
    var internalWalls: Bool
}

struct PrintPreparationResult: Sendable {
    let record: PrintPreparationRecord
    /// The copy to save, or nil when nothing changed or a check stopped it.
    let mesh: STLMesh?
    let data: Data?
    /// Why no copy was made despite changes (a failed repair or a failed final check).
    let blocked: String?
    var changed: Bool { !record.appliedSteps.isEmpty }
}

/// The automatic preparation, in order: repair (only when the mesh check fails, and only if it makes the mesh sound),
/// placement, fit-safe Auto-improve treatments (bridging and free-ledge chamfers; never wall matching or fillets), then
/// internal walls on the bed face. Each step keeps its own checks; the copy must also pass the mesh check, keep its part
/// count, and still fit the build volume if the original did. Throws only `PrintPreparationError.stopped`.
func preparePrintReadyCopy(_ source: STLMesh, input: PrintPreparationInput, now: Date = Date(),
                           progress: @escaping @Sendable (String) -> Void = { _ in },
                           isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> PrintPreparationResult {
    func check() throws { if isCancelled() { throw PrintPreparationError.stopped } }
    var steps: [PrintPreparationStepRecord] = []
    var orientation = PrintOrientation.zUp
    var treatments: [AutoImprovementStep] = []
    var walls: PrintPreparationWalls?
    var notes: [String] = []
    func record() -> PrintPreparationRecord {
        PrintPreparationRecord(sourceID: input.sourceID, sourceName: input.sourceName, created: now, steps: steps,
                               orientation: orientation, treatments: treatments, internalWalls: walls, notes: notes)
    }
    func blocked(_ reason: String) -> PrintPreparationResult {
        PrintPreparationResult(record: record(), mesh: nil, data: nil, blocked: reason)
    }

    progress("Checking the mesh…")
    guard let before = analyzeMeshHealth(source, isCancelled: isCancelled) else { throw PrintPreparationError.stopped }
    var mesh = source
    var health = before

    // 1. Repair, only when needed.
    switch printPreparationDecision(.repair, triangles: mesh.triangleCount, meshSound: meshHealthIsSound(before), internalWallsOn: input.internalWalls) {
    case .skip(let reason):
        steps.append(PrintPreparationStepRecord(step: .repair, applied: false, lines: [reason]))
    case .run:
        progress("Repairing the mesh…")
        let repaired: MeshRepairResult
        do { repaired = try repairMesh(mesh, isCancelled: isCancelled) }
        catch MeshToolError.cancelled { throw PrintPreparationError.stopped }
        catch {
            try check()
            return blocked("The mesh check found problems and Studio couldn’t repair them (\(error.localizedDescription)) Use Repair and simplify below, or fix the model in your CAD tool.")
        }
        guard repaired.summary.isSound else {
            return blocked("The mesh check found problems that Studio’s repair couldn’t fix. \(meshRepairOutcomeLine(repaired.summary.after)) Use Repair and simplify below to see what’s left.")
        }
        mesh = repaired.mesh
        health = repaired.summary.after
        steps.append(PrintPreparationStepRecord(step: .repair, applied: true, lines: meshRepairSummaryLines(repaired.summary)))
    }
    try check()

    // 2. Placement. Slant prints the part as uploaded, so this decides which way the layers run.
    progress("Choosing the print placement…")
    let placement = printPreparationPlacementIntent(saved: input.savedIntent)
    let assessments = mesh.orientationAssessments()
    let asImported = assessments.first { $0.orientation == .zUp }
    if let best = preferredOrientation(assessments, intent: placement.intent) {
        if best.orientation != .zUp {
            orientation = best.orientation
            var lines = ["\(best.orientation.label).", placement.note]
            if let asImported {
                lines.append(String(format: "Overhangs steeper than 45°: %.0f mm² as imported, %.0f mm² now. Bed contact: %.0f mm².",
                                    asImported.overhangArea, best.overhangArea, best.contactArea))
            }
            steps.append(PrintPreparationStepRecord(step: .orientation, applied: true, lines: lines))
        } else {
            steps.append(PrintPreparationStepRecord(step: .orientation, applied: false, lines: ["Kept as imported: it already sits well on the bed.", placement.note]))
        }
    } else {
        steps.append(PrintPreparationStepRecord(step: .orientation, applied: false, lines: [
            "Kept as imported: no placement with a flat face on the bed fits Slant’s \(Int(slantBuildVolumeMM)) mm build volume.",
        ]))
    }
    // Always from the origin, so the bed face is at Z = 0 for the steps below. A translation alone isn't a change.
    mesh = mesh.oriented(orientation)
    try check()

    // 3. Fit-safe treatments: bridging layers and chamfers under free ledges only.
    switch printPreparationDecision(.treatments, triangles: mesh.triangleCount, meshSound: true, internalWallsOn: input.internalWalls) {
    case .skip(let reason):
        steps.append(PrintPreparationStepRecord(step: .treatments, applied: false, lines: [reason]))
    case .run:
        progress("Looking for ledges and counterbores…")
        do {
            let improved = try AutoImprover.improve(mesh, intent: placement.intent, orientation: .zUp, profile: .fitSafe,
                                                    progress: progress, cancelled: isCancelled)
            notes = improved.manual
            if improved.applied.isEmpty {
                steps.append(PrintPreparationStepRecord(step: .treatments, applied: false,
                                                        lines: ["None needed: no free ledges or counterbores that suit them."] + improved.skipped))
            } else {
                mesh = improved.mesh
                treatments = improved.applied
                steps.append(PrintPreparationStepRecord(step: .treatments, applied: true,
                                                        lines: improved.applied.map { $0.summary + "." } + improved.skipped))
            }
        } catch {
            try check()
            steps.append(PrintPreparationStepRecord(step: .treatments, applied: false, lines: ["Skipped: \(error.localizedDescription)"]))
        }
    }
    try check()

    // 4. Internal walls, cut up from the bed face now that it is down.
    switch printPreparationDecision(.internalWalls, triangles: mesh.triangleCount, meshSound: true, internalWallsOn: input.internalWalls) {
    case .skip(let reason):
        steps.append(PrintPreparationStepRecord(step: .internalWalls, applied: false, lines: [reason]))
    case .run:
        progress("Adding internal walls…")
        do {
            let result = try internalWallsCopy(of: mesh, options: InternalWallsOptions(), isCancelled: isCancelled)
            if let slotted = result.mesh {
                mesh = slotted
                walls = PrintPreparationWalls(slots: result.slotCount, totalLengthMM: result.totalSlotLengthMM,
                                              removedVolumeMM3: result.removedVolumeMM3, removedFraction: result.removedFraction,
                                              spacingMM: Double(result.spacingMM))
                steps.append(PrintPreparationStepRecord(step: .internalWalls, applied: true, lines: [internalWallsSummary(result)]))
            } else {
                steps.append(PrintPreparationStepRecord(step: .internalWalls, applied: false, lines: [internalWallsSummary(result)]))
            }
        } catch InternalWallsError.stopped {
            throw PrintPreparationError.stopped
        } catch {
            try check()
            steps.append(PrintPreparationStepRecord(step: .internalWalls, applied: false, lines: ["Skipped: \(error.localizedDescription)"]))
        }
    }
    try check()

    let finished = record()
    guard finished.steps.contains(where: \.applied) else {
        return PrintPreparationResult(record: finished, mesh: nil, data: nil, blocked: nil)
    }

    // Final checks on the whole copy: sound, never worse than its input, the same number of parts as the (repaired)
    // input, and still within the build volume if the original was.
    progress("Checking the copy…")
    guard let after = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw PrintPreparationError.stopped }
    guard meshHealthIsSound(after), !meshToolMadeWorse(before: before, after: after) else {
        return blocked("The prepared copy didn’t pass Studio’s mesh check, so no copy was made.")
    }
    guard after.shells == health.shells else {
        return blocked("The prepared copy would have a different number of separate parts, so no copy was made.")
    }
    let sourceExtent = meshCoordinateBounds(source.vertices), copyExtent = meshCoordinateBounds(mesh.vertices)
    if (sourceExtent.high - sourceExtent.low).max() <= slantBuildVolumeMM, (copyExtent.high - copyExtent.low).max() > slantBuildVolumeMM {
        return blocked("The prepared copy wouldn’t fit Slant’s \(Int(slantBuildVolumeMM)) mm build volume, so no copy was made.")
    }
    let data = mesh.binarySTL()
    // Read back, as the other copy tools do: the saved bytes must parse to every triangle.
    guard let readBack = try? STLMesh.parse(data), readBack.triangleCount == mesh.triangleCount else {
        return blocked("The prepared copy couldn’t be read back, so no copy was made.")
    }
    return PrintPreparationResult(record: finished, mesh: mesh, data: data, blocked: nil)
}

// MARK: - Temporary folders

/// Folders Studio's copy tools write through on their way into the library. Each is the prefix followed by a UUID and
/// is listed in `personalisationTempFolderPrefixes`, so the launch clean-up removes any a crash leaves behind.
let printReadyTempFolderPrefix = "SlantStudio-PrintReady-"
let autoImproveTempFolderPrefix = "SlantStudio-AutoImprove-"
let preparedCopyTempFolderPrefix = "SlantStudio-Prepared-"
let edgeEditTempFolderPrefix = "SlantStudio-EdgeEdit-"
let reinforceTempFolderPrefix = "SlantStudio-Reinforce-"
let stlCopyTempFolderPrefix = "SlantStudio-STLCopy-"
let scaledCopyTempFolderPrefix = "SlantStudio-ScaledCopy-"

/// A new, uniquely named folder URL (not yet created) in the temporary directory.
func studioTempFolderURL(prefix: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)\(UUID().uuidString)", isDirectory: true)
}

// MARK: - Queue

/// Read from the detached worker, which does not inherit the queue task's cancellation.
final class PrintPreparationCancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

struct PrintPreparationJob: Equatable, Sendable {
    let modelID: UUID
    let url: URL
    let name: String
    let savedIntent: PartIntent?
    /// The store's selection count when the original was imported (and selected): the copy is selected only if it is
    /// unchanged when the copy is saved.
    let selectionGeneration: Int
}

/// One model at a time, off the main actor. The work only reads the library file, so it runs whatever else is
/// happening; the copy is saved only once no sheet, alert or dialog is shown and no request runs (the same rule as
/// Finder opens), so it never switches selection behind a review or while an upload reads the selected model.
/// Stoppable, and stopped on quit.
@MainActor final class PrintPreparationQueue: ObservableObject {
    @Published private(set) var pending: [PrintPreparationJob] = []
    @Published private(set) var current: PrintPreparationJob?
    @Published private(set) var status = ""
    weak var store: StudioStore?
    private var queuedThisSession: Set<UUID> = []
    private var flag: PrintPreparationCancelFlag?
    private var runner: Task<Void, Never>?

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.stopAll() }
        }
    }

    func isPreparing(_ modelID: UUID) -> Bool {
        current?.modelID == modelID || pending.contains { $0.modelID == modelID }
    }

    func alreadyHandled(_ modelID: UUID, library: [LocalModel]) -> Bool {
        printPreparationAlreadyHandled(modelID: modelID, library: library, queuedThisSession: queuedThisSession)
    }

    func enqueue(_ job: PrintPreparationJob) {
        guard queuedThisSession.insert(job.modelID).inserted else { return }
        pending.append(job)
        startNextIfIdle()
    }

    /// The seller's Stop for one model: a queued model is dropped, a running one stops at its next safe point.
    func stop(modelID: UUID) {
        if let index = pending.firstIndex(where: { $0.modelID == modelID }) {
            pending.remove(at: index)
            store?.recordPrintPreparationStatus(PrintPreparationStatus(outcome: .stopped, date: Date()), for: modelID)
        } else if current?.modelID == modelID {
            flag?.set()
        }
    }

    /// Quit, or the setting turned off: nothing more is prepared this session.
    func stopAll() {
        pending.removeAll()
        flag?.set()
    }

    private func startNextIfIdle() {
        guard current == nil, !pending.isEmpty else { return }
        let job = pending.removeFirst()
        let settings = PrintPreparationSettings(defaults: .standard)
        guard settings.enabled else { pending.removeAll(); return }
        current = job
        status = "Preparing for printing…"
        let flag = PrintPreparationCancelFlag()
        self.flag = flag
        runner = Task { [weak self] in
            await self?.run(job, internalWalls: settings.internalWalls, flag: flag)
            guard let self else { return }
            self.current = nil
            self.flag = nil
            self.status = ""
            self.startNextIfIdle()
        }
    }

    private func run(_ job: PrintPreparationJob, internalWalls: Bool, flag: PrintPreparationCancelFlag) async {
        // Removed from the library while it waited: nothing to prepare, and nothing to report.
        guard store?.localModels.contains(where: { $0.id == job.modelID }) == true else { return }
        let input = PrintPreparationInput(sourceID: job.modelID, sourceName: job.name, savedIntent: job.savedIntent,
                                          internalWalls: internalWalls)
        let url = job.url
        let report: @Sendable (String) -> Void = { [weak self] text in
            Task { @MainActor in if !flag.isSet, self?.current?.modelID == job.modelID { self?.status = text } }
        }
        let outcome = await Task.detached(priority: .utility) { () -> Result<(PrintPreparationResult, URL?), Error> in
            Result {
                let source = try STLMesh.read(from: url)
                let result = try preparePrintReadyCopy(source, input: input, progress: report, isCancelled: { flag.isSet })
                guard let data = result.data else { return (result, nil) }
                let folder = studioTempFolderURL(prefix: printReadyTempFolderPrefix)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appendingPathComponent("copy.stl")
                do { try data.write(to: file, options: .atomic) } catch { try? FileManager.default.removeItem(at: folder); throw error }
                return (result, file)
            }
        }.value
        let tempFolder: URL? = { if case .success((_, let file?)) = outcome { return file.deletingLastPathComponent() } else { return nil } }()
        defer { if let tempFolder { try? FileManager.default.removeItem(at: tempFolder) } }
        guard let store else { return }
        if flag.isSet {
            store.finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .stopped, date: Date()), counts: (0, 0))
            return
        }
        switch outcome {
        case .failure(PrintPreparationError.stopped):
            store.finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .stopped, date: Date()), counts: (0, 0))
        case .failure(let error):
            store.finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .noCopy, lines: [
                "Studio couldn’t prepare this model: \(error.localizedDescription)",
            ], date: Date()), counts: (0, 0))
        case .success((let result, let file)):
            if let reason = result.blocked {
                store.finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .noCopy, lines: [reason], date: Date()), counts: (0, 0))
                return
            }
            guard let file else {
                store.finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .nothingToChange,
                                                                                  lines: printPreparationSkippedLines(result.record), date: Date()),
                                             counts: (0, 0))
                return
            }
            // Save only once nothing modal is shown and no request runs.
            status = "Preparing for printing…"
            while !flag.isSet, !store.printPreparationCanSave {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !flag.isSet, PrintPreparationSettings(defaults: .standard).enabled else {
                store.finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .stopped, date: Date()), counts: (0, 0))
                return
            }
            store.savePrintReadyCopy(file, job: job, record: result.record)
        }
    }
}

// MARK: - Store hooks

extension StudioStore {
    /// The same rule as Finder opens (`externalOpenCanImport`).
    var printPreparationCanSave: Bool {
        externalOpenCanImport(storeSheetPresented: isPresentingSheet, appModalUIPresented: appIsPresentingModalUI(),
                              errorShown: error != nil, busy: busy)
    }

    /// Called by `importModel` for every new library model: queues it when its origin, format, licence and the
    /// setting allow, and records a licence skip on the model so the inspector can explain it.
    func considerPrintPreparation(for model: LocalModel, origin: ModelImportOrigin) {
        let reason = printPreparationSkipReason(origin: origin, fileExtension: model.url.pathExtension, sourceDetails: model.sourceDetails,
                                                settings: PrintPreparationSettings(defaults: .standard),
                                                alreadyHandled: printPreparationQueue.alreadyHandled(model.id, library: localModels))
        if let reason {
            if let message = reason.message {
                recordPrintPreparationStatus(PrintPreparationStatus(outcome: .noCopy, lines: [message], date: Date()), for: model.id)
            }
            return
        }
        printPreparationQueue.enqueue(PrintPreparationJob(modelID: model.id, url: model.url, name: model.name,
                                                          savedIntent: designEditIntent(model),
                                                          selectionGeneration: selectionGeneration))
    }

    /// Saves the outcome on the original (metadata only; its file is never touched).
    func recordPrintPreparationStatus(_ status: PrintPreparationStatus, for modelID: UUID) {
        guard let index = localModels.firstIndex(where: { $0.id == modelID }) else { return }
        localModels[index].printPreparationStatus = status
        saveModels()
    }

    func finishPrintPreparation(_ job: PrintPreparationJob, status: PrintPreparationStatus, counts: (applied: Int, skipped: Int)) {
        recordPrintPreparationStatus(status, for: job.modelID)
        activities.insert(Activity(title: printPreparationActivityTitle,
                                   detail: printPreparationActivityDetail(status, applied: counts.applied, skipped: counts.skipped),
                                   success: status.outcome != .noCopy), at: 0)
    }

    /// Adds the checked copy through `importModel`, without switching screens. It is selected only when the seller
    /// still has the original selected and nothing else changed the selection meanwhile.
    func savePrintReadyCopy(_ file: URL, job: PrintPreparationJob, record: PrintPreparationRecord) {
        guard let original = localModels.first(where: { $0.id == job.modelID }) else {
            // Removed while it was being prepared: nothing to attach the copy to.
            activities.insert(Activity(title: printPreparationActivityTitle, detail: "Original removed; no copy saved", success: false), at: 0)
            return
        }
        let named = file.deletingLastPathComponent()
            .appendingPathComponent(exportFileName(modelName: printReadyCopyName(original.name), fileExtension: "stl"))
        do { try FileManager.default.moveItem(at: file, to: named) } catch {
            finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .noCopy, lines: ["The copy couldn’t be saved: \(error.localizedDescription)"], date: Date()), counts: (0, 0))
            return
        }
        let keepSelection = selectedLocalID == original.id && selectionGeneration == job.selectionGeneration
        guard let copyID = importModelReturningID(named, intent: original.partIntent,
                                                  sourceDetails: sourceDetailsForCopy(of: original), printPreparation: record,
                                                  origin: .studioToolCopy, selectsAndShows: false) else {
            finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .noCopy, lines: ["The copy couldn’t be added to your library."], date: Date()), counts: (0, 0))
            return
        }
        finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .madeCopy, copyID: copyID, date: Date()),
                               counts: (record.appliedSteps.count, record.skippedSteps.count))
        if keepSelection, let copy = localModels.first(where: { $0.id == copyID }) { select(copy) }
    }
}
