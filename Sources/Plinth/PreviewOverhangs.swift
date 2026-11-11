import Foundation
import simd

// MARK: - Show Overhangs in the 3D preview
//
// Display only: which triangles the preview tints, by the same rule as the 50° overhang figure Plinth already shows
// (`overhangShare(_:limitDegrees:)` at Slant's `slantOverhangLimitDegrees`), so the picture and the figure agree.
// Nothing here changes the model, is saved with it or is sent anywhere. Pure and deterministic, in triangle order.

/// Which triangles face down more steeply than `limitDegrees` from vertical, and their share of the surface.
struct OverhangTriangleMask: Equatable, Sendable {
    /// One entry per triangle, in file order.
    let overhangs: [Bool]
    let share: OverhangShare
    var overhangCount: Int { overhangs.reduce(0) { $0 + ($1 ? 1 : 0) } }
}

/// Per triangle, `overhangShare(mesh, limitDegrees:)`'s rule in the same arithmetic and order: a face counts when its
/// normal points down by more than sin(limit), unless it lies flat on the bed; zero-area and non-finite triangles never
/// count. `ignoringNarrowCeilings` also leaves out internal walls' slot and ring ceilings, as Review for Printing does on
/// print-ready copies (`printReviewNarrowCeilings`): they bridge, and print preparation measures its 50° share on the
/// outer shape before the walls. Nil when cancelled.
func overhangTriangleMask(_ mesh: STLMesh, limitDegrees: Double = Double(slantOverhangLimitDegrees),
                          ignoringNarrowCeilings: Bool = false,
                          isCancelled: () -> Bool = { false }) -> OverhangTriangleMask? {
    let count = mesh.triangleCount
    // The ceilings pass has no cancel hook of its own, so a superseded request stops before starting it.
    if isCancelled() { return nil }
    let ceilings = ignoringNarrowCeilings ? printReviewNarrowCeilings(mesh) : []
    if isCancelled() { return nil }
    let limit = sin(limitDegrees * .pi / 180)
    let v = mesh.vertices
    let floor = Double(mesh.minimum.z) + 0.0001
    var overhangs = [Bool](repeating: false, count: count)
    var surface = 0.0, overhang = 0.0
    for t in 0..<count {
        if t & 0xFFFF == 0, isCancelled() { return nil }
        let i = t * 9
        let a = SIMD3<Double>(Double(v[i]), Double(v[i + 1]), Double(v[i + 2]))
        let b = SIMD3<Double>(Double(v[i + 3]), Double(v[i + 4]), Double(v[i + 5]))
        let c = SIMD3<Double>(Double(v[i + 6]), Double(v[i + 7]), Double(v[i + 8]))
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        guard length > 0, length.isFinite else { continue }
        let area = length / 2
        surface += area
        let nz = cross.z / length
        let onBed = max(a.z, b.z, c.z) <= floor && nz <= -0.999999
        guard !onBed, nz < -limit else { continue }
        if !ceilings.isEmpty, ceilings[t] { continue }
        overhangs[t] = true
        overhang += area
    }
    return OverhangTriangleMask(overhangs: overhangs, share: OverhangShare(overhangAreaMM2: overhang, surfaceAreaMM2: surface))
}

/// The preview's two triangle lists as 32-bit vertex indices into its unindexed vertex buffer (three vertices per
/// triangle, in file order): the plain faces and the tinted ones. Built off the main actor so a 500,000-triangle model
/// only hands SceneKit two buffers.
final class PreviewOverhangHighlight: Sendable {
    let plainIndices: Data
    let overhangIndices: Data
    let plainTriangles: Int
    let overhangTriangles: Int
    let share: OverhangShare

    init(mask: OverhangTriangleMask) {
        var plain: [UInt32] = [], tinted: [UInt32] = []
        let tintedCount = mask.overhangCount
        plain.reserveCapacity((mask.overhangs.count - tintedCount) * 3)
        tinted.reserveCapacity(tintedCount * 3)
        for (t, isOverhang) in mask.overhangs.enumerated() {
            let first = UInt32(t * 3)
            if isOverhang { tinted.append(contentsOf: [first, first + 1, first + 2]) } else { plain.append(contentsOf: [first, first + 1, first + 2]) }
        }
        plainIndices = plain.withUnsafeBufferPointer { Data(buffer: $0) }
        overhangIndices = tinted.withUnsafeBufferPointer { Data(buffer: $0) }
        plainTriangles = plain.count / 3
        overhangTriangles = tinted.count / 3
        share = mask.share
    }
}

/// Builds the highlight off the main actor; nil when cancelled.
func previewOverhangHighlight(_ mesh: STLMesh, ignoringNarrowCeilings: Bool,
                              isCancelled: () -> Bool = { false }) -> PreviewOverhangHighlight? {
    guard let mask = overhangTriangleMask(mesh, ignoringNarrowCeilings: ignoringNarrowCeilings, isCancelled: isCancelled),
          !isCancelled() else { return nil }
    return PreviewOverhangHighlight(mask: mask)
}

/// The control's title.
let previewShowOverhangsTitle = "Show Overhangs"

/// Under the control while it is on: what the tint means, with the same figure and words as the 50° advisory. It names
/// Slant, like the preview's build-volume line, and with 3DAPI as the print service (`forDapi`) says the rule is
/// Slant's, so it never claims to describe 3DAPI's printing. No promise about the print.
func previewOverhangCaption(_ share: OverhangShare?, forDapi: Bool = false) -> String {
    let placed = forDapi
        ? "Shown as the file is oriented. This is Slant’s 50° rule; 3DAPI’s may differ."
        : "Shown as the file is oriented, which is how Slant prints it."
    guard let share else { return "Finding overhangs… \(placed)" }
    if share.overhangAreaMM2 <= 0 { return "No faces point down more steeply than Slant’s 50° limit. \(placed)" }
    return "Orange: \(percentLabel(share.fraction)) of the surface faces down more steeply than Slant’s 50° limit, where Slant may add supports. \(placed)"
}

/// The control's accessibility value: the share of the surface tinted, while it is on.
func previewOverhangAccessibilityValue(isOn: Bool, share: OverhangShare?) -> String {
    guard isOn else { return "Off" }
    guard let share else { return "On, finding overhangs" }
    if share.overhangAreaMM2 <= 0 { return "On, no overhangs past 50°" }
    return "On, \(percentLabel(share.fraction)) of the surface tinted"
}

/// Remembers the toggle between launches (a plain preference; the model is never changed).
let previewShowOverhangsDefaultsKey = "previewShowOverhangs"
