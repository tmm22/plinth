import Foundation
import simd

// Internal walls: thin vertical slots cut up from the bed face into solid material. Slant's slicer prints its walls
// (1 mm, about two lines) on both sides of every slot, so each slot turns a band of 25% infill into solid wall.
// Every slot opens through the bed face: Slant bills each closed internal void as an extra body (a live estimate on
// 25 Oct 2026 charged $3.50 for nine closed voids, and nothing for the same slots opened through the bottom).
//
// Four kinds, planned in this order, each kept clear of the ones before it:
// - hole rings: an annular gap round each round hole that opens through the bed face, so the bore gets a band of
//   solid wall round it; the bore itself is unchanged;
// - pin slots: one slot through the middle of an upright pin or boss 3–8 mm across;
// - thin-section slots: one slot along the middle of a straight section 2.5–5 mm thick;
// - slots in thick regions ("bulk" slots): parallel slots through regions at least 5 mm across.
//
// Every opening is proven clear of every surface except the bed face (and, for a ring, the bore it surrounds) before
// anything is built, so the cut only ever meets the bed face. The result is therefore assembled directly, as the Size
// and base tools do: the bed face is re-triangulated with an opening per slot and ring, and each one's walls and
// ceiling are added. No Boolean library is involved, so the result is exact, fast on large meshes and the same bytes on
// every run.
//
// Pure and deterministic: triangles, lines, columns and slots are walked in index order, and dictionaries are only
// used for lookups, never iterated for output.

// MARK: - Defaults

/// Slot width. Slicers close gaps narrower than about 0.1 mm (a 0.049 mm closing radius is the common default), so
/// slots must be wider than that to force walls; 0.2–0.3 mm is the workable window, and Slant's live estimate of
/// 25 Oct 2026 used 0.25 mm and kept the part one body.
let internalWallsSlotWidthMM: Float = 0.25
/// Centre-to-centre spacing between slot lines. With Slant's 1 mm walls each slot becomes a band of solid wall about
/// 2.25 mm wide (1 mm, the slot, 1 mm); at 4 mm about 1.75 mm of 25% infill is left between bands. At 3 mm the bands
/// almost touch and the region prints nearly solid, costing material without adding separate walls; at 5 mm and more
/// fewer walls are added per millimetre. 4 mm is also the spacing Slant priced in the live test (+27% cost on a
/// 40 × 40 × 20 mm block). When the volume cap below needs it, the spacing is widened in 0.5 mm steps.
let internalWallsSlotSpacingMM: Float = 4
/// Material kept between every slot in a thick region or hole ring and every other surface: outer walls, holes, the
/// top and any other face. It is twice Slant's 1 mm wall, so the walls the slicer prints round a slot never merge with
/// the part's own skin.
let internalWallsClearanceMM: Float = 2
/// Regions thinner than this across either horizontal direction get no slots: their walls and infill are already
/// close together. 5 mm is about the narrowest region the clearance allows anyway (2 × (2 mm + the 0.37 mm sampling
/// margin) + the 0.25 mm slot = 4.99 mm), so the clearance proof, not this filter, keeps every slot 2 mm from the skin.
let internalWallsMinimumRegionMM: Float = 5
/// Slots shorter than this from the bed add too few layers of wall to be worth the cut.
let internalWallsMinimumSlotHeightMM: Float = 3
/// Slots shorter than this along their length are left out.
let internalWallsMinimumSlotLengthMM: Float = 3
/// The most of the part's volume the slots in thick regions may remove; the spacing is widened until the plan fits.
/// 6% keeps the 4 mm spacing Slant priced on 25 Oct 2026 (9 slots in a 40×40×20 mm block removed 4.4%) on most parts.
let internalWallsMaximumRemovedFraction = 0.06
/// The most of the part's volume the hole rings, pin slots and thin-section slots may remove together. They are
/// narrow and few, so this only binds on parts made almost entirely of thin walls; thin-section slots, planned last,
/// are left out first.
let internalWallsMaximumTargetedRemovedFraction = 0.10
/// Distance between sample columns along a slot line, and between sample heights in a column.
let internalWallsSampleStepMM: Float = 0.5
/// Adjacent slots on one line whose heights differ by more than this become separate slots, 1 mm apart, so a tall
/// region beside a low one gets full-height slots.
let internalWallsHeightSplitMM: Float = 2
/// A bed triangle lies within this distance of the lowest point and faces straight down, the same rule as
/// `bottomContactAreaMM2`.
let internalWallsBedToleranceMM: Float = 0.0001
/// Less flat downward area than this at the lowest point is not a bed face.
let internalWallsMinimumBedAreaMM2 = 1.0
/// The most planned slots left out because their opening couldn't be joined; past this the plan is a failure.
let internalWallsMaximumDroppedSlots = 8
/// Meshes above this many triangles are skipped: the library's own limit. In a release build one run took 0.3 s at
/// 100,000 triangles, 0.5 s at 200,000 and 0.7 s at 400,000 (Euclid needed 83 s for the same slots in an 80,000-triangle
/// disc), so nothing smaller is needed. With every kind planned (a ring, a pin slot, a thin-section slot and 13 slots in
/// thick regions) one run took 0.06 s at 23,520 triangles, 0.20 s at 125,440 and 0.55 s at 376,320 (25 Oct 2026).
let internalWallsMaximumTriangles = 500_000

/// Slant's printed wall (about two 0.5 mm lines) and sparse infill, as published on 25 Oct 2026: the basis of the
/// material estimate.
let internalWallsSlantWallMM: Float = 1
let internalWallsSlantInfillFraction = 0.25

// Hole rings.

/// Material left between the bore and its ring: 1.375 mm, about 2¾ of Slant's roughly 0.5 mm lines. The bore's own
/// 1 mm wall (2 lines) takes most of it and the ring's inner wall the rest, so the band prints solid with no infill
/// between; any wider and a strip of 25% infill would be left, any narrower and the bore's wall would be squeezed. The
/// ring's centre then sits about 1.5 mm out from the bore wall, and the solid band round the bore is about 2.6 mm (this
/// band, the gap, and the 1 mm wall on the gap's far side) instead of 1 mm.
let internalWallsRingWallMM: Float = 1.375
/// A bore's triangles are those within its bed-face radius plus this, so a straight bore's walls are recognised.
let internalWallsBoreRadiusToleranceMM: Float = 0.02
/// Round holes from 1.5 to 20 mm across get rings: screw, pin and insert holes. Smaller ones print as a solid wall
/// anyway; larger ones are cut-outs rather than holes that carry a fastener.
let internalWallsBoreDiameterRangeMM: ClosedRange<Float> = 1.5...20
/// A bed-face hole is round when it has at least this many corners, every corner lies within 90% of its largest radius
/// and its area is at least 85% of the circle through that radius (an octagon passes; a square doesn't).
let internalWallsBoreMinimumCorners = 8
/// A ring round a blind bore stops this far below the bore's ceiling: one Slant wall, so the ring ends inside the
/// band the bore's own walls already make.
let internalWallsRingBlindTopClearanceMM: Float = 1
/// The ring's polygons have one side per this much of the outer circumference (24 to 256 sides).
let internalWallsRingSideMM: Float = 0.5
/// Every point of a ring lies within this of a sample point (half the radial gap, half a 0.5 mm sample spacing and
/// half a height step, with the polygon's slight overshoot), so samples this much beyond the clearance prove the ring.
let internalWallsRingSampleMarginMM: Float = 0.4
/// Most rings per part. Each adds two outline loops of up to 256 points to the bed face, so this bounds bridging work.
let internalWallsMaximumRings = 64

// Pin and thin-section slots.

/// Material kept between a pin or thin-section slot and every other surface: one Slant wall (2 lines), so the slot's
/// own walls meet the part's skin and the section prints solid. A pin or section is too small for the 2 mm clearance.
let internalWallsTargetedClearanceMM: Float = 1
/// Sample spacing for pin and thin-section slots: finer than the thick-region step, so the sampling margin is 0.22 mm
/// rather than 0.37 mm and a 2.5 mm section can take a slot with its clearance proven.
let internalWallsFineStepMM: Float = 0.25
/// Pins and bosses 3–8 mm across get a slot. Under 3 mm no slot fits with 1 mm each side; over 8 mm the part is a
/// thick region.
let internalWallsPinWidthRangeMM: ClosedRange<Float> = 3...8
/// A pin must stand at least this tall above the bed or the region it rises from.
let internalWallsMinimumPinHeightMM: Float = 3
/// Pin slots shorter than this along their length are left out.
let internalWallsMinimumPinSlotLengthMM: Float = 1
let internalWallsMaximumPinSlots = 64
/// Flat tops examined as possible pins.
let internalWallsMaximumPinCandidates = 512
/// Sections from 2.5 mm up to `internalWallsMinimumRegionMM` thick get a thin-section slot. 2.5 mm leaves 1.125 mm
/// each side of the 0.25 mm slot: just over one Slant wall.
let internalWallsThinMinimumMM: Float = 2.5
/// Sections from this up to 2.5 mm are reported as too thin.
let internalWallsThinTooThinFromMM: Float = 2
/// Heights above the bed where sections are measured: walls rising from a base are found above it.
let internalWallsThinProbeHeightsMM: [Float] = [1, 2.5, 4, 6, 9, 13, 18]
/// A thin section must run at least this far: shorter ones are pins.
let internalWallsMinimumThinRunMM: Float = 8.5
let internalWallsMaximumThinSlots = 256
/// Candidate lines examined for thin-section slots.
let internalWallsMaximumThinLines = 4096

/// A load whose horizontal share is under this (within about 22.5° of vertical) leaves the slot direction automatic:
/// the slots are vertical walls either way.
let internalWallsLoadHorizontalMinimum: Float = 0.38

// MARK: - Types

/// The direction the slots in thick regions run along. Automatic picks the bed footprint's longer side (X on a tie):
/// fewer, longer slots with fewer ends, and walls along a part's length work like the web of a beam when the part
/// bends lengthways.
enum InternalWallsAxis: String, Codable, Sendable, CaseIterable {
    case automatic, x, y
}

/// The kinds of internal wall, in the order they are planned.
enum InternalWallsKind: String, Codable, Sendable, CaseIterable {
    case holeRing, pinSlot, thinSlot, bulkSlot

    var index: Int {
        switch self {
        case .holeRing: return 0
        case .pinSlot: return 1
        case .thinSlot: return 2
        case .bulkSlot: return 3
        }
    }

    /// "2 hole rings", "1 slot in a thick region".
    func label(_ count: Int) -> String {
        let n = count.formatted()
        switch self {
        case .holeRing: return count == 1 ? "1 hole ring" : "\(n) hole rings"
        case .pinSlot: return count == 1 ? "1 pin slot" : "\(n) pin slots"
        case .thinSlot: return count == 1 ? "1 thin-section slot" : "\(n) thin-section slots"
        case .bulkSlot: return count == 1 ? "1 slot in a thick region" : "\(n) slots in thick regions"
        }
    }

    /// What a skip note counts: "2 holes", "1 thin section".
    func subject(_ count: Int) -> String {
        let n = count.formatted()
        switch self {
        case .holeRing: return count == 1 ? "1 hole" : "\(n) holes"
        case .pinSlot: return count == 1 ? "1 pin" : "\(n) pins"
        case .thinSlot: return count == 1 ? "1 thin section" : "\(n) thin sections"
        case .bulkSlot: return count == 1 ? "1 slot" : "\(n) slots"
        }
    }
}

/// Which kinds to add. `InternalWallsOptions()` keeps the slots in thick regions only, as before round 11; callers
/// choose a plan with `internalWallsPlan(for:)`.
struct InternalWallsPlan: Equatable, Codable, Sendable {
    var holeRings = false
    var pinSlots = false
    var thinSlots = false
    var bulkSlots = true

    init(holeRings: Bool = false, pinSlots: Bool = false, thinSlots: Bool = false, bulkSlots: Bool = true) {
        self.holeRings = holeRings; self.pinSlots = pinSlots; self.thinSlots = thinSlots; self.bulkSlots = bulkSlots
    }

    static let none = InternalWallsPlan(bulkSlots: false)
    static let bulkOnly = InternalWallsPlan()
    /// Rings, pin slots and thin-section slots: the cheap kinds, without the slots in thick regions.
    static let targeted = InternalWallsPlan(holeRings: true, pinSlots: true, thinSlots: true, bulkSlots: false)
    static let all = InternalWallsPlan(holeRings: true, pinSlots: true, thinSlots: true, bulkSlots: true)

    var isEmpty: Bool { !holeRings && !pinSlots && !thinSlots && !bulkSlots }

    func includes(_ kind: InternalWallsKind) -> Bool {
        switch kind {
        case .holeRing: return holeRings
        case .pinSlot: return pinSlots
        case .thinSlot: return thinSlots
        case .bulkSlot: return bulkSlots
        }
    }
}

