import XCTest
import simd
@testable import SlantStudio

final class MeshFitTests: XCTestCase {
    // MARK: Fixtures

    private func mesh(_ corners: [SIMD3<Float>]) throws -> STLMesh {
        try STLMesh.validated(corners.flatMap { [$0.x, $0.y, $0.z] })
    }

    /// Outward-wound box triangles; `inward` flips them, for the inner wall of a hollow box.
    private func boxTriangles(_ low: SIMD3<Float>, _ high: SIMD3<Float>, inward: Bool = false) -> [SIMD3<Float>] {
        let p: [SIMD3<Float>] = [
            SIMD3(low.x, low.y, low.z), SIMD3(high.x, low.y, low.z), SIMD3(high.x, high.y, low.z), SIMD3(low.x, high.y, low.z),
            SIMD3(low.x, low.y, high.z), SIMD3(high.x, low.y, high.z), SIMD3(high.x, high.y, high.z), SIMD3(low.x, high.y, high.z)
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)
        ]
        return faces.flatMap { inward ? [p[$0.0], p[$0.2], p[$0.1]] : [p[$0.0], p[$0.1], p[$0.2]] }
    }

    private func box(_ size: SIMD3<Float>, at origin: SIMD3<Float> = .zero) throws -> STLMesh {
        try mesh(boxTriangles(origin, origin + size))
    }

    /// A closed box with walls `wall` thick all round (two shells: the outside, and the cavity facing inward).
    private func hollowBox(size: Float = 20, wall: Float) throws -> STLMesh {
        try mesh(boxTriangles(.zero, SIMD3(repeating: size))
                 + boxTriangles(SIMD3(repeating: wall), SIMD3(repeating: size - wall), inward: true))
    }

    /// A closed, outward-facing UV sphere whose lowest point is at `centre.z - radius`.
    private func sphere(radius: Float = 20, centre: SIMD3<Float> = SIMD3(0, 0, 20), segments: Int = 48, rings: Int = 24) throws -> STLMesh {
        var grid: [[SIMD3<Float>]] = []
        for r in 0...rings {
            let theta = Float.pi * Float(r) / Float(rings)
            grid.append((0..<segments).map { s in
                if r == 0 { return centre + SIMD3(0, 0, -radius) }
                if r == rings { return centre + SIMD3(0, 0, radius) }
                let phi = 2 * Float.pi * Float(s) / Float(segments)
                return centre + SIMD3(sin(theta) * cos(phi), sin(theta) * sin(phi), -cos(theta)) * radius
            })
        }
        var corners: [SIMD3<Float>] = []
        for r in 0..<rings {
            for s in 0..<segments {
                let a = grid[r][s], b = grid[r][(s + 1) % segments], c = grid[r + 1][(s + 1) % segments], d = grid[r + 1][s]
                // The pole rows have one triangle per segment; the other would repeat the pole.
                if r != rings - 1 { corners += [a, c, d] }
                if r != 0 { corners += [a, b, c] }
            }
        }
        return try mesh(corners)
    }

    private func requireClosedOutward(_ mesh: STLMesh, file: StaticString = #filePath, line: UInt = #line) throws -> MeshHealthReport {
        let report = try XCTUnwrap(analyzeMeshHealth(mesh), file: file, line: line)
        XCTAssertTrue(report.isClosed, "open \(report.openEdges), non-manifold \(report.nonManifoldEdges)", file: file, line: line)
        XCTAssertTrue(report.isConsistentlyOriented, file: file, line: line)
        XCTAssertGreaterThan(report.signedVolume, 0, file: file, line: line)
        return report
    }

    func testFixturesAreClosedOutwardSolids() throws {
        _ = try requireClosedOutward(try box(SIMD3(10, 10, 10)))
        _ = try requireClosedOutward(try hollowBox(wall: 1))
        let ball = try requireClosedOutward(try sphere())
        XCTAssertEqual(ball.shells, 1)
    }

    // MARK: Millimetre input

    func testMillimetreInputIsStrict() {
        XCTAssertEqual(meshFitMillimetres("50"), 50)
        XCTAssertEqual(meshFitMillimetres(" 12.5 mm "), 12.5)
        XCTAssertEqual(meshFitMillimetres("12,5"), 12.5)
        XCTAssertNil(meshFitMillimetres(""))
        XCTAssertNil(meshFitMillimetres("0"))
        XCTAssertNil(meshFitMillimetres("-3"))
        XCTAssertNil(meshFitMillimetres("1e3"))
        XCTAssertNil(meshFitMillimetres("1.2.3"))
        XCTAssertNil(meshFitMillimetres("."))
        XCTAssertNil(meshFitMillimetres("20000"))
        XCTAssertNil(meshFitMillimetres("nan"))
    }

    // MARK: Scale to size

    func testScalePlanForEachAxis() throws {
        let extent = SIMD3<Float>(40, 20, 10)
        let longest = try scaleToSizePlan(extentMM: extent, axis: .longest, targetMM: 100)
        XCTAssertEqual(longest.factor, 2.5, accuracy: 1e-12)
        XCTAssertEqual(longest.resultSizeMM, SIMD3(100, 50, 25))
        XCTAssertTrue(longest.fitsBuildVolume)
        let tall = try scaleToSizePlan(extentMM: extent, axis: .z, targetMM: 30)
        XCTAssertEqual(tall.factor, 3, accuracy: 1e-12)
        XCTAssertEqual(tall.resultSizeMM.x, 120, accuracy: 1e-4)
        let wide = try scaleToSizePlan(extentMM: extent, axis: .y, targetMM: 200)
        XCTAssertEqual(wide.resultSizeMM.x, 400, accuracy: 1e-3)
        XCTAssertFalse(wide.fitsBuildVolume)
        XCTAssertThrowsError(try scaleToSizePlan(extentMM: extent, axis: .x, targetMM: 0))
        XCTAssertThrowsError(try scaleToSizePlan(extentMM: extent, axis: .x, targetMM: .nan))
        XCTAssertThrowsError(try scaleToSizePlan(extentMM: SIMD3(40, 20, 0), axis: .z, targetMM: 10)) { error in
            XCTAssertEqual(error as? MeshFitError, .flatAxis)
        }
    }

    func testScaledToSizeDataIsExactAndRefusesOversize() throws {
        let model = try sphere(radius: 7.3, centre: SIMD3(1.1, -2.2, 9))
        for axis in MeshFitAxis.allCases {
            let (data, plan) = try model.scaledToSizeSTLData(axis: axis, targetMM: 63.5)
            let scaled = try STLMesh.parse(data)
            XCTAssertEqual(scaled.triangleCount, model.triangleCount)
            let extent = scaled.maximum - scaled.minimum
            let measured: Float
            switch axis {
            case .longest: measured = extent.max()
            case .x: measured = extent.x
            case .y: measured = extent.y
            case .z: measured = extent.z
            }
            XCTAssertEqual(measured, 63.5, accuracy: 63.5 * 1e-4, "\(axis)")
            XCTAssertEqual(plan.resultSizeMM.max(), extent.max(), accuracy: 0.01)
            XCTAssertEqual(try model.scaledToSizeSTLData(axis: axis, targetMM: 63.5).data, data)
        }
        XCTAssertThrowsError(try model.scaledToSizeSTLData(axis: .longest, targetMM: 221)) { error in
            guard case .exceedsBuildVolume = error as? MeshFitError else { return XCTFail("\(error)") }
        }
        XCTAssertNoThrow(try model.scaledToSizeSTLData(axis: .longest, targetMM: 220))
    }

    func testCopyNames() throws {
        let plan = try scaleToSizePlan(extentMM: SIMD3(10, 10, 10), axis: .z, targetMM: 50)
        XCTAssertEqual(scaledToSizeCopyName("Owl.stl", plan: plan), "Owl (scaled to 50 mm tall)")
        let longest = try scaleToSizePlan(extentMM: SIMD3(10, 10, 10), axis: .longest, targetMM: 120.5)
        XCTAssertEqual(scaledToSizeCopyName("Owl", plan: longest), "Owl (scaled to 120.5 mm)")
        XCTAssertEqual(flatBaseCopyName("Owl.STL"), "Owl (flat base)")
        XCTAssertEqual(plinthCopyName("v1.2 owl"), "v1.2 owl (plinth)")
        XCTAssertEqual(plinthCopyName("  "), "Model (plinth)")
    }

    func testResultsWithNewZeroAreaTrianglesAreRefused() {
        func report(degenerate: Int, open: Int = 0) -> MeshHealthReport {
            MeshHealthReport(triangleCount: 20, vertexCount: 10, openEdges: open, nonManifoldEdges: 0, flippedEdges: 0,
                             degenerateTriangles: degenerate, shells: 1, signedVolume: 5)
        }
        XCTAssertNil(meshFitResultProblem(report(degenerate: 0), inputZeroArea: 0))
        XCTAssertNil(meshFitResultProblem(report(degenerate: 2), inputZeroArea: 2))
        XCTAssertEqual(meshFitResultProblem(report(degenerate: 1), inputZeroArea: 0), .addedZeroAreaTriangles)
        XCTAssertEqual(meshFitResultProblem(report(degenerate: 0, open: 3), inputZeroArea: 0), .resultNotClosed)
        XCTAssertTrue(MeshFitError.addedZeroAreaTriangles.localizedDescription.contains("zero-area"))
    }

    // MARK: Triangulation

    func testRegionWithHoleIsCoveredExactly() throws {
        let points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(4, 0), SIMD2(4, 4), SIMD2(0, 4),
                                       SIMD2(1, 1), SIMD2(1, 3), SIMD2(3, 3), SIMD2(3, 1),
                                       SIMD2(2, 0)]
        // Outer loop with a collinear point on its bottom edge; the hole runs clockwise.
        let triangles = try triangulatePlanarRegion(points: points, loops: [[0, 8, 1, 2, 3], [4, 5, 6, 7]])
        var area = 0.0
        for t in triangles {
            let a = points[Int(t.x)], b = points[Int(t.y)], c = points[Int(t.z)]
            let signed = ((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
            XCTAssertGreaterThan(signed, 0)
            area += signed
        }
        XCTAssertEqual(area, 12, accuracy: 1e-12)
        // Every outline point is used, so the fill meets the outline without T-junctions.
        XCTAssertEqual(Set(triangles.flatMap { [$0.x, $0.y, $0.z] }), Set((0..<9).map(Int32.init)))
    }

    func testCrossingOutlineIsRefused() {
        let bowtie: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(2, 2), SIMD2(2, 0), SIMD2(0, 2)]
        XCTAssertThrowsError(try triangulatePlanarRegion(points: bowtie, loops: [[0, 1, 2, 3]]))
        let orphanHole: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(0, 1), SIMD2(1, 1), SIMD2(1, 0)]
        XCTAssertThrowsError(try triangulatePlanarRegion(points: orphanHole, loops: [[0, 1, 2, 3]]))
    }

    // MARK: Flat base

    func testFlatBaseOnCubeKeepsClosedSolid() throws {
        let cube = try box(SIMD3(10, 10, 10))
        let result = try cube.flatBaseCopy(cutHeightMM: 2.5)
        let report = try requireClosedOutward(result.mesh)
        XCTAssertEqual(report.signedVolume, 750, accuracy: 0.01)
        XCTAssertEqual(result.contactAreaMM2, 100, accuracy: 1e-4)
        XCTAssertEqual(result.cutHeightMM, 2.5, accuracy: 1e-6)
        XCTAssertEqual(result.mesh.minimum.z, 2.5, accuracy: 1e-6)
        XCTAssertEqual(result.mesh.maximum, cube.maximum)
        XCTAssertEqual(try cube.flatBaseCopy(cutHeightMM: 2.5).data, result.data)
    }

    func testFlatBaseOnSphereAndAtAVertexHeight() throws {
        let ball = try sphere()
        let result = try ball.flatBaseCopy(cutHeightMM: 3)
        let report = try requireClosedOutward(result.mesh)
        XCTAssertEqual(report.shells, 1)
        // A circle of radius √(2·20·3 − 9) ≈ 10.5; the faceted sphere's section is a little smaller.
        let circle = Double.pi * (2 * 20 * 3 - 9)
        XCTAssertEqual(result.contactAreaMM2, circle, accuracy: circle * 0.03)
        XCTAssertEqual(result.contactAreaMM2, ball.crossSectionAreaMM2(atHeight: 3), accuracy: 1e-3)
        XCTAssertEqual(try ball.flatBaseCopy(cutHeightMM: 3).data, result.data)

        // A cut exactly at a ring of vertices is nudged up by a micron, so it still closes.
        let ringHeight = ball.vertices[stride(from: 2, to: ball.vertices.count, by: 3).first { ball.vertices[$0] > ball.minimum.z + 1 }!] - ball.minimum.z
        let atRing = try ball.flatBaseCopy(cutHeightMM: ringHeight)
        _ = try requireClosedOutward(atRing.mesh)
        XCTAssertGreaterThan(atRing.cutHeightMM, ringHeight)
        XCTAssertLessThan(atRing.cutHeightMM, ringHeight + 0.01)
    }

    func testFlatBaseThroughHollowWallFillsTheRingOnly() throws {
        let hollow = try hollowBox(wall: 1)
        let result = try hollow.flatBaseCopy(cutHeightMM: 5)
        let report = try requireClosedOutward(result.mesh)
        XCTAssertEqual(result.contactAreaMM2, 400 - 324, accuracy: 1e-3)
        // Removed: the 1 mm floor (400 mm³) and 4 mm of the walls' ring (4 × 76 mm³).
        XCTAssertEqual(report.signedVolume, (8000 - 5832) - 400 - 4 * 76, accuracy: 0.05)
    }

    func testFlatBaseRefusesOpenMeshesAndBadHeights() throws {
        let open = try mesh(Array(boxTriangles(.zero, SIMD3(repeating: 10)).dropLast(3)))
        XCTAssertThrowsError(try open.flatBaseCopy(cutHeightMM: 2)) { XCTAssertEqual($0 as? MeshFitError, .notClosedSolid) }
        let cube = try box(SIMD3(10, 10, 10))
        for height: Float in [0, -1, 10, 11, .nan] {
            XCTAssertThrowsError(try cube.flatBaseCopy(cutHeightMM: height), "\(height)")
        }
        XCTAssertThrowsError(try cube.flatBaseCopy(cutHeightMM: 2, isCancelled: { true })) {
            XCTAssertEqual($0 as? MeshFitError, .stopped)
        }
    }

    func testFlatBaseSuggestion() throws {
        let cube = try box(SIMD3(10, 10, 10))
        let flat = cube.flatBaseSuggestion()
        XCTAssertTrue(flat.alreadyFlat)
        XCTAssertNil(flat.cutHeightMM)
        XCTAssertEqual(flat.currentContactMM2, 100, accuracy: 1e-4)

        let ball = try sphere()
        let suggestion = ball.flatBaseSuggestion()
        XCTAssertFalse(suggestion.alreadyFlat)
        XCTAssertEqual(suggestion.targetContactMM2, 100) // min(100, 15% of 1,600)
        let cut = try XCTUnwrap(suggestion.cutHeightMM)
        XCTAssertGreaterThan(cut, 0.5)
        XCTAssertLessThan(cut, 1.5)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(suggestion.contactAtCutMM2), 100)
        XCTAssertLessThan(ball.crossSectionAreaMM2(atHeight: cut - 0.05), 100)
        XCTAssertEqual(ball.flatBaseSuggestion(), suggestion)

        let unreachable = ball.flatBaseSuggestion(minimumContactMM2: 10_000, minimumContactFraction: 1)
        XCTAssertNil(unreachable.cutHeightMM)
        XCTAssertEqual(unreachable.maximumCutMM, 5)
    }

    // MARK: Plinth

    func testRoundPlinthOnSphereIsOneClosedSolid() throws {
        let ball = try sphere()
        let settings = PlinthSettings(shape: .round, marginMM: 3, thicknessMM: 4, joinDepthMM: 0.5)
        let result = try ball.plinthCopy(settings)
        let report = try requireClosedOutward(result.mesh)
        XCTAssertEqual(report.shells, 1)
        // The top's triangulation around the sphere's outline used to end in a sliver; now it adds none.
        XCTAssertEqual(report.degenerateTriangles, 0)
        XCTAssertEqual(result.mesh.minimum.z, ball.minimum.z + 0.5 - 4, accuracy: 1e-4)
        XCTAssertEqual(result.mesh.maximum.z, ball.maximum.z, accuracy: 1e-6)
        // Covers the whole footprint plus the margin.
        XCTAssertLessThanOrEqual(result.mesh.minimum.x, ball.minimum.x - 3 + 1e-3)
        // The bottom is chamfered 0.5 mm in from the 23 mm outline.
        XCTAssertGreaterThan(result.contactAreaMM2, Double.pi * 22.5 * 22.5 * 0.99)
        XCTAssertLessThan(result.contactAreaMM2, Double.pi * 23 * 23 * 0.99)
        XCTAssertTrue(result.fitsBuildVolume)
        XCTAssertEqual(try ball.plinthCopy(settings).data, result.data)
    }

    func testRectangularPlinthUnderHollowBoxFillsInsideTheWalls() throws {
        let hollow = try hollowBox(wall: 2)
        let result = try hollow.plinthCopy(PlinthSettings(shape: .rectangular, marginMM: 5, thicknessMM: 3, joinDepthMM: 1))
        let report = try requireClosedOutward(result.mesh)
        XCTAssertEqual(report.shells, 2) // The outside, and the cavity above the plinth.
        XCTAssertEqual(result.contactAreaMM2, 29 * 29, accuracy: 1e-3)
        XCTAssertEqual(result.sizeMM.x, 30, accuracy: 1e-4)
        XCTAssertEqual(result.sizeMM.z, 20 - 1 + 3, accuracy: 1e-4)
    }

    func testPlinthBottomEdgeIsChamfered() throws {
        let result = try box(SIMD3(10, 10, 10)).plinthCopy(PlinthSettings(shape: .rectangular, marginMM: 2, thicknessMM: 2, joinDepthMM: 0.5))
        _ = try requireClosedOutward(result.mesh)
        let v = result.mesh.vertices
        let low = result.mesh.minimum, high = result.mesh.maximum
        var bottom: [SIMD3<Float>] = []
        for i in stride(from: 0, to: v.count, by: 3) where v[i + 2] == low.z { bottom.append(SIMD3(v[i], v[i + 1], v[i + 2])) }
        XCTAssertFalse(bottom.isEmpty)
        // Every bottom corner sits 0.5 mm inside the plinth's outline; the outline itself starts 0.5 mm up.
        for p in bottom {
            XCTAssertEqual(min(p.x - low.x, high.x - p.x), 0.5, accuracy: 1e-4)
            XCTAssertEqual(min(p.y - low.y, high.y - p.y), 0.5, accuracy: 1e-4)
        }
        XCTAssertEqual(low.x, -2, accuracy: 1e-5)
        XCTAssertEqual(result.contactAreaMM2, 13 * 13, accuracy: 1e-3)
        XCTAssertTrue(plinthChamferNote.contains("0.5 mm chamfer"))
        XCTAssertFalse(elephantFootNote.contains("CAD"))
    }

    func testPlinthChecks() throws {
        XCTAssertNil(plinthSettingsProblem(PlinthSettings()))
        XCTAssertNotNil(plinthSettingsProblem(PlinthSettings(marginMM: 0.5)))
        XCTAssertNotNil(plinthSettingsProblem(PlinthSettings(thicknessMM: 25)))
        XCTAssertNotNil(plinthSettingsProblem(PlinthSettings(joinDepthMM: .nan)))
        let tall = try box(SIMD3(180, 180, 50))
        XCTAssertThrowsError(try tall.plinthCopy(PlinthSettings(shape: .rectangular, marginMM: 30))) { error in
            guard case .exceedsBuildVolume = error as? MeshFitError else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try box(SIMD3(10, 10, 1)).plinthCopy(PlinthSettings(joinDepthMM: 0.5)))
    }

    // MARK: Wall thickness

    func testSlabThicknessIsMeasured() throws {
        let slab = try box(SIMD3(40, 40, 1))
        let report = try XCTUnwrap(analyzeWallThickness(slab, maximumSamples: 4000))
        XCTAssertEqual(report.sampleCount, 4000)
        XCTAssertGreaterThan(report.measuredFraction, 0.99)
        XCTAssertEqual(try XCTUnwrap(report.medianMM), 1, accuracy: 0.01)
        // Top and bottom faces are 3,200 of the 3,360 mm² of surface.
        XCTAssertEqual(report.fractionUnder2MM, 3200.0 / 3360, accuracy: 0.02)
        XCTAssertTrue(report.smallFeatures.isEmpty, "\(report.smallFeatures)")
        XCTAssertEqual(report.bands.count, 6)
        XCTAssertEqual(report.bands.reduce(0) { $0 + $1.fraction }, 1, accuracy: 1e-9)
        XCTAssertFalse(report.thinSpots.isEmpty)
    }

    func testHollowBoxWallsOfOneAndTwoMillimetres() throws {
        for wall: Float in [1, 2] {
            let report = try XCTUnwrap(analyzeWallThickness(try hollowBox(wall: wall), maximumSamples: 1200))
            XCTAssertGreaterThan(report.measuredFraction, 0.99)
            XCTAssertEqual(try XCTUnwrap(report.medianMM), wall, accuracy: 0.01)
            XCTAssertEqual(try XCTUnwrap(report.percentile5MM), wall, accuracy: 0.05)
            XCTAssertTrue(report.smallFeatures.isEmpty)
            let summary = wallThicknessSummary(report)
            if wall == 2 {
                XCTAssertLessThan(report.fractionUnder1MM, 0.01)
            } else {
                // Outside faces within 1 mm of an edge measure along the wall instead: about a tenth of the surface.
                XCTAssertGreaterThan(report.fractionUnder2MM, 0.85)
                XCTAssertFalse(summary.isClear)
                XCTAssertTrue(summary.line.contains("under 2 mm"), summary.line)
            }
        }
        let thick = try XCTUnwrap(analyzeWallThickness(try hollowBox(wall: 4), maximumSamples: 800))
        let summary = wallThicknessSummary(thick)
        XCTAssertEqual(summary.line, "Wall thickness: no walls under 2 mm found")
        XCTAssertTrue(summary.isClear)
    }

    func testPinIsReportedAsSmallFeature() throws {
        let pin = try box(SIMD3(2, 2, 12), at: SIMD3(5, 5, 0))
        let report = try XCTUnwrap(analyzeWallThickness(pin, maximumSamples: 2000))
        let feature = try XCTUnwrap(report.smallFeatures.first)
        XCTAssertEqual(feature.thinnestMM, 2, accuracy: 0.01)
        XCTAssertEqual(feature.widthMM, 2, accuracy: 0.05)
        XCTAssertTrue(wallThicknessSummary(report).details.contains { $0.hasPrefix("Small feature") })
    }

    func testThicknessIsDeterministicAndCancellable() throws {
        let ball = try sphere(radius: 10, centre: SIMD3(3, 4, 10))
        let first = analyzeWallThickness(ball, maximumSamples: 1200)
        XCTAssertNotNil(first)
        XCTAssertEqual(analyzeWallThickness(ball, maximumSamples: 1200), first)
        XCTAssertEqual(try XCTUnwrap(first?.medianMM), 20, accuracy: 1)
        XCTAssertNil(analyzeWallThickness(ball, maximumSamples: 1200, isCancelled: { true }))
        var steps: [Double] = []
        _ = analyzeWallThickness(ball, maximumSamples: 400, progress: { steps.append($0) })
        XCTAssertEqual(steps.first, 0)
        XCTAssertEqual(steps.last, 1)
    }

    func testOpenMeshReportsUnmeasuredSurface() throws {
        // Only a box's bottom face: every inward ray escapes.
        let open = try mesh(Array(boxTriangles(.zero, SIMD3(40, 40, 1)).prefix(6)))
        let report = try XCTUnwrap(analyzeWallThickness(open, maximumSamples: 500))
        XCTAssertEqual(report.measuredCount, 0)
        XCTAssertEqual(wallThicknessSummary(report).line, "Wall thickness: couldn’t measure most of the surface")
    }

    func testRayIndexFindsNearestHit() throws {
        let slab = try box(SIMD3(10, 10, 2))
        let index = try XCTUnwrap(TriangleRayIndex(slab))
        let hit = try XCTUnwrap(index.firstHit(from: SIMD3(5, 5, 10), along: SIMD3(0, 0, -1)))
        XCTAssertEqual(hit.distance, 8, accuracy: 1e-5)
        XCTAssertEqual(hit.normal, SIMD3(0, 0, 1))
        XCTAssertNil(index.firstHit(from: SIMD3(50, 5, 10), along: SIMD3(0, 0, -1)))
    }

    /// An axis-aligned ray lying exactly in a box face's plane (here x = 0 and x = 10, and y = 10) used to compute
    /// 0 × ∞ in the slab test and drop that box, missing the hit along the edge.
    func testRayIndexKeepsRaysInABoxFacePlane() throws {
        let slab = try box(SIMD3(10, 10, 2))
        let index = try XCTUnwrap(TriangleRayIndex(slab))
        for origin in [SIMD3<Float>(10, 5, 10), SIMD3(0, 5, 10), SIMD3(5, 10, 10), SIMD3(10, 10, 10)] {
            let hit = try XCTUnwrap(index.firstHit(from: origin, along: SIMD3(0, 0, -1)), "\(origin)")
            XCTAssertEqual(hit.distance, 8, accuracy: 1e-5)
            XCTAssertEqual(hit.normal, SIMD3(0, 0, 1))
        }
        // Along X, in the plane y = 0 and the plane z = 2.
        XCTAssertEqual(try XCTUnwrap(index.firstHit(from: SIMD3(-5, 0, 1), along: SIMD3(1, 0, 0))).distance, 5, accuracy: 1e-5)
        XCTAssertEqual(try XCTUnwrap(index.firstHit(from: SIMD3(-5, 4, 2), along: SIMD3(1, 0, 0))).distance, 5, accuracy: 1e-5)
        // Negative zero components behave the same.
        XCTAssertEqual(try XCTUnwrap(index.firstHit(from: SIMD3(10, 5, 10), along: SIMD3(-0.0, -0.0, -1))).distance, 8, accuracy: 1e-5)
        // Just outside the plane still misses, as before.
        XCTAssertNil(index.firstHit(from: SIMD3(10.001, 5, 10), along: SIMD3(0, 0, -1)))
        XCTAssertNil(index.firstHit(from: SIMD3(5, -0.001, 10), along: SIMD3(0, 0, -1)))
        // So every wall-thickness sample on a box is measured, including those on its edges.
        let report = try XCTUnwrap(analyzeWallThickness(try box(SIMD3(40, 40, 20)), maximumSamples: 2_000))
        XCTAssertEqual(report.measuredCount, report.sampleCount)
        XCTAssertEqual(report.thinnestMM, 20)
    }

    func testBandLabels() {
        XCTAssertEqual(wallThicknessBandLabel(ThicknessBand(lowerMM: 1, upperMM: 1.5, fraction: 0.034)), "1.0–1.5 mm · 3%")
        XCTAssertEqual(wallThicknessBandLabel(ThicknessBand(lowerMM: 3, upperMM: nil, fraction: 0.004)), "3.0 mm or more · under 1%")
        XCTAssertEqual(percentLabel(0), "0%")
    }

    // MARK: Inspector helpers

    func testEditAvailability() {
        let stl = LocalModel(name: "Owl", filePath: "/tmp/owl.stl")
        for tool in [MeshFitTool.scale, .flatBase, .plinth] { XCTAssertNil(meshFitEditBlockedReason(stl, tool: tool)) }
        let obj = LocalModel(name: "Owl", filePath: "/tmp/owl.obj")
        XCTAssertEqual(meshFitEditBlockedReason(obj, tool: .flatBase),
                       "Scaling and bases work on an STL copy. Use Save STL Copy below, then select the copy.")
        XCTAssertEqual(meshFitEditBlockedReason(LocalModel(name: "x", filePath: "/tmp/x.step"), tool: .scale), "Available for STL files.")
        var prepared = stl
        prepared.printRecipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "Owl", intent: PartIntent(), orientation: .xUp,
                                                   materialID: nil, created: Date())
        XCTAssertNotNil(meshFitEditBlockedReason(prepared, tool: .scale))
        // A prepared copy can still get a base; the copy is a plain model.
        XCTAssertNil(meshFitEditBlockedReason(prepared, tool: .flatBase))
    }

    func testLabels() {
        XCTAssertEqual(meshFitHeightText(0.65000004), "0.65")
        XCTAssertEqual(meshFitHeightText(1), "1")
        XCTAssertEqual(meshFitAreaLabel(1234.4), "1,234 mm²")
        XCTAssertEqual(meshFitSizeLabel(SIMD3(10, 20.25, 3)), "10.0 × 20.2 × 3.0 mm")
        XCTAssertTrue(isPersonalisationTempFolderName("\(meshFitTempFolderPrefix)\(UUID().uuidString)"))
    }
}
