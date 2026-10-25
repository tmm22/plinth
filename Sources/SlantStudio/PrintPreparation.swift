import SwiftUI
import AppKit
import simd

// Prepare new models for printing: after a new STL enters the library, Studio makes one separate "(print-ready)"
// copy with fit-safe changes only — repair when needed, placement on the bed (turned square about Z), bridging layers
// and chamfers under free ledges, a 0.4 mm bottom-edge chamfer, and internal walls planned for the part's saved
// purpose — then measures overhangs, thin walls, print advisories and hidden pockets on the copy, and keeps the
// original unchanged. Hidden pockets are reported, never filled automatically: Fill Hidden Pockets is the seller's.
// Fillets and wall matching, which take space from inside corners and cavities, are added only after the seller
// confirms nothing on the part has to fit. The seller can also ask for a copy of any STL with Make Print-Ready Copy.
//
// Everything here is local: nothing is uploaded or sent to any service, and no keyboard shortcut starts it.
// The pipeline is pure and deterministic (each step walks meshes in index order, and a run cut short by a time limit
// is never saved), so the same model always gives the same bytes.

// MARK: - Settings

/// Settings › Design Tools › Prepare new models for printing. All are plain preferences, on by default.
let printPreparationEnabledDefaultsKey = "prepareNewModelsForPrinting"
let printPreparationInternalWallsDefaultsKey = "prepareNewModelsAddInternalWalls"
let printPreparationBottomChamferDefaultsKey = "prepareNewModelsBottomChamfer"
/// Only that the one-time notice was dismissed is stored.
let printPreparationNoticeDismissedDefaultsKey = "prepareNewModelsNoticeDismissed"

struct PrintPreparationSettings: Equatable, Sendable {
    var enabled = true
    var internalWalls = true
    var bottomChamfer = true

    /// A missing (never set) preference reads as on.
    init(enabled: Bool = true, internalWalls: Bool = true, bottomChamfer: Bool = true) {
        self.enabled = enabled
        self.internalWalls = internalWalls
        self.bottomChamfer = bottomChamfer
    }

    init(defaults: UserDefaults) {
        enabled = defaults.object(forKey: printPreparationEnabledDefaultsKey) as? Bool ?? true
        internalWalls = defaults.object(forKey: printPreparationInternalWallsDefaultsKey) as? Bool ?? true
        bottomChamfer = defaults.object(forKey: printPreparationBottomChamferDefaultsKey) as? Bool ?? true
    }
}

let printPreparationInternalWallsCaption = "Rings round holes and slots through pins and thin sections, open through the base, make Slant’s printer add walls there. Slots through thick regions are added only for parts whose saved purpose is functional: in one Slant estimate for a 40 × 40 × 20 mm block (25 Oct 2026), they added about 27% to the price."
let printPreparationBottomChamferCaption = "Keeps the first layer’s spread inside the part’s outline. Hole entries keep their size."
let printPreparationChamferCaution = "Chamfers fill the space under overhanging ledges: check any ledge something hooks or slides under."
let printPreparationSettingsFooter = "When you import an STL, open one from Finder, save an STL copy of an OBJ or 3MF, or save a replica, Studio makes a separate “(print-ready)” copy. In order, it repairs the mesh if needed; places the part on the bed with the fewest overhangs, turned square to the printer’s axes; adds bridging layers over counterbores and chamfers under free ledges; adds a 0.4 mm chamfer round the bottom edge, if chosen; and adds internal walls, if chosen: rings round holes and slots through pins and thin sections, plus slots through thick regions for parts whose saved purpose is functional. It then lists overhangs, thin walls and other print risks on the copy. It never changes the original, never uploads or sends anything, never fills hidden pockets (the copy offers Fill Hidden Pockets), and never adds fillets or thickens walls, which can change how parts fit; the copy offers those separately. \(printPreparationChamferCaution) Personalised models, designed accessories and copies made by Studio’s tools are left alone; use Make Print-Ready Copy in a model’s More menu for any of them."
let printPreparationNoticeText = "Studio now makes a print-ready copy of each new STL. Change this in Settings › Design Tools."

/// The one-time notice shows once an automatic copy is saved, until the seller dismisses it.
func printPreparationNoticeShouldShow(dismissed: Bool, automaticCopySavedThisSession: Bool) -> Bool {
    !dismissed && automaticCopySavedThisSession
}

// MARK: - Eligibility

