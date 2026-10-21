import XCTest
import simd
@testable import SlantStudio

final class MeshHealthTests: XCTestCase {
    private func faces(_ points: [SIMD3<Float>], _ faces: [(Int, Int, Int)]) -> [SIMD3<Float>] {
        faces.flatMap { [points[$0.0], points[$0.1], points[$0.2]] }
    }

    /// An outward-wound cube made of 12 triangles.
    private func cubeTriangles(at origin: SIMD3<Float> = .zero, size: Float = 10) -> [SIMD3<Float>] {
        let p: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(1, 1, 0), SIMD3(0, 1, 0),
            SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(1, 1, 1), SIMD3(0, 1, 1)
        ].map { origin + $0 * size }
        return faces(p, [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)
        ])
    }

    private func mesh(_ corners: [SIMD3<Float>]) -> STLMesh {
        let low = corners.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
        let high = corners.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
        return STLMesh(vertices: corners.flatMap { [$0.x, $0.y, $0.z] }, minimum: low, maximum: high)
    }

    private func report(_ corners: [SIMD3<Float>]) throws -> MeshHealthReport {
        try XCTUnwrap(analyzeMeshHealth(mesh(corners)))
    }

    func testClosedCubeIsCleanSinglePart() throws {
        let r = try report(cubeTriangles())
        XCTAssertEqual(r.triangleCount, 12)
        XCTAssertEqual(r.vertexCount, 8)
        XCTAssertEqual(r.openEdges, 0)
        XCTAssertEqual(r.nonManifoldEdges, 0)
        XCTAssertEqual(r.flippedEdges, 0)
        XCTAssertEqual(r.degenerateTriangles, 0)
        XCTAssertEqual(r.shells, 1)
        XCTAssertTrue(r.isClosed)
        XCTAssertFalse(r.isInsideOut)
        XCTAssertEqual(r.signedVolume, 1000, accuracy: 1e-6)
        let summary = meshHealthSummary(r)
        XCTAssertEqual(summary.title, "Closed, 1 part")
        XCTAssertTrue(summary.isClean)
    }

    func testMissingTriangleLeavesThreeOpenEdges() throws {
        let r = try report(Array(cubeTriangles().dropLast(3)))
        XCTAssertEqual(r.openEdges, 3)
        XCTAssertFalse(r.isClosed)
        XCTAssertEqual(r.shells, 1)
        let summary = meshHealthSummary(r)
        XCTAssertEqual(summary.title, "Not closed, 1 part")
        XCTAssertTrue(summary.details[0].hasPrefix("3 open edges"))
        XCTAssertTrue(summary.details[0].contains("Slant may reject or misprint this"))
    }

    func testTwoDisjointCubesAreTwoClosedParts() throws {
        let r = try report(cubeTriangles() + cubeTriangles(at: SIMD3(20, 0, 0)))
        XCTAssertTrue(r.isClosed)
        XCTAssertEqual(r.shells, 2)
        let summary = meshHealthSummary(r)
        XCTAssertEqual(summary.title, "Closed, 2 parts")
        XCTAssertEqual(summary.details.count, 1)
        XCTAssertTrue(summary.details[0].contains("each prints as a loose piece"))
    }

    func testFlippedTriangleIsReportedAsInconsistentOrientation() throws {
        var corners = cubeTriangles()
        corners.swapAt(1, 2)
        let r = try report(corners)
        XCTAssertTrue(r.isClosed, "flipping a triangle does not open the surface")
        XCTAssertEqual(r.flippedEdges, 3)
        XCTAssertFalse(r.isConsistentlyOriented)
        XCTAssertFalse(r.isInsideOut)
        XCTAssertTrue(meshHealthSummary(r).details.contains { $0.contains("some faces are flipped") })
    }

    func testFullyInvertedCubeIsInsideOut() throws {
        var corners = cubeTriangles()
        for t in stride(from: 0, to: corners.count, by: 3) { corners.swapAt(t + 1, t + 2) }
        let r = try report(corners)
        XCTAssertTrue(r.isClosed)
        XCTAssertTrue(r.isConsistentlyOriented)
        XCTAssertTrue(r.isInsideOut)
        XCTAssertTrue(meshHealthSummary(r).details.contains { $0.contains("point inward") })
    }

    func testThreeTrianglesOnOneEdgeAreNonManifold() {
        let a = SIMD3<Float>(0, 0, 0), b = SIMD3<Float>(0, 0, 10)
        let corners = [a, b, SIMD3(10, 0, 0), b, a, SIMD3(0, 10, 0), a, b, SIMD3(-10, -10, 0)]
        let r = analyzeMeshHealth(mesh(corners))!
        XCTAssertEqual(r.nonManifoldEdges, 1)
        XCTAssertEqual(r.openEdges, 6)
        XCTAssertFalse(r.isClosed)
        XCTAssertTrue(meshHealthSummary(r).details.contains { $0.hasPrefix("1 edge is shared by more than two faces") })
    }

    func testDegenerateTrianglesAreCountedWithoutBreakingTopology() throws {
        // A repeated-corner triangle on a cube edge must not turn that edge non-manifold.
        let cube = cubeTriangles()
        let repeated = try report(cube + [cube[0], cube[0], cube[1]])
        XCTAssertEqual(repeated.degenerateTriangles, 1)
        XCTAssertTrue(repeated.isClosed)
        XCTAssertEqual(repeated.shells, 1)
        // A collinear sliver with three distinct corners is zero-area too.
        let sliver = try report(cube + [SIMD3(0, 0, 0), SIMD3(5, 0, 0), SIMD3(10, 0, 0)])
        XCTAssertEqual(sliver.degenerateTriangles, 1)
        let summary = meshHealthSummary(repeated)
        XCTAssertEqual(summary.title, "Closed, 1 part")
        XCTAssertTrue(summary.details.contains { $0.hasPrefix("1 zero-area triangle") })
    }

    func testEmptyAndSingleTriangleMeshes() throws {
        let empty = try XCTUnwrap(analyzeMeshHealth(STLMesh(vertices: [], minimum: .zero, maximum: .zero)))
        XCTAssertEqual(empty.triangleCount, 0)
        XCTAssertFalse(empty.isClosed)
        XCTAssertEqual(meshHealthSummary(empty).title, "No triangles to check")

        let single = try report([SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)])
        XCTAssertEqual(single.openEdges, 3)
        XCTAssertEqual(single.shells, 1)
        XCTAssertEqual(meshHealthSummary(single).title, "Not closed, 1 part")
    }

    func testNegativeZeroWeldsWithPositiveZero() throws {
        var corners = cubeTriangles()
        for i in corners.indices where corners[i].x == 0 { corners[i].x = -0.0 }
        XCTAssertTrue(try report(corners).isClosed)
    }

    func testCancellationReturnsNil() {
        XCTAssertNil(analyzeMeshHealth(mesh(cubeTriangles()), isCancelled: { true }))
    }

    /// Matches the directed-edge acceptance in `reinforcementSolid()` for every fixture.
    func testClosedAndOrientedAgreesWithReinforcementEdgeCheck() throws {
        var flipped = cubeTriangles()
        flipped.swapAt(1, 2)
        let fixtures: [[SIMD3<Float>]] = [cubeTriangles(), Array(cubeTriangles().dropLast(3)), flipped,
                                          cubeTriangles() + cubeTriangles(at: SIMD3(20, 0, 0))]
        for corners in fixtures {
            let r = try report(corners)
            let accepted: Bool
            do { _ = try mesh(corners).reinforcementSolid(); accepted = true } catch { accepted = false }
            XCTAssertEqual(r.isClosed && r.isConsistentlyOriented && r.degenerateTriangles == 0 && !r.isInsideOut, accepted)
        }
    }

    func testResultIsIndependentOfTriangleOrder() throws {
        // A grid of many small cubes, analysed forwards and with triangles reversed.
        var corners: [SIMD3<Float>] = []
        for x in 0..<6 { for y in 0..<6 { corners += cubeTriangles(at: SIMD3(Float(x) * 3, Float(y) * 3, 0), size: 2) } }
        var reversed: [SIMD3<Float>] = []
        for t in stride(from: corners.count - 3, through: 0, by: -3) { reversed += corners[t..<(t + 3)] }
        let forward = try report(corners)
        let backward = try report(reversed)
        XCTAssertEqual(forward.shells, 36)
        XCTAssertEqual(forward.openEdges, backward.openEdges)
        XCTAssertEqual(forward.shells, backward.shells)
        XCTAssertEqual(forward.flippedEdges, backward.flippedEdges)
        XCTAssertEqual(forward, try report(corners), "repeat runs give identical reports")
    }

    func testLargeMeshTiming() throws {
        // Opt-in: SLANT_MESH_TIMING=1 swift test --filter MeshHealthTests/testLargeMeshTiming
        guard ProcessInfo.processInfo.environment["SLANT_MESH_TIMING"] == "1" else { throw XCTSkip("Set SLANT_MESH_TIMING=1 to time 500,000 triangles.") }
        var corners: [SIMD3<Float>] = []
        corners.reserveCapacity(1_500_000)
        var index = 0
        while corners.count < 1_500_000 {
            let x = Float(index % 200), y = Float((index / 200) % 200), z = Float(index / 40_000)
            corners += cubeTriangles(at: SIMD3(x * 3, y * 3, z * 3), size: 2)
            index += 1
        }
        corners.removeLast(corners.count - 1_500_000)
        let big = mesh(corners)
        XCTAssertEqual(big.triangleCount, 500_000)
        let start = Date()
        let r = try XCTUnwrap(analyzeMeshHealth(big))
        let seconds = Date().timeIntervalSince(start)
        print("Mesh health for 500,000 triangles: \(String(format: "%.2f", seconds)) s, \(r.shells) shells")
        let thumbStart = Date()
        let rgba = try XCTUnwrap(renderThumbnailRGBA(big, size: ModelThumbnails.pixelSize))
        print("Thumbnail for 500,000 triangles: \(String(format: "%.2f", Date().timeIntervalSince(thumbStart))) s, \(rgba.count) bytes")
    }
}
