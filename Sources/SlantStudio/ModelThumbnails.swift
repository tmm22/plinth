import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers
import simd

// MARK: - Files

func fileModificationDate(_ url: URL) -> Date? {
    try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
}

enum ModelThumbnails {
    /// Edge length in pixels; a 30 pt library tile is 60 px on a Retina display.
    static let pixelSize = 96

    @MainActor static var directory: URL { StudioStore.supportDirectory.appendingPathComponent("Thumbnails", isDirectory: true) }

    @MainActor static func url(for id: UUID) -> URL { url(for: id, in: directory) }

    static func url(for id: UUID, in directory: URL) -> URL {
        directory.appendingPathComponent("\(id.uuidString).png")
    }
}

/// A cached thumbnail is reused only when it is at least as new as the model file it shows.
func thumbnailIsCurrent(thumbnailModified: Date?, modelModified: Date?) -> Bool {
    guard let thumbnailModified, let modelModified else { return false }
    return thumbnailModified >= modelModified
}

/// Deletes cached thumbnails whose model is no longer in the library. Only `<UUID>.png` files written before
/// `cutoff` are touched, so a thumbnail rendered for a model imported after the snapshot is never removed.
@discardableResult
func pruneOrphanThumbnails(in directory: URL, keeping ids: Set<UUID>, writtenBefore cutoff: Date = .distantFuture) -> Int {
    let manager = FileManager.default
    guard let names = try? manager.contentsOfDirectory(atPath: directory.path) else { return 0 }
    var removed = 0
    for name in names.sorted() where name.hasSuffix(".png") {
        guard let id = UUID(uuidString: String(name.dropLast(4))), !ids.contains(id) else { continue }
        let url = directory.appendingPathComponent(name)
        guard let written = fileModificationDate(url), written < cutoff else { continue }
        if (try? manager.removeItem(at: url)) != nil { removed += 1 }
    }
    return removed
}

// MARK: - Rendering

/// Pixel tests allowed per thumbnail, summed over each triangle's clipped bounding box at the supersampled size.
/// Real models stay far below this (small triangles cover a few pixels each); a mesh of huge overlapping triangles
/// keeps the cube icon instead of taking minutes. About 870 times the 192 × 192 sample grid.
let thumbnailRasterBudget = 32_000_000

