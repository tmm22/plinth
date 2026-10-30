import Foundation
import simd

// Local preview for OBJ and 3MF. Both are read into the same triangle soup as STL so dimensions, the build-volume
// warning and the scale check behave the same. Uploads always send the original file in its original format.

enum ModelFileFormat: String, Sendable {
    case stl, obj, threeMF = "3mf"

    init?(url: URL) { self.init(rawValue: url.pathExtension.lowercased()) }

    var displayName: String { self == .threeMF ? "3MF" : rawValue.uppercased() }
    /// STL and OBJ store bare numbers that Slant reads as millimetres; 3MF declares its unit.
    var recordsUnits: Bool { self == .threeMF }
}

/// A parsed model ready for preview. `partExtents` holds one bounding box per placed object (build item), in millimetres,
/// so a file with several objects spread across a plate isn't flagged as one oversized part.
struct PreviewModel: Sendable {
    let mesh: STLMesh
    let format: ModelFileFormat
    let objectCount: Int
    let partExtents: [SIMD3<Float>]
    /// OBJ faces that couldn't be split into triangles exactly (for example a face that crosses itself). They are
    /// previewed as a fan, but no STL copy is saved from such a model because it wouldn't match the file.
    var inexactFaces = 0
    /// Designer, licence and source from a 3MF's model-level metadata (ModelSourceDetails.swift); empty otherwise.
    var sourceDetails = ModelSourceDetails()
}

enum ModelFormatError: LocalizedError, Equatable {
    case obj(line: Int, reason: String)
    case missingModel
    case missingObject(Int)
    case unsupportedUnit(String)
    case noBuildItems
    case invalid3MF(String)
    case tooDeep
    case unsupportedFormat
    case noTriangles(ModelFileFormat)
    case invalidGeometry(ModelFileFormat)

    var errorDescription: String? {
        switch self {
        case .obj(let line, let reason): return "This OBJ couldn’t be read (line \(line): \(reason))."
        case .missingModel: return "This 3MF doesn’t contain a 3D model part."
        case .missingObject(let id): return "This 3MF refers to object \(id), which it doesn’t contain."
        case .unsupportedUnit(let unit): return "This 3MF uses an unknown unit (“\(unit)”)."
        case .noBuildItems: return "This 3MF doesn’t place any objects on its build plate."
        case .invalid3MF(let reason): return "This 3MF couldn’t be read: \(reason)."
        case .tooDeep: return "This 3MF nests components too deeply to preview."
        case .unsupportedFormat: return unsupportedPreviewMessage
        case .noTriangles(let format): return "This \(format.displayName) doesn’t contain any triangles."
        case .invalidGeometry(let format):
            return "This \(format.displayName) contains invalid coordinates, or its triangles have no size."
        }
    }
}

/// Reads any model the library accepts, within the same 128 MB / 500,000-triangle limits as STL.
func loadPreviewModel(from url: URL) throws -> PreviewModel {
    guard let format = ModelFileFormat(url: url) else { throw ModelFormatError.unsupportedFormat }
    let access = url.startAccessingSecurityScopedResource()
    defer { if access { url.stopAccessingSecurityScopedResource() } }
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= STLMesh.maximumBytes else { throw STLMesh.ParseError.oversized }
    return try parsePreviewModel(Data(contentsOf: url, options: .mappedIfSafe), format: format)
}

func parsePreviewModel(_ data: Data, format: ModelFileFormat) throws -> PreviewModel {
    switch format {
    case .stl:
        let mesh = try STLMesh.parse(data)
        return PreviewModel(mesh: mesh, format: .stl, objectCount: 1, partExtents: [mesh.maximum - mesh.minimum])
    case .obj:
        let parsed = try OBJParser.parseWithReport(data)
        return PreviewModel(mesh: parsed.mesh, format: .obj, objectCount: 1, partExtents: [parsed.mesh.maximum - parsed.mesh.minimum],
                            inexactFaces: parsed.inexactFaces)
    case .threeMF:
        return try ThreeMFReader.read(data)
    }
}

/// True when any placed object is larger than the build volume in some dimension.
func previewExceedsBuildVolume(_ model: PreviewModel) -> Bool {
    model.partExtents.contains { exceedsSlantBuildVolume(($0.x, $0.y, $0.z)) }
}

/// Shown with the preview when a 3MF places several objects. Slant's handling of multi-object files isn't documented,
/// so this states only what Studio knows: the whole file is uploaded.
func multipleObjectsNotice(objectCount: Int) -> String? {
    guard objectCount > 1 else { return nil }
    return "This file places \(objectCount) objects. Uploading sends the whole file — check the estimate covers them all."
}

