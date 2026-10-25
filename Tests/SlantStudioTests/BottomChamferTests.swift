import XCTest
import CryptoKit
import Euclid
import simd
@testable import SlantStudio

/// A closed, outward prism over `outline` with `holes`, from `z0` to `z1`, as a triangle soup. Walls are split into
/// `rings` bands. `inward` reverses every triangle (a cavity shell).
func r11PrismSoup(_ outline: [SIMD2<Float>], holes: [[SIMD2<Float>]] = [], from z0: Float = 0, to z1: Float,
                  rings: Int = 1, inward: Bool = false) throws -> [Float] {
    func area(_ loop: [SIMD2<Float>]) -> Double {
        var sum = 0.0
        for i in loop.indices {
            let p = loop[i], q = loop[(i + 1) % loop.count]
            sum += Double(p.x) * Double(q.y) - Double(q.x) * Double(p.y)
        }
        return sum / 2
    }
    // Material on the left: the outline anticlockwise, holes clockwise.
    let loops = [area(outline) > 0 ? outline : Array(outline.reversed())] + holes.map { area($0) < 0 ? $0 : Array($0.reversed()) }
    var planar: [SIMD2<Double>] = []
    var indices: [[Int]] = []
    for loop in loops {
        indices.append(Array(planar.count..<(planar.count + loop.count)))
        planar.append(contentsOf: loop.map { SIMD2(Double($0.x), Double($0.y)) })
    }
    let caps = try triangulatePlanarRegion(points: planar, loops: indices)
    var corners: [SIMD3<Float>] = []
    func at(_ i: Int32, _ z: Float) -> SIMD3<Float> { SIMD3(Float(planar[Int(i)].x), Float(planar[Int(i)].y), z) }
    for t in caps {
        corners.append(contentsOf: [at(t.x, z1), at(t.y, z1), at(t.z, z1)])
        corners.append(contentsOf: [at(t.x, z0), at(t.z, z0), at(t.y, z0)])
    }
    let heights = (0...rings).map { $0 == rings ? z1 : z0 + (z1 - z0) * Float($0) / Float(rings) }
    for loop in loops {
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            for r in 0..<rings {
                let lo = heights[r], hi = heights[r + 1]
                let a0 = SIMD3(a.x, a.y, lo), b0 = SIMD3(b.x, b.y, lo), a1 = SIMD3(a.x, a.y, hi), b1 = SIMD3(b.x, b.y, hi)
                corners.append(contentsOf: [a0, b0, b1, a0, b1, a1])
            }
        }
    }
    if inward {
        for t in stride(from: 0, to: corners.count, by: 3) { corners.swapAt(t + 1, t + 2) }
    }
    return corners.flatMap { [$0.x, $0.y, $0.z] }
}

func r11Rectangle(_ low: SIMD2<Float>, _ high: SIMD2<Float>) -> [SIMD2<Float>] {
    [low, SIMD2(high.x, low.y), high, SIMD2(low.x, high.y)]
}

func r11Circle(_ centre: SIMD2<Float>, radius: Float, segments: Int) -> [SIMD2<Float>] {
    (0..<segments).map { i in
        let angle = 2 * Float.pi * Float(i) / Float(segments)
        return centre + SIMD2(cos(angle), sin(angle)) * radius
    }
}

final class BottomChamferTests: XCTestCase {
    private let size: Double = 0.4

