import XCTest
import simd
@testable import SlantStudio

final class PrintOrientationTests: XCTestCase {
    private func box() throws -> STLMesh {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cube = try STLMesh.read(from: root.appendingPathComponent("assets/sample-cube.stl"))
        var vertices = cube.vertices
        for i in stride(from: 0, to: vertices.count, by: 3) {
            vertices[i] = vertices[i] * 2 + 7
            vertices[i + 1] += 3
            vertices[i + 2] = vertices[i + 2] * 3 - 4
        }
        // Roundtrip recalculates bounds for the scaled fixture.
        return try STLMesh.parse(STLMesh(vertices: vertices, minimum: .zero, maximum: .one).binarySTL())
    }

    func testRotationsPreserveHandednessAndDistances() {
        let a = SIMD3<Float>(2, -3, 7), b = SIMD3<Float>(-4, 5, 1)
        for orientation in PrintOrientation.allCases {
            XCTAssertEqual(simd_length(orientation.rotate(a) - orientation.rotate(b)), simd_length(a - b), accuracy: 0.0001)
            XCTAssertEqual(simd_cross(orientation.rotate(SIMD3(1, 0, 0)), orientation.rotate(SIMD3(0, 1, 0))), orientation.rotate(SIMD3(0, 0, 1)))
        }
    }

    func testPreparedSTLRoundtripsAtBedWithoutChangingDimensionsOrVolume() throws {
        let source = try box()
        let size = source.maximum - source.minimum
        for orientation in PrintOrientation.allCases {
            let rotated = source.oriented(orientation)
            let parsed = try STLMesh.parse(rotated.binarySTL())
            XCTAssertEqual(parsed.minimum, .zero)
            XCTAssertEqual(parsed.triangleCount, source.triangleCount)
            XCTAssertEqual(parsed.vertices, rotated.vertices)
            XCTAssertEqual(parsed.maximum.x * parsed.maximum.y * parsed.maximum.z, size.x * size.y * size.z, accuracy: 0.01)
        }
    }

    func testBoxHasContactAndNoUnsupportedOverhangs() throws {
        let assessments = try box().orientationAssessments()
        XCTAssertEqual(assessments.count, 6)
        for assessment in assessments {
            XCTAssertGreaterThan(assessment.contactArea, 0)
            XCTAssertEqual(assessment.contactRatio, 1, accuracy: 0.0001)
            XCTAssertEqual(assessment.overhangArea, 0, accuracy: 0.0001)
            XCTAssertTrue(assessment.fits)
        }
    }

    func testStrengthPreferenceKeepsKnownTensileLoadInPlane() throws {
        let assessments = try box().orientationAssessments()
        for load in [PrintLoadAxis.x, .y, .z] {
            let best = try XCTUnwrap(assessments.min { $0.score(priority: .strength, load: load) < $1.score(priority: .strength, load: load) })
            XCTAssertEqual(best.orientation.rotate(try XCTUnwrap(load.vector)).z, 0)
        }
    }

    func testOversizeAndZeroContactArePenalized() {
        let good = OrientationAssessment(orientation: .zUp, size: SIMD3(10, 10, 10), contactArea: 100, overhangArea: 0, surfaceArea: 600)
        let oversized = OrientationAssessment(orientation: .xUp, size: SIMD3(221, 10, 10), contactArea: 100, overhangArea: 0, surfaceArea: 600)
        let pointContact = OrientationAssessment(orientation: .yUp, size: SIMD3(10, 10, 10), contactArea: 0, overhangArea: 0, surfaceArea: 600)
        XCTAssertFalse(oversized.fits)
        XCTAssertLessThan(good.score(priority: .economy, load: .unknown), oversized.score(priority: .economy, load: .unknown))
        XCTAssertLessThan(good.score(priority: .economy, load: .unknown), pointContact.score(priority: .economy, load: .unknown))
    }
    func testPurposeRequiresDirectionForFunctionalParts() throws {
        let assessments = try box().orientationAssessments()
        for purpose in [PartPurpose.bracket, .clip, .custom] {
            var intent = PartIntent(purpose: purpose, details: "Spring latch")
            XCTAssertNil(preferredOrientation(assessments, intent: intent))
            intent.load = .z
            let chosen = try XCTUnwrap(preferredOrientation(assessments, intent: intent))
            XCTAssertEqual(chosen.orientation.rotate(SIMD3(0, 0, 1)).z, 0)
        }
        XCTAssertFalse(PartIntent(purpose: .custom, details: "  ", load: .x).isReady)
    }

    func testDecorativeDoesNotUsePreviouslySelectedStructuralLoad() throws {
        let assessments = try box().orientationAssessments()
        let withoutLoad = preferredOrientation(assessments, intent: PartIntent(purpose: .decorative))
        let withOldLoad = preferredOrientation(assessments, intent: PartIntent(purpose: .decorative, load: .x))
        XCTAssertEqual(withoutLoad?.orientation, withOldLoad?.orientation)
    }

    func testNoPreparedPlacementWhenAllCandidatesExceedVolume() {
        let oversized = OrientationAssessment(orientation: .zUp, size: SIMD3(300, 10, 10), contactArea: 100, overhangArea: 0, surfaceArea: 600)
        XCTAssertNil(preferredOrientation([oversized], intent: PartIntent()))
        XCTAssertNil(preferredOrientation([], intent: PartIntent()))
    }

