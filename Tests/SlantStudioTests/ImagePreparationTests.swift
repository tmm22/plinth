import XCTest
import SwiftUI
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SlantStudio

final class ImagePreparationTests: XCTestCase {
    /// A width × height photo with EXIF, GPS and TIFF details and the given orientation tag.
    private func photo(width: Int, height: Int, type: UTType = .jpeg, orientation: Int = 1) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: height / 2))
        let image = context.makeImage()!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
        let properties: [CFString: Any] = [
            kCGImagePropertyOrientation: orientation,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifUserComment: "Taken at the customer's house", kCGImagePropertyExifLensModel: "SecretLens"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 51.5, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 0.12, kCGImagePropertyGPSLongitudeRef: "W"],
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "PhoneMaker", kCGImagePropertyTIFFModel: "PhoneModel X"]
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    private func properties(_ data: Data) -> [CFString: Any] {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
    }

    func testFixturePhotoReallyCarriesMetadata() {
        let input = properties(photo(width: 40, height: 20))
        XCTAssertNotNil(input[kCGImagePropertyGPSDictionary])
        XCTAssertNotNil(input[kCGImagePropertyExifDictionary])
    }

    func testReencodeStripsMetadataAndScalesDown() throws {
        let prepared = try prepareImageForSharing(data: photo(width: 3000, height: 1500), maxLongEdge: 1568)
        XCTAssertEqual(prepared.mediaType, .jpeg)
        XCTAssertEqual(prepared.pixelWidth, 1568)
        XCTAssertEqual(prepared.pixelHeight, 784)
        let output = properties(prepared.data)
        XCTAssertNil(output[kCGImagePropertyGPSDictionary])
        XCTAssertNil(output[kCGImagePropertyTIFFDictionary])
        XCTAssertNil(output[kCGImagePropertyExifDictionary])
        let text = String(decoding: prepared.data, as: UTF8.self)
        for secret in ["customer", "SecretLens", "PhoneMaker", "PhoneModel", "Exif\u{0}\u{0}"] {
            XCTAssertFalse(text.contains(secret), secret)
        }
        XCTAssertEqual(imagePreparationSourceType(prepared.data), .jpeg)
        XCTAssertEqual(Data(base64Encoded: prepared.base64), prepared.data)
        XCTAssertEqual(prepared.anthropicImage.mediaType, .jpeg)
    }

    func testOrientationIsAppliedAndSmallImagesAreNotEnlarged() throws {
        // Orientation 6 (rotate 90°): a 400 × 200 stored image is shown 200 × 400.
        let rotated = try prepareImageForSharing(data: photo(width: 400, height: 200, orientation: 6), maxLongEdge: 1568)
        XCTAssertEqual(rotated.pixelWidth, 200)
        XCTAssertEqual(rotated.pixelHeight, 400)
        XCTAssertNil(properties(rotated.data)[kCGImagePropertyOrientation].flatMap { ($0 as? NSNumber)?.intValue }.flatMap { $0 == 1 ? nil : $0 })
    }

    func testPNGAcceptedAndLongEdgeCappedAt2048() throws {
        let prepared = try prepareImageForSharing(data: photo(width: 3000, height: 3000, type: .png), maxLongEdge: 5000)
        XCTAssertEqual(prepared.pixelWidth, 2048)
        XCTAssertEqual(prepared.pixelHeight, 2048)
        XCTAssertNil(properties(prepared.data)[kCGImagePropertyGPSDictionary])
    }

    func testRejectsUnsupportedOversizedAndDamagedInput() {
        let gif = Data("GIF89a".utf8) + Data(repeating: 0, count: 20)
        XCTAssertThrowsError(try prepareImageForSharing(data: gif)) { XCTAssertEqual($0 as? ImagePreparationError, .unsupportedType) }
        let tiff = photo(width: 10, height: 10, type: .tiff)
        XCTAssertThrowsError(try prepareImageForSharing(data: tiff)) { XCTAssertEqual($0 as? ImagePreparationError, .unsupportedType) }
        var huge = Data([0xFF, 0xD8, 0xFF, 0xE0])
        huge.append(Data(count: imagePreparationMaxInputBytes))
        XCTAssertThrowsError(try prepareImageForSharing(data: huge)) { XCTAssertEqual($0 as? ImagePreparationError, .tooLarge) }
        let damaged = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10]) + Data(repeating: 0x42, count: 100)
        XCTAssertThrowsError(try prepareImageForSharing(data: damaged)) { XCTAssertEqual($0 as? ImagePreparationError, .unreadable) }
        XCTAssertThrowsError(try prepareImageForSharing(at: URL(fileURLWithPath: "/nonexistent/photo.jpg")))
    }

    func testJPEGSegmentStripper() {
        // SOI, APP0 (JFIF), APP1 (Exif), COM, APP2 (ICC), SOS with two data bytes, EOI.
        let app0: [UInt8] = [0xFF, 0xE0, 0x00, 0x06, 0x4A, 0x46, 0x49, 0x46]
        let app1: [UInt8] = [0xFF, 0xE1, 0x00, 0x08, 0x45, 0x78, 0x69, 0x66, 0x00, 0x00]
        let comment: [UInt8] = [0xFF, 0xFE, 0x00, 0x04, 0x68, 0x69]
        let app2: [UInt8] = [0xFF, 0xE2, 0x00, 0x04, 0x49, 0x43]
        let scan: [UInt8] = [0xFF, 0xDA, 0x00, 0x02, 0x12, 0x34, 0xFF, 0xD9]
        let jpeg = Data([0xFF, 0xD8] + app0 + app1 + comment + app2 + scan)
        XCTAssertEqual(jpegRemovingMetadataSegments(jpeg), Data([0xFF, 0xD8] + app0 + app2 + scan))
        XCTAssertNil(jpegRemovingMetadataSegments(Data([0xFF, 0xD8, 0xFF, 0xE1, 0x00, 0x40, 0x00])))
        XCTAssertNil(jpegRemovingMetadataSegments(Data([0x89, 0x50, 0x4E, 0x47])))
        let real = photo(width: 64, height: 32)
        let stripped = try? XCTUnwrap(jpegRemovingMetadataSegments(real))
        XCTAssertNotNil(stripped.flatMap { CGImageSourceCreateWithData($0 as CFData, nil) }.flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
        XCTAssertNil(stripped.map(properties)?[kCGImagePropertyGPSDictionary])
    }

    func testSourceTypeSniffing() {
        XCTAssertEqual(imagePreparationSourceType(photo(width: 4, height: 4)), .jpeg)
        XCTAssertEqual(imagePreparationSourceType(photo(width: 4, height: 4, type: .png)), .png)
        var heic = Data([0, 0, 0, 0x18])
        heic.append(Data("ftypheic".utf8))
        heic.append(Data(count: 8))
        XCTAssertEqual(imagePreparationSourceType(heic), .heic)
        XCTAssertNil(imagePreparationSourceType(Data()))
        XCTAssertNil(imagePreparationSourceType(Data("hello world, not an image".utf8)))
    }

    func testTargetSize() {
        XCTAssertEqual(imagePreparationTargetSize(width: 4000, height: 3000, maxLongEdge: 1568).width, 1568)
        XCTAssertEqual(imagePreparationTargetSize(width: 4000, height: 3000, maxLongEdge: 1568).height, 1176)
        XCTAssertEqual(imagePreparationTargetSize(width: 100, height: 50, maxLongEdge: 1568).width, 100)
        XCTAssertEqual(imagePreparationTargetSize(width: 10_000, height: 1, maxLongEdge: 1000).height, 1)
    }

    func testFileReadingPreparesTheSameImage() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SlantStudioTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = photo(width: 300, height: 200)
        let url = folder.appendingPathComponent("photo.jpg")
        try data.write(to: url)
        XCTAssertEqual(try prepareImageForSharing(at: url), try prepareImageForSharing(data: data))
    }

    func testRenderedRGBAEncodesAsPNGAndJPEG() throws {
        // 2 × 1: an opaque red pixel and a fully transparent one.
        let rgba: [UInt8] = [255, 0, 0, 255, 0, 0, 0, 0]
        let png = try XCTUnwrap(prepareRenderedImage(rgba: rgba, width: 2, height: 1))
        XCTAssertEqual(png.mediaType, .png)
        XCTAssertEqual(imagePreparationSourceType(png.data), .png)
        XCTAssertEqual(png.pixelWidth, 2)
        let jpeg = try XCTUnwrap(prepareRenderedImage(rgba: rgba, width: 2, height: 1, format: .jpeg(quality: 0.9, background: SIMD3(1, 1, 1))))
        XCTAssertEqual(jpeg.mediaType, .jpeg)
        XCTAssertEqual(imagePreparationSourceType(jpeg.data), .jpeg)
        XCTAssertNil(prepareRenderedImage(rgba: rgba, width: 3, height: 1))
        XCTAssertNil(prepareRenderedImage(rgba: [], width: 0, height: 0))
        // Same pixels, same bytes.
        XCTAssertEqual(prepareRenderedImage(rgba: rgba, width: 2, height: 1), png)
    }
}