/// The plan for a part's saved purpose:
/// - decorative: nothing, since a display piece carries no load and every wall adds filament;
/// - bracket, clip, enclosure and custom (every functional purpose): every kind;
/// - no saved purpose: hole rings, pin slots and thin-section slots, but no slots in thick regions. Those are where
///   most of the material goes (+69% material and +27% price on Slant's 40 × 40 × 20 mm block, 25 Oct 2026), and the
///   automatic copy runs on every new model before the seller has said it carries a load; rings and pin slots add
///   little, and setting a functional purpose turns the rest on.
/// Pass the seller's saved purpose only, never a neutral stand-in such as `PartIntent()`, whose default is enclosure.
func internalWallsPlan(for intent: PartIntent?) -> InternalWallsPlan {
    guard let intent else { return .targeted }
    switch intent.purpose {
    case .decorative: return .none
    case .bracket, .clip, .enclosure, .custom: return .all
    }
}

/// The slot direction for a load, given in the placed part's coordinates (Z up): parallel to the load's horizontal
/// component, or automatic when there is no load, it is mostly vertical, or it runs diagonally between X and Y.
func internalWallsAxis(forLoad direction: SIMD3<Float>?) -> InternalWallsAxis {
    guard let direction, direction.x.isFinite, direction.y.isFinite, direction.z.isFinite else { return .automatic }
    let length = simd_length(direction)
    guard length > 0 else { return .automatic }
    let x = abs(direction.x) / length, y = abs(direction.y) / length
    guard (x * x + y * y).squareRoot() >= internalWallsLoadHorizontalMinimum, abs(x - y) > 0.01 else { return .automatic }
    return x > y ? .x : .y
}

/// Options for a part's saved purpose and load. `rotate` maps the model's original coordinates to the placed copy's
/// (the placement chosen for printing), so the load's direction is read where the slots are cut.
func internalWallsOptions(for intent: PartIntent?, rotate: (SIMD3<Float>) -> SIMD3<Float> = { $0 }) -> InternalWallsOptions {
    var options = InternalWallsOptions()
    options.plan = internalWallsPlan(for: intent)
    options.axis = internalWallsAxis(forLoad: intent?.effectiveLoad.vector.map(rotate))
    return options
}

/// A world-coordinate box no slot or ring may enter.
struct InternalWallsKeepClearBox: Equatable, Sendable {
    var low: SIMD3<Float>
    var high: SIMD3<Float>
}

struct InternalWallsOptions: Equatable, Sendable {
    var slotWidthMM: Float = internalWallsSlotWidthMM
    var spacingMM: Float = internalWallsSlotSpacingMM
    var clearanceMM: Float = internalWallsClearanceMM
    var minimumRegionMM: Float = internalWallsMinimumRegionMM
    var maximumRemovedFraction: Double = internalWallsMaximumRemovedFraction
    /// The direction of the slots in thick regions.
    var axis: InternalWallsAxis = .automatic
    var keepClear: [InternalWallsKeepClearBox] = []
    var maximumTriangles: Int = internalWallsMaximumTriangles
    var plan: InternalWallsPlan = .bulkOnly
    var maximumTargetedRemovedFraction: Double = internalWallsMaximumTargetedRemovedFraction
    var maximumRings: Int = internalWallsMaximumRings
    var maximumPinSlots: Int = internalWallsMaximumPinSlots
    var maximumThinSlots: Int = internalWallsMaximumThinSlots
}

/// Why no copy was made. Each is a normal outcome, not an error.
enum InternalWallsSkipReason: String, Equatable, Sendable, CaseIterable {
    case notClosedSolid
    case tooManyTriangles
    case noFlatBedFace
    case noRegionThickEnough
    case wouldRemoveTooMuch
    case wouldChangeShellCount
    case resultFailedChecks
    case nothingPlanned
    case noFeatureSuitable

    var message: String {
        switch self {
        case .notClosedSolid:
            return "Internal walls need a closed, outward-facing mesh with no zero-area triangles. Repair a copy first."
        case .tooManyTriangles:
            return "This model has more than \(internalWallsMaximumTriangles.formatted()) triangles, too many for internal walls. Simplify a copy first."
        case .noFlatBedFace:
            return "No internal walls were added: the model has no flat face at its lowest point for the slots to open through. Orient it with a flat face down first."
        case .noRegionThickEnough:
            return "No internal walls were added: no region is thick enough, about \(Int(internalWallsMinimumRegionMM)) mm across with \(Int(internalWallsClearanceMM)) mm of material round each slot."
        case .wouldRemoveTooMuch:
            return "No internal walls were added: the slots would remove too much of the part."
        case .wouldChangeShellCount:
            return "No internal walls were added: the slots would change the number of separate parts."
        case .resultFailedChecks:
            return "No internal walls were added: the result didn’t pass Plinth’s mesh checks."
        case .nothingPlanned:
            return "No internal walls were planned for this part."
        case .noFeatureSuitable:
            return "No internal walls were added: no round hole, pin, thin section or thick region opening onto the bed face has room for one."
        }
    }
}

/// Why one hole, pin, section or region got no wall.
enum InternalWallsFeatureSkipReason: String, Codable, Sendable, CaseIterable {
    /// Nothing of this kind was found.
    case noneFound
    /// The opening wouldn't start on the bed face.
    case notOpenAtBed
    /// Another surface (or another wall) is too close.
    case tooCloseToSurface
    /// Too short a slot or ring to be worth the cut.
    case tooShort
    /// A section under 2.5 mm, which would leave less than 1 mm each side of a slot.
    case tooThin
    case wouldRemoveTooMuch
    case limitReached
    /// Its opening couldn't be joined into the bed face's fill.
    case couldNotJoin
    /// A hollow boss: a slot through its middle would cut into its hole.
    case hollow

    var index: Int { Self.allCases.firstIndex(of: self)! }
}

struct InternalWallsFeatureSkip: Equatable, Sendable {
    let reason: InternalWallsFeatureSkipReason
    let count: Int
}

/// What happened for one kind: how many were made, and how many were left out and why (in reason order).
struct InternalWallsKindReport: Equatable, Sendable {
    let kind: InternalWallsKind
    let planned: Bool
    let made: Int
    let skipped: [InternalWallsFeatureSkip]

    func count(_ reason: InternalWallsFeatureSkipReason) -> Int { skipped.first { $0.reason == reason }?.count ?? 0 }
}

/// One line for a kind's skip, such as "2 holes got no ring: another surface is within 2 mm." Never a strength claim.
func internalWallsSkipNote(_ kind: InternalWallsKind, _ skip: InternalWallsFeatureSkip) -> String {
    if skip.reason == .noneFound {
        switch kind {
        case .holeRing: return "Hole rings: no round hole, \(internalWallsBoreDiameterRangeMM.lowerBound.formatted())–\(Int(internalWallsBoreDiameterRangeMM.upperBound)) mm across, opens through the bed face."
        case .pinSlot: return "Pin slots: no upright pin or boss \(Int(internalWallsPinWidthRangeMM.lowerBound))–\(Int(internalWallsPinWidthRangeMM.upperBound)) mm across with a flat top was found."
        case .thinSlot: return "Thin-section slots: no straight section \(internalWallsThinMinimumMM.formatted())–\(Int(internalWallsMinimumRegionMM)) mm thick was found."
        case .bulkSlot: return "Slots in thick regions: no region is about \(Int(internalWallsMinimumRegionMM)) mm across with \(Int(internalWallsClearanceMM)) mm of material round each slot."
        }
    }
    // The slots in thick regions are planned together, so they are left out together.
    if kind == .bulkSlot, skip.reason == .wouldRemoveTooMuch {
        return "Slots in thick regions were left out: they would remove too much of the part."
    }
    let treatment: String
    switch kind {
    case .holeRing: treatment = "no ring"
    case .bulkSlot: treatment = "left out"
    default: treatment = "no slot"
    }
    let verb = kind == .bulkSlot ? (skip.count == 1 ? "was" : "were") : "got"
    let why: String
    switch skip.reason {
    case .noneFound: why = ""
    case .notOpenAtBed: why = "it wouldn’t open through the bed face"
    case .tooCloseToSurface:
        let clearance = kind == .holeRing || kind == .bulkSlot ? internalWallsClearanceMM : internalWallsTargetedClearanceMM
        why = "another surface or wall is within \(Int(clearance)) mm"
    case .tooShort: why = "there isn’t room for a ring or slot at least \(Int(internalWallsMinimumSlotHeightMM)) mm tall"
    case .tooThin: why = "under \(internalWallsThinMinimumMM.formatted()) mm thick, which would leave less than \(Int(internalWallsTargetedClearanceMM)) mm each side of a slot"
    case .wouldRemoveTooMuch: why = "it would remove too much of the part"
    case .limitReached: why = "Plinth’s limit per part was reached"
    case .couldNotJoin: why = "its opening couldn’t be joined into the base"
    case .hollow: why = skip.count == 1 ? "it is hollow, so a slot through its middle would cut into its hole"
        : "they are hollow, so a slot through the middle would cut into the hole"
    }
    return "\(kind.subject(skip.count).prefix(1).uppercased())\(kind.subject(skip.count).dropFirst()) \(verb) \(treatment): \(why)."
}

/// Every skip note for the kinds that were planned, in kind and reason order.
func internalWallsSkipNotes(_ result: InternalWallsResult) -> [String] {
    result.kinds.filter(\.planned).flatMap { report in report.skipped.map { internalWallsSkipNote(report.kind, $0) } }
}

/// One slot: an axis-aligned box from the bed face up, in world coordinates.
struct InternalWallsSlot: Equatable, Sendable {
    let low: SIMD3<Float>
    let high: SIMD3<Float>
    /// Along the slot's axis.
    let lengthMM: Float
    let widthMM: Float
    var kind: InternalWallsKind = .bulkSlot
    /// How much of the material beside each face was 25% infill that the slot's walls now print solid (at most
    /// Slant's 1 mm wall): an input to the material estimate only.
    var infillBandMM: Float = internalWallsSlantWallMM
    var heightMM: Float { high.z - low.z }
    var volumeMM3: Double { Double(lengthMM) * Double(widthMM) * Double(heightMM) }
}

/// A round hole in the bed face.
struct InternalWallsBore: Equatable, Sendable {
    let centre: SIMD2<Float>
    /// The largest distance from the centre to a corner of the hole's outline.
    let radiusMM: Float
}

/// The part of space a bore's own surfaces lie in: a vertical cylinder, widening by `slope` per millimetre above
/// `floorZ` for a bore drawn with a draft (`internalWallsBoreDraftSlope`).
struct InternalWallsCylinder: Equatable, Sendable {
    let centre: SIMD2<Float>
    let radius: Float
    var floorZ: Float = 0
    var slope: Float = 0

    func contains(_ q: SIMD3<Float>) -> Bool {
        let r = slope > 0 ? radius + slope * max(0, q.z - floorZ) : radius
        return simd_distance_squared(SIMD2(q.x, q.y), centre) <= r * r
    }
}

/// tan 1°: bores drawn with up to about 1° of draft (wider at the top, as moulded parts often are) still count as the
/// bore's own surfaces.
let internalWallsBoreDraftSlope: Float = 0.017455

/// How much `cylinder`'s bore widens per millimetre of height, from the corners of the triangles that lie within its
/// largest allowed draft (up to `internalWallsBoreDraftSlope`); 0 for a straight bore.
func internalWallsBoreDraft(_ cylinder: InternalWallsCylinder, corners: [SIMD3<Float>], floor: Float) -> Float {
    let widest = InternalWallsCylinder(centre: cylinder.centre, radius: cylinder.radius, floorZ: floor, slope: internalWallsBoreDraftSlope)
    var slope: Float = 0
    var t = 0
    while t + 2 < corners.count {
        let a = corners[t], b = corners[t + 1], c = corners[t + 2]
        t += 3
        guard widest.contains(a), widest.contains(b), widest.contains(c) else { continue }
        for q in [a, b, c] where q.z > floor + 0.01 {
            let grow = (simd_distance(SIMD2(q.x, q.y), cylinder.centre) - cylinder.radius) / (q.z - floor)
            if grow > slope { slope = grow }
        }
    }
    return min(slope, internalWallsBoreDraftSlope)
}

/// One ring: the gap between two regular polygons with the same corners' angles, from the bed face up.
struct InternalWallsRing: Equatable, Sendable {
    let centre: SIMD2<Float>
    let boreRadiusMM: Float
    let blind: Bool
    let floorZ: Float
    let topZ: Float
    /// The gap's inner and outer outlines, anticlockwise from +X seen from above.
    let inner: [SIMD2<Float>]
    let outer: [SIMD2<Float>]
    /// The distance from the centre to the middle of a side.
    let innerRadiusMM: Float
    let outerRadiusMM: Float
    var heightMM: Float { topZ - floorZ }
    var volumeMM3: Double { (internalWallsPolygonArea(outer) - internalWallsPolygonArea(inner)) * Double(heightMM) }
}

/// Shoelace area of a closed outline, positive when anticlockwise.
func internalWallsPolygonArea(_ points: [SIMD2<Float>]) -> Double {
    var sum = 0.0
    for i in points.indices {
        let p = SIMD2<Double>(points[i]), q = SIMD2<Double>(points[(i + 1) % points.count])
        sum += p.x * q.y - q.x * p.y
    }
    return sum / 2
}

