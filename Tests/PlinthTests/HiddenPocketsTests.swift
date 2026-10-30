import XCTest
import Euclid
import simd
@testable import Plinth

final class HiddenPocketsTests: XCTestCase {
    private func cuboid(_ low: SIMD3<Float>, _ high: SIMD3<Float>, inward: Bool = false) throws -> [Float] {
        try r11PrismSoup(r11Rectangle(SIMD2(low.x, low.y), SIMD2(high.x, high.y)), from: low.z, to: high.z, inward: inward)
    }
    private func health(_ mesh: STLMesh) throws -> MeshHealthReport { try XCTUnwrap(analyzeMeshHealth(mesh)) }
    /// The live test's 40 × 40 × 20 mm block with a 10 mm cube pocket in its middle.
    private func pocketedBlock() throws -> STLMesh {
        try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + cuboid(SIMD3(15, 15, 5), SIMD3(25, 25, 15), inward: true))
    }

    func testOnePocketIsReportedAndFilled() throws {
        let source = try pocketedBlock()
        let before = try health(source)
        XCTAssertTrue(meshHealthIsSound(before))
        XCTAssertEqual(before.shells, 2)
        let report = try hiddenPocketsReport(source)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.shells, 2)
        XCTAssertEqual(report.separateParts, 1)
        XCTAssertEqual(report.shellsInsidePockets, 0)
        XCTAssertEqual(report.otherShells, 0)
        XCTAssertTrue(report.complete)
        XCTAssertEqual(report.estimatedExtraCostUSD, Decimal(string: "0.39"))
        let pocket = try XCTUnwrap(report.pockets.first)
        XCTAssertEqual(pocket.volumeMM3, 1000, accuracy: 1e-6)
        XCTAssertEqual(pocket.low, SIMD3(15, 15, 5))
        XCTAssertEqual(pocket.high, SIMD3(25, 25, 15))
        XCTAssertEqual(pocket.triangles, 12)
        XCTAssertEqual(report.addedVolumeMM3, 1000, accuracy: 1e-6)

        let result = try fillHiddenPocketsCopy(of: source)
        let mesh = try XCTUnwrap(result.mesh, "Skipped: \(String(describing: result.skipped))")
        let after = try health(mesh)
        XCTAssertTrue(meshHealthIsSound(after))
        XCTAssertEqual(after.shells, 1)
        XCTAssertEqual(result.shellsBefore, 2)
        XCTAssertEqual(result.shellsAfter, 1)
        XCTAssertEqual(result.filledPockets, 1)
        XCTAssertEqual(after.signedVolume, 32_000, accuracy: 1e-6)
        XCTAssertEqual(result.addedVolumeMM3, 1000, accuracy: 1e-6)
        XCTAssertEqual(mesh.minimum, source.minimum)
        XCTAssertEqual(mesh.maximum, source.maximum)
        XCTAssertEqual(try XCTUnwrap(result.data), mesh.binarySTL())
        // The outer surface is the input's own triangles, in order.
        XCTAssertEqual(mesh.vertices, Array(source.vertices.prefix(mesh.vertices.count)))
        XCTAssertEqual(try hiddenPocketsReport(mesh).count, 0)
    }

    func testSeparatePartsAreNotPockets() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(20, 20, 10)) + cuboid(SIMD3(30, 0, 0), SIMD3(50, 20, 10)))
        let report = try hiddenPocketsReport(source)
        XCTAssertEqual(report.count, 0)
        XCTAssertEqual(report.separateParts, 2)
        XCTAssertEqual(report.estimatedExtraCostUSD, 0)
        XCTAssertNil(hiddenPocketsSummary(report))
        let result = try fillHiddenPocketsCopy(of: source)
        XCTAssertEqual(result.skipped, .noPockets)
        XCTAssertNil(result.mesh)
        XCTAssertEqual(result.report.separateParts, 2)
    }

    func testASolidInsideAPocketGoesWithIt() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + cuboid(SIMD3(10, 10, 4), SIMD3(30, 30, 16), inward: true)
            + cuboid(SIMD3(15, 15, 8), SIMD3(25, 25, 12)))
        XCTAssertTrue(meshHealthIsSound(try health(source)))
        let report = try hiddenPocketsReport(source)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.shellsInsidePockets, 1)
        XCTAssertEqual(report.pockets[0].shellsInside, 1)
        XCTAssertEqual(report.separateParts, 1)
        XCTAssertEqual(report.removableBodies, 2)
        XCTAssertEqual(report.estimatedExtraCostUSD, Decimal(string: "0.78"))
        XCTAssertEqual(report.addedVolumeMM3, 20 * 20 * 12 - 10 * 10 * 4, accuracy: 1e-6)
        let result = try fillHiddenPocketsCopy(of: source)
        let mesh = try XCTUnwrap(result.mesh)
        let after = try health(mesh)
        XCTAssertEqual(after.shells, 1)
        XCTAssertEqual(result.removedInnerShells, 1)
        XCTAssertTrue(meshHealthIsSound(after))
        XCTAssertEqual(after.signedVolume, 32_000, accuracy: 1e-6)
        XCTAssertEqual(mesh.triangleCount, 12)
    }

    func testTwoPocketsAndASeparatePart() throws {
        let source = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + cuboid(SIMD3(5, 5, 5), SIMD3(10, 10, 10), inward: true)
            + cuboid(SIMD3(20, 20, 5), SIMD3(30, 30, 15), inward: true) + cuboid(SIMD3(50, 0, 0), SIMD3(60, 10, 10)))
        let report = try hiddenPocketsReport(source)
        XCTAssertEqual(report.count, 2)
        XCTAssertEqual(report.separateParts, 2)
        XCTAssertEqual(report.estimatedExtraCostUSD, Decimal(string: "0.78"))
        let text = try XCTUnwrap(hiddenPocketsSummary(report))
        XCTAssertEqual(text, "2 hidden pockets cost about $0.78 extra in total (Slant bills each as a separate body; test on 25 Oct 2026). Filling uses about 1.1 cm³ more material. Get an estimate for both. The model’s 2 separate parts aren’t pockets, so filling leaves them.")
        let result = try fillHiddenPocketsCopy(of: source)
        let after = try health(try XCTUnwrap(result.mesh))
        // The separate part stays.
        XCTAssertEqual(after.shells, 2)
        XCTAssertEqual(after.signedVolume, 32_000 + 1000, accuracy: 1e-6)
    }

    func testOpenCavitiesAndOddShellsAreNeverFilled() throws {
        // A through hole is part of the outer surface.
        let through = try STLMesh.validated(r11PrismSoup(r11Rectangle(.zero, SIMD2(40, 40)), holes: [r11Rectangle(SIMD2(15, 15), SIMD2(25, 25))], to: 20))
        XCTAssertEqual(try hiddenPocketsReport(through).count, 0)
        XCTAssertEqual(try hiddenPocketsReport(through).shells, 1)
        // A solid inside a solid is not a pocket; nor is an inward shell on its own.
        let embedded = try STLMesh.validated(cuboid(.zero, SIMD3(40, 40, 20)) + cuboid(SIMD3(15, 15, 5), SIMD3(25, 25, 15)))
        let report = try hiddenPocketsReport(embedded)
        XCTAssertEqual(report.count, 0)
        XCTAssertEqual(report.otherShells, 1)
        XCTAssertEqual(try fillHiddenPocketsCopy(of: embedded).skipped, .noPockets)
        let insideOut = try STLMesh.validated(cuboid(.zero, SIMD3(10, 10, 10), inward: true))
        XCTAssertEqual(try hiddenPocketsReport(insideOut).count, 0)
        XCTAssertEqual(try hiddenPocketsReport(insideOut).otherShells, 1)
        // An open mesh is reported but never filled.
        var open = try pocketedBlock().vertices
        open.removeFirst(9)
        let openMesh = try STLMesh.validated(open)
        // The outer surface is open, so nothing can be placed inside it.
        XCTAssertEqual(try hiddenPocketsReport(openMesh).count, 0)
        XCTAssertEqual(try hiddenPocketsReport(openMesh).otherShells, 2)
        XCTAssertEqual(try fillHiddenPocketsCopy(of: openMesh).skipped, .notClosedSolid)
    }

    func testEuclidSphericalVoidIsAPocket() throws {
        let void = Mesh.sphere(radius: 5, slices: 24, stacks: 12).translated(by: Vector(20, 20, 10))
        let block = Mesh.cube(center: Vector(20, 20, 10), size: Vector(40, 40, 20)).subtracting(void)
        let source = try repairMesh(try ReinforcementEngine.stl(block.makeWatertight())).mesh
        XCTAssertTrue(meshHealthIsSound(try health(source)))
        let report = try hiddenPocketsReport(source)
        XCTAssertEqual(report.count, 1)
        XCTAssertEqual(report.pockets[0].volumeMM3, 4 / 3 * Double.pi * 125, accuracy: 30)
        let result = try fillHiddenPocketsCopy(of: source)
        let after = try health(try XCTUnwrap(result.mesh))
        XCTAssertEqual(after.shells, 1)
        XCTAssertEqual(after.signedVolume, 32_000, accuracy: 0.01)
    }

    func testSameBytesEveryRunAndCancellation() throws {
        let source = try pocketedBlock()
        let a = try fillHiddenPocketsCopy(of: source), b = try fillHiddenPocketsCopy(of: source)
        XCTAssertNotNil(a.data)
        XCTAssertEqual(a.data, b.data)
        XCTAssertEqual(try hiddenPocketsReport(source), try hiddenPocketsReport(source))
        XCTAssertThrowsError(try hiddenPocketsReport(source, isCancelled: { true })) { XCTAssertEqual($0 as? HiddenPocketsError, .stopped) }
        XCTAssertThrowsError(try fillHiddenPocketsCopy(of: source, isCancelled: { true })) { XCTAssertEqual($0 as? HiddenPocketsError, .stopped) }
    }

    func testCopyIsDatedAndMakesNoStrengthClaims() throws {
        let report = try hiddenPocketsReport(try pocketedBlock())
        let text = try XCTUnwrap(hiddenPocketsSummary(report))
        XCTAssertEqual(text, "1 hidden pocket costs about $0.39 extra in total (Slant bills it as a separate body; test on 25 Oct 2026). Filling uses about 1.0 cm³ more material. Get an estimate for both.")
        for word in ["strong", "guarantee", "safe", "%"] { XCTAssertFalse(text.lowercased().contains(word), word) }
        XCTAssertEqual(hiddenPocketsCostText(Decimal(string: "1.17")!), "$1.17")
        XCTAssertEqual(hiddenPocketsCostText(Decimal(3) * hiddenPocketBodyChargeUSD), "$1.17")
        for reason in HiddenPocketsSkipReason.allCases { XCTAssertTrue(reason.message.hasSuffix(".")) }
    }
}
