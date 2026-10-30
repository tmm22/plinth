import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Preparing photos to send
//
// A photo the seller chooses is read from disk, turned upright, scaled down and written again as a fresh JPEG with no
// metadata at all (no EXIF, GPS, camera or maker details), entirely in memory. Only that copy is ever sent. Nothing
// is written to disk. Renders of models (RGBA buffers from `renderMeshRGBA`) are encoded the same way for tool results.
// Claude gets a 1568 px JPEG at quality 0.85 (≤ 3.75 MB); the 3D services get more detail (`ImagePreparationProfile`):
// 2048 px at 0.92 (≤ 6 MB each), and a photo with real transparency (a cut-out PNG) stays a PNG with its alpha.

/// Largest photo file Studio reads.
let imagePreparationMaxInputBytes = 30 * 1024 * 1024
/// Largest photo, in pixels, Studio decodes (a 48-megapixel phone photo fits; a decompression bomb doesn't).
let imagePreparationMaxInputPixels = 120_000_000
/// Long edge Claude needs; larger images are scaled down by Anthropic anyway.
let imagePreparationClaudeLongEdge = 1568
/// The largest long edge Studio ever sends to any service.
let imagePreparationMaxLongEdge = 2048
/// Largest encoded image sent (Anthropic accepts 5 MB per image; base64 adds a third).
let imagePreparationMaxOutputBytes = 3_750_000
/// Largest encoded photo sent to a 3D service: well within Meshy's and Tripo's 20 MB, and four as base64 in one Meshy
/// request stay near 32 MB.
let imagePreparation3DMaxOutputBytes = 6_000_000
/// JPEG quality for the 3D services: fine surface detail matters more than size there.
let imagePreparation3DQuality = 0.92

/// How a photo is prepared for where it goes.
struct ImagePreparationProfile: Equatable, Sendable {
    let maxLongEdge: Int
    let quality: Double
    let maxOutputBytes: Int
    /// Keep real transparency as a PNG instead of flattening onto white.
    let keepsTransparency: Bool

    /// Claude: 1568 px, JPEG 0.85, ≤ 3.75 MB, flattened.
    static let claude = ImagePreparationProfile(maxLongEdge: imagePreparationClaudeLongEdge, quality: 0.85,
                                                maxOutputBytes: imagePreparationMaxOutputBytes, keepsTransparency: false)
    /// Meshy and Tripo: 2048 px, JPEG 0.92, ≤ 6 MB, transparency kept.
    static let imageTo3D = ImagePreparationProfile(maxLongEdge: imagePreparationMaxLongEdge, quality: imagePreparation3DQuality,
                                                   maxOutputBytes: imagePreparation3DMaxOutputBytes, keepsTransparency: true)
}

enum ImagePreparationError: LocalizedError, Equatable {
    case tooLarge
    case tooManyPixels
    case unsupportedType
    case unreadable
    case encodingFailed

    var errorDescription: String? {
        switch self {
        case .tooLarge: return "That photo is larger than 30 MB. Choose a smaller one or export it at a lower size."
        case .tooManyPixels: return "That image has too many pixels for Plinth to open. Export it at a smaller size first."
        case .unsupportedType: return "Choose a JPEG, PNG or HEIC photo."
        case .unreadable: return "That photo couldn’t be read. It may be damaged or still downloading."
        case .encodingFailed: return "Plinth couldn’t prepare that photo to send."
        }
    }
}

/// An image ready to send: freshly encoded bytes without metadata, and its size in pixels.
struct PreparedImage: Equatable, Sendable {
    let data: Data
    let mediaType: AnthropicImageMediaType
    let pixelWidth: Int
    let pixelHeight: Int

    var base64: String { data.base64EncodedString() }
    /// For an `image` block or a tool result.
    var anthropicImage: AnthropicImage { AnthropicImage(mediaType: mediaType, base64Data: base64) }
}

/// The accepted photo formats, by content (never by file name).
enum ImagePreparationSourceType: Equatable {
    case jpeg, png, heic
}