    private func prism(_ outline: [SIMD2<Float>], holes: [[SIMD2<Float>]] = [], height: Float = 20, rings: Int = 1) throws -> STLMesh {
        try STLMesh.validated(r11PrismSoup(outline, holes: holes, to: height, rings: rings))
    }
    private func box(_ x: Float = 40, _ y: Float = 40, _ z: Float = 20) throws -> STLMesh {
        try prism(r11Rectangle(.zero, SIMD2(x, y)), height: z)
    }
    private func health(_ mesh: STLMesh) throws -> MeshHealthReport { try XCTUnwrap(analyzeMeshHealth(mesh)) }
    private func points(_ mesh: STLMesh, atZ z: Float) -> [SIMD2<Float>] {
        stride(from: 0, to: mesh.vertices.count, by: 3).compactMap { i in
            mesh.vertices[i + 2] == z ? SIMD2(mesh.vertices[i], mesh.vertices[i + 1]) : nil
        }
    }
    /// Removed volume of a mitred 45° chamfer of height s round outlines of length L whose turns sum tan(φ/2) to K.
    private func chamferVolume(length: Double, turns: Double, size s: Double) -> Double { length * s * s / 2 - turns * s * s * s / 3 }

    private func assertSoundCopy(_ result: BottomChamferResult, _ source: STLMesh, expectedRemoved: Double,
                                 file: StaticString = #filePath, line: UInt = #line) throws {
        let mesh = try XCTUnwrap(result.mesh, "Skipped: \(String(describing: result.skipped))", file: file, line: line)
        XCTAssertNil(result.skipped, file: file, line: line)
        XCTAssertEqual(mesh.minimum, source.minimum, file: file, line: line)
        XCTAssertEqual(mesh.maximum, source.maximum, file: file, line: line)
        let before = try health(source), after = try health(mesh)
        XCTAssertTrue(meshHealthIsSound(after), file: file, line: line)
        XCTAssertGreaterThan(after.signedVolume, 0, file: file, line: line)
        XCTAssertEqual(after.shells, before.shells, file: file, line: line)
        XCTAssertEqual(result.shellsAfter, before.shells, file: file, line: line)
        XCTAssertEqual(before.signedVolume - after.signedVolume, expectedRemoved, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(result.removedVolumeMM3, expectedRemoved, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(try XCTUnwrap(result.data, file: file, line: line), mesh.binarySTL(), file: file, line: line)
        // Every face that slopes is a 45° band facing down and out.
        for t in 0..<mesh.triangleCount {
            let p = (0..<3).map { j in SIMD3(mesh.vertices[t * 9 + j * 3], mesh.vertices[t * 9 + j * 3 + 1], mesh.vertices[t * 9 + j * 3 + 2]) }
            let n = simd_normalize(simd_cross(SIMD3<Double>(p[1] - p[0]), SIMD3<Double>(p[2] - p[0])))
            guard abs(n.z) > 0.01, abs(n.z) < 0.99 else { continue }
            XCTAssertEqual(n.z, -0.5.squareRoot(), accuracy: 1e-3, "Triangle \(t) slopes at \(n)", file: file, line: line)
        }
        // Euclid agrees that it is a closed, outward solid.
        if mesh.triangleCount <= 20_000 {
            let solid = try mesh.reinforcementSolid()
            XCTAssertTrue(solid.isWatertight, file: file, line: line)
            XCTAssertEqual(solid.signedVolume, after.signedVolume, accuracy: 0.01, file: file, line: line)
        }
    }

    // MARK: Shapes

    func testBoxGetsTheExactChamferVolumeAndBounds() throws {
        let source = try box()
        let result = try bottomChamferCopy(of: source)
        // 160 mm of outline and four 90° corners.
        let expected = chamferVolume(length: 160, turns: 4, size: size)
        XCTAssertEqual(expected, 12.714_667, accuracy: 1e-5)
        try assertSoundCopy(result, source, expectedRemoved: expected)
        XCTAssertEqual(result.sizeMM, 0.4)
        XCTAssertEqual(result.chamferedOutlines, 1)
        XCTAssertEqual(result.keptHoleEntries, 0)
        XCTAssertEqual(result.outlineLengthMM, 160, accuracy: 1e-4)
        XCTAssertEqual(result.contactBeforeMM2, 1600, accuracy: 1e-6)
        XCTAssertEqual(result.contactAfterMM2, 39.2 * 39.2, accuracy: 1e-3)
        let mesh = try XCTUnwrap(result.mesh)
        // At the bed the outline moved in by 0.4 mm on every side; at 0.4 mm it is the box's own.
        let bed = points(mesh, atZ: 0)
        XCTAssertEqual(bed.map(\.x).min()!, 0.4, accuracy: 1e-5)
        XCTAssertEqual(bed.map(\.x).max()!, 39.6, accuracy: 1e-5)
        XCTAssertEqual(bed.map(\.y).min()!, 0.4, accuracy: 1e-5)
        XCTAssertEqual(bed.map(\.y).max()!, 39.6, accuracy: 1e-5)
        let plane = points(mesh, atZ: 0.4)
        XCTAssertEqual(plane.map(\.x).min(), 0)
        XCTAssertEqual(plane.map(\.x).max(), 40)
    }

    func testLShapedFootprintWithAConcaveCorner() throws {
        let outline: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(30, 0), SIMD2(30, 10), SIMD2(10, 10), SIMD2(10, 30), SIMD2(0, 30)]
        let source = try prism(outline, height: 15)
        let result = try bottomChamferCopy(of: source)
        // Five 90° convex corners and one concave: tan sum 5 − 1.
        try assertSoundCopy(result, source, expectedRemoved: chamferVolume(length: 120, turns: 4, size: size))
        XCTAssertEqual(result.contactAfterMM2, 9.2 * 49.2, accuracy: 1e-3)
        // The concave corner's mitre sits where both edges' offsets meet, 0.4 mm into the material each way.
        let bed = points(try XCTUnwrap(result.mesh), atZ: 0)
        XCTAssertTrue(bed.contains { simd_distance($0, SIMD2(9.6, 9.6)) < 1e-4 })
    }

    func testHoleEntryKeepsItsSizeByDefault() throws {
        let hole = r11Rectangle(SIMD2(15, 15), SIMD2(25, 25))
        let source = try prism(r11Rectangle(.zero, SIMD2(40, 40)), holes: [hole])
        let result = try bottomChamferCopy(of: source)
        try assertSoundCopy(result, source, expectedRemoved: chamferVolume(length: 160, turns: 4, size: size))
        XCTAssertEqual(result.keptHoleEntries, 1)
        XCTAssertEqual(result.chamferedHoleEntries, 0)
        let bed = points(try XCTUnwrap(result.mesh), atZ: 0).filter { $0.x > 10 && $0.x < 30 && $0.y > 10 && $0.y < 30 }
        XCTAssertFalse(bed.isEmpty)
        for p in bed {
            XCTAssertTrue(p.x == 15 || p.x == 25 || p.y == 15 || p.y == 25, "\(p) isn't on the hole's own outline")
            XCTAssertTrue((15...25).contains(p.x) && (15...25).contains(p.y))
        }
        XCTAssertTrue(bottomChamferSummary(result).contains("1 hole entry keeps its size."))

        // As an option, the entry is chamfered too: the hole is 0.4 mm wider each side at the bed.
        let opened = try bottomChamferCopy(of: source, chamferHoleEntries: true)
        let hole45 = chamferVolume(length: 40, turns: -4, size: size)
        try assertSoundCopy(opened, source, expectedRemoved: chamferVolume(length: 160, turns: 4, size: size) + hole45)
        XCTAssertEqual(opened.chamferedHoleEntries, 1)
        XCTAssertEqual(opened.keptHoleEntries, 0)
        let wider = points(try XCTUnwrap(opened.mesh), atZ: 0).filter { $0.x > 10 && $0.x < 30 && $0.y > 10 && $0.y < 30 }
        XCTAssertEqual(wider.map(\.x).min()!, 14.6, accuracy: 1e-5)
        XCTAssertEqual(wider.map(\.x).max()!, 25.4, accuracy: 1e-5)
    }

    func testRoundHoleFromEuclidKeepsItsEntry() throws {
        let hole = Mesh.cylinder(radius: 4, height: 30, slices: 48).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(20, 15, 10))
        let block = Mesh.cube(center: Vector(20, 15, 10), size: Vector(40, 30, 20)).subtracting(hole)
        let source = try repairMesh(try ReinforcementEngine.stl(block.makeWatertight())).mesh
        XCTAssertTrue(meshHealthIsSound(try health(source)))
        let result = try bottomChamferCopy(of: source)
        try assertSoundCopy(result, source, expectedRemoved: chamferVolume(length: 140, turns: 4, size: size))
        XCTAssertEqual(result.keptHoleEntries, 1)
        // The entry's outline at the bed: the 48 corners at 4 mm and points along its sides (Euclid's bed face also has
        // points of its own just outside, which the new bed face doesn't need).
        let centre = SIMD2<Float>(20, 15)
        let apothem = 4 * cos(Float.pi / 48)
        func entry(_ mesh: STLMesh) -> Set<[Float]> {
            Set(points(mesh, atZ: 0).filter { simd_distance($0, centre) <= 4.0001 }.map { [$0.x, $0.y] })
        }
        let original = entry(source), after = entry(try XCTUnwrap(result.mesh))
        XCTAssertGreaterThanOrEqual(original.count, 48)
        XCTAssertTrue(original.isSubset(of: after), "Every corner of the hole's entry is still there")
        for p in after { XCTAssertGreaterThanOrEqual(simd_distance(SIMD2(p[0], p[1]), centre), apothem - 1e-4) }
    }

