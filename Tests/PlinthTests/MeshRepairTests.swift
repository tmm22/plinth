import XCTest
import simd
@testable import Plinth

final class MeshRepairTests: XCTestCase {
    // MARK: Fixtures

    /// Outward-facing unit cube corners: bit 0 is x, bit 1 is y, bit 2 is z.
    static let cubeTriangles: [SIMD3<Int32>] = [
        SIMD3(0, 2, 3), SIMD3(0, 3, 1), SIMD3(4, 5, 7), SIMD3(4, 7, 6),
        SIMD3(0, 1, 5), SIMD3(0, 5, 4), SIMD3(2, 6, 7), SIMD3(2, 7, 3),
        SIMD3(0, 4, 6), SIMD3(0, 6, 2), SIMD3(1, 3, 7), SIMD3(1, 7, 5)
    ]

    static func cubePoints(size: Float = 1, offset: SIMD3<Float> = .zero) -> [SIMD3<Float>] {
        (0..<8).map { i in SIMD3(Float(i & 1), Float((i >> 1) & 1), Float((i >> 2) & 1)) * size + offset }
    }

    static func mesh(_ points: [SIMD3<Float>], _ triangles: [SIMD3<Int32>]) throws -> STLMesh {
        try STLMesh.validated(meshSoup(points: points, triangles: triangles))
    }

    static func cube(size: Float = 1, offset: SIMD3<Float> = .zero, triangles: [SIMD3<Int32>] = cubeTriangles) throws -> STLMesh {
        try mesh(cubePoints(size: size, offset: offset), triangles)
    }

    static func flipped(_ t: SIMD3<Int32>) -> SIMD3<Int32> { SIMD3(t.x, t.z, t.y) }

