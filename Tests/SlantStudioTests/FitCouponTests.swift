import CryptoKit
import XCTest
import simd
@testable import SlantStudio

final class FitCouponTests: XCTestCase {
    // MARK: Fixtures

    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// A 40 × 30 × 10 mm block with two round through-holes opening in its bed face: ⌀6 at X 10 and ⌀8 at X 30.
    static func twoHoleBlock(height: Float = 10, rings: Int = 4) throws -> STLMesh {
        try STLMesh.validated(r11PrismSoup(r11Rectangle(.zero, SIMD2(40, 30)),
                                           holes: [r11Circle(SIMD2(10, 15), radius: 3, segments: 32),
                                                   r11Circle(SIMD2(30, 15), radius: 4, segments: 40)],
                                           to: height, rings: rings))
    }

    /// A 30 × 30 × 5 mm base with a ⌀4 pin standing on its top, to Z 12, centred at (15, 15). One closed solid.
    static func pinnedBase() throws -> STLMesh {
        let rect = r11Rectangle(.zero, SIMD2(30, 30))
        let circle = r11Circle(SIMD2(15, 15), radius: 2, segments: 32)
        let base: Float = 5, top: Float = 12
        var corners: [SIMD3<Float>] = []
        // The base's top, with the pin's footprint left open, facing up.
        let planar = (rect + circle).map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let loops = [Array(0..<4), Array((4..<(4 + circle.count)).reversed())]
        for t in try triangulatePlanarRegion(points: planar, loops: loops) {
            for i in [t.x, t.y, t.z] { corners.append(SIMD3(Float(planar[Int(i)].x), Float(planar[Int(i)].y), base)) }
        }
        // The bed face, facing down.
        func at(_ p: SIMD2<Float>, _ z: Float) -> SIMD3<Float> { SIMD3(p.x, p.y, z) }
        corners += [at(rect[0], 0), at(rect[2], 0), at(rect[1], 0), at(rect[0], 0), at(rect[3], 0), at(rect[2], 0)]
        // Walls: the base's sides from 0 to 5 and the pin's from 5 to 12, both anticlockwise outlines, facing out.
        for (outline, low, high) in [(rect, Float(0), base), (circle, base, top)] {
            for i in outline.indices {
                let a = outline[i], b = outline[(i + 1) % outline.count]
                corners += [at(a, low), at(b, low), at(b, high), at(a, low), at(b, high), at(a, high)]
            }
        }
        // The pin's flat top, facing up.
        for i in 1..<(circle.count - 1) { corners += [at(circle[0], top), at(circle[i], top), at(circle[i + 1], top)] }
        return try STLMesh.validated(corners.flatMap { [$0.x, $0.y, $0.z] })
    }

    /// A ⌀60 disc, 25 mm tall in 5 rings, with a ⌀22 bearing seat and a ⌀3 hole: side and top cuts cross curved walls
    /// and the bed face's fans of thin triangles, so some cuts are tried again further out.
    static func disc() throws -> STLMesh {
        try STLMesh.validated(r11PrismSoup(r11Circle(SIMD2(30, 30), radius: 30, segments: 120),
                                           holes: [r11Circle(SIMD2(30, 30), radius: 11, segments: 72),
                                                   r11Circle(SIMD2(30, 6), radius: 1.5, segments: 16)],
                                           to: 25, rings: 5))
    }