@MainActor final class ImageSharingConsentTests: XCTestCase {
    func testConsentTextNamesServiceAndWhatIsSent() {
        let claude = imageSharingConsentText(.anthropic)
        XCTAssertEqual(claude.title, "Send photos to Anthropic (Claude)?")
        XCTAssertTrue(claude.message.contains("Studio sends Anthropic (Claude) the photo you choose, the details you type"))
        XCTAssertTrue(claude.message.contains("location"))
        XCTAssertEqual(claude.allowButton, "Allow and Send")
        XCTAssertEqual(claude.cancelButton, "Don’t Send")
        for service in [ImageSharingService.meshy, .tripo] {
            let text = imageSharingConsentText(service)
            XCTAssertTrue(text.message.contains("Studio sends \(service.displayName) the photos you choose"), "one consent covers every photo")
            XCTAssertFalse(text.message.contains("details you type"))
            XCTAssertFalse(text.message.contains("renders"))
        }
        XCTAssertEqual(ImageSharingService.allCases.map(\.rawValue), ["anthropic", "meshy", "tripo"])
    }

    func testGrantAndResetStoreOnlyAFlagAndDate() throws {
        let suite = "SlantStudioTests.consent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ImageSharingConsentStore(defaults: defaults)
        XCTAssertFalse(store.hasConsented(.anthropic))
        let when = Date(timeIntervalSince1970: 1_792_800_000)
        store.grant(.anthropic, now: when)
        XCTAssertTrue(store.hasConsented(.anthropic))
        XCTAssertFalse(store.hasConsented(.meshy))
        XCTAssertEqual(store.consentDate(.anthropic), when)
        XCTAssertEqual(Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? []),
                       ["imageSharingConsent.anthropic", "imageSharingConsent.anthropic.date"])
        store.reset(.anthropic)
        XCTAssertFalse(store.hasConsented(.anthropic))
        XCTAssertNil(store.consentDate(.anthropic))
        XCTAssertTrue(defaults.persistentDomain(forName: suite)?.isEmpty ?? true)
    }

    func testRunWithConsentOnlyAsksTheFirstTime() throws {
        let suite = "SlantStudioTests.consent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ImageSharingConsentStore(defaults: defaults)
        var pending: ImageSharingConsentRequest?
        var sends = 0
        let binding = Binding(get: { pending }, set: { pending = $0 })
        runWithImageSharingConsent(.tripo, request: binding, store: store) { sends += 1 }
        XCTAssertEqual(sends, 0)
        XCTAssertEqual(pending?.service, .tripo)
        store.grant(.tripo)
        pending = nil
        runWithImageSharingConsent(.tripo, request: binding, store: store) { sends += 1 }
        XCTAssertEqual(sends, 1)
        XCTAssertNil(pending)
    }

    func testStatusLine() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let date = Date(timeIntervalSince1970: 1_792_800_000) // 24 Oct 2026 UTC
        XCTAssertEqual(imageSharingConsentStatusLine(granted: true, date: date, calendar: calendar, locale: Locale(identifier: "en_GB")),
                       "Allowed on 24 Oct 2026")
        XCTAssertEqual(imageSharingConsentStatusLine(granted: false, date: date), "Not allowed yet")
        XCTAssertEqual(imageSharingConsentStatusLine(granted: true, date: nil), "Allowed")
    }
}