/// The scale check for formats without units. 3MF declares its unit, which the preview has already applied.
func scaleWarning(extentMM: SIMD3<Float>, fileExtension: String) -> ScaleWarning? {
    let format = ModelFileFormat(rawValue: fileExtension.lowercased()) ?? .stl
    guard !format.recordsUnits, var warning = scaleWarning(extentMM: extentMM) else { return nil }
    warning.formatName = format.displayName
    return warning
}

// MARK: - OBJ

/// Mesh errors from the shared STL validation, reworded for the format being read.
func formatSpecific(_ error: Error, _ format: ModelFileFormat) -> Error {
    guard format != .stl, let parse = error as? STLMesh.ParseError else { return error }
    switch parse {
    case .empty: return ModelFormatError.noTriangles(format)
    case .malformed: return ModelFormatError.invalidGeometry(format)
    case .unsupported: return ModelFormatError.unsupportedFormat
    case .oversized: return parse
    }
}

/// Wavefront OBJ geometry: `v` and `f` only. Polygons are split into triangles by ear clipping on their best-fit plane
/// (see `triangulateOBJFace`); texture coordinates, normals, groups, materials, lines and points are ignored. Indices
/// may be negative (relative to the latest vertex).
enum OBJParser {
    static let maximumVertices = 3 * STLMesh.maximumTriangles
    static let maximumLineBytes = 65_536
    /// Ear-clipping steps allowed per file. Convex faces cost about one step per triangle; this only bounds hostile
    /// files with huge concave faces, whose remaining faces are then fanned and reported as inexact.
    static let maximumTriangulationWork = 20_000_000

    static func parse(_ data: Data) throws -> STLMesh { try parseWithReport(data).mesh }

    /// The mesh, and how many faces could only be fanned (see `PreviewModel.inexactFaces`).
    static func parseWithReport(_ data: Data) throws -> (mesh: STLMesh, inexactFaces: Int) {
        do { return try read(data) } catch { throw formatSpecific(error, .obj) }
    }

    private static func read(_ data: Data) throws -> (mesh: STLMesh, inexactFaces: Int) {
        guard data.count <= STLMesh.maximumBytes else { throw STLMesh.ParseError.oversized }
        guard let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw ModelFormatError.obj(line: 1, reason: "the text encoding isn’t recognised")
        }
        var inexactFaces = 0
        var work = 0
        var positions: [SIMD3<Float>] = []
        var output: [Float] = []
        var failure: Error?
        var lineNumber = 0
        var continued = ""
        source.enumerateLines { rawLine, stop in
            lineNumber += 1
            guard rawLine.utf8.count + continued.utf8.count <= maximumLineBytes else {
                failure = ModelFormatError.obj(line: lineNumber, reason: "line too long"); stop = true; return
            }
            // A trailing backslash joins the next line.
            if rawLine.hasSuffix("\\") { continued += String(rawLine.dropLast()) + " "; return }
            let line = continued + rawLine
            continued = ""
            let content = line.firstIndex(of: "#").map { line[..<$0] } ?? Substring(line)
            let tokens = content.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\r" })
            guard let keyword = tokens.first else { return }
            switch keyword {
            case "v":
                guard tokens.count >= 4, let x = Float(tokens[1]), let y = Float(tokens[2]), let z = Float(tokens[3]),
                      x.isFinite, y.isFinite, z.isFinite else {
                    failure = ModelFormatError.obj(line: lineNumber, reason: "invalid vertex"); stop = true; return
                }
                guard positions.count < maximumVertices else { failure = STLMesh.ParseError.oversized; stop = true; return }
                positions.append(SIMD3(x, y, z))
            case "f":
                var corners: [Int] = []
                corners.reserveCapacity(tokens.count - 1)
                for token in tokens.dropFirst() {
                    // v, v/vt, v//vn or v/vt/vn: only the position index matters.
                    let field = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
                    guard let raw = Int(field), raw != 0 else {
                        failure = ModelFormatError.obj(line: lineNumber, reason: "invalid face index"); stop = true; return
                    }
                    let index = raw > 0 ? raw - 1 : positions.count + raw
                    guard index >= 0, index < positions.count else {
                        failure = ModelFormatError.obj(line: lineNumber, reason: "face refers to a missing vertex"); stop = true; return
                    }
                    corners.append(index)
                }
                guard corners.count >= 3 else {
                    failure = ModelFormatError.obj(line: lineNumber, reason: "face with fewer than three vertices"); stop = true; return
                }
                guard output.count / 9 + corners.count - 2 <= STLMesh.maximumTriangles else {
                    failure = STLMesh.ParseError.oversized; stop = true; return
                }
                let points = corners.map { positions[$0] }
                let face = triangulateOBJFace(points, work: &work, workLimit: maximumTriangulationWork)
                if !face.exact { inexactFaces += 1 }
                for index in face.indices {
                    let point = points[index]
                    output.append(point.x); output.append(point.y); output.append(point.z)
                }
            default:
                break
            }
        }
        if let failure { throw failure }
        guard !output.isEmpty else { throw STLMesh.ParseError.empty }
        return (try STLMesh.validated(output), inexactFaces)
    }
}