/// What the bytes are, from their signature, or nil for anything else.
func imagePreparationSourceType(_ data: Data) -> ImagePreparationSourceType? {
    let bytes = [UInt8](data.prefix(16))
    if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF { return .jpeg }
    if bytes.count >= 8, bytes[0..<8].elementsEqual([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return .png }
    // ISO base media: size, "ftyp", then a HEIF brand.
    if bytes.count >= 12, String(decoding: bytes[4..<8], as: UTF8.self) == "ftyp" {
        let brand = String(decoding: bytes[8..<12], as: UTF8.self)
        if ["heic", "heix", "heim", "heis", "hevc", "hevx", "mif1", "msf1"].contains(brand) { return .heic }
    }
    return nil
}

/// The pixel size to scale to so the long edge is at most `maxLongEdge` (never enlarged).
func imagePreparationTargetSize(width: Int, height: Int, maxLongEdge: Int) -> (width: Int, height: Int) {
    let longEdge = max(width, height)
    guard longEdge > maxLongEdge, longEdge > 0 else { return (max(1, width), max(1, height)) }
    let scale = Double(maxLongEdge) / Double(longEdge)
    return (max(1, Int((Double(width) * scale).rounded())), max(1, Int((Double(height) * scale).rounded())))
}

/// Reads a photo file (refusing anything over 30 MB before reading it) and prepares it with `prepareImageForSharing(data:)`.
func prepareImageForSharing(at url: URL, maxLongEdge: Int = imagePreparationClaudeLongEdge, quality: Double = 0.85) throws -> PreparedImage {
    try prepareImageForSharing(at: url, profile: ImagePreparationProfile(maxLongEdge: maxLongEdge, quality: quality,
                                                                         maxOutputBytes: imagePreparationMaxOutputBytes,
                                                                         keepsTransparency: false))
}

/// Reads a photo file (refusing anything over 30 MB before reading it) and prepares it for `profile`.
func prepareImageForSharing(at url: URL, profile: ImagePreparationProfile) throws -> PreparedImage {
    let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    if let size = values?.fileSize, size > imagePreparationMaxInputBytes { throw ImagePreparationError.tooLarge }
    guard values?.isRegularFile != false else { throw ImagePreparationError.unreadable }
    let handle: FileHandle
    do { handle = try FileHandle(forReadingFrom: url) } catch { throw ImagePreparationError.unreadable }
    defer { try? handle.close() }
    // Read at most one byte past the limit, so a file that grew after the size check is still refused.
    guard let data = try? handle.read(upToCount: imagePreparationMaxInputBytes + 1) else { throw ImagePreparationError.unreadable }
    return try prepareImageForSharing(data: data, profile: profile)
}

/// A JPEG, PNG or HEIC photo, turned upright by its orientation tag, scaled so its long edge is at most `maxLongEdge`
/// (capped at 2048), flattened onto white and encoded as a new JPEG with no metadata. Pure: safe off the main actor.
func prepareImageForSharing(data: Data, maxLongEdge: Int = imagePreparationClaudeLongEdge, quality: Double = 0.85) throws -> PreparedImage {
    try prepareImageForSharing(data: data, profile: ImagePreparationProfile(maxLongEdge: maxLongEdge, quality: quality,
                                                                           maxOutputBytes: imagePreparationMaxOutputBytes,
                                                                           keepsTransparency: false))
}

/// The same preparation for `profile`. With `keepsTransparency`, a photo that has any partly transparent pixel is
/// redrawn as sRGB RGBA and encoded as a new PNG with no metadata, scaled down further (never below 1024 px) until it
/// fits `maxOutputBytes`; every other photo becomes a JPEG as above.
func prepareImageForSharing(data: Data, profile: ImagePreparationProfile) throws -> PreparedImage {
    let maxLongEdge = profile.maxLongEdge, quality = profile.quality, maxOutputBytes = profile.maxOutputBytes
    guard data.count <= imagePreparationMaxInputBytes else { throw ImagePreparationError.tooLarge }
    guard imagePreparationSourceType(data) != nil else { throw ImagePreparationError.unsupportedType }
    let options = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, options), CGImageSourceGetCount(source) > 0,
          let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
          let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue, width > 0, height > 0 else {
        throw ImagePreparationError.unreadable
    }
    guard width.multipliedReportingOverflow(by: height).partialValue <= imagePreparationMaxInputPixels,
          !width.multipliedReportingOverflow(by: height).overflow else { throw ImagePreparationError.tooManyPixels }
    let longEdge = min(max(16, maxLongEdge), imagePreparationMaxLongEdge)
    let thumbnailOptions = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: longEdge,
        kCGImageSourceShouldCacheImmediately: true
    ] as CFDictionary
    guard let decoded = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { throw ImagePreparationError.unreadable }
    if profile.keepsTransparency, imagePreparationHasAlphaChannel(decoded) {
        if let prepared = try imagePreparationTransparentPNG(decoded, longEdge: longEdge, maxOutputBytes: maxOutputBytes) {
            return prepared
        }
    }
    // Redrawn into a plain sRGB bitmap: converts any other colour profile to sRGB, drops alpha and guarantees the size limit.
    let target = imagePreparationTargetSize(width: decoded.width, height: decoded.height, maxLongEdge: longEdge)
    guard let flattened = imagePreparationFlatten(decoded, width: target.width, height: target.height) else {
        throw ImagePreparationError.encodingFailed
    }
    var jpegQuality = min(max(quality, 0.3), 0.95)
    while true {
        guard let encoded = imagePreparationEncode(flattened, type: .jpeg, quality: jpegQuality) else { throw ImagePreparationError.encodingFailed }
        if encoded.count <= maxOutputBytes || jpegQuality <= 0.3 {
            guard encoded.count <= maxOutputBytes else { throw ImagePreparationError.encodingFailed }
            return PreparedImage(data: encoded, mediaType: .jpeg, pixelWidth: flattened.width, pixelHeight: flattened.height)
        }
        jpegQuality = max(0.3, jpegQuality - 0.15)
    }
}