    /// A U-shaped plate: a bar along the front and two teeth going back.
    static func comb() throws -> STLMesh {
        let outline: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 30), SIMD2(20, 30), SIMD2(20, 10), SIMD2(10, 10),
                                       SIMD2(10, 30), SIMD2(0, 30)]
        return try STLMesh.validated(r11PrismSoup(outline, to: 8))
    }

    /// The 16 mm tall two-hole block with internal walls of every kind (hole rings and slots, all open through the bed
    /// face), made once per process.
    static let slottedBlock: Result<STLMesh, Error> = Result {
        var options = InternalWallsOptions()
        options.plan = .all
        return try XCTUnwrap(try internalWallsCopy(of: try twoHoleBlock(height: 16), options: options).mesh)
    }

    private func health(_ mesh: STLMesh) throws -> MeshHealthReport { try XCTUnwrap(analyzeMeshHealth(mesh)) }

    private func polygonArea(_ points: [SIMD2<Float>]) -> Double { abs(internalWallsPolygonArea(points)) }

    private func region(_ mesh: STLMesh, _ feature: FitCouponFeature) -> FitCouponRegion {
        fitCouponRegion(around: feature, meshMinimum: mesh.minimum, meshMaximum: mesh.maximum)
    }

    // MARK: Existing Size and base outputs

    /// The flat-base and plinth outputs of fixed fixtures, hashed.
    static func existingMeshFitDigest() throws -> String {
        let block = try twoHoleBlock()
        let disc = try STLMesh.validated(r11PrismSoup(r11Circle(SIMD2(5, -3), radius: 17, segments: 90), to: 12, rings: 3))
        var plinth = PlinthSettings()
        plinth.shape = .rectangular
        plinth.marginMM = 5
        let outputs = [
            try block.flatBaseCopy(cutHeightMM: 1.3).data,
            try disc.flatBaseCopy(cutHeightMM: 0.7).data,
            try block.plinthCopy(PlinthSettings()).data,
            try disc.plinthCopy(plinth).data,
        ]
        return outputs.map(digest).joined(separator: " ")
    }

    /// Recorded from main (207d167) before the plane cut was generalised for coupons: the flat base and plinth must
    /// stay byte-identical.
    func testExistingMeshFitOutputsAreUnchanged() throws {
        XCTAssertEqual(try Self.existingMeshFitDigest(), [
            "7d8166da8edfac86cb54a51d801e3a09baaded0532485417b8bf9c9b72db8903",
            "cbbf0bbbb2a65efcea6cdb917d3172047d31a607123e057cc1a5b7371fbc94c1",
            "90da2b166e54eee77e3a463118ebe2378d8690d2a12545e19dd9be6aca1468c9",
            "faa60e67af660102e29b8ed1b0c0ae3c881205e8ea766422cd553f442813a5c5",
        ].joined(separator: " "))
    }

    // MARK: Features

    func testHolesAreListedInOrderWithLabels() throws {
        let block = try Self.twoHoleBlock()
        let features = try XCTUnwrap(fitCouponFeatures(in: block))
        XCTAssertEqual(features.map(\.label), ["6.0 mm hole near the left", "8.0 mm hole near the right"])
        XCTAssertEqual(features.map(\.kind), [.hole, .hole])
        XCTAssertEqual(features[0].centre.x, 10, accuracy: 0.01)
        XCTAssertEqual(features[0].centre.y, 15, accuracy: 0.01)
        XCTAssertTrue(features.allSatisfy(\.throughHole))
        // A through hole reaches the top of the material round it.
        XCTAssertEqual(features[0].topZ, 10, accuracy: 0.01)
        XCTAssertEqual(fitCouponFeatures(in: block)?.map(\.label), features.map(\.label), "deterministic")
    }

    func testPinOnThePartIsListedButNotTheBlockItself() throws {
        let features = try XCTUnwrap(fitCouponFeatures(in: try Self.pinnedBase()))
        XCTAssertEqual(features.map(\.label), ["4.0 mm pin in the middle"])
        XCTAssertEqual(features[0].topZ, 12, accuracy: 0.001)
        XCTAssertEqual(features[0].centre.x, 15, accuracy: 0.01)
        // A small block standing on the bed is the part, not a pin.
        let peg = try STLMesh.validated(r11PrismSoup(r11Rectangle(.zero, SIMD2(5, 5)), to: 10))
        XCTAssertEqual(fitCouponFeatures(in: peg)?.count, 0)
    }

    func testBlindHoleTopIsItsCeiling() throws {
        // A 30 × 30 × 12 block with a ⌀5 hole 6 mm deep from the bed: the hole's walls and ceiling face inward.
        let outer = try r11PrismSoup(r11Rectangle(.zero, SIMD2(30, 30)), holes: [r11Circle(SIMD2(15, 15), radius: 2.5, segments: 24)],
                                     from: 0, to: 6)
        // The upper part: the full square from 6 to 12 would duplicate the ring at Z 6, so build it from the hole's
        // ceiling (a disc facing down) and the rest of the block above Z 6.
        var corners = stride(from: 0, to: outer.count, by: 9).flatMap { i -> [Float] in
            let tri = Array(outer[i..<(i + 9)])
            // Drop the lower prism's top cap (Z 6, facing up); it becomes the block's inside.
            return tri[2] == 6 && tri[5] == 6 && tri[8] == 6 ? [] : tri
        }
        let circle = r11Circle(SIMD2(15, 15), radius: 2.5, segments: 24)
        for i in 1..<(circle.count - 1) {
            for p in [circle[0], circle[i + 1], circle[i]] { corners += [p.x, p.y, 6] }
        }
        let rect = r11Rectangle(.zero, SIMD2(30, 30))
        for i in rect.indices {
            let a = rect[i], b = rect[(i + 1) % 4]
            corners += [a.x, a.y, 6, b.x, b.y, 6, b.x, b.y, 12, a.x, a.y, 6, b.x, b.y, 12, a.x, a.y, 12]
        }
        corners += [0, 0, 12, 30, 0, 12, 30, 30, 12, 0, 0, 12, 30, 30, 12, 0, 30, 12]
        let block = try STLMesh.validated(corners)
        let report = try health(block)
        XCTAssertTrue(report.isClosed && report.isConsistentlyOriented && report.signedVolume > 0, "\(report)")
        let features = try XCTUnwrap(fitCouponFeatures(in: block))
        XCTAssertEqual(features.count, 1)
        XCTAssertFalse(features[0].throughHole)
        XCTAssertEqual(features[0].topZ, 6, accuracy: 0.001)
        let coupon = try fitCouponCopy(of: block, region: region(block, features[0]))
        // Up to 2 mm above the ceiling.
        XCTAssertEqual(coupon.mesh.maximum.z, 8, accuracy: 0.11)
        XCTAssertEqual(coupon.mesh.minimum.z, 0)
    }

    func testPositionWordsAndNames() {
        let low = SIMD2<Float>(0, 0), high = SIMD2<Float>(30, 30)
        XCTAssertEqual(fitCouponPositionWords(SIMD2(2, 2), low: low, high: high), "near the front left")
        XCTAssertEqual(fitCouponPositionWords(SIMD2(15, 28), low: low, high: high), "near the back")
        XCTAssertEqual(fitCouponPositionWords(SIMD2(15, 15), low: low, high: high), "in the middle")
        XCTAssertEqual(fitCouponPositionWords(SIMD2(29, 15), low: low, high: high), "near the right")
        XCTAssertEqual(fitCouponFeatureName(.pin, sizeMM: SIMD2(3, 6)), "3.0 × 6.0 mm post")
        XCTAssertEqual(fitCouponFeatureName(.hole, sizeMM: SIMD2(22, 22)), "22.0 mm hole")
        XCTAssertEqual(fitCouponCopyName("Bracket.stl"), "Bracket (fit coupon)")
        XCTAssertEqual(fitCouponCopyName("  "), "Model (fit coupon)")
    }

    func testRepeatedLabelsGetPositions() throws {
        let block = try STLMesh.validated(r11PrismSoup(r11Rectangle(.zero, SIMD2(60, 30)),
                                                       holes: [r11Circle(SIMD2(5, 15), radius: 2, segments: 24),
                                                               r11Circle(SIMD2(12, 15), radius: 2, segments: 24)], to: 6))
        let labels = try XCTUnwrap(fitCouponFeatures(in: block)).map(\.label)
        XCTAssertEqual(labels, ["4.0 mm hole near the left (X 5, Y 15)", "4.0 mm hole near the left (X 12, Y 15)"])
    }

    // MARK: Regions

    func testRegionHasTheMarginAndShiftsInward() {
        let feature = FitCouponFeature(kind: .hole, centre: SIMD2(4, 50), sizeMM: SIMD2(6, 6), topZ: 8, throughHole: false, label: "")
        let r = fitCouponRegion(around: feature, meshMinimum: .zero, meshMaximum: SIMD3(100, 100, 30))
        // 20 mm across, moved in from the left edge instead of running off it.
        XCTAssertEqual(r.low.x, 0); XCTAssertEqual(r.high.x, 20)
        XCTAssertEqual(r.low.y, 40); XCTAssertEqual(r.high.y, 60)
        XCTAssertEqual(r.topZ, 10)
        // A large hole gets its margin; a narrow model isn't cut on that axis.
        let big = FitCouponFeature(kind: .hole, centre: SIMD2(50, 8), sizeMM: SIMD2(22, 22), topZ: 40, throughHole: true, label: "")
        let wide = fitCouponRegion(around: big, meshMinimum: .zero, meshMaximum: SIMD3(100, 16, 30))
        XCTAssertEqual(wide.high.x - wide.low.x, 28)
        XCTAssertLessThan(wide.low.y, 0); XCTAssertGreaterThan(wide.high.y, 16)
        XCTAssertEqual(wide.topZ, 30, "never above the model")
        XCTAssertEqual(fitCouponExpectedSize(wide, meshMinimum: .zero, meshMaximum: SIMD3(100, 16, 30)), SIMD3(28, 16, 30))
    }

    func testBottomSliceHeightRange() {
        let top = SIMD3<Float>(40, 30, 10)
        XCTAssertNotNil(fitCouponBottomSliceRegion(heightMM: 3, meshMinimum: .zero, meshMaximum: top))
        XCTAssertNil(fitCouponBottomSliceRegion(heightMM: 0.5, meshMinimum: .zero, meshMaximum: top))
        XCTAssertNil(fitCouponBottomSliceRegion(heightMM: 21, meshMinimum: .zero, meshMaximum: SIMD3(40, 30, 50)))
        XCTAssertNil(fitCouponBottomSliceRegion(heightMM: 9.8, meshMinimum: .zero, meshMaximum: top), "the whole model")
        XCTAssertEqual(fitCouponSliceHeightProblem(modelHeightMM: 10), "Enter a slice height from 1 to 9.5 mm.")
        XCTAssertEqual(fitCouponSliceHeightProblem(modelHeightMM: 40), "Enter a slice height from 1 to 20 mm.")
        XCTAssertTrue(fitCouponSliceHeightProblem(modelHeightMM: 1.2).contains("too thin"))
        XCTAssertNil(fitCouponRegion(for: .feature(3), features: [], sliceHeightMM: nil, meshMinimum: .zero, meshMaximum: top))
    }

    // MARK: Coupons

    func testCouponRoundAHoleIsOneSoundShellWithTheHoleUnchanged() throws {
        let block = try Self.twoHoleBlock()
        let features = try XCTUnwrap(fitCouponFeatures(in: block))
        let r = region(block, features[0])
        let coupon = try fitCouponCopy(of: block, region: r)
        let report = try health(coupon.mesh)
        XCTAssertTrue(meshHealthIsSound(report), "\(report)")
        XCTAssertEqual(report.shells, 1)
        XCTAssertEqual(coupon.mesh.minimum.z, block.minimum.z, "keeps the bed face")
        XCTAssertEqual(coupon.mesh.minimum.x, 0)
        XCTAssertEqual(coupon.mesh.maximum.x, 20, accuracy: 0.11)
        XCTAssertEqual(coupon.mesh.minimum.y, 5, accuracy: 0.11)
        XCTAssertEqual(coupon.mesh.maximum.y, 25, accuracy: 0.11)
        XCTAssertEqual(coupon.mesh.maximum.z, 10)
        // At least the margin all round the hole.
        XCTAssertLessThanOrEqual(coupon.mesh.minimum.x, 10 - 3 - fitCouponMarginMM)
        XCTAssertGreaterThanOrEqual(coupon.mesh.maximum.x, 10 + 3 + fitCouponMarginMM)
        // Every triangle of the hole's wall is in the coupon, exactly.
        func triangles(_ mesh: STLMesh) -> [[Float]] {
            stride(from: 0, to: mesh.vertices.count, by: 9).map { Array(mesh.vertices[$0..<($0 + 9)]) }
        }
        let couponTriangles = Set(triangles(coupon.mesh))
        let wall = triangles(block).filter { t in
            stride(from: 0, to: 9, by: 3).allSatisfy { simd_distance(SIMD2(t[$0], t[$0 + 1]), SIMD2(10, 15)) <= 3.01 }
        }
        XCTAssertFalse(wall.isEmpty)
        XCTAssertTrue(wall.allSatisfy { couponTriangles.contains($0) })
        // The hole still opens through the coupon's bed face.
        XCTAssertEqual(fitCouponFeatures(in: coupon.mesh)?.map(\.kind), [.hole])
        let holeArea = polygonArea(r11Circle(SIMD2(10, 15), radius: 3, segments: 32))
        XCTAssertEqual(coupon.volumeMM3, (Double(coupon.sizeMM.x) * Double(coupon.sizeMM.y) - holeArea) * 10, accuracy: 0.05)
    }

    func testCouponRoundAPinKeepsTheWholePin() throws {
        let part = try Self.pinnedBase()
        XCTAssertTrue(meshHealthIsSound(try health(part)))
        let feature = try XCTUnwrap(fitCouponFeatures(in: part)?.first)
        let coupon = try fitCouponCopy(of: part, region: region(part, feature))
        XCTAssertEqual(try health(coupon.mesh).shells, 1)
        XCTAssertEqual(coupon.sizeMM.x, 20, accuracy: 0.11)
        XCTAssertEqual(coupon.mesh.maximum.z, 12)
        let pinArea = polygonArea(r11Circle(SIMD2(15, 15), radius: 2, segments: 32))
        XCTAssertEqual(coupon.volumeMM3, Double(coupon.sizeMM.x) * Double(coupon.sizeMM.y) * 5 + pinArea * 7, accuracy: 0.5)
    }

    func testCropThatWouldSplitThePartIsRefused() throws {
        let comb = try Self.comb()
        // A box across both teeth but not the bar joining them.
        let across = FitCouponRegion(low: SIMD2(-1, 15), high: SIMD2(31, 31), topZ: 8)
        XCTAssertThrowsError(try fitCouponCopy(of: comb, region: across)) { error in
            XCTAssertEqual(error as? FitCouponError, .splits(pieces: 2))
        }
        // Taking in the bar keeps one piece.
        let joined = FitCouponRegion(low: SIMD2(-1, -1), high: SIMD2(31, 20), topZ: 8)
        XCTAssertEqual(try health(try fitCouponCopy(of: comb, region: joined).mesh).shells, 1)
    }

    func testSmallAndMissingCropsAreRefused() throws {
        let block = try Self.twoHoleBlock()
        XCTAssertThrowsError(try fitCouponCopy(of: block, region: FitCouponRegion(low: SIMD2(-1, -1), high: SIMD2(4, 31), topZ: 20))) {
            guard case .tooSmall = $0 as? FitCouponError else { return XCTFail("\($0)") }
        }
        XCTAssertThrowsError(try fitCouponCopy(of: block, region: FitCouponRegion(low: SIMD2(50, 0), high: SIMD2(60, 30), topZ: 20))) {
            XCTAssertEqual($0 as? FitCouponError, .missesModel)
        }
        // An open mesh is refused before anything is cut.
        let open = try STLMesh.validated(Array(block.vertices.dropLast(9)))
        XCTAssertThrowsError(try fitCouponCopy(of: open, region: FitCouponRegion(low: .zero, high: SIMD2(20, 20), topZ: 5))) {
            XCTAssertEqual($0 as? FitCouponError, .notClosedSolid)
        }
        XCTAssertThrowsError(try fitCouponCopy(of: block, region: FitCouponRegion(low: .zero, high: SIMD2(20, 20), topZ: 5),
                                               isCancelled: { true })) {
            XCTAssertEqual($0 as? FitCouponError, .stopped)
        }
    }

    func testBottomSliceVolumeIsFootprintTimesHeight() throws {
        let block = try Self.twoHoleBlock()
        let slice = try XCTUnwrap(fitCouponBottomSliceRegion(heightMM: 3, meshMinimum: block.minimum, meshMaximum: block.maximum))
        let coupon = try fitCouponCopy(of: block, region: slice)
        let footprint = 40.0 * 30 - polygonArea(r11Circle(SIMD2(10, 15), radius: 3, segments: 32))
            - polygonArea(r11Circle(SIMD2(30, 15), radius: 4, segments: 40))
        XCTAssertEqual(coupon.volumeMM3, footprint * 3, accuracy: footprint * 3 * 1e-5)
        XCTAssertEqual(coupon.bedContactMM2, footprint, accuracy: 0.01)
        XCTAssertEqual(coupon.sizeMM, SIMD3(40, 30, 3))
        XCTAssertTrue(meshHealthIsSound(try health(coupon.mesh)))
    }

    func testCouponOfASlottedCopyKeepsItsSlotsOpen() throws {
        let block = try Self.twoHoleBlock(height: 16)
        let slotted = try Self.slottedBlock.get()
        let before = try health(slotted)
        XCTAssertEqual(before.shells, 1)
        // The ring's outline round the bore isn't listed as a hole of its own.
        let features = try XCTUnwrap(fitCouponFeatures(in: slotted))
        XCTAssertEqual(features.map(\.label), ["6.0 mm hole near the left", "8.0 mm hole near the right"])
        let r = region(slotted, features[0])
        let coupon = try fitCouponCopy(of: slotted, region: r)
        let after = try health(coupon.mesh)
        XCTAssertTrue(meshHealthIsSound(after))
        XCTAssertEqual(after.shells, 1, "no closed cavities")
        // Less material than the same crop of the unslotted block, and the bed face still has the slots' openings.
        let plain = try fitCouponCopy(of: block, region: r)
        XCTAssertLessThan(coupon.volumeMM3, plain.volumeMM3 - 1)
        XCTAssertLessThan(coupon.bedContactMM2, plain.bedContactMM2 - 0.5)
    }

    func testCouponsOnCurvedAndGridAlignedParts() throws {
        let disc = try Self.disc()
        let features = try XCTUnwrap(fitCouponFeatures(in: disc))
        XCTAssertEqual(features.map(\.label), ["3.0 mm hole near the front", "22.0 mm hole in the middle"], "same X: by Y")
        for feature in features {
            let coupon = try fitCouponCopy(of: disc, region: region(disc, feature))
            XCTAssertTrue(meshHealthIsSound(try health(coupon.mesh)), feature.label)
            XCTAssertEqual(coupon.mesh.minimum.z, 0)
        }
        // A cut with the bottom slice through the curved wall at a ring height moves clear of the vertices.
        let slice = try XCTUnwrap(fitCouponBottomSliceRegion(heightMM: 5, meshMinimum: disc.minimum, meshMaximum: disc.maximum))
        let sliced = try fitCouponCopy(of: disc, region: slice)
        XCTAssertTrue(meshHealthIsSound(try health(sliced.mesh)))
        XCTAssertEqual(sliced.sizeMM.z, 5.05, accuracy: 0.001, "moved up clear of the ring at Z 5")
        // An outline with corners exactly where the box's side falls (X 20): the side moves outward to clear them.
        let outline: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(20, 0), SIMD2(40, 0), SIMD2(40, 30), SIMD2(20, 30), SIMD2(0, 30)]
        let grid = try STLMesh.validated(r11PrismSoup(outline, holes: [r11Circle(SIMD2(10, 15), radius: 3, segments: 32)], to: 30, rings: 3))
        let hole = try XCTUnwrap(fitCouponFeatures(in: grid)?.first)
        let r = region(grid, hole)
        XCTAssertEqual(r.high.x, 20)
        let coupon = try fitCouponCopy(of: grid, region: r)
        XCTAssertTrue(meshHealthIsSound(try health(coupon.mesh)))
        XCTAssertEqual(coupon.mesh.maximum.x, 20.05, accuracy: 0.001)
        XCTAssertEqual(coupon.mesh.maximum.z, 30, "a through hole runs the full height")
    }

    func testClearedPlaneAndDelaunayFill() throws {
        // Heights are every third of nine-per-triangle coordinates; only z matters.
        let heights: [Float] = [0, 0, 5, 0, 0, 4.97, 0, 0, 1]
        XCTAssertEqual(meshFitClearedPlane(5, heights: heights, clearance: 0.05, maximumMove: 1), 4.92, accuracy: 1e-5)
        XCTAssertEqual(meshFitClearedPlane(5, heights: heights, clearance: 0, maximumMove: 1), 5)
        XCTAssertEqual(meshFitClearedPlane(3, heights: heights, clearance: 0.05, maximumMove: 1), 3)
        // A 20 × 5 rectangle with many points along its long sides: ear clipping makes fans; the flips keep the area,
        // the outline and the winding, and make the thinnest triangle fatter.
        var points: [SIMD2<Double>] = []
        for i in 0...20 { points.append(SIMD2(Double(i), 0)) }
        for i in (0...20).reversed() { points.append(SIMD2(Double(i), 5)) }
        let loop = Array(points.indices)
        var triangles = try triangulatePlanarRegion(points: points, loops: [loop])
        func area(_ t: SIMD3<Int32>) -> Double {
            let a = points[Int(t.x)], b = points[Int(t.y)], c = points[Int(t.z)]
            return ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        func thinnest(_ list: [SIMD3<Int32>]) -> Double {
            list.map { t -> Double in
                let a = points[Int(t.x)], b = points[Int(t.y)], c = points[Int(t.z)]
                let longest = max(simd_distance_squared(a, b), simd_distance_squared(b, c), simd_distance_squared(c, a))
                return 2 * area(t) / longest
            }.min() ?? 0
        }
        let before = thinnest(triangles)
        delaunayFlipPlanar(&triangles, points: points)
        XCTAssertEqual(triangles.map(area).reduce(0, +), 100, accuracy: 1e-9)
        XCTAssertTrue(triangles.allSatisfy { area($0) > 0 })
        XCTAssertGreaterThanOrEqual(thinnest(triangles), before)
        XCTAssertGreaterThan(thinnest(triangles), 0.1)
    }

    func testEditAvailabilityAndCopyLineage() {
        var copy = LocalModel(name: "Owl", filePath: "/tmp/owl.stl")
        copy.inheritsZUpLock = true
        XCTAssertTrue(copy.requiresZUp)
        // The coupon keeps the bed face and the way up, so even Z-up-locked copies can have one.
        XCTAssertNil(meshFitEditBlockedReason(copy, tool: .fitCoupon))
        XCTAssertNotNil(meshFitEditBlockedReason(copy, tool: .flatBase))
        XCTAssertNotNil(meshFitEditBlockedReason(LocalModel(name: "Owl", filePath: "/tmp/owl.3mf"), tool: .fitCoupon))
        XCTAssertTrue(studioCopyLineage(copy).inheritsZUpLock)
        // Saved as a Studio tool copy, which is never prepared automatically.
        XCTAssertFalse(ModelImportOrigin.studioToolCopy.mayPrepareForPrinting)
        XCTAssertEqual(MeshFitTool.fitCoupon.title, "Make Fit Coupon")
    }

    func testCaptionPromisesNoFit() {
        for text in [fitCouponCaption, fitCouponPrintReadyHint, fitCouponFeatureNote(FitCouponFeature(
            kind: .pin, centre: .zero, sizeMM: SIMD2(4, 4), topZ: 9, throughHole: false, label: ""))] {
            for word in ["will fit", "guarantee", "strong", "safe", "perfect"] {
                XCTAssertFalse(text.lowercased().contains(word), "\(word) in \(text)")
            }
        }
        XCTAssertTrue(fitCouponCaption.contains("checks nothing about fit"))
    }

    // MARK: Hash seeds

    /// Coupons of every kind (a hole, a pin, a Bottom slice, a slotted copy, a cut tried again), with the existing flat
    /// base and plinth.
    static func couponDigest() throws -> String {
        let block = try twoHoleBlock(height: 16)
        let features = try XCTUnwrap(fitCouponFeatures(in: block))
        let slotted = try slottedBlock.get()
        let pinned = try pinnedBase()
        let pin = try XCTUnwrap(fitCouponFeatures(in: pinned)?.first)
        let round = try disc()
        let bearing = try XCTUnwrap(fitCouponFeatures(in: round)?.last)
        let slice = try XCTUnwrap(fitCouponBottomSliceRegion(heightMM: 4.5, meshMinimum: block.minimum, meshMaximum: block.maximum))
        let outputs = [
            try fitCouponCopy(of: block, region: fitCouponRegion(around: features[1], meshMinimum: block.minimum, meshMaximum: block.maximum)).data,
            try fitCouponCopy(of: slotted, region: fitCouponRegion(around: features[0], meshMinimum: slotted.minimum, meshMaximum: slotted.maximum)).data,
            try fitCouponCopy(of: pinned, region: fitCouponRegion(around: pin, meshMinimum: pinned.minimum, meshMaximum: pinned.maximum)).data,
            try fitCouponCopy(of: block, region: slice).data,
            try fitCouponCopy(of: round, region: fitCouponRegion(around: bearing, meshMinimum: round.minimum, meshMaximum: round.maximum)).data,
        ]
        return outputs.map(digest).joined(separator: " ") + " " + (try existingMeshFitDigest())
    }

    /// Run only as a subprocess by `PrintPreparationFixesTests.testPipelineBytesMatchAcrossHashSeeds`.
    func testHashSeedProbeWritesCouponHash() throws {
        guard let out = ProcessInfo.processInfo.environment["SLANT_R12_COUPON_HASH_OUT"] else { return }
        try Self.couponDigest().write(toFile: out, atomically: true, encoding: .utf8)
    }

    // Compared across hash seeds by `PrintPreparationFixesTests.testPipelineBytesMatchAcrossHashSeeds`, with the other
    // geometry probes, so the bundle is launched once per seed.
}