/// Splits one polygon face into triangles and returns corner positions (indices into `points`), three per triangle.
///
/// The polygon is projected onto its best-fit plane (Newell normal). A convex face is fanned from corner 0, exactly as
/// before ear clipping was added; any other face is checked for crossing edges (an x-sorted sweep) and then
/// ear-clipped. Every triangle
/// keeps the face's winding, and corners on a straight edge become zero-area triangles so the surface stays closed.
/// A face with no area at all (every corner on one line) is fanned, which is exact. A face whose edges cross, or one
/// that exceeds the work limit, can't be split exactly: it is fanned and reported as inexact. Runs in index order.
func triangulateOBJFace(_ points: [SIMD3<Float>], work: inout Int, workLimit: Int = .max) -> (indices: [Int], exact: Bool) {
    let n = points.count
    let fan: [Int] = n < 3 ? [] : (1..<(n - 1)).flatMap { [0, $0, $0 + 1] }
    guard n > 3 else { return (fan, true) }

    // Repeated consecutive corners add a zero-length edge and nothing else.
    var order: [Int] = []
    for i in 0..<n where order.last.map({ points[$0] != points[i] }) ?? true { order.append(i) }
    while order.count > 1, let last = order.last, points[last] == points[order[0]] { order.removeLast() }
    guard order.count >= 3 else { return (fan, true) }
    let m = order.count

    let origin = SIMD3<Double>(points[order[0]])
    let p3 = order.map { SIMD3<Double>(points[$0]) - origin }
    var extent = 0.0
    for q in p3 { extent = max(extent, abs(q.x), abs(q.y), abs(q.z)) }
    let tolerance = 1e-12 * max(extent * extent, .leastNormalMagnitude)

    var normal = SIMD3<Double>.zero
    for i in 0..<m {
        let a = p3[i], b = p3[(i + 1) % m]
        normal += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
    }
    let length = simd_length(normal)
    guard length.isFinite else { return (fan, false) }
    if length <= tolerance {
        // No net area: exact only when every corner is on one line (a bow tie also nets to zero).
        let far = p3.max { simd_length_squared($0) < simd_length_squared($1) } ?? .zero
        let reach = simd_length(far)
        let collinear = reach == 0 || p3.allSatisfy { simd_length(simd_cross($0, far)) <= tolerance * max(1, reach) }
        return (fan, collinear)
    }
    let axisN = normal / length
    // u × v = n, so the projected polygon runs counter-clockwise.
    let helper: SIMD3<Double> = abs(axisN.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
    let axisU = simd_normalize(simd_cross(helper, axisN))
    let axisV = simd_cross(axisN, axisU)
    let p = p3.map { SIMD2(simd_dot($0, axisU), simd_dot($0, axisV)) }

    func orient(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
        let ab = b - a, ac = c - a
        return ab.x * ac.y - ab.y * ac.x
    }

    // Convex: every corner turns left or goes straight, and the turns add up to one full revolution.
    var turning = 0.0
    var turnsLeft = true
    for i in 0..<m {
        let a = p[(i + m - 1) % m], b = p[i], c = p[(i + 1) % m]
        let incoming = b - a, outgoing = c - b
        let turn = incoming.x * outgoing.y - incoming.y * outgoing.x
        if turn < -tolerance { turnsLeft = false; break }
        turning += atan2(turn, simd_dot(incoming, outgoing))
    }
    if turnsLeft, abs(turning - 2 * Double.pi) < 1e-6 { return (fan, true) }

    // Any other face must not cross or touch itself. Edges are swept in order of their lowest x (ties by index), so
    // only edges whose x ranges overlap are compared; a typical concave face costs close to linear time.
    func segmentsMeet(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
        func sign(_ v: Double) -> Int { v > tolerance ? 1 : (v < -tolerance ? -1 : 0) }
        func within(_ q: SIMD2<Double>, _ s: SIMD2<Double>, _ t: SIMD2<Double>) -> Bool {
            q.x >= min(s.x, t.x) - 1e-12 * extent && q.x <= max(s.x, t.x) + 1e-12 * extent
                && q.y >= min(s.y, t.y) - 1e-12 * extent && q.y <= max(s.y, t.y) + 1e-12 * extent
        }
        let o1 = sign(orient(a, b, c)), o2 = sign(orient(a, b, d)), o3 = sign(orient(c, d, a)), o4 = sign(orient(c, d, b))
        if o1 * o2 < 0, o3 * o4 < 0 { return true }
        return (o1 == 0 && within(c, a, b)) || (o2 == 0 && within(d, a, b))
            || (o3 == 0 && within(a, c, d)) || (o4 == 0 && within(b, c, d))
    }
    let slack = 1e-12 * extent
    let edgeLow = (0..<m).map { min(p[$0].x, p[($0 + 1) % m].x) }
    let edgeHigh = (0..<m).map { max(p[$0].x, p[($0 + 1) % m].x) }
    let sweep = (0..<m).sorted { edgeLow[$0] != edgeLow[$1] ? edgeLow[$0] < edgeLow[$1] : $0 < $1 }
    var active: [Int] = []
    for i in sweep {
        active.removeAll { edgeHigh[$0] < edgeLow[i] - slack }
        for j in active {
            let gap = abs(i - j)
            guard gap != 1, gap != m - 1 else { continue }
            work += 1
            if work > workLimit { return (fan, false) }
            let ylow = min(p[i].y, p[(i + 1) % m].y), yhigh = max(p[i].y, p[(i + 1) % m].y)
            let otherLow = min(p[j].y, p[(j + 1) % m].y), otherHigh = max(p[j].y, p[(j + 1) % m].y)
            guard ylow <= otherHigh + slack, otherLow <= yhigh + slack else { continue }
            if segmentsMeet(p[i], p[(i + 1) % m], p[j], p[(j + 1) % m]) { return (fan, false) }
        }
        active.append(i)
    }

    // Ear clipping. After each clip the search resumes at the clipped corner's neighbour, so each ear is usually found
    // within a few steps.
    func isConvex(_ a: Int, _ b: Int, _ c: Int) -> Bool { orient(p[a], p[b], p[c]) > tolerance }
    var next = Array(1...m), previous = Array(-1..<(m - 1))
    next[m - 1] = 0
    previous[0] = m - 1
    var alive = [Bool](repeating: true, count: m)
    var head = 0, remaining = m
    // Only corners that aren't strictly convex can lie inside an ear of a simple polygon, and clipping never makes a
    // corner reflex, so this list (sorted by x for range lookups, ties by index) only needs filtering.
    let blockers = (0..<m).filter { !isConvex(previous[$0], $0, next[$0]) }
        .sorted { p[$0].x != p[$1].x ? p[$0].x < p[$1].x : $0 < $1 }
    var local: [Int] = []
    local.reserveCapacity(3 * (m - 2))
    func clip(_ b: Int) {
        let a = previous[b], c = next[b]
        local += [a, b, c]
        next[a] = c
        previous[c] = a
        alive[b] = false
        if b == head { head = c }
        remaining -= 1
    }
    func isEar(_ b: Int) -> Bool {
        let a = previous[b], c = next[b]
        guard isConvex(a, b, c) else { return false }
        let lowX = min(p[a].x, p[b].x, p[c].x) - slack, highX = max(p[a].x, p[b].x, p[c].x) + slack
        // First blocker at or right of the ear's left edge.
        var lower = 0, upper = blockers.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if p[blockers[middle]].x < lowX { lower = middle + 1 } else { upper = middle }
        }
        var k = lower
        while k < blockers.count, p[blockers[k]].x <= highX {
            let q = blockers[k]
            k += 1
            guard alive[q], q != a, q != b, q != c else { continue }
            work += 1
            if work > workLimit { return false }
            // Inclusive: a corner on the ear's boundary, such as on the new diagonal, blocks it.
            if orient(p[a], p[b], p[q]) >= -tolerance, orient(p[b], p[c], p[q]) >= -tolerance,
               orient(p[c], p[a], p[q]) >= -tolerance { return false }
        }
        return true
    }
    /// A corner on a straight line between its neighbours: clipping it as a zero-area triangle leaves the shape as it
    /// is and keeps the surface closed.
    func isStraight(_ b: Int) -> Bool {
        let a = previous[b], c = next[b]
        return abs(orient(p[a], p[b], p[c])) <= tolerance && simd_dot(p[a] - p[b], p[c] - p[b]) < 0
    }
    var cursor = next[head]
    while remaining > 3 {
        guard work <= workLimit else { return (fan, false) }
        var target: Int?
        var candidate = cursor
        for _ in 0..<remaining {
            work += 1
            if isStraight(candidate) || isEar(candidate) { target = candidate; break }
            candidate = next[candidate]
        }
        guard let target else { return (fan, false) }
        cursor = previous[target]
        clip(target)
    }
    local += [head, next[head], next[next[head]]]
    return (local.map { order[$0] }, true)
}