/// A ring's outlines round `centre`, with the given distances to the middle of each side: one side per
/// `internalWallsRingSideMM` of the outer outline, 24 to 256 sides.
func internalWallsRingOutlines(centre: SIMD2<Float>, innerRadius: Float, outerRadius: Float) -> (inner: [SIMD2<Float>], outer: [SIMD2<Float>]) {
    let sides = min(256, max(24, Int((2 * Float.pi * outerRadius / internalWallsRingSideMM).rounded(.up))))
    let toCorner = 1 / cos(Double.pi / Double(sides))
    var inner: [SIMD2<Float>] = [], outer: [SIMD2<Float>] = []
    inner.reserveCapacity(sides); outer.reserveCapacity(sides)
    for k in 0..<sides {
        let angle = 2 * Double.pi * Double(k) / Double(sides)
        let direction = SIMD2<Double>(cos(angle), sin(angle))
        let c = SIMD2<Double>(centre)
        let i = c + direction * Double(innerRadius) * toCorner, o = c + direction * Double(outerRadius) * toCorner
        inner.append(SIMD2(Float(i.x) + 0, Float(i.y) + 0))
        outer.append(SIMD2(Float(o.x) + 0, Float(o.y) + 0))
    }
    return (inner, outer)
}

/// Sample points along the middle of a ring's gap, at most 0.5 mm apart.
func internalWallsRingSamples(inner: [SIMD2<Float>], outer: [SIMD2<Float>]) -> [SIMD2<Float>] {
    var samples: [SIMD2<Float>] = []
    for k in inner.indices {
        let next = (k + 1) % inner.count
        let a = (inner[k] + outer[k]) / 2, b = (inner[next] + outer[next]) / 2
        let pieces = max(1, Int((simd_distance(a, b) / internalWallsSampleStepMM).rounded(.up)))
        for j in 0..<pieces { samples.append(a + (b - a) * ((Float(j) + 0.5) / Float(pieces))) }
    }
    return samples
}

/// Round holes among the bed face's outline loops (corner indices into `points`). Holes run anticlockwise seen from
/// above, because the bed face faces down.
func internalWallsBores(points: [SIMD3<Float>], loops: [[Int]]) -> [InternalWallsBore] {
    var bores: [InternalWallsBore] = []
    for loop in loops where loop.count >= internalWallsBoreMinimumCorners {
        var twiceArea = 0.0, cx = 0.0, cy = 0.0
        for i in loop.indices {
            let p = points[loop[i]], q = points[loop[(i + 1) % loop.count]]
            let cross = Double(p.x) * Double(q.y) - Double(q.x) * Double(p.y)
            twiceArea += cross
            cx += (Double(p.x) + Double(q.x)) * cross
            cy += (Double(p.y) + Double(q.y)) * cross
        }
        guard twiceArea > 0, twiceArea.isFinite else { continue }
        cx /= 3 * twiceArea; cy /= 3 * twiceArea
        var largest = 0.0, smallest = Double.greatestFiniteMagnitude
        for i in loop {
            let r = ((Double(points[i].x) - cx) * (Double(points[i].x) - cx) + (Double(points[i].y) - cy) * (Double(points[i].y) - cy)).squareRoot()
            largest = max(largest, r); smallest = min(smallest, r)
        }
        guard internalWallsBoreDiameterRangeMM.contains(Float(2 * largest)), smallest >= 0.9 * largest,
              twiceArea / 2 >= 0.85 * Double.pi * largest * largest else { continue }
        bores.append(InternalWallsBore(centre: SIMD2(Float(cx), Float(cy)), radiusMM: Float(largest)))
    }
    return bores
}

struct InternalWallsResult: Sendable {
    /// The slotted copy, or nil when skipped.
    let mesh: STLMesh?
    /// The copy as binary STL, the bytes to save.
    let data: Data?
    let skipped: InternalWallsSkipReason?
    /// Every slot: pin slots, then thin-section slots, then slots in thick regions.
    let slots: [InternalWallsSlot]
    /// The direction the slots in thick regions run along: `.x` or `.y`, or `.automatic` when skipped before one was
    /// chosen.
    let axis: InternalWallsAxis
    /// The spacing of the slots in thick regions, which may be wider than asked for to keep within the volume cap.
    let spacingMM: Float
    /// Every slot's and ring's volume.
    let removedVolumeMM3: Double
    /// Of the input's volume.
    let removedFraction: Double
    let shellsBefore: Int
    let shellsAfter: Int
    /// Planned slots and rings left out because their opening couldn't be joined into the bed face's fill.
    var droppedSlots = 0
    var rings: [InternalWallsRing] = []
    /// One per kind, in `InternalWallsKind` order.
    var kinds: [InternalWallsKindReport] = []
    /// The new internal faces: every slot's and ring's walls and ceiling.
    var addedSurfaceAreaMM2: Double = 0
    /// Studio's estimate of the extra filament from Slant's 1 mm walls and 25% infill (published 25 Oct 2026): each
    /// new face turns its band of infill solid, and the slot's own volume of infill goes. For Slant's 40 × 40 × 20 mm
    /// block it gives about 64%; Slant's own estimate that day showed 69% more material.
    var estimatedExtraMaterialMM3: Double = 0
    /// Of Studio's estimate of the part's printed material (its 1 mm walls, then 25% infill).
    var estimatedExtraMaterialFraction: Double = 0

    var slotCount: Int { slots.count }
    var totalSlotLengthMM: Double { slots.reduce(0) { $0 + Double($1.lengthMM) } }
    /// The slots' outline length in one layer: about the extra perimeter path the slicer prints per layer, on each side
    /// of every slot. An estimate.
    var slotPerimeterMM: Double { slots.reduce(0) { $0 + 2 * Double($1.lengthMM + $1.widthMM) } }
    var applied: Bool { mesh != nil }

    func count(of kind: InternalWallsKind) -> Int {
        kind == .holeRing ? rings.count : slots.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
    }
    func report(_ kind: InternalWallsKind) -> InternalWallsKindReport? { kinds.first { $0.kind == kind } }
}

enum InternalWallsError: LocalizedError, Equatable {
    case invalidOptions(String)
    case stopped

    var errorDescription: String? {
        switch self {
        case .invalidOptions(let problem): return problem
        case .stopped: return "Stopped. Nothing was saved."
        }
    }
}

/// Nil when the options can be used.
func internalWallsOptionsProblem(_ options: InternalWallsOptions) -> String? {
    let values = [options.slotWidthMM, options.spacingMM, options.clearanceMM, options.minimumRegionMM]
    guard values.allSatisfy({ $0.isFinite }), options.maximumRemovedFraction.isFinite,
          options.maximumTargetedRemovedFraction.isFinite else { return "Use finite values for internal walls." }
    if !(0.15...0.5).contains(options.slotWidthMM) { return "Use a slot width from 0.15 to 0.5 mm." }
    if !(2...20).contains(options.spacingMM) || options.spacingMM < options.slotWidthMM * 4 { return "Use a slot spacing from 2 to 20 mm." }
    if !(1...10).contains(options.clearanceMM) { return "Use a clearance from 1 to 10 mm." }
    if !(2...50).contains(options.minimumRegionMM) { return "Use a minimum region from 2 to 50 mm." }
    if !(0.001...0.2).contains(options.maximumRemovedFraction) { return "Use a volume limit from 0.1% to 20%." }
    if !(0.001...0.3).contains(options.maximumTargetedRemovedFraction) { return "Use a volume limit for rings and narrow slots from 0.1% to 30%." }
    if options.maximumTriangles < 1 { return "Use a positive triangle limit." }
    if options.maximumRings < 0 || options.maximumPinSlots < 0 || options.maximumThinSlots < 0 { return "Use limits of zero or more." }
    for box in options.keepClear {
        guard [box.low.x, box.low.y, box.low.z, box.high.x, box.high.y, box.high.z].allSatisfy({ $0.isFinite }),
              box.high.x > box.low.x, box.high.y > box.low.y, box.high.z > box.low.z else {
            return "Keep-clear regions need finite positions and positive dimensions."
        }
    }
    return nil
}

/// "a", "a and b", "a, b and c".
private func internalWallsList(_ items: [String]) -> String {
    guard items.count > 1 else { return items.first ?? "" }
    return items.dropLast().joined(separator: ", ") + " and " + items.last!
}

/// One line for the seller, such as "Adds internal walls: 2 hole rings and 9 slots in thick regions, 0.25 mm wide,
/// all opening through the bed face. About 1,500 mm³ (4.7%) removed and 11,000 mm² of internal surface added: an
/// estimated 64% more filament (…). 1 part before and after." Never a strength claim.
func internalWallsSummary(_ result: InternalWallsResult) -> String {
    if let reason = result.skipped { return reason.message }
    let made = InternalWallsKind.allCases.compactMap { kind -> String? in
        let n = result.count(of: kind)
        return n > 0 ? kind.label(n) : nil
    }
    let parts = result.shellsAfter == 1 ? "1 part" : "\(result.shellsAfter.formatted()) parts"
    let width = String(format: "%.2f", result.slots.first?.widthMM ?? internalWallsSlotWidthMM)
    let opening = made.count == 1 && result.slots.count + result.rings.count == 1 ? "opening" : "all opening"
    let lengths = result.rings.isEmpty && !result.slots.isEmpty ? ", \(Int(result.totalSlotLengthMM.rounded()).formatted()) mm in all" : ""
    var summary = "Adds internal walls: \(internalWallsList(made))\(lengths), \(width) mm wide, \(opening) through the bed face."
    summary += " About \(Int(result.removedVolumeMM3.rounded()).formatted()) mm³ (\(String(format: "%.1f", result.removedFraction * 100))%) removed"
    summary += " and \(Int(result.addedSurfaceAreaMM2.rounded()).formatted()) mm² of internal surface added: an estimated"
    summary += " \(Int((result.estimatedExtraMaterialFraction * 100).rounded()))% more filament (Plinth’s estimate from Slant’s 1 mm walls and 25% infill, 25 Oct 2026), so request a new Slant quote."
    summary += " \(parts) before and after."
    return summary + internalWallsDroppedSlotsNote(result.droppedSlots)
}

/// " 2 planned slots were left out: …", or nothing when every planned slot was cut.
func internalWallsDroppedSlotsNote(_ dropped: Int) -> String {
    guard dropped > 0 else { return "" }
    return dropped == 1 ? " 1 planned slot was left out: its opening couldn’t be joined into the base."
        : " \(dropped) planned slots were left out: their openings couldn’t be joined into the base."
}

// MARK: - Material estimate

/// Studio's estimate of a part's printed material on Slant: its skin as a 1 mm wall (never more than the part), then
/// 25% infill in the rest.
func internalWallsBaselineMaterialMM3(volumeMM3: Double, surfaceAreaMM2: Double) -> Double {
    let skin = min(volumeMM3, surfaceAreaMM2 * Double(internalWallsSlantWallMM))
    return skin + internalWallsSlantInfillFraction * max(0, volumeMM3 - skin)
}

/// The new internal faces' area: every slot's four walls and ceiling, and every ring's two walls and ceiling.
func internalWallsAddedSurfaceAreaMM2(slots: [InternalWallsSlot], rings: [InternalWallsRing]) -> Double {
    var area = 0.0
    for slot in slots {
        let l = Double(slot.lengthMM), w = Double(slot.widthMM), h = Double(slot.heightMM)
        area += 2 * l * h + 2 * w * h + l * w
    }
    for ring in rings {
        let walls = internalWallsRingFaceAreas(ring)
        area += walls.inner + walls.outer + walls.ceiling
    }
    return area
}

private func internalWallsRingFaceAreas(_ ring: InternalWallsRing) -> (inner: Double, outer: Double, ceiling: Double) {
    func perimeter(_ points: [SIMD2<Float>]) -> Double {
        points.indices.reduce(0) { $0 + Double(simd_distance(points[$1], points[($1 + 1) % points.count])) }
    }
    let h = Double(ring.heightMM)
    return (perimeter(ring.inner) * h, perimeter(ring.outer) * h,
            internalWallsPolygonArea(ring.outer) - internalWallsPolygonArea(ring.inner))
}

/// Studio's estimate of the extra filament: each new face turns a band of 25% infill beside it into solid wall (the
/// slot's `infillBandMM`; for a ring, 1 mm outside and the 0.375 mm its 1.375 mm band has beyond the bore's own wall
/// inside), less the infill the slots and rings themselves replace.
func internalWallsEstimatedExtraMaterialMM3(slots: [InternalWallsSlot], rings: [InternalWallsRing]) -> Double {
    let gain = 1 - internalWallsSlantInfillFraction
    var extra = 0.0
    for slot in slots {
        let l = Double(slot.lengthMM), w = Double(slot.widthMM), h = Double(slot.heightMM)
        extra += (2 * l * h + 2 * w * h + l * w) * Double(slot.infillBandMM) * gain - slot.volumeMM3 * internalWallsSlantInfillFraction
    }
    let innerBand = Double(min(internalWallsSlantWallMM, max(0, internalWallsRingWallMM - internalWallsSlantWallMM)))
    for ring in rings {
        let faces = internalWallsRingFaceAreas(ring)
        extra += (faces.inner * innerBand + (faces.outer + faces.ceiling) * Double(internalWallsSlantWallMM)) * gain
            - ring.volumeMM3 * internalWallsSlantInfillFraction
    }
    return max(0, extra)
}

