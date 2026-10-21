import XCTest
import simd
@testable import SlantStudio

final class ModelThumbnailAndTrashTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("SlantStudioThumbTrash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func cube(size: Float = 10) -> STLMesh {
        let p: [SIMD3<Float>] = [
            SIMD3(0, 0, 0), SIMD3(size, 0, 0), SIMD3(size, size, 0), SIMD3(0, size, 0),
            SIMD3(0, 0, size), SIMD3(size, 0, size), SIMD3(size, size, size), SIMD3(0, size, size)
        ]
        let faces: [(Int, Int, Int)] = [
            (0, 2, 1), (0, 3, 2), (4, 5, 6), (4, 6, 7), (0, 1, 5), (0, 5, 4),
            (1, 2, 6), (1, 6, 5), (2, 3, 7), (2, 7, 6), (3, 0, 4), (3, 4, 7)
        ]
        let vertices = faces.flatMap { [p[$0.0], p[$0.1], p[$0.2]] }.flatMap { [$0.x, $0.y, $0.z] }
        return STLMesh(vertices: vertices, minimum: .zero, maximum: SIMD3(repeating: size))
    }

    // MARK: Thumbnails

    func testThumbnailRendersOpaqueCentreAndTransparentCorners() throws {
        let size = 32
        let rgba = try XCTUnwrap(renderThumbnailRGBA(cube(), size: size))
        XCTAssertEqual(rgba.count, size * size * 4)
        func alpha(_ x: Int, _ y: Int) -> UInt8 { rgba[(y * size + x) * 4 + 3] }
        XCTAssertEqual(alpha(size / 2, size / 2), 255)
        XCTAssertEqual(alpha(0, 0), 0)
        XCTAssertEqual(alpha(size - 1, size - 1), 0)
        XCTAssertEqual(rgba, renderThumbnailRGBA(cube(), size: size), "rendering is deterministic")
        let png = try XCTUnwrap(thumbnailPNGData(rgba: rgba, size: size))
        XCTAssertEqual(Array(png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testThumbnailRejectsEmptyAndCancelledWork() {
        XCTAssertNil(renderThumbnailRGBA(STLMesh(vertices: [], minimum: .zero, maximum: .zero), size: 32))
        XCTAssertNil(renderThumbnailRGBA(cube(), size: 0))
        XCTAssertNil(renderThumbnailRGBA(cube(), size: 32, isCancelled: { true }))
        XCTAssertNil(thumbnailPNGData(rgba: [0, 0, 0], size: 32))
    }

    func testThumbnailFromFileHandlesMissingAndNonSTLFiles() throws {
        XCTAssertNil(renderModelThumbnailPNG(at: root.appendingPathComponent("missing.stl")))
        let obj = root.appendingPathComponent("part.obj")
        try Data("v 0 0 0\n".utf8).write(to: obj)
        XCTAssertNil(renderModelThumbnailPNG(at: obj))
        let stl = root.appendingPathComponent("cube.stl")
        try cube().binarySTL().write(to: stl)
        XCTAssertNotNil(renderModelThumbnailPNG(at: stl, size: 24))
    }

    func testThumbnailCurrencyFollowsModelModificationDate() {
        let now = Date()
        XCTAssertTrue(thumbnailIsCurrent(thumbnailModified: now, modelModified: now))
        XCTAssertTrue(thumbnailIsCurrent(thumbnailModified: now, modelModified: now.addingTimeInterval(-60)))
        XCTAssertFalse(thumbnailIsCurrent(thumbnailModified: now, modelModified: now.addingTimeInterval(60)))
        XCTAssertFalse(thumbnailIsCurrent(thumbnailModified: nil, modelModified: now))
        XCTAssertFalse(thumbnailIsCurrent(thumbnailModified: now, modelModified: nil))
        let id = UUID()
        XCTAssertEqual(ModelThumbnails.url(for: id, in: root).lastPathComponent, "\(id.uuidString).png")
        XCTAssertNotEqual(thumbnailVersion(path: "/a.stl", modified: now), thumbnailVersion(path: "/a.stl", modified: now.addingTimeInterval(1)))
    }

    func testPruneRemovesOnlyOrphanThumbnails() throws {
        let kept = UUID(), orphan = UUID()
        for name in ["\(kept.uuidString).png", "\(orphan.uuidString).png", "notes.png", "\(orphan.uuidString).txt"] {
            try Data([1]).write(to: root.appendingPathComponent(name))
        }
        XCTAssertEqual(pruneOrphanThumbnails(in: root, keeping: [kept]), 1)
        let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: root.path))
        XCTAssertEqual(remaining, ["\(kept.uuidString).png", "notes.png", "\(orphan.uuidString).txt"])
        XCTAssertEqual(pruneOrphanThumbnails(in: root.appendingPathComponent("absent"), keeping: []), 0)
        // Thumbnails written after the library snapshot belong to newer imports and are kept.
        let newer = UUID()
        try Data([1]).write(to: root.appendingPathComponent("\(newer.uuidString).png"))
        XCTAssertEqual(pruneOrphanThumbnails(in: root, keeping: [kept], writtenBefore: Date().addingTimeInterval(-3600)), 0)
    }

    func testLimiterBoundsConcurrency() async {
        let limiter = AsyncLimiter(limit: 2)
        actor Counter { var now = 0, peak = 0
            func enter() { now += 1; peak = max(peak, now) }
            func leave() { now -= 1 }
        }
        let counter = Counter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await limiter.acquire()
                    await counter.enter()
                    try? await Task.sleep(nanoseconds: 5_000_000)
                    await counter.leave()
                    await limiter.release()
                }
            }
        }
        let peak = await counter.peak
        XCTAssertLessThanOrEqual(peak, 2)
        XCTAssertGreaterThanOrEqual(peak, 1)
    }

    // MARK: Trash and undo

    private func libraryFile(_ name: String = "ABC.stl") throws -> URL {
        let folder = root.appendingPathComponent("Models", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data("solid x\nendsolid x\n".utf8).write(to: url)
        return url
    }

    /// Stands in for the system Trash so tests never touch the user's real one.
    private func fakeTrash(_ url: URL) throws -> URL? {
        let bin = root.appendingPathComponent("FakeTrash", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let target = bin.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }

    func testTrashUsesModelNameAndRestoresToLibraryLocation() throws {
        let original = try libraryFile()
        let staging = root.appendingPathComponent("Removed", isDirectory: true)
        let trashed = try moveLibraryFileToTrash(original, displayName: "Bracket: v2", stagingRoot: staging, trash: fakeTrash)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(trashed.trashedURL?.lastPathComponent, "Bracket- v2.stl")
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.trashedURL!.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [], "staging folder is cleaned up")

        try restoreLibraryFile(trashed, to: original, name: "Bracket")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: trashed.trashedURL!.path))
    }

    func testFailedTrashLeavesLibraryFileInPlace() throws {
        let original = try libraryFile()
        struct NoTrash: Error {}
        XCTAssertThrowsError(try moveLibraryFileToTrash(original, displayName: "Bracket", stagingRoot: root.appendingPathComponent("Removed"),
                                                        trash: { _ in throw NoTrash() }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testRestoreRefusesWhenTrashEmptiedOrDestinationTaken() throws {
        let original = try libraryFile()
        let trashed = try moveLibraryFileToTrash(original, displayName: "Bracket", stagingRoot: root.appendingPathComponent("Removed"), trash: fakeTrash)
        // Something else now sits at the library location: never overwritten.
        try Data([9]).write(to: original)
        XCTAssertThrowsError(try restoreLibraryFile(trashed, to: original, name: "Bracket")) { error in
            XCTAssertTrue(error.localizedDescription.contains("another file"))
        }
        XCTAssertEqual(try Data(contentsOf: original), Data([9]))
        try FileManager.default.removeItem(at: original)
        // Emptied Trash.
        try FileManager.default.removeItem(at: trashed.trashedURL!)
        XCTAssertThrowsError(try restoreLibraryFile(trashed, to: original, name: "Bracket")) { error in
            XCTAssertTrue(error.localizedDescription.contains("no longer in the Trash"))
        }
    }

    func testRestoreAcceptsFinderPutBack() throws {
        let original = try libraryFile()
        let trashed = try moveLibraryFileToTrash(original, displayName: "Bracket", stagingRoot: root.appendingPathComponent("Removed"), trash: fakeTrash)
        try FileManager.default.createDirectory(at: trashed.putBackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: trashed.trashedURL!, to: trashed.putBackURL)
        try restoreLibraryFile(trashed, to: original, name: "Bracket")
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
    }

    func testRestoredEntryKeepsPositionAndDropsDeletedCloudLink() {
        let model = LocalModel(name: "Bracket", filePath: "/x/ABC.stl", remoteID: "file-1")
        let removed = RemovedLibraryModel(model: model, index: 5, wasSelected: true, file: nil)
        let kept = restoredLibraryEntry(removed, deletedCloudFileIDs: [], currentCount: 8)
        XCTAssertEqual(kept.index, 5)
        XCTAssertEqual(kept.model.remoteID, "file-1")
        XCTAssertEqual(kept.model.id, model.id)
        let dropped = restoredLibraryEntry(removed, deletedCloudFileIDs: ["file-1"], currentCount: 2)
        XCTAssertEqual(dropped.index, 2, "clamped to the current library")
        XCTAssertNil(dropped.model.remoteID)
    }

    func testRemovalCopyMentionsTrashAndUndo() {
        let trashed = localModelRemovalMessage(name: "Bracket", isUploaded: false)
        XCTAssertTrue(trashed.contains("Trash"))
        XCTAssertTrue(trashed.contains("Edit › Undo"))
        XCTAssertTrue(trashed.contains("original file on your Mac isn’t touched"))
        let external = localModelRemovalMessage(name: "Bracket", isUploaded: true, movesToTrash: false)
        XCTAssertFalse(external.contains("Trash"))
        XCTAssertTrue(external.contains("stays in your Slant account"))
    }
}