// MARK: - 3MF

/// 3MF core geometry: the root model part (found through `_rels/.rels`), `unit`, objects with meshes or components,
/// `<build><item>` placement and 3×4 transforms, and production-extension `path` references to other model parts.
/// The root part's model-level `<metadata>` is read separately (`ThreeMFMetadataReader`) for designer and licence.
/// Colours, materials, slicer paint data and plate metadata are ignored.
enum ThreeMFReader {
    static let maximumDepth = 32
    static let maximumModelParts = 1_000
    static let maximumPlacements = 100_000
    static let modelRelationshipType = "http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"
    static let unitScale: [String: Double] = [
        "micron": 0.001, "millimeter": 1, "centimeter": 10, "inch": 25.4, "foot": 304.8, "meter": 1000
    ]

    static func read(_ data: Data) throws -> PreviewModel {
        do { return try readPackage(data) } catch { throw formatSpecific(error, .threeMF) }
    }

    private static func readPackage(_ data: Data) throws -> PreviewModel {
        guard data.count <= STLMesh.maximumBytes else { throw STLMesh.ParseError.oversized }
        let archive = try ZipArchive(data)
        var budget = STLMesh.maximumBytes
        func extract(_ entry: ZipArchive.Entry) throws -> Data {
            let part = try archive.extract(entry, limit: budget)
            budget -= part.count
            return part
        }

        let rootPath = try rootModelPath(archive, extract: extract)
        guard let rootEntry = archive.entry(named: rootPath) else { throw ModelFormatError.missingModel }
        // The root part's bytes are read once more for its metadata, then released before the geometry is built.
        let (root, sourceDetails) = try { () throws -> (ThreeMFModelPart, ModelSourceDetails) in
            let rootData = try extract(rootEntry)
            let part = try ThreeMFModelPart.parse(rootData, isRoot: true)
            return (part, modelSourceDetails(fromMetadata: ThreeMFMetadataReader.entries(in: rootData)))
        }()
        let unit = root.unit ?? "millimeter"
        guard let scale = unitScale[unit.lowercased()] else { throw ModelFormatError.unsupportedUnit(unit) }
        guard !root.items.isEmpty else { throw ModelFormatError.noBuildItems }

        // Parts are cached by entry name. The dictionary is only used for lookup; output follows build and component order.
        let rootName = rootEntry.name
        var parts: [String: ThreeMFModelPart] = [rootName: root]
        func part(_ path: String?, from current: String) throws -> String {
            guard let path, !path.isEmpty else { return current }
            let decoded = path.removingPercentEncoding ?? path
            guard let entry = archive.entry(named: decoded) ?? archive.entry(named: path) else {
                throw ModelFormatError.invalid3MF("a referenced model part (\(path)) is missing")
            }
            if parts[entry.name] != nil { return entry.name }
            guard parts.count < maximumModelParts else { throw ModelFormatError.invalid3MF("too many model parts") }
            parts[entry.name] = try ThreeMFModelPart.parse(try extract(entry), isRoot: false)
            return entry.name
        }

        // Count placed triangles before transforming any, so heavily instanced files fail fast. Counts saturate just
        // above the limit, so nested instancing can't overflow. The memo is only used for lookup. Each component
        // counted here is placed at least once below, so the same placement cap applies to this pass.
        let limit = STLMesh.maximumTriangles
        var counted: [String: Int] = [:]
        var countedComponents = 0
        func placedTriangles(objectID: Int, in partName: String, depth: Int) throws -> Int {
            guard depth <= maximumDepth else { throw ModelFormatError.tooDeep }
            let key = "\(partName)#\(objectID)"
            if let known = counted[key] { return known }
            guard let object = parts[partName]?.objects[objectID] else { throw ModelFormatError.missingObject(objectID) }
            var total = object.triangles.count / 3
            for component in object.components where total <= limit {
                countedComponents += 1
                guard countedComponents <= maximumPlacements else { throw STLMesh.ParseError.oversized }
                let child = try part(component.path, from: partName)
                total += try placedTriangles(objectID: component.objectID, in: child, depth: depth + 1)
            }
            total = min(total, limit + 1)
            counted[key] = total
            return total
        }
        var placed = 0
        for item in root.items where placed <= limit {
            placed += try placedTriangles(objectID: item.objectID, in: try part(item.path, from: rootName), depth: 0)
        }
        guard placed <= limit else { throw STLMesh.ParseError.oversized }

        var output: [Float] = []
        output.reserveCapacity(placed * 9)
        var extents: [SIMD3<Float>] = []
        // Bounds the walk even when nested components place empty objects an exponential number of times.
        var visits = 0
        func emit(objectID: Int, in partName: String, transform: Affine3D, depth: Int,
                  low: inout SIMD3<Double>, high: inout SIMD3<Double>) throws {
            guard depth <= maximumDepth else { throw ModelFormatError.tooDeep }
            visits += 1
            guard visits <= maximumPlacements else { throw STLMesh.ParseError.oversized }
            guard let object = parts[partName]?.objects[objectID] else { throw ModelFormatError.missingObject(objectID) }
            if !object.triangles.isEmpty {
                guard output.count / 9 + object.triangles.count / 3 <= limit else { throw STLMesh.ParseError.oversized }
                // A mirroring transform reverses winding; swap two corners so faces keep pointing outwards.
                let order = transform.determinant < 0 ? [0, 2, 1] : [0, 1, 2]
                for triangle in stride(from: 0, to: object.triangles.count, by: 3) {
                    for corner in order {
                        let index = Int(object.triangles[triangle + corner]) * 3
                        let local = SIMD3<Double>(Double(object.vertices[index]), Double(object.vertices[index + 1]),
                                                  Double(object.vertices[index + 2]))
                        let point = transform.apply(local) * scale
                        low = simd_min(low, point)
                        high = simd_max(high, point)
                        output.append(Float(point.x)); output.append(Float(point.y)); output.append(Float(point.z))
                    }
                }
            }
            for component in object.components {
                let childPart = try part(component.path, from: partName)
                try emit(objectID: component.objectID, in: childPart, transform: transform.then(component.transform),
                         depth: depth + 1, low: &low, high: &high)
            }
        }

        for item in root.items {
            let itemPart = try part(item.path, from: rootName)
            var low = SIMD3<Double>(repeating: .greatestFiniteMagnitude)
            var high = SIMD3<Double>(repeating: -.greatestFiniteMagnitude)
            try emit(objectID: item.objectID, in: itemPart, transform: item.transform, depth: 0, low: &low, high: &high)
            if low.x <= high.x { extents.append(SIMD3<Float>(high - low)) }
        }
        guard !output.isEmpty else { throw STLMesh.ParseError.empty }
        let mesh = try STLMesh.validated(output)
        return PreviewModel(mesh: mesh, format: .threeMF, objectCount: root.items.count, partExtents: extents,
                            sourceDetails: sourceDetails)
    }

