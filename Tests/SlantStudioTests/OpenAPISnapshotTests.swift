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
                if let source = dictionary[Self.sourceTag], !["docs", "live"].contains(source as? String ?? "") {
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

    static let sourceTag = "x-slant-studio-source"

    /// JSON-pointer-like paths of every source tag at the document root or directly inside a name map (`paths`,
    /// `properties`, `encoding`…, the app's `slantAPINameMapKeys`), where it would read as a path or property name and,
    /// in `check-slant-api.py`, exempt everything below it. Name maps are tracked as the app's comparison tracks them.
    static func misplacedSourceTags(_ value: Any, path: String = "", isNameMap: Bool = false) -> [String] {
        if let dictionary = value as? [String: Any] {
            var found = dictionary[sourceTag] != nil && (isNameMap || path.isEmpty) ? [path.isEmpty ? "/" : path] : []
            for (key, child) in dictionary.sorted(by: { $0.key < $1.key }) {
                let childIsNameMap = !isNameMap && slantAPINameMapKeys.contains(key) && child is [String: Any]
                found += misplacedSourceTags(child, path: path + "/" + key, isNameMap: childIsNameMap)
            }
            return found
        }
        if let array = value as? [Any] {
            return array.enumerated().flatMap { misplacedSourceTags($0.element, path: path + "/\($0.offset)") }
        }
        return []
    }

    func testStudioSourceTagsAreNeverPlacedInANameMap() throws {
        XCTAssertEqual(Self.misplacedSourceTags(try document("openapi")), [],
                       "put each tag on the entry that holds the fact, never directly in paths, properties or another name map")
    }

    func testMisplacedSourceTagsAreFound() {
        let spec: [String: Any] = [
            Self.sourceTag: "docs",
            "paths": [
                Self.sourceTag: "live",
                "/orders": ["get": [
                    Self.sourceTag: "docs",
                    "parameters": [["name": "status", "in": "query", Self.sourceTag: "live"]],
                    "requestBody": ["content": ["multipart/form-data": [
                        "encoding": [Self.sourceTag: "docs", "file": ["contentType": "text/plain"]],
                        "schema": ["properties": [
                            Self.sourceTag: "docs",
                            "properties": [Self.sourceTag: "docs", "type": "object"],
                            "note": [Self.sourceTag: "docs", "type": "string"]
                        ]]
                    ]]]
                ]]
            ],
            "components": [Self.sourceTag: "docs", "schemas": ["Order": [Self.sourceTag: "live"]]]
        ]
        XCTAssertEqual(Self.misplacedSourceTags(spec), [
            "/",
            "/paths",
            "/paths//orders/get/requestBody/content/multipart/form-data/encoding",
            "/paths//orders/get/requestBody/content/multipart/form-data/schema/properties"
        ])
    }

    func testOrdersEndDateIsADateAsSlantSays() throws {
        let get = try XCTUnwrap(((document("openapi")["paths"] as? [String: Any])?["/orders"] as? [String: Any])?["get"] as? [String: Any])
        let endDate = try XCTUnwrap((get["parameters"] as? [[String: Any]])?.first { $0["name"] as? String == "endDate" })
        XCTAssertEqual((endDate["schema"] as? [String: Any])?["format"] as? String, "date")
    }
}