    func testLegacyLibraryAndPreparedRecipeRoundtrip() throws {
        let oldModel = LocalModel(name: "original", filePath: "/tmp/original.stl")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldModel)) as? [String: Any])
        json.removeValue(forKey: "partIntent")
        json.removeValue(forKey: "printRecipe")
        let legacy = try JSONDecoder().decode(LocalModel.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(legacy.partIntent)
        XCTAssertNil(legacy.printRecipe)
        let intent = PartIntent(purpose: .clip, details: "Retaining clip", load: .y)
        let recipe = PreparedPrintRecipe(sourceID: legacy.id, sourceName: legacy.name, intent: intent,
                                         orientation: .xUp, materialID: "chosen-material", created: Date())
        let prepared = LocalModel(name: "prepared", filePath: "/tmp/prepared.stl", partIntent: intent, printRecipe: recipe)
        let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(prepared))
        XCTAssertEqual(restored.printRecipe, recipe)
        XCTAssertEqual(restored.partIntent, intent)
        XCTAssertNil(restored.remoteID)
        XCTAssertNotEqual(restored.id, legacy.id)
    }

    func testPreparedMeshPreservesEveryTriangleEdgeLength() throws {
        let source = try box()
        for orientation in PrintOrientation.allCases {
            let prepared = try STLMesh.parse(source.oriented(orientation).binarySTL())
            for i in stride(from: 0, to: source.vertices.count, by: 9) {
                func point(_ vertices: [Float], _ offset: Int) -> SIMD3<Float> {
                    SIMD3(vertices[i + offset], vertices[i + offset + 1], vertices[i + offset + 2])
                }
                for (a, b) in [(0, 3), (3, 6), (6, 0)] {
                    XCTAssertEqual(simd_distance(point(source.vertices, a), point(source.vertices, b)),
                                   simd_distance(point(prepared.vertices, a), point(prepared.vertices, b)), accuracy: 0.00001)
                }
            }
        }
    }

    func testPointContactIsNotSelectedEvenWhenItHasNoOverhangPenalty() {
        let point = OrientationAssessment(orientation: .zUp, size: SIMD3(10, 10, 10), contactArea: 0, overhangArea: 0, surfaceArea: 100)
        let flat = OrientationAssessment(orientation: .zDown, size: SIMD3(10, 10, 10), contactArea: 25, overhangArea: 80, surfaceArea: 100)
        XCTAssertEqual(preferredOrientation([point, flat], intent: PartIntent())?.orientation, .zDown)
        XCTAssertNil(preferredOrientation([point], intent: PartIntent()))
    }

    func testPointDownTetrahedronIsPlacedOnItsFlatBase() throws {
        let points: [SIMD3<Float>] = [SIMD3(0, 0, 0), SIMD3(5, 0, 10), SIMD3(0, 5, 10), SIMD3(-5, -5, 10)]
        let vertices = [[0, 2, 1], [0, 3, 2], [0, 1, 3], [1, 2, 3]].flatMap { triangle in
            triangle.flatMap { index in [points[index].x, points[index].y, points[index].z] }
        }
        let mesh = STLMesh(vertices: vertices, minimum: SIMD3(-5, -5, 0), maximum: SIMD3(5, 5, 10))
        let assessments = mesh.orientationAssessments()
        XCTAssertEqual(assessments.first { $0.orientation == .zUp }?.contactArea, 0)
        let selected = try XCTUnwrap(preferredOrientation(assessments, intent: PartIntent(purpose: .decorative)))
        let originalBase = try XCTUnwrap(assessments.first { $0.orientation == .zDown })
        XCTAssertLessThanOrEqual(selected.score(priority: .economy, load: .unknown), originalBase.score(priority: .economy, load: .unknown))
        XCTAssertGreaterThan(selected.contactArea, 0)
        XCTAssertEqual(mesh.oriented(selected.orientation).minimum.z, 0)
    }

    func testNearBedSlopedFaceIsNotCountedAsFlatContact() throws {
        let vertices: [Float] = [0, 0, 0, 10, 0, 0, 0, 10, 0.005]
        let mesh = STLMesh(vertices: vertices, minimum: .zero, maximum: SIMD3(10, 10, 0.005))
        let original = try XCTUnwrap(mesh.orientationAssessments().first { $0.orientation == .zUp })
        XCTAssertEqual(original.contactArea, 0)
    }

    func testNarrowContactIsLessStableAtSameHeightAndContactArea() {
        let broad = OrientationAssessment(orientation: .zUp, size: SIMD3(20, 20, 40), contactArea: 100, overhangArea: 0, surfaceArea: 1000, contactWidth: 10)
        let narrow = OrientationAssessment(orientation: .zDown, size: SIMD3(20, 20, 40), contactArea: 100, overhangArea: 0, surfaceArea: 1000, contactWidth: 1)
        XCTAssertLessThan(broad.score(priority: .balanced, load: .unknown), narrow.score(priority: .balanced, load: .unknown))
    }

    func testPreviewBedMatchesTransformedBottomForAllPlacements() throws {
        let mesh = try box()
        for orientation in PrintOrientation.allCases {
            let prepared = mesh.oriented(orientation)
            let extent = prepared.maximum - prepared.minimum
            let center = (prepared.maximum + prepared.minimum) / 2
            let renderedBottom = (prepared.minimum.z - center.z) * (8 / extent.max())
            XCTAssertEqual(previewBedHeight(prepared), renderedBottom, accuracy: 0.000001)
        }
    }

}