    private static func rootModelPath(_ archive: ZipArchive, extract: (ZipArchive.Entry) throws -> Data) throws -> String {
        let fallback = "3D/3dmodel.model"
        guard let rels = archive.entry(named: "_rels/.rels") else {
            guard archive.entry(named: fallback) != nil else { throw ModelFormatError.missingModel }
            return fallback
        }
        for target in try ThreeMFRelationships.targets(in: try extract(rels), type: modelRelationshipType) {
            if archive.entry(named: target) != nil { return target }
            if let decoded = target.removingPercentEncoding, archive.entry(named: decoded) != nil { return decoded }
        }
        guard archive.entry(named: fallback) != nil else { throw ModelFormatError.missingModel }
        return fallback
    }
}

/// An affine map p ↦ a·p + t. 3MF writes row-vector matrices "m00 m01 m02 m10 m11 m12 m20 m21 m22 m30 m31 m32",
/// so x′ = x·m00 + y·m10 + z·m20 + m30 and each group of three is the image of a basis vector.
struct Affine3D: Equatable {
    var a: simd_double3x3
    var t: SIMD3<Double>
    static let identity = Affine3D(a: matrix_identity_double3x3, t: .zero)

    init(a: simd_double3x3, t: SIMD3<Double>) { self.a = a; self.t = t }

