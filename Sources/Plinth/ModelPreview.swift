import SwiftUI
import SceneKit

/// A local preview. Rendering a model does not upload or transmit its contents.
struct ModelPreview: View {
    let url: URL?
    var showsPrintBed = false
    /// Show Overhangs leaves out internal walls' slot ceilings, as Review for Printing does on print-ready copies.
    var overhangsIgnoreNarrowCeilings = false
    /// Reports the parsed model (or nil) for the URL just loaded, so callers can check it without parsing again.
    var onModelChange: ((URL, PreviewModel?) -> Void)? = nil
    @State private var model: PreviewModel?
    @State private var failure: String?
    @State private var isLoading = false
    /// The URL `model` was read from; the overhang work starts only once it is set.
    @State private var loadedURL: URL?
    /// Show Overhangs (PreviewOverhangs.swift): display only, remembered as a plain preference.
    @AppStorage(previewShowOverhangsDefaultsKey) private var showOverhangs = false
    /// The overhang caption says the 50° rule is Slant's while 3DAPI is the print service.
    @ObservedObject private var printChoice = PrintServiceChoice.shared
    /// The tint and the URL it was worked out for: shown only while that is still the loaded model.
    @State private var overhangs: (url: URL, highlight: PreviewOverhangHighlight)?
    private var currentOverhangs: PreviewOverhangHighlight? {
        guard let overhangs, overhangs.url == loadedURL else { return nil }
        return overhangs.highlight
    }

    private struct OverhangWork: Equatable {
        let url: URL?
        let show: Bool
        let ignoreNarrowCeilings: Bool
    }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let model {
                STLSceneView(mesh: model.mesh, showsPrintBed: showsPrintBed, overhangs: showOverhangs ? currentOverhangs : nil)
                    // Named for VoiceOver from what the caption already shows; never the file's path or name.
                    .accessibilityElement()
                    .accessibilityLabel("3D preview")
                    .accessibilityValue(previewAccessibilityValue(model, overhangsShown: showOverhangs && currentOverhangs != nil))
                    .accessibilityAddTraits(.isImage)
                VStack {
                    Spacer()
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Label("Drag to orbit · Scroll to zoom", systemImage: "rotate.3d")
                            Spacer(minLength: 8)
                            Text("\(model.mesh.triangleCount.formatted()) triangles")
                        }
                        HStack(alignment: .firstTextBaseline) {
                            Text(previewDimensionsLabel(model))
                            Spacer(minLength: 8)
                            // A regular-size control (the overlay's captions beside it keep the caption style).
                            Toggle(previewShowOverhangsTitle, isOn: $showOverhangs)
                                .toggleStyle(.checkbox)
                                .controlSize(.regular)
                                .font(.body)
                                .foregroundStyle(.primary)
                                .accessibilityLabel(previewShowOverhangsTitle)
                                .accessibilityValue(previewOverhangAccessibilityValue(isOn: showOverhangs, share: currentOverhangs?.share))
                                .help(previewShowOverhangsHelp)
                        }
                        if showOverhangs {
                            Text(previewOverhangCaption(currentOverhangs?.share, forDapi: printChoice.service == .dapi))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if let warning = previewBuildVolumeWarning(model) {
                            Label(warning, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.studioWarning)
                        }
                        if let notice = multipleObjectsNotice(objectCount: model.objectCount) {
                            Label(notice, systemImage: "square.stack.3d.up")
                                .fixedSize(horizontal: false, vertical: true)
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
                    Text(failure ?? "Choose an STL, OBJ or 3MF file to inspect it in 3D.")
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task(id: OverhangWork(url: loadedURL, show: showOverhangs, ignoreNarrowCeilings: overhangsIgnoreNarrowCeilings)) {
            // Off the main actor; a model switched or the toggle turned off meanwhile cancels it, and a late result
            // for an earlier model is dropped.
            overhangs = nil
            guard showOverhangs, let loaded = loadedURL, let mesh = model?.mesh else { return }
            let ignore = overhangsIgnoreNarrowCeilings
            let worker = Task.detached(priority: .userInitiated) {
                previewOverhangHighlight(mesh, ignoringNarrowCeilings: ignore, isCancelled: { Task.isCancelled })
            }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, loadedURL == loaded, showOverhangs, let result else { return }
            overhangs = (loaded, result)
        }
        .task(id: url) {
            model = nil
            loadedURL = nil
            failure = nil
            guard let url else { isLoading = false; return }
            if !supportsLocalPreview(url) {
                failure = unsupportedPreviewMessage
                isLoading = false
                return
            }
            isLoading = true
            let worker = Task.detached(priority: .userInitiated) {
                Result { try loadPreviewModel(from: url) }
            }
            let result = await worker.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let loaded):
                model = loaded
                loadedURL = url
            case .failure(let error): failure = error.localizedDescription
            }
            isLoading = false
            onModelChange?(url, model)
        }
    }
}

let unsupportedPreviewMessage = "Preview is available for STL, OBJ and 3MF files."

func supportsLocalPreview(_ url: URL) -> Bool {
    ModelFileFormat(url: url) != nil
}

/// Overall dimensions; a file with several placed objects is labelled as the overall layout.
func previewDimensionsLabel(_ model: PreviewModel) -> String {
    let extent = model.mesh.maximum - model.mesh.minimum
    let label = footprintLabel((extent.x, extent.y, extent.z))
    return model.objectCount > 1 ? "Overall \(label)" : label
}

