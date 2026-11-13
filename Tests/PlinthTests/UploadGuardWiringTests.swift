import XCTest
@testable import Plinth

/// Where the store's uploads call the guarded seams. `uploadModel` and Upload from URL need a `StudioStore`, which tests
/// never create, so their wiring is pinned in the source (SourceCheck.swift); the guard itself is driven through a
/// stubbed `APIClient` (APIClientTests, BatchPersonaliseTests).
final class UploadGuardWiringTests: XCTestCase {
    /// Models' uploads hand the pre-PUT guard every file the name check read plus every library model's link (less the
    /// file being replaced), and the Replace File, so `APIClient.upload` refuses before any bytes are sent.
    func testModelsUploadsPassTheirProtectedFilesAndReplacement() throws {
        let upload = try SourceCheck.body(of: "func uploadModel(id: UUID, as uploadName: String", in: SourceCheck.file("StudioStore.swift"))
        assertSourceContains(upload, "let guarded = uploadProtectedFilesAddingLibraryLinks(protectedFiles, models: localModels, replacing: replacing?.fileID)",
                             "Models' uploads protect every file the name check read and every library link, less the replaced file")
        assertSourceContains(upload, "protectedFiles: guarded, replacing: replacing,", "the guard inside APIClient.upload gets that list and the Replace File")
        assertSourceCount(upload, "client.upload(", 1, "one upload, never retried")
        assertSourceContains(upload, """
            onPlaceholder: { placeholder in
                target.value = uploadPlaceholderFileID(placeholder)
            })
            """, "the file Slant offered is recorded before the guard may refuse it, for the failure handling")
        XCTAssertTrue(upload.hasPrefix(SourceCheck.code("""
            func uploadModel(id: UUID, as uploadName: String, replacing: UploadReplacement?,
                             protectedFiles: [String: String]) async -> Bool {
            """)), "Source check: uploadModel's protected list and Replace File have no defaults, so every caller passes them")
    }

    /// A Replace File unlinks (and saves) before anything is sent: in Models' upload before `client.upload`, and in
    /// Upload from URL before its one `POST /files`.
    func testReplaceFileUnlinksBeforeTheUploadIsSent() throws {
        let store = try SourceCheck.file("StudioStore.swift")
        let upload = try SourceCheck.body(of: "func uploadModel(id: UUID, as uploadName: String", in: store)
        assertSourceOrder(upload, "let cleared = try clearLinksBeforeReplacing(fileID: replacedFileID, alsoUnlinking: capturedID)",
                          before: "try await client.upload(", "a Replace File unlinks every model from the file before the upload is sent")
        assertSourceCount(upload, "clearLinksBeforeReplacing(", 1, "Models' upload unlinks once, before sending")

        let url = try SourceCheck.body(of: "func importModelFromURL(", in: store)
        assertSourceOrder(url, "unlinkedBeforeSending = try clearLinksBeforeReplacing(fileID: replaced, alsoUnlinking: nil).otherNames",
                          before: #"try await client.request("POST", path: "/files", body: body)"#,
                          "Upload from URL's Replace File unlinks every model from the file before its POST is sent")
        assertSourceCount(url, "clearLinksBeforeReplacing(", 1, "Upload from URL unlinks once, before sending")
        assertSourceCount(url, "client.request(", 1, "one request, never retried")
    }

    /// Personalised uploads pass the runner's list plus this order's earlier uploads, and are never a Replace File.
    func testPersonalisedUploadsPassTheirProtectedFiles() throws {
        let run = try SourceCheck.body(of: "func batchPersonaliseMakeAndUpload(", in: SourceCheck.file("BatchPersonalise.swift"))
        assertSourceOrder(run, """
            var protected = hooks.protectedFiles()
            for id in fileIDs where protected[id] == nil { protected[id] = "" }
            """, before: "protectedFiles: protected, replacing: nil)",
            "personalised uploads protect the loaded files, library links and this order's earlier uploads")
    }

    /// The helper itself: comments don't count, formatting doesn't matter, and a missing body fails rather than skips.
    func testSourceChecksCompareCodeNotText() throws {
        XCTAssertEqual(SourceCheck.code("let a = 1 // a comment\n    let url = \"https://example.com\"  // another\n// whole line\nlet b = 2"),
                       "let a = 1 let url = \"https://example.com\" let b = 2")
        XCTAssertEqual(SourceCheck.code("x(a,\n      b)"), "x(a, b)")
        XCTAssertEqual(try SourceCheck.body(of: "func f(g: () -> Void = { }) {", in: SourceCheck.code("func f(g: () -> Void = { }) { let s = \"}\"; if x { y } } func h() {}")),
                       "func f(g: () -> Void = { }) { let s = \"}\"; if x { y } }")
        XCTAssertThrowsError(try SourceCheck.body(of: "func missing(", in: "func present() {}"))
        XCTAssertThrowsError(try SourceCheck.body(of: "func open(", in: "func open() { if x {"))
    }
}