    init?(threeMF text: String) {
        let values = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
        guard values.count == 12, values.allSatisfy(\.isFinite) else { return nil }
        a = simd_double3x3(columns: (SIMD3(values[0], values[1], values[2]), SIMD3(values[3], values[4], values[5]),
                                     SIMD3(values[6], values[7], values[8])))
        t = SIMD3(values[9], values[10], values[11])
    }

    func apply(_ p: SIMD3<Double>) -> SIMD3<Double> { a * p + t }
    /// `inner` is applied first, then this transform (a component inside a placed object).
    func then(_ inner: Affine3D) -> Affine3D { Affine3D(a: a * inner.a, t: a * inner.t + t) }
    var determinant: Double { simd_determinant(a) }
}

struct ThreeMFReference {
    let objectID: Int
    let transform: Affine3D
    let path: String?
}

struct ThreeMFObject {
    var vertices: [Float] = []
    var triangles: [Int32] = []
    var components: [ThreeMFReference] = []
}

/// One model part (XML file) of a 3MF package.
struct ThreeMFModelPart {
    var unit: String?
    var objects: [Int: ThreeMFObject] = [:]
    var items: [ThreeMFReference] = []

    static func parse(_ data: Data, isRoot: Bool) throws -> ThreeMFModelPart {
        try rejectDocumentType(data)
        let delegate = ThreeMFModelDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        let ok = parser.parse()
        if let failure = delegate.failure { throw failure }
        guard ok else { throw ModelFormatError.invalid3MF("the model XML is malformed") }
        guard delegate.sawModel else { throw ModelFormatError.invalid3MF("the model part has no <model> element") }
        var part = delegate.part
        if !isRoot { part.items = [] }
        return part
    }
}