/// Software z-buffer rendering of the mesh from the preview's default camera, shaded like the preview.
/// Pure CPU work, safe on any thread, deterministic (triangles drawn in index order; ties keep the first).
/// Returns premultiplied RGBA rows, top row first, with a transparent background, or nil when the mesh would need
/// more than `rasterBudget` pixel tests (checked before drawing anything).
func renderThumbnailRGBA(_ mesh: STLMesh, size: Int, rasterBudget: Int = thumbnailRasterBudget,
                         isCancelled: () -> Bool = { false }) -> [UInt8]? {
    guard size > 0, mesh.triangleCount > 0 else { return nil }
    let extent = mesh.maximum - mesh.minimum
    guard extent.max() > 0 else { return nil }
    let samples = 2
    let n = size * samples
    let center = (mesh.maximum + mesh.minimum) * 0.5
    // STL Z is up, as in the preview: scene = (x, z, -y), seen from the preview camera at (11, 8, 12).
    let eye = simd_normalize(SIMD3<Float>(11, 8, 12))
    let right = simd_normalize(simd_cross(-eye, SIMD3<Float>(0, 1, 0)))
    let up = simd_cross(right, -eye)
    let light = simd_normalize(SIMD3<Float>(5, 12, 9) + SIMD3<Float>(11, 8, 12) * 0.5)
    let v = mesh.vertices
    func scene(_ i: Int) -> SIMD3<Float> {
        let p = SIMD3<Float>(v[i], v[i + 1], v[i + 2]) - center
        return SIMD3(p.x, p.z, -p.y)
    }
    var low = SIMD2<Float>(repeating: .greatestFiniteMagnitude), high = SIMD2<Float>(repeating: -.greatestFiniteMagnitude)
    for i in stride(from: 0, to: v.count, by: 3) {
        let s = scene(i)
        let q = SIMD2(simd_dot(s, right), simd_dot(s, up))
        low = simd_min(low, q)
        high = simd_max(high, q)
    }
    let span = max(high.x - low.x, high.y - low.y)
    guard span > 0, span.isFinite else { return nil }
    let scale = Float(n) * 0.88 / span
    let mid = (low + high) * 0.5
    func project(_ s: SIMD3<Float>) -> SIMD3<Float> {
        let q = SIMD2(simd_dot(s, right), simd_dot(s, up)) - mid
        return SIMD3(Float(n) * 0.5 + q.x * scale, Float(n) * 0.5 - q.y * scale, simd_dot(s, eye))
    }

    /// The triangle's projected corners and clipped pixel bounds, or nil when it draws nothing.
    func footprint(_ t: Int) -> (a: SIMD3<Float>, b: SIMD3<Float>, c: SIMD3<Float>, pa: SIMD3<Float>, pb: SIMD3<Float>,
                                 pc: SIMD3<Float>, area: Float, minX: Int, maxX: Int, minY: Int, maxY: Int)? {
        let a = scene(t * 9), b = scene(t * 9 + 3), c = scene(t * 9 + 6)
        let length = simd_length(simd_cross(b - a, c - a))
        guard length > 0, length.isFinite else { return nil }
        let pa = project(a), pb = project(b), pc = project(c)
        let area = (pb.x - pa.x) * (pc.y - pa.y) - (pb.y - pa.y) * (pc.x - pa.x)
        guard abs(area) > 1e-12 else { return nil }
        let minX = max(0, Int(min(pa.x, pb.x, pc.x).rounded(.down)))
        let maxX = min(n - 1, Int(max(pa.x, pb.x, pc.x).rounded(.up)))
        let minY = max(0, Int(min(pa.y, pb.y, pc.y).rounded(.down)))
        let maxY = min(n - 1, Int(max(pa.y, pb.y, pc.y).rounded(.up)))
        guard minX <= maxX, minY <= maxY else { return nil }
        return (a, b, c, pa, pb, pc, area, minX, maxX, minY, maxY)
    }

    // A cheap first pass totals the pixel tests, so an over-budget mesh is refused before any drawing.
    var work = 0
    for t in 0..<mesh.triangleCount {
        if t % 8192 == 0, isCancelled() { return nil }
        guard let box = footprint(t) else { continue }
        work += (box.maxX - box.minX + 1) * (box.maxY - box.minY + 1)
        if work > rasterBudget { return nil }
    }

    var depth = [Float](repeating: -.greatestFiniteMagnitude, count: n * n)
    var shade = [Float](repeating: -1, count: n * n)
    for t in 0..<mesh.triangleCount {
        if t % 8192 == 0, isCancelled() { return nil }
        guard let box = footprint(t) else { continue }
        let (a, b, c, pa, pb, pc, area, minX, maxX, minY, maxY) = box
        let normalVector = simd_cross(b - a, c - a)
        let intensity = 0.38 + 0.62 * abs(simd_dot(normalVector / simd_length(normalVector), light))
        for y in minY...maxY {
            let py = Float(y) + 0.5
            for x in minX...maxX {
                let px = Float(x) + 0.5
                let w0 = ((pb.x - px) * (pc.y - py) - (pb.y - py) * (pc.x - px)) / area
                let w1 = ((pc.x - px) * (pa.y - py) - (pc.y - py) * (pa.x - px)) / area
                let w2 = 1 - w0 - w1
                guard w0 >= 0, w1 >= 0, w2 >= 0 else { continue }
                let z = w0 * pa.z + w1 * pb.z + w2 * pc.z
                let index = y * n + x
                if z > depth[index] {
                    depth[index] = z
                    shade[index] = intensity
                }
            }
        }
    }

    // Same base colour as the preview material; 2×2 supersampling smooths the silhouette.
    let base = SIMD3<Float>(0.72, 0.79, 0.84)
    var rgba = [UInt8](repeating: 0, count: size * size * 4)
    for y in 0..<size {
        for x in 0..<size {
            var colour = SIMD3<Float>(repeating: 0)
            var coverage: Float = 0
            for sy in 0..<samples {
                for sx in 0..<samples {
                    let s = shade[(y * samples + sy) * n + x * samples + sx]
                    if s >= 0 { colour += base * s; coverage += 1 }
                }
            }
            let count = Float(samples * samples)
            let out = (y * size + x) * 4
            // Premultiplied: colour sums are already weighted by covered samples.
            rgba[out] = UInt8(min(255, (colour.x / count * 255).rounded()))
            rgba[out + 1] = UInt8(min(255, (colour.y / count * 255).rounded()))
            rgba[out + 2] = UInt8(min(255, (colour.z / count * 255).rounded()))
            rgba[out + 3] = UInt8(min(255, (coverage / count * 255).rounded()))
        }
    }
    return rgba
}

func thumbnailPNGData(rgba: [UInt8], size: Int) -> Data? {
    guard size > 0, rgba.count == size * size * 4 else { return nil }
    var pixels = rgba
    let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage()
    }
    guard let image else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

/// Reads the STL, OBJ or 3MF model and renders its thumbnail PNG, or nil for unreadable, oversized or cancelled work.
func renderModelThumbnailPNG(at url: URL, size: Int = ModelThumbnails.pixelSize, isCancelled: () -> Bool = { false }) -> Data? {
    guard supportsLocalPreview(url), !isCancelled(), let mesh = try? loadPreviewModel(from: url).mesh, !isCancelled(),
          let rgba = renderThumbnailRGBA(mesh, size: size, isCancelled: isCancelled) else { return nil }
    return thumbnailPNGData(rgba: rgba, size: size)
}

