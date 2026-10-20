import SwiftUI
import SceneKit

/// A local preview. Rendering a model does not upload or transmit its contents.
struct ModelPreview: View {
    let url: URL?
    var showsPrintBed = false
    /// Reports the parsed mesh (or nil) for the URL just loaded, so callers can check it without parsing again.
    var onMeshChange: ((URL, STLMesh?) -> Void)? = nil
    @State private var mesh: STLMesh?
    @State private var failure: String?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let mesh {
                STLSceneView(mesh: mesh, showsPrintBed: showsPrintBed)
                VStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Drag to orbit · Scroll to zoom", systemImage: "rotate.3d")
                            Spacer(minLength: 8)
                            Text("\(mesh.triangleCount.formatted()) triangles")
                        }
                        if let footprint = meshFootprint(mesh) {
                            Text(footprintLabel(footprint))
                            if exceedsSlantBuildVolume(footprint) {
                                Label("Larger than Slant’s 220 mm build volume", systemImage: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .background(.regularMaterial)
                }
            } else if isLoading {
                ProgressView("Reading model…")
            } else {
                ContentUnavailableView {
                    Label(failure == nil ? "Model preview" : "Preview unavailable", systemImage: "cube.transparent")
                } description: {
                    Text(failure ?? "Choose an STL file to inspect it in 3D.")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: url) {
            mesh = nil
            failure = nil
            guard let url else { isLoading = false; return }
            if !supportsLocalPreview(url) {
                failure = nonSTLPreviewMessage
                isLoading = false
                return
            }
            isLoading = true
            let worker = Task.detached(priority: .userInitiated) {
                Result { try STLMesh.read(from: url) }
            }
            let result = await worker.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let loaded): mesh = loaded
            case .failure(let error): failure = error.localizedDescription
            }
            isLoading = false
            onMeshChange?(url, mesh)
        }
    }
}

let nonSTLPreviewMessage = "Preview is available for STL files. This model can still be uploaded, estimated and ordered."

func supportsLocalPreview(_ url: URL) -> Bool {
    url.pathExtension.lowercased() == "stl"
}

/// Bounding box in model units when a mesh is available; nil when there is no preview mesh.
func meshFootprint(_ mesh: STLMesh?) -> (width: Float, depth: Float, height: Float)? {
    guard let mesh else { return nil }
    let extent = mesh.maximum - mesh.minimum
    return (extent.x, extent.y, extent.z)
}

/// Slant prints on a 220 × 220 × 220 mm bed and reads model units as millimetres.
let slantBuildVolumeMM: Float = 220
/// Slant’s documented 250 MB upload limit, counted in decimal megabytes so the check never lets an oversized file through.
let slantMaximumUploadBytes = 250_000_000

func exceedsSlantBuildVolume(_ footprint: (width: Float, depth: Float, height: Float)) -> Bool {
    max(footprint.width, footprint.depth, footprint.height) > slantBuildVolumeMM
}

func footprintLabel(_ footprint: (width: Float, depth: Float, height: Float)) -> String {
    let values = [footprint.width, footprint.depth, footprint.height].map { String(format: "%.1f", $0) }
    return values.joined(separator: " × ") + " mm"
}

func uploadSizeProblem(fileBytes: Int) -> String? {
    guard fileBytes > slantMaximumUploadBytes else { return nil }
    let megabytes = Int((Double(fileBytes) / 1_000_000).rounded(.up))
    return "This model is \(megabytes) MB. Slant accepts files up to 250 MB, so reduce its size before uploading."
}

/// Pure-data parser, usable independently of SceneKit for validation and tests.
struct STLMesh: Sendable {
    let vertices: [Float]
    let minimum: SIMD3<Float>
    let maximum: SIMD3<Float>
    var triangleCount: Int { vertices.count / 9 }

    enum ParseError: LocalizedError {
        case unsupported, oversized, malformed, empty
        var errorDescription: String? {
            switch self {
            case .unsupported: return "Local preview supports binary and ASCII STL files."
            case .oversized: return "This model exceeds the preview limit of 500,000 triangles or 128 MB."
            case .malformed: return "This STL contains incomplete triangles or invalid coordinates."
            case .empty: return "This STL does not contain any triangles."
            }
        }
    }

    static let maximumTriangles = 500_000
    static let maximumBytes = 128 * 1024 * 1024

    static func read(from url: URL) throws -> STLMesh {
        guard url.pathExtension.lowercased() == "stl" else { throw ParseError.unsupported }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= maximumBytes else { throw ParseError.oversized }
        return try parse(Data(contentsOf: url, options: .mappedIfSafe))
    }

