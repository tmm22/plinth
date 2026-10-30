import AppKit
import UniformTypeIdentifiers

// Dragging a library model out to Finder or another app. The drag never offers the library file itself: Finder could
// move it (⌘-drag) or the Dock's Trash could take it. Each drag offers a fresh copy, named after the model, in its own
// temporary folder (on APFS the copy is a clone, so it is instant and takes no extra space). The library is untouched.
// The folders go when Studio quits (this session's), at launch (leftovers from a crash or force quit) and, while it
// runs, once they are a day old, so an app that reads a dropped file some time later still finds it.

enum ModelDragExport {
    static let folderPrefix = "Plinth-Drag-"
    /// Slant Studio's name for these folders: never made any more, but still a drag copy (never imported) and still
    /// removed by the clean-up.
    static let legacyFolderPrefix = "SlantStudio-Drag-"
    /// Every prefix a drag folder may carry, the current one first.
    static let recognisedFolderPrefixes = [folderPrefix, legacyFolderPrefix]
    /// Folders from earlier drags are removed once they are this old. Most receivers copy the file when it is dropped,
    /// but some (a mail draft, an upload form) read it later.
    static let staleAge: TimeInterval = 24 * 60 * 60

    /// The drag payload for a local model: a file URL to a named copy, or an empty provider (nothing to drop) when the
    /// library file is missing or couldn't be copied.
    static func itemProvider(for model: LocalModel, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> NSItemProvider {
        removeStaleFolders(in: temporaryDirectory)
        guard let copy = try? makeCopy(of: model.url, name: model.name, in: temporaryDirectory) else { return NSItemProvider() }
        DragFolderRegistry.shared.add(copy.deletingLastPathComponent())
        let provider = NSItemProvider(object: copy as NSURL)
        provider.suggestedName = copy.deletingPathExtension().lastPathComponent
        return provider
    }

    /// Copies `source` to "<temporary>/Plinth-Drag-<UUID>/<model name>.<original extension>".
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
        return recognisedFolderPrefixes.contains { relative.hasPrefix($0) } && relative.contains("/")
    }

    /// A folder this code made (or Slant Studio's did): a recognised prefix followed by exactly a UUID.
    static func isDragFolderName(_ name: String) -> Bool {
        recognisedFolderPrefixes.contains { prefix in
            name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
        }
    }

    /// Drag folders to delete. With `minimumAge` nil every one goes (launch, when no other copy of Studio is running);
    /// otherwise only those at least that old, and a folder without a date stays.
    static func staleFolderNames(_ entries: [(name: String, created: Date?)], now: Date, minimumAge: TimeInterval?) -> [String] {
        entries.filter { entry in
            guard isDragFolderName(entry.name) else { return false }
            guard let minimumAge else { return true }
            guard let created = entry.created else { return false }
            return now.timeIntervalSince(created) >= minimumAge
        }.map(\.name)
    }

    /// Removes drag folders older than `staleAge`, between drags.
    static func removeStaleFolders(in temporaryDirectory: URL, now: Date = Date()) {
        removeFolders(in: temporaryDirectory, now: now, minimumAge: staleAge)
    }

    /// Launch clean-up (from `PersonalisationTempCleanup`): leftovers a crash or force quit skipped. While another copy
    /// of Studio may be running, its recent drags are left alone; a drag this session already made is always kept.
    static func removeLeftoverFolders(in temporaryDirectory: URL, otherInstanceMayBeRunning: Bool, now: Date = Date()) {
        removeFolders(in: temporaryDirectory, now: now, minimumAge: otherInstanceMayBeRunning ? staleAge : nil,
                      keeping: DragFolderRegistry.shared.names)
    }

    /// Only real folders (never a symbolic link) directly in the temporary folder, named by `isDragFolderName`.
    private static func removeFolders(in temporaryDirectory: URL, now: Date, minimumAge: TimeInterval?, keeping: Set<String> = []) {
        let manager = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let urls = try? manager.contentsOfDirectory(at: temporaryDirectory, includingPropertiesForKeys: keys,
                                                          options: [.skipsSubdirectoryDescendants]) else { return }
        var byName: [String: URL] = [:]
        var entries: [(name: String, created: Date?)] = []
        for url in urls {
            let name = url.lastPathComponent
            guard isDragFolderName(name), !keeping.contains(name), let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == true, values.isSymbolicLink != true else { continue }
            byName[name] = url
            entries.append((name, values.creationDate ?? values.contentModificationDate))
        }
        for name in staleFolderNames(entries, now: now, minimumAge: minimumAge) {
            if let url = byName[name] { try? manager.removeItem(at: url) }
        }
    }
}

/// Drag folders this run of Studio made, removed when it quits. Thread-safe.
final class DragFolderRegistry: @unchecked Sendable {
    static let shared = DragFolderRegistry()
    private let lock = NSLock()
    private var folders: [URL] = []

    func add(_ folder: URL) { lock.withLock { folders.append(folder) } }

    var count: Int { lock.withLock { folders.count } }
    var names: Set<String> { lock.withLock { Set(folders.map(\.lastPathComponent)) } }

    /// When the app terminates: deletes each folder still there.
    func removeAll() {
        let current = lock.withLock { () -> [URL] in
            defer { folders = [] }
            return folders
        }
        for folder in current where ModelDragExport.isDragFolderName(folder.lastPathComponent) {
            try? FileManager.default.removeItem(at: folder)
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
