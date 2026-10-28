import XCTest
@testable import SlantStudio

/// Studio's patched `openapi.json` and the snapshot of Slant's live spec (`slant-openapi-upstream.json`) are both
/// bundled. `scripts/check-slant-api.py` compares them in detail; these tests keep the basics true in every build.
final class OpenAPISnapshotTests: XCTestCase {
    private static let methods: Set<String> = ["get", "put", "post", "delete", "patch", "head", "options", "trace"]

    private func document(_ name: String) throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json"), "\(name).json is not bundled")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        return try XCTUnwrap(object as? [String: Any], "\(name).json is not a JSON object")
    }

    private func operations(_ document: [String: Any]) throws -> Set<String> {
        let paths = try XCTUnwrap(document["paths"] as? [String: Any], "no paths")
        var result: Set<String> = []
        for (path, item) in paths {
            guard let item = item as? [String: Any] else { continue }
            for method in item.keys where Self.methods.contains(method) { result.insert(method.uppercased() + " " + path) }
        }
        return result
    }

    func testBothSpecsLoadFromTheBundle() throws {
        let studio = try document("openapi")
        let upstream = try document("slant-openapi-upstream")
        XCTAssertEqual(studio["openapi"] as? String, upstream["openapi"] as? String)
        XCTAssertFalse(try operations(upstream).isEmpty)
        XCTAssertFalse(EndpointCatalog.load().isEmpty, "the Workbench must still read Studio's spec")
    }

    func testStudioKeepsEveryOperationInSlantsSpec() throws {
        let studio = try operations(document("openapi"))
        let upstream = try operations(document("slant-openapi-upstream"))
        let lost = upstream.subtracting(studio).sorted()
        XCTAssertTrue(lost.isEmpty, "Studio's openapi.json has lost \(lost); Studio may add operations, never drop Slant's")
        let catalog = Set(EndpointCatalog.load().map(\.id))
        let unlisted = upstream.filter { !["HEAD", "OPTIONS", "TRACE"].contains(String($0.prefix { $0 != " " })) }.subtracting(catalog).sorted()
        XCTAssertTrue(unlisted.isEmpty, "the Workbench doesn't list \(unlisted)")
    }

    func testStudioSourceTagsAreDocsOrLive() throws {
        var bad: [String] = []
        func walk(_ value: Any, _ path: String) {
            if let dictionary = value as? [String: Any] {
                if let source = dictionary["x-slant-studio-source"], !["docs", "live"].contains(source as? String ?? "") {
                    bad.append(path)
                }
                for (key, child) in dictionary { walk(child, path + "/" + key) }
            } else if let array = value as? [Any] {
                for (index, child) in array.enumerated() { walk(child, path + "/\(index)") }
            }
        }
        walk(try document("openapi"), "")
        XCTAssertEqual(bad, [])
    }

    func testOrdersEndDateIsADateAsSlantSays() throws {
        let get = try XCTUnwrap(((document("openapi")["paths"] as? [String: Any])?["/orders"] as? [String: Any])?["get"] as? [String: Any])
        let endDate = try XCTUnwrap((get["parameters"] as? [[String: Any]])?.first { $0["name"] as? String == "endDate" })
        XCTAssertEqual((endDate["schema"] as? [String: Any])?["format"] as? String, "date")
    }
}
