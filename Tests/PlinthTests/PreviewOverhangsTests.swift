import XCTest
import simd
@testable import Plinth

/// Show Overhangs (PreviewOverhangs.swift): which triangles the preview tints, and that the tint agrees with the 50°
/// figure Plinth already shows.
final class PreviewOverhangsTests: XCTestCase {
    // MARK: Fixtures

    private func mesh(_ triangles: [[SIMD3<Float>]]) throws -> STLMesh {
        try STLMesh.validated(triangles.flatMap { $0.flatMap { [$0.x, $0.y, $0.z] } })
    }

    /// An upward-facing triangle at z = 0, so other faces sit above the bed.
    private let base: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(10, 0, 0), SIMD3(0, 10, 0)]

    /// A 10 mm triangle at `degrees` from vertical, facing down and out along +X, its lowest corner at `origin`.
    private func face(degrees: Float, at origin: SIMD3<Float>) -> [SIMD3<Float>] {
        let a = degrees * .pi / 180
        let along = SIMD3<Float>(0, 1, 0) * 10
        let up = SIMD3<Float>(sin(a), 0, cos(a)) * 10
        return [origin, origin + along, origin + up]
    }

    private func normalZ(_ t: [SIMD3<Float>]) -> Float { simd_normalize(simd_cross(t[1] - t[0], t[2] - t[0])).z }

    private func assertMatchesFigure(_ mesh: STLMesh, file: StaticString = #filePath, line: UInt = #line) throws {
        let mask = try XCTUnwrap(overhangTriangleMask(mesh), file: file, line: line)
        XCTAssertEqual(mask.overhangs.count, mesh.triangleCount, file: file, line: line)
        XCTAssertEqual(mask.share, overhangShare(mesh, limitDegrees: Double(slantOverhangLimitDegrees)), file: file, line: line)
    }

    // MARK: Which triangles

    func testFaceAnglesSanity() {
        XCTAssertEqual(normalZ(face(degrees: 60, at: .zero)), -sin(60 * .pi / 180), accuracy: 1e-5)
        XCTAssertEqual(normalZ(face(degrees: 45, at: .zero)), -sin(45 * .pi / 180), accuracy: 1e-5)
    }

    func testCubeOnTheBedHasNoOverhangs() throws {
        let cube = try MeshRepairTests.cube(size: 20)
        let mask = try XCTUnwrap(overhangTriangleMask(cube))
        XCTAssertEqual(mask.overhangCount, 0, "The bottom rests on the bed; the sides are vertical")
        try assertMatchesFigure(cube)
    }

    func testAFloatingCubesBottomIsTinted() throws {
        let points = MeshRepairTests.cubePoints(size: 10) + MeshRepairTests.cubePoints(size: 10, offset: SIMD3(20, 0, 15))
        let triangles = MeshRepairTests.cubeTriangles + MeshRepairTests.cubeTriangles.map { $0 &+ 8 }
        let pair = try MeshRepairTests.mesh(points, triangles)
        let mask = try XCTUnwrap(overhangTriangleMask(pair))
        // Triangles 0 and 1 are the bottom (z = 0) of each cube.
        XCTAssertEqual(mask.overhangs.enumerated().filter(\.element).map(\.offset), [12, 13])
        XCTAssertEqual(mask.share.overhangAreaMM2, 100, accuracy: 1e-9)
        try assertMatchesFigure(pair)
    }

    func testA60DegreeUndersideIsTintedAndA45DegreeOneIsNot() throws {
        let sixty = face(degrees: 60, at: SIMD3(0, 0, 5))
        let fortyFive = face(degrees: 45, at: SIMD3(20, 0, 5))
        let fifty = face(degrees: 49, at: SIMD3(40, 0, 5))
        let mesh = try mesh([base, sixty, fortyFive, fifty])
        let mask = try XCTUnwrap(overhangTriangleMask(mesh))
        XCTAssertEqual(mask.overhangs, [false, true, false, false])
        try assertMatchesFigure(mesh)
    }

    func testAFaceOnTheBedIsNotAnOverhangButTheSameFaceRaisedIs() throws {
        let down: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(0, 10, 0), SIMD3(10, 0, 0)]
        XCTAssertLessThan(normalZ(down), -0.99)
        let raisedBy: (Float) -> [SIMD3<Float>] = { z in down.map { $0 + SIMD3(0, 0, z) } }
        let onBed = try mesh([down, face(degrees: 0, at: SIMD3(0, 0, 0))])
        XCTAssertEqual(try XCTUnwrap(overhangTriangleMask(onBed)).overhangs, [false, false])
        let lifted = try mesh([base, raisedBy(3)])
        XCTAssertEqual(try XCTUnwrap(overhangTriangleMask(lifted)).overhangs, [false, true])
        try assertMatchesFigure(onBed)
        try assertMatchesFigure(lifted)
    }

    func testDegenerateTrianglesAreNeverTintedOrCounted() throws {
        let line: [SIMD3<Float>] = [SIMD3(0, 0, 5), SIMD3(5, 0, 5), SIMD3(10, 0, 5)]
        let point: [SIMD3<Float>] = [SIMD3(3, 3, 3), SIMD3(3, 3, 3), SIMD3(3, 3, 3)]
        let mesh = try mesh([base, line, point, face(degrees: 80, at: SIMD3(0, 0, 4))])
        let mask = try XCTUnwrap(overhangTriangleMask(mesh))
        XCTAssertEqual(mask.overhangs, [false, false, false, true])
        XCTAssertEqual(mask.share.surfaceAreaMM2, overhangShare(mesh, limitDegrees: 50).surfaceAreaMM2)
        try assertMatchesFigure(mesh)
    }

    func testOnlyDownwardFacesEverTint() throws {
        let mesh = try mesh([base, face(degrees: 89, at: SIMD3(0, 0, 4))])
        XCTAssertEqual(try XCTUnwrap(overhangTriangleMask(mesh)).overhangs, [false, true])
        // The same face turned to face up never counts.
        let up = face(degrees: 89, at: SIMD3(0, 0, 4))
        let flipped = try self.mesh([base, [up[0], up[2], up[1]]])
        XCTAssertEqual(try XCTUnwrap(overhangTriangleMask(flipped)).overhangs, [false, false])
    }

    func testASphereMatchesTheFigureExactly() throws {
        let sphere = try MeshRepairTests.sphere(levels: 3)
        let mask = try XCTUnwrap(overhangTriangleMask(sphere))
        XCTAssertGreaterThan(mask.overhangCount, 0)
        XCTAssertLessThan(mask.overhangCount, sphere.triangleCount)
        try assertMatchesFigure(sphere)
        // Turned on its side, the same rule still matches the figure.
        try assertMatchesFigure(sphere.oriented(.xUp))
    }

    // MARK: Print-ready copies

    func testNarrowCeilingsAreLeftOutOnlyWhenAsked() throws {
        // A 0.2 mm × 10 mm downward strip at z = 5: an internal walls' slot ceiling.
        let a = SIMD3<Float>(0, 0, 5), b = SIMD3<Float>(10, 0, 5), c = SIMD3<Float>(10, 0.2, 5), d = SIMD3<Float>(0, 0.2, 5)
        let strip = [[a, c, b], [a, d, c]]
        XCTAssertLessThan(normalZ(strip[0]), -0.99)
        let mesh = try mesh([base] + strip)
        XCTAssertEqual(try XCTUnwrap(overhangTriangleMask(mesh)).overhangs, [false, true, true])
        let ignoring = try XCTUnwrap(overhangTriangleMask(mesh, ignoringNarrowCeilings: true))
        XCTAssertEqual(ignoring.overhangs, [false, false, false])
        XCTAssertEqual(ignoring.share.overhangAreaMM2, 0)
        // A wide downward face is not a ceiling and stays tinted.
        let wide = try self.mesh([base, face(degrees: 90, at: SIMD3(0, 0, 5))])
        XCTAssertEqual(try XCTUnwrap(overhangTriangleMask(wide, ignoringNarrowCeilings: true)).overhangs, [false, true])
    }

    // MARK: Cancellation, size and the preview's buffers

    func testCancelledWorkReturnsNothing() throws {
        let sphere = try MeshRepairTests.sphere(levels: 2)
        XCTAssertNil(overhangTriangleMask(sphere, isCancelled: { true }))
        XCTAssertNil(previewOverhangHighlight(sphere, ignoringNarrowCeilings: false, isCancelled: { true }))
    }

    func testHighlightPartitionsEveryTriangleOnce() throws {
        let sphere = try MeshRepairTests.sphere(levels: 2)
        let highlight = try XCTUnwrap(previewOverhangHighlight(sphere, ignoringNarrowCeilings: false))
        XCTAssertEqual(highlight.plainTriangles + highlight.overhangTriangles, sphere.triangleCount)
        func indices(_ data: Data) -> [UInt32] { data.withUnsafeBytes { Array($0.bindMemory(to: UInt32.self)) } }
        let plain = indices(highlight.plainIndices), tinted = indices(highlight.overhangIndices)
        XCTAssertEqual(plain.count, highlight.plainTriangles * 3)
        XCTAssertEqual(tinted.count, highlight.overhangTriangles * 3)
        XCTAssertEqual((plain + tinted).sorted(), (0..<UInt32(sphere.triangleCount * 3)).map { $0 })
        let mask = try XCTUnwrap(overhangTriangleMask(sphere))
        for t in stride(from: 0, to: tinted.count, by: 3) {
            XCTAssertTrue(mask.overhangs[Int(tinted[t] / 3)])
            XCTAssertEqual(tinted[t + 1], tinted[t] + 1)
            XCTAssertEqual(tinted[t + 2], tinted[t] + 2)
        }
        XCTAssertEqual(highlight.share, mask.share)
    }

    /// The library's 500,000-triangle limit: done in one pass, matching the figure.
    func testALibrarySizedMeshMatchesTheFigure() throws {
        var vertices: [Float] = []
        vertices.reserveCapacity(STLMesh.maximumTriangles * 9)
        for t in 0..<STLMesh.maximumTriangles {
            let x = Float(t % 1000), y = Float(t / 1000), z = Float(t % 7)
            // Alternating up, down-steep and down-shallow faces.
            switch t % 3 {
            case 0: vertices += [x, y, z, x + 1, y, z, x, y + 1, z]
            case 1: vertices += [x, y, z + 1, x, y + 1, z + 1, x + 1, y, z + 1]
            default: vertices += [x, y, z, x, y + 1, z, x + 0.5, y, z + 1]
            }
        }
        let big = try STLMesh.validated(vertices)
        XCTAssertEqual(big.triangleCount, STLMesh.maximumTriangles)
        try assertMatchesFigure(big)
    }

    // MARK: Wording

    func testCaptionAndAccessibilityValue() {
        let share = OverhangShare(overhangAreaMM2: 12, surfaceAreaMM2: 100)
        let none = OverhangShare(overhangAreaMM2: 0, surfaceAreaMM2: 100)
        XCTAssertEqual(previewOverhangCaption(share),
                       "Orange: 12% of the surface faces down more steeply than Slant’s 50° limit, where Slant adds supports. Shown as the file is oriented, which is how Slant prints it.")
        XCTAssertTrue(previewOverhangCaption(none).hasPrefix("No faces point down"))
        XCTAssertTrue(previewOverhangCaption(nil).hasPrefix("Finding overhangs"))
        for text in [previewOverhangCaption(share), previewOverhangCaption(none), previewOverhangCaption(nil)] {
            XCTAssertTrue(text.contains("Slant"), "Names Slant, so it never claims to describe 3DAPI's printing")
            for banned in ["will print", "guarantee", "strong", "fail"] { XCTAssertFalse(text.lowercased().contains(banned)) }
        }
        XCTAssertEqual(previewOverhangAccessibilityValue(isOn: false, share: share), "Off")
        XCTAssertEqual(previewOverhangAccessibilityValue(isOn: true, share: share), "On, 12% of the surface tinted")
        XCTAssertEqual(previewOverhangAccessibilityValue(isOn: true, share: none), "On, no overhangs past 50°")
        XCTAssertEqual(previewOverhangAccessibilityValue(isOn: true, share: nil), "On, finding overhangs")
        XCTAssertEqual(previewShowOverhangsTitle, "Show Overhangs")
    }
}