// MARK: - Engine

/// Cuts internal walls into a copy of `mesh`, which must already sit on its bed face: a flat, downward face at its
/// lowest Z. Only the kinds in `options.plan` are added. Returns a skipped result (with the reason) when no copy can be
/// made, and throws only for invalid options or when `isCancelled` reports true. A returned copy is one closed,
/// outward, sound solid with the input's shell count, bounding box and every surface except the bed face unchanged, and
/// its volume is the input's less exactly the slots' and rings'.
func internalWallsCopy(of mesh: STLMesh, options: InternalWallsOptions = InternalWallsOptions(),
                       isCancelled: () -> Bool = { false }) throws -> InternalWallsResult {
    if let problem = internalWallsOptionsProblem(options) { throw InternalWallsError.invalidOptions(problem) }
    let wallPlan = options.plan
    var skipCounts = [[Int]](repeating: [Int](repeating: 0, count: InternalWallsFeatureSkipReason.allCases.count),
                             count: InternalWallsKind.allCases.count)
    func note(_ kind: InternalWallsKind, _ reason: InternalWallsFeatureSkipReason, _ n: Int = 1) {
        guard n > 0 else { return }
        skipCounts[kind.index][reason.index] += n
    }
    func reports(slots: [InternalWallsSlot], rings: [InternalWallsRing]) -> [InternalWallsKindReport] {
        InternalWallsKind.allCases.map { kind in
            let made = kind == .holeRing ? rings.count : slots.reduce(0) { $0 + ($1.kind == kind ? 1 : 0) }
            let skipped = InternalWallsFeatureSkipReason.allCases.compactMap { reason -> InternalWallsFeatureSkip? in
                let n = skipCounts[kind.index][reason.index]
                return n > 0 ? InternalWallsFeatureSkip(reason: reason, count: n) : nil
            }
            return InternalWallsKindReport(kind: kind, planned: wallPlan.includes(kind), made: made, skipped: skipped)
        }
    }
    func skip(_ reason: InternalWallsSkipReason, shells: Int = 0, axis: InternalWallsAxis = .automatic) -> InternalWallsResult {
        InternalWallsResult(mesh: nil, data: nil, skipped: reason, slots: [], axis: axis, spacingMM: options.spacingMM,
                            removedVolumeMM3: 0, removedFraction: 0, shellsBefore: shells, shellsAfter: shells,
                            kinds: reports(slots: [], rings: []))
    }
    guard !wallPlan.isEmpty else { return skip(.nothingPlanned) }
    let count = mesh.triangleCount
    guard count <= options.maximumTriangles, count <= STLMesh.maximumTriangles else { return skip(.tooManyTriangles) }
    guard let before = analyzeMeshHealth(mesh, isCancelled: isCancelled) else { throw InternalWallsError.stopped }
    guard meshHealthIsSound(before), before.signedVolume > 0 else { return skip(.notClosedSolid, shells: before.shells) }
    let shells = before.shells
    let bounds = meshCoordinateBounds(mesh.vertices)
    let floor = bounds.low.z
    let v = mesh.vertices
    func corner(_ t: Int, _ j: Int) -> SIMD3<Float> { SIMD3(v[t * 9 + j * 3], v[t * 9 + j * 3 + 1], v[t * 9 + j * 3 + 2]) }

    // The bed face: flat, downward triangles at the lowest point.
    var isBed = [Bool](repeating: false, count: count)
    var bedArea = 0.0
    var bedLow = SIMD2<Float>(repeating: .greatestFiniteMagnitude), bedHigh = -bedLow
    for t in 0..<count {
        if t % 8192 == 0, isCancelled() { throw InternalWallsError.stopped }
        let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
        guard max(a.z, b.z, c.z) <= floor + internalWallsBedToleranceMM else { continue }
        let cross = simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))
        let length = simd_length(cross)
        guard length > 0, cross.z / length <= -0.999999 else { continue }
        isBed[t] = true
        bedArea += length / 2
        for p in [a, b, c] { bedLow = simd_min(bedLow, SIMD2(p.x, p.y)); bedHigh = simd_max(bedHigh, SIMD2(p.x, p.y)) }
    }
    guard bedArea >= internalWallsMinimumBedAreaMM2 else { return skip(.noFlatBedFace, shells: shells) }
    let extent = bedHigh - bedLow
    let axis: InternalWallsAxis = options.axis != .automatic ? options.axis : (extent.y > extent.x ? .y : .x)
    let along = axis == .y ? 1 : 0, across = 1 - along

    // Indexes: rays over every triangle (bed membership and thickness); nearest distance over all but the bed face.
    guard let rays = TriangleRayIndex(mesh, isCancelled: isCancelled), !isCancelled() else { throw InternalWallsError.stopped }
    var others: [SIMD3<Float>] = []
    others.reserveCapacity((count - isBed.filter { $0 }.count) * 3)
    for t in 0..<count where !isBed[t] { others.append(corner(t, 0)); others.append(corner(t, 1)); others.append(corner(t, 2)) }
    let nearest = InternalWallsDistanceIndex(corners: others)
    // Kept for measuring a bore's draft.
    let surfaceCorners = wallPlan.holeRings ? others : []
    others = []
    if isCancelled() { throw InternalWallsError.stopped }

    let w = options.slotWidthMM, step = internalWallsSampleStepMM
    // Every point of a slot lies within half a column, half the width and half a height step of a sample point, so a
    // sample this far from every surface but the bed keeps the whole slot `clearanceMM` away (distance is 1-Lipschitz).
    let reach = options.clearanceMM + (w * w / 4 + step * step / 4 + step * step / 4).squareRoot()
    let fine = internalWallsFineStepMM
    let narrowReach = internalWallsTargetedClearanceMM + (w * w / 4 + fine * fine / 4 + fine * fine / 4).squareRoot()
    let ringReach = options.clearanceMM + internalWallsRingSampleMarginMM
    let jumpLimit: Float = 20
    let ceiling = bounds.high.z
    let up = SIMD3<Float>(0, 0, 1)

    // Walls already planned: every later wall keeps its own clearance from them too. They are indexed in levels, as a
    // binary counter merges: each new wall is a level of its own, and levels holding as many walls as the new one are
    // merged into it and indexed again. Every wall is rebuilt about log₂ n times rather than once per later wall, and a
    // query visits about log₂ n indexes. The nearest distance is the same whichever index holds a wall.
    var featureLevels: [(walls: Int, corners: [SIMD3<Float>], index: InternalWallsDistanceIndex)] = []
    func distance(_ p: SIMD3<Float>, within limit: Float, ignoring bore: InternalWallsCylinder? = nil) -> Float {
        let surfaces = bore.map { nearest.distance(to: p, within: limit, ignoringInside: $0) } ?? nearest.distance(to: p, within: limit)
        // As `min(surfaces, index.distance(…))` over one index of every wall, which returns `limit` when empty.
        guard !featureLevels.isEmpty else { return min(surfaces, limit) }
        var nearestWall = Float.infinity
        for level in featureLevels {
            let d = level.index.distance(to: p, within: limit)
            if d < nearestWall { nearestWall = d }
        }
        return min(surfaces, nearestWall)
    }

    /// The highest clear slot top for a column at (`u` along, `p` across), or nil when the column can't take a slot.
    func columnTop(_ u: Float, _ p: Float) -> Float? {
        var base = SIMD3<Float>(0, 0, floor)
        base[along] = u; base[across] = p
        // It must start on the bed face, with material directly above it.
        guard let hit = rays.firstHit(from: base - up, along: up), isBed[hit.triangle], abs(hit.distance - 1) < 0.001 else { return nil }
        var top: Float?
        var j = 0
        while true {
            let z = floor + Float(j) * step
            guard z + step / 2 <= ceiling else { break }
            let d = distance(SIMD3(base.x, base.y, z), within: reach + jumpLimit)
            guard d >= reach else { break }
            // Clear here and, by the Lipschitz bound, at the next whole steps while d stays above `reach`.
            let skipped = max(0, Int(((d - reach) / step).rounded(.down)))
            let last = min(j + skipped, Int(((ceiling - step / 2 - floor) / step).rounded(.down)))
            top = floor + Float(last) * step + step / 2
            j = last + 1
        }
        guard var clear = top else { return nil }
        for box in options.keepClear {
            let cellLow = SIMD2<Float>(u - step / 2, p - w / 2), cellHigh = SIMD2<Float>(u + step / 2, p + w / 2)
            let boxLow = SIMD2(box.low[along], box.low[across]), boxHigh = SIMD2(box.high[along], box.high[across])
            guard cellLow.x < boxHigh.x, cellHigh.x > boxLow.x, cellLow.y < boxHigh.y, cellHigh.y > boxLow.y,
                  box.high.z > floor, box.low.z < clear else { continue }
            clear = box.low.z
        }
        guard clear - floor >= internalWallsMinimumSlotHeightMM else { return nil }
        // Thick enough both ways, measured part-way up the column.
        var probe = base
        probe.z = floor + min(1, (clear - floor) / 2)
        for axisIndex in [across, along] {
            var direction = SIMD3<Float>(repeating: 0)
            direction[axisIndex] = 1
            guard let ahead = rays.firstHit(from: probe, along: direction),
                  let behind = rays.firstHit(from: probe, along: -direction),
                  ahead.distance + behind.distance >= options.minimumRegionMM else { return nil }
        }
        return clear
    }

    /// The highest clear top of a column at `xy` for a ring, pin or thin-section slot, kept `reach` from every surface
    /// (but the bed face and `bore`'s own) at heights `columnStep` apart; `onBed` is false when the column doesn't start
    /// on the bed face. `cellHalf` is the column's half-size for keep-clear regions.
    func clearColumnTop(_ xy: SIMD2<Float>, reach: Float, columnStep: Float, cellHalf: SIMD2<Float>,
                        ignoring bore: InternalWallsCylinder? = nil) -> (top: Float?, onBed: Bool) {
        let base = SIMD3<Float>(xy.x, xy.y, floor)
        guard let hit = rays.firstHit(from: base - up, along: up), isBed[hit.triangle], abs(hit.distance - 1) < 0.001 else { return (nil, false) }
        let lastIndex = Int(((ceiling - columnStep / 2 - floor) / columnStep).rounded(.down))
        var top: Float?
        var j = 0
        while j <= lastIndex {
            let d = distance(SIMD3(xy.x, xy.y, floor + Float(j) * columnStep), within: reach + jumpLimit, ignoring: bore)
            guard d >= reach else { break }
            let last = min(j + max(0, Int(((d - reach) / columnStep).rounded(.down))), lastIndex)
            top = floor + Float(last) * columnStep + columnStep / 2
            j = last + 1
        }
        guard var clear = top else { return (nil, true) }
        for box in options.keepClear {
            guard xy.x - cellHalf.x < box.high.x, xy.x + cellHalf.x > box.low.x, xy.y - cellHalf.y < box.high.y,
                  xy.y + cellHalf.y > box.low.y, box.high.z > floor, box.low.z < clear else { continue }
            clear = box.low.z
        }
        return (clear > floor ? clear : nil, true)
    }

    /// Material intervals (entry, exit) along horizontal axis `c` of the line at `u` on the other axis, at height `z`;
    /// nil when the hits don't alternate cleanly.
    func materialIntervals(across c: Int, at u: Float, z: Float) -> [SIMD2<Float>]? {
        var origin = SIMD3<Float>(0, 0, z)
        origin[1 - c] = u
        origin[c] = bounds.low[c] - 1
        var axisDirection = SIMD3<Float>(repeating: 0)
        axisDirection[c] = 1
        let direction = axisDirection
        var intervals: [SIMD2<Float>] = []
        var travelled: Float = 0
        var entry: Float?
        for _ in 0..<256 {
            guard let hit = rays.firstHit(from: origin, along: direction, minimumDistance: travelled) else { break }
            travelled = hit.distance + 0.0001
            if hit.normal[c] < 0 {
                guard entry == nil else { return nil }
                entry = hit.distance
            } else if hit.normal[c] > 0 {
                guard let start = entry else { return nil }
                intervals.append(SIMD2(origin[c] + start * direction[c], origin[c] + hit.distance * direction[c]))
                entry = nil
            } else {
                return nil
            }
        }
        return entry == nil ? intervals : nil
    }

    func addFeature(_ append: (inout [SIMD3<Float>]) -> Void) {
        var corners: [SIMD3<Float>] = []
        append(&corners)
        var walls = 1
        while let last = featureLevels.last, last.walls <= walls {
            corners = last.corners + corners
            walls += last.walls
            featureLevels.removeLast()
        }
        featureLevels.append((walls, corners, InternalWallsDistanceIndex(corners: corners)))
    }

    let targetedBudget = options.maximumTargetedRemovedFraction * before.signedVolume
    var targetedRemoved = 0.0
    var rings: [InternalWallsRing] = []
    var narrowSlots: [InternalWallsSlot] = []
    let outline = internalWallsBedOutline(mesh, isBed: isBed)
    if isCancelled() { throw InternalWallsError.stopped }

    // 1. Hole rings round the round holes in the bed face.
    if wallPlan.holeRings {
        let bores = outline.map { internalWallsBores(points: $0.points, loops: $0.loops) } ?? []
        var holes = 0
        for bore in bores {
            if isCancelled() { throw InternalWallsError.stopped }
            guard rings.count < options.maximumRings else { note(.holeRing, .limitReached); continue }
            // A blind bore's ceiling is the first face above the bed at its centre; a through-hole has none.
            var ceilingZ: Float?
            if let hit = rays.firstHit(from: SIMD3(bore.centre.x, bore.centre.y, floor - 1), along: up) {
                // Material at the bed inside the loop, or a face that isn't a ceiling: not an open hole.
                guard hit.distance > 1.01, hit.normal.z < 0 else { continue }
                ceilingZ = floor - 1 + hit.distance
            }
            holes += 1
            var cylinder = InternalWallsCylinder(centre: bore.centre, radius: bore.radiusMM + internalWallsBoreRadiusToleranceMM)
            // A bore drawn with a little draft widens upward; its own walls stay ignored, and the ring stops where the
            // band between them would be under 1 mm.
            let draft = internalWallsBoreDraft(cylinder, corners: surfaceCorners, floor: floor)
            if draft > 0 { cylinder = InternalWallsCylinder(centre: bore.centre, radius: cylinder.radius, floorZ: floor, slope: draft) }
            let innerRadius = cylinder.radius + internalWallsRingWallMM
            let shape = internalWallsRingOutlines(centre: bore.centre, innerRadius: innerRadius, outerRadius: innerRadius + w)
            var top = Float.greatestFiniteMagnitude
            var failure: InternalWallsFeatureSkipReason?
            for sample in internalWallsRingSamples(inner: shape.inner, outer: shape.outer) {
                let column = clearColumnTop(sample, reach: ringReach, columnStep: step,
                                            cellHalf: SIMD2(repeating: internalWallsRingSampleMarginMM), ignoring: cylinder)
                guard column.onBed else { failure = .notOpenAtBed; break }
                guard let clear = column.top else { failure = .tooCloseToSurface; break }
                top = min(top, clear)
            }
            if let failure { note(.holeRing, failure); continue }
            if let ceilingZ { top = min(top, ceilingZ - internalWallsRingBlindTopClearanceMM) }
            if draft > 0 { top = min(top, floor + (internalWallsRingWallMM - internalWallsTargetedClearanceMM) / draft) }
            guard top - floor >= internalWallsMinimumSlotHeightMM else { note(.holeRing, .tooShort); continue }
            let ring = InternalWallsRing(centre: bore.centre, boreRadiusMM: bore.radiusMM, blind: ceilingZ != nil, floorZ: floor,
                                         topZ: top, inner: shape.inner, outer: shape.outer,
                                         innerRadiusMM: innerRadius, outerRadiusMM: innerRadius + w)
            guard targetedRemoved + ring.volumeMM3 <= targetedBudget else { note(.holeRing, .wouldRemoveTooMuch); continue }
            targetedRemoved += ring.volumeMM3
            rings.append(ring)
            addFeature { internalWallsAppendRingFaces(ring, to: &$0) }
        }
        if holes == 0 { note(.holeRing, .noneFound) }
    }

    // 2. Pin slots: upright pins and bosses with a flat top, through the middle along their longer side.
    if wallPlan.pinSlots {
        let candidates = internalWallsFlatTops(mesh, minimumZ: floor + internalWallsMinimumPinHeightMM + 1,
                                               isCancelled: isCancelled)
        // The search returns nothing when stopped: that is a stop, never "no pins".
        if isCancelled() { throw InternalWallsError.stopped }
        /// The section through `xy` at height `z`, from rays that must leave the material.
        func section(_ xy: SIMD2<Float>, _ z: Float) -> (low: SIMD2<Float>, high: SIMD2<Float>)? {
            let p = SIMD3<Float>(xy.x, xy.y, z)
            var low = xy, high = xy
            for axisIndex in 0..<2 {
                for sign: Float in [1, -1] {
                    var axisDirection = SIMD3<Float>(repeating: 0)
                    axisDirection[axisIndex] = sign
                    let direction = axisDirection
                    guard let hit = rays.firstHit(from: p, along: direction), simd_dot(hit.normal, direction) > 0 else { return nil }
                    if sign > 0 { high[axisIndex] = xy[axisIndex] + hit.distance } else { low[axisIndex] = xy[axisIndex] - hit.distance }
                }
            }
            return (low, high)
        }
        let widest = internalWallsPinWidthRangeMM.upperBound + 0.5
        var centres: [SIMD2<Float>] = []
        var pinsFound = 0
        for top in candidates {
            if isCancelled() { throw InternalWallsError.stopped }
            // Centre the probe from below the top, where a chamfer has ended.
            let probeZ = top.z - 0.75
            guard probeZ > floor else { continue }
            guard var s = section(top.centre, probeZ) else {
                // A hollow boss: its flat top is a ring, and its middle is the hole. A slot through the middle would
                // cut into the hole, so it gets none, and says why.
                let middle = SIMD3<Float>(top.centre.x, top.centre.y, probeZ)
                let above = rays.firstHit(from: middle, along: up)
                if above.map({ $0.normal.z < 0 }) ?? true, top.size.max() <= widest {
                    pinsFound += 1
                    note(.pinSlot, .hollow)
                }
                continue
            }
            var centre = SIMD2<Float>((s.low.x + s.high.x) / 2, top.centre.y)
            guard let sy = section(centre, probeZ) else { continue }
            centre.y = (sy.low.y + sy.high.y) / 2
            guard let settled = section(centre, probeZ) else { continue }
            s = settled
            centre = (s.low + s.high) / 2
            // Compact both ways: diagonals no longer than the widest pin's.
            var compact = true
            for diagonal in [SIMD2<Float>(1, 1), SIMD2(1, -1)] {
                let d = SIMD3<Float>(diagonal.x, diagonal.y, 0) / Float(2).squareRoot()
                let p = SIMD3<Float>(centre.x, centre.y, probeZ)
                guard let ahead = rays.firstHit(from: p, along: d), let behind = rays.firstHit(from: p, along: -d),
                      ahead.distance + behind.distance <= widest * Float(2).squareRoot() else { compact = false; break }
            }
            guard compact else { continue }
            // Down the pin to where it widens into the region it rises from, or to the bed.
            var root = floor
            var size = s.high - s.low
            var z = probeZ - 0.5
            while z >= floor + 0.25 {
                guard let here = section(centre, z) else { root = z + 0.25; break }
                let dims = here.high - here.low
                guard dims.x <= widest, dims.y <= widest else { root = z + 0.25; break }
                size = simd_max(size, dims)
                z -= 0.5
            }
            guard top.z - root >= internalWallsMinimumPinHeightMM,
                  size.x >= internalWallsPinWidthRangeMM.lowerBound - 0.01, size.y >= internalWallsPinWidthRangeMM.lowerBound - 0.01,
                  size.x <= internalWallsPinWidthRangeMM.upperBound + 0.01, size.y <= internalWallsPinWidthRangeMM.upperBound + 0.01,
                  !centres.contains(where: { simd_distance($0, centre) < 1 }) else { continue }
            centres.append(centre)
            pinsFound += 1
            guard narrowSlots.count < options.maximumPinSlots else { note(.pinSlot, .limitReached); continue }
            // Along the longer side (X unless Y is clearly longer), through the middle.
            let a = size.y > size.x + 0.05 ? 1 : 0, c = 1 - a
            let half = Int((size[a] / 2 / fine).rounded(.down))
            var tops = [Float?](repeating: nil, count: 2 * half + 1)
            var centreOnBed = true
            for k in -half...half {
                var xy = centre
                xy[a] = centre[a] + Float(k) * fine
                var cell = SIMD2<Float>(repeating: 0)
                cell[a] = fine / 2; cell[c] = w / 2
                let column = clearColumnTop(xy, reach: narrowReach, columnStep: fine, cellHalf: cell)
                if k == 0 { centreOnBed = column.onBed }
                tops[k + half] = column.top
            }
            guard let centreTop = tops[half] else { note(.pinSlot, centreOnBed ? .tooCloseToSurface : .notOpenAtBed); continue }
            var first = half, last = half
            while first > 0, let t = tops[first - 1], abs(t - centreTop) <= internalWallsHeightSplitMM { first -= 1 }
            while last < 2 * half, let t = tops[last + 1], abs(t - centreTop) <= internalWallsHeightSplitMM { last += 1 }
            let slotTop = tops[first...last].compactMap { $0 }.min() ?? centreTop
            let start = centre[a] + Float(first - half) * fine - fine / 2, end = centre[a] + Float(last - half) * fine + fine / 2
            guard end - start >= internalWallsMinimumPinSlotLengthMM - 1e-4 else { note(.pinSlot, .tooCloseToSurface); continue }
            guard slotTop - floor >= internalWallsMinimumSlotHeightMM, slotTop >= root + 1 else { note(.pinSlot, .tooShort); continue }
            var low = SIMD3<Float>(0, 0, floor), high = SIMD3<Float>(0, 0, slotTop)
            low[a] = start; high[a] = end
            low[c] = centre[c] - w / 2; high[c] = centre[c] + w / 2
            let band = min(internalWallsSlantWallMM, max(0, (size[c] - w) / 2 - internalWallsSlantWallMM))
            let slot = InternalWallsSlot(low: low, high: high, lengthMM: end - start, widthMM: w, kind: .pinSlot, infillBandMM: band)
            guard targetedRemoved + slot.volumeMM3 <= targetedBudget else { note(.pinSlot, .wouldRemoveTooMuch); continue }
            targetedRemoved += slot.volumeMM3
            narrowSlots.append(slot)
            addFeature { internalWallsAppendBoxFaces(slot, to: &$0) }
        }
        if pinsFound == 0 { note(.pinSlot, .noneFound) }
    }

    // 3. Thin-section slots: one along the middle of each straight section 2.5–5 mm thick, found by scanning across
    // the bed at a few heights.
    if wallPlan.thinSlots {
        struct Line {
            let axis: Int
            let mid: Float
            let thickness: Float
            let usable: Bool
            /// The probe height index each scan column first saw this line at, or -1.
            var columns: [Int8]
        }
        var lines: [Line] = []
        var lineAt: [SIMD3<Int>: Int] = [:]
        let heights = internalWallsThinProbeHeightsMM
        for a in 0..<2 {
            let c = 1 - a
            let columnCount = max(0, Int((extent[a] / step).rounded(.down)))
            guard columnCount > 0 else { continue }
            for (h, height) in heights.enumerated() where floor + height < ceiling - 0.5 {
                for i in 0..<columnCount {
                    if i % 64 == 0, isCancelled() { throw InternalWallsError.stopped }
                    let u = bedLow[a] + (Float(i) + 0.5) * step
                    guard let intervals = materialIntervals(across: c, at: u, z: floor + height) else { continue }
                    for interval in intervals {
                        let t = interval.y - interval.x
                        let usable = t >= internalWallsThinMinimumMM && t < options.minimumRegionMM
                        guard usable || (t >= internalWallsThinTooThinFromMM && t < internalWallsThinMinimumMM) else { continue }
                        let mid = (interval.x + interval.y) / 2
                        let key = Int((mid / 0.01).rounded())
                        var found: Int?
                        for k in [key, key - 1, key + 1] {
                            if let index = lineAt[SIMD3(a, k, usable ? 1 : 0)], abs(lines[index].mid - mid) <= 0.02 { found = index; break }
                        }
                        if found == nil {
                            guard lines.count < internalWallsMaximumThinLines else { continue }
                            lines.append(Line(axis: a, mid: mid, thickness: t, usable: usable, columns: [Int8](repeating: -1, count: columnCount)))
                            lineAt[SIMD3(a, key, usable ? 1 : 0)] = lines.count - 1
                            found = lines.count - 1
                        }
                        if let index = found, lines[index].columns[i] < 0 { lines[index].columns[i] = Int8(h) }
                    }
                }
            }
        }
        let minimumColumns = Int((internalWallsMinimumThinRunMM / step).rounded(.up))
        var sectionsFound = 0
        var tooThin: [(axis: Int, mid: Float)] = []
        var thinCount = 0
        for line in lines {
            if isCancelled() { throw InternalWallsError.stopped }
            guard line.columns.reduce(0, { $0 + ($1 >= 0 ? 1 : 0) }) >= minimumColumns else { continue }
            guard line.usable else { tooThin.append((line.axis, line.mid)); continue }
            let a = line.axis, c = 1 - a
            var tops = [Float?](repeating: nil, count: 2 * line.columns.count)
            var verified = false, onBed = false, clearAnywhere = false
            for i in line.columns.indices where line.columns[i] >= 0 {
                let z = floor + heights[Int(line.columns[i])]
                for half in 0..<2 {
                    let k = 2 * i + half
                    let u = bedLow[a] + fine / 2 + Float(k) * fine
                    // Still this thin section here, not where it joins a thicker one.
                    guard let intervals = materialIntervals(across: c, at: u, z: z),
                          let interval = intervals.first(where: { $0.x < line.mid && line.mid < $0.y }),
                          interval.y - interval.x >= internalWallsThinMinimumMM, interval.y - interval.x < options.minimumRegionMM,
                          abs((interval.x + interval.y) / 2 - line.mid) <= 0.02 else { continue }
                    verified = true
                    var xy = SIMD2<Float>(repeating: 0)
                    xy[a] = u; xy[c] = line.mid
                    var cell = SIMD2<Float>(repeating: 0)
                    cell[a] = fine / 2; cell[c] = w / 2
                    let column = clearColumnTop(xy, reach: narrowReach, columnStep: fine, cellHalf: cell)
                    if column.onBed { onBed = true }
                    guard let top = column.top else { continue }
                    clearAnywhere = true
                    if top - floor >= internalWallsMinimumSlotHeightMM { tops[k] = top }
                }
            }
            guard verified else { continue }
            sectionsFound += 1
            let band = min(internalWallsSlantWallMM, max(0, (line.thickness - w) / 2 - internalWallsSlantWallMM))
            let runs = internalWallsRuns(tops: tops, start: bedLow[a] + fine / 2, step: fine, across: line.mid, along: a,
                                         floor: floor, width: w, minimumLength: internalWallsMinimumSlotLengthMM,
                                         kind: .thinSlot, infillBand: band)
            guard !runs.isEmpty else {
                note(.thinSlot, !onBed ? .notOpenAtBed : (clearAnywhere ? .tooShort : .tooCloseToSurface))
                continue
            }
            var added: [InternalWallsSlot] = []
            for slot in runs {
                guard thinCount < options.maximumThinSlots else { note(.thinSlot, .limitReached); continue }
                guard targetedRemoved + slot.volumeMM3 <= targetedBudget else { note(.thinSlot, .wouldRemoveTooMuch); continue }
                targetedRemoved += slot.volumeMM3
                thinCount += 1
                added.append(slot)
            }
            guard !added.isEmpty else { continue }
            narrowSlots.append(contentsOf: added)
            addFeature { list in for slot in added { internalWallsAppendBoxFaces(slot, to: &list) } }
        }
        // Too-thin sections are counted once each, and not where a usable line runs at the same place.
        var thinSkips = 0
        for (index, section) in tooThin.enumerated() {
            let repeated = tooThin[..<index].contains { $0.axis == section.axis && abs($0.mid - section.mid) <= 0.05 }
            let served = narrowSlots.contains { slot in
                guard slot.kind == .thinSlot else { return false }
                let c = 1 - section.axis
                return slot.high[section.axis] - slot.low[section.axis] > slot.high[c] - slot.low[c]
                    && abs((slot.low[c] + slot.high[c]) / 2 - section.mid) <= 0.05
            }
            if !repeated, !served { thinSkips += 1 }
        }
        note(.thinSlot, .tooThin, thinSkips)
        if sectionsFound == 0, thinSkips == 0 { note(.thinSlot, .noneFound) }
    }

    // 4. Slots in thick regions, kept clear of everything above.
    let lowAlong = bedLow[along], spanAlong = extent[along]
    let lowAcross = bedLow[across], spanAcross = extent[across]
    let columnCount = max(0, Int((spanAlong / step).rounded(.down)))
    let columnStart = lowAlong + (spanAlong - Float(columnCount) * step) / 2 + step / 2

    /// Slots for one spacing: lines centred across the bed footprint, columns merged into runs.
    func bulkPlan(spacing: Float) throws -> [InternalWallsSlot] {
        let usable = spanAcross - 2 * reach
        guard usable >= 0, columnCount > 0 else { return [] }
        let lineCount = Int((usable / spacing).rounded(.down)) + 1
        let firstLine = lowAcross + reach + (usable - Float(lineCount - 1) * spacing) / 2
        var slots: [InternalWallsSlot] = []
        for line in 0..<lineCount {
            let p = firstLine + Float(line) * spacing
            var tops: [Float?] = []
            tops.reserveCapacity(columnCount)
            for i in 0..<columnCount {
                if i % 64 == 0, isCancelled() { throw InternalWallsError.stopped }
                tops.append(columnTop(columnStart + Float(i) * step, p))
            }
            slots += internalWallsRuns(tops: tops, start: columnStart, step: step, across: p, along: along, floor: floor,
                                       width: w, minimumLength: internalWallsMinimumSlotLengthMM, kind: .bulkSlot,
                                       infillBand: internalWallsSlantWallMM)
        }
        return slots
    }

    var spacing = options.spacingMM
    var slots: [InternalWallsSlot] = []
    var bulkReason: InternalWallsSkipReason?
    func removed(_ list: [InternalWallsSlot]) -> Double { list.reduce(0) { $0 + $1.volumeMM3 } }
    if wallPlan.bulkSlots {
        slots = try bulkPlan(spacing: spacing)
        var attempts = 0
        while !slots.isEmpty, removed(slots) / before.signedVolume > options.maximumRemovedFraction {
            attempts += 1
            // Removal falls roughly with the spacing; jump close to the cap, then widen in 0.5 mm steps.
            let fraction = removed(slots) / before.signedVolume
            let estimate = spacing * Float(fraction / options.maximumRemovedFraction)
            let widened = attempts == 1 ? max(spacing + 0.5, (estimate / 0.5).rounded(.down) * 0.5) : spacing + 0.5
            guard attempts <= 40, widened <= 50 else { slots = []; bulkReason = .wouldRemoveTooMuch; break }
            spacing = widened
            slots = try bulkPlan(spacing: spacing)
        }
        if slots.isEmpty, bulkReason == nil { bulkReason = .noRegionThickEnough }
        if let bulkReason { note(.bulkSlot, bulkReason == .wouldRemoveTooMuch ? .wouldRemoveTooMuch : .noneFound) }
    }
    // A stop during planning is a stop, never a plan that found nothing (a time limit must save nothing).
    if isCancelled() { throw InternalWallsError.stopped }
    var boxes = narrowSlots + slots
    guard !boxes.isEmpty || !rings.isEmpty else {
        let bulkOnly = !wallPlan.holeRings && !wallPlan.pinSlots && !wallPlan.thinSlots
        return skip(bulkOnly ? (bulkReason ?? .noRegionThickEnough) : .noFeatureSuitable, shells: shells, axis: axis)
    }

    // An opening that can't be joined into the bed face's fill is left out, and the rest assembled again, at most
    // `internalWallsMaximumDroppedSlots` times: each attempt re-assembles the whole bed face.
    var corners: [SIMD3<Float>] = []
    var dropped = 0
    assembly: while true {
        guard let outline else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
        switch try slottedCorners(mesh, isBed: isBed, outline: outline, slots: boxes, rings: rings, isCancelled: isCancelled) {
        case .corners(let list): corners = list; break assembly
        case .unjoinableSlot(let slot):
            dropped += 1
            guard dropped <= internalWallsMaximumDroppedSlots else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
            note(boxes[slot].kind, .couldNotJoin)
            boxes.remove(at: slot)
        case .unjoinableRing(let ring):
            dropped += 1
            guard dropped <= internalWallsMaximumDroppedSlots else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
            note(.holeRing, .couldNotJoin)
            rings.remove(at: ring)
        case .failed: return skip(.resultFailedChecks, shells: shells, axis: axis)
        }
        guard !boxes.isEmpty || !rings.isEmpty else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
    }
    let removedVolume = removed(boxes) + rings.reduce(0) { $0 + $1.volumeMM3 }
    guard corners.count / 3 <= STLMesh.maximumTriangles else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
    var floats: [Float] = []
    floats.reserveCapacity(corners.count * 3)
    for p in corners { floats.append(p.x); floats.append(p.y); floats.append(p.z) }
    guard let assembled = try? STLMesh.validated(floats) else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
    let data = assembled.binarySTL()
    guard let parsed = try? STLMesh.parse(data), parsed.triangleCount == corners.count / 3 else {
        return skip(.resultFailedChecks, shells: shells, axis: axis)
    }
    guard let after = analyzeMeshHealth(parsed, isCancelled: isCancelled) else { throw InternalWallsError.stopped }
    guard parsed.minimum == bounds.low, parsed.maximum == bounds.high else { return skip(.resultFailedChecks, shells: shells, axis: axis) }
    if let problem = internalWallsResultProblem(before: before, after: after, removedVolume: removedVolume) {
        return skip(problem, shells: shells, axis: axis)
    }
    var surfaceArea = 0.0
    for t in 0..<count {
        let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
        surfaceArea += simd_length(simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))) / 2
    }
    let extra = internalWallsEstimatedExtraMaterialMM3(slots: boxes, rings: rings)
    let baseline = internalWallsBaselineMaterialMM3(volumeMM3: before.signedVolume, surfaceAreaMM2: surfaceArea)
    return InternalWallsResult(mesh: parsed, data: data, skipped: nil, slots: boxes, axis: axis, spacingMM: spacing,
                               removedVolumeMM3: removedVolume, removedFraction: removedVolume / before.signedVolume,
                               shellsBefore: shells, shellsAfter: after.shells, droppedSlots: dropped, rings: rings,
                               kinds: reports(slots: boxes, rings: rings),
                               addedSurfaceAreaMM2: internalWallsAddedSurfaceAreaMM2(slots: boxes, rings: rings),
                               estimatedExtraMaterialMM3: extra,
                               estimatedExtraMaterialFraction: baseline > 0 ? extra / baseline : 0)
}