    func testRoundPuckFromEuclid() throws {
        let puck = Mesh.cylinder(radius: 15, height: 8, slices: 64).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(0, 0, 4))
        let source = try repairMesh(try ReinforcementEngine.stl(puck.makeWatertight())).mesh
        XCTAssertTrue(meshHealthIsSound(try health(source)))
        let result = try bottomChamferCopy(of: source)
        // A regular 64-gon: each corner turns by 2π/64.
        let side = 2 * 15 * sin(Double.pi / 64)
        try assertSoundCopy(result, source, expectedRemoved: chamferVolume(length: 64 * side, turns: 64 * tan(Double.pi / 64), size: size))
    }

    func testTwoPartsOnTheBedAreBothChamfered() throws {
        let soup = try r11PrismSoup(r11Rectangle(.zero, SIMD2(20, 20)), to: 10)
            + r11PrismSoup(r11Rectangle(SIMD2(30, 0), SIMD2(50, 20)), to: 10)
        let source = try STLMesh.validated(soup)
        let result = try bottomChamferCopy(of: source)
        try assertSoundCopy(result, source, expectedRemoved: 2 * chamferVolume(length: 80, turns: 4, size: size))
        XCTAssertEqual(result.chamferedOutlines, 2)
        XCTAssertEqual(result.shellsAfter, 2)
    }

    func testPlaneMovesClearOfVerticesAtTheChamferHeight() throws {
        // Wall rings every 0.4 mm put vertices exactly on the requested plane.
        let source = try prism(r11Rectangle(.zero, SIMD2(30, 30)), height: 20, rings: 50)
        let result = try bottomChamferCopy(of: source)
        XCTAssertGreaterThan(result.sizeMM, 0.4)
        XCTAssertLessThan(result.sizeMM, 0.41)
        try assertSoundCopy(result, source, expectedRemoved: chamferVolume(length: 120, turns: 4, size: Double(result.sizeMM)))
    }

    // MARK: Skips

    func testSlopedSidesAreSkipped() throws {
        func frustum(bottom: Float, top: Float) throws -> STLMesh {
            let b = r11Rectangle(SIMD2(-bottom / 2, -bottom / 2), SIMD2(bottom / 2, bottom / 2))
            let t = r11Rectangle(SIMD2(-top / 2, -top / 2), SIMD2(top / 2, top / 2))
            var corners: [SIMD3<Float>] = [SIMD3(b[0], 0), SIMD3(b[2], 0), SIMD3(b[1], 0), SIMD3(b[0], 0), SIMD3(b[3], 0), SIMD3(b[2], 0),
                                           SIMD3(t[0], 20), SIMD3(t[1], 20), SIMD3(t[2], 20), SIMD3(t[0], 20), SIMD3(t[2], 20), SIMD3(t[3], 20)]
            for i in 0..<4 {
                let j = (i + 1) % 4
                corners.append(contentsOf: [SIMD3(b[i], 0), SIMD3(b[j], 0), SIMD3(t[j], 20), SIMD3(b[i], 0), SIMD3(t[j], 20), SIMD3(t[i], 20)])
            }
            let mesh = try STLMesh.validated(corners.flatMap { [$0.x, $0.y, $0.z] })
            XCTAssertTrue(meshHealthIsSound(try health(mesh)))
            return mesh
        }
        // Wider at the bed: the sides flare out.
        XCTAssertEqual(try bottomChamferCopy(of: frustum(bottom: 40, top: 30)).skipped, .sidesNotUpright)
        // Narrower at the bed: the edge already slopes in.
        XCTAssertEqual(try bottomChamferCopy(of: frustum(bottom: 30, top: 40)).skipped, .alreadyTapered)
        // A plinth copy already has its own chamfer.
        let plinth = try box(20, 20, 10).plinthCopy(PlinthSettings(shape: .rectangular))
        XCTAssertEqual(try bottomChamferCopy(of: plinth.mesh).skipped, .alreadyTapered)
        // A ledge 0.2 mm above the bed.
        let ledge = try STLMesh.validated(r11PrismSoup(r11Rectangle(.zero, SIMD2(30, 30)), to: 0.2)
            + r11PrismSoup(r11Rectangle(SIMD2(5, 5), SIMD2(25, 25)), from: 0.2, to: 10))
        XCTAssertNotNil(try bottomChamferCopy(of: ledge).skipped)
    }

    func testPartWithoutAFlatBedFaceIsSkipped() throws {
        // A box standing on one edge.
        let source = try box(20, 20, 20)
        let turn = simd_quatf(angle: .pi / 4, axis: SIMD3(1, 0, 0))
        var rotated: [Float] = []
        for i in stride(from: 0, to: source.vertices.count, by: 3) {
            let p = turn.act(SIMD3(source.vertices[i], source.vertices[i + 1], source.vertices[i + 2]))
            rotated.append(contentsOf: [p.x, p.y, p.z])
        }
        let result = try bottomChamferCopy(of: STLMesh.validated(rotated))
        XCTAssertEqual(result.skipped, .noFlatBedFace)
        XCTAssertNil(result.mesh)
        XCTAssertNil(result.data)
    }

    func testSmallOrThinPartsAreSkipped() throws {
        XCTAssertEqual(try bottomChamferCopy(of: box(4, 30, 10)).skipped, .tooSmall)
        XCTAssertEqual(try bottomChamferCopy(of: box(30, 30, 0.6)).skipped, .tooSmall)
    }

    func testIntricateEdgesAreSkipped() throws {
        // A hole 0.5 mm from the edge: the moved edge would reach it.
        let near = try prism(r11Rectangle(.zero, SIMD2(20, 20)), holes: [r11Rectangle(SIMD2(0.5, 8), SIMD2(3, 12))])
        XCTAssertEqual(try bottomChamferCopy(of: near).skipped, .tooIntricate)
        // A neck 0.6 mm wide between two blocks.
        let neck: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 4.7), SIMD2(20, 4.7), SIMD2(20, 0), SIMD2(30, 0),
                                    SIMD2(30, 10), SIMD2(20, 10), SIMD2(20, 5.3), SIMD2(10, 5.3), SIMD2(10, 10), SIMD2(0, 10)]
        XCTAssertEqual(try bottomChamferCopy(of: prism(neck)).skipped, .tooIntricate)
        // A spike whose tip turns by more than 170°.
        let spike: [SIMD2<Float>] = [SIMD2(0, 0), SIMD2(20, 0), SIMD2(20, 20), SIMD2(10, 20), SIMD2(10.5, 40), SIMD2(9.9, 20), SIMD2(0, 20)]
        XCTAssertEqual(try bottomChamferCopy(of: prism(spike)).skipped, .tooIntricate)
    }

    func testThinWallsKeepEnoughContact() throws {
        func ring(_ wall: Float) throws -> STLMesh {
            try prism(r11Rectangle(.zero, SIMD2(30, 30)), holes: [r11Rectangle(SIMD2(wall, wall), SIMD2(30 - wall, 30 - wall))])
        }
        let thick = try ring(1.2)
        try assertSoundCopy(try bottomChamferCopy(of: thick), thick, expectedRemoved: chamferVolume(length: 120, turns: 4, size: size))
        XCTAssertEqual(try bottomChamferCopy(of: ring(1.0)).skipped, .wouldReduceContactTooMuch)
    }

    func testRefusesUnsoundMeshesAndBadSizes() throws {
        var open = try box().vertices
        open.removeLast(9)
        XCTAssertEqual(try bottomChamferCopy(of: STLMesh.validated(open)).skipped, .notClosedSolid)
        XCTAssertThrowsError(try bottomChamferCopy(of: box(), sizeMM: 0)) { XCTAssertEqual($0 as? BottomChamferError, .invalidSize) }
        XCTAssertThrowsError(try bottomChamferCopy(of: box(), sizeMM: .nan)) { XCTAssertEqual($0 as? BottomChamferError, .invalidSize) }
        XCTAssertThrowsError(try bottomChamferCopy(of: box(), sizeMM: 1.5))
        XCTAssertThrowsError(try bottomChamferCopy(of: box(), isCancelled: { true })) { XCTAssertEqual($0 as? BottomChamferError, .stopped) }
        let half = try bottomChamferCopy(of: box(), sizeMM: 0.2)
        try assertSoundCopy(half, try box(), expectedRemoved: chamferVolume(length: 160, turns: 4, size: 0.2))
    }

    // MARK: Determinism and copy

    func testSameBytesEveryRun() throws {
        let hole = Mesh.cylinder(radius: 3, height: 30, slices: 40).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(12, 12, 10))
        let source = try repairMesh(try ReinforcementEngine.stl(Mesh.cube(center: Vector(15, 15, 10), size: Vector(30, 30, 20))
            .subtracting(hole).makeWatertight())).mesh
        let a = try bottomChamferCopy(of: source), b = try bottomChamferCopy(of: source)
        XCTAssertNotNil(a.data)
        XCTAssertEqual(a.data, b.data)
    }

    func testSummaryNamesTheChamferWithoutStrengthClaims() throws {
        let result = try bottomChamferCopy(of: box())
        let text = bottomChamferSummary(result)
        XCTAssertTrue(text.hasPrefix("Adds a 0.4 mm chamfer round the bottom edge (160 mm of outline)"), text)
        XCTAssertTrue(text.contains("Bed contact 1,600 → 1,537 mm²."), text)
        for word in ["strong", "stronger", "guarantee", "safe", "%"] { XCTAssertFalse(text.lowercased().contains(word), word) }
        for reason in BottomChamferSkipReason.allCases {
            XCTAssertTrue(reason.message.hasSuffix("."))
            XCTAssertFalse(reason.message.lowercased().contains("strong"))
        }
        XCTAssertEqual(bottomChamferSummary(try bottomChamferCopy(of: box(4, 30, 10))), BottomChamferSkipReason.tooSmall.message)
    }

    func testMitreInsetAndSegmentHelpers() {
        let square = r11Rectangle(.zero, SIMD2(10, 10)).map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        let inset = bottomChamferMitreInset(square, by: 1)!
        XCTAssertEqual(inset[0], SIMD2(1, 1))
        XCTAssertEqual(inset[2], SIMD2(9, 9))
        XCTAssertEqual(bottomChamferLoopArea(inset), 64, accuracy: 1e-9)
        // A hole (clockwise) grows.
        XCTAssertEqual(bottomChamferLoopArea(bottomChamferMitreInset(square.reversed(), by: 1)!), -144, accuracy: 1e-9)
        XCTAssertNil(bottomChamferMitreInset([SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 0.01)], by: 1))
        XCTAssertEqual(bottomChamferSegmentDistance(SIMD2(0, 0), SIMD2(10, 0), SIMD2(0, 2), SIMD2(10, 2)), 2, accuracy: 1e-12)
        XCTAssertEqual(bottomChamferSegmentDistance(SIMD2(0, 0), SIMD2(10, 0), SIMD2(5, -1), SIMD2(5, 1)), 0)
        XCTAssertTrue(bottomChamferSegmentsTouch(SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 0), SIMD2(10, 5)))
    }

    func testCornersBandsAndSliverFlips() {
        // A square with cut points along its sides, one of them 0.2 mm from a corner.
        let loop: [SIMD2<Double>] = [SIMD2(10, 10), SIMD2(0, 10), SIMD2(0, 0), SIMD2(5, 0), SIMD2(9.8, 0), SIMD2(10, 0), SIMD2(10, 7)]
        let found = bottomChamferCorners(loop)
        XCTAssertEqual(found.start, 2)
        XCTAssertEqual(found.corners.map { (found.start + $0) % loop.count }, [2, 5, 0, 1])
        let band = bottomChamferBand(loop, by: 0.4)!
        XCTAssertEqual(band.bottom.count, 6, "The point 0.2 mm from a corner shares the corner's bottom point")
        XCTAssertEqual(band.bottom[band.bottomOf[4]], band.bottom[band.bottomOf[5]])
        // Rounded to the Float coordinates that are written.
        XCTAssertEqual(band.bottom[band.bottomOf[5]], SIMD2(Double(Float(9.6)), Double(Float(0.4))))
        XCTAssertEqual(band.bottom[band.bottomOf[3]], SIMD2(5, Double(Float(0.4))))
        XCTAssertEqual(bottomChamferLoopArea(band.bottom), 9.2 * 9.2, accuracy: 1e-4)

        // Three points along a line, and the triangle across their long edge: one flip removes the sliver.
        let points: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(2, 0), SIMD2(1, 1)]
        var triangles: [SIMD3<Int32>] = [SIMD3(0, 1, 2), SIMD3(2, 3, 0)]
        XCTAssertTrue(bottomChamferIsSliver(points[0], points[1], points[2]))
        bottomChamferFlipSlivers(&triangles, points: points)
        XCTAssertFalse(triangles.contains { bottomChamferIsSliver(points[Int($0.x)], points[Int($0.y)], points[Int($0.z)]) })
        XCTAssertEqual(triangles, [SIMD3(2, 3, 1), SIMD3(3, 0, 1)])
    }

    // MARK: Hash seeds and timing

    /// Run only as a subprocess by the test below: writes both tools' output hashes to the named file.
    func testHashSeedProbeWritesGeometryHashes() throws {
        guard let out = ProcessInfo.processInfo.environment["SLANT_R11_GEOMETRY_HASH_OUT"] else { return }
        try Self.geometryDigest().write(toFile: out, atomically: true, encoding: .utf8)
    }

    static func geometryDigest() throws -> String {
        let hole = Mesh.cylinder(radius: 3, height: 30, slices: 40).rotated(by: Rotation(pitch: .halfPi)).translated(by: Vector(12, 12, 10))
        let chamferSource = try repairMesh(try ReinforcementEngine.stl(Mesh.cube(center: Vector(15, 15, 10), size: Vector(30, 30, 20))
            .subtracting(hole).makeWatertight())).mesh
        let chamfer = try XCTUnwrap(try bottomChamferCopy(of: chamferSource).data)
        let pocket = Mesh.sphere(radius: 5, slices: 24, stacks: 12).translated(by: Vector(20, 20, 10))
        let pocketSource = try repairMesh(try ReinforcementEngine.stl(Mesh.cube(center: Vector(20, 20, 10), size: Vector(40, 40, 20))
            .subtracting(pocket).makeWatertight())).mesh
        let filled = try XCTUnwrap(try fillHiddenPocketsCopy(of: pocketSource).data)
        return [chamfer, filled].map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }.joined(separator: " ")
    }

    /// The same models give the same bytes whatever the process's hash seed: two runs of this test bundle, one with
    /// `SWIFT_DETERMINISTIC_HASHING=1` and one with a random seed, against this process's own result.
    func testGeometryBytesMatchAcrossHashSeeds() throws {
        guard ProcessInfo.processInfo.environment["SLANT_R11_GEOMETRY_HASH_OUT"] == nil else { return }
        let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
        guard FileManager.default.isExecutableFile(atPath: xcrun.path) else { throw XCTSkip("xcrun isn't available") }
        let bundle = Bundle(for: Self.self).bundlePath
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("SlantStudioR11HashSeed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func hash(deterministic: Bool) throws -> String {
            let out = folder.appendingPathComponent(deterministic ? "fixed.txt" : "random.txt").path
            var environment = ProcessInfo.processInfo.environment
            environment["SLANT_R11_GEOMETRY_HASH_OUT"] = out
            if deterministic { environment["SWIFT_DETERMINISTIC_HASHING"] = "1" } else { environment.removeValue(forKey: "SWIFT_DETERMINISTIC_HASHING") }
            let process = Process()
            process.executableURL = xcrun
            process.arguments = ["xctest", "-XCTest", "SlantStudioTests.BottomChamferTests/testHashSeedProbeWritesGeometryHashes", bundle]
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            let deadline = Date().addingTimeInterval(180)
            while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { process.terminate(); XCTFail("The subprocess didn't finish") }
            return try String(contentsOfFile: out, encoding: .utf8)
        }
        let local = try Self.geometryDigest()
        XCTAssertEqual(try hash(deterministic: true), local)
        XCTAssertEqual(try hash(deterministic: false), local)
    }

    /// Opt-in timing (set MESH_TOOLS_BENCH=1; best run in release) on ring-shaped prisms of about 20,000, 100,000 and
    /// 400,000 triangles, each with a hidden pocket in its wall.
    func testTiming() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MESH_TOOLS_BENCH"] == "1", "Set MESH_TOOLS_BENCH=1 to time the geometry tools.")
        for (segments, rings) in [(200, 33), (500, 66), (1000, 133)] {
            var soup = try r11PrismSoup(r11Circle(.zero, radius: 50, segments: segments),
                                        holes: [r11Circle(.zero, radius: 15, segments: segments / 2)], to: 20, rings: rings)
            soup += try r11PrismSoup(r11Rectangle(SIMD2(30, -3), SIMD2(36, 3)), from: 5, to: 15, inward: true)
            let source = try STLMesh.validated(soup)
            var start = Date()
            let chamfer = try bottomChamferCopy(of: source)
            let chamferSeconds = Date().timeIntervalSince(start)
            start = Date()
            let report = try hiddenPocketsReport(source)
            let reportSeconds = Date().timeIntervalSince(start)
            start = Date()
            let filled = try fillHiddenPocketsCopy(of: source)
            let fillSeconds = Date().timeIntervalSince(start)
            print(String(format: "R11 geometry timing: %d triangles, chamfer %.2f s (%@), pockets report %.2f s (%d), fill %.2f s (%@)",
                         source.triangleCount, chamferSeconds, chamfer.applied ? "applied" : "\(chamfer.skipped!)", reportSeconds,
                         report.count, fillSeconds, filled.applied ? "applied" : "\(filled.skipped!)"))
            XCTAssertTrue(chamfer.applied)
            XCTAssertEqual(report.count, 1)
            XCTAssertTrue(filled.applied)
        }
    }
}
