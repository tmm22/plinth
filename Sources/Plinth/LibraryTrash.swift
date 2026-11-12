import Foundation

/// Where a removed library file went, so Edit › Undo can bring it back during the session.
struct TrashedLibraryFile: Equatable, Sendable {
    /// The file's location in the Trash, when the system reported it.
    let trashedURL: URL?
    /// Where Finder's Put Back returns the file (a named copy in Plinth's support folder).
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

/// The entry to put back: same position (clamped), and no link to a Slant file deleted since it was removed, to one
/// another library model is linked to now (`linkedFileIDs`; such as after an upload Slant saved in that file), so two
/// library models are never linked to one file, or to one whose contents changed this session (`restoredLibraryKeepsLink`).
func restoredLibraryEntry(_ removed: RemovedLibraryModel, deletedCloudFileIDs: Set<String>, currentCount: Int,
                          linkedFileIDs: Set<String> = [], changedFileIDs: Set<String> = [],
                          uploadedBy: [String: UUID] = [:]) -> (model: LocalModel, index: Int) {
    var model = removed.model
    if let remote = model.remoteID,
       !restoredLibraryKeepsLink(fileID: remote, modelID: model.id, deletedCloudFileIDs: deletedCloudFileIDs,
                                 linkedFileIDs: linkedFileIDs, changedFileIDs: changedFileIDs, uploadedBy: uploadedBy) {
        model.remoteID = nil
    }
    return (model, min(max(0, removed.index), currentCount))
}

/// Whether a model put back by Edit › Undo keeps its link to the Slant file `fileID`. Never to a file deleted since,
/// one another library model links now, or one whose contents changed this session (`changedFileIDs`: unlinked after a
/// Replace File, an upload that stopped part-way, Upload from URL or a Workbench upload, or stored into by a confirmed
/// upload, the keys of `uploadedBy`), unless that file's last change was this model's own confirmed upload
/// (`uploadedBy[fileID]`, which every later change removes). Errs towards dropping: the model is then uploaded again,
/// never ordered from a file that may hold another model's bytes.
func restoredLibraryKeepsLink(fileID: String, modelID: UUID, deletedCloudFileIDs: Set<String>, linkedFileIDs: Set<String>,
                              changedFileIDs: Set<String>, uploadedBy: [String: UUID]) -> Bool {
    // The sets may hold an ID as Slant returned it or trimmed: either spelling counts.
    let trimmed = fileID.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return true }
    let forms: Set<String> = [fileID, trimmed]
    guard forms.isDisjoint(with: deletedCloudFileIDs), forms.isDisjoint(with: linkedFileIDs) else { return false }
    let uploaders = forms.compactMap { uploadedBy[$0] }
    guard !forms.isDisjoint(with: changedFileIDs) || !uploaders.isEmpty else { return true }
    return !uploaders.isEmpty && uploaders.allSatisfy { $0 == modelID }
}