/// 3MF forbids DTDs. Refusing them up front also rules out entity-expansion attacks on the XML parser.
///
/// The scan covers UTF-8 and both UTF-16 byte orders (the encodings XML parsers must detect without a declaration)
/// within the first 64 KB, where a prolog normally sits. It is a fast first check, not the only one: both parser
/// delegates also abort on the first DTD declaration callback (entities, elements, attributes, notations), which
/// libxml2 reports while reading the DTD and before any entity is expanded, so a DTD hidden behind a long comment
/// or in another encoding is still refused.
private let documentTypeMarkers: [Data] = ["<!DOCTYPE", "<!ENTITY"].flatMap { marker -> [Data] in
    let units = Array(marker.utf16)
    return [Data(marker.utf8),
            Data(units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }),
            Data(units.flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] })]
}

private func rejectDocumentType(_ data: Data) throws {
    let prefix = data.prefix(64 * 1024)
    for marker in documentTypeMarkers where prefix.range(of: marker) != nil {
        throw ModelFormatError.invalid3MF("it contains a document type declaration")
    }
}

/// Base for both delegates: every DTD declaration callback refuses the document. These must be class methods, not a
/// protocol extension, because XMLParser only calls delegate methods the Objective-C runtime can see.
private class DocumentTypeRefusingDelegate: NSObject, XMLParserDelegate {
    func refuseDocumentType(_ parser: XMLParser) { parser.abortParsing() }

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        refuseDocumentType(parser)
    }
    func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String, publicID: String?, systemID: String?) {
        refuseDocumentType(parser)
    }
    func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String, publicID: String?, systemID: String?,
                notationName: String?) {
        refuseDocumentType(parser)
    }
    func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
        refuseDocumentType(parser)
    }
    func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String, forElement elementName: String,
                type: String?, defaultValue: String?) {
        refuseDocumentType(parser)
    }
    func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String, publicID: String?, systemID: String?) {
        refuseDocumentType(parser)
    }
}

private func localName(_ qualified: String) -> Substring {
    qualified.lastIndex(of: ":").map { qualified[qualified.index(after: $0)...] } ?? Substring(qualified)
}

/// Attribute lookup that ignores namespace prefixes, such as the production extension's `p:path`.
private func attribute(_ attributes: [String: String], _ name: String) -> String? {
    if let value = attributes[name] { return value }
    return attributes.first { localName($0.key) == name }?.value
}

private final class ThreeMFModelDelegate: DocumentTypeRefusingDelegate {
    var part = ThreeMFModelPart()
    var failure: Error?
    var sawModel = false
    private var objectID: Int?
    private var object = ThreeMFObject()
    private var inBuild = false
    private var parsedTriangles = 0
    private var parsedVertices = 0

