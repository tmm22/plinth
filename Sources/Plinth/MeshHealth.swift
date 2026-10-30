import SwiftUI
import simd

// MARK: - Analysis

/// Topology counts for a triangle soup, measured before upload. Advisory only: nothing here blocks an upload.
struct MeshHealthReport: Equatable, Sendable {
    let triangleCount: Int
    /// Distinct vertex positions after welding identical coordinates.
    let vertexCount: Int
    /// Edges used by exactly one triangle: gaps in the surface.
    let openEdges: Int
    /// Edges shared by more than two triangles.
    let nonManifoldEdges: Int
    /// Edges shared by two triangles that both run the same way, so one of them is flipped.
    let flippedEdges: Int
    /// Triangles with a repeated corner, or whose corners are (numerically) on one line.
    let degenerateTriangles: Int
    /// Groups of triangles connected through shared vertices.
    let shells: Int
    /// Signed volume in cubic model units; negative when a closed, consistent mesh faces inward.
    let signedVolume: Double

    var isClosed: Bool { triangleCount > 0 && openEdges == 0 && nonManifoldEdges == 0 }
    var isConsistentlyOriented: Bool { flippedEdges == 0 }
    var isInsideOut: Bool { isClosed && isConsistentlyOriented && signedVolume < 0 }
}

/// A triangle counts as zero-area when its height is below this fraction of its longest edge.
/// A numerical tolerance for Float STL coordinates, not a manufacturing threshold.
let meshHealthDegenerateRatio = 1e-6

/// Counts open, non-manifold and flipped edges, degenerate triangles and separate shells.
///
/// Vertices are welded by exact coordinate equality, the same rule `MeshEdge` and the reinforcement checks use,
/// so "closed and consistently oriented" here means the same as the directed-edge test in `reinforcementSolid()`.
/// Everything walks triangles, vertices and sorted edge keys in index order, so the result never depends on the
/// process's hash seed. Returns nil when `isCancelled` reports true.
func analyzeMeshHealth(_ mesh: STLMesh, isCancelled: () -> Bool = { false }) -> MeshHealthReport? {
    let count = mesh.triangleCount
    let v = mesh.vertices
    guard count > 0 else {
        return MeshHealthReport(triangleCount: 0, vertexCount: 0, openEdges: 0, nonManifoldEdges: 0, flippedEdges: 0,
                                degenerateTriangles: 0, shells: 0, signedVolume: 0)
    }
    let checkInterval = 8192

    // Weld: first-seen order assigns indices, so they are deterministic.
    var ids = [Int32](repeating: 0, count: count * 3)
    var lookup: [SIMD3<Float>: Int32] = [:]
    lookup.reserveCapacity(min(count * 3, 1 << 21))
    var points: [SIMD3<Float>] = []
    points.reserveCapacity(min(count * 3, 1 << 21))
    for corner in 0..<(count * 3) {
        if corner % checkInterval == 0, isCancelled() { return nil }
        let base = corner * 3
        // Adding zero turns -0 into +0, so both spellings of a coordinate weld together.
        let p = SIMD3<Float>(v[base] + 0, v[base + 1] + 0, v[base + 2] + 0)
        if let id = lookup[p] {
            ids[corner] = id
        } else {
            let id = Int32(points.count)
            lookup[p] = id
            points.append(p)
            ids[corner] = id
        }
    }
    lookup = [:]

    var parent = [Int32](0..<Int32(points.count))
    func root(_ x: Int32) -> Int32 {
        var r = x
        while parent[Int(r)] != r { r = parent[Int(r)] }
        var c = x
        while parent[Int(c)] != r { let next = parent[Int(c)]; parent[Int(c)] = r; c = next }
        return r
    }
    func union(_ a: Int32, _ b: Int32) {
        let ra = root(a), rb = root(b)
        if ra != rb { if ra < rb { parent[Int(rb)] = ra } else { parent[Int(ra)] = rb } }
    }

    // Each directed edge packs (low vertex, high vertex, direction) into one key; sorting groups the uses of an edge.
    var edges: [UInt64] = []
    edges.reserveCapacity(count * 3)
    func addEdge(_ p: Int32, _ q: Int32) {
        // 32 bits per vertex (`meshDirectedEdgeKey`): the same order as before, without overflowing above 2²² vertices.
        edges.append(meshDirectedEdgeKey(p, q))
    }
    var degenerate = 0
    var volume = 0.0
    let origin = SIMD3<Double>(mesh.minimum)
    for t in 0..<count {
        if t % checkInterval == 0, isCancelled() { return nil }
        let a = ids[3 * t], b = ids[3 * t + 1], c = ids[3 * t + 2]
        union(a, b)
        union(a, c)
        if a == b || b == c || a == c {
            // A repeated corner has no surface; its remaining edges would only pair with each other.
            degenerate += 1
            continue
        }
        let pa = SIMD3<Double>(points[Int(a)]) - origin
        let pb = SIMD3<Double>(points[Int(b)]) - origin
        let pc = SIMD3<Double>(points[Int(c)]) - origin
        let cross = simd_cross(pb - pa, pc - pa)
        let longest = max(simd_length_squared(pb - pa), simd_length_squared(pc - pb), simd_length_squared(pa - pc))
        // |cross| is twice the area = longest edge × height, so this compares height to the longest edge.
        if simd_length(cross) <= meshHealthDegenerateRatio * longest { degenerate += 1 }
        // Collinear slivers still count for edges: they often close a crack between their neighbours.
        addEdge(a, b)
        addEdge(b, c)
        addEdge(c, a)
        volume += simd_dot(pa, simd_cross(pb, pc)) / 6
    }
    if isCancelled() { return nil }
    edges.sort()
    if isCancelled() { return nil }

    var open = 0, nonManifold = 0, flipped = 0
    var i = 0
    while i < edges.count {
        let key = edges[i] >> 1
        var j = i, forward = 0
        while j < edges.count, edges[j] >> 1 == key {
            if edges[j] & 1 == 0 { forward += 1 }
            j += 1
        }
        switch j - i {
        case 1: open += 1
        case 2: if forward != 1 { flipped += 1 }
        default: nonManifold += 1
        }
        i = j
    }

    var shells = 0
    for p in 0..<points.count where root(Int32(p)) == Int32(p) { shells += 1 }

    return MeshHealthReport(triangleCount: count, vertexCount: points.count, openEdges: open, nonManifoldEdges: nonManifold,
                            flippedEdges: flipped, degenerateTriangles: degenerate, shells: shells, signedVolume: volume)
}