    /// An icosahedron subdivided `levels` times onto a sphere: closed, manifold and outward.
    static func sphere(levels: Int, radius: Float = 10) throws -> STLMesh {
        let t = Float((1 + 5.0.squareRoot()) / 2)
        var points: [SIMD3<Float>] = [
            SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0),
            SIMD3(0, -1, t), SIMD3(0, 1, t), SIMD3(0, -1, -t), SIMD3(0, 1, -t),
            SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1)
        ].map { simd_normalize($0) }
        var faces: [SIMD3<Int32>] = [
            SIMD3(0, 11, 5), SIMD3(0, 5, 1), SIMD3(0, 1, 7), SIMD3(0, 7, 10), SIMD3(0, 10, 11),
            SIMD3(1, 5, 9), SIMD3(5, 11, 4), SIMD3(11, 10, 2), SIMD3(10, 7, 6), SIMD3(7, 1, 8),
            SIMD3(3, 9, 4), SIMD3(3, 4, 2), SIMD3(3, 2, 6), SIMD3(3, 6, 8), SIMD3(3, 8, 9),
            SIMD3(4, 9, 5), SIMD3(2, 4, 11), SIMD3(6, 2, 10), SIMD3(8, 6, 7), SIMD3(9, 8, 1)
        ]
        for _ in 0..<levels {
            var midpoints: [UInt64: Int32] = [:]
            func midpoint(_ a: Int32, _ b: Int32) -> Int32 {
                let key = UInt64(UInt32(min(a, b))) << 32 | UInt64(UInt32(max(a, b)))
                if let id = midpoints[key] { return id }
                points.append(simd_normalize(points[Int(a)] + points[Int(b)]))
                midpoints[key] = Int32(points.count - 1)
                return Int32(points.count - 1)
            }
            var next: [SIMD3<Int32>] = []
            for f in faces {
                let ab = midpoint(f.x, f.y), bc = midpoint(f.y, f.z), ca = midpoint(f.z, f.x)
                next += [SIMD3(f.x, ab, ca), SIMD3(f.y, bc, ab), SIMD3(f.z, ca, bc), SIMD3(ab, bc, ca)]
            }
            faces = next
        }
        return try mesh(points.map { $0 * radius }, faces)
    }

    static func digest(_ data: Data) -> UInt64 {
        data.reduce(UInt64(0xcbf2_9ce4_8422_2325)) { ($0 ^ UInt64($1)) &* 0x100_0000_01b3 }
    }

    func health(_ mesh: STLMesh) -> MeshHealthReport { analyzeMeshHealth(mesh)! }

    // MARK: Repair

    func testCleanCubeIsUnchanged() throws {
        let result = try repairMesh(try Self.cube())
        XCTAssertFalse(result.summary.changed)
        XCTAssertTrue(result.summary.isSound)
        XCTAssertEqual(result.mesh.binarySTL(), try Self.cube().binarySTL())
    }

    func testWeldMergesNearDuplicates() throws {
        var vertices = try Self.cube().vertices
        // Nudge one corner of one triangle by a micron's fraction, opening three edges.
        vertices[0] += 1e-6
        let source = try STLMesh.validated(vertices)
        XCTAssertGreaterThan(health(source).openEdges, 0)
        let exact = try weldMeshCorners(source, tolerance: 0)
        XCTAssertEqual(exact.points.count, 9)
        XCTAssertEqual(exact.mergedPositions, 0)
        let welded = try weldMeshCorners(source, tolerance: 1e-5)
        XCTAssertEqual(welded.points.count, 8)
        XCTAssertEqual(welded.mergedPositions, 1)

        let result = try repairMesh(source)
        XCTAssertEqual(result.summary.weldedVertices, 1)
        XCTAssertTrue(result.summary.isSound)
        XCTAssertEqual(health(result.mesh).vertexCount, 8)
    }

    func testRepeatedCornerAndCollinearSliverAreRemovedWithoutOpeningSeams() throws {
        var points = Self.cubePoints()
        points.append(SIMD3(0.5, 0, 1)) // m = 8, on the top edge from 4 to 5
        var triangles = Self.cubeTriangles.filter { $0 != SIMD3(4, 5, 7) }
        // The top face meets the side at a T-junction, closed by a zero-area sliver.
        triangles += [SIMD3(4, 8, 7), SIMD3(8, 5, 7), SIMD3(4, 5, 8)]
        triangles.append(SIMD3(0, 0, 3)) // a repeated corner
        let source = try Self.mesh(points, triangles)
        XCTAssertEqual(health(source).degenerateTriangles, 2)

        let result = try repairMesh(source)
        XCTAssertEqual(result.summary.removedDegenerate, 2)
        XCTAssertEqual(result.summary.splitTriangles, 1)
        XCTAssertTrue(result.summary.isSound, "\(result.summary.after)")
        XCTAssertEqual(result.summary.after.signedVolume, 1, accuracy: 1e-5)
    }

    func testInconsistentWindingIsFixed() throws {
        var triangles = Self.cubeTriangles
        triangles[0] = Self.flipped(triangles[0])
        triangles[7] = Self.flipped(triangles[7])
        let source = try Self.cube(triangles: triangles)
        XCTAssertGreaterThan(health(source).flippedEdges, 0)

        let result = try repairMesh(source)
        XCTAssertEqual(result.summary.flippedTriangles, 2)
        XCTAssertTrue(result.summary.isSound)
        XCTAssertGreaterThan(result.summary.after.signedVolume, 0)
    }

    func testInsideOutCubeIsTurnedOutward() throws {
        let source = try Self.cube(triangles: Self.cubeTriangles.map(Self.flipped))
        XCTAssertTrue(health(source).isInsideOut)
        let result = try repairMesh(source)
        XCTAssertEqual(result.summary.invertedShells, 1)
        XCTAssertTrue(result.summary.isSound)
        XCTAssertEqual(result.summary.after.signedVolume, 1, accuracy: 1e-5)
    }

    func testCavityFacingInwardIsKept() throws {
        // A 10 mm box with a 4 mm cavity: the inner shell faces inward on purpose.
        let outer = Self.cubePoints(size: 10)
        let inner = Self.cubePoints(size: 4, offset: SIMD3(3, 3, 3))
        let triangles = Self.cubeTriangles + Self.cubeTriangles.map { Self.flipped($0) &+ 8 }
        let result = try repairMesh(try Self.mesh(outer + inner, triangles))
        XCTAssertFalse(result.summary.changed)
        XCTAssertEqual(result.summary.after.signedVolume, 1000 - 64, accuracy: 1e-3)
        XCTAssertTrue(result.summary.isSound)
    }

    func testInvertedHollowBoxComesOutWithItsCavityFacingInward() throws {
        // The hollow box above turned inside out as a whole: the outside faces in and the cavity faces out.
        let outer = Self.cubePoints(size: 10)
        let inner = Self.cubePoints(size: 4, offset: SIMD3(3, 3, 3))
        let triangles = Self.cubeTriangles.map(Self.flipped) + Self.cubeTriangles.map { $0 &+ 8 }
        let source = try Self.mesh(outer + inner, triangles)
        XCTAssertEqual(health(source).signedVolume, -(1000 - 64), accuracy: 1e-3)
        let result = try repairMesh(source)
        XCTAssertEqual(result.summary.invertedShells, 2)
        XCTAssertTrue(result.summary.isSound, "\(result.summary.after)")
        XCTAssertEqual(result.summary.after.signedVolume, 1000 - 64, accuracy: 1e-3)
        XCTAssertEqual(try repairMesh(source).mesh.binarySTL(), result.mesh.binarySTL())
    }

    func testOutwardPartInsideACorrectModelIsLeftAlone() throws {
        // A part embedded in a correct model faces outward too; it must not be turned into a cavity.
        let outer = Self.cubePoints(size: 10)
        let inner = Self.cubePoints(size: 4, offset: SIMD3(3, 3, 3))
        let source = try Self.mesh(outer + inner, Self.cubeTriangles + Self.cubeTriangles.map { $0 &+ 8 })
        let result = try repairMesh(source)
        XCTAssertFalse(result.summary.changed)
        XCTAssertEqual(result.summary.after.signedVolume, 1000 + 64, accuracy: 1e-3)
    }

    func testSliverBesideAFlippedNeighbourKeepsTheMeshClosed() throws {
        // The top face's diagonal 4–7 has a corner m on it, closed by a zero-area sliver (4, 7, m); the neighbour
        // across the diagonal is wound the wrong way, so the sliver's edge has no opposite-direction partner.
        var points = Self.cubePoints()
        points.append(SIMD3(0.5, 0.5, 1)) // m = 8
        var triangles = Self.cubeTriangles.filter { $0 != SIMD3(4, 5, 7) && $0 != SIMD3(4, 7, 6) }
        triangles += [Self.flipped(SIMD3(4, 5, 7)), SIMD3(4, 8, 6), SIMD3(8, 7, 6), SIMD3(4, 7, 8)]
        let source = try Self.mesh(points, triangles)
        let before = health(source)
        XCTAssertTrue(before.isClosed)
        XCTAssertEqual(before.degenerateTriangles, 1)
        XCTAssertGreaterThan(before.flippedEdges, 0)

        let result = try repairMesh(source)
        XCTAssertTrue(result.summary.after.isClosed, "\(result.summary.after)")
        XCTAssertEqual(result.summary.removedDegenerate, 1)
        XCTAssertEqual(result.summary.splitTriangles, 1)
        XCTAssertTrue(result.summary.isSound, "\(result.summary.after)")
        XCTAssertEqual(result.summary.after.signedVolume, 1, accuracy: 1e-5)
    }

    func testASoundModelIsNeverMadeWorse() {
        func report(open: Int = 0, degenerate: Int = 0) -> MeshHealthReport {
            MeshHealthReport(triangleCount: 12, vertexCount: 8, openEdges: open, nonManifoldEdges: 0, flippedEdges: 0,
                             degenerateTriangles: degenerate, shells: 1, signedVolume: 1)
        }
        let sound = report(), open = report(open: 3), sliver = report(degenerate: 1)
        XCTAssertTrue(meshToolMadeWorse(before: sound, after: open))
        XCTAssertTrue(meshToolMadeWorse(before: sound, after: sliver))
        XCTAssertFalse(meshToolMadeWorse(before: sound, after: sound))
        XCTAssertFalse(meshToolMadeWorse(before: open, after: sliver))
        XCTAssertTrue(MeshToolError.madeWorse.localizedDescription.contains("no copy was made"))
    }

    func testHoleCappingClosesCube() throws {
        // One triangle missing: a three-edge hole.
        let one = try repairMesh(try Self.cube(triangles: Array(Self.cubeTriangles.dropLast())))
        XCTAssertEqual(one.summary.filledHoles, 1)
        XCTAssertEqual(one.summary.addedTriangles, 1)
        XCTAssertTrue(one.summary.isSound)

        // A whole face missing: a four-edge hole, ear-clipped into two triangles.
        let source = try Self.cube(triangles: Array(Self.cubeTriangles.dropLast(2)))
        XCTAssertEqual(health(source).openEdges, 4)
        let face = try repairMesh(source)
        XCTAssertEqual(face.summary.filledHoles, 1)
        XCTAssertEqual(face.summary.addedTriangles, 2)
        XCTAssertTrue(face.summary.isSound)
        XCTAssertEqual(face.summary.after.signedVolume, 1, accuracy: 1e-5)
        XCTAssertEqual(face.mesh.triangleCount, 12)
    }

    func testLargeHoleIsReportedNotClaimed() throws {
        let source = try Self.cube(triangles: Array(Self.cubeTriangles.dropLast(2)))
        var options = MeshRepairOptions()
        options.maximumHoleEdges = 3
        let result = try repairMesh(source, options: options)
        XCTAssertEqual(result.summary.unfilledHoles, 1)
        XCTAssertEqual(result.summary.largestUnfilledHole, 4)
        XCTAssertFalse(result.summary.isSound)
        let lines = meshRepairSummaryLines(result.summary)
        XCTAssertTrue(lines.last!.contains("still needs work"))
        XCTAssertFalse(lines.joined().contains("closed and consistent"))
    }

    func testTinyShellsAreRemovedAndReported() throws {
        let big = Self.cubePoints(size: 10)
        let speck = Self.cubePoints(size: 0.1, offset: SIMD3(20, 0, 0))
        let stray: [SIMD3<Float>] = [SIMD3(30, 0, 0), SIMD3(31, 0, 0), SIMD3(30, 1, 0)]
        let triangles = Self.cubeTriangles + Self.cubeTriangles.map { $0 &+ 8 } + [SIMD3(16, 17, 18)]
        let result = try repairMesh(try Self.mesh(big + speck + stray, triangles))
        XCTAssertEqual(result.summary.filledHoles, 0)
        XCTAssertEqual(result.summary.unfilledHoles, 0)
        XCTAssertEqual(result.summary.removedShells.count, 2)
        XCTAssertEqual(result.summary.removedShells.map(\.triangles), [12, 1])
        XCTAssertEqual(result.summary.after.shells, 1)
        XCTAssertTrue(result.summary.isSound)
        XCTAssertTrue(meshRepairSummaryLines(result.summary).contains("Removed 2 loose fragments (13 triangles)."))
    }

    func testSecondPartOfSimilarSizeIsKept() throws {
        let triangles = Self.cubeTriangles + Self.cubeTriangles.map { $0 &+ 8 }
        let source = try Self.mesh(Self.cubePoints(size: 10) + Self.cubePoints(size: 5, offset: SIMD3(20, 0, 0)), triangles)
        let result = try repairMesh(source)
        XCTAssertTrue(result.summary.removedShells.isEmpty)
        XCTAssertEqual(result.summary.after.shells, 2)
    }

    func testFaceToFaceDuplicatesAreRemovedAsAnInternalWall() throws {
        // Two unit cubes sharing the x = 1 face: that face appears twice, facing opposite ways.
        let triangles = Self.cubeTriangles + Self.cubeTriangles.map { $0 &+ 8 }
        let source = try Self.mesh(Self.cubePoints() + Self.cubePoints(offset: SIMD3(1, 0, 0)), triangles)
        let result = try repairMesh(source)
        XCTAssertEqual(result.summary.removedDuplicates, 4)
        XCTAssertTrue(result.summary.isSound, "\(result.summary.after)")
        XCTAssertEqual(result.summary.after.signedVolume, 2, accuracy: 1e-5)

        // A same-way repeat keeps one copy.
        let repeated = try repairMesh(try Self.cube(triangles: Self.cubeTriangles + [Self.cubeTriangles[3]]))
        XCTAssertEqual(repeated.summary.removedDuplicates, 1)
        XCTAssertTrue(repeated.summary.isSound)
    }

    func testRepairIsCancellable() {
        XCTAssertThrowsError(try repairMesh(try Self.sphere(levels: 2), isCancelled: { true })) { error in
            XCTAssertEqual(error as? MeshToolError, .cancelled)
        }
    }

    // MARK: Simplify

    func testSimplifyingASphereKeepsItClosedNearTarget() throws {
        let source = try Self.sphere(levels: 3) // 1,280 triangles
        XCTAssertEqual(source.triangleCount, 1280)
        var options = MeshSimplifyOptions()
        options.targetTriangles = 600
        var reported: [Double] = []
        let result = try simplifyMesh(source, options: options, progress: { fraction, _ in reported.append(fraction) })
        XCTAssertTrue(result.reachedTarget)
        XCTAssertLessThanOrEqual(result.triangles, 600)
        XCTAssertGreaterThanOrEqual(result.triangles, 590)
        XCTAssertTrue(meshHealthIsSound(result.after), "\(result.after)")
        XCTAssertEqual(result.after.shells, 1)
        XCTAssertLessThan(result.estimatedMaximumDeviation, 1) // on a 10 mm radius
        XCTAssertGreaterThan(result.estimatedMaximumDeviation, 0)
        // Volume stays close to the original's.
        XCTAssertEqual(result.after.signedVolume, result.before.signedVolume, accuracy: result.before.signedVolume * 0.05)
        XCTAssertEqual(reported.last, 1)
        XCTAssertTrue(meshSimplifySummaryLines(result).first!.contains("1,280"))
    }

    func testSimplifyKeepsOpenBoundaryInPlace() throws {
        let sphere = try Self.sphere(levels: 3)
        let open = try STLMesh.validated(Array(sphere.vertices.dropLast(9)))
        var options = MeshSimplifyOptions()
        options.targetTriangles = 300
        let result = try simplifyMesh(open, options: options)
        XCTAssertEqual(result.after.openEdges, 3)
        XCTAssertEqual(result.lockedVertices, 3)
        XCTAssertLessThanOrEqual(result.triangles, 300)
        // The hole's corners are still where they were.
        let corners = (0..<3).map { SIMD3(sphere.vertices[sphere.vertices.count - 9 + 3 * $0],
                                          sphere.vertices[sphere.vertices.count - 8 + 3 * $0],
                                          sphere.vertices[sphere.vertices.count - 7 + 3 * $0]) }
        let output = stride(from: 0, to: result.mesh.vertices.count, by: 3).map {
            SIMD3(result.mesh.vertices[$0], result.mesh.vertices[$0 + 1], result.mesh.vertices[$0 + 2])
        }
        for corner in corners { XCTAssertTrue(output.contains(corner)) }
    }

    func testSimplifyUnderTargetChangesNothing() throws {
        let cube = try Self.cube()
        let result = try simplifyMesh(cube)
        XCTAssertFalse(result.changed)
        XCTAssertEqual(result.mesh.binarySTL(), cube.binarySTL())
        XCTAssertTrue(meshSimplifySummaryLines(result).first!.hasPrefix("Already at 12 triangles"))
    }

    func testSimplifyIsCancellable() {
        var options = MeshSimplifyOptions()
        options.targetTriangles = 100
        XCTAssertThrowsError(try simplifyMesh(try Self.sphere(levels: 3), options: options, isCancelled: { true })) { error in
            XCTAssertEqual(error as? MeshToolError, .cancelled)
        }
    }

    func testQuadricMinimiserFindsCornerOfThreePlanes() {
        let q = MeshQuadric(normal: SIMD3(1, 0, 0), offset: -2) + MeshQuadric(normal: SIMD3(0, 1, 0), offset: -3)
            + MeshQuadric(normal: SIMD3(0, 0, 1), offset: 1)
        let x = q.minimiser()!
        XCTAssertEqual(x.x, 2, accuracy: 1e-9)
        XCTAssertEqual(x.y, 3, accuracy: 1e-9)
        XCTAssertEqual(x.z, -1, accuracy: 1e-9)
        XCTAssertEqual(q.error(x), 0, accuracy: 1e-12)
        XCTAssertNil(MeshQuadric(normal: SIMD3(0, 0, 1), offset: 0).minimiser())
    }

    // MARK: Determinism

    /// Same input → same bytes. Also run under SWIFT_DETERMINISTIC_HASHING=1 and normal hashing and compare the
    /// printed digests across processes.
    func testToolsRunTwiceGiveIdenticalBytes() throws {
        // A messy input: flipped faces, a missing face, a nudged corner and a fragment.
        var triangles = try Self.sphere(levels: 3).vertices
        triangles.removeLast(18)
        triangles[9 * 5 + 1] += 1e-5
        for f in stride(from: 0, to: 9 * 40, by: 9 * 7) {
            let b = Array(triangles[(f + 3)..<(f + 6)])
            triangles.replaceSubrange((f + 3)..<(f + 6), with: triangles[(f + 6)..<(f + 9)])
            triangles.replaceSubrange((f + 6)..<(f + 9), with: b)
        }
        triangles += meshSoup(points: Self.cubePoints(size: 0.05, offset: SIMD3(30, 0, 0)), triangles: Self.cubeTriangles)
        let messy = try STLMesh.validated(triangles)

        let first = try repairMesh(messy), second = try repairMesh(messy)
        XCTAssertEqual(first.mesh.binarySTL(), second.mesh.binarySTL())
        XCTAssertEqual(first.summary, second.summary)
        XCTAssertTrue(first.summary.isSound, "\(first.summary.after)")

        var options = MeshSimplifyOptions()
        options.targetTriangles = 400
        let a = try simplifyMesh(first.mesh, options: options), b = try simplifyMesh(first.mesh, options: options)
        XCTAssertEqual(a.mesh.binarySTL(), b.mesh.binarySTL())
        XCTAssertTrue(meshHealthIsSound(a.after))
        print("MeshRepairTests digest repair=\(String(Self.digest(first.mesh.binarySTL()), radix: 16)) simplify=\(String(Self.digest(a.mesh.binarySTL()), radix: 16))")
    }

    /// Opt-in timing on a 327,680-triangle sphere (set MESH_TOOLS_BENCH=1); best run in release.
    func testLargeMeshTiming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MESH_TOOLS_BENCH"] == "1", "Set MESH_TOOLS_BENCH=1 to time the mesh tools.")
        let source = try Self.sphere(levels: 7, radius: 50)
        var start = Date()
        let repaired = try repairMesh(source)
        let repairSeconds = Date().timeIntervalSince(start)
        start = Date()
        let simplified = try simplifyMesh(repaired.mesh)
        let simplifySeconds = Date().timeIntervalSince(start)
        print(String(format: "MeshRepairTests timing: %d triangles, repair %.2f s, simplify to %d in %.2f s, deviation %.3f mm",
                     source.triangleCount, repairSeconds, simplified.triangles, simplifySeconds, simplified.estimatedMaximumDeviation))
        XCTAssertTrue(meshHealthIsSound(simplified.after))
        XCTAssertLessThanOrEqual(simplified.triangles, meshToolsReinforceTriangleLimit)
    }

    // MARK: Copy

    func testOutcomeLineOnlyClaimsSoundMeshes() {
        let sound = MeshHealthReport(triangleCount: 12, vertexCount: 8, openEdges: 0, nonManifoldEdges: 0, flippedEdges: 0,
                                     degenerateTriangles: 0, shells: 1, signedVolume: 1)
        XCTAssertEqual(meshRepairOutcomeLine(sound), "Mesh check: closed and consistent, 1 part.")
        let open = MeshHealthReport(triangleCount: 11, vertexCount: 8, openEdges: 3, nonManifoldEdges: 1, flippedEdges: 0,
                                    degenerateTriangles: 0, shells: 1, signedVolume: 1)
        XCTAssertEqual(meshRepairOutcomeLine(open), "Mesh check: still needs work — 3 open edges, 1 edge shared by more than two faces. Fix the rest in your CAD tool or a repair tool.")
        let inward = MeshHealthReport(triangleCount: 12, vertexCount: 8, openEdges: 0, nonManifoldEdges: 0, flippedEdges: 0,
                                      degenerateTriangles: 0, shells: 1, signedVolume: -1)
        XCTAssertFalse(meshHealthIsSound(inward))
    }
}