// MARK: - Scheduling

/// Bounds how many thumbnails parse and render at once, so a large library never floods the CPU at launch.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(limit: Int) { self.limit = max(1, limit) }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}

@MainActor final class ThumbnailMemoryCache {
    static let shared = ThumbnailMemoryCache()
    let limiter = AsyncLimiter(limit: 2)
    private var images: [UUID: (version: String, image: NSImage)] = [:]
    private var pruned = false

    func image(for id: UUID, version: String) -> NSImage? {
        guard let entry = images[id], entry.version == version else { return nil }
        return entry.image
    }
    func store(_ image: NSImage, for id: UUID, version: String) { images[id] = (version, image) }
    func remove(_ id: UUID) { images[id] = nil }

    /// Once per session, drops thumbnails left behind by models removed in an earlier session.
    func pruneOnce(keeping ids: Set<UUID>) {
        guard !pruned else { return }
        pruned = true
        let directory = ModelThumbnails.directory
        let snapshot = Date()
        Task.detached(priority: .background) { pruneOrphanThumbnails(in: directory, keeping: ids, writtenBefore: snapshot) }
    }
}

func thumbnailVersion(path: String, modified: Date?) -> String {
    "\(path)|\(modified?.timeIntervalSinceReferenceDate ?? -1)"
}

/// The library row tile: a rendered thumbnail for previewable models, or the generic cube while it renders or
/// when the file can't be previewed. Rendered only when the row appears, and cached on disk per model.
struct LocalModelThumbnail: View {
    @EnvironmentObject var store: StudioStore
    let model: LocalModel
    var size: CGFloat = 30
    @State private var image: NSImage?
    @State private var shownVersionID = ""

    var body: some View {
        let taskID = "\(model.id.uuidString)|\(model.filePath)"
        ZStack {
            if let image, shownVersionID == taskID {
                RoundedRectangle(cornerRadius: StudioMetrics.tileRadius).fill(Color.studioAccent.opacity(0.12))
                Image(nsImage: image).resizable().interpolation(.high).scaledToFit().padding(size * 0.06)
            } else {
                StudioTile(symbol: "cube", size: size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: StudioMetrics.tileRadius))
        .overlay(RoundedRectangle(cornerRadius: StudioMetrics.tileRadius).stroke(Color.studioHairline))
        .accessibilityHidden(true)
        .task(id: taskID) { await load(taskID: taskID) }
    }

    private func load(taskID: String) async {
        let cache = ThumbnailMemoryCache.shared
        cache.pruneOnce(keeping: Set(store.localModels.map(\.id)))
        guard model.supportsMeshPreview else { return }
        let id = model.id, path = model.filePath, modelURL = model.url
        let thumbnailURL = ModelThumbnails.url(for: id)
        let (modelModified, cachedData) = await Task.detached(priority: .utility) { () -> (Date?, Data?) in
            let modified = fileModificationDate(modelURL)
            guard modified != nil, thumbnailIsCurrent(thumbnailModified: fileModificationDate(thumbnailURL), modelModified: modified) else {
                return (modified, nil)
            }
            return (modified, try? Data(contentsOf: thumbnailURL))
        }.value
        // A missing library file keeps the generic tile.
        guard modelModified != nil, !Task.isCancelled else { return }
        let version = thumbnailVersion(path: path, modified: modelModified)
        if let cached = cache.image(for: id, version: version) { show(cached, taskID: taskID); return }
        if let cachedData, let cached = NSImage(data: cachedData) {
            cache.store(cached, for: id, version: version)
            show(cached, taskID: taskID)
            return
        }

        await cache.limiter.acquire()
        guard !Task.isCancelled else { await cache.limiter.release(); return }
        let worker = Task.detached(priority: .utility) {
            renderModelThumbnailPNG(at: modelURL, isCancelled: { Task.isCancelled })
        }
        let png = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        await cache.limiter.release()
        guard let png, let rendered = NSImage(data: png) else { return }
        // The model may have been removed or replaced while it rendered; only cache for the same library file.
        guard store.localModels.contains(where: { $0.id == id && $0.filePath == path }),
              fileModificationDate(modelURL) == modelModified else { return }
        do {
            try FileManager.default.createDirectory(at: thumbnailURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try png.write(to: thumbnailURL, options: .atomic)
        } catch {
            // The thumbnail is only a cache; the tile still shows the in-memory image.
        }
        cache.store(rendered, for: id, version: version)
        if !Task.isCancelled { show(rendered, taskID: taskID) }
    }

    private func show(_ image: NSImage, taskID: String) {
        self.image = image
        shownVersionID = taskID
    }
}
