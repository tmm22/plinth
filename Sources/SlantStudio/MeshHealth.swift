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
        let low = UInt64(min(p, q)), high = UInt64(max(p, q))
        edges.append(((low << 22) | high) << 1 | (p < q ? 0 : 1))
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
    /// Plain-language findings, most consequential first. Empty when nothing needs attention.
    let details: [String]
    var isClean: Bool { details.isEmpty }
}

private func counted(_ n: Int, _ singular: String, _ plural: String) -> String {
    "\(n.formatted()) \(n == 1 ? singular : plural)"
}

func meshHealthSummary(_ report: MeshHealthReport) -> MeshHealthSummary {
    guard report.triangleCount > 0 else {
        return MeshHealthSummary(title: "No triangles to check", details: [])
    }
    let parts = counted(report.shells, "part", "parts")
    let title = "\(report.isClosed ? "Closed" : "Not closed"), \(parts)"
    var details: [String] = []
    if report.openEdges > 0 {
        details.append("\(counted(report.openEdges, "open edge", "open edges")) — gaps in the surface. Slant may reject or misprint this; close them in your CAD tool or a mesh repair tool.")
    }
    if report.nonManifoldEdges > 0 {
        details.append("\(counted(report.nonManifoldEdges, "edge is", "edges are")) shared by more than two faces. Slicers can misread these areas; fix them in CAD or a repair tool.")
    }
    if report.flippedEdges > 0 {
        details.append("\(counted(report.flippedEdges, "edge joins faces", "edges join faces")) pointing opposite ways, so some faces are flipped. A repair tool can make them consistent.")
    }
    if report.isInsideOut {
        details.append("The faces point inward. Slicers may read this as a hollow; a repair tool can flip them outward.")
    }
    if report.shells > 1 {
        details.append("\(parts) that don’t touch. Unless one sits inside another as a hollow, each prints as a loose piece.")
    }
    if report.degenerateTriangles > 0 {
        details.append("\(counted(report.degenerateTriangles, "zero-area triangle", "zero-area triangles")). Usually harmless, though some tools list them as errors.")
    }
    return MeshHealthSummary(title: title, details: details)
}

// MARK: - Cache and view

/// In-memory, per model file version. Cleared when the app quits.
@MainActor enum MeshHealthCache {
    static var reports: [String: MeshHealthReport] = [:]
}

func meshHealthCacheKey(modelID: UUID, path: String, modified: Date?) -> String {
    "\(modelID.uuidString)|\(path)|\(modified?.timeIntervalSinceReferenceDate ?? -1)"
}

/// Compact mesh check shown under the local preview. Advisory: upload stays available whatever it finds.
struct MeshHealthPanel: View {
    let model: LocalModel
    let mesh: STLMesh
    @State private var report: MeshHealthReport?
    @State private var reportKey = ""

    var body: some View {
        let taskID = "\(model.id.uuidString)|\(model.filePath)|\(mesh.triangleCount)"
        Group {
            if let report, reportKey == taskID {
                let summary = meshHealthSummary(report)
                VStack(alignment: .leading, spacing: 6) {
                    Label(summary.title, systemImage: summary.isClean ? "checkmark.circle" : "info.circle")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(summary.isClean ? Color.green : Color.primary)
                    ForEach(summary.details, id: \.self) { line in
                        Text(line).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !summary.isClean {
                        Text("This check is advisory and doesn’t block upload.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Mesh check: \(([summary.title] + summary.details).joined(separator: " "))")
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Checking mesh…").font(.callout).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.studioCard, in: RoundedRectangle(cornerRadius: StudioMetrics.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: StudioMetrics.cardRadius).stroke(Color.studioHairline))
        .task(id: taskID) {
            let url = model.url
            let modified = await Task.detached(priority: .utility) { fileModificationDate(url) }.value
            let key = meshHealthCacheKey(modelID: model.id, path: model.filePath, modified: modified)
            if let cached = MeshHealthCache.reports[key] {
                report = cached
                reportKey = taskID
                return
            }
            let mesh = mesh
            let worker = Task.detached(priority: .userInitiated) {
                analyzeMeshHealth(mesh, isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let result else { return }
            MeshHealthCache.reports[key] = result
            report = result
            reportKey = taskID
        }
    }
}
