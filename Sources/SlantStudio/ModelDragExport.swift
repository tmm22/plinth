import AppKit
import UniformTypeIdentifiers

// Dragging a library model out to Finder or another app. The drag never offers the library file itself: Finder could
// move it (⌘-drag) or the Dock's Trash could take it. Each drag offers a fresh copy, named after the model, in its own
// temporary folder (on APFS the copy is a clone, so it is instant and takes no extra space). The library is untouched.

enum ModelDragExport {
    static let folderPrefix = "SlantStudio-Drag-"
    /// Folders from earlier drags are removed once they are this old; receivers copy the file when it is dropped.
    static let staleAge: TimeInterval = 10 * 60

    /// The drag payload for a local model: a file URL to a named copy, or an empty provider (nothing to drop) when the
    /// library file is missing or couldn't be copied.
    static func itemProvider(for model: LocalModel, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> NSItemProvider {
        removeStaleFolders(in: temporaryDirectory)
        guard let copy = try? makeCopy(of: model.url, name: model.name, in: temporaryDirectory) else { return NSItemProvider() }
        let provider = NSItemProvider(object: copy as NSURL)
        provider.suggestedName = copy.deletingPathExtension().lastPathComponent
        return provider
    }

    /// Copies `source` to "<temporary>/SlantStudio-Drag-<UUID>/<model name>.<original extension>".
    static func makeCopy(of source: URL, name: String, in temporaryDirectory: URL) throws -> URL {
        let folder = temporaryDirectory.appendingPathComponent(folderPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(exportFileName(modelName: name, fileExtension: source.pathExtension))
        do {
            try FileManager.default.copyItem(at: source, to: destination)
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        return destination
    }

    /// True for a file inside one of these drag folders, so a model dragged from the library onto Studio's own drop
    /// area isn't imported again as a duplicate.
    static func isDragCopy(_ url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        let base = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base + "/") else { return false }
        let relative = path.dropFirst(base.count + 1)
        return relative.hasPrefix(folderPrefix) && relative.contains("/")
    }

    /// Removes drag folders older than `staleAge`. Only folders with this prefix directly in the temporary folder.
    static func removeStaleFolders(in temporaryDirectory: URL, now: Date = Date()) {
        let manager = FileManager.default
        guard let entries = try? manager.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: [.creationDateKey],
                                                             options: [.skipsHiddenFiles]) else { return }
        for entry in entries where entry.lastPathComponent.hasPrefix(folderPrefix) {
            guard let created = try? entry.resourceValues(forKeys: [.creationDateKey]).creationDate,
                  now.timeIntervalSince(created) > staleAge else { continue }
            try? manager.removeItem(at: entry)
        }
    }
}

/// Files dropped on the Models screen that should be imported: model files from elsewhere, never a model dragged out
/// of this library (its drag copy) or a file already inside the library's own folder.
func modelDropURLsToImport(_ urls: [URL], supportDirectory: URL,
                           temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> [URL] {
    urls.filter {
        !ModelDragExport.isDragCopy($0, temporaryDirectory: temporaryDirectory) && !isManagedModelCopy($0, supportDirectory: supportDirectory)
    }
}