/// Columns' clear tops on one line merged into slots: adjacent columns join while their tops stay within
/// `internalWallsHeightSplitMM`, each slot takes its lowest top, slots on a line stay at least 1 mm apart, and runs
/// shorter than `minimumLength` are left out. Column `i` is centred at `start + i × step` along axis `along`.
func internalWallsRuns(tops: [Float?], start columnStart: Float, step: Float, across p: Float, along: Int, floor: Float,
                       width w: Float, minimumLength: Float, kind: InternalWallsKind, infillBand: Float) -> [InternalWallsSlot] {
    let across = 1 - along
    var slots: [InternalWallsSlot] = []
    var first = -1, last = -1, lowest: Float = 0, highest: Float = 0
    // Slots on one line stay at least 1 mm apart, so a thin web is never left between them.
    let gap = Int((1 / step).rounded(.up)) + 1
    var previousLast = -gap
    func close() {
        defer { first = -1 }
        guard first >= 0 else { return }
        previousLast = last
        let start = columnStart + Float(first) * step - step / 2, end = columnStart + Float(last) * step + step / 2
        guard end - start >= minimumLength - 1e-4 else { return }
        var low = SIMD3<Float>(0, 0, floor), high = SIMD3<Float>(0, 0, lowest)
        low[along] = start; high[along] = end
        low[across] = p - w / 2; high[across] = p + w / 2
        slots.append(InternalWallsSlot(low: low, high: high, lengthMM: end - start, widthMM: w, kind: kind, infillBandMM: infillBand))
    }
    for i in tops.indices {
        guard let top = tops[i] else { close(); continue }
        if first >= 0 {
            if max(highest, top) - min(lowest, top) <= internalWallsHeightSplitMM {
                last = i; lowest = min(lowest, top); highest = max(highest, top)
                continue
            }
            // A step in height ends this slot; the next starts after the gap.
            close()
        }
        guard i >= previousLast + gap else { continue }
        first = i; last = i; lowest = top; highest = top
    }
    close()
    return slots
}

