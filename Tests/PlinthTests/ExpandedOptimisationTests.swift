import XCTest
import simd
@testable import SlantStudio

final class ExpandedOptimisationTests: XCTestCase {
    func testTiltedBoxFindsFlatPlacementAndPreservesEdges() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let cube = try STLMesh.read(from: root.appendingPathComponent("assets/sample-cube.stl"))
        let rotation = simd_quatf(angle: 0.62, axis: simd_normalize(SIMD3<Float>(1, 2, 3)))
        var vertices: [Float] = []
        for i in stride(from: 0, to: cube.vertices.count, by: 3) {
            let p = rotation.act(SIMD3(cube.vertices[i] * 2, cube.vertices[i + 1], cube.vertices[i + 2] * 3))
            vertices += [p.x, p.y, p.z]
        }
        let mesh = try STLMesh.parse(STLMesh(vertices: vertices, minimum: .zero, maximum: .one).binarySTL())
        let assessments = mesh.orientationAssessments()
        XCTAssertFalse(assessments.prefix(6).contains { $0.hasFlatContact })
        let chosen = try XCTUnwrap(preferredOrientation(assessments, intent: PartIntent()))
        XCTAssertTrue(chosen.hasFlatContact)
        XCTAssertLessThanOrEqual(assessments.count, 30)
        XCTAssertEqual(mesh.placementCandidates(), mesh.placementCandidates())
        let prepared = try STLMesh.parse(mesh.oriented(chosen.orientation).binarySTL())
        XCTAssertEqual(prepared.minimum.z, 0)
        XCTAssertEqual(prepared.triangleCount, mesh.triangleCount)
        for i in stride(from: 0, to: vertices.count, by: 9) {
            func point(_ values: [Float], _ j: Int) -> SIMD3<Float> { SIMD3(values[i+j], values[i+j+1], values[i+j+2]) }
            for (a, b) in [(0,3), (3,6), (6,0)] {
                XCTAssertEqual(simd_distance(point(vertices, a), point(vertices, b)), simd_distance(point(prepared.vertices, a), point(prepared.vertices, b)), accuracy: 0.0001)
            }
        }
        let r = chosen.orientation
        XCTAssertEqual(simd_dot(simd_cross(r.rotate(SIMD3(1,0,0)), r.rotate(SIMD3(0,1,0))), r.rotate(SIMD3(0,0,1))), 1, accuracy: 0.00001)
    }

    func testOldAndNewRecipesDecode() throws {
        XCTAssertEqual(try JSONDecoder().decode(PrintOrientation.self, from: Data("\"xUp\"".utf8)), .xUp)
        let orientation = PrintOrientation.face(simd_normalize(SIMD3<Float>(1, 2, 3)))
        XCTAssertEqual(try JSONDecoder().decode(PrintOrientation.self, from: JSONEncoder().encode(orientation)), orientation)
        XCTAssertThrowsError(try JSONDecoder().decode(PrintOrientation.self, from: Data("[0,0,0]".utf8)))
        let oldIntent = Data("{\"purpose\":\"Enclosure\",\"details\":\"\",\"load\":\"Not specified\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(PartIntent.self, from: oldIntent).materialGoal)
        let intent = PartIntent(materialGoal: .impact)
        XCTAssertEqual(try JSONDecoder().decode(PartIntent.self, from: JSONEncoder().encode(intent)), intent)
    }

    func testMaterialRecommendationsRequireKnownProfileAndAvailability() {
        let records = [
            Record(values: ["id":"a", "profile":"PLA", "available":true]),
            Record(values: ["id":"b", "profile":"PETG", "available":true]),
            Record(values: ["id":"c", "profile":"PETG", "available":false]),
            Record(values: ["id":"d", "profile":"PETG"]),
            Record(values: ["id":"e", "profile":"PETG-CF", "available":true]),
            Record(values: ["id":"f", "profile":"OPM", "available":true])
        ]
        XCTAssertEqual(recommendedMaterials(for: .rigid, in: records).map(\.id), ["a"])
        XCTAssertEqual(recommendedMaterials(for: .impact, in: records).map(\.id), ["b"])
        // Outdoors, sun or warmth: OPM first, then PETG.
        XCTAssertEqual(recommendedMaterials(for: .warm, in: records).map(\.id), ["f", "b"])
        for goal in [MaterialGoal.keepCurrent, .repeatedFlex] {
            XCTAssertTrue(recommendedMaterials(for: goal, in: records).isEmpty)
        }
        XCTAssertTrue(recommendedMaterials(for: .rigid, in: []).isEmpty)
    }

    func testObliqueLoadIsNotSilentlyRemappedToAnAxis() {
        let recipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "tilted", intent: PartIntent(purpose: .bracket, load: .x), orientation: .face(simd_normalize(SIMD3<Float>(1,2,3))), materialID: nil, created: Date())
        let model = LocalModel(name: "prepared", filePath: "/tmp/prepared.stl", printRecipe: recipe)
        XCTAssertEqual(designEditIntent(model)?.load, .unknown)
    }
}
