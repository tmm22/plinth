import SwiftUI
import AppKit

// Library lineage, filter and sort, and Remove Copies of This Model… (local only: nothing here uploads or sends).

// MARK: - Lineage

extension LocalModel {
    /// The library model this copy was made from: `copiedFromID`, or, for a print-ready copy saved before that field
    /// existed, its record's `sourceID`. Nil for an import.
    var originalModelID: UUID? { copiedFromID ?? printPreparation?.sourceID }

    /// A copy Plinth's tools saved: one with a known original, or one carrying a tool's record (copies saved before
    /// `copiedFromID` existed). An import, download, replica or design is an original.
    var isLibraryCopy: Bool {
        originalModelID != nil || printRecipe != nil || designImprovement != nil || reinforcement != nil
            || autoImprovement != nil || printPreparation != nil || filledPockets == true || fromPrintReadyCopy == true
            || fitCoupon == true
    }
}

// MARK: - Copies known only by their names

/// The bracketed endings Plinth's tools give the copies they save (`studioCopyName`, `stlCopyName`, the Size and base,
/// print-ready, reviewed and pockets-filled names and Reinforce's `fileSuffix`), so a copy saved before lineage was
/// recorded still shows under Copies. A replica, a design and a fit test are originals, so their endings are not here.
/// A split always saves two numbered parts, so a bare "(part)" is never a Plinth ending.
let libraryCopyNameSuffixes: Set<String> = [
    "repaired", "simplified", "STL copy", "auto-improved", "prepared", "edge-improved", "print-ready",
    "print-ready, teardrop holes", "reviewed", "pockets filled", "flat base", "plinth", "fit coupon",
    "experimental cells", "experimental shell", "experimental hole ring", "teardrop holes", "bridging",
    "overhang chamfer", "matched walls", "internal walls", "reinforced",
]

/// Reinforce's endings that may carry a part number, "Name (part 2)" (`reinforcementCopyName`).
private let libraryCopyNumberedSuffixes: Set<String> = [
    "experimental cells", "experimental shell", "experimental hole ring", "teardrop holes", "bridging",
    "overhang chamfer", "matched walls", "part", "internal walls", "reinforced",
]

