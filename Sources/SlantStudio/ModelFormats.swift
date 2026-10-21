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
}

enum ModelFormatError: LocalizedError, Equatable {
    case obj(line: Int, reason: String)
    case missingModel
    case missingObject(Int)
    case unsupportedUnit(String)
    case noBuildItems
    case invalid3MF(String)
    case tooDeep

    var errorDescription: String? {
        switch self {
        case .obj(let line, let reason): return "This OBJ couldn’t be read (line \(line): \(reason))."
        case .missingModel: return "This 3MF doesn’t contain a 3D model part."
        case .missingObject(let id): return "This 3MF refers to object \(id), which it doesn’t contain."
        case .unsupportedUnit(let unit): return "This 3MF uses an unknown unit (“\(unit)”)."
        case .noBuildItems: return "This 3MF doesn’t place any objects on its build plate."
        case .invalid3MF(let reason): return "This 3MF couldn’t be read: \(reason)."
        case .tooDeep: return "This 3MF nests components too deeply to preview."
        }
    }
}

/// Reads any model the library accepts, within the same 128 MB / 500,000-triangle limits as STL.
func loadPreviewModel(from url: URL) throws -> PreviewModel {
    guard let format = ModelFileFormat(url: url) else { throw STLMesh.ParseError.unsupported }
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
        let mesh = try OBJParser.parse(data)
        return PreviewModel(mesh: mesh, format: .obj, objectCount: 1, partExtents: [mesh.maximum - mesh.minimum])
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
    return "This file places \(objectCount) objects, previewed as arranged in the file. Uploading sends the whole file, so check that the estimate covers everything you expect to print."
}

/// The scale check for formats without units. 3MF declares its unit, which the preview has already applied.
func scaleWarning(extentMM: SIMD3<Float>, fileExtension: String) -> ScaleWarning? {
    let format = ModelFileFormat(rawValue: fileExtension.lowercased()) ?? .stl
    guard !format.recordsUnits, var warning = scaleWarning(extentMM: extentMM) else { return nil }
    warning.formatName = format.displayName
    return warning
}

// MARK: - OBJ

/// Wavefront OBJ geometry: `v` and `f` only. Polygons are fan-triangulated in index order; texture coordinates, normals,
/// groups, materials, lines and points are ignored. Indices may be negative (relative to the latest vertex).
enum OBJParser {
    static let maximumVertices = 3 * STLMesh.maximumTriangles
    static let maximumLineBytes = 65_536

    static func parse(_ data: Data) throws -> STLMesh {
        guard data.count <= STLMesh.maximumBytes else { throw STLMesh.ParseError.oversized }
        guard let source = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw STLMesh.ParseError.malformed
        }
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
                let first = positions[corners[0]]
                for corner in 1..<(corners.count - 1) {
                    let b = positions[corners[corner]], c = positions[corners[corner + 1]]
                    for point in [first, b, c] { output.append(point.x); output.append(point.y); output.append(point.z) }
                }
            default:
                break
            }
        }
        if let failure { throw failure }
        guard !output.isEmpty else { throw STLMesh.ParseError.empty }
        return try STLMesh.validated(output)
    }
}

// MARK: - 3MF

/// 3MF core geometry: the root model part (found through `_rels/.rels`), `unit`, objects with meshes or components,
/// `<build><item>` placement and 3×4 transforms, and production-extension `path` references to other model parts.
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
        let root = try ThreeMFModelPart.parse(try extract(rootEntry), isRoot: true)
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
        // above the limit, so nested instancing can't overflow. The memo is only used for lookup.
        let limit = STLMesh.maximumTriangles
        var counted: [String: Int] = [:]
        func placedTriangles(objectID: Int, in partName: String, depth: Int) throws -> Int {
            guard depth <= maximumDepth else { throw ModelFormatError.tooDeep }
            let key = "\(partName)#\(objectID)"
            if let known = counted[key] { return known }
            guard let object = parts[partName]?.objects[objectID] else { throw ModelFormatError.missingObject(objectID) }
            var total = object.triangles.count / 3
            for component in object.components where total <= limit {
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
        return PreviewModel(mesh: mesh, format: .threeMF, objectCount: root.items.count, partExtents: extents)
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
private func rejectDocumentType(_ data: Data) throws {
    let prefix = data.prefix(64 * 1024)
    for marker in ["<!DOCTYPE", "<!ENTITY"] where prefix.range(of: Data(marker.utf8)) != nil {
        throw ModelFormatError.invalid3MF("it contains a document type declaration")
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

private final class ThreeMFModelDelegate: NSObject, XMLParserDelegate {
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

    func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
        fail(parser, ModelFormatError.invalid3MF("it contains an entity declaration"))
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

    private final class RelationshipsDelegate: NSObject, XMLParserDelegate {
        let type: String
        var targets: [String] = []
        init(type: String) { self.type = type }
        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            guard localName(elementName) == "Relationship", attribute(attributes, "Type") == type,
                  let target = attribute(attributes, "Target") else { return }
            targets.append(target)
        }
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            parser.abortParsing()
        }
    }
}