/// How a model entered the library. Every `importModel` caller states one, so whether a model is prepared for printing
/// automatically is decided by where it came from, never guessed from its name.
enum ModelImportOrigin: Equatable, Sendable {
    /// The Import panel, Finder and Dock opens, and drag-in. Prepared.
    case imported
    /// An STL copy of an OBJ or 3MF model (ModelFileOpening.swift). Prepared: it becomes an STL.
    case stlCopyOfOtherFormat
    /// A saved replica (ReplicaGeneratorView.swift). Prepared, keeping the way up the seller chose.
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
    /// auto-improved, reviewed, print-ready, edge-improved. Never prepared automatically, so preparation can never loop.
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

/// Whether a model that has just entered the library gets an automatic print-ready copy. Nil means yes. Models failing
/// the mesh check are not refused here: preparation repairs them first, and stops without a copy if repair can't make
/// them sound. The 3 mm scale check is applied by the pipeline, which reads the mesh.
func printPreparationSkipReason(origin: ModelImportOrigin, fileExtension: String, sourceDetails: ModelSourceDetails?,
                                settings: PrintPreparationSettings, alreadyHandled: Bool) -> PrintPreparationSkipReason? {
    guard settings.enabled else { return .settingOff }
    guard origin.mayPrepareForPrinting else { return .originNotPrepared }
    guard fileExtension.lowercased() == "stl" else { return .notSTL }
    guard !alreadyHandled else { return .alreadyPrepared }
    if modelLicenceForbidsDerivatives(sourceDetails) { return .noDerivativesLicence }
    return nil
}

/// The automatic trigger's "never twice" rule: a model that already has a preparation outcome, that a print-ready copy
/// was made from (tracked by source ID in the copy's record), or that this session has already queued is never
/// prepared again automatically. Make Print-Ready Copy is not bound by it.
func printPreparationAlreadyHandled(modelID: UUID, library: [LocalModel], queuedThisSession: Set<UUID>) -> Bool {
    if queuedThisSession.contains(modelID) { return true }
    if library.first(where: { $0.id == modelID })?.printPreparationStatus != nil { return true }
    return library.contains { $0.printPreparation?.sourceID == modelID }
}

/// Why Make Print-Ready Copy can't run on this model, or nil. Any STL works, including Studio's own copies and
/// accessories, except a print-ready copy itself. A failing mesh is repaired first, as in the automatic run.
func printPreparationManualBlockedReason(_ model: LocalModel) -> String? {
    guard model.supportsPreview else { return "Make Print-Ready Copy works on STL files. Save an STL copy first, then use it on the copy." }
    guard model.printPreparation == nil else { return "This is already a print-ready copy." }
    return nil
}

/// The placement kept, and why, or nil when Studio may choose one: a replica keeps the way up its seller chose, a
/// prepared or Z-up-locked copy keeps its placement, and a decorative part keeps the way it was made to stand.
func printPreparationKeptPlacementReason(_ model: LocalModel, origin: ModelImportOrigin?) -> String? {
    if origin == .replica || model.keepsPlacement == true { return "Kept as saved: a replica keeps the way up you chose." }
    if model.printRecipe != nil { return "Kept as placed: this copy already has a prepared placement." }
    if model.requiresZUp { return "Kept as placed: this copy has features that depend on its print layers." }
    if designEditIntent(model)?.purpose == .decorative { return "Kept as imported: a decorative part keeps the way it was made to stand." }
    return nil
}

/// The print-ready copy last made from `model` (its status's copy ID), if it is still in the library and is a real
/// print-ready copy. Further copies of it are never matched.
func printReadyCopy(of model: LocalModel, in library: [LocalModel]) -> LocalModel? {
    guard let id = model.printPreparationStatus?.copyID,
          let copy = library.first(where: { $0.id == id }), copy.printPreparation?.sourceID == model.id else { return nil }
    return copy
}

/// The status to save: a later outcome without a copy keeps the copy ID of an earlier one, so Show Copy stays.
func printPreparationStatusKeepingCopy(_ status: PrintPreparationStatus, previous: PrintPreparationStatus?) -> PrintPreparationStatus {
    var kept = status
    if kept.copyID == nil { kept.copyID = previous?.copyID }
    return kept
}

// MARK: - Step plan

/// In the order they run. The bottom chamfer runs before the internal walls, so the walls are planned against the
/// finished surface: every ring and slot keeps its full clearance from the chamfer, and the chamfer never meets a
/// ring's inner island, which it would otherwise take for an outer edge and cut into.
enum PrintPreparationStep: String, Codable, CaseIterable, Sendable {
    case repair, orientation, treatments, bottomChamfer, internalWalls

