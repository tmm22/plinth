import XCTest
import simd
@testable import Plinth

final class ListingAssetsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("PlinthListing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A box `x` wide, `y` deep and `z` tall, from the origin.
    private func box(_ x: Float, _ y: Float, _ z: Float) -> STLMesh {
        let p: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(x, 0, 0), SIMD3(x, y, 0), SIMD3(0, y, 0),
            SIMD3(0, 0, z), SIMD3(x, 0, z), SIMD3(x, y, z), SIMD3(0, y, z)
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)
        ]
        let vertices = faces.flatMap { [p[$0.0], p[$0.1], p[$0.2]] }.flatMap { [$0.x, $0.y, $0.z] }
        return STLMesh(vertices: vertices, minimum: .zero, maximum: SIMD3(x, y, z))
    }

    private func assertNear(_ a: SIMD3<Float>, _ b: SIMD3<Float>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertLessThan(simd_length(a - b), 1e-5, "\(a) vs \(b)", file: file, line: line)
    }

    // MARK: Cameras

    func testEveryListingCameraIsOrthonormal() {
        for angle in ListingImageAngle.allCases {
            let camera = listingCamera(angle)
            XCTAssertEqual(simd_length(camera.eye), 1, accuracy: 1e-5, angle.title)
            XCTAssertEqual(simd_length(camera.right), 1, accuracy: 1e-5, angle.title)
            XCTAssertEqual(simd_length(camera.up), 1, accuracy: 1e-5, angle.title)
            XCTAssertEqual(simd_dot(camera.eye, camera.right), 0, accuracy: 1e-5, angle.title)
            XCTAssertEqual(simd_dot(camera.eye, camera.up), 0, accuracy: 1e-5, angle.title)
            XCTAssertEqual(simd_dot(camera.right, camera.up), 0, accuracy: 1e-5, angle.title)
            XCTAssertNotNil(MeshRenderCamera(eye: angle.eye, upHint: angle.upHint), "\(angle.title) needs no fallback")
        }
    }

    func testListingViewsFaceTheExpectedSides() {
        // Scene space is (x, z, −y) of the STL: front (STL −Y) is scene +Z, up (STL +Z) is scene +Y.
        let front = listingCamera(.front)
        assertNear(front.eye, SIMD3(0, 0, 1))
        assertNear(front.right, SIMD3(1, 0, 0))
        assertNear(front.up, SIMD3(0, 1, 0))
        let side = listingCamera(.side)
        assertNear(side.eye, SIMD3(1, 0, 0))
        assertNear(side.up, SIMD3(0, 1, 0))
        // Looking down, the model's back (STL +Y, scene −Z) points up the image and STL +X stays to the right.
        let top = listingCamera(.top)
        assertNear(top.eye, SIMD3(0, 1, 0))
        assertNear(top.right, SIMD3(1, 0, 0))
        assertNear(top.up, SIMD3(0, 0, -1))
        // The three-quarter view is the preview's (and thumbnail's) default camera.
        XCTAssertEqual(listingCamera(.threeQuarter), MeshRenderCamera.thumbnail)
        // The light is always on the viewer's side.
        for angle in ListingImageAngle.allCases {
            let camera = listingCamera(angle)
            XCTAssertGreaterThan(simd_dot(listingLight(camera), camera.eye), 0.5, angle.title)
        }
    }

    func testCameraRefusesDegenerateDirections() {
        XCTAssertNil(MeshRenderCamera(eye: .zero))
        XCTAssertNil(MeshRenderCamera(eye: SIMD3(0, 1, 0)), "straight down needs a different up hint")
        XCTAssertNil(MeshRenderCamera(eye: SIMD3(.nan, 0, 1)))
        XCTAssertNotNil(MeshRenderCamera(eye: SIMD3(0, 1, 0), upHint: SIMD3(0, 0, -1)))
    }

    func testDefaultViewsAndFileNames() {
        // Listed front first, round the model, then from above.
        XCTAssertEqual(ListingImageAngle.allCases, [.front, .threeQuarter, .side, .back, .rearThreeQuarter, .top])
        XCTAssertEqual(ListingImageAngle.allCases.filter(\.selectedByDefault), [.front, .threeQuarter, .side, .top])
        XCTAssertEqual(listingImageFileName(modelName: "Desk Tidy", angle: .front), "Desk Tidy – front.png")
        XCTAssertEqual(listingImageFileName(modelName: "Desk Tidy", angle: .rearThreeQuarter, attempt: 3),
                       "Desk Tidy – rear three-quarter 3.png")
        XCTAssertEqual(listingImageFileName(modelName: "a/b:c", angle: .top), "a-b-c – top.png")
        XCTAssertEqual(listingImageFileName(modelName: "  ", angle: .side), "Model – side.png")
        // A long name is shortened before the view is added, so the view always survives.
        let long = listingImageFileName(modelName: String(repeating: "x", count: 400), angle: .back)
        XCTAssertTrue(long.hasSuffix(" – back.png"))
    }

    // MARK: Colour

    func testHexColourParsing() {
        assertNear(listingColour(hex: "#FF8000")!, SIMD3(1, 128 / 255, 0))
        assertNear(listingColour(hex: "ff8000")!, SIMD3(1, 128 / 255, 0))
        assertNear(listingColour(hex: " 0x000000 ")!, SIMD3(0, 0, 0))
        assertNear(listingColour(hex: "#fff")!, SIMD3(1, 1, 1))
        assertNear(listingColour(hex: "#11223380")!, SIMD3(17, 34, 51) / 255)
        for bad in ["", "#", "red", "#12345", "#GGGGGG", "#1234567", "12 34 56", "#ff80001"] {
            XCTAssertNil(listingColour(hex: bad), bad)
        }
    }

    func testRenderStyleKeepsDarkAndLightColoursVisible() {
        let camera = listingCamera(.front)
        let black = listingRenderStyle(colour: SIMD3(0, 0, 0), camera: camera)
        XCTAssertGreaterThan(black.base.max(), 0)
        let white = listingRenderStyle(colour: SIMD3(1, 1, 1), camera: camera)
        XCTAssertLessThan(white.base.max(), 1)
        XCTAssertGreaterThan(black.sheen, white.sheen)
    }

    func testCompositeIsOpaqueOverTheBackground() {
        // One transparent pixel, one fully covered red pixel, one half-covered premultiplied grey pixel.
        let out = listingComposite([0, 0, 0, 0, 255, 0, 0, 255, 64, 64, 64, 128], over: SIMD3(1, 1, 1))
        XCTAssertEqual(Array(out[0..<4]), [255, 255, 255, 255])
        XCTAssertEqual(Array(out[4..<8]), [255, 0, 0, 255])
        XCTAssertEqual(Array(out[8..<12]), [191, 191, 191, 255])
    }

    // MARK: Rendering

    func testListingRenderIsOpaqueTintedAndDeterministic() throws {
        let mesh = box(20, 10, 5)
        let colour = SIMD3<Float>(0.9, 0.1, 0.1)
        guard case .png(let data) = renderListingImagePNG(mesh, angle: .threeQuarter, colour: colour, background: .white, size: 48) else {
            return XCTFail("expected an image")
        }
        XCTAssertEqual(Array(data.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
        XCTAssertEqual(renderListingImagePNG(mesh, angle: .threeQuarter, colour: colour, background: .white, size: 48), .png(data))
        let rgba = try XCTUnwrap(renderMeshRGBA(mesh, size: 48, camera: listingCamera(.front),
                                                style: listingRenderStyle(colour: colour, camera: listingCamera(.front)),
                                                rasterBudget: listingImageRasterBudget))
        let centre = (24 * 48 + 24) * 4
        XCTAssertEqual(rgba[centre + 3], 255)
        XCTAssertGreaterThan(rgba[centre], rgba[centre + 1], "tinted red")
        XCTAssertEqual(rgba[3], 0, "corner left for the background")
    }

    func testListingRenderRefusesOverBudgetAndCancelledWork() {
        let mesh = box(20, 10, 5)
        XCTAssertEqual(renderListingImagePNG(mesh, angle: .front, colour: listingNeutralColour, background: .white, size: 64,
                                             rasterBudget: 10), .tooComplex)
        XCTAssertEqual(renderListingImagePNG(mesh, angle: .front, colour: listingNeutralColour, background: .white, size: 64,
                                             isCancelled: { true }), .cancelled)
        let empty = STLMesh(vertices: [], minimum: .zero, maximum: .zero)
        XCTAssertEqual(renderListingImagePNG(empty, angle: .front, colour: listingNeutralColour, background: .white, size: 64), .tooComplex)
    }

    func testExportWritesEachViewWithoutReplacingFiles() throws {
        let model = root.appendingPathComponent("box.stl")
        try box(20, 10, 5).binarySTL().write(to: model)
        let folder = root.appendingPathComponent("out", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let existing = folder.appendingPathComponent("Box – front.png")
        try Data("keep".utf8).write(to: existing)
        var reported: [ListingImageAngle] = []
        let summary = exportListingImages(modelURL: model, modelName: "Box", angles: [.front, .top], colour: listingNeutralColour,
                                          background: .lightGrey, folder: folder, size: 32, isCancelled: { false }) { _, angle in
            reported.append(angle)
        }
        XCTAssertEqual(reported, [.front, .top])
        XCTAssertEqual(summary.saved.map(\.lastPathComponent), ["Box – front 2.png", "Box – top.png"])
        XCTAssertEqual(try Data(contentsOf: existing), Data("keep".utf8), "an existing file is never replaced")
        XCTAssertTrue(summary.failures.isEmpty)
        XCTAssertFalse(summary.cancelled)
        XCTAssertEqual(listingExportResultText(summary), "Saved 2 images.")
    }

    func testExportStopsWhenCancelledAndReportsUnreadableModels() throws {
        let model = root.appendingPathComponent("box.stl")
        try box(20, 10, 5).binarySTL().write(to: model)
        var calls = 0
        let stopped = exportListingImages(modelURL: model, modelName: "Box", angles: [.front, .top, .side], colour: listingNeutralColour,
                                          background: .white, folder: root, size: 16, isCancelled: { calls > 0 }) { _, _ in calls += 1 }
        XCTAssertTrue(stopped.cancelled)
        XCTAssertLessThanOrEqual(stopped.saved.count, 1)
        XCTAssertTrue(listingExportResultText(stopped).hasPrefix("Stopped"))

        let missing = exportListingImages(modelURL: root.appendingPathComponent("missing.stl"), modelName: "Gone", angles: [.front],
                                          colour: listingNeutralColour, background: .white, folder: root, size: 16, isCancelled: { false })
        XCTAssertNotNil(missing.readFailure)
        XCTAssertTrue(missing.saved.isEmpty)
        XCTAssertTrue(listingExportResultText(missing).hasPrefix("No images were saved."))
    }

    // MARK: Listing details

    func testDimensionsInMillimetresAndInches() {
        XCTAssertEqual(listingDimensionsLine(extentMM: SIMD3(25.4, 50.8, 12.7)),
                       "Size: 25.4 × 50.8 × 12.7 mm (1.00 × 2.00 × 0.50 in), width × depth × height")
        XCTAssertEqual(listingInches(120), "4.72")
        XCTAssertEqual(listingInches(0.04), "0.00")
        XCTAssertEqual(listingDimensionsLine(extentMM: SIMD3(100, 0, 0)),
                       "Size: 100.0 × 0.0 × 0.0 mm (3.94 × 0.00 × 0.00 in), width × depth × height")
        XCTAssertTrue(listingDimensionsLine(extentMM: SIMD3(10, 10, 10), objectCount: 3)!.hasPrefix("Overall size (all 3 objects as placed): "))
        XCTAssertNil(listingDimensionsLine(extentMM: nil))
        XCTAssertNil(listingDimensionsLine(extentMM: .zero))
        XCTAssertNil(listingDimensionsLine(extentMM: SIMD3(.infinity, 1, 1)))
        XCTAssertNil(listingDimensionsLine(extentMM: SIMD3(-1, 1, 1)))
    }

    func testWeightFromModelAnalysis() {
        XCTAssertEqual(listingWeight(metrics: ["weight": 24.4]), "about 24 g (0.9 oz)")
        XCTAssertEqual(listingWeight(metrics: ["weight": "56.7", "weightUnit": "g"]), "about 57 g (2.0 oz)")
        XCTAssertEqual(listingWeight(metrics: ["weight": 0.4]), "under 1 g")
        XCTAssertEqual(listingWeight(metrics: ["weight": 1.25, "weightUnit": "kg"]), "about 1.25 kg")
        XCTAssertEqual(listingWeight(metrics: ["weight": 3, "weightUnit": "oz"]), "about 3 oz")
        XCTAssertNil(listingWeight(metrics: [:]))
        XCTAssertNil(listingWeight(metrics: ["weight": NSNull()]))
        XCTAssertNil(listingWeight(metrics: ["weight": 0]))
        XCTAssertNil(listingWeight(metrics: ["weight": -2]))
        XCTAssertNil(listingWeight(metrics: ["weight": true]))
        XCTAssertNil(listingWeight(metrics: ["weight": "heavy"]))
    }

    func testListingDetailsTextLeavesOutMissingFacts() {
        let full = listingDetailsText(ListingDetailsFacts(extentMM: SIMD3(25.4, 25.4, 25.4), materialName: " PLA Matte Black ",
                                                          weight: "about 24 g (0.9 oz)"))
        XCTAssertEqual(full, """
        Size: 25.4 × 25.4 × 25.4 mm (1.00 × 1.00 × 1.00 in), width × depth × height
        Material: PLA Matte Black
        Weight: about 24 g (0.9 oz) (printed part, before packaging)

        \(listingProductionPartnerSuggestion)

        """)
        let bare = listingDetailsText(ListingDetailsFacts(materialName: "  "))
        XCTAssertEqual(bare, listingProductionPartnerSuggestion + "\n")
        XCTAssertTrue(listingProductionPartnerSuggestion.contains("Slant 3D"))
        XCTAssertTrue(listingProductionPartnerSuggestion.contains("[your shop]"), "the seller must edit the suggestion")
    }

    func testCopiedMessageNamesWhatToCheck() {
        XCTAssertEqual(listingDetailsCopiedMessage(hasSize: true, scaleSuspect: false), "Listing details copied. " + listingProductionPartnerNote)
        XCTAssertTrue(listingDetailsCopiedMessage(hasSize: true, scaleSuspect: true).contains("millimetres"))
        XCTAssertTrue(listingDetailsCopiedMessage(hasSize: false, scaleSuspect: true).contains("without the size"))
    }
}