// MARK: - Summary copy

struct MeshHealthSummary: Equatable {
    let title: String
    /// Plain-language findings, most consequential first, shown collapsed under the one-line result.
    let details: [String]
    /// True when nothing needs attention. Zero-area triangles alone are mentioned in the details but keep it clean.
    let isClean: Bool
    /// The one line shown under the preview.
    var line: String {
        if isClean { return "Mesh check: \(title)" }
        return "Mesh check: \(details.count == 1 ? "1 note" : "\(details.count) notes")"
    }
}

private func counted(_ n: Int, _ singular: String, _ plural: String) -> String {
    "\(n.formatted()) \(n == 1 ? singular : plural)"
}

/// The body line when every extra body is a hidden pocket: the pocket line below gives the cost.
func meshBodyPocketsNote(bodies: Int) -> String {
    "\(bodies.formatted()) separate bodies: the extra ones are hidden pockets, explained in the hidden-pocket line below."
}

/// What Slant's estimates showed for extra bodies (live test, 25 Oct 2026: nine closed internal voids in a block gave
/// 10 bodies and a $3.50 `bodyChargeCost`; the same slots open to the bottom face kept one body and no charge).
let meshBodyChargeNote = "Slant charges extra for each body after the first (about $0.39 each in a test on 25 Oct 2026)."

/// The one advisory line for a model of more than one shell. Shells are groups of connected triangles, so a closed
/// hidden pocket is a body of its own, while a cavity that opens to the outside is part of the outer surface.
func meshBodyChargeAdvisory(bodies: Int, objectCount: Int = 1) -> String {
    let across = objectCount > 1 ? " across \(objectCount.formatted()) objects" : ""
    return "\(bodies.formatted()) separate bodies\(across): \(meshBodyChargeNote) Join them or remove hidden pockets if they aren’t meant to be separate."
}

/// `objectCount` is the number of objects a 3MF places (1 for STL and OBJ). When each object is exactly one part,
/// separate parts are expected and aren't flagged as a problem, though the body charge is still noted.
/// `pocketsExplainBodies`: every extra body is a hidden pocket (`hiddenPocketsAccountForExtraBodies`), so the body line
/// points to the pocket line, which gives the cost, instead of repeating it.
func meshHealthSummary(_ report: MeshHealthReport, objectCount: Int = 1, pocketsExplainBodies: Bool = false) -> MeshHealthSummary {
    guard report.triangleCount > 0 else {
        return MeshHealthSummary(title: "No triangles to check", details: [], isClean: true)
    }
    let onePartPerObject = objectCount > 1 && report.shells == objectCount
    let parts = counted(report.shells, "part", "parts") + (onePartPerObject ? " (one per object)" : "")
    let title = "\(report.isClosed ? "Closed" : "Not closed"), \(parts)"
    var details: [String] = []
    if report.openEdges > 0 {
        details.append("\(counted(report.openEdges, "open edge", "open edges")) — gaps in the surface. Slicers may fill or skip gaps, so the print may not match the model. Repair & Save Copy, in Improve for printing, can close small ones; otherwise close them in your CAD tool.")
    }
    if report.nonManifoldEdges > 0 {
        details.append("\(counted(report.nonManifoldEdges, "edge is", "edges are")) shared by more than two faces. Slicers can misread these areas. Repair & Save Copy, in Improve for printing, removes loose flaps; fix the rest in your CAD tool.")
    }
    if report.flippedEdges > 0 {
        details.append("\(counted(report.flippedEdges, "edge joins faces", "edges join faces")) pointing opposite ways, so some faces are flipped. Repair & Save Copy, in Improve for printing, can make them consistent.")
    }
    if report.isInsideOut {
        details.append("The faces point inward. Slicers may read this as a hollow; Repair & Save Copy, in Improve for printing, can turn them outward.")
    }
    if report.shells > 1, !onePartPerObject {
        details.append(pocketsExplainBodies ? meshBodyPocketsNote(bodies: report.shells)
                       : meshBodyChargeAdvisory(bodies: report.shells, objectCount: objectCount))
    }
    let hasIssues = !details.isEmpty
    if onePartPerObject {
        // Separate objects are expected, so the check stays clean, but Slant still bills the extra bodies.
        details.append("\(report.shells.formatted()) bodies, one per object: \(meshBodyChargeNote)")
    }
    if report.degenerateTriangles > 0 {
        details.append("\(counted(report.degenerateTriangles, "zero-area triangle", "zero-area triangles")). Usually harmless, though some tools list them as errors.")
    }
    return MeshHealthSummary(title: title, details: details, isClean: !hasIssues)
}