/// A flat, upward face that might be a pin's top: its outline's centre, size and height.
struct InternalWallsFlatTop: Equatable, Sendable {
    let centre: SIMD2<Float>
    let size: SIMD2<Float>
    let z: Float
}

/// Connected flat, upward faces no wider than a pin (8.5 mm each way) at or above `minimumZ`, in the order of their
/// first triangle, at most `internalWallsMaximumPinCandidates`.
func internalWallsFlatTops(_ mesh: STLMesh, minimumZ: Float, isCancelled: () -> Bool = { false }) -> [InternalWallsFlatTop] {
    let v = mesh.vertices, count = mesh.triangleCount
    func corner(_ t: Int, _ j: Int) -> SIMD3<Float> { SIMD3(v[t * 9 + j * 3] + 0, v[t * 9 + j * 3 + 1] + 0, v[t * 9 + j * 3 + 2] + 0) }
    var parent = [Int32](repeating: -1, count: count)
    func find(_ t: Int) -> Int {
        var x = t
        while Int(parent[x]) != x { parent[x] = parent[Int(parent[x])]; x = Int(parent[x]) }
        return x
    }
    var owner: [SIMD3<Float>: Int] = [:]
    for t in 0..<count {
        if t % 8192 == 0, isCancelled() { return [] }
        let a = corner(t, 0), b = corner(t, 1), c = corner(t, 2)
        guard min(a.z, b.z, c.z) >= minimumZ, max(a.z, b.z, c.z) - min(a.z, b.z, c.z) <= 0.0001 else { continue }
        let cross = simd_cross(SIMD3<Double>(b - a), SIMD3<Double>(c - a))
        let length = simd_length(cross)
        guard length > 0, cross.z / length >= 0.999999 else { continue }
        parent[t] = Int32(t)
        for p in [a, b, c] {
            if let other = owner[p] {
                let x = find(t), y = find(other)
                // The lower index is the root, so components are named by their first triangle.
                if x != y { if x < y { parent[y] = Int32(x) } else { parent[x] = Int32(y) } }
            } else {
                owner[p] = t
            }
        }
    }
    var componentOf: [Int: Int] = [:]
    var lows: [SIMD2<Float>] = [], highs: [SIMD2<Float>] = [], heights: [Float] = []
    for t in 0..<count where parent[t] >= 0 {
        let root = find(t)
        let index: Int
        if let known = componentOf[root] { index = known } else {
            index = lows.count
            componentOf[root] = index
            lows.append(SIMD2(repeating: .greatestFiniteMagnitude)); highs.append(SIMD2(repeating: -.greatestFiniteMagnitude))
            heights.append(corner(t, 0).z)
        }
        for j in 0..<3 {
            let p = corner(t, j)
            lows[index] = simd_min(lows[index], SIMD2(p.x, p.y)); highs[index] = simd_max(highs[index], SIMD2(p.x, p.y))
        }
    }
    var tops: [InternalWallsFlatTop] = []
    let widest = internalWallsPinWidthRangeMM.upperBound + 0.5
    for index in lows.indices {
        let size = highs[index] - lows[index]
        guard size.x <= widest, size.y <= widest else { continue }
        tops.append(InternalWallsFlatTop(centre: (lows[index] + highs[index]) / 2, size: size, z: heights[index]))
        if tops.count >= internalWallsMaximumPinCandidates { break }
    }
    return tops
}