/// Whether the decoded image carries an alpha channel at all (a cheap first test before looking at its pixels).
private func imagePreparationHasAlphaChannel(_ image: CGImage) -> Bool {
    switch image.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: return false
    default: return true
    }
}

/// The image as a metadata-free PNG with its transparency, or nil when no pixel is transparent (an opaque photo saved
/// with an alpha channel is sent as a JPEG instead). Scales down in steps until the PNG fits `maxOutputBytes`.
private func imagePreparationTransparentPNG(_ image: CGImage, longEdge: Int, maxOutputBytes: Int) throws -> PreparedImage? {
    var edge = min(longEdge, max(image.width, image.height))
    let smallest = min(edge, 1024)
    var checkedTransparency = false
    while true {
        let target = imagePreparationTargetSize(width: image.width, height: image.height, maxLongEdge: edge)
        guard let context = CGContext(data: nil, width: target.width, height: target.height, bitsPerComponent: 8,
                                      bytesPerRow: target.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ImagePreparationError.encodingFailed
        }
        context.clear(CGRect(x: 0, y: 0, width: target.width, height: target.height))
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        if !checkedTransparency {
            guard let pixels = context.data else { throw ImagePreparationError.encodingFailed }
            let bytes = pixels.bindMemory(to: UInt8.self, capacity: target.width * target.height * 4)
            var transparent = false
            for index in stride(from: 3, to: target.width * target.height * 4, by: 4) where bytes[index] < 255 {
                transparent = true
                break
            }
            guard transparent else { return nil }
            checkedTransparency = true
        }
        guard let redrawn = context.makeImage(), let written = imagePreparationEncode(redrawn, type: .png, quality: 1),
              let encoded = pngKeepingOnlyImageChunks(written) else {
            throw ImagePreparationError.encodingFailed
        }
        if encoded.count <= maxOutputBytes {
            return PreparedImage(data: encoded, mediaType: .png, pixelWidth: redrawn.width, pixelHeight: redrawn.height)
        }
        guard edge > smallest else { throw ImagePreparationError.encodingFailed }
        edge = max(smallest, Int(Double(edge) * 0.8))
    }
}

enum PreparedImageFormat: Equatable {
    case png
    /// Transparent pixels are composited over `background` (RGB, 0…1).
    case jpeg(quality: Double, background: SIMD3<Float>)
}