    var title: String {
        switch self {
        case .repair: return "Repair"
        case .orientation: return "Placement"
        case .treatments: return "Bridging and chamfers"
        case .bottomChamfer: return "Bottom-edge chamfer"
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
let printPreparationChamferOff = printPreparationWallsOff
let printPreparationWallsDecorative = "Skipped for a decorative part: internal walls add filament and cost, and a display piece carries no load."
let printPreparationScaleFirst = "This model is under 3 mm across, so it may have been exported in another unit. Scale it first, then use Make Print-Ready Copy."

/// Whether each step runs, checked against the mesh as it stands when that step is reached (repair can change the
/// triangle count). Steps always run in `PrintPreparationStep.allCases` order: repair, placement, bridging and chamfers,
/// the bottom-edge chamfer, then internal walls; the last two need the bed face down.
func printPreparationDecision(_ step: PrintPreparationStep, triangles: Int, meshSound: Bool, internalWallsOn: Bool,
                              decorative: Bool = false, keptPlacement: String? = nil,
                              bottomChamferOn: Bool = true) -> PrintPreparationDecision {
    switch step {
    case .repair:
        return meshSound ? .skip(printPreparationRepairNotNeeded) : .run
    case .orientation:
        return keptPlacement.map { .skip($0) } ?? .run
    case .treatments:
        return triangles > meshToolsReinforceTriangleLimit ? .skip(printPreparationTreatmentsTooLarge) : .run
    case .bottomChamfer:
        guard bottomChamferOn else { return .skip(printPreparationChamferOff) }
        return triangles > bottomChamferMaximumTriangles ? .skip("Skipped: " + BottomChamferSkipReason.tooManyTriangles.message) : .run
    case .internalWalls:
        guard internalWallsOn else { return .skip(printPreparationWallsOff) }
        guard !decorative else { return .skip(printPreparationWallsDecorative) }
        return triangles > internalWallsMaximumTriangles ? .skip("Skipped: " + InternalWallsSkipReason.tooManyTriangles.message) : .run
    }
}

func printPreparationPlan(triangles: Int, meshSound: Bool, internalWallsOn: Bool, decorative: Bool = false,
                          keptPlacement: String? = nil,
                          bottomChamferOn: Bool = true) -> [(step: PrintPreparationStep, decision: PrintPreparationDecision)] {
    PrintPreparationStep.allCases.map {
        ($0, printPreparationDecision($0, triangles: triangles, meshSound: meshSound, internalWallsOn: internalWallsOn,
                                      decorative: decorative, keptPlacement: keptPlacement, bottomChamferOn: bottomChamferOn))
    }
}

// MARK: - Placement

let printPreparationSetPurposeNote = "For a bracket or clip, set its purpose and stress direction in Optimise for purpose, then use Make Print-Ready Copy."

/// The purpose isn't known at import, so placement uses a neutral ranking unless the model already has a complete
/// saved purpose: `PartIntent()`'s balanced priority with no load direction, which scores only overhangs, bed contact,
/// height and slenderness. A bracket, clip or custom part needs a load direction, which Studio never guesses.
func printPreparationPlacementIntent(saved: PartIntent?) -> (intent: PartIntent, note: String) {
    let neutral = PartIntent(purpose: .enclosure, details: "", load: .unknown)
    let neutralNote = "Neutral placement: the fewest overhangs and a steady bed face."
    guard let saved else {
        return (neutral, "\(neutralNote) The part’s purpose isn’t known, so no load direction was assumed. \(printPreparationSetPurposeNote)")
    }
    guard saved.isReady else {
        return (neutral, "\(neutralNote) The saved purpose (\(saved.purpose.rawValue.lowercased())) has no stress direction, and Studio never guesses one. Set it in Optimise for purpose, then use Make Print-Ready Copy.")
    }
    if saved.effectiveLoad != .unknown {
        return (saved, "Placed for its saved purpose (\(saved.purpose.rawValue.lowercased()), main stress along \(saved.effectiveLoad.rawValue.lowercased())).")
    }
    return (saved, "Placed for its saved purpose (\(saved.purpose.rawValue.lowercased())): the fewest overhangs and a steady bed face.")
}

// MARK: - Thin walls

/// Samples for the copy's thin-wall advisory: modest, so preparation stays fast.
let printPreparationWallThicknessSamples = 4_000

/// Separate areas of readings under `belowMM`: spots within `radiusMM` of an area's first spot join it, in sample order.
func printPreparationThinAreaCount(_ report: WallThicknessReport, belowMM: Float = 1, radiusMM: Float = smallFeatureClusterRadiusMM) -> Int {
    var centres: [SIMD3<Float>] = []
    for spot in report.thinSpots where spot.thicknessMM < belowMM {
        if centres.contains(where: { simd_distance($0, spot.point) <= radiusMM }) { continue }
        centres.append(spot.point)
    }
    return centres.count
}

func printPreparationThinAreasLine(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return "\(count == 1 ? "1 area" : "\(count) areas") thinner than 1 mm: Slant’s 1 mm walls may not print \(count == 1 ? "it" : "them") well."
}

// MARK: - Records

struct PrintPreparationStepRecord: Codable, Equatable, Sendable {
    var step: PrintPreparationStep
    var applied: Bool
    /// Studio's own figures when applied, or why it was skipped.
    var lines: [String]
}

/// Internal-wall figures, from `InternalWallsResult`. `slots` counts every slot (pin, thin-section and thick-region);
/// rings are counted apart.
struct PrintPreparationWalls: Codable, Equatable, Sendable {
    var slots: Int
    var totalLengthMM: Double
    var removedVolumeMM3: Double
    var removedFraction: Double
    var spacingMM: Double
    var holeRings = 0
    var pinSlots = 0
    var thinSlots = 0
    var bulkSlots = 0
    /// Studio's estimate of the extra filament, as a share of the part's (`InternalWallsResult`); nil when not measured.
    var estimatedExtraMaterialFraction: Double?
    var addedSurfaceAreaMM2: Double?

    init(slots: Int, totalLengthMM: Double, removedVolumeMM3: Double, removedFraction: Double, spacingMM: Double,
         holeRings: Int = 0, pinSlots: Int = 0, thinSlots: Int = 0, bulkSlots: Int? = nil,
         estimatedExtraMaterialFraction: Double? = nil, addedSurfaceAreaMM2: Double? = nil) {
        self.slots = slots; self.totalLengthMM = totalLengthMM; self.removedVolumeMM3 = removedVolumeMM3
        self.removedFraction = removedFraction; self.spacingMM = spacingMM
        self.holeRings = holeRings; self.pinSlots = pinSlots; self.thinSlots = thinSlots
        self.bulkSlots = bulkSlots ?? max(0, slots - pinSlots - thinSlots)
        self.estimatedExtraMaterialFraction = estimatedExtraMaterialFraction; self.addedSurfaceAreaMM2 = addedSurfaceAreaMM2
    }

    init(_ result: InternalWallsResult) {
        self.init(slots: result.slotCount, totalLengthMM: result.totalSlotLengthMM, removedVolumeMM3: result.removedVolumeMM3,
                  removedFraction: result.removedFraction, spacingMM: Double(result.spacingMM),
                  holeRings: result.count(of: .holeRing), pinSlots: result.count(of: .pinSlot),
                  thinSlots: result.count(of: .thinSlot), bulkSlots: result.count(of: .bulkSlot),
                  estimatedExtraMaterialFraction: result.estimatedExtraMaterialFraction,
                  addedSurfaceAreaMM2: result.addedSurfaceAreaMM2)
    }

    private enum CodingKeys: String, CodingKey {
        case slots, totalLengthMM, removedVolumeMM3, removedFraction, spacingMM, holeRings, pinSlots, thinSlots, bulkSlots
        case estimatedExtraMaterialFraction, addedSurfaceAreaMM2
    }

    /// Records from before round 11 have only slots in thick regions, so their slots read as those.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        slots = try c.decode(Int.self, forKey: .slots)
        totalLengthMM = (try? c.decode(Double.self, forKey: .totalLengthMM)) ?? 0
        removedVolumeMM3 = (try? c.decode(Double.self, forKey: .removedVolumeMM3)) ?? 0
        removedFraction = (try? c.decode(Double.self, forKey: .removedFraction)) ?? 0
        spacingMM = (try? c.decode(Double.self, forKey: .spacingMM)) ?? 0
        holeRings = max(0, (try? c.decode(Int.self, forKey: .holeRings)) ?? 0)
        pinSlots = max(0, (try? c.decode(Int.self, forKey: .pinSlots)) ?? 0)
        thinSlots = max(0, (try? c.decode(Int.self, forKey: .thinSlots)) ?? 0)
        bulkSlots = max(0, (try? c.decode(Int.self, forKey: .bulkSlots)) ?? max(0, slots - pinSlots - thinSlots))
        estimatedExtraMaterialFraction = (try? c.decode(Double.self, forKey: .estimatedExtraMaterialFraction)).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        addedSurfaceAreaMM2 = (try? c.decode(Double.self, forKey: .addedSurfaceAreaMM2)).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
    }

    /// "1 hole ring, 2 pin slots": the kinds made, in planning order.
    var kindsList: [String] {
        [(InternalWallsKind.holeRing, holeRings), (.pinSlot, pinSlots), (.thinSlot, thinSlots), (.bulkSlot, bulkSlots)]
            .filter { $0.1 > 0 }.map { $0.0.label($0.1) }
    }
}

/// The bottom-edge chamfer's figures, from `BottomChamferResult`.
struct PrintPreparationChamfer: Codable, Equatable, Sendable {
    var sizeMM: Double
    var outlineLengthMM: Double
    var removedVolumeMM3: Double
    var keptHoleEntries: Int
}

/// Overhang shares of the copy's outer shape as placed (before its internal walls, whose slot ceilings bridge):
/// steeper than Studio's 45° (`printPreparationOverhangReportDegrees`) and past Slant's 50°.
struct PrintPreparationOverhangs: Codable, Equatable, Sendable {
    var share45: Double
    var share50: Double
}

/// One print advisory (`PrintAdvisory`): its kind's raw value and its line.
struct PrintPreparationAdvisoryRecord: Codable, Equatable, Sendable {
    var kind: String
    var message: String
}

/// Saved advisories are capped at `printAdvisoryMaximumCount`, each line at this many characters.
let printPreparationAdvisoryMaximumLength = 400

/// Hidden pockets on the finished copy (`HiddenPocketsReport`). The pipeline never fills them; a count of zero means
/// the copy was checked and has none.
struct PrintPreparationPockets: Codable, Equatable, Sendable {
    var count: Int
    /// Shells inside the pockets, which a fill removes too.
    var shellsInside: Int
    var addedVolumeMM3: Double
    /// The bodies a fill would remove, each one Slant bills.
    var removableBodies: Int { count + shellsInside }
}

/// Read for a record whose source ID is damaged: matches no model.
let printPreparationUnknownSourceID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")!

/// Saved with a print-ready copy: what was applied and skipped, with Studio's numbers. `sourceID` is the original, so
/// a model is never prepared twice automatically.
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
    /// Separate areas under 1 mm thick on the copy (advisory; nil when not measured).
    var thinAreasUnder1MM: Int?
    /// Round 11, all nil or empty on older records.
    var bottomChamfer: PrintPreparationChamfer?
    var overhangs: PrintPreparationOverhangs?
    /// At most `printAdvisoryMaximumCount`, in `PrintAdvisoryKind` order.
    var advisories: [PrintPreparationAdvisoryRecord]
    var hiddenPockets: PrintPreparationPockets?

    init(sourceID: UUID, sourceName: String, created: Date, steps: [PrintPreparationStepRecord], orientation: PrintOrientation,
         treatments: [AutoImprovementStep], internalWalls: PrintPreparationWalls?, notes: [String], thinAreasUnder1MM: Int? = nil,
         bottomChamfer: PrintPreparationChamfer? = nil, overhangs: PrintPreparationOverhangs? = nil,
         advisories: [PrintPreparationAdvisoryRecord] = [], hiddenPockets: PrintPreparationPockets? = nil) {
        self.sourceID = sourceID; self.sourceName = sourceName; self.created = created; self.steps = steps
        self.orientation = orientation; self.treatments = treatments; self.internalWalls = internalWalls; self.notes = notes
        self.thinAreasUnder1MM = thinAreasUnder1MM
        self.bottomChamfer = bottomChamfer; self.overhangs = overhangs
        self.advisories = printPreparationCappedAdvisories(advisories); self.hiddenPockets = hiddenPockets
    }

    private enum CodingKeys: String, CodingKey {
        case sourceID, sourceName, created, steps, orientation, treatments, internalWalls, notes, thinAreasUnder1MM
        case bottomChamfer, overhangs, advisories, hiddenPockets
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
        thinAreasUnder1MM = try? c?.decode(Int.self, forKey: .thinAreasUnder1MM)
        bottomChamfer = try? c?.decode(PrintPreparationChamfer.self, forKey: .bottomChamfer)
        overhangs = try? c?.decode(PrintPreparationOverhangs.self, forKey: .overhangs)
        advisories = printPreparationCappedAdvisories((try? c?.decode([PrintPreparationAdvisoryRecord].self, forKey: .advisories)) ?? [])
        hiddenPockets = (try? c?.decode(PrintPreparationPockets.self, forKey: .hiddenPockets)).flatMap {
            $0.count >= 0 && $0.shellsInside >= 0 ? $0 : nil
        }
    }

    var appliedSteps: [PrintPreparationStepRecord] { steps.filter(\.applied) }
    var skippedSteps: [PrintPreparationStepRecord] { steps.filter { !$0.applied } }
    var chamferCount: Int { treatments.filter { $0.settings.kind == .overhang }.count }
    var bridgeCount: Int { treatments.filter { $0.settings.kind == .bridge }.count }
    /// The turn about Z the placement added, in degrees counter-clockwise from above; 0 when not turned.
    var zTurnDegrees: Float { orientation.zTurnDegrees }
}

/// At most `printAdvisoryMaximumCount` advisories, each line at most `printPreparationAdvisoryMaximumLength`
/// characters, empty lines dropped.
func printPreparationCappedAdvisories(_ advisories: [PrintPreparationAdvisoryRecord]) -> [PrintPreparationAdvisoryRecord] {
    Array(advisories.lazy
        .filter { !$0.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        .map { PrintPreparationAdvisoryRecord(kind: String($0.kind.prefix(40)), message: String($0.message.prefix(printPreparationAdvisoryMaximumLength))) }
        .prefix(printAdvisoryMaximumCount))
}

/// The outcome saved on the original, so the inspector can say what happened and the model is never prepared twice
/// automatically.
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
    /// second automatic run.
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
let printPreparationWallsPriceNote = "Internal walls use more filament, so Slant’s price is likely higher: about 27% more in one Slant estimate for a 40 × 40 × 20 mm block (25 Oct 2026). Get an estimate for both before choosing."
let printPreparationTookTooLong = "Preparation stopped: it took too long, so no copy was made. Try Make Print-Ready Copy again."

/// "about 4%", "under 1%": a share as a whole percentage.
func printPreparationPercentText(_ fraction: Double) -> String {
    let percent = (fraction * 100).rounded()
    return percent < 1 ? "under 1%" : "about \(Int(percent))%"
}

/// The price line for a copy: with internal walls, Studio's own estimate of the extra filament beside Slant's dated
/// figure, or the older dated note when there is no estimate; otherwise the general note.
func printPreparationPriceLine(_ record: PrintPreparationRecord) -> String {
    guard let walls = record.internalWalls else { return printPreparationPriceNote }
    guard let fraction = walls.estimatedExtraMaterialFraction, fraction > 0 else { return printPreparationWallsPriceNote }
    return "Studio estimates \(printPreparationPercentText(fraction)) more filament for the internal walls; Slant’s price is likely higher. In one Slant estimate for a 40 × 40 × 20 mm block (25 Oct 2026), slots through thick regions added about 27% to the price. Get an estimate for both before choosing."
}

/// The copy's "steeper than 45°" share leaves out faces at 45° itself: the bottom-edge chamfer and the chamfers under
/// ledges are built at exactly 45°, and rounding can tip their normals a hair past it.
let printPreparationOverhangReportDegrees = 45.1

/// The copy's overhangs as placed: Studio's 45° measure and Slant's 50° limit.
func printPreparationOverhangLine(_ overhangs: PrintPreparationOverhangs) -> String {
    if overhangs.share45 <= 0 { return "Overhangs: none steeper than 45° as placed." }
    let past50 = overhangs.share50 <= 0 ? "none past Slant’s 50° limit" : "\(printPreparationPercentText(overhangs.share50)) past Slant’s 50° limit"
    return "Overhangs: \(printPreparationPercentText(overhangs.share45)) of the surface steeper than 45° as placed; \(past50)."
}

/// "2 hidden pockets: Slant would bill each as a separate body (about $0.78 extra, test on 25 Oct 2026).", or nil
/// when there are none. The cost is `removableBodies` × `hiddenPocketBodyChargeUSD`, an estimate from Slant's price on
/// `hiddenPocketBodyChargeDate`. Never says filling makes a part stronger.
func hiddenPocketsLine(count: Int, shellsInside: Int) -> String? {
    guard count > 0 else { return nil }
    let pockets = count == 1 ? "1 hidden pocket" : "\(count.formatted()) hidden pockets"
    let inside = shellsInside > 0 ? (shellsInside == 1 ? ", with 1 loose part inside" : ", with \(shellsInside.formatted()) loose parts inside") : ""
    let each = count == 1 && shellsInside == 0 ? "it" : "each"
    let cost = hiddenPocketsCostText(Decimal(count + shellsInside) * hiddenPocketBodyChargeUSD)
    return "\(pockets)\(inside): Slant would bill \(each) as a separate body (about \(cost) extra, test on \(hiddenPocketBodyChargeDate))."
}

func hiddenPocketsLine(_ report: HiddenPocketsReport) -> String? {
    hiddenPocketsLine(count: report.count, shellsInside: report.shellsInsidePockets)
}

func hiddenPocketsLine(_ pockets: PrintPreparationPockets) -> String? {
    hiddenPocketsLine(count: pockets.count, shellsInside: pockets.shellsInside)
}

/// The copy's panel lists up to this many advisories inline; more go in a collapsed "Print checks" list.
let printPreparationAdvisoriesShownInline = 3

/// The copy's advisories to show: at most `printAdvisoryMaximumCount` lines.
func printPreparationAdvisoryLines(_ record: PrintPreparationRecord) -> [String] {
    record.advisories.map(\.message)
}

/// An applied placement step's lines already cover a small bed contact and a tipping risk on the placed part, so the
/// advisories for the same kinds are left out of the record (pass nil to keep them); the others are kept, at most
/// `printAdvisoryMaximumCount`.
func printPreparationAdvisoryRecords(_ advisories: [PrintAdvisory], placement: PrintPlacementChoice?) -> [PrintPreparationAdvisoryRecord] {
    printPreparationCappedAdvisories(advisories.compactMap { advisory in
        if advisory.kind == .smallBedContact, placement?.smallBedContact == true { return nil }
        if advisory.kind == .tipping, placement?.tippingProne == true { return nil }
        return PrintPreparationAdvisoryRecord(kind: advisory.kind.rawValue, message: advisory.message)
    })
}

/// Cautions for the copy's panel: the chamfer caution when chamfers were added, and thin areas.
func printPreparationCautions(_ record: PrintPreparationRecord) -> [String] {
    var lines: [String] = []
    if record.chamferCount > 0 { lines.append(printPreparationChamferCaution) }
    if let thin = record.thinAreasUnder1MM, let line = printPreparationThinAreasLine(thin) { lines.append(line) }
    return lines
}

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
        case .orientation:
            parts.append(record.zTurnDegrees == 0 ? "placed for printing"
                         : "placed for printing (turned \(printPlacementTurnDegreesLabel(record.zTurnDegrees)) about Z)")
        case .treatments:
            if record.bridgeCount > 0 { parts.append(record.bridgeCount == 1 ? "1 bridging layer" : "\(record.bridgeCount) bridging layers") }
            if record.chamferCount > 0 { parts.append(record.chamferCount == 1 ? "1 chamfer" : "\(record.chamferCount) chamfers") }
        case .bottomChamfer:
            parts.append("bottom-edge chamfer")
        case .internalWalls:
            let kinds = record.internalWalls?.kindsList ?? []
            parts.append(kinds.isEmpty ? "internal walls" : "internal walls (\(kinds.joined(separator: ", ")))")
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
    /// A step hit a time limit; its result could differ from a full run, so nothing is saved.
    case tookTooLong
    var errorDescription: String? {
        switch self {
        case .stopped: return "Preparing for printing stopped. Nothing was saved."
        case .tookTooLong: return printPreparationTookTooLong
        }
    }
}

struct PrintPreparationInput: Sendable {
    var sourceID: UUID
    var sourceName: String
    /// The model's saved purpose (`designEditIntent`), if any. Only this decides the internal-walls plan: never the
    /// neutral placement intent, whose purpose is a stand-in.
    var savedIntent: PartIntent?
    var internalWalls: Bool
    /// The automatic trigger (true) also stops at the 3 mm scale check; Make Print-Ready Copy doesn't.
    var automatic = true
    /// Why the placement is kept (`printPreparationKeptPlacementReason`), or nil when Studio chooses one.
    var keptPlacement: String? = nil
    /// Settings › Design Tools › Add a 0.4 mm bottom-edge chamfer.
    var bottomChamfer = true
    var decorative: Bool { savedIntent?.purpose == .decorative }
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

/// The preparation, in order: repair (only when the mesh check fails, and only if it makes the mesh sound),
/// placement (turned about Z to line up its faces), fit-safe Auto-improve treatments (bridging and free-ledge chamfers;
/// never wall matching or fillets), the 0.4 mm bottom-edge chamfer (hole entries keep their size), then internal walls
/// planned for the saved purpose, cut up through the bed face. Each step keeps its own checks; the copy must also pass
/// the mesh check, keep its part count, and still fit the build volume if the original did. Overhangs, thin areas,
/// print advisories and hidden pockets are then measured on the result; pockets are reported, never filled.
/// Throws `PrintPreparationError.stopped`, or `.tookTooLong` when a step hit its time limit.
func preparePrintReadyCopy(_ source: STLMesh, input: PrintPreparationInput, now: Date = Date(),
                           progress: @escaping @Sendable (String) -> Void = { _ in },
                           isCancelled: @escaping @Sendable () -> Bool = { false }) throws -> PrintPreparationResult {
    func check() throws { if isCancelled() { throw PrintPreparationError.stopped } }
    var steps: [PrintPreparationStepRecord] = []
    var orientation = PrintOrientation.zUp
    var treatments: [AutoImprovementStep] = []
    var walls: PrintPreparationWalls?
    var chamfer: PrintPreparationChamfer?
    var notes: [String] = []
    var thinAreas: Int?
    var overhangs: PrintPreparationOverhangs?
    var advisories: [PrintPreparationAdvisoryRecord] = []
    var pockets: PrintPreparationPockets?
    func record() -> PrintPreparationRecord {
        PrintPreparationRecord(sourceID: input.sourceID, sourceName: input.sourceName, created: now, steps: steps,
                               orientation: orientation, treatments: treatments, internalWalls: walls, notes: notes,
                               thinAreasUnder1MM: thinAreas, bottomChamfer: chamfer, overhangs: overhangs,
                               advisories: advisories, hiddenPockets: pockets)
    }
    func blocked(_ reason: String) -> PrintPreparationResult {
        PrintPreparationResult(record: record(), mesh: nil, data: nil, blocked: reason)
    }

    // The automatic run waits for the seller where the 3 mm scale check suggests another unit.
    if input.automatic {
        let bounds = meshCoordinateBounds(source.vertices)
        if scaleWarning(extentMM: bounds.high - bounds.low) != nil { return blocked(printPreparationScaleFirst) }
    }

    progress("Checking the mesh…")
    guard let before = analyzeMeshHealth(source, isCancelled: isCancelled) else { throw PrintPreparationError.stopped }
    var mesh = source
    var health = before
    func decision(_ step: PrintPreparationStep, sound: Bool = true) -> PrintPreparationDecision {
        printPreparationDecision(step, triangles: mesh.triangleCount, meshSound: sound, internalWallsOn: input.internalWalls,
                                 decorative: input.decorative, keptPlacement: input.keptPlacement,
                                 bottomChamferOn: input.bottomChamfer)
    }

    // 1. Repair, only when needed.
    switch decision(.repair, sound: meshHealthIsSound(before)) {
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

    // 2. Placement. Slant prints the part as uploaded, so this decides which way the layers run. The preferred
    //    placement is turned about Z so faces drawn at an angle line up with the printer's axes.
    let placement = printPreparationPlacementIntent(saved: input.savedIntent)
    var choice: PrintPlacementChoice?
    switch decision(.orientation) {
    case .skip(let reason):
        steps.append(PrintPreparationStepRecord(step: .orientation, applied: false, lines: [reason]))
    case .run:
        progress("Choosing the print placement…")
        let assessments = mesh.orientationAssessments()
        try check()
        let asImported = assessments.first { $0.orientation == .zUp }
        if let chosen = printPlacement(assessments, in: mesh, intent: placement.intent, allowTurn: true) {
            choice = chosen
            if chosen.orientation != .zUp {
                orientation = chosen.orientation
                var lines = ["\(chosen.orientation.label).", placement.note]
                if let asImported {
                    lines.append(String(format: "Overhangs steeper than 45°: %.0f mm² as imported, %.0f mm² now. Bed contact: %.0f mm².",
                                        asImported.overhangArea, chosen.assessment.overhangArea, chosen.assessment.contactArea))
                }
                steps.append(PrintPreparationStepRecord(step: .orientation, applied: true, lines: lines + chosen.lines))
            } else {
                steps.append(PrintPreparationStepRecord(step: .orientation, applied: false,
                                                        lines: ["Kept as imported: it already sits well on the bed.", placement.note] + chosen.lines))
            }
        } else {
            steps.append(PrintPreparationStepRecord(step: .orientation, applied: false, lines: [
                "Kept as imported: no placement with a flat face on the bed fits Slant’s \(Int(slantBuildVolumeMM)) mm build volume.",
            ]))
        }
    }
    // Always from the origin, so the bed face is at Z = 0 for the steps below. A translation alone isn't a change.
    mesh = mesh.oriented(orientation)
    try check()

    // 3. Fit-safe treatments: bridging layers and chamfers under free ledges only.
    switch decision(.treatments) {
    case .skip(let reason):
        steps.append(PrintPreparationStepRecord(step: .treatments, applied: false, lines: [reason]))
    case .run:
        progress("Looking for ledges and counterbores…")
        do {
            let improved = try AutoImprover.improve(mesh, intent: placement.intent, orientation: .zUp, profile: .fitSafe,
                                                    progress: progress, cancelled: isCancelled)
            try check()
            // A run cut short by a time limit could differ from a full one, so the whole preparation stops.
            guard !improved.timedOut else { throw PrintPreparationError.tookTooLong }
            notes = improved.manual
            if improved.applied.isEmpty {
                steps.append(PrintPreparationStepRecord(step: .treatments, applied: false,
                                                        lines: ["None needed: no free ledges or counterbores that suit them."] + improved.skipped))
            } else if let kept = soundTreatedMesh(improved.mesh, shells: health.shells, isCancelled: isCancelled) {
                mesh = kept.mesh
                treatments = improved.applied
                steps.append(PrintPreparationStepRecord(step: .treatments, applied: true,
                                                        lines: improved.applied.map { $0.summary + "." } + kept.lines + improved.skipped))
            } else {
                try check()
                // A treatment that leaves the mesh unsound, or whose repair changes the number of parts, is dropped: the
                // part continues as it was before the treatments.
                steps.append(PrintPreparationStepRecord(step: .treatments, applied: false, lines: [printPreparationTreatmentsDropped]))
            }
        } catch let error as PrintPreparationError {
            throw error
        } catch {
            try check()
            steps.append(PrintPreparationStepRecord(step: .treatments, applied: false, lines: ["Skipped: \(error.localizedDescription)"]))
        }
    }
    try check()

    // 4. The 0.4 mm bottom-edge chamfer, round the outer edge of the bed face only: hole entries keep their size, so a
    //    bore that fits a pin or screw is unchanged at the bed. It runs before the internal walls (see
    //    `PrintPreparationStep`), which are then planned against the chamfered surface.
    switch decision(.bottomChamfer) {
    case .skip(let reason):
        steps.append(PrintPreparationStepRecord(step: .bottomChamfer, applied: false, lines: [reason]))
    case .run:
        progress("Chamfering the bottom edge…")
        do {
            let result = try bottomChamferCopy(of: mesh, sizeMM: bottomChamferDefaultSizeMM, chamferHoleEntries: false,
                                               isCancelled: isCancelled)
            if let chamfered = result.mesh, result.shellsAfter == health.shells {
                mesh = chamfered
                chamfer = PrintPreparationChamfer(sizeMM: Double(result.sizeMM), outlineLengthMM: result.outlineLengthMM,
                                                  removedVolumeMM3: result.removedVolumeMM3, keptHoleEntries: result.keptHoleEntries)
                steps.append(PrintPreparationStepRecord(step: .bottomChamfer, applied: true, lines: [bottomChamferSummary(result)]))
            } else {
                steps.append(PrintPreparationStepRecord(step: .bottomChamfer, applied: false,
                                                        lines: [result.skipped?.message ?? BottomChamferSkipReason.resultFailedChecks.message]))
            }
        } catch BottomChamferError.stopped {
            throw PrintPreparationError.stopped
        } catch {
            try check()
            steps.append(PrintPreparationStepRecord(step: .bottomChamfer, applied: false, lines: ["Skipped: \(error.localizedDescription)"]))
        }
    }
    try check()
    // The copy's outer shape, measured below. The internal walls only add 0.25 mm slots opening through the bed face,
    // whose ceilings bridge and whose sides Slant's walls fill; measured with them, a ring's island would read as a
    // slender post and its gap as a hole near an edge, and slot ceilings as overhangs.
    let outerShape = mesh

    // 5. Internal walls, cut up from the bed face now that it is down, planned for the saved purpose only (no purpose:
    //    rings and pin and thin-section slots, but no slots through thick regions), with the load read in the placed
    //    copy's axes.
    switch decision(.internalWalls) {
    case .skip(let reason):
        steps.append(PrintPreparationStepRecord(step: .internalWalls, applied: false, lines: [reason]))
    case .run:
        progress("Adding internal walls…")
        do {
            let placed = orientation
            let options = internalWallsOptions(for: input.savedIntent, rotate: { placed.rotate($0) })
            let result = try internalWallsCopy(of: mesh, options: options, isCancelled: isCancelled)
            if let slotted = result.mesh {
                mesh = slotted
                walls = PrintPreparationWalls(result)
                steps.append(PrintPreparationStepRecord(step: .internalWalls, applied: true,
                                                        lines: [internalWallsSummary(result)] + internalWallsSkipNotes(result)))
            } else {
                steps.append(PrintPreparationStepRecord(step: .internalWalls, applied: false,
                                                        lines: [internalWallsSummary(result)] + internalWallsSkipNotes(result)))
            }
        } catch InternalWallsError.stopped {
            throw PrintPreparationError.stopped
        } catch {
            try check()
            steps.append(PrintPreparationStepRecord(step: .internalWalls, applied: false, lines: ["Skipped: \(error.localizedDescription)"]))
        }
    }
    try check()

    guard steps.contains(where: \.applied) else {
        return PrintPreparationResult(record: record(), mesh: nil, data: nil, blocked: nil)
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

    // Advisory only, on the copy's outer shape as it will print (placed, treated and chamfered): overhangs past 45°
    // and Slant's 50°, thin areas Slant's 1 mm walls may not print well, the print advisories (from the same wall
    // analysis) and hidden pockets, which the walls never change.
    progress("Measuring the copy…")
    overhangs = PrintPreparationOverhangs(share45: overhangShare(outerShape, limitDegrees: printPreparationOverhangReportDegrees).fraction,
                                          share50: overhangShare(outerShape, limitDegrees: Double(slantOverhangLimitDegrees)).fraction)
    guard let thickness = analyzeWallThickness(outerShape, maximumSamples: printPreparationWallThicknessSamples, isCancelled: isCancelled) else {
        throw PrintPreparationError.stopped
    }
    thinAreas = printPreparationThinAreaCount(thickness)
    let found = printAdvisories(for: outerShape, placed: true, intent: input.savedIntent, wallThickness: thickness, isCancelled: isCancelled)
    try check()
    // Only an applied placement's lines are shown among what was applied; a kept one's sit in the collapsed list of
    // skipped steps, so its contact and tipping advisories stay.
    let placementShown = steps.contains { $0.step == .orientation && $0.applied }
    advisories = printPreparationAdvisoryRecords(found, placement: placementShown ? choice : nil)
    // A pocket is a shell of its own, so a one-part copy has none. The pipeline never fills them.
    if after.shells > 1, outerShape.triangleCount <= hiddenPocketsMaximumTriangles {
        let report: HiddenPocketsReport
        do { report = try hiddenPocketsReport(outerShape, isCancelled: isCancelled) } catch { throw PrintPreparationError.stopped }
        pockets = PrintPreparationPockets(count: report.count, shellsInside: report.shellsInsidePockets, addedVolumeMM3: report.addedVolumeMM3)
    } else if after.shells <= 1 {
        pockets = PrintPreparationPockets(count: 0, shellsInside: 0, addedVolumeMM3: 0)
    }
    let data = mesh.binarySTL()
    // Read back, as the other copy tools do: the saved bytes must parse to every triangle.
    guard let readBack = try? STLMesh.parse(data), readBack.triangleCount == mesh.triangleCount else {
        return blocked("The prepared copy couldn’t be read back, so no copy was made.")
    }
    return PrintPreparationResult(record: record(), mesh: mesh, data: data, blocked: nil)
}

let printPreparationTreatmentsDropped = "Dropped: the result didn’t pass Studio’s mesh check, even after repair, so the part was kept without them."

/// The treated mesh, repaired if a treatment left it unsound (with the repair's lines), or nil when even repair can't
/// make it sound with `shells` separate parts (a repair that drops a loose piece drops the treatments instead).
func soundTreatedMesh(_ mesh: STLMesh, shells: Int, isCancelled: () -> Bool = { false }) -> (mesh: STLMesh, lines: [String])? {
    guard let report = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { return nil }
    if meshHealthIsSound(report) { return report.shells == shells ? (mesh, []) : nil }
    guard let repaired = try? repairMesh(mesh, isCancelled: isCancelled), repaired.summary.isSound,
          repaired.summary.after.shells == shells else { return nil }
    return (repaired.mesh, ["Tidied after the treatments: " + meshRepairSummaryLines(repaired.summary).joined(separator: " ")])
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
    /// The automatic trigger (true) or Make Print-Ready Copy (false).
    let automatic: Bool
    let keptPlacement: String?
}

/// One model at a time, off the main actor. The work only reads the library file, so it runs whatever else is
/// happening; the copy is saved only once no sheet, alert or dialog is shown and no request runs (the same rule as
/// Finder opens). Saving never changes the selection or the screen. Stoppable, and stopped on quit.
@MainActor final class PrintPreparationQueue: ObservableObject {
    @Published private(set) var pending: [PrintPreparationJob] = []
    @Published private(set) var current: PrintPreparationJob?
    @Published private(set) var status = ""
    /// The one-time notice after the first automatic copy (`printPreparationNoticeShouldShow`).
    @Published private(set) var showsFirstCopyNotice = false
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

    /// Automatic jobs run once per model per session; a manual job runs whenever the model isn't already queued.
    func enqueue(_ job: PrintPreparationJob) {
        if job.automatic {
            guard queuedThisSession.insert(job.modelID).inserted else { return }
        } else {
            guard !isPreparing(job.modelID) else { return }
            queuedThisSession.insert(job.modelID)
        }
        pending.append(job)
        startNextIfIdle()
    }

    /// The seller's Stop for one model: a queued model is dropped, a running one stops at its next safe point.
    func stop(modelID: UUID) {
        if let index = pending.firstIndex(where: { $0.modelID == modelID }) {
            pending.remove(at: index)
            markStopped(modelID)
        } else if current?.modelID == modelID {
            flag?.set()
        }
    }

    /// Quit (everything), or the setting turned off (`automaticOnly`: Make Print-Ready Copy requests carry on). Every
    /// dropped model is marked stopped, so its panel offers Make Print-Ready Copy.
    func stopAll(automaticOnly: Bool = false) {
        let dropped = pending.filter { !automaticOnly || $0.automatic }
        pending.removeAll { !automaticOnly || $0.automatic }
        for job in dropped { markStopped(job.modelID) }
        if let running = current, !automaticOnly || running.automatic {
            flag?.set()
            // Marked now, so a quit before the run reaches its safe point still leaves the status.
            markStopped(running.modelID)
        }
    }

    func dismissFirstCopyNotice() {
        UserDefaults.standard.set(true, forKey: printPreparationNoticeDismissedDefaultsKey)
        showsFirstCopyNotice = false
    }

    private func markStopped(_ modelID: UUID) {
        store?.recordPrintPreparationStatus(PrintPreparationStatus(outcome: .stopped, date: Date()), for: modelID)
    }

    private func startNextIfIdle() {
        guard current == nil else { return }
        let settings = PrintPreparationSettings(defaults: .standard)
        var next: PrintPreparationJob?
        while next == nil, !pending.isEmpty {
            let job = pending.removeFirst()
            // An automatic job whose setting was turned off before it started is dropped, and says so.
            if job.automatic, !settings.enabled { markStopped(job.modelID) } else { next = job }
        }
        guard let job = next else { return }
        current = job
        status = "Preparing for printing…"
        let flag = PrintPreparationCancelFlag()
        self.flag = flag
        runner = Task { [weak self] in
            await self?.run(job, settings: settings, flag: flag)
            guard let self else { return }
            self.current = nil
            self.flag = nil
            self.status = ""
            self.startNextIfIdle()
        }
    }

    private func run(_ job: PrintPreparationJob, settings: PrintPreparationSettings, flag: PrintPreparationCancelFlag) async {
        // Removed from the library while it waited: nothing to prepare, and nothing to report.
        guard store?.localModels.contains(where: { $0.id == job.modelID }) == true else { return }
        let input = PrintPreparationInput(sourceID: job.modelID, sourceName: job.name, savedIntent: job.savedIntent,
                                          internalWalls: settings.internalWalls, automatic: job.automatic, keptPlacement: job.keptPlacement,
                                          bottomChamfer: settings.bottomChamfer)
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
        case .failure(PrintPreparationError.tookTooLong):
            store.finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .stopped, lines: [printPreparationTookTooLong], date: Date()),
                                         counts: (0, 0))
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
            while !flag.isSet, !store.printPreparationCanSave {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            guard !flag.isSet, !job.automatic || PrintPreparationSettings(defaults: .standard).enabled else {
                store.finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .stopped, date: Date()), counts: (0, 0))
                return
            }
            if store.savePrintReadyCopy(file, job: job, record: result.record), job.automatic {
                showsFirstCopyNotice = printPreparationNoticeShouldShow(
                    dismissed: UserDefaults.standard.bool(forKey: printPreparationNoticeDismissedDefaultsKey),
                    automaticCopySavedThisSession: true)
            }
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
                                                          savedIntent: designEditIntent(model), automatic: true,
                                                          keptPlacement: printPreparationKeptPlacementReason(model, origin: origin)))
    }

