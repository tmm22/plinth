import XCTest
@testable import SlantStudio

final class ModelPreviewTests: XCTestCase {
    private let ascii = """
    solid triangle
    facet normal 0 0 1
      outer loop
        vertex -2 0 0
        vertex 1 0 0
        vertex 0 3 0
      endloop
    endfacet
    endsolid triangle
    """

    private func binary(header: String = "binary model", count: UInt32 = 1) -> Data {
        var data = Data(header.utf8.prefix(80))
        data.append(Data(repeating: 0, count: 80 - data.count))
        func appendWord(_ value: UInt32) {
            data.append(contentsOf: (0..<4).map { UInt8((value >> ($0 * 8)) & 255) })
        }
        appendWord(count)
        for value: Float in [0, 0, 1, -2, 0, 0, 1, 0, 0, 0, 3, 0] {
            appendWord(value.bitPattern)
        }
        data.append(contentsOf: [0, 0])
        return data
    }

    func testASCIIBoundsAndCoordinates() throws {
        let result = try STLMesh.parse(Data(ascii.utf8))
        XCTAssertEqual(result.triangleCount, 1)
        XCTAssertEqual(result.minimum, SIMD3<Float>(-2, 0, 0))
        XCTAssertEqual(result.maximum, SIMD3<Float>(1, 3, 0))
        XCTAssertEqual(result.vertices, [-2, 0, 0, 1, 0, 0, 0, 3, 0])
    }

    func testBinaryAndSolidPrefixedBinaryMatchASCII() throws {
        let expected = try STLMesh.parse(Data(ascii.utf8))
        for header in ["binary model", "solid binary header"] {
            let actual = try STLMesh.parse(binary(header: header))
            XCTAssertEqual(actual.vertices, expected.vertices)
            XCTAssertEqual(actual.minimum, expected.minimum)
            XCTAssertEqual(actual.maximum, expected.maximum)
        }
    }

    func testTruncatedAndUntrustedBinaryCountsAreRejected() {
        XCTAssertThrowsError(try STLMesh.parse(Data(binary().dropLast())))
        XCTAssertThrowsError(try STLMesh.parse(binary(count: UInt32.max)))
    }

    func testNonfiniteCoordinatesRejectedInBothFormats() {
        XCTAssertThrowsError(try STLMesh.parse(Data(ascii.replacingOccurrences(of: "-2", with: "nan").utf8)))
        var data = binary()
        let bits = Float.infinity.bitPattern
        for byte in 0..<4 { data[96 + byte] = UInt8((bits >> (byte * 8)) & 255) }
        XCTAssertThrowsError(try STLMesh.parse(data))
    }

    func testEmptyIncompleteAndNestedFacetsRejected() {
        for text in ["solid empty\nendsolid empty", ascii.replacingOccurrences(of: "vertex 0 3 0", with: ""),
                     ascii.replacingOccurrences(of: "outer loop", with: "facet normal 0 0 1")] {
            XCTAssertThrowsError(try STLMesh.parse(Data(text.utf8)))
        }
    }

    func testLongASCIILineRejectedBeforeTokenAllocation() {
        let source = "solid huge\n" + String(repeating: "vertex ", count: 10_000) + "\nendsolid huge"
        XCTAssertThrowsError(try STLMesh.parse(Data(source.utf8)))
    }

    func testPreviewTriangleLimitRejectsValidLengthBinary() {
        let count = STLMesh.maximumTriangles + 1
        var data = Data(repeating: 0, count: 84 + count * 50)
        for byte in 0..<4 { data[80 + byte] = UInt8((count >> (byte * 8)) & 255) }
        XCTAssertThrowsError(try STLMesh.parse(data)) { error in
            guard case STLMesh.ParseError.oversized = error else { return XCTFail("Unexpected error: \(error)") }
        }
    }
}