/// Validates `internalWallsCopy`'s result: it must be sound, no worse than the input, with the same shell count, and
/// its volume must fall by the slots' and rings' volume (a check on the assembly, independent of how it was built).
func internalWallsResultProblem(before: MeshHealthReport, after: MeshHealthReport, removedVolume: Double) -> InternalWallsSkipReason? {
    guard meshHealthIsSound(after), !meshToolMadeWorse(before: before, after: after), after.signedVolume > 0 else { return .resultFailedChecks }
    guard after.shells == before.shells else { return .wouldChangeShellCount }
    guard abs((before.signedVolume - after.signedVolume) - removedVolume) <= max(0.05, removedVolume * 0.005) else { return .resultFailedChecks }
    return nil
}

/// The bed face's outline: its corners welded in first-seen order, and its loops of directed edges whose reverse
/// isn't a bed edge (the outer outline clockwise seen from above, holes anticlockwise). Nil when the outline doesn't
/// form simple loops.
func internalWallsBedOutline(_ mesh: STLMesh, isBed: [Bool]) -> (points: [SIMD3<Float>], loops: [[Int]])? {
    let v = mesh.vertices, count = mesh.triangleCount
    func corner(_ t: Int, _ j: Int) -> SIMD3<Float> { SIMD3(v[t * 9 + j * 3] + 0, v[t * 9 + j * 3 + 1] + 0, v[t * 9 + j * 3 + 2] + 0) }
    var lookup: [SIMD3<Float>: Int] = [:]
    var points: [SIMD3<Float>] = []
    var edges: [SIMD2<Int>] = []
    for t in 0..<count where isBed[t] {
        let ids = (0..<3).map { j -> Int in
            let p = corner(t, j)
            if let id = lookup[p] { return id }
            lookup[p] = points.count
            points.append(p)
            return points.count - 1
        }
        for j in 0..<3 { edges.append(SIMD2(ids[j], ids[(j + 1) % 3])) }
    }
    let edgeSet = Set(edges)
    // Each outline point must start exactly one outline edge.
    var next = [Int](repeating: -1, count: points.count)
    var starts: [Int] = []
    for edge in edges where !edgeSet.contains(SIMD2(edge.y, edge.x)) {
        guard next[edge.x] < 0 else { return nil }
        next[edge.x] = edge.y
        starts.append(edge.x)
    }
    var visited = [Bool](repeating: false, count: points.count)
    var loops: [[Int]] = []
    for start in starts where !visited[start] {
        var loop: [Int] = []
        var p = start
        while !visited[p] {
            visited[p] = true
            loop.append(p)
            p = next[p]
            guard p >= 0 else { return nil }
        }
        guard p == start, loop.count >= 3 else { return nil }
        loops.append(loop)
    }
    return (points, loops)
}

private enum SlottedAssembly {
    case corners([SIMD3<Float>])
    /// This slot's or ring's opening couldn't be joined into the bed face's fill.
    case unjoinableSlot(Int)
    case unjoinableRing(Int)
    case failed
}

/// Appends a planar quad as two triangles facing `n`.
private func internalWallsAppendQuad(_ corners: inout [SIMD3<Float>], _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                                     _ c: SIMD3<Float>, _ d: SIMD3<Float>, facing n: SIMD3<Float>) {
    if simd_dot(simd_cross(b - a, c - a), n) >= 0 {
        corners.append(contentsOf: [a, b, c, a, c, d])
    } else {
        corners.append(contentsOf: [a, c, b, a, d, c])
    }
}

/// A slot's four walls and ceiling, each facing into the slot.
func internalWallsAppendBoxFaces(_ slot: InternalWallsSlot, to corners: inout [SIMD3<Float>]) {
    let l = slot.low, h = slot.high
    let p000 = SIMD3(l.x, l.y, l.z), p100 = SIMD3(h.x, l.y, l.z), p110 = SIMD3(h.x, h.y, l.z), p010 = SIMD3(l.x, h.y, l.z)
    let p001 = SIMD3(l.x, l.y, h.z), p101 = SIMD3(h.x, l.y, h.z), p111 = SIMD3(h.x, h.y, h.z), p011 = SIMD3(l.x, h.y, h.z)
    internalWallsAppendQuad(&corners, p000, p100, p101, p001, facing: SIMD3(0, 1, 0))
    internalWallsAppendQuad(&corners, p010, p011, p111, p110, facing: SIMD3(0, -1, 0))
    internalWallsAppendQuad(&corners, p000, p001, p011, p010, facing: SIMD3(1, 0, 0))
    internalWallsAppendQuad(&corners, p100, p110, p111, p101, facing: SIMD3(-1, 0, 0))
    internalWallsAppendQuad(&corners, p001, p101, p111, p011, facing: SIMD3(0, 0, -1))
}

/// A ring's inner and outer walls and ceiling, each facing into the gap.
func internalWallsAppendRingFaces(_ ring: InternalWallsRing, to corners: inout [SIMD3<Float>]) {
    let z0 = ring.floorZ, z1 = ring.topZ
    for k in ring.inner.indices {
        let next = (k + 1) % ring.inner.count
        let i0 = ring.inner[k], i1 = ring.inner[next], o0 = ring.outer[k], o1 = ring.outer[next]
        let middle = (i0 + i1) / 2 - ring.centre
        let outward = SIMD3<Float>(middle.x, middle.y, 0)
        internalWallsAppendQuad(&corners, SIMD3(i0, z0), SIMD3(i1, z0), SIMD3(i1, z1), SIMD3(i0, z1), facing: outward)
        internalWallsAppendQuad(&corners, SIMD3(o0, z0), SIMD3(o1, z0), SIMD3(o1, z1), SIMD3(o0, z1), facing: -outward)
        internalWallsAppendQuad(&corners, SIMD3(i0, z1), SIMD3(i1, z1), SIMD3(o1, z1), SIMD3(o0, z1), facing: SIMD3(0, 0, -1))
    }
}

/// Every non-bed triangle in input order, then the bed face re-triangulated with an opening per slot and ring, then
/// each slot's walls and ceiling and each ring's walls and ceiling, facing into them.
private func slottedCorners(_ mesh: STLMesh, isBed: [Bool], outline: (points: [SIMD3<Float>], loops: [[Int]]),
                            slots: [InternalWallsSlot], rings: [InternalWallsRing],
                            isCancelled: () -> Bool) throws -> SlottedAssembly {
    let v = mesh.vertices, count = mesh.triangleCount
    func corner(_ t: Int, _ j: Int) -> SIMD3<Float> { SIMD3(v[t * 9 + j * 3] + 0, v[t * 9 + j * 3 + 1] + 0, v[t * 9 + j * 3 + 2] + 0) }
    var corners: [SIMD3<Float>] = []
    corners.reserveCapacity(count * 3 + slots.count * 60 + rings.reduce(0) { $0 + $1.inner.count * 36 })
    for t in 0..<count where !isBed[t] { corners.append(corner(t, 0)); corners.append(corner(t, 1)); corners.append(corner(t, 2)) }
    if isCancelled() { throw InternalWallsError.stopped }
    let points = outline.points
    var loops = outline.loops
    // Mirrored in X, so the downward bed reads anticlockwise, as the flat base cap does. Slot holes and each ring's
    // outer outline follow, clockwise once mirrored; each ring's inner outline is the outline of the band round its
    // bore, anticlockwise once mirrored, and the bore's own loop becomes a hole in it.
    let bedLoops = loops.count
    var planar = points.map { SIMD2<Double>(-Double($0.x), Double($0.y)) }
    var where3D = points
    for slot in slots {
        let base = planar.count
        let rectangle = [SIMD2(slot.low.x, slot.low.y), SIMD2(slot.high.x, slot.low.y),
                         SIMD2(slot.high.x, slot.high.y), SIMD2(slot.low.x, slot.high.y)]
        for q in rectangle {
            planar.append(SIMD2(-Double(q.x), Double(q.y)))
            where3D.append(SIMD3(q.x, q.y, slot.low.z))
        }
        loops.append([base, base + 1, base + 2, base + 3])
    }
    for ring in rings {
        for loop in [ring.outer, Array(ring.inner.reversed())] {
            let base = planar.count
            for q in loop {
                planar.append(SIMD2(-Double(q.x), Double(q.y)))
                where3D.append(SIMD3(q.x, q.y, ring.floorZ))
            }
            loops.append(Array(base..<(base + loop.count)))
        }
    }
    // Holes are joined to their outlines here, each bridge ending at a point no other bridge uses, so the filled
    // outlines never repeat a point more than twice; the shared filler then sees no holes.
    let bridging = try internalWallsBridgedLoops(points: planar, loops: loops, isCancelled: isCancelled)
    if isCancelled() { throw InternalWallsError.stopped }
    guard let merged = bridging.loops else {
        // An exhausted work budget is a failure for the whole plan, never a reason to drop one slot and try again.
        if bridging.workLimitReached { return .failed }
        if let hole = bridging.unjoinedLoop, hole >= bedLoops {
            let index = hole - bedLoops
            return index < slots.count ? .unjoinableSlot(index) : .unjoinableRing((index - slots.count) / 2)
        }
        return .failed
    }
    guard let triangles = try? triangulatePlanarRegion(points: planar, loops: merged, isCancelled: isCancelled) else {
        if isCancelled() { throw InternalWallsError.stopped }
        return .failed
    }
    for t in triangles { corners.append(where3D[Int(t.x)]); corners.append(where3D[Int(t.y)]); corners.append(where3D[Int(t.z)]) }
    for slot in slots { internalWallsAppendBoxFaces(slot, to: &corners) }
    for ring in rings { internalWallsAppendRingFaces(ring, to: &corners) }
    return .corners(corners)
}