    static func parse(_ data: Data) throws -> STLMesh {
        guard data.count <= maximumBytes else { throw ParseError.oversized }
        var vertices: [Float] = []
        // Read bytes explicitly: binary STL fields may be unaligned in memory.
        func uint32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | (UInt32(data[data.startIndex + offset + $1]) << ($1 * 8)) }
        }
        if data.count >= 84 {
            let count = Int(uint32(80))
            let expectedSize = 84 + count * 50
            // Binary headers may begin with "solid"; the length is authoritative.
            if expectedSize == data.count || (count > 0 && expectedSize < data.count && !data.prefix(5).elementsEqual("solid".utf8)) {
                guard count <= maximumTriangles else { throw ParseError.oversized }
                guard count > 0 else { throw ParseError.empty }
                vertices.reserveCapacity(count * 9)
                for triangle in 0..<count {
                    let base = 84 + triangle * 50 + 12
                    for component in 0..<9 {
                        vertices.append(Float(bitPattern: uint32(base + component * 4)))
                    }
                }
                return try validated(vertices)
            }
        }
        guard let source = String(data: data, encoding: .utf8),
              source.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("solid") else {
            throw ParseError.malformed
        }
        var invalid = false
        var tooLarge = false
        var facetVertices: Int?
        var facetCount = 0
        source.enumerateLines { line, stop in
            // Bound token allocation even for a malicious single-line ASCII file.
            guard line.utf8.count <= 4096 else { invalid = true; stop = true; return }
            let tokens = line.split(whereSeparator: { $0.isWhitespace })
            guard let first = tokens.first else { return }
            switch first {
            case "facet":
                if facetVertices != nil { invalid = true; stop = true }
                facetVertices = 0
            case "vertex":
                guard let current = facetVertices, current < 3, tokens.count == 4,
                      let x = Float(tokens[1]), let y = Float(tokens[2]), let z = Float(tokens[3]) else {
                    invalid = true; stop = true; return
                }
                guard vertices.count < maximumTriangles * 9 else { tooLarge = true; stop = true; return }
                vertices.append(contentsOf: [x, y, z])
                facetVertices = current + 1
            case "endfacet":
                guard facetVertices == 3 else { invalid = true; stop = true; return }
                facetVertices = nil
                facetCount += 1
            default: break
            }
        }
        if tooLarge { throw ParseError.oversized }
        guard !invalid, facetVertices == nil, facetCount * 9 == vertices.count else { throw ParseError.malformed }
        return try validated(vertices)
    }

    private static func validated(_ vertices: [Float]) throws -> STLMesh {
        guard !vertices.isEmpty else { throw ParseError.empty }
        var low = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
        var high = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
        for index in stride(from: 0, to: vertices.count, by: 3) {
            let point = SIMD3<Float>(vertices[index], vertices[index + 1], vertices[index + 2])
            for axis in 0..<3 {
                guard point[axis].isFinite, abs(point[axis]) <= 1e10 else { throw ParseError.malformed }
                low[axis] = min(low[axis], point[axis])
                high[axis] = max(high[axis], point[axis])
            }
        }
        guard (high - low).max() > 0 else { throw ParseError.malformed }
        return STLMesh(vertices: vertices, minimum: low, maximum: high)
    }
}

/// Matches the centered, scaled mesh after STL Z becomes SceneKit Y.
func previewBedHeight(_ mesh: STLMesh) -> Float {
    let extent = mesh.maximum - mesh.minimum
    return -extent.z * 0.5 * (8 / extent.max())
}

