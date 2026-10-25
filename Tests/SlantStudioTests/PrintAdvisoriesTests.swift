import XCTest
import Euclid
import simd
@testable import SlantStudio

/// Round 11: placement checks (minimum contact, tipping, turn about Z, overhangs past 50°) and print advisories.
final class PrintAdvisoriesTests: XCTestCase {
    private func exported(_ mesh: Mesh) throws -> STLMesh { try ReinforcementEngine.stl(mesh.makeWatertight()) }
    private func box(_ low: SIMD3<Double>, _ size: SIMD3<Double>) -> Mesh {
        .cube(center: Vector(low.x + size.x / 2, low.y + size.y / 2, low.z + size.z / 2), size: Vector(size.x, size.y, size.z))
    }
    /// A vertical (Z) cylinder standing on `z`.
    private func post(x: Double, y: Double, z: Double, radius: Double, height: Double, slices: Int = 32) -> Mesh {
        Mesh.cylinder(radius: radius, height: height, slices: slices).rotated(by: Rotation(pitch: .halfPi))
            .translated(by: Vector(x, y, z + height / 2))
    }
    private func turnedAboutZ(_ mesh: STLMesh, degrees: Float) throws -> STLMesh {
        let rotation = simd_quatf(angle: degrees * .pi / 180, axis: SIMD3(0, 0, 1))
        var vertices: [Float] = []
        for i in stride(from: 0, to: mesh.vertices.count, by: 3) {
            let p = rotation.act(SIMD3(mesh.vertices[i], mesh.vertices[i + 1], mesh.vertices[i + 2]))
            vertices += [p.x, p.y, p.z]
        }
        return try STLMesh.parse(STLMesh(vertices: vertices, minimum: .zero, maximum: .one).binarySTL())
    }
    private func kinds(_ advisories: [PrintAdvisory]) -> [PrintAdvisoryKind] { advisories.map(\.kind) }
    /// `printAdvisories` with a lighter wall-thickness check, to keep the suite quick.
    private func advise(_ mesh: STLMesh, placed: Bool, intent: PartIntent?) -> [PrintAdvisory] {
        printAdvisories(for: mesh, placed: placed, intent: intent, wallThickness: analyzeWallThickness(mesh, maximumSamples: 3_000))
    }

    // MARK: Turn about Z