// MARK: - Cache and view

/// In-memory, per model file version. Cleared when the app quits.
@MainActor enum MeshHealthCache {
    static var reports: [String: MeshHealthReport] = [:]
}

func meshHealthCacheKey(modelID: UUID, path: String, modified: Date?) -> String {
    "\(modelID.uuidString)|\(path)|\(modified?.timeIntervalSinceReferenceDate ?? -1)"
}

/// One-line mesh check shown under the local preview, with any notes in a collapsed disclosure. Advisory: upload
/// stays available whatever it finds.
struct MeshHealthPanel: View {
    let model: LocalModel
    let mesh: STLMesh
    /// Objects the 3MF places; 1 for STL and OBJ.
    var objectCount = 1
    @State private var report: MeshHealthReport?
    @State private var reportKey = ""
    @State private var expanded = false
    /// The pocket check for an STL with extra bodies (shared with `HiddenPocketsCheck` through its cache).
    @State private var pockets: HiddenPocketsReport?

    private func pocketsExplainBodies(_ report: MeshHealthReport) -> Bool {
        if let saved = model.printPreparation?.hiddenPockets {
            return saved.count > 0 && saved.incomplete != true && saved.removableBodies == report.shells - 1
        }
        return hiddenPocketsAccountForExtraBodies(report, pockets)
    }

    var body: some View {
        let taskID = "\(model.id.uuidString)|\(model.filePath)|\(mesh.triangleCount)"
        Group {
            if let report, reportKey == taskID {
                let summary = meshHealthSummary(report, objectCount: objectCount, pocketsExplainBodies: pocketsExplainBodies(report))
                let label = Label(summary.line, systemImage: summary.isClean ? "checkmark.circle" : "info.circle")
                    .font(.callout)
                    .foregroundStyle(summary.isClean ? Color.green : Color.primary)
                if summary.details.isEmpty {
                    label
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel(summary.line)
                } else {
                    DisclosureGroup(isExpanded: $expanded) {
                        VStack(alignment: .leading, spacing: 6) {
                            if !summary.isClean {
                                Text(summary.title).font(.callout.weight(.semibold))
                            }
                            ForEach(summary.details, id: \.self) { line in
                                Text(line).font(.callout).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("This check is advisory and doesn’t block upload.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.top, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        label.accessibilityLabel(summary.isClean ? summary.line : "\(summary.line). \(summary.title)")
                    }.studioDisclosureStyle()
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking mesh…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: taskID) {
            let url = model.url
            let modified = await Task.detached(priority: .utility) { fileModificationDate(url) }.value
            let key = meshHealthCacheKey(modelID: model.id, path: model.filePath, modified: modified)
            let result: MeshHealthReport
            if let cached = MeshHealthCache.reports[key] {
                result = cached
            } else {
                let mesh = mesh
                let worker = Task.detached(priority: .userInitiated) {
                    analyzeMeshHealth(mesh, isCancelled: { Task.isCancelled })
                }
                guard let found = await withTaskCancellationHandler(operation: { await worker.value }, onCancel: { worker.cancel() }),
                      !Task.isCancelled else { return }
                MeshHealthCache.reports[key] = found
                result = found
            }
            report = result
            reportKey = taskID
            // Extra bodies on an STL: whether they are hidden pockets, so the body line can point to the pocket line.
            pockets = nil
            if result.shells > 1, hiddenPocketsCheckApplies(model), mesh.triangleCount <= hiddenPocketsMaximumTriangles {
                pockets = await hiddenPocketsCachedReport(key: hiddenPocketsCacheKey(modelID: model.id, path: model.filePath), mesh: mesh)
            }
        }
    }
}