    private func fail(_ parser: XMLParser, _ error: Error) {
        if failure == nil { failure = error }
        parser.abortParsing()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes: [String: String] = [:]) {
        guard failure == nil else { return }
        switch localName(elementName) {
        case "model":
            sawModel = true
            part.unit = attribute(attributes, "unit")
        case "object":
            guard let id = attribute(attributes, "id").flatMap(Int.init) else {
                return fail(parser, ModelFormatError.invalid3MF("an object has no valid id"))
            }
            objectID = id
            object = ThreeMFObject()
        case "vertex":
            guard objectID != nil else { return }
            guard let x = attribute(attributes, "x").flatMap(Float.init), let y = attribute(attributes, "y").flatMap(Float.init),
                  let z = attribute(attributes, "z").flatMap(Float.init), x.isFinite, y.isFinite, z.isFinite else {
                return fail(parser, ModelFormatError.invalid3MF("a vertex has invalid coordinates"))
            }
            parsedVertices += 1
            guard parsedVertices <= 3 * STLMesh.maximumTriangles else { return fail(parser, STLMesh.ParseError.oversized) }
            object.vertices.append(x); object.vertices.append(y); object.vertices.append(z)
        case "triangle":
            guard objectID != nil else { return }
            guard let v1 = attribute(attributes, "v1").flatMap(Int32.init), let v2 = attribute(attributes, "v2").flatMap(Int32.init),
                  let v3 = attribute(attributes, "v3").flatMap(Int32.init) else {
                return fail(parser, ModelFormatError.invalid3MF("a triangle has invalid vertex indices"))
            }
            parsedTriangles += 1
            guard parsedTriangles <= 2 * STLMesh.maximumTriangles else { return fail(parser, STLMesh.ParseError.oversized) }
            object.triangles.append(v1); object.triangles.append(v2); object.triangles.append(v3)
        case "component":
            guard objectID != nil else { return }
            guard let reference = reference(attributes) else {
                return fail(parser, ModelFormatError.invalid3MF("a component is invalid"))
            }
            object.components.append(reference)
        case "build":
            inBuild = true
        case "item":
            guard inBuild else { return }
            guard let reference = reference(attributes) else {
                return fail(parser, ModelFormatError.invalid3MF("a build item is invalid"))
            }
            part.items.append(reference)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard failure == nil else { return }
        switch localName(elementName) {
        case "object":
            guard let id = objectID else { return }
            let count = Int32(object.vertices.count / 3)
            if object.triangles.contains(where: { $0 < 0 || $0 >= count }) {
                return fail(parser, ModelFormatError.invalid3MF("object \(id) has a triangle that refers to a missing vertex"))
            }
            guard part.objects[id] == nil else { return fail(parser, ModelFormatError.invalid3MF("object \(id) is defined twice")) }
            part.objects[id] = object
            objectID = nil
            object = ThreeMFObject()
        case "build":
            inBuild = false
        default:
            break
        }
    }

    override func refuseDocumentType(_ parser: XMLParser) {
        fail(parser, ModelFormatError.invalid3MF("it contains a document type declaration"))
    }

    private func reference(_ attributes: [String: String]) -> ThreeMFReference? {
        guard let id = attribute(attributes, "objectid").flatMap(Int.init) else { return nil }
        var transform = Affine3D.identity
        if let text = attribute(attributes, "transform") {
            guard let parsed = Affine3D(threeMF: text) else { return nil }
            transform = parsed
        }
        return ThreeMFReference(objectID: id, transform: transform, path: attribute(attributes, "path"))
    }
}

/// Relationship targets of one type from an OPC `.rels` part.
enum ThreeMFRelationships {
    static func targets(in data: Data, type: String) throws -> [String] {
        try rejectDocumentType(data)
        let delegate = RelationshipsDelegate(type: type)
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() else { throw ModelFormatError.invalid3MF("its package relationships are malformed") }
        return delegate.targets
    }

    private final class RelationshipsDelegate: DocumentTypeRefusingDelegate {
        let type: String
        var targets: [String] = []
        init(type: String) { self.type = type }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            guard localName(elementName) == "Relationship", attribute(attributes, "Type") == type,
                  let target = attribute(attributes, "Target") else { return }
            targets.append(target)
        }
    }
}

/// Model-level `<metadata name="…">value</metadata>` entries of a 3MF model part, in document order (3MF Core
/// Specification §3.4.1: children of `<model>`, before `<resources>`). Object-level metadata groups are not read.
///
/// This is a second, separate pass over a part the geometry parser has already accepted (so DTDs are already refused,
/// and are refused again here). It stops at the first `<resources>`, `<build>` or `<object>`, so it costs next to
/// nothing on large meshes, and it is bounded: at most `maximumEntries` entries of `maximumValueLength` characters
/// each. Metadata is advisory, so a failure here never fails the preview; it just yields fewer entries.
enum ThreeMFMetadataReader {
    static let maximumEntries = 64
    static let maximumValueLength = 4_096

    static func entries(in data: Data) -> [(name: String, value: String)] {
        guard (try? rejectDocumentType(data)) != nil else { return [] }
        let delegate = MetadataDelegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        _ = parser.parse()  // Usually aborted on purpose at <resources>; what was read before that is kept.
        return delegate.refused ? [] : delegate.entries
    }

    private final class MetadataDelegate: DocumentTypeRefusingDelegate {
        var entries: [(name: String, value: String)] = []
        var refused = false
        private var depth = 0
        private var modelDepth: Int?
        private var current: (name: String, value: String)?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            depth += 1
            let name = localName(elementName)
            if modelDepth == nil {
                if name == "model" { modelDepth = depth }
                return
            }
            guard let modelDepth, depth == modelDepth + 1 else { return }
            switch name {
            case "resources", "build", "object":
                parser.abortParsing()
            case "metadata":
                guard entries.count < maximumEntries else { return parser.abortParsing() }
                current = (attribute(attributes, "name") ?? "", "")
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            if let entry = current, let modelDepth, depth == modelDepth + 1 {
                if !entry.name.isEmpty { entries.append(entry) }
                current = nil
            }
            depth -= 1
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { append(string) }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            append(String(decoding: CDATABlock, as: UTF8.self))
        }

        private func append(_ text: String) {
            guard var entry = current, entry.value.utf16.count < maximumValueLength else { return }
            entry.value += text
            if entry.value.utf16.count > maximumValueLength {
                entry.value = String(entry.value.prefix(maximumValueLength))
            }
            current = entry
        }

        override func refuseDocumentType(_ parser: XMLParser) {
            refused = true
            parser.abortParsing()
        }
    }
}