    /// Make Print-Ready Copy: the seller's own request for any STL except a print-ready copy. Local only; it queues the
    /// work and never uploads. Uses the model's current saved purpose.
    func makePrintReadyCopy(modelID: UUID) {
        // Like Save as Product and Order a Sample: nothing while a sheet, alert or dialog is open.
        guard !menuCommandsBlockedByModalUI else { return }
        guard let model = localModels.first(where: { $0.id == modelID }), printPreparationManualBlockedReason(model) == nil else { return }
        printPreparationQueue.enqueue(PrintPreparationJob(modelID: model.id, url: model.url, name: model.name,
                                                          savedIntent: designEditIntent(model), automatic: false,
                                                          keptPlacement: printPreparationKeptPlacementReason(model, origin: nil)))
    }

    /// Saves the outcome on the original (metadata only; its file is never touched).
    func recordPrintPreparationStatus(_ status: PrintPreparationStatus, for modelID: UUID) {
        guard let index = localModels.firstIndex(where: { $0.id == modelID }) else { return }
        localModels[index].printPreparationStatus = printPreparationStatusKeepingCopy(status, previous: localModels[index].printPreparationStatus)
        saveModels()
    }

    func finishPrintPreparation(_ job: PrintPreparationJob, status: PrintPreparationStatus, counts: (applied: Int, skipped: Int)) {
        recordPrintPreparationStatus(status, for: job.modelID)
        activities.insert(Activity(title: printPreparationActivityTitle,
                                   detail: printPreparationActivityDetail(status, applied: counts.applied, skipped: counts.skipped),
                                   success: status.outcome != .noCopy), at: 0)
    }