struct STLSceneView: NSViewRepresentable {
    let mesh: STLMesh
    var showsPrintBed = false

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = makeScene()
        view.defaultCameraController.target = SCNVector3Zero
        view.defaultCameraController.inertiaEnabled = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        // The enclosing view removes this representable while a new URL loads.
    }

    private func makeScene() -> SCNScene {
        let scene = SCNScene()
        let extent = mesh.maximum - mesh.minimum
        let center = (mesh.maximum + mesh.minimum) * 0.5
        let scale = 8 / extent.max()
        var normalized: [Float] = []
        var normals: [Float] = []
        normalized.reserveCapacity(mesh.vertices.count)
        normals.reserveCapacity(mesh.vertices.count)
        for offset in stride(from: 0, to: mesh.vertices.count, by: 9) {
            func point(_ delta: Int) -> SIMD3<Float> {
                (SIMD3<Float>(mesh.vertices[offset + delta], mesh.vertices[offset + delta + 1], mesh.vertices[offset + delta + 2]) - center) * scale
            }
            let a = point(0), b = point(3), c = point(6)
            let cross = simd_cross(b - a, c - a)
            let normal = simd_length_squared(cross) > 1e-16 ? simd_normalize(cross) : SIMD3<Float>(0, 1, 0)
            for p in [a, b, c] {
                normalized.append(contentsOf: [p.x, p.y, p.z])
                normals.append(contentsOf: [normal.x, normal.y, normal.z])
            }
        }
        func source(_ floats: [Float], semantic: SCNGeometrySource.Semantic) -> SCNGeometrySource {
            let data = floats.withUnsafeBufferPointer { Data(buffer: $0) }
            return SCNGeometrySource(data: data, semantic: semantic, vectorCount: floats.count / 3,
                                     usesFloatComponents: true, componentsPerVector: 3, bytesPerComponent: 4,
                                     dataOffset: 0, dataStride: 12)
        }
        let geometry = SCNGeometry(sources: [source(normalized, semantic: .vertex), source(normals, semantic: .normal)],
                                   elements: [SCNGeometryElement(data: nil, primitiveType: .triangles,
                                                                primitiveCount: mesh.triangleCount, bytesPerIndex: 0)])
        let material = SCNMaterial()
        material.diffuse.contents = NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.84, alpha: 1)
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.65
        material.metalness.contents = 0.05
        material.isDoubleSided = true
        geometry.materials = [material]
        let model = SCNNode(geometry: geometry)
        // STL printing coordinates conventionally use Z as the vertical axis.
        model.eulerAngles.x = -.pi / 2
        scene.rootNode.addChildNode(model)

        if showsPrintBed {
            // Illustrative local bed, not a claimed Slant plate size or packing layout.
            let bed = SCNPlane(width: 10, height: 10)
            bed.firstMaterial?.diffuse.contents = NSColor(calibratedWhite: 0.23, alpha: 1)
            bed.firstMaterial?.roughness.contents = 1
            bed.firstMaterial?.isDoubleSided = true
            let bedNode = SCNNode(geometry: bed)
            bedNode.eulerAngles.x = -.pi / 2
            bedNode.simdPosition.y = previewBedHeight(mesh) - 0.002
            scene.rootNode.addChildNode(bedNode)
        }

        // Axis markers use the same STL-to-scene mapping as the mesh, so the
        // purpose picker can refer to visible source axes while the camera orbits.
        let origin = SIMD3<Float>(-5, -extent.z * scale / 2, 4)
        let axes: [(String, SIMD3<Float>, NSColor)] = [
            ("X", SIMD3(1.5, 0, 0), .systemRed),
            ("Y", SIMD3(0, 0, -1.5), .systemGreen),
            ("Z", SIMD3(0, 1.5, 0), .systemBlue)
        ]
        for (label, direction, color) in axes {
            let end = origin + direction
            let line = SCNGeometry(sources: [SCNGeometrySource(vertices: [SCNVector3(origin), SCNVector3(end)])],
                                   elements: [SCNGeometryElement(indices: [Int32(0), Int32(1)], primitiveType: .line)])
            line.firstMaterial?.diffuse.contents = color
            line.firstMaterial?.lightingModel = .constant
            scene.rootNode.addChildNode(SCNNode(geometry: line))
            let text = SCNText(string: label, extrusionDepth: 0)
            text.font = .systemFont(ofSize: 1, weight: .bold)
            text.firstMaterial?.diffuse.contents = color
            text.firstMaterial?.lightingModel = .constant
            let node = SCNNode(geometry: text)
            node.simdPosition = end
            node.scale = SCNVector3(0.5, 0.5, 0.5)
            node.constraints = [SCNBillboardConstraint()]
            scene.rootNode.addChildNode(node)
        }

        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.01
        camera.camera?.zFar = 1000
        camera.position = SCNVector3(11, 8, 12)
        camera.look(at: SCNVector3Zero)
        scene.rootNode.addChildNode(camera)
        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 500
        scene.rootNode.addChildNode(ambient)
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .omni
        key.light?.intensity = 1300
        key.position = SCNVector3(5, 12, 9)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .omni
        fill.light?.intensity = 700
        fill.position = SCNVector3(-8, 3, -6)
        scene.rootNode.addChildNode(fill)
        return scene
    }
}
