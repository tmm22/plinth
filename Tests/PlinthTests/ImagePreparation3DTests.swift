import XCTest
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SlantStudio

/// Photos for Meshy and Tripo (round 8): 2048 px, a higher JPEG quality, transparency kept, metadata still stripped.
final class ImagePreparation3DTests: XCTestCase {
    /// A width × height image with EXIF, GPS and TIFF details. `transparentMargin` leaves a clear border (a cut-out).
    private func image(width: Int, height: Int, type: UTType, transparentMargin: Int = 0, noise: Bool = false) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: transparentMargin, y: transparentMargin, width: width - 2 * transparentMargin, height: height - 2 * transparentMargin))
        if noise, let pixels = context.data {
            let bytes = pixels.bindMemory(to: UInt8.self, capacity: context.bytesPerRow * height)
            var state: UInt32 = 12345
            for y in 0..<height {
                for x in 0..<(width * 4) {
                    state = state &* 1_664_525 &+ 1_013_904_223
                    bytes[y * context.bytesPerRow + x] = UInt8(truncatingIfNeeded: state >> 24)
                }
                // Keep premultiplied colour ≤ alpha.
                for x in 0..<width {
                    let base = y * context.bytesPerRow + x * 4
                    let alpha = bytes[base + 3]
                    for c in 0..<3 { bytes[base + c] = min(bytes[base + c], alpha) }
                }
            }
        }
        let picture = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Taken at the customer's house"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PhoneMaker"]
        ]
        CGImageDestinationAddImage(destination, picture, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    private func assertNoMetadata(_ data: Data, file: StaticString = #filePath, line: UInt = #line) {
        let output = properties(data)
        XCTAssertNil(output[kCGImagePropertyGPSDictionary], file: file, line: line)
        XCTAssertNil(output[kCGImagePropertyExifDictionary], file: file, line: line)
        XCTAssertNil(output[kCGImagePropertyTIFFDictionary], file: file, line: line)
        let text = String(decoding: data, as: UTF8.self)
        for secret in ["customer", "PhoneMaker"] { XCTAssertFalse(text.contains(secret), secret, file: file, line: line) }
    }

    /// The alpha of the decoded pixel at (x, y), top row first.
    private func alpha(_ data: Data, x: Int, y: Int) -> UInt8? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: decoded.width, height: decoded.height, bitsPerComponent: 8, bytesPerRow: decoded.width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.clear(CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        context.draw(decoded, in: CGRect(x: 0, y: 0, width: decoded.width, height: decoded.height))
        guard let pixels = context.data else { return nil }
        return pixels.bindMemory(to: UInt8.self, capacity: decoded.width * decoded.height * 4)[(y * decoded.width + x) * 4 + 3]
    }

    func testProfiles() {
        XCTAssertEqual(ImagePreparationProfile.claude.maxLongEdge, 1568)
        XCTAssertEqual(ImagePreparationProfile.claude.quality, 0.85)
        XCTAssertEqual(ImagePreparationProfile.claude.maxOutputBytes, 3_750_000)
        XCTAssertFalse(ImagePreparationProfile.claude.keepsTransparency)
        XCTAssertEqual(ImagePreparationProfile.imageTo3D.maxLongEdge, 2048)
        XCTAssertEqual(ImagePreparationProfile.imageTo3D.quality, 0.92)
        XCTAssertLessThanOrEqual(ImagePreparationProfile.imageTo3D.maxOutputBytes * 4 * 4 / 3, 33_000_000,
                                 "four base64 photos in one Meshy request stay near 32 MB")
        XCTAssertLessThan(ImagePreparationProfile.imageTo3D.maxOutputBytes, imageTo3DMaxImageBytes)
    }

    func testCutOutPNGStaysAPNGWithItsTransparency() throws {
        let prepared = try prepareImageForSharing(data: image(width: 3000, height: 1500, type: .png, transparentMargin: 300),
                                                  profile: .imageTo3D)
        XCTAssertEqual(prepared.mediaType, .png)
        XCTAssertEqual(imagePreparationSourceType(prepared.data), .png)
        XCTAssertEqual(prepared.pixelWidth, 2048)
        XCTAssertEqual(prepared.pixelHeight, 1024)
        XCTAssertEqual(alpha(prepared.data, x: 2, y: 2), 0, "the clear border stays clear")
        XCTAssertEqual(alpha(prepared.data, x: 1024, y: 512), 255)
        XCTAssertLessThanOrEqual(prepared.data.count, imagePreparation3DMaxOutputBytes)
        assertNoMetadata(prepared.data)
        XCTAssertNil(imageTo3DImageProblem(ImageTo3DImage(data: prepared.data, mediaType: prepared.mediaType.rawValue)))

        // Claude's path still flattens it onto white as a JPEG.
        let claude = try prepareImageForSharing(data: image(width: 400, height: 200, type: .png, transparentMargin: 20))
        XCTAssertEqual(claude.mediaType, .jpeg)
    }

    func testOpaquePNGAndPhotosBecomeDetailedJPEGs() throws {
        // The premise: this PNG really carries an alpha channel, all of it opaque.
        let opaqueData = image(width: 600, height: 400, type: .png)
        let decoded = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithData(opaqueData as CFData, nil)!, 0, nil)!
        XCTAssertFalse([CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo), "has an alpha channel")
        XCTAssertEqual(alpha(opaqueData, x: 0, y: 0), 255)
        let opaque = try prepareImageForSharing(data: opaqueData, profile: .imageTo3D)
        XCTAssertEqual(opaque.mediaType, .jpeg, "an alpha channel with nothing transparent isn't worth a PNG")
        let photo = try prepareImageForSharing(data: image(width: 4032, height: 3024, type: .jpeg), profile: .imageTo3D)
        XCTAssertEqual(photo.mediaType, .jpeg)
        XCTAssertEqual(photo.pixelWidth, 2048)
        XCTAssertEqual(photo.pixelHeight, 1536)
        XCTAssertLessThanOrEqual(photo.data.count, imagePreparation3DMaxOutputBytes)
        assertNoMetadata(photo.data)
        let claude = try prepareImageForSharing(data: image(width: 4032, height: 3024, type: .jpeg))
        XCTAssertEqual(claude.pixelWidth, 1568, "Claude's path is unchanged")
    }

    func testTransparentPNGShrinksToFitTheCap() throws {
        // Noise doesn't compress: 1200 × 1200 RGBA is about 5.8 MB as a PNG.
        let noisy = image(width: 1200, height: 1200, type: .png, noise: true)
        let roomy = ImagePreparationProfile(maxLongEdge: 2048, quality: 0.92, maxOutputBytes: 4_500_000, keepsTransparency: true)
        let shrunk = try prepareImageForSharing(data: noisy, profile: roomy)
        XCTAssertEqual(shrunk.mediaType, .png)
        XCTAssertEqual(shrunk.pixelWidth, 1024, "scaled down, but never below 1024 px")
        XCTAssertLessThanOrEqual(shrunk.data.count, 4_500_000)
        let tight = ImagePreparationProfile(maxLongEdge: 2048, quality: 0.92, maxOutputBytes: 1_000_000, keepsTransparency: true)
        XCTAssertThrowsError(try prepareImageForSharing(data: noisy, profile: tight)) {
            XCTAssertEqual($0 as? ImagePreparationError, .encodingFailed)
        }
    }

    func testFileReadingUsesTheProfile() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("r8-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try image(width: 300, height: 300, type: .png, transparentMargin: 30).write(to: url)
        XCTAssertEqual(try prepareImageForSharing(at: url, profile: .imageTo3D).mediaType, .png)
        XCTAssertEqual(try prepareImageForSharing(at: url).mediaType, .jpeg)
    }
}