/// The name before the copy ending Plinth's tools add, or nil when the name doesn't end like a copy's: one of
/// `libraryCopyNameSuffixes` in brackets after a name, "(scaled to 50 mm)" or "(scaled to 50 mm wide)" from Scale to
/// Size, "(part 2)" from a split, or the scale check's "-scaled-x25.4". "Owl (print-ready) (auto-improved)" gives
/// "Owl (print-ready)".
func libraryCopyNameBase(_ name: String) -> String? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if let scaled = trimmed.range(of: #"-scaled-x[0-9][0-9.eE+-]*$"#, options: .regularExpression),
       scaled.lowerBound > trimmed.startIndex, !trimmed[trimmed.index(before: scaled.lowerBound)].isWhitespace {
        return String(trimmed[..<scaled.lowerBound])
    }
    guard trimmed.hasSuffix(")"), let open = trimmed.range(of: " (", options: .backwards), open.lowerBound > trimmed.startIndex
    else { return nil }
    let base = String(trimmed[..<open.lowerBound])
    let inner = String(trimmed[open.upperBound..<trimmed.index(before: trimmed.endIndex)])
    if libraryCopyNameSuffixes.contains(inner) { return base }
    if inner.range(of: #"^scaled to [0-9]+(\.[0-9]+)? mm( wide| deep| tall)?$"#, options: .regularExpression) != nil { return base }
    if let space = inner.lastIndex(of: " "), libraryCopyNumberedSuffixes.contains(String(inner[..<space])) {
        let number = inner[inner.index(after: space)...]
        if !number.isEmpty && number.count <= 4 && number.allSatisfy({ $0.isASCII && $0.isNumber }) { return base }
    }
    return nil
}

/// Whether a library name ends the way a copy saved by Plinth's tools does (`libraryCopyNameBase`). On its own this
/// proves nothing: a downloaded "Benchy (simplified)" ends the same way, so the filter also asks for evidence
/// (`isShownAsLibraryCopy`).
func libraryNameLooksLikeCopy(_ name: String) -> Bool { libraryCopyNameBase(name) != nil }

/// How a name is compared with a copy's base: as `studioCopyName` writes it (slashes and colons as hyphens, trimmed),
/// any case, without a trailing .stl/.obj/.3mf (which `stlCopyName` and `scaledCopyName` drop).
func libraryCopyNameKey(_ name: String) -> String {
    var key = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if let dot = key.lastIndex(of: "."), dot > key.startIndex, modelNameFileExtensions.contains(String(key[key.index(after: dot)...])) {
        key = String(key[..<dot]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return key
}

/// The library's names as `libraryCopyNameKey`s, for `isShownAsLibraryCopy`.
func libraryCopyNameKeys(_ models: [LocalModel]) -> Set<String> { Set(models.map { libraryCopyNameKey($0.name) }) }

extension LocalModel {
    /// What the library's Copies and Originals filters go by (display only). A known copy (`isLibraryCopy`) is a copy.
    /// A copy-like name (`libraryNameLooksLikeCopy`) counts only with evidence that Plinth made it, because every
    /// library file, an import's included, is kept in Plinth's Models folder under a new name, so the folder proves
    /// nothing: the model inherited a Z-up lock (only tool copies do), or the library still holds an original whose
    /// name is the copy's less one or more copy endings ("Owl" for "Owl (simplified)" or "Owl (print-ready)
    /// (auto-improved)"). So a downloaded "Benchy (simplified)" stays an original unless "Benchy" is in the library,
    /// and an old copy whose original was removed shows under Originals, like any model nothing ties to another.
    /// Every tool saves its copy as an STL, so an OBJ or 3MF file is never a copy by its name.
    func isShownAsLibraryCopy(libraryNameKeys: Set<String>) -> Bool {
        if isLibraryCopy { return true }
        guard url.pathExtension.lowercased() == "stl", var base = libraryCopyNameBase(name) else { return false }
        if inheritsZUpLock == true { return true }
        let ownKey = libraryCopyNameKey(name)
        var steps = 0
        while steps < 16 {
            let key = libraryCopyNameKey(base)
            if !key.isEmpty, key != ownKey, libraryNameKeys.contains(key) { return true }
            guard let next = libraryCopyNameBase(base) else { return false }
            base = next
            steps += 1
        }
        return false
    }
}

/// Library models by ID (the first of any repeated ID).
func libraryModelsByID(_ models: [LocalModel]) -> [UUID: LocalModel] {
    Dictionary(models.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
}

/// The row caption naming the model a copy came from, or nil when it isn't known to be a copy of a library model, the
/// original is no longer in the library (nothing the seller could do with that), or the copy's name already starts
/// with the original's ("Owl (repaired)" under "Owl"), which says the same thing. So it shows for renamed copies and
/// originals, where the names no longer tell. Show Original is offered whenever the original is in the library.
func libraryCopyCaption(_ model: LocalModel, modelsByID: [UUID: LocalModel]) -> String? {
    guard let originalID = model.originalModelID, originalID != model.id, let original = modelsByID[originalID] else { return nil }
    let originalName = original.name.trimmingCharacters(in: .whitespacesAndNewlines)
    if !originalName.isEmpty, model.name.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(originalName) { return nil }
    return "Copy of “\(original.name)”"
}

/// Every copy made from `id`, and copies of those copies, in library order. Never includes `id` itself.
func libraryCopyIDs(of id: UUID, in models: [LocalModel]) -> [UUID] {
    var children: [UUID: [UUID]] = [:]
    for model in models {
        if let parent = model.originalModelID, parent != model.id { children[parent, default: []].append(model.id) }
    }
    var found: Set<UUID> = [id]
    var queue = [id]
    while let next = queue.popLast() {
        for child in children[next] ?? [] where !found.contains(child) {
            found.insert(child)
            queue.append(child)
        }
    }
    found.remove(id)
    return models.map(\.id).filter { found.contains($0) }
}

// MARK: - Filter and sort

enum LibraryFilter: String, CaseIterable, Identifiable {
    case all, originals, copies, uploaded, readyToUpload
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "All Models"
        case .originals: return "Originals"
        case .copies: return "Copies"
        case .uploaded: return "Uploaded"
        case .readyToUpload: return "Ready to Upload"
        }
    }
    /// `libraryNameKeys` is `libraryCopyNameKeys` of the whole library (`isShownAsLibraryCopy`).
    func includes(_ model: LocalModel, libraryNameKeys: Set<String> = []) -> Bool {
        switch self {
        case .all: return true
        case .originals: return !model.isShownAsLibraryCopy(libraryNameKeys: libraryNameKeys)
        case .copies: return model.isShownAsLibraryCopy(libraryNameKeys: libraryNameKeys)
        case .uploaded: return model.remoteID != nil
        case .readyToUpload: return model.remoteID == nil
        }
    }
    /// What the list says while this filter is on, such as "Showing copies only".
    var showingText: String? {
        switch self {
        case .all: return nil
        case .originals: return "Showing originals only"
        case .copies: return "Showing copies only"
        case .uploaded: return "Showing uploaded models only"
        case .readyToUpload: return "Showing models ready to upload only"
        }
    }
}

/// The Show menu's visible label above the library list: "Show: All Models", "Show: Copies".
func libraryFilterMenuTitle(_ filter: LibraryFilter) -> String { "Show: \(filter.title)" }

/// Its accessible name: the visible label first (WCAG 2.5.3, Label in Name), then what else the menu does.
func libraryFilterMenuAccessibilityLabel(_ filter: LibraryFilter) -> String {
    "\(libraryFilterMenuTitle(filter)), filter and sort models"
}

enum LibrarySort: String, CaseIterable, Identifiable {
    /// The library's own order: newest first, with each automatic print-ready copy beside its original.
    case newest
    case oldest
    case name
    var id: String { rawValue }
    var title: String {
        switch self {
        case .newest: return "Newest First"
        case .oldest: return "Oldest First"
        case .name: return "Name"
        }
    }
}

/// The models the list shows: matching the typed search (by name) and the filter, in the chosen order. Ties in a name
/// sort keep the library's order.
func libraryModelsShown(_ models: [LocalModel], search: String, filter: LibraryFilter, sort: LibrarySort) -> [LocalModel] {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let nameKeys = filter == .originals || filter == .copies ? libraryCopyNameKeys(models) : []
    let matching = models.filter { model in
        filter.includes(model, libraryNameKeys: nameKeys) && (trimmed.isEmpty || model.name.localizedCaseInsensitiveContains(trimmed))
    }
    switch sort {
    case .newest:
        return matching
    case .oldest:
        return matching.reversed()
    case .name:
        return matching.enumerated().sorted { a, b in
            switch a.element.name.localizedStandardCompare(b.element.name) {
            case .orderedAscending: return true
            case .orderedDescending: return false
            case .orderedSame: return a.offset < b.offset
            }
        }.map(\.element)
    }
}

/// What the list says when it shows nothing although the library has models: names the filter (and the typed
/// search), so the seller knows which one emptied it.
func libraryEmptyListText(filter: LibraryFilter, search: String) -> String {
    let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
    let match = trimmed.isEmpty ? nil : "match “\(trimmed)”."
    switch filter {
    case .all: return "No local models \(match ?? "on this Mac.")"
    case .originals: return match.map { "No originals \($0)" } ?? "No originals on this Mac. Every model here is a copy."
    case .copies: return match.map { "No copies \($0)" } ?? "No copies on this Mac."
    case .uploaded: return match.map { "No uploaded models \($0)" } ?? "No models on this Mac are uploaded yet."
    case .readyToUpload: return match.map { "No models ready to upload \($0)" } ?? "Every model on this Mac is uploaded."
    }
}

// MARK: - Remove Copies of This Model…

func libraryRemoveCopiesMenuTitle(count: Int) -> String {
    count == 1 ? "Remove 1 Copy of This Model…" : "Remove \(count) Copies of This Model…"
}

func libraryRemoveCopiesTitle(count: Int, originalName: String) -> String {
    count == 1 ? "Remove 1 copy of “\(originalName)” from your library?"
        : "Remove \(count) copies of “\(originalName)” from your library?"
}

/// The confirmation's message. `movesToTrash` is false only when none of the copies' files is in Plinth's folder.
/// `includesPrintReady` and `usedBySavedProducts` name what the seller might not expect to go with the copies.
func libraryRemoveCopiesMessage(count: Int, originalName: String, uploadedCount: Int, movesToTrash: Bool = true,
                                includesPrintReady: Bool = false, usedBySavedProducts: Int = 0) -> String {
    var message: String
    if count == 1 {
        message = movesToTrash
            ? "The copy will be removed from Plinth and its library file moved to the Trash. To restore it, choose Edit › Undo."
            : "The copy will be removed from Plinth."
    } else {
        message = movesToTrash
            ? "These copies, including any made from other copies, will be removed from Plinth and their library files moved to the Trash. To restore them all, choose Edit › Undo."
            : "These copies, including any made from other copies, will be removed from Plinth."
    }
    if includesPrintReady { message += count == 1 ? " It is the print-ready copy." : " This includes the print-ready copy." }
    if usedBySavedProducts > 0 {
        message += count == 1
            ? " A saved product uses it, so check that product afterwards."
            : (usedBySavedProducts == 1 ? " 1 of them is used in saved products" : " \(usedBySavedProducts) of them are used in saved products")
              + ", so check those products afterwards."
    }
    message += " “\(originalName)” itself stays."
    if uploadedCount > 0 { message += " Uploaded copies stay in your Slant account." }
    return message
}

func libraryRemoveCopiesButtonTitle(count: Int) -> String {
    count == 1 ? "Remove 1 Copy" : "Remove \(count) Copies"
}

/// The entries to put back after removing several models, in the order to insert them: by their old position, so
/// inserting each at its index rebuilds the library's order.
func libraryRestoreOrder(_ removed: [RemovedLibraryModel]) -> [RemovedLibraryModel] {
    removed.enumerated().sorted { ($0.element.index, $0.offset) < ($1.element.index, $1.offset) }.map(\.element)
}

extension StudioStore {
    /// Removes several library models with one confirmation already given, moving each app-owned file to the Trash
    /// like `removeLocalModel`, and registers one Edit › Undo that restores them all. A model whose file can't be
    /// trashed stays in the library and is named in the error.
    func removeLocalModels(ids: [UUID], undoManager: UndoManager?) {
        let wanted = Set(ids)
        let snapshot = localModels
        var removed: [RemovedLibraryModel] = []
        var failures: [String] = []
        let stagingRoot = Self.supportDirectory.appendingPathComponent("Removed", isDirectory: true)
        for (index, model) in snapshot.enumerated() where wanted.contains(model.id) {
            var trashed: TrashedLibraryFile?
            if isManagedModelCopy(model.url, supportDirectory: Self.supportDirectory),
               FileManager.default.fileExists(atPath: model.url.path) {
                do {
                    trashed = try moveLibraryFileToTrash(model.url, displayName: model.name, stagingRoot: stagingRoot)
                } catch {
                    failures.append("“\(model.name)”: \(error.localizedDescription)")
                    continue
                }
            }
            removed.append(RemovedLibraryModel(model: model, index: index, wasSelected: selectedLocalID == model.id, file: trashed))
        }
        if !removed.isEmpty {
            let removedIDs = Set(removed.map(\.model.id))
            localModels.removeAll { removedIDs.contains($0.id) }
            for id in removedIDs {
                try? FileManager.default.removeItem(at: ModelThumbnails.url(for: id))
                ThumbnailMemoryCache.shared.remove(id)
            }
            if let selected = selectedLocalID, removedIDs.contains(selected) {
                selectedLocalID = nil
                fileID = ""
                estimate = nil
            }
            saveModels()
            activities.insert(Activity(title: "Remove from library", detail: libraryModelCountText(removed.count), success: true), at: 0)
            registerRestoreAllUndo(removed, undoManager: undoManager)
        }
        if !failures.isEmpty {
            let lead = failures.count == 1 ? "One model couldn’t be moved to the Trash, so it stays in your library."
                : "\(failures.count) models couldn’t be moved to the Trash, so they stay in your library."
            showError("\(lead) \(failures.joined(separator: " "))")
        }
    }

    /// Like the single removal's undo: refused (and put back on the stack) while modal UI is shown.
    private func registerRestoreAllUndo(_ removed: [RemovedLibraryModel], undoManager: UndoManager?) {
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            MainActor.assumeIsolated {
                guard !store.menuCommandsBlockedByModalUI else {
                    NSSound.beep()
                    DispatchQueue.main.async { store.registerRestoreAllUndo(removed, undoManager: undoManager) }
                    return
                }
                store.restoreRemovedModels(removed, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(libraryRemoveCopiesUndoName)
    }

    /// Undo for `removeLocalModels`: moves every file back from the Trash and reinserts the same entries in their old
    /// places. An entry whose file can't come back is left out and named in the error; the rest are restored.
    func restoreRemovedModels(_ removed: [RemovedLibraryModel], undoManager: UndoManager? = nil) {
        var restoredIDs: [UUID] = []
        var failures: [String] = []
        var reselect: LocalModel?
        for item in libraryRestoreOrder(removed) where !localModels.contains(where: { $0.id == item.model.id }) {
            if let file = item.file {
                do { try restoreLibraryFile(file, to: item.model.url, name: item.model.name) }
                catch { failures.append(error.localizedDescription); continue }
            }
            let entry = restoredLibraryEntry(item, deletedCloudFileIDs: deletedCloudFileIDs, currentCount: localModels.count,
                                             linkedFileIDs: Set(localModels.compactMap(\.remoteID)))
            localModels.insert(entry.model, at: entry.index)
            restoredIDs.append(entry.model.id)
            if item.wasSelected { reselect = entry.model }
        }
        if let reselect, selectedLocalID == nil, fileID.isEmpty { select(reselect) }
        if !restoredIDs.isEmpty {
            saveModels()
            activities.insert(Activity(title: "Restore to library", detail: libraryModelCountText(restoredIDs.count), success: true), at: 0)
        }
        if !failures.isEmpty { showError(failures.joined(separator: " ")) }
        guard !restoredIDs.isEmpty else { return }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] store in
            MainActor.assumeIsolated {
                // Redo is a menu command too: refuse it over modal UI (the models simply stay in the library).
                guard !store.menuCommandsBlockedByModalUI else { NSSound.beep(); return }
                // An upload may be reading a file; the confirmed removal is disabled then too.
                guard !store.busy else { store.showError("Wait for the current task to finish, then remove the copies again."); return }
                store.removeLocalModels(ids: restoredIDs, undoManager: undoManager)
            }
        }
        undoManager?.setActionName(libraryRemoveCopiesUndoName)
    }
}

/// Edit › Undo / Redo's action names, naming the operation as its command does (HIG: Undo and redo): "Undo Remove
/// Copies" for Remove Copies of This Model…, "Undo Remove from Library" for Remove from Library….
let libraryRemoveCopiesUndoName = "Remove Copies"
let libraryRemoveModelUndoName = "Remove from Library"

/// "1 model" / "3 models", for Activity (counts only).
func libraryModelCountText(_ count: Int) -> String {
    count == 1 ? "1 model" : "\(count) models"
}