/// The 3D preview's VoiceOver value, from the caption's own text: dimensions and triangle count (never a path).
func previewAccessibilityValue(_ model: PreviewModel, overhangsShown: Bool) -> String {
    let triangles = model.mesh.triangleCount == 1 ? "1 triangle" : "\(model.mesh.triangleCount.formatted()) triangles"
    return "\(previewDimensionsLabel(model)), \(triangles)\(overhangsShown ? ", overhangs tinted orange" : "")"
}

/// Checks each placed object, so objects spread across a plate aren't flagged as one oversized part.
func previewBuildVolumeWarning(_ model: PreviewModel) -> String? {
    guard previewExceedsBuildVolume(model) else { return nil }
    return model.partExtents.count > 1
        ? "An object is larger than Slant’s 220 mm build volume"
        : "Larger than Slant’s 220 mm build volume"
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

    static func parse(_ data: Data) throws -> STLMesh { try parse(data, maximumTriangles: maximumTriangles) }

    /// The same reader with another triangle limit. Only the replica pipeline passes a higher one, for a generated model
    /// it simplifies in memory before anything is saved; the library and every other reader keep `maximumTriangles`.
    static func parse(_ data: Data, maximumTriangles: Int) throws -> STLMesh {
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
                vertices = [Float](repeating: 0, count: count * 9)
                vertices.withUnsafeMutableBufferPointer { output in
                    data.withUnsafeBytes { raw in
                        for triangle in 0..<count {
                            let base = 84 + triangle * 50 + 12
                            for component in 0..<9 {
                                let bits = UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: base + component * 4, as: UInt32.self))
                                output[triangle * 9 + component] = Float(bitPattern: bits)
                            }
                        }
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

    /// Requires finite, bounded coordinates and a non-flat bounding box; shared with the OBJ and 3MF readers.
    static func validated(_ vertices: [Float]) throws -> STLMesh {
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
    /// Show Overhangs' tinted triangles, or nil for one colour. Display only.
    var overhangs: PreviewOverhangHighlight? = nil

    /// The model's node and buffers, so the tint can change without rebuilding the scene or moving the camera.
    final class Coordinator {
        var modelNode: SCNNode?
        var sources: [SCNGeometrySource] = []
        var triangleCount = 0
        var applied: PreviewOverhangHighlight?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = NSColor(calibratedWhite: 0.105, alpha: 1)
        view.antialiasingMode = .multisampling4X
        view.allowsCameraControl = true
        view.autoenablesDefaultLighting = false
        view.scene = makeScene(context.coordinator)
        applyOverhangs(context.coordinator)
        view.defaultCameraController.target = SCNVector3Zero
        view.defaultCameraController.inertiaEnabled = true
        return view
    }

    func updateNSView(_ view: SCNView, context: Context) {
        // The enclosing view removes this representable while a new URL loads; only the tint changes here.
        applyOverhangs(context.coordinator)
    }

    private static func previewMaterial(_ color: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.diffuse.contents = color
        material.lightingModel = .physicallyBased
        material.roughness.contents = 0.65
        material.metalness.contents = 0.05
        material.isDoubleSided = true
        return material
    }

    private static let plainColour = NSColor(calibratedRed: 0.72, green: 0.79, blue: 0.84, alpha: 1)
    private static let overhangColour = NSColor(calibratedRed: 0.96, green: 0.48, blue: 0.16, alpha: 1)

    /// One plain element (as before) without a tint; with one, the plain and tinted triangles as two indexed elements
    /// over the same buffers, each with its own material.
    private func applyOverhangs(_ coordinator: Coordinator) {
        guard let node = coordinator.modelNode, coordinator.applied !== overhangs || node.geometry == nil else { return }
        coordinator.applied = overhangs
        var elements: [SCNGeometryElement] = []
        var materials: [SCNMaterial] = []
        if let overhangs, overhangs.plainTriangles + overhangs.overhangTriangles == coordinator.triangleCount {
            if overhangs.plainTriangles > 0 {
                elements.append(SCNGeometryElement(data: overhangs.plainIndices, primitiveType: .triangles,
                                                   primitiveCount: overhangs.plainTriangles, bytesPerIndex: 4))
                materials.append(Self.previewMaterial(Self.plainColour))
            }
            if overhangs.overhangTriangles > 0 {
                elements.append(SCNGeometryElement(data: overhangs.overhangIndices, primitiveType: .triangles,
                                                   primitiveCount: overhangs.overhangTriangles, bytesPerIndex: 4))
                materials.append(Self.previewMaterial(Self.overhangColour))
            }
        }
        if elements.isEmpty {
            elements = [SCNGeometryElement(data: nil, primitiveType: .triangles, primitiveCount: coordinator.triangleCount,
                                           bytesPerIndex: 0)]
            materials = [Self.previewMaterial(Self.plainColour)]
        }
        let geometry = SCNGeometry(sources: coordinator.sources, elements: elements)
        geometry.materials = materials
        node.geometry = geometry
    }

    private func makeScene(_ coordinator: Coordinator) -> SCNScene {
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
        // The geometry itself is set by `applyOverhangs`, plain or tinted.
        coordinator.sources = [source(normalized, semantic: .vertex), source(normals, semantic: .normal)]
        coordinator.triangleCount = mesh.triangleCount
        let model = SCNNode()
        coordinator.modelNode = model
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

/// Show Overhangs' help: the tint is Slant's 50° limit (`overhangTriangleMask`, the same faces as Plinth's advisory
/// for overhangs past that limit), while Plinth's other overhang figures use 45°, a margin under it.
let previewShowOverhangsHelp = "Tints faces that point down more steeply than Slant’s 50° overhang limit, the same faces as Plinth’s note about overhangs past that limit. Plinth’s other overhang figures use 45°, a margin under Slant’s limit, so they can be larger. Display only: the model isn’t changed."