/// Encodes premultiplied RGBA rows, top row first (as `renderMeshRGBA` returns them), as a PNG or JPEG without
/// metadata. Nil when the buffer doesn't match the size.
func prepareRenderedImage(rgba: [UInt8], width: Int, height: Int, format: PreparedImageFormat = .png) -> PreparedImage? {
    guard width > 0, height > 0, width <= imagePreparationMaxLongEdge, height <= imagePreparationMaxLongEdge,
          rgba.count == width * height * 4 else { return nil }
    var pixels: [UInt8]
    let type: UTType
    var quality = 1.0
    switch format {
    case .png:
        pixels = rgba
        type = .png
    case .jpeg(let jpegQuality, let background):
        pixels = listingComposite(rgba, over: background)
        type = .jpeg
        quality = min(max(jpegQuality, 0.3), 0.95)
    }
    let image: CGImage? = pixels.withUnsafeMutableBytes { buffer in
        guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        return context.makeImage()
    }
    guard let image, let data = imagePreparationEncode(image, type: type, quality: quality) else { return nil }
    return PreparedImage(data: data, mediaType: type == .png ? .png : .jpeg, pixelWidth: width, pixelHeight: height)
}

private func imagePreparationFlatten(_ image: CGImage, width: Int, height: Int) -> CGImage? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
    context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context.makeImage()
}

/// A new file from pixels only: no source properties are copied, so no EXIF, GPS or TIFF details are written.
private func imagePreparationEncode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    var properties: [CFString: Any] = [:]
    if type == .jpeg { properties[kCGImageDestinationLossyCompressionQuality] = quality }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return type == .jpeg ? jpegRemovingMetadataSegments(data as Data) : data as Data
}

/// The PNG with only the chunks needed to draw it: header, palette, transparency, colour (sRGB, gamma, chromaticity,
/// ICC profile, significant bits), pixel density, background and the image data. Everything else goes, including the
/// small `eXIf` block ImageIO writes (pixel sizes, colour space) and any text or time chunk. Nil for a malformed PNG.
func pngKeepingOnlyImageChunks(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    guard bytes.count >= 8, Array(bytes[0..<8]) == signature else { return nil }
    let kept: Set<String> = ["IHDR", "PLTE", "tRNS", "sRGB", "gAMA", "cHRM", "iCCP", "sBIT", "pHYs", "bKGD", "IDAT", "IEND"]
    var output = signature
    output.reserveCapacity(bytes.count)
    var position = 8
    while position + 12 <= bytes.count {
        let length = Int(bytes[position]) << 24 | Int(bytes[position + 1]) << 16 | Int(bytes[position + 2]) << 8 | Int(bytes[position + 3])
        let end = position + 12 + length
        guard length >= 0, end <= bytes.count else { return nil }
        let type = String(decoding: bytes[(position + 4)..<(position + 8)], as: UTF8.self)
        if kept.contains(type) { output += bytes[position..<end] }
        position = end
        if type == "IEND" { return Data(output) }
    }
    return nil
}

/// The JPEG without its metadata segments: APP1 (EXIF, XMP), APP3–APP15 (maker and editor data) and comments.
/// APP0 (JFIF), APP2 (the colour profile) and the image itself are kept byte for byte. Nil for a malformed JPEG.
/// ImageIO writes a small EXIF block (pixel sizes, colour space) into every JPEG; this removes it too.
func jpegRemovingMetadataSegments(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xD8 else { return nil }
    var output: [UInt8] = [0xFF, 0xD8]
    output.reserveCapacity(bytes.count)
    var position = 2
    while position < bytes.count {
        guard bytes[position] == 0xFF else { return nil }
        var markerAt = position + 1
        while markerAt < bytes.count, bytes[markerAt] == 0xFF { markerAt += 1 } // fill bytes
        guard markerAt < bytes.count else { return nil }
        let marker = bytes[markerAt]
        if marker == 0xD9 { output += [0xFF, 0xD9]; return Data(output) }
        if marker == 0x01 || (0xD0...0xD7).contains(marker) {
            output += [0xFF, marker]
            position = markerAt + 1
            continue
        }
        guard markerAt + 2 < bytes.count else { return nil }
        let length = Int(bytes[markerAt + 1]) << 8 | Int(bytes[markerAt + 2])
        let end = markerAt + 1 + length
        guard length >= 2, end <= bytes.count else { return nil }
        if marker == 0xDA {
            // Start of scan: the compressed image and everything after it.
            output += [0xFF]
            output += bytes[markerAt..<bytes.count]
            return Data(output)
        }
        let isMetadata = marker == 0xE1 || (0xE3...0xEF).contains(marker) || marker == 0xFE
        if !isMetadata {
            output += [0xFF]
            output += bytes[markerAt..<end]
        }
        position = end
    }
    return nil
}