    func testTurnedOrientationRoundTripsCombinesAndKeepsShape() throws {
        let turned = PrintOrientation.xUp.turned(byDegrees: 23)
        XCTAssertEqual(turned, .turned(.xUp, degrees: 23))
        XCTAssertEqual(turned.base, .xUp)
        XCTAssertEqual(turned.zTurnDegrees, 23)
        XCTAssertEqual(turned.turned(byDegrees: -23), .xUp, "Turns combine and a zero turn is no turn")
        XCTAssertEqual(PrintOrientation.zUp.turned(byDegrees: 0), .zUp)
        XCTAssertEqual(try JSONDecoder().decode(PrintOrientation.self, from: JSONEncoder().encode(turned)), turned)
        let face = PrintOrientation.face(simd_normalize(SIMD3<Float>(1, 2, 3))).turned(byDegrees: -12.5)
        XCTAssertEqual(try JSONDecoder().decode(PrintOrientation.self, from: JSONEncoder().encode(face)), face)
        XCTAssertEqual(try JSONDecoder().decode(PrintOrientation.self, from: Data("\"yDown\"".utf8)), .yDown)
        for bad in ["{\"base\":\"xUp\",\"zTurnDegrees\":0}", "{\"base\":\"xUp\",\"zTurnDegrees\":200}",
                    "{\"base\":{\"base\":\"xUp\",\"zTurnDegrees\":5},\"zTurnDegrees\":5}"] {
            XCTAssertThrowsError(try JSONDecoder().decode(PrintOrientation.self, from: Data(bad.utf8)), bad)
        }
        let a = SIMD3<Float>(2, -3, 7), b = SIMD3<Float>(-4, 5, 1)
        XCTAssertEqual(simd_length(turned.rotate(a) - turned.rotate(b)), simd_length(a - b), accuracy: 0.0001)
        XCTAssertEqual(simd_dot(simd_cross(turned.rotate(SIMD3(1, 0, 0)), turned.rotate(SIMD3(0, 1, 0))), turned.rotate(SIMD3(0, 0, 1))), 1, accuracy: 0.00001)
        for v in [SIMD3<Float>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1), a] {
            XCTAssertEqual(turned.rotate(v).z, PrintOrientation.xUp.rotate(v).z, accuracy: 0.00001, "The turn never changes which way is up")
        }
        XCTAssertEqual(turned.label, "Side · X up · turned 23° about Z")
        XCTAssertEqual(printReviewTurnLabel(turned), "on its side, +X side up, turned 23° about Z")
        XCTAssertEqual(printPlacementTurnLine(-0.3), "Turned under 1° about Z to line up its faces.")
        XCTAssertNil(printPlacementTurnLine(0))
    }

    func testPartDrawnAtAnAngleIsTurnedSquareAndAutoImproveThenFindsItsWalls() throws {
        let tray = try exported(box(.zero, SIMD3(20, 20, 20)).subtracting(box(SIMD3(1.8, 1.8, 2), SIMD3(16.4, 16.4, 20))))
        let angled = try turnedAboutZ(tray, degrees: 23)
        XCTAssertNil(tray.oriented(.zUp).zAlignmentTurnDegrees(), "Already square")
        let turn = try XCTUnwrap(angled.oriented(.zUp).zAlignmentTurnDegrees())
        XCTAssertEqual(turn, -23, accuracy: 0.01)
        let choice = try XCTUnwrap(angled.printPlacement(intent: PartIntent()))
        XCTAssertEqual(choice.assessment.orientation, .zUp)
        XCTAssertEqual(choice.zTurnDegrees, turn)
        XCTAssertEqual(choice.lines.first, "Turned 23° about Z to line up its faces.")
        let squared = angled.oriented(choice.orientation)
        XCTAssertEqual(squared.maximum.x, 20, accuracy: 0.001)
        XCTAssertEqual(squared.maximum.y, 20, accuracy: 0.001)
        XCTAssertEqual(squared.maximum.z, 20, accuracy: 0.001)
        // Deterministic: the same mesh gives the same turn and the same bytes.
        XCTAssertEqual(angled.printPlacement(intent: PartIntent()), choice)
        XCTAssertEqual(angled.oriented(choice.orientation).binarySTL(), squared.binarySTL())
        // Unturned, the axis-aligned detection finds no walls to match; turned, it finds all four.
        XCTAssertTrue(AutoImprover.candidates(.thicken, in: angled.oriented(.zUp), intent: PartIntent()).candidates.isEmpty)
        let orientation = try XCTUnwrap(AutoImprover.orientation(for: angled, intent: PartIntent(), locked: false))
        XCTAssertEqual(orientation, choice.orientation)
        XCTAssertEqual(AutoImprover.candidates(.thicken, in: angled.oriented(orientation), intent: PartIntent()).candidates.count, 4)
        // Locked copies keep their placement and aren't turned.
        XCTAssertEqual(AutoImprover.orientation(for: angled, intent: PartIntent(), locked: true), .zUp)
        XCTAssertEqual(AutoImprover.placement(for: angled, intent: PartIntent(), locked: true)?.zTurnDegrees, 0)
        XCTAssertEqual(angled.printPlacement(intent: PartIntent(), allowTurn: false)?.orientation, .zUp)
    }

    func testRoundPartsAreNotTurnedAndTurnsThatWouldNotFitAreSkipped() throws {
        let cylinder = try exported(post(x: 0, y: 0, z: 0, radius: 10, height: 20, slices: 64))
        XCTAssertNil(cylinder.oriented(.zUp).zAlignmentTurnDegrees())
        // A 300 mm bar laid at 45° fits (about 216 mm square); squared up it would be 300 mm long.
        let bar = try turnedAboutZ(try exported(box(.zero, SIMD3(300, 5, 5))), degrees: 45)
        XCTAssertNotNil(bar.oriented(.zUp).zAlignmentTurnDegrees())
        XCTAssertEqual(bar.placementTurnDegrees(after: .zUp), 0)
    }

    // MARK: Contact and tipping

    func testHullHelpers() {
        let square: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(10, 0), SIMD2(10, 10), SIMD2(0, 10), SIMD2(5, 5), SIMD2(5, 0), SIMD2(0, 0)]
        let hull = placementConvexHull(square)
        XCTAssertEqual(hull.count, 4)
        XCTAssertEqual(placementHullMargin(SIMD2(5, 5), hull: hull) ?? .nan, 5, accuracy: 1e-9)
        XCTAssertEqual(placementHullMargin(SIMD2(9, 5), hull: hull) ?? .nan, 1, accuracy: 1e-9)
        XCTAssertEqual(placementHullMargin(SIMD2(13, 5), hull: hull) ?? .nan, -3, accuracy: 1e-9)
        XCTAssertNil(placementHullMargin(SIMD2(0, 0), hull: [SIMD2(0, 0), SIMD2(1, 1)]))
        let angle = 0.5
        let rectangle = [SIMD2<Double>(0, 0), SIMD2(10, 0), SIMD2(10, 4), SIMD2(0, 4)].map {
            SIMD2($0.x * cos(angle) - $0.y * sin(angle), $0.x * sin(angle) + $0.y * cos(angle))
        }
        XCTAssertEqual(placementHullWidth(placementConvexHull(rectangle)), 4, accuracy: 1e-9)
        XCTAssertEqual(placementHullWidth([]), 0)
    }

    func testMinimumContactIsPreferredAndFlaggedWhenNothingHasIt() throws {
        // Better on every other count, but only 5 mm² on the bed (it needs 60 mm² of its 400 mm² footprint).
        let tiny = OrientationAssessment(orientation: .zUp, size: SIMD3(20, 20, 5), contactArea: 5, overhangArea: 0, surfaceArea: 1000)
        let broad = OrientationAssessment(orientation: .xUp, size: SIMD3(20, 20, 20), contactArea: 100, overhangArea: 100, surfaceArea: 1000)
        XCTAssertEqual(tiny.minimumContactMM2, 60, accuracy: 0.001)
        XCTAssertFalse(tiny.meetsMinimumContact)
        XCTAssertTrue(broad.meetsMinimumContact)
        XCTAssertLessThan(tiny.score(priority: .balanced, load: .unknown), broad.score(priority: .balanced, load: .unknown))
        XCTAssertEqual(preferredOrientation([tiny, broad], intent: PartIntent())?.orientation, .xUp)
        let only = try XCTUnwrap(printPlacement([tiny], in: try exported(box(.zero, SIMD3(20, 20, 5))), intent: PartIntent(), allowTurn: true))
        XCTAssertTrue(only.smallBedContact)
        XCTAssertTrue(only.lines.contains { $0.hasPrefix("Small bed contact: about 5 mm² touches the bed, under the 60 mm²") }, "\(only.lines)")
        // The 100 mm² cap applies to large footprints.
        XCTAssertEqual(OrientationAssessment(orientation: .zUp, size: SIMD3(100, 100, 5), contactArea: 99, overhangArea: 0, surfaceArea: 1).minimumContactMM2, 100)
    }

    func testCentreOfMassOutsideTheContactTipsAndScoresWorse() throws {
        // An upside-down L: a 4 mm stem with a long arm at the top. Its centre of mass is well past the stem's foot.
        let hook = try exported(box(.zero, SIMD3(4, 4, 30)).union(box(SIMD3(3.9, 0, 26), SIMD3(36.1, 4, 4))))
        let standing = hook.orientationAssessment(.zUp)
        XCTAssertEqual(standing.contactArea, 16, accuracy: 0.01)
        let margin = try XCTUnwrap(standing.tipMarginMM)
        XCTAssertLessThan(margin, -5)
        XCTAssertTrue(standing.centreOfMassNearEdge)
        XCTAssertTrue(standing.tippingProne)
        XCTAssertEqual(standing.tippingPenalty, 4.5)
        XCTAssertEqual(printPlacementTippingLine(standing), "Could tip: its centre of mass is beyond the edge of what touches the bed. A plinth or a wider flat base helps it stay put.")
        // Lying on its side it is stable, and that is chosen.
        let chosen = try XCTUnwrap(hook.printPlacement(intent: PartIntent()))
        XCTAssertFalse(chosen.tippingProne)
        XCTAssertNotEqual(chosen.assessment.orientation, .zUp)

        let cube = try exported(box(.zero, SIMD3(10, 10, 10))).orientationAssessment(.zUp)
        XCTAssertEqual(cube.tipMarginMM ?? .nan, 5, accuracy: 0.001)
        XCTAssertEqual(cube.contactHullWidth ?? .nan, 10, accuracy: 0.001)
        XCTAssertFalse(cube.tippingProne)
        XCTAssertEqual(cube.tippingPenalty, 0)

        let column = try exported(box(.zero, SIMD3(5, 5, 40))).orientationAssessment(.zUp)
        XCTAssertTrue(column.slenderOnBed)
        XCTAssertFalse(column.centreOfMassNearEdge)
        XCTAssertEqual(printPlacementTippingLine(column), "Tall and narrow on the bed: about 40 mm tall on a contact 5.0 mm wide. Slant uses no brims, so a plinth or a wider base helps it stay put.")
        // Hand-made assessments without these figures are scored as before.
        let plain = OrientationAssessment(orientation: .zUp, size: SIMD3(10, 10, 10), contactArea: 100, overhangArea: 0, surfaceArea: 600)
        XCTAssertFalse(plain.tippingProne)
        XCTAssertEqual(plain.tippingPenalty, 0)
    }

    // MARK: Overhangs past 50°

    func testOverhangShareAtFortyFiveIsUnchangedAndFiftyCountsOnlySteeperFaces() throws {
        // One face 48° from vertical, facing down: past Studio's 45°, within Slant's 50°.
        let gentle = STLMesh(vertices: [0, 0, 0, 0, 10, 9, 10, 0, 0], minimum: .zero, maximum: SIMD3(10, 10, 9))
        XCTAssertEqual(overhangShare(gentle).fraction, 1)
        XCTAssertEqual(overhangShare(gentle, limitDegrees: 50).fraction, 0)
        let steep = STLMesh(vertices: [0, 0, 0, 0, 10, 5, 10, 0, 0], minimum: .zero, maximum: SIMD3(10, 10, 5))
        XCTAssertEqual(overhangShare(steep, limitDegrees: 50).fraction, 1)
        let ledge = try exported(box(.zero, SIMD3(20, 5, 20)).union(box(SIMD3(0, 5, 15), SIMD3(20, 10, 5))))
        for mesh in [gentle, steep, ledge, try turnedAboutZ(ledge, degrees: 31)] {
            XCTAssertEqual(overhangShare(mesh, limitDegrees: 45), overhangShare(mesh))
        }
        let placed = ledge.orientationAssessment(.zUp)
        XCTAssertEqual(placed.steepOverhangArea, 200, accuracy: 0.5)
        XCTAssertEqual(Double(placed.steepOverhangArea), overhangShare(ledge, limitDegrees: 50).overhangAreaMM2, accuracy: 0.5)
    }

    // MARK: Advisories

    func testPlainBlockHasNoAdvisories() throws {
        XCTAssertEqual(printAdvisories(for: try exported(box(.zero, SIMD3(20, 20, 20))), placed: true, intent: PartIntent()), [])
    }

    func testThinPinIsReportedAndStandingPinIsSlenderForFunctionalParts() throws {
        let part = try exported(box(.zero, SIMD3(30, 30, 3)).union(post(x: 15, y: 15, z: 2.9, radius: 1, height: 12.1)))
        let advisories = advise(part, placed: true, intent: PartIntent())
        let pin = try XCTUnwrap(advisories.first { $0.kind == .thinPin })
        XCTAssertTrue(pin.message.contains("under 3 mm across can snap"), pin.message)
        XCTAssertEqual(pin.figure ?? 0, 2, accuracy: 0.3)
        let slender = try XCTUnwrap(advisories.first { $0.kind == .slenderUpright }, "\(advisories)")
        XCTAssertTrue(slender.message.contains("printed standing, parts like hooks have tested about half as strong as printed flat (CNC Kitchen)"))
        XCTAssertEqual(slender.location?.x ?? 0, 15, accuracy: 1.5)
        XCTAssertEqual(slender.location?.y ?? 0, 15, accuracy: 1.5)
        XCTAssertEqual(advisories, advise(part, placed: true, intent: PartIntent()), "Deterministic")
        // Decorative parts and unplaced meshes get no upright-feature note; the pin note stays.
        for (placed, intent) in [(true, PartIntent(purpose: .decorative)), (false, PartIntent())] {
            let found = kinds(advise(part, placed: placed, intent: intent))
            XCTAssertTrue(found.contains(.thinPin))
            XCTAssertFalse(found.contains(.slenderUpright))
        }
        // The same pin lying down isn't standing up.
        let lying = try exported(box(.zero, SIMD3(30, 30, 3)).union(box(SIMD3(5, 14, 2.9), SIMD3(20, 2, 2))))
        XCTAssertFalse(kinds(advise(lying, placed: true, intent: PartIntent())).contains(.slenderUpright))
    }

    func testWideStandingWallIsNotSlender() throws {
        // A 2 mm wall 60 mm wide and 40 mm tall: wider than it is tall, so it isn't a slender feature.
        let wall = try exported(box(.zero, SIMD3(60, 20, 3)).union(box(SIMD3(0, 9, 2.9), SIMD3(60, 2, 40.1))))
        XCTAssertFalse(kinds(advise(wall, placed: true, intent: PartIntent())).contains(.slenderUpright))
    }

    func testHoleCloseToAnEdgeIsReportedAndCentralHoleAndBossAreNot() throws {
        let plate = box(.zero, SIMD3(40, 20, 5))
        let part = try exported(plate.subtracting(post(x: 4, y: 10, z: -1, radius: 2, height: 7))
            .subtracting(post(x: 20, y: 10, z: -1, radius: 2, height: 7)))
        let index = try XCTUnwrap(TriangleRayIndex(part))
        let holes = try XCTUnwrap(verticalHolesNearEdges(part, index: index))
        XCTAssertEqual(holes.count, 1, "\(holes)")
        let hole = try XCTUnwrap(holes.first)
        XCTAssertEqual(hole.diameterMM, 4, accuracy: 0.05)
        XCTAssertEqual(hole.centre.x, 4, accuracy: 0.05)
        XCTAssertEqual(hole.edgeDistanceMM, 4, accuracy: 0.1)
        let advisory = try XCTUnwrap(advise(part, placed: true, intent: PartIntent()).first { $0.kind == .holeNearEdge })
        XCTAssertTrue(advisory.message.hasPrefix("⌀4.0 mm hole near X 4, Y 10, Z "), advisory.message)
        XCTAssertTrue(advisory.message.contains(": about 4.0 mm from its centre to the nearest edge (1.0 diameters). Studies of pin-loaded holes use about 3 diameters;"), advisory.message)
        XCTAssertFalse(kinds(advise(part, placed: true, intent: PartIntent(purpose: .decorative))).contains(.holeNearEdge))
        // A boss standing near the edge leaves a round loop too, but isn't a hole.
        let boss = try exported(plate.union(post(x: 4, y: 10, z: 4.9, radius: 2, height: 3.1)))
        XCTAssertEqual(verticalHolesNearEdges(boss, index: try XCTUnwrap(TriangleRayIndex(boss)))?.count, 0)
    }

    func testLargeSharpCorneredFootprintIsReportedAndRoundedOneIsNot() throws {
        let sharp = try exported(box(.zero, SIMD3(120, 40, 3)))
        let footprint = try XCTUnwrap(sharpFootprintCorners(sharp))
        XCTAssertEqual(footprint.corners, 4)
        XCTAssertEqual(footprint.lengthMM, 120, accuracy: 0.01)
        let advisory = try XCTUnwrap(advise(sharp, placed: true, intent: PartIntent()).first { $0.kind == .sharpFootprintCorners })
        XCTAssertEqual(advisory.message, "Large flat footprint, about 120 mm long, with 4 sharp corners. Large flat parts can lift at sharp corners (Slant uses no brims); rounding the corners helps.")
        XCTAssertNil(sharpFootprintCorners(try exported(box(.zero, SIMD3(80, 40, 3)))), "Under 100 mm")
        var rounded = box(SIMD3(5, 0, 0), SIMD3(110, 40, 3)).union(box(SIMD3(0, 5, 0), SIMD3(120, 30, 3)))
        for (x, y) in [(5.0, 5.0), (115.0, 5.0), (5.0, 35.0), (115.0, 35.0)] {
            rounded = rounded.union(post(x: x, y: y, z: 0, radius: 5, height: 3))
        }
        XCTAssertNil(sharpFootprintCorners(try exported(rounded)))
        XCTAssertFalse(kinds(advise(sharp, placed: false, intent: PartIntent())).contains(.sharpFootprintCorners))
    }

    func testPlacementAdvisoriesForSmallContactTippingAndSteepOverhangs() throws {
        let hook = try exported(box(.zero, SIMD3(4, 4, 30)).union(box(SIMD3(3.9, 0, 26), SIMD3(36.1, 4, 4))))
        let advisories = advise(hook, placed: true, intent: PartIntent())
        XCTAssertEqual(Array(kinds(advisories).prefix(3)), [.smallBedContact, .tipping, .steepOverhangs], "\(advisories)")
        XCTAssertTrue(advisories[0].message.contains("Add a flat base or plinth in Size and base."))
        XCTAssertTrue(advisories[2].message.contains("Slant’s 50° limit"))
        XCTAssertEqual(advisories[0].figure ?? 0, 16, accuracy: 0.01)
        let unplaced = kinds(advise(hook, placed: false, intent: PartIntent()))
        for kind in [PrintAdvisoryKind.smallBedContact, .tipping, .steepOverhangs] { XCTAssertFalse(unplaced.contains(kind)) }
    }

    func testAdvisoriesAreDedupedAndCapped() {
        func advisory(_ kind: PrintAdvisoryKind, _ n: Int) -> PrintAdvisory { PrintAdvisory(kind: kind, message: "\(kind.rawValue) \(n)") }
        let input = [advisory(.thinPin, 1), advisory(.thinPin, 1), advisory(.thinPin, 2), advisory(.thinPin, 3), advisory(.tipping, 1)]
            + (1...3).map { advisory(.holeNearEdge, $0) } + (1...3).map { advisory(.slenderUpright, $0) }
            + [advisory(.sharpFootprintCorners, 1), advisory(.steepOverhangs, 1), advisory(.smallBedContact, 1)]
        let capped = printAdvisoriesCapped(input)
        XCTAssertEqual(capped.count, printAdvisoryMaximumCount)
        XCTAssertEqual(kinds(capped), [.smallBedContact, .tipping, .steepOverhangs, .slenderUpright, .slenderUpright, .thinPin, .thinPin, .holeNearEdge])
        XCTAssertEqual(capped.filter { $0.kind == .thinPin }.map(\.message), ["thinPin 1", "thinPin 2"])
    }
}
