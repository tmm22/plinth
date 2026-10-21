import Foundation

/// Where a removed library file went, so Edit › Undo can bring it back during the session.
struct TrashedLibraryFile: Equatable, Sendable {
    /// The file's location in the Trash, when the system reported it.
    let trashedURL: URL?
    /// Where Finder's Put Back returns the file (a named copy in Slant Studio's support folder).
    let putBackURL: URL
}

/// A removed library entry and everything needed to restore it.
struct RemovedLibraryModel {
    let model: LocalModel
    let index: Int
    let wasSelected: Bool
    /// Nil when the entry pointed at a file outside the app's library folder, which is never moved.
    let file: TrashedLibraryFile?
}

enum LibraryTrashError: LocalizedError {
    case notInTrash(String)
    case destinationOccupied(String)
    /// Trashing failed and the file couldn't be moved back; it is kept, renamed, at this path.
    case keptAt(path: String, underlying: String)
    var errorDescription: String? {
        switch self {
        case .keptAt(let path, let underlying):
            return "\(underlying) Its file couldn’t be moved back into the library and is kept at \(path)."
        case .notInTrash(let name):
            return "“\(name)” couldn’t be restored because its file is no longer in the Trash. If you still have it, import it again."
        case .destinationOccupied(let name):
            return "“\(name)” couldn’t be restored because another file is already at its library location."
        }
    }
}

/// Moves an item to the macOS Trash and returns its new location.
func moveItemToSystemTrash(_ url: URL) throws -> URL? {
    var result: NSURL?
    try FileManager.default.trashItem(at: url, resultingItemURL: &result)
    return result as URL?
}

/// Moves a library file to the Trash under the model's name (library files use internal names), so it can be
/// recognised there. The file is renamed inside `stagingRoot` first; if trashing fails it is put back and the
/// error rethrown, so the library file is never lost.
func moveLibraryFileToTrash(_ url: URL, displayName: String, stagingRoot: URL,
                            trash: (URL) throws -> URL? = moveItemToSystemTrash) throws -> TrashedLibraryFile {
    let manager = FileManager.default
    let folder = stagingRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try manager.createDirectory(at: folder, withIntermediateDirectories: true)
    let named = folder.appendingPathComponent(exportFileName(modelName: displayName, fileExtension: url.pathExtension))
    // Only ever delete the staging folder when it is empty, so a failure can never take the library file with it.
    func removeFolderIfEmpty() {
        if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? manager.removeItem(at: folder) }
    }
    do {
        try manager.moveItem(at: url, to: named)
    } catch {
        removeFolderIfEmpty()
        throw error
    }
    let trashed: URL?
    do {
        trashed = try trash(named)
    } catch {
        do {
            try manager.moveItem(at: named, to: url)
        } catch {
            removeFolderIfEmpty()
            throw LibraryTrashError.keptAt(path: named.path, underlying: error.localizedDescription)
        }
        removeFolderIfEmpty()
        throw error
    }
    removeFolderIfEmpty()
    return TrashedLibraryFile(trashedURL: trashed, putBackURL: named)
}

/// Moves a trashed library file back to its library location. Also accepts a file the user already put back
/// from Finder. Never overwrites an existing file.
func restoreLibraryFile(_ file: TrashedLibraryFile, to original: URL, name: String) throws {
    let manager = FileManager.default
    guard !manager.fileExists(atPath: original.path) else { throw LibraryTrashError.destinationOccupied(name) }
    let candidates = [file.trashedURL, file.putBackURL].compactMap { $0 }
    guard let source = candidates.first(where: { manager.fileExists(atPath: $0.path) }) else {
        throw LibraryTrashError.notInTrash(name)
    }
    try manager.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
    try manager.moveItem(at: source, to: original)
    if source == file.putBackURL {
        let folder = source.deletingLastPathComponent()
        if (try? manager.contentsOfDirectory(atPath: folder.path))?.isEmpty == true { try? manager.removeItem(at: folder) }
    }
}

/// The entry to put back: same position (clamped), and no link to a Slant file deleted since it was removed.
func restoredLibraryEntry(_ removed: RemovedLibraryModel, deletedCloudFileIDs: Set<String>, currentCount: Int) -> (model: LocalModel, index: Int) {
    var model = removed.model
    if let remote = model.remoteID, deletedCloudFileIDs.contains(remote) { model.remoteID = nil }
    return (model, min(max(0, removed.index), currentCount))
}