/// Joins every clockwise hole loop to the anticlockwise outline that most tightly contains it, in the style of the
/// flat base cap's filler: holes rightmost first, each by a two-way cut to the nearest outline point it can see without
/// touching any edge of the outline, this hole or the holes still to be joined. Unlike that filler, a cut may start at
/// any of the hole's points, and never ends at a point an earlier cut used, so no point appears more than twice in a
/// filled outline. Returns the joined outlines, or the index of the first loop that couldn't be joined, with
/// `workLimitReached` when it stopped because the work budget ran out (a failure, not an unjoinable hole).
///
/// Only the `internalWallsBridgeCandidatesPerPoint` nearest outline points of each hole point are tried, so the
/// candidates sorted per hole stay bounded however large the outline grows; distance computations, the sort and the
/// visibility tests all count against `workLimit`. Throws `InternalWallsError.stopped` when `isCancelled` reports true.
func internalWallsBridgedLoops(points: [SIMD2<Double>], loops: [[Int]], workLimit: Int = 200_000_000,
                               candidatesPerPoint: Int = internalWallsBridgeCandidatesPerPoint,
                               isCancelled: () -> Bool = { false }) throws -> (loops: [[Int]]?, unjoinedLoop: Int?, workLimitReached: Bool) {
    func area(_ loop: [Int]) -> Double {
        var sum = 0.0
        for i in loop.indices {
            let p = points[loop[i]], q = points[loop[(i + 1) % loop.count]]
            sum += p.x * q.y - q.x * p.y
        }
        return sum / 2
    }
    func contains(_ loop: [Int], _ point: SIMD2<Double>) -> Bool {
        var inside = false
        var j = loop.count - 1
        for i in loop.indices {
            let a = points[loop[i]], b = points[loop[j]]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
    func orient(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double { (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) }
    func onSegment(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Bool {
        min(a.x, b.x) <= c.x && c.x <= max(a.x, b.x) && min(a.y, b.y) <= c.y && c.y <= max(a.y, b.y)
    }
    func touch(_ p1: SIMD2<Double>, _ p2: SIMD2<Double>, _ q1: SIMD2<Double>, _ q2: SIMD2<Double>) -> Bool {
        let d1 = orient(q1, q2, p1), d2 = orient(q1, q2, p2), d3 = orient(p1, p2, q1), d4 = orient(p1, p2, q2)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
        if d1 == 0, onSegment(q1, q2, p1) { return true }
        if d2 == 0, onSegment(q1, q2, p2) { return true }
        if d3 == 0, onSegment(p1, p2, q1) { return true }
        if d4 == 0, onSegment(p1, p2, q2) { return true }
        return false
    }
    let areas = loops.map(area)
    if let flat = areas.firstIndex(where: { !($0 != 0 && $0.isFinite) }) { return (nil, flat, false) }
    let outers = loops.indices.filter { areas[$0] > 0 }
    var holesOf = [[Int]](repeating: [], count: loops.count)
    for hole in loops.indices where areas[hole] < 0 {
        let probe = points[loops[hole][0]]
        guard let owner = outers.filter({ contains(loops[$0], probe) }).min(by: { (areas[$0], $0) < (areas[$1], $1) }) else {
            return (nil, hole, false)
        }
        holesOf[owner].append(hole)
    }
    var work = 0
    var result: [[Int]] = []
    for outer in outers {
        var polygon = loops[outer]
        // Lookups only: points already at the end of a cut.
        var used = Set<Int>()
        let holes = holesOf[outer].sorted {
            let a = loops[$0].map { points[$0].x }.max()!, b = loops[$1].map { points[$0].x }.max()!
            return a != b ? a > b : $0 < $1
        }
        for (position, holeIndex) in holes.enumerated() {
            let hole = loops[holeIndex]
            var edges: [(SIMD2<Double>, SIMD2<Double>)] = []
            for loop in [polygon, hole] + holes[(position + 1)...].map({ loops[$0] }) {
                for i in loop.indices { edges.append((points[loop[i]], points[loop[(i + 1) % loop.count]])) }
            }
            if isCancelled() { throw InternalWallsError.stopped }
            // The nearest few outline points of each hole point, kept in order by (distance, from, to).
            typealias Pair = (distance: Double, from: Int, to: Int)
            func before(_ a: Pair, _ b: Pair) -> Bool { (a.distance, a.from, a.to) < (b.distance, b.from, b.to) }
            var pairs: [Pair] = []
            for from in hole.indices {
                work += polygon.count
                guard work <= workLimit else { return (nil, holeIndex, true) }
                var nearest: [Pair] = []
                for to in polygon.indices where !used.contains(polygon[to]) && points[polygon[to]] != points[hole[from]] {
                    let pair: Pair = (simd_distance_squared(points[hole[from]], points[polygon[to]]), from, to)
                    if nearest.count == candidatesPerPoint, let last = nearest.last, !before(pair, last) { continue }
                    let at = nearest.firstIndex { before(pair, $0) } ?? nearest.count
                    nearest.insert(pair, at: at)
                    if nearest.count > candidatesPerPoint { nearest.removeLast() }
                }
                pairs.append(contentsOf: nearest)
            }
            // The sort is counted too (n log n comparisons).
            work += pairs.count * max(1, Int(log2(Double(max(pairs.count, 2)))))
            guard work <= workLimit else { return (nil, holeIndex, true) }
            pairs.sort(by: before)
            var joined: [Int]?
            for pair in pairs {
                if isCancelled() { throw InternalWallsError.stopped }
                let m = points[hole[pair.from]], target = points[polygon[pair.to]]
                work += edges.count
                guard work <= workLimit else { return (nil, holeIndex, true) }
                let blocked = edges.contains { edge in
                    // Edges ending at either end of the cut can only meet it there.
                    if edge.0 == m || edge.1 == m || edge.0 == target || edge.1 == target { return false }
                    return touch(m, target, edge.0, edge.1)
                }
                guard !blocked else { continue }
                var merged = Array(polygon[...pair.to])
                merged.append(contentsOf: hole[pair.from...] + hole[..<pair.from])
                merged.append(hole[pair.from])
                merged.append(polygon[pair.to])
                merged.append(contentsOf: polygon[(pair.to + 1)...])
                used.insert(polygon[pair.to])
                used.insert(hole[pair.from])
                joined = merged
                break
            }
            guard let joined else { return (nil, holeIndex, false) }
            polygon = joined
        }
        result.append(polygon)
    }
    return (result, nil, false)
}

/// Outline points tried per hole point when joining slot openings to the bed outline (`internalWallsBridgedLoops`).
/// A slot opening has four points, so at most 128 candidate cuts are sorted per slot.
let internalWallsBridgeCandidatesPerPoint = 32

// MARK: - Nearest-surface index

/// A bounding-volume hierarchy for the distance from a point to the nearest triangle. Built like `TriangleRayIndex`:
/// triangles ordered by the Morton code of their centroid (ties by index) and split at the middle of each range.
struct InternalWallsDistanceIndex {
    private let a: [SIMD3<Float>], b: [SIMD3<Float>], c: [SIMD3<Float>]
    private let order: [Int32]
    private var low: [SIMD3<Float>] = [], high: [SIMD3<Float>] = []
    private var start: [Int32] = [], extra: [Int32] = []
    static let leafSize = 4

    /// `corners` holds three points per triangle.
    init(corners: [SIMD3<Float>]) {
        let count = corners.count / 3
        var a = [SIMD3<Float>](), b = [SIMD3<Float>](), c = [SIMD3<Float>]()
        a.reserveCapacity(count); b.reserveCapacity(count); c.reserveCapacity(count)
        var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
        for t in 0..<count {
            a.append(corners[3 * t]); b.append(corners[3 * t + 1]); c.append(corners[3 * t + 2])
            lo = simd_min(lo, simd_min(a[t], simd_min(b[t], c[t]))); hi = simd_max(hi, simd_max(a[t], simd_max(b[t], c[t])))
        }
        let span = simd_max(hi - lo, SIMD3(repeating: 1e-12))
        func spread(_ value: UInt32) -> UInt64 {
            var x = UInt64(value) & 0x1fffff
            x = (x | x << 32) & 0x1f00000000ffff
            x = (x | x << 16) & 0x1f0000ff0000ff
            x = (x | x << 8) & 0x100f00f00f00f00f
            x = (x | x << 4) & 0x10c30c30c30c30c3
            x = (x | x << 2) & 0x1249249249249249
            return x
        }
        var keys = [UInt64](repeating: 0, count: count)
        for t in 0..<count {
            let centroid = ((a[t] + b[t] + c[t]) / 3 - lo) / span
            let q = simd_clamp(centroid, SIMD3(repeating: 0), SIMD3(repeating: 1)) * 1_048_575
            keys[t] = spread(UInt32(q.x)) | spread(UInt32(q.y)) << 1 | spread(UInt32(q.z)) << 2
        }
        self.a = a; self.b = b; self.c = c
        self.order = (0..<Int32(count)).sorted { keys[Int($0)] != keys[Int($1)] ? keys[Int($0)] < keys[Int($1)] : $0 < $1 }
        if count > 0 { build(0, count) }
    }

    @discardableResult
    private mutating func build(_ from: Int, _ to: Int) -> Int {
        let node = low.count
        low.append(.zero); high.append(.zero); start.append(-1); extra.append(0)
        if to - from <= Self.leafSize {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for k in from..<to {
                let t = Int(order[k])
                lo = simd_min(lo, simd_min(a[t], simd_min(b[t], c[t])))
                hi = simd_max(hi, simd_max(a[t], simd_max(b[t], c[t])))
            }
            low[node] = lo; high[node] = hi
            start[node] = Int32(from); extra[node] = Int32(to - from)
        } else {
            let middle = (from + to) / 2
            let left = build(from, middle)
            let right = build(middle, to)
            low[node] = simd_min(low[left], low[right]); high[node] = simd_max(high[left], high[right])
            extra[node] = Int32(right)
        }
        return node
    }

    /// Lane by lane, the same arithmetic as `simd_length_squared(simd_max(simd_max(low − p, p − high), 0))`, written
    /// out because the generic SIMD operators are slow in unoptimised builds and this runs for every node visited.
    private func boxDistanceSquared(_ node: Int, _ p: SIMD3<Float>) -> Float {
        func larger(_ a: Float, _ b: Float) -> Float { a > b ? a : b }
        let lo = low[node], hi = high[node]
        let dx = larger(larger(lo.x - p.x, p.x - hi.x), 0)
        let dy = larger(larger(lo.y - p.y, p.y - hi.y), 0)
        let dz = larger(larger(lo.z - p.z, p.z - hi.z), 0)
        return dx * dx + dy * dy + dz * dz
    }

    /// The distance from `p` to the nearest triangle that isn't wholly inside `cylinder` (a bore's own surfaces), or
    /// `limit` when none is nearer.
    func distance(to p: SIMD3<Float>, within limit: Float, ignoringInside cylinder: InternalWallsCylinder) -> Float {
        guard !low.isEmpty else { return limit }
        func inside(_ q: SIMD3<Float>) -> Bool { cylinder.contains(q) }
        var best = limit * limit
        // A stack on the stack, not the heap: this runs for every query.
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 64) { stack in
            var depth = 1
            stack[0] = 0
            while depth > 0 {
                depth -= 1
                let node = stack[depth]
                guard boxDistanceSquared(node, p) < best else { continue }
                if start[node] >= 0 {
                    for k in Int(start[node])..<Int(start[node] + extra[node]) {
                        let t = Int(order[k])
                        if inside(a[t]), inside(b[t]), inside(c[t]) { continue }
                        // `min(best, d)`, without the generic call.
                        let d = internalWallsPointTriangleDistanceSquared(p, a[t], b[t], c[t])
                        if d < best { best = d }
                    }
                } else if depth + 2 <= stack.count {
                    let left = node + 1, right = Int(extra[node])
                    if boxDistanceSquared(left, p) <= boxDistanceSquared(right, p) {
                        stack[depth] = right; stack[depth + 1] = left
                    } else {
                        stack[depth] = left; stack[depth + 1] = right
                    }
                    depth += 2
                }
            }
        }
        return best.squareRoot()
    }

    /// The distance from `p` to the nearest triangle, or `limit` when none is nearer.
    func distance(to p: SIMD3<Float>, within limit: Float) -> Float {
        guard !low.isEmpty else { return limit }
        var best = limit * limit
        // A stack on the stack, not the heap: this runs for every query.
        withUnsafeTemporaryAllocation(of: Int.self, capacity: 64) { stack in
            var depth = 1
            stack[0] = 0
            while depth > 0 {
                depth -= 1
                let node = stack[depth]
                guard boxDistanceSquared(node, p) < best else { continue }
                if start[node] >= 0 {
                    for k in Int(start[node])..<Int(start[node] + extra[node]) {
                        let t = Int(order[k])
                        // `min(best, d)`, without the generic call.
                        let d = internalWallsPointTriangleDistanceSquared(p, a[t], b[t], c[t])
                        if d < best { best = d }
                    }
                } else if depth + 2 <= stack.count {
                    let left = node + 1, right = Int(extra[node])
                    // The nearer child is searched first.
                    if boxDistanceSquared(left, p) <= boxDistanceSquared(right, p) {
                        stack[depth] = right; stack[depth + 1] = left
                    } else {
                        stack[depth] = left; stack[depth + 1] = right
                    }
                    depth += 2
                }
            }
        }
        return best.squareRoot()
    }
}

/// Squared distance from `p` to triangle `abc` (Ericson, Real-Time Collision Detection, 5.1.5), in Double.
func internalWallsPointTriangleDistanceSquared(_ point: SIMD3<Float>, _ a32: SIMD3<Float>, _ b32: SIMD3<Float>, _ c32: SIMD3<Float>) -> Float {
    let p = SIMD3<Double>(point), a = SIMD3<Double>(a32), b = SIMD3<Double>(b32), c = SIMD3<Double>(c32)
    let ab = b - a, ac = c - a, ap = p - a
    let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
    if d1 <= 0 && d2 <= 0 { return Float(simd_length_squared(ap)) }
    let bp = p - b
    let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
    if d3 >= 0 && d4 <= d3 { return Float(simd_length_squared(bp)) }
    let vc = d1 * d4 - d3 * d2
    if vc <= 0 && d1 >= 0 && d3 <= 0, d1 - d3 > 0 { return Float(simd_length_squared(p - (a + ab * (d1 / (d1 - d3))))) }
    let cp = p - c
    let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
    if d6 >= 0 && d5 <= d6 { return Float(simd_length_squared(cp)) }
    let vb = d5 * d2 - d1 * d6
    if vb <= 0 && d2 >= 0 && d6 <= 0, d2 - d6 > 0 { return Float(simd_length_squared(p - (a + ac * (d2 / (d2 - d6))))) }
    let va = d3 * d6 - d5 * d4
    if va <= 0 && d4 - d3 >= 0 && d5 - d6 >= 0, (d4 - d3) + (d5 - d6) > 0 {
        return Float(simd_length_squared(p - (b + (c - b) * ((d4 - d3) / ((d4 - d3) + (d5 - d6))))))
    }
    let sum = va + vb + vc
    // Only a zero-area triangle gets here without a positive sum; sound meshes, the only input, have none.
    guard sum > 0, sum.isFinite else { return Float(min(simd_length_squared(ap), simd_length_squared(bp), simd_length_squared(cp))) }
    let v = vb / sum, w = vc / sum
    return Float(simd_length_squared(p - (a + ab * v + ac * w)))
}
