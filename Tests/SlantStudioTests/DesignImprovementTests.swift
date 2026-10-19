import XCTest
import simd
@testable import SlantStudio

final class DesignImprovementTests: XCTestCase {
    private func cube() throws -> STLMesh {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try STLMesh.read(from: root.appendingPathComponent("assets/sample-cube.stl"))
    }

    private func assertClosed(_ mesh: STLMesh, file: StaticString = #filePath, line: UInt = #line) {
        var edges: [MeshEdge: Int] = [:]
        var directions: [MeshEdge: Int] = [:]
        for i in stride(from: 0, to: mesh.vertices.count, by: 9) {
            let points = [0, 3, 6].map { j in SIMD3(mesh.vertices[i + j], mesh.vertices[i + j + 1], mesh.vertices[i + j + 2]) }
            XCTAssertGreaterThan(simd_length(simd_cross(points[1] - points[0], points[2] - points[0])), 0, file: file, line: line)
            for j in 0..<3 {
                let a = points[j], b = points[(j + 1) % 3]
                let key = MeshEdge(a, b)
                edges[key, default: 0] += 1
                directions[key, default: 0] += key.a == a ? 1 : -1
            }
        }
        XCTAssertTrue(edges.values.allSatisfy { $0 == 2 }, file: file, line: line)
        XCTAssertTrue(directions.values.allSatisfy { $0 == 0 }, file: file, line: line)
    }

    func testRecognizesOnlyClosedUnmodifiedBox() throws {
        let mesh = try cube()
        XCTAssertTrue(mesh.edgeDesignCheck().plainBox)
        XCTAssertTrue(mesh.edgeDesignCheck().hasSharpJoins)
        XCTAssertFalse(mesh.edgeDesignCheck().hasTransitions)
        let open = STLMesh(vertices: Array(mesh.vertices.dropLast(9)), minimum: mesh.minimum, maximum: mesh.maximum)
        XCTAssertFalse(open.edgeDesignCheck().plainBox)
        XCTAssertThrowsError(try open.applyingEdgeImprovement(.bottomChamfer, size: 0.5))
        let duplicate = STLMesh(vertices: mesh.vertices + Array(mesh.vertices.prefix(9)), minimum: mesh.minimum, maximum: mesh.maximum)
        XCTAssertFalse(duplicate.edgeDesignCheck().plainBox)
    }

    func testBothEditsAreClosedPreserveEnvelopeAndAreNotAppliedTwice() throws {
        let original = try cube()
        for kind in EdgeImprovement.allCases {
            let edited = try original.applyingEdgeImprovement(kind, size: 0.5)
            XCTAssertEqual(edited.minimum, original.minimum)
            XCTAssertEqual(edited.maximum, original.maximum)
            assertClosed(edited)
            XCTAssertTrue(edited.edgeDesignCheck().hasTransitions)
            XCTAssertFalse(edited.edgeDesignCheck().plainBox)
            XCTAssertThrowsError(try edited.applyingEdgeImprovement(kind, size: 0.5))
            let restored = try STLMesh.parse(edited.binarySTL())
            XCTAssertEqual(restored.vertices, edited.vertices)
        }
    }

    func testChamferLeavesFlatInsetBaseAndExactFortyFiveDegreeBand() throws {
        let original = try cube()
        let r: Float = 0.5
        let edited = try original.applyingEdgeImprovement(.bottomChamfer, size: r)
        let assessment = try XCTUnwrap(edited.orientationAssessments().first { $0.orientation == .zUp })
        let size = original.maximum - original.minimum
        XCTAssertEqual(assessment.contactArea, (size.x - 2 * r) * (size.y - 2 * r), accuracy: 0.001)
        let bottomVertices = stride(from: 0, to: edited.vertices.count, by: 3).filter { edited.vertices[$0 + 2] == original.minimum.z }
        for i in bottomVertices {
            XCTAssertGreaterThanOrEqual(edited.vertices[i], original.minimum.x + r)
            XCTAssertLessThanOrEqual(edited.vertices[i], original.maximum.x - r)
            XCTAssertGreaterThanOrEqual(edited.vertices[i + 1], original.minimum.y + r)
            XCTAssertLessThanOrEqual(edited.vertices[i + 1], original.maximum.y - r)
        }
    }

    func testInvalidRadiusAndReversedShellAreRejected() throws {
        let original = try cube()
        for radius: Float in [0, -1, .nan, .infinity, 1000] {
            XCTAssertThrowsError(try original.applyingEdgeImprovement(.verticalFillet, size: radius))
        }
        var oneReversed = original.vertices
        for j in 0..<3 { oneReversed.swapAt(3 + j, 6 + j) }
        XCTAssertFalse(STLMesh(vertices: oneReversed, minimum: original.minimum, maximum: original.maximum).edgeDesignCheck().plainBox)
        var reversed = original.vertices
        for i in stride(from: 0, to: reversed.count, by: 9) {
            for j in 0..<3 { reversed.swapAt(i + 3 + j, i + 6 + j) }
        }
        XCTAssertFalse(STLMesh(vertices: reversed, minimum: original.minimum, maximum: original.maximum).edgeDesignCheck().plainBox)
    }

    func testRecipeMetadataRoundtripAndLoadAxisRemapping() throws {
        let intent = PartIntent(purpose: .bracket, load: .x)
        let recipe = PreparedPrintRecipe(sourceID: UUID(), sourceName: "source", intent: intent, orientation: .xUp, materialID: nil, created: Date())
        let record = DesignImprovementRecord(sourceID: UUID(), kind: .bottomChamfer, sizeMM: 0.5, created: Date())
        let model = LocalModel(name: "prepared", filePath: "/tmp/test.stl", partIntent: intent, printRecipe: recipe, designImprovement: record)
        XCTAssertEqual(designEditIntent(model)?.load, .z)
        let restored = try JSONDecoder().decode(LocalModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored.designImprovement, record)
        XCTAssertEqual(designEditIntent(restored)?.purpose, .bracket)
    }
}
