import XCTest
@testable import Plinth

/// Where the store's uploads call the guarded seams. `uploadModel` and Upload from URL need a `StudioStore`, which tests
/// never create, so their wiring is pinned in the source; the guard itself is driven through a stubbed `APIClient`
/// (APIClientTests, BatchPersonaliseTests).
final class UploadGuardWiringTests: XCTestCase {
    /// Models' uploads hand the pre-PUT guard every file the name check read plus every library model's link (less the
    /// file being replaced), and the Replace File, so `APIClient.upload` refuses before any bytes are sent.
    func testModelsUploadsPassTheirProtectedFilesAndReplacement() throws {
        let upload = try functionBody("func uploadModel(id: UUID, as uploadName: String", in: try source("StudioStore.swift"))
        XCTAssertTrue(upload.contains("let guarded = uploadProtectedFilesAddingLibraryLinks(protectedFiles, models: localModels, replacing: replacing?.fileID)"))
        XCTAssertTrue(upload.contains("protectedFiles: guarded, replacing: replacing,"))
        XCTAssertEqual(upload.components(separatedBy: "client.upload(").count, 2, "one upload, never retried")
        // The file Slant offered is recorded before the guard may refuse it, for the failure handling.
        XCTAssertTrue(upload.contains("onPlaceholder: { placeholder in\n                target.value = uploadPlaceholderFileID(placeholder)\n            })"))
        // No default protected list: every caller passes one.
        XCTAssertTrue(upload.hasPrefix("func uploadModel(id: UUID, as uploadName: String, replacing: UploadReplacement?,\n                     protectedFiles: [String: String]) async -> Bool {"))
    }

    /// A Replace File unlinks (and saves) before anything is sent: in Models' upload before `client.upload`, and in
    /// Upload from URL before its one `POST /files`.
    func testReplaceFileUnlinksBeforeTheUploadIsSent() throws {
        let store = try source("StudioStore.swift")
        let upload = try functionBody("func uploadModel(id: UUID, as uploadName: String", in: store)
        let unlinkModels = try XCTUnwrap(upload.range(of: "let cleared = try clearLinksBeforeReplacing(fileID: replacedFileID, alsoUnlinking: capturedID)"))
        let sendModels = try XCTUnwrap(upload.range(of: "try await client.upload("))
        XCTAssertLessThan(unlinkModels.lowerBound, sendModels.lowerBound)
        XCTAssertEqual(upload.components(separatedBy: "clearLinksBeforeReplacing(").count, 2)

        let url = try functionBody("func importModelFromURL(", in: store)
        let unlinkURL = try XCTUnwrap(url.range(of: "unlinkedBeforeSending = try clearLinksBeforeReplacing(fileID: replaced, alsoUnlinking: nil).otherNames"))
        let sendURL = try XCTUnwrap(url.range(of: #"try await client.request("POST", path: "/files", body: body)"#))
        XCTAssertLessThan(unlinkURL.lowerBound, sendURL.lowerBound)
        XCTAssertEqual(url.components(separatedBy: "clearLinksBeforeReplacing(").count, 2)
        XCTAssertEqual(url.components(separatedBy: "client.request(").count, 2, "one request, never retried")
    }

    /// Personalised uploads pass the runner's list plus this order's earlier uploads, and are never a Replace File.
    func testPersonalisedUploadsPassTheirProtectedFiles() throws {
        let run = try functionBody("func batchPersonaliseMakeAndUpload(", in: try source("BatchPersonalise.swift"))
        let gather = try XCTUnwrap(run.range(of: "var protected = hooks.protectedFiles()\n        for id in fileIDs where protected[id] == nil { protected[id] = \"\" }"))
        let send = try XCTUnwrap(run.range(of: "protectedFiles: protected, replacing: nil)"))
        XCTAssertLessThan(gather.lowerBound, send.lowerBound)
    }

    // MARK: Helpers

    private func source(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/Plinth").appendingPathComponent(name)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The text from `signature` to the brace that closes its body, which opens at the first `{` from `signature` on.
    private func functionBody(_ signature: String, in source: String) throws -> String {
        let start = try XCTUnwrap(source.range(of: signature), signature)
        let open = try XCTUnwrap(source[start.lowerBound...].firstIndex(of: "{"), signature)
        var depth = 0
        var index = open
        while index < source.endIndex {
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[start.lowerBound...index]) }
            }
            index = source.index(after: index)
        }
        throw XCTSkip("unbalanced braces after \(signature)")
    }
}