final class PNGChunkStripTests: XCTestCase {
    private func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
        let n = payload.count
        return [UInt8(n >> 24 & 0xFF), UInt8(n >> 16 & 0xFF), UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)] + Array(type.utf8) + payload + [0, 0, 0, 0]
    }

    func testOnlyImageChunksAreKept() {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        let png = signature + chunk("IHDR", Array(repeating: 1, count: 13)) + chunk("eXIf", Array("secret".utf8))
            + chunk("tEXt", Array("Comment\u{0}customer".utf8)) + chunk("zTXt", Array("Author\u{0}\u{0}x".utf8))
            + chunk("IDAT", [1, 2, 3]) + chunk("iTXt", Array("Description\u{0}\u{0}\u{0}\u{0}\u{0}address".utf8))
            + chunk("tIME", [1, 2, 3, 4, 5, 6, 7]) + chunk("IEND", [])
        let stripped = pngKeepingOnlyImageChunks(Data(png))
        XCTAssertEqual(stripped, Data(signature + chunk("IHDR", Array(repeating: 1, count: 13)) + chunk("IDAT", [1, 2, 3]) + chunk("IEND", [])))
        XCTAssertNil(pngKeepingOnlyImageChunks(Data(signature + chunk("IHDR", [1]).dropLast(3))), "truncated")
        XCTAssertNil(pngKeepingOnlyImageChunks(Data([0xFF, 0xD8, 0xFF])))
        XCTAssertNil(pngKeepingOnlyImageChunks(Data(signature + chunk("IHDR", [1]))), "no IEND")
    }
}