final class MeshToolsViewHelperTests: XCTestCase {
    func testCopyNames() {
        XCTAssertEqual(meshToolCopyName("Bracket", kind: .repair), "Bracket (repaired)")
        XCTAssertEqual(meshToolCopyName("Bracket (repaired)", kind: .simplify(target: 20_000)), "Bracket (repaired) (simplified)")
        XCTAssertEqual(meshToolCopyName("a/b:c", kind: .repair), "a-b-c (repaired)")
        XCTAssertEqual(meshToolCopyName("  ", kind: .repair), "Model (repaired)")
        XCTAssertEqual(meshToolCopyName(".hidden", kind: .repair), "Model .hidden (repaired)")
        let long = meshToolCopyName(String(repeating: "é", count: 300), kind: .simplify(target: 100))
        XCTAssertLessThanOrEqual(long.utf8.count + ".stl".utf8.count, 255)
    }

    func testTargetParsing() {
        XCTAssertEqual(meshSimplifyTarget("20,000"), 20_000)
        XCTAssertEqual(meshSimplifyTarget(" 20 000 "), 20_000)
        XCTAssertEqual(meshSimplifyTarget("20.000"), 20_000)
        XCTAssertNil(meshSimplifyTarget(""))
        XCTAssertNil(meshSimplifyTarget("2e4"))
        XCTAssertNil(meshSimplifyTarget("-5"))
        XCTAssertNil(meshSimplifyTarget("١٢٣")) // non-ASCII digits
        XCTAssertNil(meshSimplifyTarget("9999999999"))

        XCTAssertNil(meshSimplifyTargetProblem("20,000", currentTriangles: 300_000))
        XCTAssertEqual(meshSimplifyTargetProblem("abc", currentTriangles: 300_000), "Enter a whole number of triangles.")
        XCTAssertEqual(meshSimplifyTargetProblem("50", currentTriangles: 300_000), "Enter at least 100 triangles.")
        XCTAssertEqual(meshSimplifyTargetProblem("20,000", currentTriangles: 12_000), "Enter fewer than this model’s 12,000 triangles.")
        XCTAssertEqual(meshSimplifyTargetProblem("20,000", currentTriangles: 12), "This model is already very simple.")
    }

    func testStatusLineAndExplanation() {
        let sound = MeshHealthReport(triangleCount: 12, vertexCount: 8, openEdges: 0, nonManifoldEdges: 0, flippedEdges: 0,
                                     degenerateTriangles: 0, shells: 1, signedVolume: 1)
        XCTAssertEqual(meshToolsStatusLine(triangles: 12, report: sound), "12 triangles · closed and consistent")
        let open = MeshHealthReport(triangleCount: 11, vertexCount: 8, openEdges: 3, nonManifoldEdges: 0, flippedEdges: 0,
                                    degenerateTriangles: 0, shells: 1, signedVolume: 1)
        XCTAssertEqual(meshToolsStatusLine(triangles: 11, report: open), "11 triangles · not closed, 1 part")
        XCTAssertTrue(meshSimplifyExplanation.contains("20,000"))
    }

    func testTempFoldersAreCleanedAtLaunch() {
        XCTAssertTrue(isPersonalisationTempFolderName("\(meshToolsTempFolderPrefix)\(UUID().uuidString)"))
        XCTAssertFalse(isPersonalisationTempFolderName("\(meshToolsTempFolderPrefix)notauuid"))
    }
}