    /// Adds the checked copy through `importModel`, next to its original, without changing the selection or the screen.
    @discardableResult
    func savePrintReadyCopy(_ file: URL, job: PrintPreparationJob, record: PrintPreparationRecord) -> Bool {
        guard let original = localModels.first(where: { $0.id == job.modelID }) else {
            // Removed while it was being prepared: nothing to attach the copy to.
            activities.insert(Activity(title: printPreparationActivityTitle, detail: "Original removed; no copy saved", success: false), at: 0)
            return false
        }
        let named = file.deletingLastPathComponent()
            .appendingPathComponent(exportFileName(modelName: printReadyCopyName(original.name), fileExtension: "stl"))
        do { try FileManager.default.moveItem(at: file, to: named) } catch {
            finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .noCopy, lines: ["The copy couldn’t be saved: \(error.localizedDescription)"], date: Date()), counts: (0, 0))
            return false
        }
        guard let copyID = importModelReturningID(named, intent: original.partIntent,
                                                  sourceDetails: sourceDetailsForCopy(of: original), printPreparation: record,
                                                  origin: .studioToolCopy, selectsAndShows: false, insertingBefore: original.id) else {
            finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .noCopy, lines: ["The copy couldn’t be added to your library."], date: Date()), counts: (0, 0))
            return false
        }
        finishPrintPreparation(job, status: PrintPreparationStatus(outcome: .madeCopy, copyID: copyID, date: Date()),
                               counts: (record.appliedSteps.count, record.skippedSteps.count))
        return true
    }
}
